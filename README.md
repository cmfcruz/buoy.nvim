# buoy.nvim

> Floats on the surface, anchored to the code.

A floating window for your AI coding agent — Codex or Claude Code's
**official TUI** — plus **pull-based editor context**: the agent itself calls
into your running Neovim (via MCP) to read the current file, cursor position,
visual selection, open buffers, and LSP diagnostics — the same experience as
the VS Code integration, without maintaining any chat UI.

The window **floats on the surface** of your editor; the MCP bridge keeps the
agent **anchored to the code** — grounded in your live editor state instead of
whatever you remember to paste.

```
┌─ Neovim ──────────────────────┬─ Agent (official TUI) ─┐
│  editing buffers              │  › what does this      │
│  autocmds cache:              │    selection do?       │
│   file / cursor / selection   │                        │
│        ▲                      │  [calls MCP tool       │
│        │ msgpack-RPC          │   get_current_selection│
│  ┌─────┴──────┐   stdio MCP   │   mid-turn]            │
│  │ mcp_bridge │◄──────────────┤                        │
│  └────────────┘  (spawned by  │                        │
│                   the agent)  │                        │
└───────────────────────────────┴────────────────────────┘
```

## Requirements

- Neovim 0.9+ (0.10+ recommended for exact charwise selections)
- The Codex and/or Claude Code CLI on your `$PATH`

## Install (lazy.nvim)

```lua
{
  "cmfcruz/buoy.nvim",
  opts = {
    agent = "codex",        -- "codex" | "claude" (Claude Code)
    -- cmd = "codex",       -- optional: override the agent's default binary
    window = { style = "float", width = 0.4, border = "rounded" },
    keymaps = { toggle = "<F2>" },
  },
}
```

The `agent` option is the single switch between Codex and Claude Code. It
selects which CLI the window launches and the window title; set `cmd` only if
your binary isn't on `$PATH` under the default name. The MCP context bridge
below is identical for both agents — only the registration step differs.

## Register the MCP server

The bridge is a standard stdio MCP server, so both agents can use it. Use
the **absolute** path to wherever your plugin manager installed this repo.

### Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.nvim_context]
command = "nvim"
args = ["-l", "/home/you/.local/share/nvim/lazy/buoy.nvim/bridge/mcp_bridge.lua"]
```

Verify inside the Codex TUI with `/mcp` — you should see `nvim_context`
with five tools.

### Claude Code

Register via the CLI (writes to your Claude Code config):

```sh
claude mcp add nvim_context -- \
  nvim -l /home/you/.local/share/nvim/lazy/buoy.nvim/bridge/mcp_bridge.lua
```

…or add it to a project-local `.mcp.json`:

```json
{
  "mcpServers": {
    "nvim_context": {
      "command": "nvim",
      "args": ["-l", "/home/you/.local/share/nvim/lazy/buoy.nvim/bridge/mcp_bridge.lua"]
    }
  }
}
```

Verify inside Claude Code with `/mcp` — you should see `nvim_context`.

## Teach the agent to use the context

Add the following to the instructions file your agent reads — `AGENTS.md`
(or `~/.codex/AGENTS.md` globally) for Codex, or `CLAUDE.md`
(or `~/.claude/CLAUDE.md` globally) for Claude Code:

```markdown
## Neovim context

You may be running inside the user's Neovim. The `nvim_context` MCP server
exposes the user's live editor state. When the user says "this file",
"this code", "the selection", "here", or refers to code they have not
pasted, call `get_current_selection`, `get_current_file`, or
`get_cursor_position` before answering. Use `get_diagnostics` when asked
about errors or warnings.
```

## Usage

1. `:Buoy` (or `<F2>`) toggles the window. The agent session survives
   hiding the window.
2. Edit normally, select code in visual mode, then ask the agent things like
   *"refactor this selection"* — the agent pulls the selection itself.

## How socket discovery works

The agent spawns the bridge as a child process. The bridge finds your
running Neovim in this order:

1. `$NVIM` — set automatically for processes spawned from inside Neovim,
   if the agent forwards its environment to MCP servers
2. `$NVIM_CONTEXT_SOCKET` — exported by the plugin when it launches the
   agent (`$CODEX_NVIM_SOCKET` is also set as a legacy alias)
3. A cwd-keyed lockfile under `stdpath("cache")/buoy/`
4. A `latest` lockfile (most recently started instance)

If your agent sanitizes the environment for MCP children, the lockfiles
still make discovery work; for multiple simultaneous Neovim instances in
*different* directories, the cwd-keyed lockfile picks the right one.

## Limitations / roadmap

- Context is pull-based only; there is no push of selection-changed
  events (the agent's MCP client has no use for them anyway).
- `open_diff` / in-editor approval is intentionally out of scope: the
  official TUI already renders diffs and approvals, which is the point.
- Two Neovim instances in the *same* cwd will race on the lockfile;
  `$NVIM` passthrough resolves this when available.
