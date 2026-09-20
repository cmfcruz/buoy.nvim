--- Claude Code launch adapter.
local M = {}

function M.argv(opts)
  local integration = require("buoy.instructions").integration(opts.context)
  local argv = { opts.cmd, "--append-system-prompt", integration.guidance }
  local hooks = {}
  if integration.context_hook then
    hooks.UserPromptSubmit = {
      { hooks = { { type = "command", command = integration.context_hook, timeout = 10 } } },
    }
    hooks.PostToolUse = {
      {
        matcher = "Edit|Write",
        hooks = { { type = "command", command = integration.post_tool_hook, timeout = 10 } },
      },
    }
  end
  if next(hooks) then
    vim.list_extend(argv, { "--settings", vim.json.encode({ hooks = hooks }) })
  end
  return argv
end

function M.resolve(opts, callback)
  callback(M.argv(opts))
end

return M
