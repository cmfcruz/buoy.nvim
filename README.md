# buoy.nvim

[![Release](https://img.shields.io/github/v/release/cmfcruz/buoy.nvim?label=release)](https://github.com/cmfcruz/buoy.nvim/releases)
[![License](https://img.shields.io/github/license/cmfcruz/buoy.nvim)](LICENSE)
![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)
![MCP](https://img.shields.io/badge/MCP-stdio-5D6DFF)

<p align="center">
  <img src="buoy.png" alt="buoy.nvim" width="400">
</p>

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

## Install

buoy.nvim runs inside Neovim, so installing it means cloning it where Neovim
looks. Neovim loads anything in its built-in `pack/*/start/` folder
automatically at startup, and buoy configures itself with sensible defaults on
first load. Setup comes in two parts: **clone-and-launch** (below) gets you the
floating agent TUI, and a one-time
[MCP registration](#register-the-mcp-server) is what lets the agent pull your
live editor state. The clone is the only step needed to try the window.

**Linux/macOS:**

```sh
git clone https://github.com/cmfcruz/buoy.nvim \
  ~/.local/share/nvim/site/pack/buoy/start/buoy.nvim
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/cmfcruz/buoy.nvim `
  "$env:LOCALAPPDATA\nvim-data\site\pack\buoy\start\buoy.nvim"
```

Start Neovim, open any file, and **press `<F2>`** — Claude Code's
TUI floats over the editor. (buoy auto-detects which agent CLI is on your
`$PATH`, preferring Claude Code; no config file required.)

To update buoy later, pull the clone:

```sh
git -C ~/.local/share/nvim/site/pack/buoy/start/buoy.nvim pull
```

To also let the agent read your live editor state (selection, open file,
diagnostics), continue to [Register the MCP server](#register-the-mcp-server).

## Configuration

buoy works with zero configuration: it auto-detects your agent CLI (Claude
Code first, then Codex) and maps `<F2>`. Call `setup()` only to override a
default — put it in your `init.lua` (`~/.config/nvim/init.lua`, or
`~/AppData/Local/nvim/init.lua` on Windows):

```lua
require("buoy").setup({
  agent = "codex",            -- pin the agent: "auto" (default) | "claude" | "codex"
  keymaps = { toggle = "<leader>a" },  -- change the toggle key; set to false to disable
  -- cmd = "codex",           -- override the agent binary if it isn't on $PATH by name
  window = { style = "float", width = 0.4, border = "rounded" },
})
```

- **Switch to Codex:** set `agent = "codex"`. (With the default `"auto"`,
  buoy uses Codex anyway if it's the only CLI on your `$PATH`.)
- **Change the hotkey:** set `keymaps.toggle` to any key, or `false` to map
  nothing and drive it with `:Buoy` / `:BuoyFocus`.
- Every key is optional; anything you omit keeps its default.

## Register the MCP server

The bridge is a standard stdio MCP server. Register it with your agent's own
CLI — no need to find or hand-edit a config file, and the shell fills in the
absolute path for you (the agents spawn MCP servers without a shell, so the
path *must* be absolute — `~/...` in a config file would not expand).

Run **one** of these, matching the agent you use. `$HOME` is the only thing
the shell substitutes:

**Claude Code:**

```sh
claude mcp add -s user buoy -- \
  nvim -l "$HOME/.local/share/nvim/site/pack/buoy/start/buoy.nvim/bridge/mcp_bridge.lua"
```

(`-s user` registers it for all your projects; drop it to scope to the
current project only. Codex's `mcp add` is global by default.)

**Codex:**

```sh
codex mcp add buoy -- \
  nvim -l "$HOME/.local/share/nvim/site/pack/buoy/start/buoy.nvim/bridge/mcp_bridge.lua"
```

Verify with `/mcp` inside the TUI — you should see `buoy` with five
tools.

## Teach the agent to use the context

Add the following to the instructions file your agent reads — `AGENTS.md`
(or `~/.codex/AGENTS.md` globally) for Codex, or `CLAUDE.md`
(or `~/.claude/CLAUDE.md` globally) for Claude Code:

```markdown
## Neovim context

You may be running inside the user's Neovim. The `buoy` MCP server
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
2. `$NVIM_CONTEXT_SOCKET` — exported by buoy when it launches the
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

## Development

Contributions go through pull requests; `main` is protected by CI.

- **Formatting** — [StyLua](https://github.com/JohnnyMorganz/StyLua).
  Run `stylua .` (or `stylua --check .` to verify).
- **Linting** — [Selene](https://github.com/Kampfkarren/selene). Run
  `selene .`. The Neovim runtime is described in `vim.yml`.
- **Pre-commit** — `pip install pre-commit && pre-commit install` wires
  StyLua and a few hygiene hooks into your commits (StyLua's binary is
  fetched automatically; install Selene separately if you want it locally).

CI (`.github/workflows/ci.yml`) enforces both checks on every PR.

### Releases

Versioning is automated with
[Release Please](https://github.com/googleapis/release-please) using
[Conventional Commits](https://www.conventionalcommits.org/). Merging
`feat:` / `fix:` commits to `main` opens a release PR that bumps
`version.txt`, updates the changelog, and — once merged — tags the
release. Use `feat:`/`fix:` in commit subjects (and `feat!:` or a
`BREAKING CHANGE:` footer for breaking changes).
