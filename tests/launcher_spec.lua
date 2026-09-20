local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:prepend(root)

local function eq(expected, actual, label)
  assert(vim.deep_equal(expected, actual), label .. "\n" .. vim.inspect(actual))
end

local original_has = vim.fn.has
local original_notify = vim.notify
local originals = {}
local modules = {}
for _, name in ipairs(require("buoy.agents").order) do
  local module = require("buoy.agents").get(name).module
  modules[name] = module
  originals[module] = package.loaded[module] or false
end

local ok, err = xpcall(function()
  local calls = {}
  for name, module in pairs(modules) do
    local adapter_name = name
    package.loaded[module] = {
      resolve = function(opts, callback)
        calls[#calls + 1] = { name = adapter_name, opts = opts }
        callback({ "resolved", adapter_name }, { BUOY_TEST_AGENT = adapter_name })
      end,
    }
  end
  package.loaded["buoy.launcher"] = nil
  local launcher = require("buoy.launcher")
  local context = require("buoy").config.context
  for _, name in ipairs(require("buoy.agents").order) do
    local argv, env
    launcher.resolve(name, name .. "-custom", "/cwd", function(value, launch_env)
      argv, env = value, launch_env
    end)
    eq({ "resolved", name }, argv, name .. " adapter controls argv")
    eq({ BUOY_TEST_AGENT = name }, env, name .. " adapter controls launch environment")
    eq(
      { cmd = name .. "-custom", cwd = "/cwd", context = context },
      calls[#calls].opts,
      name .. " receives the uniform adapter options"
    )
  end

  local adapter_calls_before_windows = #calls
  local notifications = {}
  vim.fn.has = function(feature)
    return feature == "win32" and 1 or original_has(feature)
  end
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message, level }
  end
  for _, name in ipairs(require("buoy.agents").order) do
    launcher.resolve(name, name .. "-custom", "/cwd", function(argv, env)
      eq({ name .. "-custom" }, argv, "Windows launches " .. name .. " unchanged")
      eq(nil, env, "Windows does not attach an environment for " .. name)
    end)
  end
  eq(1, #notifications, "the shared Windows limitation warns once")
  eq(adapter_calls_before_windows, #calls, "Windows never invokes an agent adapter")
end, debug.traceback)

vim.fn.has = original_has
vim.notify = original_notify
for module, original in pairs(originals) do
  package.loaded[module] = original ~= false and original or nil
end
package.loaded["buoy.launcher"] = nil

if not ok then
  error(err)
end
print("launcher_spec: ok")
