local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
-- A globally installed start package may have loaded its own copy before this
-- spec runs under `-u NONE`; force the checkout's module after setting the path.
package.loaded["buoy.instructions"] = nil

local function fail(message)
  error(message, 2)
end

local function eq(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    fail(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        label or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function truthy(value, label)
  if not value then
    fail(label or "expected a truthy value")
  end
end

local ok, err = xpcall(function()
  local instructions = require("buoy.instructions")
  local neovim_instructions = instructions.neovim_instructions()
  truthy(
    neovim_instructions:find("attached to every user prompt", 1, true),
    "Buoy guidance states that editor context arrives with every prompt"
  )
  truthy(
    neovim_instructions:find(
      "get_buffer_range %-%-start%-line N %-%-end%-line N %[%-%-file ABSOLUTE_PATH%]"
    ),
    "Buoy guidance includes the compact buffer-read signature"
  )
  truthy(
    neovim_instructions:find("get_diagnostics %[%-%-file ABSOLUTE_PATH%] %[%-%-offset N%]"),
    "Buoy guidance includes the compact diagnostics signature"
  )
  truthy(
    neovim_instructions:find(
      "set_cursor_position %-%-line N %[%-%-col N%] %[%-%-file ABSOLUTE_PATH%]"
    ),
    "Buoy guidance includes the compact cursor signature"
  )
  truthy(
    neovim_instructions:find("Move the cursor only when the user explicitly asks", 1, true),
    "Buoy guidance restricts cursor movement to explicit requests"
  )
  truthy(
    neovim_instructions:find("every invocation requires", 1, true),
    "Buoy guidance requires permission escalation for live editor calls"
  )
  truthy(
    neovim_instructions:find("Use that mechanism on the first attempt", 1, true),
    "Buoy guidance requests permission escalation before invoking the CLI"
  )
  truthy(
    neovim_instructions:find("Never look up the socket path", 1, true),
    "Buoy guidance preserves authoritative socket routing"
  )
  -- The plugin root may be an installed (possibly symlinked) copy rather than
  -- this checkout, so assert the command's shape instead of the exact path.
  local cli_prefix = instructions.cli_prefix()
  truthy(
    cli_prefix:find("^'" .. vim.pesc(vim.v.progpath) .. "' %-%-headless %-u NONE %-i NONE %-l '"),
    "CLI prefix isolates the headless child from user configuration"
  )
  truthy(
    cli_prefix:find("/bridge/buoy%.lua'$"),
    "CLI prefix targets the unified bridge entry point"
  )

  local hook_command = instructions.hook_command()
  eq(
    cli_prefix .. " hook-context",
    hook_command,
    "context hook uses the unified bridge path and its internal mode"
  )
  local post_tool_hook_command = instructions.post_tool_hook_command()
  eq(
    cli_prefix .. " hook-checktime",
    post_tool_hook_command,
    "PostToolUse hook uses the unified bridge path and its internal mode"
  )
  truthy(
    neovim_instructions:find(cli_prefix, 1, true),
    "Buoy guidance includes the exact CLI prefix"
  )

  -- Capability switches drop disabled surfaces from the guidance. Navigation is
  -- always advertised.
  local no_buffers = instructions.neovim_instructions({ expose_buffers = false })
  truthy(
    not no_buffers:find("get_buffer_range --start-line", 1, true),
    "disabling expose_buffers omits the buffer-read command"
  )
  truthy(
    no_buffers:find("get_diagnostics %[%-%-file ABSOLUTE_PATH%]"),
    "disabling expose_buffers keeps diagnostics"
  )
  truthy(
    no_buffers:find("set_cursor_position %-%-line N", 1, false),
    "disabling expose_buffers keeps navigation"
  )
  truthy(
    not no_buffers:find("next_start_line", 1, true),
    "disabling expose_buffers drops its truncation-continuation arg"
  )
  truthy(
    no_buffers:find("next_offset", 1, true),
    "disabling expose_buffers keeps the diagnostics continuation arg"
  )
  local no_diagnostics = instructions.neovim_instructions({ expose_diagnostics = false })
  truthy(
    not no_diagnostics:find("next_offset", 1, true),
    "disabling expose_diagnostics drops its truncation-continuation arg"
  )
  truthy(
    no_diagnostics:find("next_start_line", 1, true),
    "disabling expose_diagnostics keeps the buffer continuation arg"
  )
  local no_context = instructions.neovim_instructions({ expose_editor_context = false })
  truthy(
    not no_context:find("attached to every user prompt", 1, true),
    "disabling expose_editor_context drops the per-prompt snapshot line"
  )
  local navigation_only = instructions.neovim_instructions({
    expose_buffers = false,
    expose_diagnostics = false,
    expose_editor_context = false,
  })
  truthy(
    navigation_only:find("Lines and columns are 1-based", 1, true),
    "navigation-only guidance keeps the 1-based coordinate contract"
  )
  truthy(
    navigation_only
      :gsub("%s+", " ")
      :find("When `--file` is omitted, commands target the user's current file", 1, true),
    "navigation-only guidance keeps the current-file default"
  )
  truthy(
    navigation_only:find("Results are JSON", 1, true),
    "navigation-only guidance keeps the result format"
  )
  truthy(
    navigation_only:find("set_cursor_position --line N", 1, true),
    "navigation-only guidance still advertises cursor navigation"
  )
  truthy(
    not navigation_only:find("truncated", 1, true),
    "navigation-only guidance omits the read-command truncation sentence"
  )
  truthy(
    not navigation_only:find("next_start_line", 1, true),
    "navigation-only guidance omits the buffer continuation argument"
  )
  truthy(
    not navigation_only:find("next_offset", 1, true),
    "navigation-only guidance omits the diagnostics continuation argument"
  )

  local integration = instructions.integration({ expose_editor_context = false })
  eq(no_context, integration.guidance, "shared integration returns capability-aware guidance")
  eq(nil, integration.context_hook, "shared integration omits the disabled context hook")
  eq(nil, integration.post_tool_hook, "shared integration omits the disabled refresh hook")
end, debug.traceback)

if not ok then
  error(err)
end

print("instructions_spec: ok")
