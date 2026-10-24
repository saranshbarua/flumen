import type { AgentProposal } from './AgentProposalOverlay';

export type ProposalPhase = 'review' | 'applying' | 'failed';

export interface QueuedProposal extends AgentProposal {
  phase: ProposalPhase;
  error?: string;
}

export type ProposalOutcome = 'applied' | 'failed' | 'declined' | 'expired' | 'cancelled' | 'unavailable';

export interface ProposalSettlement {
  requestId: string;
  outcome: ProposalOutcome;
  message?: string;
}

/** Adds a proposal unless it is already queued. */
export const enqueueProposal = (queue: QueuedProposal[], proposal: AgentProposal): QueuedProposal[] =>
  queue.some((entry) => entry.requestId === proposal.requestId)
    ? queue
    : [...queue, { ...proposal, phase: 'review' }];

/**
 * Replaces the reviewable entries with native's pending list (oldest first).
 * Entries the person already approved stay until native settles them.
 */
export const syncPendingProposals = (queue: QueuedProposal[], pending: AgentProposal[]): QueuedProposal[] => {
  const decided = queue.filter((entry) => entry.phase !== 'review');
  const decidedIds = new Set(decided.map((entry) => entry.requestId));
  const reviewable = pending
    .filter((proposal) => proposal?.requestId && !decidedIds.has(proposal.requestId))
    .map((proposal) => ({ ...proposal, phase: 'review' as const }));
  return [...decided, ...reviewable];
};

export const markApplying = (queue: QueuedProposal[], requestId: string): QueuedProposal[] =>
  queue.map((entry) => (entry.requestId === requestId ? { ...entry, phase: 'applying', error: undefined } : entry));

export const dismissProposal = (queue: QueuedProposal[], requestId: string): QueuedProposal[] =>
  queue.filter((entry) => entry.requestId !== requestId);

/**
 * Applies native's final word on a proposal. A failure after approval stays on screen
 * so the person learns the change did not happen; everything else leaves the queue.
 */
export const settleProposal = (queue: QueuedProposal[], settlement: ProposalSettlement): QueuedProposal[] => {
  const entry = queue.find((candidate) => candidate.requestId === settlement.requestId);
  if (!entry) return queue;
  const approvedThenFailed =
    settlement.outcome === 'failed' || (settlement.outcome === 'unavailable' && entry.phase === 'applying');
  if (approvedThenFailed) {
    return queue.map((candidate) =>
      candidate.requestId === settlement.requestId
        ? { ...candidate, phase: 'failed', error: settlement.message || 'Flumen could not apply this change.' }
        : candidate
    );
  }
  return dismissProposal(queue, settlement.requestId);
};
