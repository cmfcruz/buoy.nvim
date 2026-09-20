local TIMEOUT_MS = 2000

return function(transport, cwd, callback, timeout_ms)
  local done = false
  local initialized = false
  local buffer = ""

  local function finish(err, instructions)
    if done then
      return
    end
    done = true
    transport:cleanup()
    callback(err, instructions)
  end

  local function send(message)
    local ok, encoded = pcall(vim.json.encode, message)
    if not ok then
      finish("could not encode app-server request")
      return false
    end
    transport:write(encoded .. "\n")
    return true
  end

  transport:on_exit(function()
    finish("app-server exited before returning Codex configuration")
  end)

  transport:on_timeout(timeout_ms or TIMEOUT_MS, function()
    finish("timed out reading Codex configuration")
  end)

  transport:on_data(function(chunk)
    if done then
      return
    end
    buffer = buffer .. chunk
    local newline = buffer:find("\n", 1, true)
    while newline do
      local line = buffer:sub(1, newline - 1)
      buffer = buffer:sub(newline + 1)
      if line ~= "" then
        local ok, message = pcall(vim.json.decode, line)
        if not ok or type(message) ~= "table" then
          finish("app-server returned malformed JSON")
          return
        end
        if message.id == 1 then
          if message.error or type(message.result) ~= "table" then
            finish("Codex app-server initialization failed")
            return
          end
          initialized = true
          if not send({ method = "initialized", params = {} }) then
            return
          end
          if
            not send({
              id = 2,
              method = "config/read",
              params = { cwd = cwd, includeLayers = false },
            })
          then
            return
          end
        elseif message.id == 2 then
          if not initialized or message.error then
            finish("Codex config/read failed")
            return
          end
          local result = message.result
          local config = type(result) == "table" and result.config or nil
          if type(config) ~= "table" then
            finish("Codex config/read returned an invalid result")
            return
          end
          local value = config.developer_instructions
          if value ~= nil and value ~= vim.NIL and type(value) ~= "string" then
            finish("Codex config/read returned invalid developer instructions")
            return
          end
          finish(nil, value == vim.NIL and nil or value)
          return
        end
      end
      newline = buffer:find("\n", 1, true)
    end
  end)

  send({
    id = 1,
    method = "initialize",
    params = {
      clientInfo = {
        name = "buoy_nvim",
        title = "buoy.nvim",
        version = "0.1.0",
      },
    },
  })
end
