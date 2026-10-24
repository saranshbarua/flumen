import React, { useEffect, useState } from 'react';
import { NativeBridge } from '../services/nativeBridge';
import type { ProposalPhase } from './agentProposalQueue';
import { theme } from './theme';

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
    <div role="presentation" style={backdropStyle}>
      <div style={stackStyle}>
        {queuedCount > 0 && <div aria-hidden style={peekStyle(queuedCount > 1)} />}
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
            {proposal.provenance?.origin || 'Agent'}
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
              <button type="button" onClick={() => onDismiss(proposal.requestId)} style={{ ...primaryButtonStyle, marginTop: 16 }}>
                Close
              </button>
            </>
          ) : (
            <div style={actionsStyle}>
              <button type="button" onClick={decline} disabled={!reviewing} style={buttonState(secondaryButtonStyle, reviewing)}>
                Decline
              </button>
              <button type="button" onClick={approve} disabled={!reviewing} style={buttonState(primaryButtonStyle, reviewing)}>
                {phase === 'applying' ? 'Applying…' : 'Approve'}
              </button>
            </div>
          )}
        </section>
      </div>
    </div>
  );
};

const SessionPips: React.FC<{ count: number }> = ({ count }) => (
  <span aria-hidden style={pipRowStyle}>
    {Array.from({ length: Math.min(count, MAX_PIPS) }).map((_, index) => <span key={index} style={pipStyle} />)}
    {count > MAX_PIPS && <span>+{count - MAX_PIPS}</span>}
  </span>
);

const buttonState = (style: React.CSSProperties, enabled: boolean): React.CSSProperties =>
  enabled ? style : { ...style, opacity: 0.4, cursor: 'default' };

const backdropStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 5000, background: 'rgba(0,0,0,.7)', backdropFilter: 'blur(16px)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 22, borderRadius: theme.radii.window };
const stackStyle: React.CSSProperties = { position: 'relative', width: '100%', maxHeight: 'calc(100% - 12px)', display: 'flex' };
const peekStyle = (deep: boolean): React.CSSProperties => ({
  position: 'absolute', left: 12, right: 12, bottom: -8, height: 40, borderRadius: 20,
  background: '#202020', border: '1px solid rgba(255,255,255,.08)',
  boxShadow: deep ? '0 8px 0 -4px #161616' : 'none',
});
const cardStyle: React.CSSProperties = { position: 'relative', width: '100%', maxHeight: '100%', overflowY: 'auto', boxSizing: 'border-box', padding: '22px 20px 18px', borderRadius: 22, background: '#1A1A1A', border: '1px solid rgba(255,255,255,.09)', boxShadow: '0 30px 80px rgba(0,0,0,.7)', color: theme.colors.text.primary, fontFamily: theme.fonts.display };
const timeTrackStyle: React.CSSProperties = { position: 'absolute', top: 10, left: 20, right: 20, height: 2, overflow: 'hidden', borderRadius: 2, background: 'rgba(255,255,255,.06)' };
const timeFillStyle: React.CSSProperties = { height: '100%', background: theme.colors.focus.primary, transformOrigin: 'left', transition: 'transform 1s linear' };
const originStyle: React.CSSProperties = { color: theme.colors.text.muted, fontSize: 11, marginBottom: 6 };
const titleStyle: React.CSSProperties = { fontFamily: theme.fonts.brand, fontSize: 21, fontWeight: 600, lineHeight: 1.15, letterSpacing: '-.02em', margin: 0 };
const subjectStyle: React.CSSProperties = { margin: '6px 0 0', color: 'rgba(255,255,255,.78)', fontSize: 14, lineHeight: 1.35, overflowWrap: 'anywhere' };
const metaStyle: React.CSSProperties = { margin: '8px 0 0', color: theme.colors.text.secondary, fontSize: 12, fontVariantNumeric: 'tabular-nums', whiteSpace: 'pre-wrap' };
const reasonStyle: React.CSSProperties = { margin: '10px 0 0', color: 'rgba(255,255,255,.62)', fontSize: 12, lineHeight: 1.45, fontStyle: 'italic', overflowWrap: 'anywhere' };
const itemListStyle: React.CSSProperties = { listStyle: 'none', margin: '14px 0 0', padding: 0, display: 'flex', flexDirection: 'column', borderTop: '1px solid rgba(255,255,255,.06)' };
const itemRowStyle: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12, padding: '9px 0', borderBottom: '1px solid rgba(255,255,255,.06)', fontSize: 12 };
const itemTitleStyle: React.CSSProperties = { color: 'rgba(255,255,255,.86)', overflowWrap: 'anywhere' };
const itemMetaStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 8, color: theme.colors.text.secondary, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' };
const pipRowStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 4, fontSize: 10 };
const pipStyle: React.CSSProperties = { width: 5, height: 5, borderRadius: '50%', background: 'white' };
const notesStyle: React.CSSProperties = { listStyle: 'none', margin: '14px 0 0', padding: 0, display: 'flex', flexDirection: 'column', gap: 4, color: theme.colors.text.secondary, fontSize: 12, lineHeight: 1.4 };
const errorStyle: React.CSSProperties = { margin: '16px 0 0', color: '#FF6961', fontSize: 12, lineHeight: 1.45 };
const actionsStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginTop: 20 };
const primaryButtonStyle: React.CSSProperties = { width: '100%', height: 40, marginTop: 0, border: 0, borderRadius: 12, background: 'white', color: '#0A0A0A', fontSize: 13, fontWeight: 600, cursor: 'pointer' };
const secondaryButtonStyle: React.CSSProperties = { ...primaryButtonStyle, background: 'rgba(255,255,255,.07)', color: 'rgba(255,255,255,.8)' };
const visuallyHidden: React.CSSProperties = { position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' };

export default AgentProposalOverlay;
