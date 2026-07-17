local M = {}

local protocol = require("buoy.codex_protocol")

local function spawn_transport(cmd, cwd)
  local job_id
  local data_callback
  local exit_callback
  local cleaned = false

  local transport = {}

  function transport:on_exit(callback)
    exit_callback = callback
  end

  function transport:on_data(callback)
    data_callback = callback
  end

  function transport:on_timeout(ms, callback)
    vim.defer_fn(callback, ms)
  end

  function transport:write(data)
    if job_id and job_id > 0 and not cleaned then
      vim.fn.chansend(job_id, data)
    end
  end

  function transport:cleanup()
    if cleaned then
      return
    end
    cleaned = true
    if job_id and job_id > 0 then
      vim.fn.jobstop(job_id)
    end
  end

  job_id = vim.fn.jobstart({ cmd, "app-server", "--stdio" }, {
    cwd = cwd,
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data_callback and data and #data > 0 then
        local chunk = table.concat(data, "\n")
        if chunk ~= "" then
          data_callback(chunk)
        end
      end
    end,
    -- The app-server may emit tracing or startup warnings. Drain them so a noisy
    -- stderr cannot fill its pipe and stall the short-lived config request.
    on_stderr = function() end,
    on_exit = function()
      cleaned = true
      if exit_callback then
        exit_callback()
      end
    end,
  })

  if job_id <= 0 then
    return nil
  end

  return transport
end

function M.resolve(cmd, cwd, callback)
  local transport = spawn_transport(cmd, cwd)
  if not transport then
    vim.schedule(function()
      callback("could not start Codex app-server")
    end)
    return
  end
  protocol(transport, cwd, callback)
end

return M
