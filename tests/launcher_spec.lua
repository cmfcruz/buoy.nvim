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

local original_codex = package.loaded["buoy.codex"]
local original_notify = vim.notify
local original_has = vim.fn.has

local ok, err = xpcall(function()
  local instructions = require("buoy.instructions")
  local hook_command = instructions.hook_command()
  local notifications = {}
  local resolution_attempts = 0
  package.loaded["buoy.codex"] = {
    resolve = function(_, _, callback)
      resolution_attempts = resolution_attempts + 1
      callback("unsupported API")
    end,
  }
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message, level }
  end
  local launches = {}
  require("buoy.launcher").resolve("codex", "codex", "/cwd", function(argv)
    launches[#launches + 1] = argv
  end)
  package.loaded["buoy.codex"] = original_codex
  vim.notify = original_notify
  eq({
    instructions.codex_argv("codex", nil, hook_command),
  }, launches, "degraded Codex launch preserves the prompt hook without private CLI guidance")
  eq(1, resolution_attempts, "Codex configuration resolution is attempted exactly once")
  eq(1, #notifications, "fallback warns")
  truthy(
    notifications[1][1]:find("on%-demand live editor operations are unavailable"),
    "fallback warning describes the degraded session honestly"
  )

  local resolved_launches = {}
  package.loaded["buoy.codex"] = {
    resolve = function(_, _, callback)
      callback(nil, "existing guidance")
    end,
  }
  require("buoy.launcher").resolve("codex", "codex", "/cwd", function(argv)
    resolved_launches[#resolved_launches + 1] = argv
  end)
  package.loaded["buoy.codex"] = original_codex
  eq({
    instructions.codex_argv(
      "codex",
      instructions.append_instructions("existing guidance", instructions.neovim_instructions()),
      hook_command
    ),
  }, resolved_launches, "resolved Codex launch preserves effective guidance and attaches Buoy")

  local claude_launches = {}
  require("buoy.launcher").resolve("claude", "claude", "/cwd", function(argv)
    claude_launches[#claude_launches + 1] = argv
  end)
  eq(1, #claude_launches, "Claude launches exactly once")
  eq(
    instructions.claude_argv("claude", instructions.neovim_instructions(), hook_command),
    claude_launches[1],
    "Claude launch uses the complete inline argv"
  )

  notifications = {}
  launches = {}
  package.loaded["buoy.codex"] = {
    resolve = function()
      fail("Windows must not attempt Codex configuration resolution")
    end,
  }
  vim.fn.has = function(feature)
    if feature == "win32" then
      return 1
    end
    return original_has(feature)
  end
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message, level }
  end
  for _ = 1, 2 do
    require("buoy.launcher").resolve("codex", "codex", "/cwd", function(argv)
      launches[#launches + 1] = argv
    end)
  end
  vim.fn.has = original_has
  vim.notify = original_notify
  package.loaded["buoy.codex"] = original_codex
  eq({ { "codex" }, { "codex" } }, launches, "Windows launches the terminal command unchanged")
  eq(1, #notifications, "Windows live-context limitation warns once")
end, debug.traceback)

package.loaded["buoy.codex"] = original_codex
vim.notify = original_notify
vim.fn.has = original_has

if not ok then
  error(err)
end

print("launcher_spec: ok")
