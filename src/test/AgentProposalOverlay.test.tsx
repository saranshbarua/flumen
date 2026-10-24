import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import React from 'react';
import AgentProposalOverlay from '../ui/AgentProposalOverlay';
import { NativeBridge } from '../services/nativeBridge';

vi.mock('../services/nativeBridge', () => ({
  NativeBridge: { agentProposalResult: vi.fn() },
}));

const baseProposal = {
  requestId: 'r1',
  action: 'finish_focus',
  actionTitle: 'Finish focus',
  title: 'Write report',
  task: { id: 't1', title: 'Write report' },
  summary: 'Cursor · Finish focus',
  provenance: { origin: 'Cursor' },
  sideEffects: ['Also marks “Write report” complete'],
  expiresAt: Date.now() + 60_000,
};

describe('AgentProposalOverlay', () => {
  beforeEach(() => vi.clearAllMocks());

  it('leads with the action and the task, without field labels', () => {
    render(<AgentProposalOverlay proposal={baseProposal} onApproving={vi.fn()} onDismiss={vi.fn()} />);
    expect(screen.getByRole('heading').textContent).toBe('Finish focus');
    expect(screen.getByText('Write report')).toBeTruthy();
    expect(screen.getByText('Cursor')).toBeTruthy();
    expect(screen.queryByText(/AGENT PROPOSAL|WHAT WILL CHANGE|ACTION|SOURCE/)).toBeNull();
  });

  it('shows consequences the heading does not already say', () => {
    render(<AgentProposalOverlay proposal={baseProposal} onApproving={vi.fn()} onDismiss={vi.fn()} />);
    expect(screen.getByText('Also marks “Write report” complete')).toBeTruthy();
  });

  it('shows time left as a progress bar instead of text', () => {
    render(<AgentProposalOverlay proposal={baseProposal} onApproving={vi.fn()} onDismiss={vi.fn()} />);
    expect(screen.getByRole('progressbar').getAttribute('aria-label')).toMatch(/seconds to respond/);
    expect(screen.queryByText(/Expires in/)).toBeNull();
  });

  it('approving keeps the card open in an applying state', () => {
    const onApproving = vi.fn();
    const onDismiss = vi.fn();
    render(<AgentProposalOverlay proposal={baseProposal} onApproving={onApproving} onDismiss={onDismiss} />);
    fireEvent.click(screen.getByText('Approve'));
    expect(NativeBridge.agentProposalResult).toHaveBeenCalledWith('r1', true);
    expect(onApproving).toHaveBeenCalledWith('r1');
    expect(onDismiss).not.toHaveBeenCalled();
  });

  it('disables both buttons while applying', () => {
    render(<AgentProposalOverlay proposal={baseProposal} phase="applying" onApproving={vi.fn()} onDismiss={vi.fn()} />);
    expect((screen.getByText('Applying…') as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByText('Decline') as HTMLButtonElement).disabled).toBe(true);
  });

  it('shows why an approved change was not applied', () => {
    const onDismiss = vi.fn();
    render(
      <AgentProposalOverlay
        proposal={baseProposal}
        phase="failed"
        error="Task was changed after approval."
        onApproving={vi.fn()}
        onDismiss={onDismiss}
      />
    );
    expect(screen.getByRole('alert').textContent).toBe('Task was changed after approval.');
    fireEvent.click(screen.getByText('Close'));
    expect(onDismiss).toHaveBeenCalledWith('r1');
  });

  it('signals queued proposals through layout and to screen readers', () => {
    render(<AgentProposalOverlay proposal={baseProposal} queuedCount={2} onApproving={vi.fn()} onDismiss={vi.fn()} />);
    expect(screen.getByText(/2 more waiting/)).toBeTruthy();
  });

  it('lists every task with its sessions in a batch completion', () => {
    render(
      <AgentProposalOverlay
        proposal={{
          requestId: 'batch',
          action: 'complete_tasks',
          actionTitle: 'Complete tasks',
          items: [
            { title: 'Smoke-test build', sessions: 3, durationSeconds: 4500 },
            { title: 'Already filled', sessions: 0, durationSeconds: 0 },
          ],
        }}
        onApproving={vi.fn()}
        onDismiss={vi.fn()}
      />
    );
    expect(screen.getByText('Smoke-test build')).toBeTruthy();
    expect(screen.getByLabelText('3 sessions').textContent).toBe('1h 15m');
    expect(screen.getByLabelText('0 sessions').textContent).toBe('—');
  });

  it('declines and dismisses immediately', () => {
    const onDismiss = vi.fn();
    render(<AgentProposalOverlay proposal={baseProposal} onApproving={vi.fn()} onDismiss={onDismiss} />);
    fireEvent.click(screen.getByText('Decline'));
    expect(NativeBridge.agentProposalResult).toHaveBeenCalledWith('r1', false, 'user_declined');
    expect(onDismiss).toHaveBeenCalledWith('r1');
  });
});
