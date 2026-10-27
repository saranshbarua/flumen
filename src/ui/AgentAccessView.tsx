import React, { useEffect, useState } from 'react';
import { AgentAccessSettings, NativeBridge } from '../services/nativeBridge';
import { AGENT_ACCESS_CONSENT_VERSION, shouldShowAgentEnableConsent } from './agentAccessConsent';
import { agentDisplayName } from './agentClientName';
import { theme } from './theme';

export type AgentAccessStatus = 'off' | 'starting' | 'ready' | 'connected' | 'error';

export interface AgentConnection {
  id?: string;
  name?: string;
  connectedAt?: number;
  active?: boolean;
}

const initialSettings: AgentAccessSettings = {
  enabled: false,
  readFocusData: true,
  allowProposals: true,
  privacyAcknowledged: false,
  consentVersion: 0,
  skipConsentPrompt: false,
};

const statusColor: Record<AgentAccessStatus, string> = {
  off: theme.colors.text.muted,
  starting: '#FF9F0A',
  ready: theme.colors.shortBreak.primary,
  connected: theme.colors.shortBreak.primary,
  error: theme.colors.focus.primary,
};

type UnknownRecord = Record<string, unknown>;

const isRecord = (value: unknown): value is UnknownRecord =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const SETTINGS_BOOLEAN_KEYS = ['enabled', 'readFocusData', 'allowProposals', 'privacyAcknowledged', 'skipConsentPrompt'] as const;

export const normalizeSettings = (detail: unknown): Partial<AgentAccessSettings> => {
  const source = isRecord(detail) && isRecord(detail.settings) ? detail.settings : detail;
  if (!isRecord(source)) return {};
  const next: Partial<AgentAccessSettings> = {};
  for (const key of SETTINGS_BOOLEAN_KEYS) {
    if (typeof source[key] === 'boolean') next[key] = source[key] as boolean;
  }
  if (typeof source.consentVersion === 'number') next.consentVersion = source.consentVersion;
  return next;
};

const normalizeConnections = (detail: unknown): AgentConnection[] => {
  const raw = isRecord(detail) ? detail.connections ?? detail.activeConnections ?? detail.clients ?? [] : [];
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((connection): connection is UnknownRecord => isRecord(connection) && connection.active !== false)
    .map((connection) => ({
      id: typeof connection.id === 'string' ? connection.id : undefined,
      name: agentDisplayName(
        typeof connection.name === 'string'
          ? connection.name
          : typeof connection.clientName === 'string' ? connection.clientName : undefined
      ),
      connectedAt: typeof connection.connectedAt === 'number' ? connection.connectedAt : undefined,
      active: true,
    }));
};

/** One label per app. Codex keeps several helper processes for a single window. */
const distinctAgentNames = (connections: AgentConnection[]): string[] => {
  const names: string[] = [];
  for (const connection of connections) {
    const name = connection.name ?? 'Agent';
    if (!names.includes(name)) names.push(name);
  }
  return names;
};

const statusTitle = (status: AgentAccessStatus, connections: AgentConnection[]) => {
  switch (status) {
    case 'off': return 'Off';
    case 'starting': return 'Starting…';
    case 'ready': return 'Ready';
    case 'error': return 'Couldn’t start';
    case 'connected': {
      const names = distinctAgentNames(connections);
      return names.length > 1
        ? `${names.length} agents connected`
        : `${names[0] ?? 'Agent'} connected`;
    }
  }
};

interface AgentAccessViewProps {
  onBack: () => void;
}

const ICON_SIZE = 14;

/** Cursor brand mark from Simple Icons (MIT). */
const CursorMarkIcon: React.FC = () => (
  <svg width={ICON_SIZE} height={ICON_SIZE} viewBox="0 0 24 24" fill="currentColor" aria-hidden style={inlineIconStyle}>
    <path d="M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23" />
  </svg>
);

const CopiedCheckIcon: React.FC = () => (
  <svg width={ICON_SIZE} height={ICON_SIZE} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden style={inlineIconStyle}>
    <polyline points="5 13 10 18 19 7" />
  </svg>
);

const AgentAccessView: React.FC<AgentAccessViewProps> = ({ onBack }) => {
  const [settings, setSettings] = useState(initialSettings);
  const [status, setStatus] = useState<AgentAccessStatus>('off');
  const [connections, setConnections] = useState<AgentConnection[]>([]);
  const [consentStep, setConsentStep] = useState<0 | 1 | 2>(0);
  const [privacyAcknowledged, setPrivacyAcknowledged] = useState(false);
  const [dontShowAgain, setDontShowAgain] = useState(false);
  const [confirmDisable, setConfirmDisable] = useState(false);
  const [copied, setCopied] = useState(false);
  const [statusError, setStatusError] = useState('');

  useEffect(() => {
    const handleSettings = (event: Event) => {
      const next = normalizeSettings((event as CustomEvent).detail);
      setSettings((current) => ({ ...current, ...next }));
      // Readiness comes only from native connection status, which knows whether the socket is listening.
      if (next.enabled === false) setStatus('off');
    };
    const handleStatus = (event: Event) => {
      const detail = (event as CustomEvent).detail;
      const payload: UnknownRecord = isRecord(detail) ? detail : {};
      const nextConnections = normalizeConnections(payload);
      setConnections(nextConnections);
      setStatusError(typeof payload.error === 'string' ? payload.error : '');
      const rawStatus = String(payload.status ?? '').toLowerCase();
      if (rawStatus === 'error' || payload.error) setStatus('error');
      else if (rawStatus === 'starting') setStatus('starting');
      else if (nextConnections.length > 0 || rawStatus === 'connected') setStatus('connected');
      else if (payload.enabled === false || rawStatus === 'off') setStatus('off');
      else setStatus('ready');
    };
    window.addEventListener('native:agentAccessSettings', handleSettings);
    window.addEventListener('native:agentConnectionStatus', handleStatus);
    NativeBridge.getAgentAccessSettings();
    NativeBridge.getAgentConnectionStatus();

    return () => {
      window.removeEventListener('native:agentAccessSettings', handleSettings);
      window.removeEventListener('native:agentConnectionStatus', handleStatus);
    };
  }, []);

  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 1600);
    return () => window.clearTimeout(timer);
  }, [copied]);

  const persistSettings = (patch: Partial<AgentAccessSettings>) => {
    setSettings((current) => ({ ...current, ...patch }));
    NativeBridge.setAgentAccessSettings(patch);
  };

  const turnOn = () => {
    if (shouldShowAgentEnableConsent(settings)) {
      setPrivacyAcknowledged(false);
      setDontShowAgain(false);
      setConsentStep(1);
      return;
    }
    setStatus('starting');
    persistSettings({ enabled: true, readFocusData: true });
  };

  const turnOff = () => {
    if (connections.length > 0 && !confirmDisable) {
      setConfirmDisable(true);
      return;
    }
    setConfirmDisable(false);
    setStatus('off');
    setConnections([]);
    persistSettings({ enabled: false });
  };

  const completeConsent = () => {
    if (!privacyAcknowledged) return;
    setConsentStep(0);
    setStatus('starting');
    persistSettings({
      enabled: true,
      readFocusData: true,
      allowProposals: true,
      privacyAcknowledged: true,
      consentVersion: AGENT_ACCESS_CONSENT_VERSION,
      skipConsentPrompt: dontShowAgain,
    });
  };

  const dismissConsent = () => {
    setConsentStep(0);
    setPrivacyAcknowledged(false);
    setDontShowAgain(false);
  };

  const connected = status === 'connected';
  const enabledAndHealthy = settings.enabled && status !== 'error';
  const title = statusTitle(status, connections);
  const agentNames = distinctAgentNames(connections);
  const otherNames = agentNames.length > 1 ? agentNames.join(', ') : '';

  return (
    <div className="agent-access-panel" style={panelStyle}>
      <style>{panelMotion}</style>

      <header style={headerStyle}>
        <button className="agent-control" onClick={onBack} aria-label="Back to Settings" style={backButtonStyle}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <polyline points="15 18 9 12 15 6" />
          </svg>
        </button>
        <h3 style={headerTitleStyle}>Agent Access</h3>
        <div style={{ width: 32 }} aria-hidden />
      </header>

      <div style={scrollStyle}>
          <section aria-label={`Agent Access: ${title}`} style={heroStyle}>
            <div style={heroRowStyle}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, minWidth: 0 }}>
                <span aria-hidden style={{ ...dotStyle, background: statusColor[status], boxShadow: connected ? `0 0 0 4px ${theme.colors.shortBreak.glow}` : 'none' }} />
                <span aria-live="polite" style={heroTitleStyle}>{title}</span>
              </div>
              <button
                className="agent-control"
                type="button"
                role="switch"
                aria-label="Agent Access"
                aria-checked={settings.enabled}
                disabled={status === 'starting'}
                onClick={settings.enabled ? turnOff : turnOn}
                style={toggleStyle(settings.enabled)}
              >
                <span style={toggleKnobStyle(settings.enabled)} />
              </button>
            </div>

            {status === 'off' && (
              <p style={heroHelperStyle}>Let agents on this Mac read your focus data and propose changes you approve.</p>
            )}
            {status === 'error' && statusError && <p style={{ ...heroHelperStyle, color: theme.colors.focus.primary }}>{statusError}</p>}
            {otherNames && <p style={heroHelperStyle}>{otherNames}</p>}

            {status === 'error' && (
              <button
                className="agent-control"
                onClick={() => { setStatus('starting'); NativeBridge.retryAgentAccess(); }}
                style={{ ...primaryButtonStyle, marginTop: 14 }}
              >
                Try again
              </button>
            )}

            {connected && !confirmDisable && (
              <button className="agent-control" onClick={() => NativeBridge.disconnectAgentSessions()} style={textButtonStyle}>
                Disconnect
              </button>
            )}

            {confirmDisable && (
              <div role="alertdialog" aria-label="Turn off Agent Access?" style={confirmStyle}>
                <span style={heroHelperStyle}>
                  {agentNames.length > 1 ? 'Connected agents' : agentNames[0] ?? 'The agent'} will be disconnected.
                </span>
                <div style={confirmActionsStyle}>
                  <button className="agent-control" onClick={() => setConfirmDisable(false)} style={smallSecondaryStyle}>Cancel</button>
                  <button className="agent-control" onClick={turnOff} style={smallDangerStyle}>Turn off</button>
                </div>
              </div>
            )}
          </section>

        {enabledAndHealthy && (
          <section style={sectionStyle} aria-label="Connect an agent">
            <button
              className="agent-control"
              onClick={() => { NativeBridge.copyAgentConfiguration(); setCopied(true); }}
              style={connected ? secondaryButtonStyle : primaryButtonStyle}
            >
              <span className="agent-copy-label" style={{ ...copyLabelStyle, opacity: copied ? 0 : 1, transform: copied ? 'translateY(-6px)' : 'none' }}>Copy configuration</span>
              <span className="agent-copied-label" aria-hidden style={{ ...copiedLabelStyle, opacity: copied ? 1 : 0, transform: copied ? 'none' : 'translateY(6px)' }}>
                <CopiedCheckIcon />
                Copied
              </span>
            </button>
            <div style={twoColumnStyle}>
              <button className="agent-control" onClick={() => NativeBridge.addToCursor()} style={secondaryButtonStyle}>
                <CursorMarkIcon />
                Install in Cursor
              </button>
              <button className="agent-control" onClick={() => NativeBridge.openAgentSetupGuide()} style={secondaryButtonStyle}>
                Setup guide
              </button>
            </div>
            <p style={helperStyle}>Paste into your agent’s MCP settings. Flumen must stay open.</p>
          </section>
        )}

        {enabledAndHealthy && (
          <section style={rowSectionStyle}>
            <div style={{ minWidth: 0 }}>
              <div style={rowTitleStyle}>Ask before applying</div>
            </div>
            <button
              className="agent-control"
              role="switch"
              aria-label="Ask before applying"
              aria-checked={settings.allowProposals}
              onClick={() => persistSettings({ allowProposals: !settings.allowProposals })}
              style={toggleStyle(settings.allowProposals)}
            >
              <span style={toggleKnobStyle(settings.allowProposals)} />
            </button>
          </section>
        )}

      </div>

      {consentStep > 0 && (
        <div className="agent-consent" role="dialog" aria-modal="true" aria-labelledby="agent-consent-title" style={consentBackdropStyle}>
            <div style={consentCardStyle}>
              <div aria-label={`Step ${consentStep} of 2`} style={stepDotsStyle}>
                <span style={stepDotStyle(consentStep >= 1)} />
                <span style={stepDotStyle(consentStep >= 2)} />
              </div>
              {consentStep === 1 ? (
                <>
                  <h3 id="agent-consent-title" style={consentTitleStyle}>Let agents work with Flumen</h3>
                  <ul style={consentListStyle}>
                    <li>Read your tasks, sessions, and reports</li>
                    <li>Propose changes you approve</li>
                    <li>Stays on this Mac. No account.</li>
                  </ul>
                  <div style={consentActionsStyle}>
                    <button className="agent-control" onClick={dismissConsent} style={secondaryButtonStyle}>Not now</button>
                    <button className="agent-control" onClick={() => setConsentStep(2)} style={primaryButtonStyle}>Continue</button>
                  </div>
                </>
              ) : (
                <>
                  <h3 id="agent-consent-title" style={consentTitleStyle}>Your agent may share what it reads</h3>
                  <p style={consentBodyStyle}>
                    Flumen keeps your data on this Mac. A connected agent may send what it reads to its model provider under that product’s privacy terms.
                  </p>
                  <label style={checkboxLabelStyle}>
                    <input
                      type="checkbox"
                      checked={privacyAcknowledged}
                      onChange={(event) => setPrivacyAcknowledged(event.target.checked)}
                    />
                    <span>I understand</span>
                  </label>
                  <label style={quietCheckboxLabelStyle}>
                    <input
                      type="checkbox"
                      checked={dontShowAgain}
                      onChange={(event) => setDontShowAgain(event.target.checked)}
                    />
                    <span>Don’t show this again</span>
                  </label>
                  <div style={consentActionsStyle}>
                    <button className="agent-control" onClick={() => setConsentStep(1)} style={secondaryButtonStyle}>Back</button>
                    <button
                      className="agent-control"
                      disabled={!privacyAcknowledged}
                      onClick={completeConsent}
                      style={{ ...primaryButtonStyle, opacity: privacyAcknowledged ? 1 : 0.35, cursor: privacyAcknowledged ? 'pointer' : 'default' }}
                    >
                      Turn on
                    </button>
                  </div>
                </>
              )}
            </div>
        </div>
      )}
    </div>
  );
};

const SPRING = 'cubic-bezier(0.32, 0.72, 0, 1)';

const panelMotion = `
  @keyframes agentPanelIn { from { transform: translateY(14px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
  @keyframes agentConsentIn { from { transform: translateY(22px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
  .agent-access-panel { animation: agentPanelIn 520ms ${SPRING} both; }
  .agent-consent > div { animation: agentConsentIn 560ms ${SPRING} both; }
  .agent-control { transition: transform 240ms ${SPRING}, background-color 240ms ${SPRING}, opacity 240ms ${SPRING}; }
  .agent-copy-label, .agent-copied-label { transition: opacity 420ms ${SPRING}, transform 420ms ${SPRING}; }
  .agent-control:not(:disabled):active { transform: scale(0.97); }
  .agent-control:focus-visible { outline: 2px solid ${theme.colors.focus.primary}; outline-offset: 2px; }
  @media (prefers-reduced-motion: reduce) {
    .agent-access-panel, .agent-consent > div { animation: none !important; }
    .agent-control { transition: none !important; }
  }
`;

const panelStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 120, background: theme.colors.background, borderRadius: theme.radii.window, padding: 24, boxSizing: 'border-box', display: 'flex', flexDirection: 'column', color: theme.colors.text.primary, fontFamily: theme.fonts.display };
const headerStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 24 };
const headerTitleStyle: React.CSSProperties = { margin: 0, fontFamily: theme.fonts.brand, fontSize: '1.2rem', fontWeight: 700, letterSpacing: '-0.02em' };
const backButtonStyle: React.CSSProperties = { width: 32, height: 32, borderRadius: 16, border: 'none', background: theme.colors.button.background, color: theme.colors.text.primary, display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', padding: 0, flexShrink: 0 };
const scrollStyle: React.CSSProperties = { overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 20, paddingBottom: 12 };

const heroStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', padding: '14px 16px', borderRadius: theme.radii.button, background: theme.colors.surface, border: `1px solid ${theme.colors.border}` };
const heroRowStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 };
const dotStyle: React.CSSProperties = { width: 8, height: 8, borderRadius: '50%', flexShrink: 0 };
const heroTitleStyle: React.CSSProperties = { fontSize: '0.95rem', fontWeight: 650, letterSpacing: '-.01em', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' };
const heroHelperStyle: React.CSSProperties = { margin: '8px 0 0', fontSize: '0.7rem', lineHeight: 1.45, color: theme.colors.text.muted };
const textButtonStyle: React.CSSProperties = { alignSelf: 'flex-start', marginTop: 8, padding: 0, border: 'none', background: 'none', color: theme.colors.text.secondary, fontFamily: theme.fonts.display, fontSize: '0.75rem', fontWeight: 600, cursor: 'pointer' };
const confirmStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 4, marginTop: 8 };
const confirmActionsStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginTop: 10 };

const sectionStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 8 };
const rowSectionStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, paddingTop: 16, borderTop: `1px solid ${theme.colors.border}` };
const rowTitleStyle: React.CSSProperties = { color: theme.colors.text.primary, fontSize: '0.85rem', fontWeight: 500 };
const helperStyle: React.CSSProperties = { margin: '2px 0 0', fontSize: '0.7rem', lineHeight: 1.45, color: theme.colors.text.muted };
const twoColumnStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 };

const primaryButtonStyle: React.CSSProperties = { position: 'relative', minHeight: 40, borderRadius: theme.radii.button, border: 'none', background: theme.colors.text.primary, color: theme.colors.background, fontFamily: theme.fonts.display, fontWeight: 650, fontSize: '0.8rem', cursor: 'pointer', padding: '0 16px', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 7, whiteSpace: 'nowrap', overflow: 'hidden' };
const copyLabelStyle: React.CSSProperties = { display: 'inline-flex', alignItems: 'center' };
const copiedLabelStyle: React.CSSProperties = { position: 'absolute', inset: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 7, pointerEvents: 'none' };
const inlineIconStyle: React.CSSProperties = { width: ICON_SIZE, height: ICON_SIZE, flex: '0 0 auto', display: 'block' };
const secondaryButtonStyle: React.CSSProperties = { ...primaryButtonStyle, color: theme.colors.text.primary, background: theme.colors.button.background, border: `1px solid ${theme.colors.border}` };
const smallSecondaryStyle: React.CSSProperties = { ...secondaryButtonStyle, minHeight: 34, fontSize: '0.75rem' };
const smallDangerStyle: React.CSSProperties = { ...smallSecondaryStyle, background: 'rgba(255,95,87,.1)', color: theme.colors.focus.primary, border: '1px solid rgba(255,95,87,.28)' };

const toggleStyle = (enabled: boolean): React.CSSProperties => ({ position: 'relative', width: 44, height: 24, border: 0, borderRadius: 12, background: enabled ? theme.colors.focus.primary : 'rgba(255,255,255,.1)', padding: 0, cursor: 'pointer', flexShrink: 0, transition: 'background-color 0.3s cubic-bezier(0.4, 0, 0.2, 1)' });
const toggleKnobStyle = (enabled: boolean): React.CSSProperties => ({ position: 'absolute', top: 3, left: enabled ? 23 : 3, width: 18, height: 18, borderRadius: '50%', background: 'white', transition: 'left 0.3s cubic-bezier(0.4, 0, 0.2, 1)', boxShadow: '0 2px 4px rgba(0,0,0,.2)' });

const consentBackdropStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 10, background: 'rgba(0,0,0,.72)', backdropFilter: 'blur(16px)', display: 'flex', alignItems: 'flex-end', padding: 16, borderRadius: theme.radii.window };
const consentCardStyle: React.CSSProperties = { width: '100%', padding: '20px 18px 16px', boxSizing: 'border-box', borderRadius: theme.radii.button, background: theme.colors.surface, border: `1px solid ${theme.colors.border}`, display: 'flex', flexDirection: 'column', gap: 14 };
const stepDotsStyle: React.CSSProperties = { display: 'flex', gap: 5 };
const stepDotStyle = (active: boolean): React.CSSProperties => ({ width: active ? 16 : 5, height: 5, borderRadius: 3, background: active ? theme.colors.text.primary : theme.colors.button.background, transition: `width 360ms ${SPRING}` });
const consentTitleStyle: React.CSSProperties = { margin: 0, fontFamily: theme.fonts.brand, fontSize: '1.15rem', fontWeight: 700, lineHeight: 1.2, letterSpacing: '-.02em' };
const consentBodyStyle: React.CSSProperties = { margin: 0, color: theme.colors.text.secondary, fontSize: '0.75rem', lineHeight: 1.5 };
const consentListStyle: React.CSSProperties = { margin: 0, padding: 0, listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 8, color: theme.colors.text.primary, fontSize: '0.82rem', lineHeight: 1.4 };
const consentActionsStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 8 };
const checkboxLabelStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 10, color: theme.colors.text.primary, fontSize: '0.8rem', cursor: 'pointer' };
const quietCheckboxLabelStyle: React.CSSProperties = { ...checkboxLabelStyle, color: theme.colors.text.muted, fontSize: '0.75rem' };

export default AgentAccessView;
