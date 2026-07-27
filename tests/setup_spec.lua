local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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
  local executables = { claude = 1, codex = 1 }
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

  -- Automatic setup falls back to Codex, then to Claude's command when neither
  -- CLI exists so opening the window can report the missing executable.
  executables.claude = 0
  buoy = fresh_buoy()
  buoy.ensure_setup()
  eq("codex", buoy.config.agent, "automatic setup falls back to Codex")

  executables.codex = 0
  buoy = fresh_buoy()
  buoy.ensure_setup()
  eq("claude", buoy.config.agent, "automatic setup falls back to the Claude command")

  -- An explicit cmd stays an override; the preset only fills the gap.
  buoy = fresh_buoy()
  buoy.setup({ agent = "claude", cmd = "claude-dev" })
  eq("claude-dev", buoy.config.cmd, "explicit cmd overrides the preset")
  eq(" Claude Code ", buoy.config.title, "title still derives from the preset")

  -- A rejected config leaves automatic startup free to apply valid defaults.
  buoy = fresh_buoy()
  truthy(not pcall(buoy.setup, { agent = "nope" }), "unknown agent is rejected")
  truthy(not buoy._did_setup, "a rejected config leaves setup unlocked")
  buoy.ensure_setup()
  truthy(buoy._did_setup, "automatic startup applies after a rejected config")
  eq("claude", buoy.config.agent, "automatic startup resolves the deterministic fallback")

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

  -- setup() installs the configured agent keymaps, and `false` installs none.
  -- Mappings outlive a fresh_buoy(), so clear them before each check.
  local function unmap(lhs)
    pcall(vim.keymap.del, { "n", "x", "t" }, lhs)
  end
  local function mapping(lhs)
    return vim.fn.maparg(lhs, "n", false, true)
  end

  unmap("<F2>")
  unmap("<S-F2>")
  buoy = fresh_buoy()
  buoy.setup({ agent = "codex" })
  truthy(not vim.tbl_isempty(mapping("<F2>")), "setup installs the primary keymap")
  truthy(not vim.tbl_isempty(mapping("<S-F2>")), "setup installs the secondary keymap")

  unmap("<F2>")
  unmap("<S-F2>")
  buoy = fresh_buoy()
  buoy.setup({ agent = "codex", keymaps = { primary = false, secondary = "<F9>" } })
  truthy(vim.tbl_isempty(mapping("<F2>")), "a false primary installs no mapping")
  truthy(not vim.tbl_isempty(mapping("<F9>")), "a custom secondary key is installed")
  unmap("<F9>")

  vim.notify = original_notify
  vim.fn.executable = original_executable
  vim.fn.serverstart = original_serverstart
end, debug.traceback)

if not ok then
  error(err)
end

print("setup_spec: ok")
