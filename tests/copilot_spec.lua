local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

vim.opt.runtimepath:prepend(root)

local function eq(expected, actual, label)
  assert(vim.deep_equal(expected, actual), label .. "\n" .. vim.inspect(actual))
end

local temp = vim.fn.tempname() .. " quoted ' 日本語"
vim.fn.mkdir(temp, "p")
local original_tempname = vim.fn.tempname
local original_notify = vim.notify
local original_system = vim.system
local config = require("buoy").config
local original_context = config.context
local original_dirs = vim.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS
vim.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS = nil

local ok, err = xpcall(function()
  local addr = vim.fn.serverstart()
  local file = temp .. "/current.lua"
  vim.fn.writefile({ "saved", "second line" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local state = require("buoy.context").state
  state.file = file
  state.filetype = "lua"
  state.cursor = { line = 1, col = 2 }

  -- Execute Buoy's generated hook argv directly over a live RPC connection.
  -- No shell: spaces, quotes and Unicode must remain literal.
  local function run(hook, payload, missing)
    local argv = { hook.exec }
    vim.list_extend(argv, hook.args)
    local result
    vim.system(argv, {
      env = { NVIM_CONTEXT_SOCKET = missing and (temp .. "/missing.sock") or addr },
      stdin = payload,
      text = true,
    }, function(value)
      result = value
    end)
    assert(
      vim.wait(10000, function()
        return result ~= nil
      end, 10),
      "hook finishes within its deadline"
    )
    eq(0, result.code, "hook contract is fail-open")
    eq("", result.stderr, "hooks do not emit error noise")
    return result.stdout
  end

  local version_result = { code = 0, stdout = "GitHub Copilot CLI 1.0.83.\n" }
  vim.system = function(argv, opts, callback)
    if argv[1] == "copilot-custom" and argv[2] == "--version" then
      callback(version_result)
      return {}
    end
    return original_system(argv, opts, callback)
  end
  local serial = 0
  vim.fn.tempname = function()
    serial = serial + 1
    return temp .. "/plugin " .. serial
  end
  local prompt_hook
  for _, buffers in ipairs({ true, false }) do
    for _, diagnostics in ipairs({ true, false }) do
      for _, editor in ipairs({ true, false }) do
        config.context = {
          expose_buffers = buffers,
          expose_diagnostics = diagnostics,
          expose_editor_context = editor,
        }
        local argv, launch_env
        require("buoy.launcher").resolve("copilot", "copilot-custom", temp, function(value, env)
          argv, launch_env = value, env
        end)
        assert(
          vim.wait(1000, function()
            return argv ~= nil
          end),
          "launcher resolves asynchronously"
        )
        eq("copilot-custom", argv[1], "custom executable survives launch preparation")
        eq("--plugin-dir", argv[2], "Copilot loads a session-local plugin")
        eq(3, #argv, "launch does not change permissions or instruction discovery")
        local manifest = vim.json.decode(table.concat(vim.fn.readfile(argv[3] .. "/plugin.json")))
        local hooks =
          vim.json.decode(table.concat(vim.fn.readfile(argv[3] .. "/" .. manifest.hooks))).hooks
        local guidance = table.concat(vim.fn.readfile(argv[3] .. "/buoy.instructions.md"), "\n")
        eq(
          argv[3],
          launch_env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS,
          "instructions directory is session-local"
        )
        eq(nil, hooks.sessionStart, "Buoy does not override user session-start context")
        eq(
          require("buoy.instructions").neovim_instructions(config.context),
          guidance,
          "Copilot writes the shared guidance for the active capability configuration"
        )
        eq(editor, hooks.userPromptTransformed ~= nil, "snapshot hook follows capability")
        eq(editor, hooks.postToolUse ~= nil, "refresh hook follows capability")
        if editor then
          eq(
            "create|edit|str_replace_editor|apply_patch",
            hooks.postToolUse[1].matcher,
            "Copilot refresh configuration matches native file mutations and excludes shell tools"
          )
          prompt_hook = hooks.userPromptTransformed[1]
        end
      end
    end
  end
  local allocations_before_relaunch = serial
  local first_argv, env =
    require("buoy.custom.copilot").argv({ cmd = "copilot", context = config.context })
  local previous_dirs = vim.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS
  vim.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS = "/user instructions,/another"
  local repeated_argv, appended =
    require("buoy.custom.copilot").argv({ cmd = "copilot", context = config.context })
  eq(first_argv, repeated_argv, "equal guidance reuses the same plugin directory")
  eq(
    "/user instructions,/another," .. env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS,
    appended.COPILOT_CUSTOM_INSTRUCTIONS_DIRS,
    "existing custom instruction directories are preserved"
  )
  vim.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS = previous_dirs
  eq(allocations_before_relaunch, serial, "repeated launches do not allocate more plugins")
  vim.fn.tempname = original_tempname
  config.context = original_context

  local prompt = "original\n日本語 'quotes' \\ \"double\""
  local output = vim.json.decode(
    run(prompt_hook, vim.json.encode({ prompt = "displayed prompt", transformedPrompt = prompt }))
  ).modifiedTransformedPrompt
  eq(prompt .. "\n\n", output:sub(1, #prompt + 2), "hook output preserves the input prompt")
  assert(
    output:find("Current Neovim editor context %(auto%-refreshed for every prompt%):", 1, false),
    "Copilot maps the shared context text into its transformed-prompt field"
  )
  for _, payload in ipairs({
    "",
    "{",
    "null",
    "[]",
    "{}",
    '{"transformedPrompt":null}',
    '{"transformedPrompt":42}',
    '{"transformedPrompt":""}',
  }) do
    eq("", run(prompt_hook, payload), "invalid events leave the prompt unchanged")
  end
  eq(
    "",
    run(prompt_hook, '{"transformedPrompt":"keep me"}', true),
    "missing socket preserves the original prompt"
  )
  local notices = {}
  vim.notify = function(message)
    notices[#notices + 1] = message
  end
  for _, result in ipairs({
    { code = 0, stdout = "GitHub Copilot CLI 1.0.82." },
    { code = 0, stdout = "unrecognized version" },
    { code = 124, stdout = "" },
  }) do
    version_result = result
    local fallback
    require("buoy.launcher").resolve("copilot", "copilot-custom", temp, function(argv)
      fallback = argv
    end)
    assert(
      vim.wait(1000, function()
        return fallback ~= nil
      end),
      "unsupported launch finishes"
    )
    eq({ "copilot-custom" }, fallback, "unverified clients launch without unsupported hooks")
  end
  eq(3, #notices, "unsupported and timed-out versions each warn")
  assert(notices[1]:find("1.0.83+", 1, true), "warning includes the supported version")
end, debug.traceback)

vim.fn.tempname = original_tempname
vim.notify = original_notify
vim.system = original_system
config.context = original_context
vim.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS = original_dirs
vim.fn.delete(temp, "rf")
if not ok then
  error(err)
end
print("copilot_spec: ok")
