import React, { useEffect, useState } from 'react';
import { AgentAccessSettings, NativeBridge } from '../services/nativeBridge';
import {
  AGENT_ACCESS_CONSENT_VERSION,
  connectionDetailEntries,
  shouldShowAgentEnableConsent,
} from './agentAccessConsent';
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

const statusCopy: Record<AgentAccessStatus, { title: string; detail: string; color: string }> = {
  off: {
    title: 'Agent Access is off',
    detail: 'No agent can read or propose changes.',
    color: theme.colors.text.muted,
  },
  starting: {
    title: 'Preparing Agent Access…',
    detail: 'Authorizing the local Flumen helper.',
    color: '#FF9F0A',
  },
  ready: {
    title: 'Ready for agents',
    detail: 'Available locally while Flumen is open.',
    color: '#30D158',
  },
  connected: {
    title: 'Connected locally',
    detail: 'An agent is actively connected to Flumen.',
    color: '#30D158',
  },
  error: {
    title: 'Agent Access unavailable',
    detail: 'Flumen could not prepare the local helper.',
    color: '#FF453A',
  },
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
      name: typeof connection.name === 'string'
        ? connection.name
        : typeof connection.clientName === 'string'
          ? connection.clientName
          : 'Local MCP Client',
      connectedAt: typeof connection.connectedAt === 'number' ? connection.connectedAt : undefined,
      active: true,
    }));
};

interface AgentAccessViewProps {
  onBack: () => void;
}

/** Cursor brand mark from Simple Icons (MIT), filled for dark secondary buttons. */
const CursorMarkIcon: React.FC = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
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
  const [detailsOpen, setDetailsOpen] = useState(false);
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
        : payload.success === false ? 'Action failed. Show details and try again.' : 'Done.');
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

  useEffect(() => {
    if (!feedback) return;
    const timer = window.setTimeout(() => setFeedback(''), 2500);
    return () => window.clearTimeout(timer);
  }, [feedback]);

  const copy = statusCopy[status];
  const connectedName = connections[0]?.name || 'Local MCP Client';

  return (
    <div style={panelStyle}>
      <style>{`
        .agent-control:focus-visible { outline: 2px solid ${theme.colors.focus.primary}; outline-offset: 2px; }
        @media (prefers-reduced-motion: reduce) {
          .agent-access-panel, .agent-consent { animation: none !important; transition: none !important; }
        }
      `}</style>

      <header style={headerStyle}>
        <button className="agent-control" onClick={onBack} aria-label="Back to Settings" style={backButtonStyle}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <polyline points="15 18 9 12 15 6" />
          </svg>
        </button>
        <h3 style={titleStyle}>Agent Access</h3>
        <div style={{ width: 32 }} aria-hidden />
      </header>

      <div style={scrollStyle}>
        <section aria-label={`Agent Access status: ${copy.title}`} style={statusCardStyle}>
          <div style={{ display: 'flex', gap: 12, minWidth: 0 }}>
            <span aria-hidden style={{ ...statusDotStyle, background: copy.color }} />
            <div style={{ minWidth: 0 }}>
              <div aria-live="polite" style={{ color: 'white', fontSize: 15, fontWeight: 700 }}>
                {status === 'connected' ? `${connectedName} connected` : copy.title}
              </div>
              <div style={secondaryTextStyle}>{status === 'error' && statusError ? statusError : copy.detail}</div>
            </div>
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
        </section>

        {confirmDisable && (
          <section role="alertdialog" aria-label="Turn off Agent Access?" style={warningCardStyle}>
            <strong style={{ color: 'white', fontSize: 13 }}>Turn off Agent Access?</strong>
            <span style={secondaryTextStyle}>{connectedName} will be disconnected immediately.</span>
            <div style={{ display: 'flex', gap: 8 }}>
              <button className="agent-control" onClick={turnOff} style={dangerButtonStyle}>Turn Off</button>
              <button className="agent-control" onClick={() => setConfirmDisable(false)} style={smallButtonStyle}>Cancel</button>
            </div>
          </section>
        )}

        {status === 'error' && (
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="agent-control" onClick={() => { setStatus('starting'); NativeBridge.retryAgentAccess(); }} style={primaryButtonStyle}>Try Again</button>
            <button
              className="agent-control"
              onClick={() => {
                setDetailsOpen(true);
                NativeBridge.getAgentConnectionDetails();
              }}
              style={secondaryButtonStyle}
            >
              Show Details
            </button>
          </div>
        )}

        {settings.enabled && status !== 'error' && (
          <>
            <section style={sectionStyle} aria-labelledby="connect-agent-title">
              <div>
                <div id="connect-agent-title" style={sectionLabelStyle}>CONNECT AN AGENT</div>
                <p style={{ ...secondaryTextStyle, margin: '6px 0 14px' }}>
                  Paste this into your agent’s MCP settings. Flumen stays on this Mac and must remain open.
                </p>
              </div>
              <button
                className="agent-control"
                onClick={() => copyAction(() => NativeBridge.copyAgentConfiguration(), 'MCP configuration copied.')}
                style={primaryButtonStyle}
              >
                Copy configuration
              </button>
              <div style={twoColumnStyle}>
                <button
                  className="agent-control"
                  onClick={() => NativeBridge.addToCursor()}
                  style={iconButtonStyle}
                >
                  <CursorMarkIcon />
                  Install in Cursor
                </button>
                <button className="agent-control" onClick={() => NativeBridge.openAgentSetupGuide()} style={secondaryButtonStyle}>
                  Setup Guide
                </button>
              </div>
              {feedback && <div role="status" aria-live="polite" style={feedbackStyle}>{feedback}</div>}
            </section>

            <section style={sectionStyle} aria-labelledby="permissions-title">
              <div id="permissions-title" style={sectionLabelStyle}>PERMISSIONS</div>
              <div style={permissionRowStyle}>
                <div>
                  <div style={rowTitleStyle}>Read Focus Data</div>
                  <div style={secondaryTextStyle}>Tasks, projects, sessions, and reports</div>
                </div>
                <span style={allowedPillStyle}>Required</span>
              </div>
              <div style={permissionRowStyle}>
                <div>
                  <div style={rowTitleStyle}>Allow Proposals</div>
                  <div style={secondaryTextStyle}>Agents may propose; you confirm every change</div>
                </div>
                <button
                  className="agent-control"
                  role="switch"
                  aria-label="Allow Proposals"
                  aria-checked={settings.allowProposals}
                  onClick={() => persistSettings({ allowProposals: !settings.allowProposals })}
                  style={toggleStyle(settings.allowProposals)}
                >
                  <span style={toggleKnobStyle(settings.allowProposals)} />
                </button>
              </div>
            </section>

            <section style={sectionStyle} aria-labelledby="connections-title">
              <div id="connections-title" style={sectionLabelStyle}>ACTIVE CONNECTIONS</div>
              {connections.length === 0 ? (
                <p style={{ ...secondaryTextStyle, margin: 0 }}>No agent is connected right now.</p>
              ) : (
                <>
                  {connections.map((connection, index) => (
                    <div key={connection.id ?? `${connection.name}-${index}`} style={connectionRowStyle}>
                      <span style={rowTitleStyle}>{connection.name || 'Local MCP Client'}</span>
                      <span style={allowedPillStyle}>Active now</span>
                    </div>
                  ))}
                  <button
                    className="agent-control"
                    onClick={() => NativeBridge.disconnectAgentSessions()}
                    style={secondaryButtonStyle}
                  >
                    Disconnect Sessions
                  </button>
                </>
              )}
            </section>
          </>
        )}

        {settings.enabled && (
          <section style={sectionStyle}>
            <button
              className="agent-control"
              aria-expanded={detailsOpen}
              onClick={() => {
                const next = !detailsOpen;
                setDetailsOpen(next);
                if (next) NativeBridge.getAgentConnectionDetails();
              }}
              style={disclosureButtonStyle}
            >
              <span>Advanced</span><span aria-hidden>{detailsOpen ? '⌄' : '›'}</span>
            </button>
            {detailsOpen && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                <p style={{ ...secondaryTextStyle, margin: 0 }}>For support or manual MCP setup.</p>
                <dl style={detailsListStyle}>
                  {connectionDetailEntries(details).map((entry) => (
                    <div key={entry.key}>
                      <dt style={detailTermStyle}>{entry.label}</dt>
                      <dd style={detailValueStyle}>{entry.value}</dd>
                    </div>
                  ))}
                </dl>
                <button
                  className="agent-control"
                  onClick={() => copyAction(() => NativeBridge.copyAgentServerCommand(), 'Helper command copied.')}
                  style={secondaryButtonStyle}
                >
                  Copy helper command
                </button>
                {status === 'error' && feedback && (
                  <div role="status" aria-live="polite" style={feedbackStyle}>{feedback}</div>
                )}
              </div>
            )}
          </section>
        )}
      </div>

      {consentStep > 0 && (
        <div className="agent-consent" role="dialog" aria-modal="true" aria-labelledby="agent-consent-title" style={consentBackdropStyle}>
          <div style={consentCardStyle}>
            {consentStep === 1 ? (
              <>
                <div style={eyebrowStyle}>1 OF 2</div>
                <h3 id="agent-consent-title" style={consentTitleStyle}>Connect Flumen to your agent</h3>
                <p style={consentBodyStyle}>Let supported agents read your current focus, help log forgotten work, and prepare proposals from your history.</p>
                <ul style={consentListStyle}>
                  <li>Runs locally on this Mac.</li>
                  <li>No Flumen account or cloud.</li>
                  <li>Every change requires your confirmation.</li>
                </ul>
                <div style={consentActionsStyle}>
                  <button className="agent-control" onClick={() => setConsentStep(2)} style={primaryButtonStyle}>Continue</button>
                  <button className="agent-control" onClick={dismissConsent} style={secondaryButtonStyle}>Not Now</button>
                </div>
              </>
            ) : (
              <>
                <div style={eyebrowStyle}>2 OF 2</div>
                <h3 id="agent-consent-title" style={consentTitleStyle}>Your agent may use the data it reads</h3>
                <p style={consentBodyStyle}>Flumen keeps your data on this Mac. A connected agent may send requested tasks or focus history to its model provider under that product’s privacy terms.</p>
                <label style={checkboxLabelStyle}>
                  <input
                    type="checkbox"
                    checked={privacyAcknowledged}
                    onChange={(event) => setPrivacyAcknowledged(event.target.checked)}
                  />
                  <span>I understand connected agents may process data outside Flumen.</span>
                </label>
                <label style={quietCheckboxLabelStyle}>
                  <input
                    type="checkbox"
                    checked={dontShowAgain}
                    onChange={(event) => setDontShowAgain(event.target.checked)}
                  />
                  <span>Don't show this again</span>
                </label>
                <div style={consentActionsStyle}>
                  <button className="agent-control" disabled={!privacyAcknowledged} onClick={completeConsent} style={{ ...primaryButtonStyle, opacity: privacyAcknowledged ? 1 : 0.35 }}>Turn On Agent Access</button>
                  <button className="agent-control" onClick={() => setConsentStep(1)} style={secondaryButtonStyle}>Back</button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
};

const panelStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 120, background: theme.colors.background, borderRadius: theme.radii.window, padding: 24, boxSizing: 'border-box', display: 'flex', flexDirection: 'column', color: 'white', fontFamily: theme.fonts.display };
const headerStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 18 };
const titleStyle: React.CSSProperties = { margin: 0, fontFamily: theme.fonts.brand, fontSize: '1.1rem', letterSpacing: '-0.02em' };
const backButtonStyle: React.CSSProperties = {
  width: 32,
  height: 32,
  borderRadius: 16,
  border: 'none',
  background: 'rgba(255,255,255,.05)',
  color: 'white',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  cursor: 'pointer',
  padding: 0,
  flexShrink: 0,
};
const scrollStyle: React.CSSProperties = { overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 14, paddingBottom: 12 };
const statusCardStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, padding: '16px', background: 'linear-gradient(145deg, rgba(255,255,255,.075), rgba(255,255,255,.025))', border: '1px solid rgba(255,255,255,.09)', borderRadius: 18 };
const statusDotStyle: React.CSSProperties = {
  width: 9,
  height: 9,
  borderRadius: '50%',
  marginTop: 5,
  flexShrink: 0,
  boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.12)',
};
const secondaryTextStyle: React.CSSProperties = { fontSize: 11, lineHeight: 1.45, color: 'rgba(255,255,255,.48)' };
const sectionStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 10, padding: '14px 0', borderTop: '1px solid rgba(255,255,255,.06)' };
const sectionLabelStyle: React.CSSProperties = { color: 'rgba(255,255,255,.3)', fontSize: 9, fontWeight: 800, letterSpacing: '.12em' };
const permissionRowStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, minHeight: 42 };
const connectionRowStyle: React.CSSProperties = { ...permissionRowStyle, background: 'rgba(255,255,255,.035)', padding: '8px 10px', borderRadius: 10 };
const rowTitleStyle: React.CSSProperties = { color: 'white', fontSize: 12, fontWeight: 650 };
const allowedPillStyle: React.CSSProperties = { color: '#8BE69B', background: 'rgba(48,209,88,.1)', padding: '3px 7px', borderRadius: 6, fontSize: 9, fontWeight: 700, whiteSpace: 'nowrap' };
const twoColumnStyle: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 };
const primaryButtonStyle: React.CSSProperties = { minHeight: 38, borderRadius: 11, border: 'none', background: 'white', color: '#0A0A0A', fontWeight: 750, fontSize: 12, cursor: 'pointer', padding: '0 14px' };
const secondaryButtonStyle: React.CSSProperties = {
  ...primaryButtonStyle,
  color: 'rgba(255,255,255,.8)',
  background: 'rgba(255,255,255,.065)',
  border: '1px solid rgba(255,255,255,.075)',
  whiteSpace: 'nowrap',
};
const iconButtonStyle: React.CSSProperties = {
  ...secondaryButtonStyle,
  display: 'inline-flex',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 7,
};
const smallButtonStyle: React.CSSProperties = { ...secondaryButtonStyle, minHeight: 32 };
const dangerButtonStyle: React.CSSProperties = { ...smallButtonStyle, background: 'rgba(255,69,58,.16)', color: '#FF6961' };
const warningCardStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 9, padding: 13, borderRadius: 12, background: 'rgba(255,69,58,.08)', border: '1px solid rgba(255,69,58,.16)' };
const disclosureButtonStyle: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', width: '100%', border: 'none', background: 'transparent', color: 'rgba(255,255,255,.75)', padding: '6px 0', fontSize: 12, fontWeight: 650, cursor: 'pointer' };
const detailsListStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 7, margin: 0, padding: 10, background: 'rgba(255,255,255,.025)', borderRadius: 10, fontFamily: theme.fonts.mono, fontSize: 9, overflowWrap: 'anywhere' };
const detailTermStyle: React.CSSProperties = { color: 'rgba(255,255,255,.3)', display: 'inline', textTransform: 'capitalize' };
const detailValueStyle: React.CSSProperties = { color: 'rgba(255,255,255,.65)', display: 'inline', marginLeft: 8 };
const feedbackStyle: React.CSSProperties = { color: 'rgba(255,255,255,.65)', background: 'rgba(255,255,255,.04)', borderRadius: 9, padding: 9, fontSize: 10, textAlign: 'center' };
const toggleStyle = (enabled: boolean): React.CSSProperties => ({ position: 'relative', width: 42, height: 24, border: 0, borderRadius: 12, background: enabled ? theme.colors.focus.primary : 'rgba(255,255,255,.12)', padding: 0, cursor: 'pointer', flexShrink: 0 });
const toggleKnobStyle = (enabled: boolean): React.CSSProperties => ({ position: 'absolute', top: 3, left: enabled ? 21 : 3, width: 18, height: 18, borderRadius: '50%', background: 'white', transition: 'left .2s ease', boxShadow: '0 2px 5px rgba(0,0,0,.3)' });
const consentBackdropStyle: React.CSSProperties = { position: 'absolute', inset: 0, zIndex: 10, background: 'rgba(0,0,0,.78)', backdropFilter: 'blur(18px)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 20, borderRadius: theme.radii.window };
const consentCardStyle: React.CSSProperties = { width: '100%', padding: '18px 18px 16px', boxSizing: 'border-box', borderRadius: 18, background: '#171717', border: '1px solid rgba(255,255,255,.1)', display: 'flex', flexDirection: 'column', gap: 10, boxShadow: '0 22px 60px rgba(0,0,0,.55)' };
const eyebrowStyle: React.CSSProperties = { color: theme.colors.focus.primary, fontSize: 9, fontWeight: 800, letterSpacing: '.12em' };
const consentTitleStyle: React.CSSProperties = { margin: 0, fontFamily: theme.fonts.brand, fontSize: 17, letterSpacing: '-.025em' };
const consentBodyStyle: React.CSSProperties = { margin: 0, color: 'rgba(255,255,255,.62)', fontSize: 12, lineHeight: 1.5 };
const consentListStyle: React.CSSProperties = { margin: 0, paddingLeft: 18, color: 'rgba(255,255,255,.7)', fontSize: 11, lineHeight: 1.55 };
const consentActionsStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 8, marginTop: 2 };
const checkboxLabelStyle: React.CSSProperties = { display: 'flex', alignItems: 'flex-start', gap: 9, padding: '9px 10px', borderRadius: 10, background: 'rgba(255,255,255,.04)', color: 'rgba(255,255,255,.72)', fontSize: 11, lineHeight: 1.45, cursor: 'pointer' };
const quietCheckboxLabelStyle: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 9, padding: '2px 2px 0', color: 'rgba(255,255,255,.52)', fontSize: 11, lineHeight: 1.4, cursor: 'pointer' };

export default AgentAccessView;

