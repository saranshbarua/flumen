# MCP icon source

`mcp-icon.png` is the Flumen mark kept for a future client that can render MCP icons.

The helper does not embed this image in `initialize`, tools, resources, or prompts. Several MCP clients reject the handshake when those optional fields are present, so the wire protocol stays on the baseline schema.
