import React, { useEffect, useMemo, useState } from 'react';
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

const formatDuration = (seconds?: number) => {
  if (!seconds || seconds < 1) return null;
  const minutes = Math.round(seconds / 60);
  return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
};

const formatTime = (value?: number) =>
  value ? new Date(value).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) : null;

const formatDay = (value?: number) => {
  if (!value) return null;
  const date = new Date(value);
  const today = new Date();
  if (date.toDateString() === today.toDateString()) return null;
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

  const sideEffects = useMemo(() => {
    if (Array.isArray(proposal.sideEffects)) return proposal.sideEffects;
    return proposal.sideEffects ? [proposal.sideEffects] : [];
  }, [proposal.sideEffects]);

  const approve = () => {
    NativeBridge.agentProposalResult(proposal.requestId, true);
    onApproving(proposal.requestId);
  };

  const decline = () => {
    NativeBridge.agentProposalResult(proposal.requestId, false, 'user_declined');
    onDismiss(proposal.requestId);
  };

  if (expired) return null;

  const duration = formatDuration(proposal.durationSeconds);
  const start = formatTime(proposal.startedAt);
  const end = formatTime(proposal.endedAt);
  const day = formatDay(proposal.startedAt);
  const interval = start && end ? `${day ? `${day}, ` : ''}${start}–${end}` : null;
  const time = [interval, duration].filter(Boolean).join(' · ') || null;
  const project = typeof proposal.project === 'string' ? proposal.project : proposal.project?.name;
  const actionLabel = proposal.actionTitle || proposal.action;

  return (
    <div role="presentation" style={backdropStyle}>
      <section role="dialog" aria-modal="true" aria-labelledby="proposal-title" aria-busy={phase === 'applying'} style={cardStyle}>
        <div style={eyebrowRowStyle}>
          <span style={eyebrowStyle}>AGENT PROPOSAL</span>
          {queuedCount > 0 && <span style={queueStyle}>{queuedCount} more waiting</span>}
        </div>
        <h2 id="proposal-title" style={titleStyle}>{proposal.title || actionLabel}</h2>
        {proposal.summary && <p style={summaryStyle}>{proposal.summary}</p>}
        <p style={introStyle}>Review the exact change. Nothing is written until you approve.</p>

        <dl style={detailListStyle}>
          <Detail label="Action" value={actionLabel} />
          <Detail label="Task" value={proposal.task?.title} />
          <Detail label="Project" value={project} />
          <Detail label="Time" value={time} />
          <Detail label="Reason" value={proposal.reason} />
          <Detail
            label="Source"
            value={[
              proposal.provenance?.origin,
              proposal.provenance?.durationSource,
            ].filter(Boolean).join(' · ') || 'Agent proposal'}
          />
        </dl>

        {sideEffects.length > 0 && (
          <div style={effectsStyle}>
            <span style={effectLabelStyle}>WHAT WILL CHANGE</span>
            {sideEffects.map((effect, index) => <span key={`${effect}-${index}`}>• {effect}</span>)}
          </div>
        )}

        {phase === 'failed' ? (
          <>
            <div role="alert" style={errorStyle}>
              <strong style={{ color: '#FF6961' }}>Not applied.</strong> {error}
            </div>
            <button type="button" onClick={() => onDismiss(proposal.requestId)} style={approveButtonStyle}>Close</button>
          </>
        ) : (
          <>
            {reviewing && expiresAt && (
              <div role="status" style={expiryStyle}>
                Expires in {Math.max(1, Math.ceil((expiresAt - now) / 1000))} seconds
              </div>
            )}
            {phase === 'applying' && (
              <div role="status" aria-live="polite" style={expiryStyle}>Applying in Flumen…</div>
            )}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 9 }}>
              <button type="button" onClick={decline} disabled={!reviewing} style={buttonState(declineButtonStyle, reviewing)}>Decline</button>
              <button type="button" onClick={approve} disabled={!reviewing} style={buttonState(approveButtonStyle, reviewing)}>
                {phase === 'applying' ? 'Applying…' : 'Approve'}
              </button>
            </div>
          </>
        )}
      </section>
    </div>
  );
};

const Detail: React.FC<{ label: string; value?: string | null }> = ({ label, value }) =>
  value ? (
    <div style={detailRowStyle}>
      <dt style={termStyle}>{label}</dt>
      <dd style={valueStyle}>{value}</dd>
    </div>
  ) : null;

const buttonState = (style: React.CSSProperties, enabled: boolean): React.CSSProperties =>
  enabled ? style : { ...style, opacity: 0.45, cursor: 'default' };

const backdropStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 5000, background: 'rgba(0,0,0,.72)', backdropFilter: 'blur(16px)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 22, borderRadius: theme.radii.window };
const cardStyle: React.CSSProperties = { width: '100%', maxHeight: 'calc(100% - 12px)', overflowY: 'auto', boxSizing: 'border-box', padding: 20, borderRadius: 22, background: 'linear-gradient(150deg, #1B1B1B, #111)', border: '1px solid rgba(255,255,255,.11)', boxShadow: '0 30px 80px rgba(0,0,0,.7)', color: 'white', fontFamily: theme.fonts.display };
const eyebrowRowStyle: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 7 };
const eyebrowStyle: React.CSSProperties = { color: theme.colors.focus.primary, fontSize: 9, fontWeight: 800, letterSpacing: '.13em' };
const queueStyle: React.CSSProperties = { color: 'rgba(255,255,255,.45)', fontSize: 9, fontWeight: 700 };
const titleStyle: React.CSSProperties = { fontFamily: theme.fonts.brand, fontSize: 19, lineHeight: 1.2, letterSpacing: '-.025em', margin: 0 };
const summaryStyle: React.CSSProperties = { color: 'rgba(255,255,255,.7)', fontSize: 11, lineHeight: 1.45, margin: '6px 0 0' };
const introStyle: React.CSSProperties = { color: 'rgba(255,255,255,.48)', fontSize: 11, lineHeight: 1.5, margin: '7px 0 15px' };
const detailListStyle: React.CSSProperties = { margin: 0, padding: 11, borderRadius: 12, background: 'rgba(255,255,255,.035)', display: 'flex', flexDirection: 'column', gap: 8 };
const detailRowStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '70px 1fr', gap: 8 };
const termStyle: React.CSSProperties = { color: 'rgba(255,255,255,.32)', fontSize: 9, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.08em' };
const valueStyle: React.CSSProperties = { margin: 0, color: 'rgba(255,255,255,.82)', fontSize: 11, overflowWrap: 'anywhere' };
const effectsStyle: React.CSSProperties = { marginTop: 11, padding: 11, borderRadius: 12, border: '1px solid rgba(255,159,10,.14)', background: 'rgba(255,159,10,.06)', display: 'flex', flexDirection: 'column', gap: 5, color: 'rgba(255,255,255,.65)', fontSize: 10 };
const effectLabelStyle: React.CSSProperties = { color: '#FFB340', fontSize: 8, fontWeight: 800, letterSpacing: '.1em' };
const expiryStyle: React.CSSProperties = { margin: '10px 0', color: 'rgba(255,255,255,.38)', fontSize: 9, textAlign: 'center' };
const errorStyle: React.CSSProperties = { margin: '11px 0', padding: 11, borderRadius: 12, border: '1px solid rgba(255,69,58,.25)', background: 'rgba(255,69,58,.08)', color: 'rgba(255,255,255,.8)', fontSize: 11, lineHeight: 1.45 };
const approveButtonStyle: React.CSSProperties = { width: '100%', height: 40, border: 0, borderRadius: 12, background: 'white', color: '#090909', fontSize: 12, fontWeight: 750, cursor: 'pointer' };
const declineButtonStyle: React.CSSProperties = { ...approveButtonStyle, background: 'rgba(255,255,255,.065)', color: 'rgba(255,255,255,.7)', border: '1px solid rgba(255,255,255,.075)' };

export default AgentProposalOverlay;
