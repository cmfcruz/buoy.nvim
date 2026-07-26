local M = {}

local source = debug.getinfo(1, "S").source
local module_file = source:sub(1, 1) == "@" and source:sub(2) or source
local plugin_root = vim.fn.fnamemodify(module_file, ":p:h:h:h")

function M.append_instructions(existing, additional)
  if type(existing) == "string" and existing ~= "" then
    return existing .. "\n\n" .. additional
  end
  return additional
end

--- POSIX single-quoting. Not vim.fn.shellescape(): that tracks the user's
--- 'shell' option, while these commands are interpreted by agent POSIX shells.
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function headless_script_command(script)
  return shell_quote(vim.v.progpath)
    .. " --headless -u NONE -i NONE -l "
    .. shell_quote(plugin_root .. "/bridge/" .. script)
end

function M.cli_prefix()
  return headless_script_command("agent_cli.lua")
end

function M.neovim_instructions()
  return ([[## Neovim context

A fresh snapshot of the current file, cursor, visual selection, cwd, and open buffers is
attached to every user prompt. For additional live editor state, use this private CLI:

`%s`

- `get_buffer_range --start-line N --end-line N [--file ABSOLUTE_PATH]` — read up to
  500 lines from an open buffer
- `get_diagnostics [--file ABSOLUTE_PATH] [--offset N]` — editor errors and warnings
  for an open buffer, up to 200 per call; `--offset N` skips the first N
- `set_cursor_position --line N [--col N] [--file ABSOLUTE_PATH]` — move the user's
  cursor, opening the file first if it is not already open

Lines and columns are 1-based. When `--file` is omitted, commands target the user's
current file. Results are JSON; if a result has `"truncated": true`, repeat the call,
passing `next_start_line` as `--start-line` or `next_offset` as `--offset`, to fetch
the rest.

Use `get_buffer_range` for files open in the editor, whose buffers may hold unsaved
edits; read all other files from disk with your normal tools.

Move the cursor only when the user explicitly asks for a jump and you have already
determined the exact target line; if they ask where something is, answer without moving.

The CLI connects through a session-local Neovim socket, so every invocation requires the
agent's normal permission-escalation mechanism. Use that mechanism on the first attempt;
do not try the command in a restricted shell sandbox first.
Never look up the socket path or connect to any socket directly; reach the editor only
through this CLI. If permission is denied or the command reports `RPC_FAILED`, report
that live editor access is unavailable.]]):format(M.cli_prefix())
end

--- Shell command both agents register as the UserPromptSubmit hook. Kept
--- stable across sessions (no per-session socket embedded) so Codex's
--- persisted hook trust survives relaunches; the hook script discovers the
--- socket from the environment exported in terminal.lua.
function M.hook_command()
  return headless_script_command("context_hook.lua")
end

-- Render a TOML basic string. vim.json.encode() is the wrong boundary here:
-- Codex parses the value as TOML, whose valid escapes are narrower than JSON's.
-- TOML basic strings permit only
-- \b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX, so escape backslash, double quote,
-- and control bytes (0x00-0x1F and 0x7F) and leave everything else, including
-- "/", verbatim.
local function toml_basic_string(s)
  local shorthand = {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["\b"] = "\\b",
    ["\t"] = "\\t",
    ["\n"] = "\\n",
    ["\f"] = "\\f",
    ["\r"] = "\\r",
  }
  local escaped = s:gsub('[%z\1-\31\127"\\]', function(c)
    return shorthand[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

function M.codex_argv(cmd, developer_instructions, hook_command)
  local argv = { cmd }
  if developer_instructions then
    vim.list_extend(argv, {
      "-c",
      "developer_instructions=" .. toml_basic_string(developer_instructions),
    })
  end
  -- The structure is hand-written TOML (inline tables); toml_basic_string()
  -- renders the command as a valid TOML basic string on every Neovim version.
  vim.list_extend(argv, {
    "-c",
    'hooks.UserPromptSubmit=[{hooks=[{type="command",command='
      .. toml_basic_string(hook_command)
      .. ",timeout=10}]}]",
  })
  return argv
end

function M.claude_argv(cmd, system_instructions, hook_command)
  local settings = {
    hooks = {
      UserPromptSubmit = {
        { hooks = { { type = "command", command = hook_command, timeout = 10 } } },
      },
    },
  }
  return {
    cmd,
    "--append-system-prompt",
    system_instructions,
    "--settings",
    vim.json.encode(settings),
  }
end

return M
