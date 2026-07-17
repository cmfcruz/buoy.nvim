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

local function fake_transport()
  local transport = {
    writes = {},
    cleanups = 0,
  }

  function transport:on_exit(callback)
    self.exit_callback = callback
  end

  function transport:on_timeout(_, callback)
    self.timeout_callback = callback
  end

  function transport:on_data(callback)
    self.data_callback = callback
  end

  function transport:write(data)
    self.writes[#self.writes + 1] = vim.json.decode(data)
  end

  function transport:cleanup()
    self.cleanups = self.cleanups + 1
  end

  return transport
end

local function run_protocol()
  local transport = fake_transport()
  local calls = {}
  require("buoy.codex_protocol")(transport, "/work/tree", function(err, value)
    calls[#calls + 1] = { err = err, value = value }
  end, 25)
  return transport, calls
end

local ok, err = xpcall(function()
  local transport, calls = run_protocol()
  eq("initialize", transport.writes[1].method, "initialization is sent first")
  transport.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
  eq("initialized", transport.writes[2].method, "initialization is acknowledged")
  eq("config/read", transport.writes[3].method, "effective config is requested")
  eq(
    { cwd = "/work/tree", includeLayers = false },
    transport.writes[3].params,
    "config resolution uses Neovim's cwd"
  )
  transport.data_callback(vim.json.encode({
    id = 2,
    result = { config = { developer_instructions = "keep me" } },
  }) .. "\n")
  eq({ { value = "keep me" } }, calls, "effective developer instructions are extracted")
  eq(1, transport.cleanups, "successful resolution cleans up")

  for _, value in ipairs({ "", vim.NIL }) do
    transport, calls = run_protocol()
    transport.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
    transport.data_callback(vim.json.encode({
      id = 2,
      result = { config = { developer_instructions = value } },
    }) .. "\n")
    local expected = value == vim.NIL and nil or value
    eq(expected, calls[1].value, "empty and null instructions are accepted")
    eq(1, transport.cleanups, "empty and null responses clean up")
  end

  local failures = {
    function(t)
      t.data_callback("{nope}\n")
    end,
    function(t)
      t.data_callback(vim.json.encode({ id = 1, error = { message = "no" } }) .. "\n")
    end,
    function(t)
      t.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
      t.data_callback(vim.json.encode({ id = 2, error = { message = "no" } }) .. "\n")
    end,
    function(t)
      t.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
      t.data_callback(vim.json.encode({ id = 2, result = {} }) .. "\n")
    end,
    function(t)
      t.exit_callback()
    end,
    function(t)
      t.timeout_callback()
    end,
  }
  for _, trigger in ipairs(failures) do
    transport, calls = run_protocol()
    trigger(transport)
    truthy(calls[1].err, "failure returns an error")
    eq(1, #calls, "failure callback runs exactly once")
    eq(1, transport.cleanups, "failure cleans up")
    transport.exit_callback()
    eq(1, #calls, "late process exit does not call back again")
  end
end, debug.traceback)

if not ok then
  error(err)
end

print("codex_spec: ok")
