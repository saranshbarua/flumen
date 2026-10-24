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
  summary: 'Cursor · Finish focus',
  sideEffects: ['Stops the active timer and advances the session', 'Marks “Write report” complete'],
  expiresAt: Date.now() + 60_000,
};

describe('AgentProposalOverlay', () => {
  beforeEach(() => vi.clearAllMocks());

  it('shows every side effect, including task completion', () => {
    render(<AgentProposalOverlay proposal={baseProposal} onApproving={vi.fn()} onDismiss={vi.fn()} />);
    expect(screen.getByText(/Marks “Write report” complete/)).toBeTruthy();
    expect(screen.getByText('Cursor · Finish focus')).toBeTruthy();
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
    expect((screen.getByText('Applying…', { selector: 'button' }) as HTMLButtonElement).disabled).toBe(true);
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
    expect(screen.getByRole('alert').textContent).toContain('Task was changed after approval.');
    fireEvent.click(screen.getByText('Close'));
    expect(onDismiss).toHaveBeenCalledWith('r1');
  });

  it('shows how many proposals are queued behind this one', () => {
    render(<AgentProposalOverlay proposal={baseProposal} queuedCount={2} onApproving={vi.fn()} onDismiss={vi.fn()} />);
    expect(screen.getByText('2 more waiting')).toBeTruthy();
  });

  it('declines and dismisses immediately', () => {
    const onDismiss = vi.fn();
    render(<AgentProposalOverlay proposal={baseProposal} onApproving={vi.fn()} onDismiss={onDismiss} />);
    fireEvent.click(screen.getByText('Decline'));
    expect(NativeBridge.agentProposalResult).toHaveBeenCalledWith('r1', false, 'user_declined');
    expect(onDismiss).toHaveBeenCalledWith('r1');
  });
});
