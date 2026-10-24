# Quality Assurance Strategy & Test Cases

This document outlines the testing strategy for the Flumen macOS app, covering functional requirements, edge cases, and native system integrations.

## 1. Core Timer Logic
| Case ID | Feature | Description | Expected Result |
| :--- | :--- | :--- | :--- |
| T-1.1 | Accuracy | Start timer and wait for 5 minutes. | Remaining seconds match real-world time (no JS drift). |
| T-1.2 | Pause/Resume | Pause at 12:34, wait 10 seconds, resume. | Timer resumes exactly at 12:34 without skipping. |
| T-1.3 | Reset | Reset timer during a running session. | Timer returns to full duration and status changes to 'idle'. |
| T-1.4 | Completion | Allow timer to reach 00:00. | Notification triggers, completion sound plays, session transitions. |
| T-1.5 | Transition | Complete Focus #4. | App transitions to 'Long Break' instead of 'Short Break'. |

## 2. Task Management & Shelf
| Case ID | Feature | Description | Expected Result |
| :--- | :--- | :--- | :--- |
| TS-2.1 | Creation | Add a task with a project tag. | Task appears in list with the correct tag pill. |
| TS-2.2 | Selection | Click a task in the shelf. | Task becomes 'Active' on the main screen. |
| TS-2.3 | Scrolling | Add 15 tasks to the shelf. | List is scrollable; Header/Form remain pinned at top. |
| TS-2.4 | Session Count | Set estimate to 20 sessions. | 20 small dots appear correctly in the task card. |
| TS-2.5 | Completion | Check a task as complete. | "Task-completed" event fires, next uncompleted task is auto-selected. |
| TS-2.6 | Deletion | Delete the active task. | Task is removed; activeTaskId becomes null or switches to next. |

## 3. Reports & Persistence (The "Corner Cases")
| Case ID | Feature | Description | Expected Result |
| :--- | :--- | :--- | :--- |
| R-3.1 | Reboot Recovery | Start timer, quit app (Cmd+Q), relaunch. | Timer resumes with correct elapsed time (calculated from lastStartedAt). |
| R-3.2 | Fragmented Log | Start focus, pause after 30 seconds, quit app. | 30 seconds are logged in Stats even if the minute wasn't full. |
| R-3.3 | Multi-Day Streak | Log focus time at 11:59 PM and 12:01 AM. | Streak increments correctly; Daily chart shows bars for both dates. |
| R-3.4 | Deleted Tag | Log time for task with tag "Work", then delete task. | Historical report still shows "Work" project in the Mix chart. |
| R-3.5 | Large Log Vol. | Simulate 1,000 session logs. | ReportsView remains performant; scroll is smooth. |

## 4. Native macOS UX
| Case ID | Feature | Description | Expected Result |
| :--- | :--- | :--- | :--- |
| N-4.1 | Click Outside | Open app panel, click on the desktop background. | Panel hides immediately (NSPanel behavior). |
| N-4.2 | Space Switching | Open panel on Desktop 1, swipe to Desktop 2. | Panel stays visible or follows to current space. |
| N-4.3 | Right-Click | Right-click tray icon during running focus. | Menu shows "Skip", "Reset", etc. Action works without opening window. |
| N-4.4 | Notification | Let timer finish while another app is fullscreen. | Notification appears on top of the fullscreen app. |
| N-4.5 | Sound Muting | Toggle "Sound Effects" in Settings. | No sound plays on timer start or task completion. |

## 5. Visual Regression & Glitches
| Case ID | Feature | Description | Expected Result |
| :--- | :--- | :--- | :--- |
| V-5.1 | Viewport Cut | Open Reports and scroll to the bottom. | Bottom border radius is perfectly rounded (no flat edge). |
| V-5.2 | Layout Shift | Observe digits during 09 -> 10 transition. | No horizontal shift in the colon or surrounding digits (tabular-nums check). |
| V-5.3 | Transparency | Move window over a bright image. | Blob background/Grain overlay correctly blend with the dark surface. |
| V-5.4 | Input Focus | Open Task Shelf and try to type immediately. | Input is auto-focused; keyboard events are captured by native NSPanel. |

## 7. Automated Tests
The app includes a suite of automated unit and integration tests powered by **Vitest** and **React Testing Library**, plus native Swift tests and an MCP helper smoke test.

### Running Tests
```bash
npm test -- --run          # TypeScript / UI
npm run test:native        # Swift package tests
npm run test:mcp           # flumen-mcp smoke: refusal (or live app) check, then a full handshake + write against a stub Flumen socket
npm run test:all           # TypeScript + native + MCP smoke
```

### Test Coverage
- **`timerEngine.test.ts`**: Verifies accuracy of the core timestamp-based countdown.
- **`sessionManager.test.ts`**: Validates focus cycle transitions (Focus -> Break -> Long Break).
- **`taskStore.test.ts`**: Ensures tasks can be added, completed, and auto-selected.
- **`statsStore.test.ts`**: Checks activity logging, streak calculation, and report data generation.
- **`agentCommandAdapter.test.ts`**: Timer bridge command handling for agent status/start/pause/finish.
- **`app.test.tsx`**: Integration tests for UI interactions like opening Settings and Task Shelf.
- **`FlumenTests`**: AppRepository provenance, idempotency, revision conflicts, and IPC protocol.

## 8. Agent Access / MCP Regression Matrix

| Case ID | Area | Description | Expected Result |
| :--- | :--- | :--- | :--- |
| M-8.1 | Off by default | Launch with Agent Access disabled | No Unix socket listener; helper exits / fails initialize — Cursor must not stay healthy green |
| M-8.2 | Read tools | Enable Agent Access; call `get_focus_status`, `list_tasks` | Structured local data; no writes |
| M-8.3 | Write confirmation | Call `log_time` | Flumen proposal UI + notification; decline leaves DB unchanged |
| M-8.4 | Ad-hoc metrics | Confirm agent `log_time` | Totals/streak increase; completedCycles unchanged |
| M-8.5 | Idempotency | Retry same idempotency key | Same activity id/result; no duplicate row |
| M-8.6 | Overlap | Propose overlapping interval | Rejected with `activity_overlap` |
| M-8.7 | Future time | Propose start far in the future | Validation error |
| M-8.8 | Multi-client | Two helpers connected | Serialized writes; connections listed informationally |
| M-8.9 | Packaging | Universal release build | `flumen-mcp` in `Contents/Helpers`, both arch slices signed |
| M-8.10 | Staging isolation | Staging app Agent Access | Staging socket/helper only; production data untouched |
| M-8.11 | Turn Off while live | Disable Agent Access during an active Cursor session | Socket closes; helper exits within a few seconds; Cursor drops healthy connection |

### Manual client matrix
Verify `tools/list` + `get_server_status` against current Cursor, Claude Code, Codex, and Gemini CLI versions after helper packaging changes. Setup instructions live in [MCP-SETUP.md](MCP-SETUP.md).
