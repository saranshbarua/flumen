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
  off: 'rgba(255,255,255,.22)',
  starting: '#FF9F0A',
  ready: '#30D158',
  connected: '#30D158',
  error: '#FF453A',
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

const statusTitle = (status: AgentAccessStatus, connections: AgentConnection[]) => {
  switch (status) {
    case 'off': return 'Off';
    case 'starting': return 'Starting…';
    case 'ready': return 'Ready';
    case 'error': return 'Couldn’t start';
    case 'connected':
      return connections.length > 1
        ? `${connections.length} agents connected`
        : `${connections[0]?.name ?? 'Agent'} connected`;
  }
};

interface AgentAccessViewProps {
  onBack: () => void;
}

/** Cursor brand mark from Simple Icons (MIT). */
const CursorMarkIcon: React.FC = () => (
  <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
    <path d="M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23" />
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
  const [manualOpen, setManualOpen] = useState(false);
  const [details, setDetails] = useState<Record<string, unknown>>({});
  const [feedback, setFeedback] = useState('');
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
    const handleDetails = (event: Event) => {
      const payload = (event as CustomEvent).detail;
      setDetails(isRecord(payload) ? payload : {});
    };
    const handleAction = (event: Event) => {
      const detail = (event as CustomEvent).detail;
      const payload: UnknownRecord = isRecord(detail) ? detail : {};
      setFeedback(typeof payload.message === 'string'
        ? payload.message
        : payload.success === false ? 'That didn’t work. Try again.' : 'Done.');
    };

    window.addEventListener('native:agentAccessSettings', handleSettings);
    window.addEventListener('native:agentConnectionStatus', handleStatus);
    window.addEventListener('native:agentConnectionDetails', handleDetails);
    window.addEventListener('native:agentAccessActionResult', handleAction);
    NativeBridge.getAgentAccessSettings();
    NativeBridge.getAgentConnectionStatus();

    return () => {
      window.removeEventListener('native:agentAccessSettings', handleSettings);
      window.removeEventListener('native:agentConnectionStatus', handleStatus);
      window.removeEventListener('native:agentConnectionDetails', handleDetails);
      window.removeEventListener('native:agentAccessActionResult', handleAction);
    };
  }, []);

  useEffect(() => {
    if (!feedback) return;
    const timer = window.setTimeout(() => setFeedback(''), 2500);
    return () => window.clearTimeout(timer);
  }, [feedback]);

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

  const copyAction = (action: () => void, message: string) => {
    action();
    setFeedback(message);
  };

  const toggleManual = () => {
    const next = !manualOpen;
    setManualOpen(next);
    if (next) NativeBridge.getAgentConnectionDetails();
  };

  const connected = status === 'connected';
  const enabledAndHealthy = settings.enabled && status !== 'error';
  const title = statusTitle(status, connections);
  const helperPath = typeof details.helperPath === 'string' ? details.helperPath : '';
  const otherNames = connections.length > 1 ? connections.map((connection) => connection.name).join(', ') : '';

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
        <div style={shellStyle}>
          <section aria-label={`Agent Access: ${title}`} style={heroStyle}>
            <div style={heroRowStyle}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, minWidth: 0 }}>
                <span aria-hidden style={{ ...dotStyle, background: statusColor[status], boxShadow: connected ? `0 0 0 4px rgba(48,209,88,.14)` : 'none' }} />
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
            {status === 'error' && statusError && <p style={{ ...heroHelperStyle, color: '#FF8A80' }}>{statusError}</p>}
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
                  {connections.length > 1 ? 'Connected agents' : connections[0]?.name ?? 'The agent'} will be disconnected.
                </span>
                <div style={confirmActionsStyle}>
                  <button className="agent-control" onClick={() => setConfirmDisable(false)} style={smallSecondaryStyle}>Cancel</button>
                  <button className="agent-control" onClick={turnOff} style={smallDangerStyle}>Turn off</button>
                </div>
              </div>
            )}
          </section>
        </div>

        {enabledAndHealthy && (
          <section style={sectionStyle} aria-label="Connect an agent">
            <button
              className="agent-control"
              onClick={() => copyAction(() => NativeBridge.copyAgentConfiguration(), 'Configuration copied')}
              style={connected ? secondaryButtonStyle : primaryButtonStyle}
            >
              Copy configuration
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
            <p style={helperStyle}>
              {feedback || 'Paste into your agent’s MCP settings. Flumen must stay open.'}
            </p>
          </section>
        )}

        {enabledAndHealthy && (
          <section style={rowSectionStyle}>
            <div style={{ minWidth: 0 }}>
              <div style={rowTitleStyle}>Proposals</div>
              <div style={helperStyle}>Agents can always read tasks and sessions. Changes need your approval.</div>
            </div>
            <button
              className="agent-control"
              role="switch"
              aria-label="Allow proposals"
              aria-checked={settings.allowProposals}
              onClick={() => persistSettings({ allowProposals: !settings.allowProposals })}
              style={toggleStyle(settings.allowProposals)}
            >
              <span style={toggleKnobStyle(settings.allowProposals)} />
            </button>
          </section>
        )}

        {settings.enabled && (
          <section style={manualSectionStyle}>
            <button className="agent-control" aria-expanded={manualOpen} onClick={toggleManual} style={disclosureStyle}>
              <span>Manual setup</span>
              <span aria-hidden style={{ ...chevronStyle, transform: manualOpen ? 'rotate(90deg)' : 'none' }}>›</span>
            </button>
            {manualOpen && (
              <div style={pathRowStyle}>
                <code style={pathStyle}>{helperPath || '…'}</code>
                <button
                  className="agent-control"
                  onClick={() => copyAction(() => NativeBridge.copyAgentServerCommand(), 'Helper path copied')}
                  style={copyChipStyle}
                >
                  Copy
                </button>
              </div>
            )}
          </section>
        )}
      </div>

      {consentStep > 0 && (
        <div className="agent-consent" role="dialog" aria-modal="true" aria-labelledby="agent-consent-title" style={consentBackdropStyle}>
          <div style={consentShellStyle}>
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
  .agent-control:not(:disabled):active { transform: scale(0.97); }
  .agent-control:focus-visible { outline: 2px solid ${theme.colors.focus.primary}; outline-offset: 2px; }
  @media (prefers-reduced-motion: reduce) {
    .agent-access-panel, .agent-consent > div { animation: none !important; }
    .agent-control { transition: none !important; }
  }
`;

const panelStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 120, background: theme.colors.background, borderRadius: theme.radii.window, padding: '24px 20px', boxSizing: 'border-box', display: 'flex', flexDirection: 'column', color: 'white', fontFamily: theme.fonts.brand };
const headerStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 };
const headerTitleStyle: React.CSSProperties = { margin: 0, fontFamily: theme.fonts.brand, fontSize: '1.1rem', fontWeight: 600, letterSpacing: '-0.02em' };
const backButtonStyle: React.CSSProperties = { width: 32, height: 32, borderRadius: 16, border: 'none', background: 'rgba(255,255,255,.05)', color: 'white', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', padding: 0, flexShrink: 0 };
const scrollStyle: React.CSSProperties = { overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 22, paddingBottom: 12 };

// Two-layer bezel: a translucent shell holding a solid core with concentric corners.
const shellStyle: React.CSSProperties = { padding: 4, borderRadius: 22, background: 'rgba(255,255,255,.04)', boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.06)' };
const heroStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', padding: '16px 16px', borderRadius: 18, background: '#151515', boxShadow: 'inset 0 1px 1px rgba(255,255,255,.07)' };
const heroRowStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 };
const dotStyle: React.CSSProperties = { width: 8, height: 8, borderRadius: '50%', flexShrink: 0, transition: `box-shadow 400ms ${SPRING}` };
const heroTitleStyle: React.CSSProperties = { fontSize: 17, fontWeight: 600, letterSpacing: '-.02em', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' };
const heroHelperStyle: React.CSSProperties = { margin: '8px 0 0', fontSize: 12, lineHeight: 1.45, color: 'rgba(255,255,255,.5)' };
const textButtonStyle: React.CSSProperties = { alignSelf: 'flex-start', marginTop: 10, padding: 0, border: 'none', background: 'none', color: 'rgba(255,255,255,.5)', fontFamily: theme.fonts.brand, fontSize: 12, fontWeight: 500, cursor: 'pointer' };
const confirmStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 4, marginTop: 6 };
const confirmActionsStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginTop: 10 };

const sectionStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 8 };
const rowSectionStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 14 };
const manualSectionStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 10, paddingTop: 16, borderTop: '1px solid rgba(255,255,255,.05)' };
const rowTitleStyle: React.CSSProperties = { color: 'white', fontSize: 14, fontWeight: 500 };
const helperStyle: React.CSSProperties = { margin: '3px 0 0', fontSize: 11.5, lineHeight: 1.45, color: 'rgba(255,255,255,.45)' };
const twoColumnStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 };

const primaryButtonStyle: React.CSSProperties = { minHeight: 42, borderRadius: 999, border: 'none', background: '#F5F5F3', color: '#0A0A0A', fontFamily: theme.fonts.brand, fontWeight: 600, fontSize: 13, cursor: 'pointer', padding: '0 16px', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 7, whiteSpace: 'nowrap' };
const secondaryButtonStyle: React.CSSProperties = { ...primaryButtonStyle, color: 'rgba(255,255,255,.82)', background: 'rgba(255,255,255,.06)', boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.06)' };
const smallSecondaryStyle: React.CSSProperties = { ...secondaryButtonStyle, minHeight: 34, fontSize: 12 };
const smallDangerStyle: React.CSSProperties = { ...smallSecondaryStyle, background: 'rgba(255,69,58,.14)', color: '#FF6961', boxShadow: 'none' };

const disclosureStyle: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'center', width: '100%', border: 'none', background: 'transparent', color: 'rgba(255,255,255,.6)', padding: 0, fontFamily: theme.fonts.brand, fontSize: 13, fontWeight: 500, cursor: 'pointer' };
const chevronStyle: React.CSSProperties = { display: 'inline-block', fontSize: 18, lineHeight: 1, transition: `transform 320ms ${SPRING}` };
const pathRowStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 10, padding: '10px 10px 10px 12px', borderRadius: 14, background: 'rgba(255,255,255,.03)', boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.05)' };
const pathStyle: React.CSSProperties = { flex: 1, minWidth: 0, fontFamily: theme.fonts.mono, fontSize: 10, lineHeight: 1.5, color: 'rgba(255,255,255,.6)', overflowWrap: 'anywhere' };
const copyChipStyle: React.CSSProperties = { ...secondaryButtonStyle, minHeight: 28, padding: '0 12px', fontSize: 11, flexShrink: 0 };

const toggleStyle = (enabled: boolean): React.CSSProperties => ({ position: 'relative', width: 42, height: 24, border: 0, borderRadius: 12, background: enabled ? theme.colors.focus.primary : 'rgba(255,255,255,.12)', padding: 0, cursor: 'pointer', flexShrink: 0, transition: `background-color 300ms ${SPRING}` });
const toggleKnobStyle = (enabled: boolean): React.CSSProperties => ({ position: 'absolute', top: 3, left: 3, width: 18, height: 18, borderRadius: '50%', background: 'white', transform: `translateX(${enabled ? 18 : 0}px)`, transition: `transform 320ms ${SPRING}`, boxShadow: '0 1px 3px rgba(0,0,0,.25)' });

const consentBackdropStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 10, background: 'linear-gradient(180deg, rgba(0,0,0,.4) 0%, rgba(0,0,0,.82) 55%)', backdropFilter: 'blur(14px)', display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', padding: 8, borderRadius: theme.radii.window };
const consentShellStyle: React.CSSProperties = { padding: 5, borderRadius: 20, background: 'rgba(255,255,255,.045)', boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.07), 0 40px 90px -20px rgba(0,0,0,.65)' };
const consentCardStyle: React.CSSProperties = { padding: '20px 18px 18px', boxSizing: 'border-box', borderRadius: 15, background: '#161616', boxShadow: 'inset 0 1px 1px rgba(255,255,255,.08)', display: 'flex', flexDirection: 'column', gap: 14 };
const stepDotsStyle: React.CSSProperties = { display: 'flex', gap: 5 };
const stepDotStyle = (active: boolean): React.CSSProperties => ({ width: active ? 16 : 5, height: 5, borderRadius: 3, background: active ? 'white' : 'rgba(255,255,255,.2)', transition: `width 360ms ${SPRING}` });
const consentTitleStyle: React.CSSProperties = { margin: 0, fontFamily: theme.fonts.brand, fontSize: 21, fontWeight: 600, lineHeight: 1.15, letterSpacing: '-.025em' };
const consentBodyStyle: React.CSSProperties = { margin: 0, color: 'rgba(255,255,255,.6)', fontSize: 12.5, lineHeight: 1.5 };
const consentListStyle: React.CSSProperties = { margin: 0, padding: 0, listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 8, color: 'rgba(255,255,255,.75)', fontSize: 13.5, lineHeight: 1.4 };
const consentActionsStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 8, marginTop: 6 };
const checkboxLabelStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 10, color: 'rgba(255,255,255,.85)', fontSize: 13, cursor: 'pointer' };
const quietCheckboxLabelStyle: React.CSSProperties = { ...checkboxLabelStyle, color: 'rgba(255,255,255,.5)', fontSize: 12 };

export default AgentAccessView;
