--- UserPromptSubmit hook, run by the agent as:
--- nvim --headless -u NONE -i NONE -l context_hook.lua
---
--- Prints the editor-context snapshot from the user's running Neovim to
--- stdout; Claude Code and Codex attach hook stdout as per-prompt context,
--- giving the model fresh editor state without spending a tool call.
---
--- The command line registered with the agent must stay stable across
--- sessions (Codex persists hook trust keyed on it), so the socket is never
--- embedded here — discovery goes through the environment.
--- Stdin (the agent's event payload) is deliberately never read: a CLI that
--- holds the pipe open would stall the prompt until the hook timeout.
---
--- Snapshot failures must never block the user's prompt: this script suppresses
--- errors and always exits 0 (an uncaught error under
--- `nvim --headless -u NONE -i NONE -l` would exit 1; Claude Code treats exit 2
--- as "block the prompt").

local function write_lines(lines)
  for _, line in ipairs(lines) do
    io.write(line .. "\n")
  end
  io.flush()
end

pcall(function()
  local script_dir = arg[0]:match("^(.*)[/\\]") or "."
  local rpc = dofile(script_dir .. "/nvim_rpc.lua")

  local chan = rpc.connect()
  if not chan then
    return
  end

  local ok, context = pcall(rpc.exec, chan, "return require('buoy.tools').editor_context()", {})
  pcall(vim.fn.chanclose, chan)

  if not ok or type(context) ~= "table" then
    return
  end

  local encoded = vim.json.encode(context)

  write_lines({
    "Current Neovim editor context (auto-refreshed for every prompt):",
    encoded,
  })
end)

os.exit(0)
