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
  local capabilities = require("buoy.capabilities")

  local all_on = { expose_buffers = true, expose_diagnostics = true, expose_editor_context = true }
  eq(all_on, capabilities.resolve(nil), "resolve(nil) returns every default")
  eq(all_on, capabilities.resolve({}), "resolve({}) returns every default")
  eq(
    { expose_buffers = false, expose_diagnostics = true, expose_editor_context = true },
    capabilities.resolve({ expose_buffers = false }),
    "resolve flips only the provided key"
  )

  -- Drift guard: the registry defaults and the public config.context must stay
  -- in lockstep (same keys, same default values).
  local context_defaults = require("buoy").config.context
  eq(
    capabilities.defaults,
    context_defaults,
    "capabilities.defaults matches the public config.context defaults"
  )

  -- Drift guard: requiring buoy.tools runs its load-time assertion that every
  -- operation's capability tag is a real registry key, so a mistyped capability
  -- would fail here rather than silently never gating its operation.
  truthy(pcall(require, "buoy.tools"), "buoy.tools loads with valid capability tags")
end, debug.traceback)

if not ok then
  error(err)
end

print("capabilities_spec: ok")
