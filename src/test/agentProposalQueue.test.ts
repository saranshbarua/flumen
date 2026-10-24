import { describe, expect, it } from 'vitest';
import {
  QueuedProposal,
  dismissProposal,
  enqueueProposal,
  markApplying,
  settleProposal,
  syncPendingProposals,
} from '../ui/agentProposalQueue';

const proposal = (requestId: string) => ({ requestId, action: 'log_time' });

describe('agent proposal queue', () => {
  it('keeps every concurrent proposal instead of replacing the visible one', () => {
    let queue: QueuedProposal[] = [];
    queue = enqueueProposal(queue, proposal('a'));
    queue = enqueueProposal(queue, proposal('b'));
    queue = enqueueProposal(queue, proposal('a'));
    expect(queue.map((entry) => entry.requestId)).toEqual(['a', 'b']);
    expect(queue.every((entry) => entry.phase === 'review')).toBe(true);
  });

  it('removes a cancelled or expired proposal so it cannot be approved', () => {
    let queue = enqueueProposal(enqueueProposal([], proposal('a')), proposal('b'));
    queue = settleProposal(queue, { requestId: 'a', outcome: 'cancelled' });
    queue = settleProposal(queue, { requestId: 'b', outcome: 'expired' });
    expect(queue).toEqual([]);
  });

  it('keeps an approved proposal until native settles it', () => {
    let queue = markApplying(enqueueProposal([], proposal('a')), 'a');
    expect(queue[0].phase).toBe('applying');
    queue = settleProposal(queue, { requestId: 'a', outcome: 'applied' });
    expect(queue).toEqual([]);
  });

  it('shows a failure after approval instead of silently dismissing', () => {
    let queue = markApplying(enqueueProposal([], proposal('a')), 'a');
    queue = settleProposal(queue, { requestId: 'a', outcome: 'failed', message: 'Task was changed after approval.' });
    expect(queue[0]).toMatchObject({ phase: 'failed', error: 'Task was changed after approval.' });
    expect(dismissProposal(queue, 'a')).toEqual([]);
  });

  it('treats an approval of a closed request as a visible failure', () => {
    let queue = markApplying(enqueueProposal([], proposal('a')), 'a');
    queue = settleProposal(queue, { requestId: 'a', outcome: 'unavailable', message: 'No longer waiting.' });
    expect(queue[0]).toMatchObject({ phase: 'failed', error: 'No longer waiting.' });
  });

  it('restores pending proposals from native and drops stale reviewable cards', () => {
    let queue = enqueueProposal([], proposal('stale'));
    queue = enqueueProposal(queue, proposal('applying'));
    queue = markApplying(queue, 'applying');
    queue = syncPendingProposals(queue, [proposal('p1'), proposal('p2')]);
    expect(queue.map((entry) => [entry.requestId, entry.phase])).toEqual([
      ['applying', 'applying'],
      ['p1', 'review'],
      ['p2', 'review'],
    ]);
  });
});
