# Flumen MCP Setup Guide

Flumen exposes a local MCP server through a signed stdio helper bundled inside the app. Agents connect with standard MCP configuration. Flumen must be open, and **Settings → Agent Access** must be on.

## Requirements

- Flumen is running on this Mac
- Agent Access is enabled
- Read Focus Data is on (required while Agent Access is on)
- Allow Proposals is on only if the agent should propose writes
- Every write is confirmed inside Flumen

If Agent Access is off or Flumen is closed, `flumen-mcp` refuses to stay connected. Cursor should show an error or disconnected state — not a healthy green session. That is intentional: Cursor “connected” must not outlive Flumen authorization.

## Client compatibility

The helper speaks baseline MCP stdio JSON. `initialize`, tool, resource, and prompt results omit optional `icons` and `websiteUrl` fields. Those fields are in the current spec, but several clients reject the entire handshake when they appear. A client only needs the absolute path to `flumen-mcp`. When that binary is inside `Flumen.app`, it finds that app’s bundle id itself. Set `FLUMEN_BUNDLE_ID` only to target a different build than the one that contains the helper.

## Add to Cursor

Cursor users can use **Install in Cursor** from Agent Access for a one-click deeplink, or paste **Copy configuration** into Cursor’s MCP settings.

1. Open Flumen → Settings → Agent Access → Turn On
2. Prefer **Copy configuration**, or choose **Install in Cursor**
3. Confirm in Cursor if using the deeplink
4. Ask Cursor to call `get_server_status` or `get_focus_status`

## Generic MCP configuration

Use **Copy configuration** in Agent Access, or the helper path under **Advanced**. Example:

```json
{
  "mcpServers": {
    "flumen": {
      "command": "/Applications/Flumen.app/Contents/Helpers/flumen-mcp",
      "args": []
    }
  }
}
```

Staging builds use the staging app path and staging Application Support socket. Do not mix staging and production helpers.

## Claude Code

```bash
claude mcp add flumen -- /Applications/Flumen.app/Contents/Helpers/flumen-mcp
```

Or paste the JSON from **Copy Configuration** into Claude Code’s MCP config.

## Codex

Add an MCP server entry that launches the `flumen-mcp` helper over stdio. Prefer **Copy Configuration** from Flumen so the helper path matches the installed app.

## Gemini CLI

Register Flumen as a local stdio MCP server using the helper path from Advanced. Restart the CLI after saving the config.

## Other MCP clients

Any client that supports local stdio MCP can use:

- command: absolute path to `Flumen.app/Contents/Helpers/flumen-mcp`
- args: none
- env: optional `FLUMEN_BUNDLE_ID` only when targeting a non-default bundle

Flumen never edits client config files for you.

## Verify the connection

1. Keep Flumen open with Agent Access on
2. In the client, list tools — you should see `get_focus_status`, `list_tasks`, `log_time`, and related tools
3. Call `get_server_status` — should report `ok: true`
4. Call `get_focus_status` — should return timer and active-task state
5. In Flumen, Active Connections should show the client name after a successful handshake

## Common errors

| Symptom | Fix |
| --- | --- |
| `app_unavailable` / Open Flumen | Launch Flumen and turn on Agent Access |
| Helper exits / Cursor shows error | Expected when Agent Access is off or Flumen is closed |
| `agent_access_disabled` | Settings → Agent Access → Turn On |
| `permission_denied` for writes | Enable Allow Proposals |
| `user_declined` / `proposal_expired` | Approve the proposal in Flumen within two minutes |
| Helper not found | Reinstall/update Flumen; copy the helper command again from Advanced |
| Staging/production mismatch | Use the helper from the same app that is running |

## Privacy boundary

Flumen keeps focus data on this Mac. A connected agent may send requested tasks or history to its model provider. Writes never apply without Flumen-side confirmation.

## Uninstall / turn off

Turn off Agent Access in Flumen to stop the local socket immediately. Remove the MCP server entry from your agent client when you no longer need it. Tasks, logs, and timer state are unchanged.
