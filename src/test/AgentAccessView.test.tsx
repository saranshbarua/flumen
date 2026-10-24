import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, act, fireEvent } from '@testing-library/react';
import React from 'react';
import AgentAccessView, { normalizeSettings } from '../ui/AgentAccessView';
import { agentDisplayName } from '../ui/agentClientName';
import { NativeBridge } from '../services/nativeBridge';

vi.mock('../services/nativeBridge', () => ({
  NativeBridge: {
    getAgentAccessSettings: vi.fn(),
    getAgentConnectionStatus: vi.fn(),
    setAgentAccessSettings: vi.fn(),
    disconnectAgentSessions: vi.fn(),
    getAgentConnectionDetails: vi.fn(),
    retryAgentAccess: vi.fn(),
    copyAgentConfiguration: vi.fn(),
    addToCursor: vi.fn(),
    openAgentSetupGuide: vi.fn(),
    copyAgentServerCommand: vi.fn(),
  },
}));

const emit = (action: string, detail: unknown) =>
  act(() => {
    window.dispatchEvent(new CustomEvent(`native:${action}`, { detail }));
  });

describe('AgentAccessView', () => {
  beforeEach(() => vi.clearAllMocks());

  it('keeps a failed start visible when settings arrive afterwards', () => {
    render(<AgentAccessView onBack={vi.fn()} />);
    emit('agentConnectionStatus', {
      status: 'error',
      enabled: true,
      error: 'Unable to bind: Address already in use.',
      connections: [],
    });
    emit('agentAccessSettings', { enabled: true, readFocusData: true, allowProposals: true });
    expect(screen.getByText('Couldn’t start')).toBeTruthy();
    expect(screen.getByText('Unable to bind: Address already in use.')).toBeTruthy();
    expect(screen.queryByText('Ready')).toBeNull();
  });

  it('shows Ready only when native reports the listener is up', () => {
    render(<AgentAccessView onBack={vi.fn()} />);
    emit('agentAccessSettings', { enabled: true });
    emit('agentConnectionStatus', { status: 'ready', enabled: true, connections: [] });
    expect(screen.getByText('Ready')).toBeTruthy();
  });

  it('explains the feature only while it is off', () => {
    render(<AgentAccessView onBack={vi.fn()} />);
    emit('agentConnectionStatus', { status: 'ready', enabled: true, connections: [] });
    emit('agentAccessSettings', { enabled: false });
    expect(screen.getByText('Off')).toBeTruthy();
    expect(screen.getByText(/read your focus data and propose changes you approve/)).toBeTruthy();
  });

  it('names the connected agent and offers Disconnect without a separate list', () => {
    render(<AgentAccessView onBack={vi.fn()} />);
    emit('agentAccessSettings', { enabled: true });
    emit('agentConnectionStatus', { status: 'connected', enabled: true, connections: [{ id: 'c1', name: 'cursor-vscode' }] });
    expect(screen.getByText('Cursor connected')).toBeTruthy();
    expect(screen.queryByText(/ACTIVE CONNECTIONS|Active now/)).toBeNull();
    fireEvent.click(screen.getByText('Disconnect'));
    expect(NativeBridge.disconnectAgentSessions).toHaveBeenCalled();
  });

  it('drops redundant labels from the connected screen', () => {
    render(<AgentAccessView onBack={vi.fn()} />);
    emit('agentAccessSettings', { enabled: true });
    emit('agentConnectionStatus', { status: 'ready', enabled: true, connections: [] });
    expect(screen.queryByText(/CONNECT AN AGENT|PERMISSIONS|Read Focus Data|Required|For support or manual MCP setup/)).toBeNull();
    expect(screen.getByText('Approvals')).toBeTruthy();
    expect(screen.getByText('Each change waits for you. Off applies it immediately.')).toBeTruthy();
    expect(screen.getByText(/Paste into your agent’s MCP settings/)).toBeTruthy();
  });
});

describe('normalizeSettings', () => {
  it('keeps only known, correctly typed fields', () => {
    expect(normalizeSettings({ settings: { enabled: true, consentVersion: 1, extra: 'x', allowProposals: 'yes' } }))
      .toEqual({ enabled: true, consentVersion: 1 });
    expect(normalizeSettings(null)).toEqual({});
    expect(normalizeSettings('bad')).toEqual({});
  });
});

describe('agentDisplayName', () => {
  it('maps known client identifiers to product names', () => {
    expect(agentDisplayName('cursor-vscode')).toBe('Cursor');
    expect(agentDisplayName('claude-code')).toBe('Claude Code');
    expect(agentDisplayName('flumen-mcp')).toBe('Agent');
    expect(agentDisplayName('my-custom-client')).toBe('my-custom-client');
    expect(agentDisplayName(undefined)).toBe('Agent');
  });
});
