local M = {}

local protocol = require("buoy.custom.codex_protocol")

local function append_instructions(existing, additional)
  if type(existing) == "string" and existing ~= "" then
    return existing .. "\n\n" .. additional
  end
  return additional
end

-- Render a TOML basic string. vim.json.encode() is the wrong boundary here:
-- Codex parses the value as TOML, whose valid escapes are narrower than JSON's.
local function toml_basic_string(s)
  local shorthand = {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["\b"] = "\\b",
    ["\t"] = "\\t",
    ["\n"] = "\\n",
    ["\f"] = "\\f",
    ["\r"] = "\\r",
  }
  local escaped = s:gsub('[%z\1-\31\127"\\]', function(c)
    return shorthand[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

local function build_argv(cmd, developer_instructions, integration)
  local argv = { cmd }
  if developer_instructions then
    vim.list_extend(argv, {
      "-c",
      "developer_instructions=" .. toml_basic_string(developer_instructions),
    })
  end
  if integration.context_hook then
    vim.list_extend(argv, {
      "-c",
      'hooks.UserPromptSubmit=[{hooks=[{type="command",command=' .. toml_basic_string(
        integration.context_hook
      ) .. ",timeout=10}]}]",
      "-c",
      'hooks.PostToolUse=[{matcher="Edit|Write",hooks=[{type="command",command='
        .. toml_basic_string(integration.post_tool_hook)
        .. ",timeout=10}]}]",
    })
  end
  return argv
end

function M.argv(opts, developer_instructions)
  return build_argv(
    opts.cmd,
    developer_instructions,
    require("buoy.instructions").integration(opts.context)
  )
end

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

function M.resolve_instructions(cmd, cwd, callback)
  local transport = spawn_transport(cmd, cwd)
  if not transport then
    vim.schedule(function()
      callback("could not start Codex app-server")
    end)
    return
  end
  protocol(transport, cwd, callback)
end

function M.resolve(opts, callback)
  local integration = require("buoy.instructions").integration(opts.context)
  M.resolve_instructions(opts.cmd, opts.cwd, function(err, existing)
    if err then
      vim.notify(
        "buoy: "
          .. err
          .. "; on-demand live editor operations are unavailable for this Codex session",
        vim.log.levels.WARN
      )
      callback(build_argv(opts.cmd, nil, integration))
      return
    end
    callback(build_argv(opts.cmd, append_instructions(existing, integration.guidance), integration))
  end)
end

return M
