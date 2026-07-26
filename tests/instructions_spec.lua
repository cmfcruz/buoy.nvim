local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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
  local consolidated =
    instructions.append_instructions("first line\nsecond line", neovim_instructions)
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
  eq(
    "first line\nsecond line\n\n" .. neovim_instructions,
    consolidated,
    "existing multiline instructions are preserved"
  )
  eq(
    neovim_instructions,
    instructions.append_instructions("", neovim_instructions),
    "empty instructions use only Buoy guidance"
  )
  eq(
    neovim_instructions,
    instructions.append_instructions(nil, neovim_instructions),
    "null instructions use only Buoy guidance"
  )

  -- The plugin root may be an installed (possibly symlinked) copy rather than
  -- this checkout, so assert the command's shape instead of the exact path.
  local hook_command = instructions.hook_command()
  truthy(
    hook_command:find("^'" .. vim.pesc(vim.v.progpath) .. "' %-%-headless %-u NONE %-i NONE %-l '"),
    "hook command isolates the current nvim from user configuration"
  )
  truthy(
    hook_command:find("/bridge/context_hook%.lua'$"),
    "hook command targets the bundled context hook script"
  )
  local cli_prefix = instructions.cli_prefix()
  truthy(
    cli_prefix:find("^'" .. vim.pesc(vim.v.progpath) .. "' %-%-headless %-u NONE %-i NONE %-l '"),
    "CLI prefix isolates the headless child from user configuration"
  )
  truthy(
    cli_prefix:find("/bridge/agent_cli%.lua'$"),
    "CLI prefix targets the bundled agent adapter"
  )
  truthy(
    neovim_instructions:find(cli_prefix, 1, true),
    "Buoy guidance includes the exact CLI prefix"
  )

  local fake_hook = "'/path/to/nvim' --headless -l '/path/to/context_hook.lua'"
  local codex_argv = instructions.codex_argv("codex-custom", consolidated, fake_hook)
  eq("codex-custom", codex_argv[1], "Codex command is preserved")
  eq("-c", codex_argv[2], "Codex receives a config override")
  local encoded = codex_argv[3]:sub(#"developer_instructions=" + 1)
  eq(consolidated, vim.json.decode(encoded), "multiline Codex instructions are safely encoded")
  eq({
    "-c",
    'hooks.UserPromptSubmit=[{hooks=[{type="command",'
      .. "command=\"'/path/to/nvim' --headless -l '/path/to/context_hook.lua'\",timeout=10}]}]",
  }, { unpack(codex_argv, 4) }, "Codex argv attaches only its context hook after guidance")

  local claude_argv = instructions.claude_argv("claude-custom", neovim_instructions, fake_hook)
  eq("claude-custom", claude_argv[1], "Claude command is preserved")
  eq("--append-system-prompt", claude_argv[2], "Claude receives the system prompt flag")
  eq(neovim_instructions, claude_argv[3], "Claude receives the Buoy guidance")
  eq("--settings", claude_argv[4], "Claude receives the settings flag")
  local settings = vim.json.decode(claude_argv[5])
  eq(
    { { hooks = { { type = "command", command = fake_hook, timeout = 10 } } } },
    settings.hooks.UserPromptSubmit,
    "Claude registers the context hook for every prompt"
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
    navigation_only:find(
      "When `--file` is omitted, commands target the user's\ncurrent file",
      1,
      true
    ),
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

  -- A nil hook_command omits the UserPromptSubmit hook from both argv builders.
  local claude_no_hook = instructions.claude_argv("claude-custom", neovim_instructions, nil)
  truthy(
    not vim.list_contains(claude_no_hook, "--settings"),
    "Claude omits --settings when the hook is disabled"
  )
  local codex_no_hook = instructions.codex_argv("codex-custom", consolidated, nil)
  for _, entry in ipairs(codex_no_hook) do
    truthy(
      type(entry) ~= "string" or not entry:find("hooks.UserPromptSubmit", 1, true),
      "Codex omits the UserPromptSubmit hook when disabled"
    )
  end
end, debug.traceback)

if not ok then
  error(err)
end

print("instructions_spec: ok")
