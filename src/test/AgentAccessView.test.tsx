import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, act } from '@testing-library/react';
import React from 'react';
import AgentAccessView, { normalizeSettings } from '../ui/AgentAccessView';

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
    expect(screen.getByText('Agent Access unavailable')).toBeTruthy();
    expect(screen.getByText('Unable to bind: Address already in use.')).toBeTruthy();
    expect(screen.queryByText('Ready for agents')).toBeNull();
  });

  it('shows Ready only when native reports the listener is up', () => {
    render(<AgentAccessView onBack={vi.fn()} />);
    emit('agentAccessSettings', { enabled: true });
    emit('agentConnectionStatus', { status: 'ready', enabled: true, connections: [] });
    expect(screen.getByText('Ready for agents')).toBeTruthy();
  });

  it('turns off when settings say disabled', () => {
    render(<AgentAccessView onBack={vi.fn()} />);
    emit('agentConnectionStatus', { status: 'ready', enabled: true, connections: [] });
    emit('agentAccessSettings', { enabled: false });
    expect(screen.getByText('Agent Access is off')).toBeTruthy();
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
