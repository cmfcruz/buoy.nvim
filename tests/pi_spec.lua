local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local function eq(expected, actual, label)
  assert(vim.deep_equal(expected, actual), label .. "\n" .. vim.inspect(actual))
end

local ok, err = xpcall(function()
  local pi = require("buoy.custom.pi")
  local instructions = require("buoy.instructions")
  local opts = { cmd = "pi-custom", cwd = "/cwd", context = {} }
  local argv, env = pi.argv(opts)
  eq("pi-custom", argv[1], "Pi preserves the configured command")
  eq("--extension", argv[2], "Pi loads its adapter extension")
  assert(argv[3]:find("/lua/buoy/custom/pi_hooks%.ts$"), "Pi uses its bundled extension")
  eq(instructions.neovim_instructions(), env.BUOY_PI_INSTRUCTIONS, "Pi receives shared guidance")
  eq(instructions.hook_command(), env.BUOY_CONTEXT_HOOK_COMMAND, "Pi receives the context hook")
  eq(
    instructions.post_tool_hook_command(),
    env.BUOY_POST_TOOL_HOOK_COMMAND,
    "Pi receives the refresh hook"
  )

  opts.context = { expose_editor_context = false }
  argv, env = pi.argv(opts)
  eq(nil, env.BUOY_CONTEXT_HOOK_COMMAND, "Pi omits its disabled context hook")
  eq(nil, env.BUOY_POST_TOOL_HOOK_COMMAND, "Pi omits its disabled refresh hook")
  assert(
    env.BUOY_PI_INSTRUCTIONS:find("set_cursor_position", 1, true),
    "Pi keeps navigation guidance"
  )

  local resolved_argv, resolved_env
  pi.resolve(opts, function(value, launch_env)
    resolved_argv, resolved_env = value, launch_env
  end)
  eq(argv, resolved_argv, "Pi implements the common argv contract")
  eq(env, resolved_env, "Pi implements the common environment contract")
end, debug.traceback)

if not ok then
  error(err)
end
print("pi_spec: ok")
