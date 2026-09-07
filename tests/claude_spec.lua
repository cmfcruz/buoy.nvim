local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local function eq(expected, actual, label)
  assert(vim.deep_equal(expected, actual), label .. "\n" .. vim.inspect(actual))
end

local ok, err = xpcall(function()
  local claude = require("buoy.custom.claude")
  local instructions = require("buoy.instructions")
  local opts = { cmd = "claude-custom", cwd = "/cwd", context = {} }
  local argv = claude.argv(opts)
  eq("claude-custom", argv[1], "Claude preserves the configured command")
  eq("--append-system-prompt", argv[2], "Claude attaches shared guidance")
  eq(instructions.neovim_instructions(), argv[3], "Claude receives all shared guidance")
  eq("--settings", argv[4], "Claude attaches its hook settings")
  local hooks = vim.json.decode(argv[5]).hooks
  eq(
    instructions.hook_command(),
    hooks.UserPromptSubmit[1].hooks[1].command,
    "Claude maps prompt submission to the shared context hook"
  )
  eq("Edit|Write", hooks.PostToolUse[1].matcher, "Claude matches its native mutation tools")
  eq(
    instructions.post_tool_hook_command(),
    hooks.PostToolUse[1].hooks[1].command,
    "Claude maps native edits to the shared refresh hook"
  )

  opts.context = { expose_editor_context = false }
  argv = claude.argv(opts)
  eq(3, #argv, "Claude omits hook settings when automatic context is disabled")
  assert(argv[3]:find("set_cursor_position", 1, true), "Claude keeps navigation guidance")

  local resolved
  claude.resolve(opts, function(value)
    resolved = value
  end)
  eq(argv, resolved, "Claude implements the common resolve contract")
end, debug.traceback)

if not ok then
  error(err)
end
print("claude_spec: ok")
