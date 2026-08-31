local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:prepend(root)

local function fail(message)
  error(message, 2)
end

local function truthy(value, label)
  if not value then
    fail(label or "expected a truthy value")
  end
end

local function eq(expected, actual, label)
  if expected ~= actual then
    fail(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function fresh_buoy()
  package.loaded["buoy"] = nil
  return require("buoy")
end

local ok, err = xpcall(function()
  local original_schedule = vim.schedule
  -- Keep automatic startup callbacks deterministic in this configuration-only
  -- spec; startup behavior has dedicated coverage in auto_open_spec.lua.
  vim.schedule = function() end

  local original_has = vim.fn.has
  vim.fn.has = function(feature)
    if feature == "nvim-0.11" then
      return 0
    end
    return original_has(feature)
  end
  local version_ok, version_err = pcall(fresh_buoy)
  vim.fn.has = original_has
  truthy(not version_ok, "Neovim older than 0.11 is rejected")
  truthy(
    tostring(version_err):find("requires Neovim 0.11 or newer", 1, true),
    "the minimum-version error is actionable"
  )

  local original_serverstart = vim.fn.serverstart
  vim.fn.serverstart = function()
    return "/tmp/buoy-setup-spec.sock"
  end
  local original_executable = vim.fn.executable
  local executables = { claude = 1, codex = 1, pi = 1 }
  vim.fn.executable = function(cmd)
    return executables[cmd] or 0
  end
  local original_notify = vim.notify
  local notices = {}
  vim.notify = function(msg)
    table.insert(notices, msg)
  end
  vim.env.BUOY_AGENT = nil

  -- The first setup applies a partial configuration over the defaults.
  local buoy = fresh_buoy()
  buoy.setup({ agent = "codex", window = { width = 100 } })
  eq("codex", buoy.config.agent, "explicit agent is applied")
  eq("codex", buoy.config.cmd, "cmd derives from the selected preset")
  eq(" Codex ", buoy.config.title, "title derives from the selected preset")
  eq(100, buoy.config.window.width, "partial window options apply over defaults")
  eq("rounded", buoy.config.window.border, "unspecified options keep their defaults")
  eq(true, buoy.config.startup.open, "startup opens by default")
  eq(true, buoy.config.startup.message, "the startup reminder defaults on")

  -- Later setup calls cannot change a running Neovim session.
  buoy.setup({ agent = "claude" })
  eq("codex", buoy.config.agent, "a second setup() is ignored")
  eq("codex", buoy.config.cmd, "an ignored setup does not retain another agent's command")
  eq(" Codex ", buoy.config.title, "an ignored setup does not retain another agent's title")
  eq(1, #notices, "the ignored call notifies the user")
  buoy.ensure_setup()
  eq(1, #notices, "ensure_setup() after setup stays silent")

  -- Zero-config setup prefers Claude when both supported agents are installed
  -- and is also final for the session.
  buoy = fresh_buoy()
  buoy.ensure_setup()
  eq("claude", buoy.config.agent, "automatic setup prefers Claude")
  buoy.setup({ agent = "codex" })
  eq("claude", buoy.config.agent, "explicit setup cannot replace zero-config setup")
  eq(2, #notices, "reconfiguring zero-config setup notifies the user")

  -- Automatic setup falls back to Codex, then Pi, then to Claude's command when
  -- no supported CLI exists so opening the window can report the missing executable.
  executables.claude = 0
  buoy = fresh_buoy()
  buoy.ensure_setup()
  eq("codex", buoy.config.agent, "automatic setup falls back to Codex")

  executables.codex = 0
  buoy = fresh_buoy()
  buoy.ensure_setup()
  eq("pi", buoy.config.agent, "automatic setup falls back to Pi")

  executables.pi = 0
  buoy = fresh_buoy()
  buoy.ensure_setup()
  eq("claude", buoy.config.agent, "automatic setup falls back to the Claude command")

  -- An explicit cmd stays an override; the preset only fills the gap.
  buoy = fresh_buoy()
  buoy.setup({ agent = "claude", cmd = "claude-dev" })
  eq("claude-dev", buoy.config.cmd, "explicit cmd overrides the preset")
  eq(" Claude Code ", buoy.config.title, "title still derives from the preset")

  buoy = fresh_buoy()
  buoy.setup({ agent = "pi" })
  eq("pi", buoy.config.agent, "Pi can be selected explicitly")
  eq("pi", buoy.config.cmd, "Pi cmd derives from the selected preset")
  eq(" Pi ", buoy.config.title, "Pi title derives from the selected preset")

  -- A rejected config leaves automatic startup free to apply valid defaults.
  buoy = fresh_buoy()
  truthy(not pcall(buoy.setup, { agent = "nope" }), "unknown agent is rejected")
  truthy(not buoy._did_setup, "a rejected config leaves setup unlocked")
  buoy.ensure_setup()
  truthy(buoy._did_setup, "automatic startup applies after a rejected config")
  eq("claude", buoy.config.agent, "automatic startup resolves the deterministic fallback")

  -- Invalid startup switches fail before the one-shot setup lock is set, so a
  -- corrected call can still apply.
  buoy = fresh_buoy()
  truthy(
    not pcall(buoy.setup, { startup = { open = "yes" } }),
    "a non-boolean startup.open is rejected"
  )
  truthy(not buoy._did_setup, "invalid startup.open leaves setup unlocked")
  truthy(
    not pcall(buoy.setup, { startup = { message = 1 } }),
    "a non-boolean startup.message is rejected"
  )
  truthy(not buoy._did_setup, "invalid startup.message leaves setup unlocked")
  buoy.setup({ startup = { open = false, message = false } })
  eq(false, buoy.config.startup.open, "a corrected startup.open is applied")
  eq(false, buoy.config.startup.message, "a corrected startup.message is applied")

  -- window.width is a fixed column count: it must be a whole number of at least
  -- 40, so a too-small integer and a non-integer both fail while a valid integer
  -- width completes setup.
  buoy = fresh_buoy()
  truthy(not pcall(buoy.setup, { window = { width = 10 } }), "width below 40 is rejected")
  truthy(not buoy._did_setup, "a rejected width leaves setup unlocked")

  buoy = fresh_buoy()
  truthy(not pcall(buoy.setup, { window = { width = 0.4 } }), "a non-integer width is rejected")
  truthy(not buoy._did_setup, "a rejected non-integer width leaves setup unlocked")

  buoy = fresh_buoy()
  truthy(pcall(buoy.setup, { window = { width = 40 } }), "a valid width completes setup")
  eq(40, buoy.config.window.width, "the valid width is applied")

  -- setup() installs the configured agent keymaps, including the traditional
  -- terminfo alias for shifted function keys, and `false` installs none.
  -- Mappings outlive a fresh_buoy(), so clear them before each check.
  local function unmap(lhs)
    pcall(vim.keymap.del, { "n", "x", "t" }, lhs)
  end
  local function mapping(lhs)
    return vim.fn.maparg(lhs, "n", false, true)
  end

  unmap("<F2>")
  unmap("<S-F2>")
  unmap("<F14>")
  buoy = fresh_buoy()
  buoy.setup({ agent = "codex" })
  truthy(not vim.tbl_isempty(mapping("<F2>")), "setup installs the primary keymap")
  truthy(not vim.tbl_isempty(mapping("<S-F2>")), "setup installs the secondary keymap")
  truthy(not vim.tbl_isempty(mapping("<F14>")), "setup installs the shifted-key alias")

  unmap("<F2>")
  unmap("<S-F2>")
  unmap("<F14>")
  unmap("<S-F3>")
  unmap("<F15>")
  local original_terminal = package.loaded["buoy.terminal"]
  local secondary_calls = 0
  package.loaded["buoy.terminal"] = {
    on_secondary = function()
      secondary_calls = secondary_calls + 1
    end,
  }
  buoy = fresh_buoy()
  buoy.setup({ agent = "codex", keymaps = { primary = false, secondary = "<S-F3>" } })
  truthy(not vim.tbl_isempty(mapping("<S-F3>")), "a shifted function key is installed")
  truthy(not vim.tbl_isempty(mapping("<F15>")), "its traditional terminfo alias is installed")
  vim.api.nvim_feedkeys(vim.keycode("<S-F3>"), "mx", false)
  vim.api.nvim_feedkeys(vim.keycode("<F15>"), "mx", false)
  eq(2, secondary_calls, "both shifted-key representations invoke the secondary action")
  package.loaded["buoy.terminal"] = original_terminal

  unmap("<S-F3>")
  unmap("<F15>")
  unmap("<F9>")
  unmap("<F21>")
  buoy = fresh_buoy()
  buoy.setup({ agent = "codex", keymaps = { primary = false, secondary = "<F9>" } })
  truthy(vim.tbl_isempty(mapping("<F2>")), "a false primary installs no mapping")
  truthy(not vim.tbl_isempty(mapping("<F9>")), "a custom secondary key is installed")
  truthy(vim.tbl_isempty(mapping("<F21>")), "an unshifted function key gains no alias")
  unmap("<F9>")

  buoy = fresh_buoy()
  buoy.setup({ agent = "codex", keymaps = { primary = false, secondary = false } })
  truthy(vim.tbl_isempty(mapping("<F14>")), "a false secondary installs no compatibility alias")

  vim.notify = original_notify
  vim.fn.executable = original_executable
  vim.fn.serverstart = original_serverstart
  vim.schedule = original_schedule
end, debug.traceback)

if not ok then
  error(err)
end

print("setup_spec: ok")
