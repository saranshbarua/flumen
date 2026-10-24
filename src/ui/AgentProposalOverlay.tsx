import React, { useEffect, useState } from 'react';
import { NativeBridge } from '../services/nativeBridge';
import type { ProposalPhase } from './agentProposalQueue';
import { theme } from './theme';
import { agentDisplayName } from './agentClientName';

export interface AgentProposal {
  requestId: string;
  action: string;
  actionTitle?: string;
  title?: string;
  task?: { id?: string; title?: string };
  project?: { id?: string; name?: string } | string;
  durationSeconds?: number;
  startedAt?: number;
  endedAt?: number;
  reason?: string;
  /** Per-task breakdown for batch proposals such as complete_tasks. */
  items?: { title: string; sessions: number; durationSeconds: number }[];
  provenance?: {
    origin?: string;
    durationSource?: string;
    source?: string;
  };
  sideEffects?: string[] | string;
  expiresAt?: number;
  summary?: string;
}

interface AgentProposalOverlayProps {
  proposal: AgentProposal;
  phase?: ProposalPhase;
  error?: string;
  /** Other proposals waiting behind this one. */
  queuedCount?: number;
  onApproving: (requestId: string) => void;
  onDismiss: (requestId: string) => void;
}

const MAX_PIPS = 12;

const formatDuration = (seconds?: number) => {
  if (!seconds || seconds < 1) return null;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const rest = minutes % 60;
  return rest ? `${Math.floor(minutes / 60)}h ${rest}m` : `${minutes / 60}h`;
};

const formatTime = (value?: number) =>
  value ? new Date(value).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) : null;

const formatDay = (value?: number) => {
  if (!value) return null;
  const date = new Date(value);
  if (date.toDateString() === new Date().toDateString()) return null;
  return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
};

const AgentProposalOverlay: React.FC<AgentProposalOverlayProps> = ({
  proposal,
  phase = 'review',
  error,
  queuedCount = 0,
  onApproving,
  onDismiss,
}) => {
  const [now, setNow] = useState(Date.now());
  const [windowMs] = useState(() => (proposal.expiresAt ? Math.max(1, proposal.expiresAt - Date.now()) : 0));
  const expiresAt = proposal.expiresAt;
  const reviewing = phase === 'review';
  const expired = reviewing && Boolean(expiresAt && expiresAt <= now);

  useEffect(() => {
    if (!expiresAt || !reviewing) return;
    const interval = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(interval);
  }, [expiresAt, reviewing]);

  useEffect(() => {
    if (!expired) return;
    NativeBridge.agentProposalResult(proposal.requestId, false, 'expired');
    onDismiss(proposal.requestId);
  }, [expired, onDismiss, proposal.requestId]);

  const approve = () => {
    NativeBridge.agentProposalResult(proposal.requestId, true);
    onApproving(proposal.requestId);
  };

  const decline = () => {
    NativeBridge.agentProposalResult(proposal.requestId, false, 'user_declined');
    onDismiss(proposal.requestId);
  };

  if (expired) return null;

  const start = formatTime(proposal.startedAt);
  const end = formatTime(proposal.endedAt);
  const day = formatDay(proposal.startedAt);
  const interval = start && end ? `${day ? `${day}, ` : ''}${start}–${end}` : null;
  const project = typeof proposal.project === 'string' ? proposal.project : proposal.project?.name;
  const meta = [project, interval, formatDuration(proposal.durationSeconds)].filter(Boolean).join('  ·  ');
  const notes = Array.isArray(proposal.sideEffects)
    ? proposal.sideEffects
    : proposal.sideEffects ? [proposal.sideEffects] : [];
  const subject = proposal.items?.length ? null : proposal.task?.title;
  const remaining = expiresAt && windowMs ? Math.max(0, Math.min(1, (expiresAt - now) / windowMs)) : 0;
  const secondsLeft = expiresAt ? Math.max(0, Math.ceil((expiresAt - now) / 1000)) : 0;

  return (
    <div role="presentation" className="agent-sheet-backdrop" style={backdropStyle}>
      <style>{sheetMotion}</style>
      <div className="agent-sheet" style={stackStyle}>
        {queuedCount > 1 && <div aria-hidden style={peekStyle(2)} />}
        {queuedCount > 0 && <div aria-hidden style={peekStyle(1)} />}
        <section
          role="dialog"
          aria-modal="true"
          aria-labelledby="proposal-title"
          aria-busy={phase === 'applying'}
          style={cardStyle}
        >
          {reviewing && expiresAt && (
            <div
              role="progressbar"
              aria-label={`${secondsLeft} seconds to respond`}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={Math.round(remaining * 100)}
              style={timeTrackStyle}
            >
              <div style={{ ...timeFillStyle, transform: `scaleX(${remaining})` }} />
            </div>
          )}

          <div style={originStyle}>
            {agentDisplayName(proposal.provenance?.origin)}
            {queuedCount > 0 && <span style={visuallyHidden}>, {queuedCount} more waiting</span>}
          </div>
          <h2 id="proposal-title" style={titleStyle}>{proposal.actionTitle || proposal.title || proposal.action}</h2>
          {subject && <p style={subjectStyle}>{subject}</p>}
          {meta && <p style={metaStyle}>{meta}</p>}
          {proposal.reason && <p style={reasonStyle}>“{proposal.reason}”</p>}

          {proposal.items && proposal.items.length > 0 && (
            <ul aria-label="Tasks" style={itemListStyle}>
              {proposal.items.map((item, index) => (
                <li key={`${item.title}-${index}`} style={itemRowStyle}>
                  <span style={itemTitleStyle}>{item.title}</span>
                  <span style={itemMetaStyle} aria-label={`${item.sessions} sessions`}>
                    <SessionPips count={item.sessions} />
                    {formatDuration(item.durationSeconds) ?? '—'}
                  </span>
                </li>
              ))}
            </ul>
          )}

          {notes.length > 0 && (
            <ul style={notesStyle}>
              {notes.map((note, index) => <li key={`${note}-${index}`}>{note}</li>)}
            </ul>
          )}

          {phase === 'failed' ? (
            <>
              <p role="alert" style={errorStyle}>{error}</p>
              <button type="button" className="agent-sheet-button" onClick={() => onDismiss(proposal.requestId)} style={{ ...primaryButtonStyle, marginTop: 18 }}>
                Close
              </button>
            </>
          ) : (
            <div style={actionsStyle}>
              <button type="button" className="agent-sheet-button" onClick={decline} disabled={!reviewing} style={buttonState(secondaryButtonStyle, reviewing)}>
                Decline
              </button>
              <button type="button" className="agent-sheet-button" onClick={approve} disabled={!reviewing} style={buttonState(primaryButtonStyle, reviewing)}>
                {phase === 'applying' ? 'Applying…' : 'Approve'}
              </button>
            </div>
          )}
        </section>
      </div>
    </div>
  );
};

const SPRING = 'cubic-bezier(0.32, 0.72, 0, 1)';

const sheetMotion = `
  @keyframes agentSheetIn { from { transform: translateY(28px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
  @keyframes agentBackdropIn { from { opacity: 0; } to { opacity: 1; } }
  .agent-sheet-backdrop { animation: agentBackdropIn 320ms ${SPRING} both; }
  .agent-sheet { animation: agentSheetIn 560ms ${SPRING} both; }
  .agent-sheet-button { transition: transform 260ms ${SPRING}, opacity 260ms ${SPRING}, background-color 260ms ${SPRING}; }
  .agent-sheet-button:not(:disabled):active { transform: scale(0.97); }
  .agent-sheet-button:focus-visible { outline: 2px solid ${theme.colors.focus.primary}; outline-offset: 2px; }
  @media (prefers-reduced-motion: reduce) {
    .agent-sheet-backdrop, .agent-sheet { animation: none; }
    .agent-sheet-button { transition: none; }
  }
`;

const SessionPips: React.FC<{ count: number }> = ({ count }) => (
  <span aria-hidden style={pipRowStyle}>
    {Array.from({ length: Math.min(count, MAX_PIPS) }).map((_, index) => <span key={index} style={pipStyle} />)}
    {count > MAX_PIPS && <span>+{count - MAX_PIPS}</span>}
  </span>
);

const buttonState = (style: React.CSSProperties, enabled: boolean): React.CSSProperties =>
  enabled ? style : { ...style, opacity: 0.4, cursor: 'default' };

const backdropStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 5000, background: 'rgba(0,0,0,.72)', backdropFilter: 'blur(16px)', display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', padding: 12, borderRadius: theme.radii.window };
const stackStyle: React.CSSProperties = { position: 'relative', display: 'flex', flexDirection: 'column', maxHeight: '100%', paddingTop: 14 };
const peekStyle = (depth: 1 | 2): React.CSSProperties => ({
  position: 'absolute', top: 14 - depth * 6, left: depth * 12, right: depth * 12, height: 24,
  borderRadius: `${theme.radii.button} ${theme.radii.button} 0 0`,
  background: theme.colors.surface,
  border: `1px solid ${theme.colors.border}`,
  borderBottom: 'none',
});
const cardStyle: React.CSSProperties = { position: 'relative', width: '100%', maxHeight: '100%', overflowY: 'auto', boxSizing: 'border-box', padding: '22px 16px 16px', borderRadius: theme.radii.button, background: theme.colors.surface, border: `1px solid ${theme.colors.border}`, color: theme.colors.text.primary, fontFamily: theme.fonts.display };
const timeTrackStyle: React.CSSProperties = { position: 'absolute', top: 10, left: '50%', width: 36, marginLeft: -18, height: 3, overflow: 'hidden', borderRadius: 3, background: theme.colors.button.background };
const timeFillStyle: React.CSSProperties = { height: '100%', background: theme.colors.focus.primary, transformOrigin: 'left', transition: `transform 1s ${SPRING}` };
const originStyle: React.CSSProperties = { color: theme.colors.text.muted, fontSize: '0.7rem', marginBottom: 6 };
const titleStyle: React.CSSProperties = { fontFamily: theme.fonts.brand, fontSize: '1.25rem', fontWeight: 700, lineHeight: 1.15, letterSpacing: '-.02em', margin: 0 };
const subjectStyle: React.CSSProperties = { margin: '6px 0 0', color: theme.colors.text.primary, fontSize: '0.9rem', lineHeight: 1.35, overflowWrap: 'anywhere' };
const metaStyle: React.CSSProperties = { margin: '8px 0 0', color: theme.colors.text.secondary, fontSize: '0.75rem', fontVariantNumeric: 'tabular-nums', whiteSpace: 'pre-wrap' };
const reasonStyle: React.CSSProperties = { margin: '8px 0 0', color: theme.colors.text.secondary, fontSize: '0.75rem', lineHeight: 1.45, overflowWrap: 'anywhere' };
const itemListStyle: React.CSSProperties = { listStyle: 'none', margin: '14px 0 0', padding: 0, display: 'flex', flexDirection: 'column', borderTop: `1px solid ${theme.colors.border}` };
const itemRowStyle: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12, padding: '9px 0', borderBottom: `1px solid ${theme.colors.border}`, fontSize: '0.75rem' };
const itemTitleStyle: React.CSSProperties = { color: theme.colors.text.primary, overflowWrap: 'anywhere' };
const itemMetaStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 8, color: theme.colors.text.secondary, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' };
const pipRowStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 4, fontSize: 10 };
const pipStyle: React.CSSProperties = { width: 5, height: 5, borderRadius: '50%', background: 'white' };
const notesStyle: React.CSSProperties = { listStyle: 'none', margin: '12px 0 0', padding: 0, display: 'flex', flexDirection: 'column', gap: 4, color: theme.colors.text.muted, fontSize: '0.7rem', lineHeight: 1.4 };
const errorStyle: React.CSSProperties = { margin: '14px 0 0', color: theme.colors.focus.primary, fontSize: '0.75rem', lineHeight: 1.45 };
const actionsStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 8, marginTop: 20 };
const primaryButtonStyle: React.CSSProperties = { width: '100%', height: 40, marginTop: 0, border: 'none', borderRadius: theme.radii.button, background: theme.colors.text.primary, color: theme.colors.background, fontFamily: theme.fonts.display, fontSize: '0.8rem', fontWeight: 650, cursor: 'pointer' };
const secondaryButtonStyle: React.CSSProperties = { ...primaryButtonStyle, background: theme.colors.button.background, color: theme.colors.text.primary, border: `1px solid ${theme.colors.border}` };
const visuallyHidden: React.CSSProperties = { position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' };

export default AgentProposalOverlay;
