local M = {}

local source = debug.getinfo(1, "S").source
local module_file = source:sub(1, 1) == "@" and source:sub(2) or source
local plugin_root = vim.fn.fnamemodify(module_file, ":p:h:h:h")

function M.plugin_path(relative)
  return plugin_root .. "/" .. relative
end

--- POSIX single-quoting. Not vim.fn.shellescape(): that tracks the user's
--- 'shell' option, while these commands are interpreted by agent POSIX shells.
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function bridge_command(mode)
  local command = shell_quote(vim.v.progpath)
    .. " --headless -u NONE -i NONE -l "
    .. shell_quote(M.plugin_path("bridge/buoy.lua"))
  return mode and (command .. " " .. mode) or command
end

function M.cli_prefix()
  return bridge_command()
end

--- Direct argv for hosts that can launch hooks without a shell.
function M.bridge_argv(mode)
  return {
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-l",
    M.plugin_path("bridge/buoy.lua"),
    mode,
  }
end

--- Build the Neovim-integration guidance, including only the capabilities that
--- are enabled. `opts` mirrors the `context` config switches
--- (`expose_buffers`, `expose_diagnostics`, `expose_editor_context`); each
--- defaults to true when the table or field is nil, so a no-arg call reproduces
--- the full guidance. `set_cursor_position` is always advertised (navigation is
--- never gated).
function M.neovim_instructions(opts)
  local caps = require("buoy.capabilities").resolve(opts)
  local expose_buffers = caps.expose_buffers
  local expose_diagnostics = caps.expose_diagnostics
  local expose_editor_context = caps.expose_editor_context

  local parts = { "## Neovim context" }

  if expose_editor_context then
    parts[#parts + 1] = "A fresh snapshot of the current file, cursor, visual selection, cwd, and open buffers is\n"
      .. "attached to every user prompt. For additional live editor state, use this private CLI:"
  else
    parts[#parts + 1] = "Use this private CLI for live editor state:"
  end

  parts[#parts + 1] = "`" .. M.cli_prefix() .. "`"

  local bullets = {}
  if expose_buffers then
    bullets[#bullets + 1] = "- `get_buffer_range --start-line N --end-line N [--file ABSOLUTE_PATH]` — read up to\n"
      .. "  500 lines from an open buffer"
  end
  if expose_diagnostics then
    bullets[#bullets + 1] = "- `get_diagnostics [--file ABSOLUTE_PATH] [--offset N]` — editor errors and warnings\n"
      .. "  for an open buffer, up to 200 per call; `--offset N` skips the first N"
  end
  bullets[#bullets + 1] = "- `set_cursor_position --line N [--col N] [--file ABSOLUTE_PATH]` — move the user's\n"
    .. "  cursor, opening the file first if it is not already open"
  parts[#parts + 1] = table.concat(bullets, "\n")

  -- These hold for every command, including the always-advertised
  -- set_cursor_position, so they must survive with all read capabilities off.
  parts[#parts + 1] = "Lines and columns are 1-based. When `--file` is omitted, commands target the user's\n"
    .. "current file. Results are JSON."

  if expose_buffers or expose_diagnostics then
    -- Only advertise the continuation mechanic for the read commands that are
    -- actually exposed, so a single-capability config never references an
    -- argument for a command it withheld.
    local continuations = {}
    if expose_buffers then
      continuations[#continuations + 1] = "`next_start_line` as `--start-line`"
    end
    if expose_diagnostics then
      continuations[#continuations + 1] = "`next_offset` as `--offset`"
    end
    parts[#parts + 1] = 'If a result has `"truncated": true`, repeat the call, passing '
      .. table.concat(continuations, " or ")
      .. ",\n"
      .. "to fetch the rest."
  end

  if expose_buffers then
    parts[#parts + 1] = "Use `get_buffer_range` for files open in the editor, whose buffers may hold unsaved\n"
      .. "edits; read all other files from disk with your normal tools."
  end

  parts[#parts + 1] = "Move the cursor only when the user explicitly asks for a jump and you have already\n"
    .. "determined the exact target line; if they ask where something is, answer without moving."

  parts[#parts + 1] = "The CLI connects through a session-local Neovim socket, so every invocation requires the\n"
    .. "agent's normal permission-escalation mechanism. Use that mechanism on the first attempt;\n"
    .. "do not try the command in a restricted shell sandbox first.\n"
    .. "Never look up the socket path or connect to any socket directly; reach the editor only\n"
    .. "through this CLI. If permission is denied or the command reports `RPC_FAILED`, report\n"
    .. "that live editor access is unavailable."

  return table.concat(parts, "\n\n")
end

--- Shell command used by adapters that register a UserPromptSubmit hook. Kept
--- stable across sessions (no per-session socket embedded) so Codex's
--- persisted hook trust survives relaunches; the hook script discovers the
--- socket from the environment exported in terminal.lua.
function M.hook_command()
  return bridge_command("hook-context")
end

function M.post_tool_hook_command()
  return bridge_command("hook-checktime")
end

--- Shared material every adapter needs. Agents decide how to attach the
--- guidance and lifecycle commands to their own CLI or extension API.
function M.integration(opts)
  local caps = require("buoy.capabilities").resolve(opts)
  local integration = { guidance = M.neovim_instructions(caps) }
  if caps.expose_editor_context then
    integration.context_hook = M.hook_command()
    integration.post_tool_hook = M.post_tool_hook_command()
  end
  return integration
end

return M
