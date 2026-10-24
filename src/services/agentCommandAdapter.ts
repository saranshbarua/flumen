import { TimerEngine } from '../core/timerEngine';
import { usePomodoroStore } from '../state/pomodoroStore';
import { useTaskStore } from '../state/taskStore';
import { getLastStateUpdatedAt } from './persistence';
import { NativeBridge } from './nativeBridge';

export interface AgentCommand {
  requestId?: string;
  command?: string;
  name?: string;
  confirmed?: boolean;
  /** Check preconditions only; never mutate. */
  dryRun?: boolean;
  /** Epoch ms after which native has already reported a timeout, so a mutation must not run. */
  deadline?: number;
  arguments?: Record<string, unknown>;
  args?: Record<string, unknown>;
}

export type AgentCommandResult =
  | { ok: true; requestId: string; data: Record<string, unknown> }
  | { ok: false; requestId: string; error: { code: string; message: string } };

const fail = (requestId: string, code: string, message: string): AgentCommandResult => ({
  ok: false,
  requestId,
  error: { code, message },
});

const getStatus = (requestId: string, now = Date.now()): AgentCommandResult => {
  const pomodoro = usePomodoroStore.getState();
  const tasks = useTaskStore.getState();
  const timer = pomodoro.timer;
  const remainingSeconds = TimerEngine.getRemainingSeconds(timer, now);
  const activeTask = tasks.tasks.find((task) => task.id === tasks.activeTaskId) ?? null;
  const lastStateUpdatedAt = getLastStateUpdatedAt() ?? now;

  return {
    ok: true,
    requestId,
    data: {
      now,
      capturedAt: now,
      lastStateUpdatedAt,
      dataFreshness: {
        lastStateUpdatedAt,
        ageMs: Math.max(0, now - lastStateUpdatedAt),
      },
      timer: {
        status: timer.status,
        sessionType: pomodoro.session.type,
        remainingSeconds,
        totalDuration: timer.totalDuration,
        startedAt: timer.status === 'running' ? timer.lastStartedAt : null,
        endsAt:
          timer.status === 'running' && timer.lastStartedAt !== null
            ? timer.lastStartedAt + timer.remainingSeconds * 1000
            : null,
      },
      activeTask,
      config: {
        focusDurationSeconds: pomodoro.config.focusDuration,
      },
    },
  };
};

const asString = (value: unknown) => typeof value === 'string' ? value.trim() : '';
const asPositiveInteger = (value: unknown, fallback = 1) =>
  typeof value === 'number' && Number.isFinite(value) && value > 0
    ? Math.max(1, Math.round(value))
    : fallback;

export const executeAgentCommand = (
  input: AgentCommand,
  now = Date.now()
): AgentCommandResult => {
  const requestId = asString(input?.requestId) || crypto.randomUUID();
  const command = asString(input?.command || input?.name).toLowerCase().replace(/-/g, '_');
  const args = input?.arguments ?? input?.args ?? {};

  if (command === 'get_status' || command === 'status' || command === 'get_timer_status') {
    return getStatus(requestId, now);
  }

  // A dry run applies every precondition but changes nothing, so native can refuse an
  // impossible proposal before asking the person to approve it.
  const dryRun = input?.dryRun === true;
  const wouldApply = (): AgentCommandResult => ({ ok: true, requestId, data: { wouldApply: true } });

  if (!dryRun && !input?.confirmed) {
    return fail(
      requestId,
      'confirmation_required',
      'This action requires explicit confirmation in Flumen.'
    );
  }

  if (!dryRun && typeof input.deadline === 'number' && now > input.deadline) {
    return fail(
      requestId,
      'command_expired',
      'Flumen received this command after the agent stopped waiting, so nothing was changed.'
    );
  }

  const pomodoro = usePomodoroStore.getState();
  const taskStore = useTaskStore.getState();

  switch (command) {
    case 'set_active_task': {
      const taskId = asString(args.taskId ?? args.id);
      const task = taskStore.tasks.find((candidate) => candidate.id === taskId);
      if (!task || task.status !== 0) {
        return fail(requestId, 'task_not_found', 'Choose an active, incomplete Flumen task.');
      }
      if (dryRun) return wouldApply();
      taskStore.setActiveTask(task.id);
      return { ok: true, requestId, data: { activeTaskId: task.id } };
    }

    case 'begin_focus':
    case 'start_focus': {
      if (pomodoro.timer.status === 'running') {
        return fail(requestId, 'timer_already_running', 'A Flumen timer is already running.');
      }
      if (pomodoro.timer.status === 'paused') {
        return fail(requestId, 'timer_paused', 'A focus session is paused. Use resume_focus to continue it.');
      }
      if (pomodoro.session.type !== 'focus') {
        return fail(requestId, 'not_focus_session', 'Finish or reset the current break before starting focus.');
      }

      let taskId = asString(args.taskId);
      if (taskId) {
        const selected = taskStore.tasks.find((task) => task.id === taskId && task.status === 0);
        if (!selected) return fail(requestId, 'task_not_found', 'The requested task is unavailable.');
        if (dryRun) return wouldApply();
        taskStore.setActiveTask(taskId);
      } else if (dryRun) {
        return wouldApply();
      } else {
        const taskPayload =
          args.task && typeof args.task === 'object'
            ? args.task as Record<string, unknown>
            : args;
        const title = asString(taskPayload.title);
        if (title) {
          const projectId = asString(taskPayload.projectId);
          const projectName = projectId
            ? taskStore.projects.find((project) => project.id === projectId)?.name
            : undefined;
          taskId = taskStore.addTask(
            title,
            asPositiveInteger(taskPayload.estimatedPomos),
            asString(taskPayload.project ?? taskPayload.tag) || projectName || undefined
          );
          taskStore.setActiveTask(taskId);
        }
      }

      usePomodoroStore.getState().startTimer(now);
      return {
        ok: true,
        requestId,
        data: { startedAt: now, activeTaskId: useTaskStore.getState().activeTaskId },
      };
    }

    case 'resume':
    case 'resume_timer':
    case 'resume_focus':
      if (pomodoro.timer.status !== 'paused') {
        return fail(requestId, 'timer_not_paused', 'There is no paused timer to resume.');
      }
      if (dryRun) return wouldApply();
      pomodoro.startTimer(now);
      return { ok: true, requestId, data: { resumedAt: now } };

    case 'pause':
    case 'pause_timer':
    case 'pause_focus':
      if (pomodoro.timer.status !== 'running') {
        return fail(requestId, 'timer_not_running', 'There is no running timer to pause.');
      }
      if (dryRun) return wouldApply();
      pomodoro.pauseTimer();
      return { ok: true, requestId, data: { pausedAt: now } };

    case 'finish':
    case 'finish_timer':
    case 'finish_focus':
      if (pomodoro.timer.status !== 'running' && pomodoro.timer.status !== 'paused') {
        return fail(requestId, 'timer_not_active', 'There is no active timer to finish.');
      }
      if (dryRun) return wouldApply();
      pomodoro.skipTimer();
      return { ok: true, requestId, data: { finishedAt: now } };

    case 'complete_task': {
      const taskId = asString(args.taskId ?? args.id) || taskStore.activeTaskId;
      const task = taskStore.tasks.find((candidate) => candidate.id === taskId);
      if (!task) return fail(requestId, 'task_not_found', 'The requested task is unavailable.');
      if (dryRun) return wouldApply();
      if (!task.isCompleted) taskStore.toggleTask(task.id);
      return { ok: true, requestId, data: { taskId: task.id, isCompleted: true } };
    }

    default:
      return fail(requestId, 'unsupported_command', `Unsupported agent command: ${command || 'unknown'}`);
  }
};

export const handleNativeAgentCommand = (event: Event) => {
  const detail = (event as CustomEvent).detail;
  const command = detail?.command && typeof detail.command === 'object'
    ? { ...detail.command, requestId: detail.command.requestId ?? detail.requestId }
    : detail;
  const result = executeAgentCommand(command ?? {});
  NativeBridge.agentCommandResult(result.requestId, result);
  return result;
};

