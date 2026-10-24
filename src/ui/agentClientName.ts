const KNOWN_CLIENTS: Record<string, string> = {
  'cursor-vscode': 'Cursor',
  cursor: 'Cursor',
  'claude-code': 'Claude Code',
  'claude-ai': 'Claude',
  claude: 'Claude',
  codex: 'Codex',
  'codex-mcp-client': 'Codex',
  'gemini-cli-mcp-client': 'Gemini CLI',
  windsurf: 'Windsurf',
  zed: 'Zed',
  // The helper's own name, reported before the agent completes its handshake.
  'flumen-mcp': 'Agent',
};

/** Human name for a self-reported MCP client identifier. */
export const agentDisplayName = (raw?: string | null): string => {
  const name = raw?.trim();
  if (!name) return 'Agent';
  return KNOWN_CLIENTS[name.toLowerCase()] ?? name;
};
