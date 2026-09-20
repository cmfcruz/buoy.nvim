--- Pi launch adapter.
local M = {}

function M.argv(opts)
  local instructions = require("buoy.instructions")
  local integration = instructions.integration(opts.context)
  local env = { BUOY_PI_INSTRUCTIONS = integration.guidance }
  if integration.context_hook then
    env.BUOY_CONTEXT_HOOK_COMMAND = integration.context_hook
    env.BUOY_POST_TOOL_HOOK_COMMAND = integration.post_tool_hook
  end
  return { opts.cmd, "--extension", instructions.plugin_path("lua/buoy/custom/pi_hooks.ts") }, env
end

function M.resolve(opts, callback)
  callback(M.argv(opts))
end

return M
