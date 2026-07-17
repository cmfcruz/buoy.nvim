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
end, debug.traceback)

if not ok then
  error(err)
end

print("instructions_spec: ok")
