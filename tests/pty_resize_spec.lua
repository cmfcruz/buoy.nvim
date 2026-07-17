local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local RETRY_GROUP = "BuoyContextWindowInoculation"

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

local function retry_count()
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = RETRY_GROUP })
  return ok and #autocmds or 0
end

local function reset_editor()
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

local function terminal_buffer()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_open_term(buf, {})
  return buf
end

local function normal_buffer()
  return vim.api.nvim_create_buf(true, false)
end

local function with_inoculation_spy(fail_first_read, callback)
  local original_create_buf = vim.api.nvim_create_buf
  local original_bo = vim.bo
  local scratches = {}
  local current_buftypes = {}
  local failing_scratch = nil

  vim.api.nvim_create_buf = function(listed, scratch)
    local buf = original_create_buf(listed, scratch)
    if listed == false and scratch == true then
      table.insert(scratches, buf)
      table.insert(current_buftypes, original_bo.buftype)
      if fail_first_read and failing_scratch == nil then
        failing_scratch = buf
      end
    end
    return buf
  end

  if fail_first_read then
    vim.bo = setmetatable({}, {
      __index = function(_, key)
        if key == failing_scratch then
          return setmetatable({}, {
            __index = function()
              error("forced scratch option-read failure")
            end,
          })
        end
        return original_bo[key]
      end,
    })
  end

  local ok, err = xpcall(function()
    callback(scratches, current_buftypes)
  end, debug.traceback)
  vim.bo = original_bo
  vim.api.nvim_create_buf = original_create_buf

  if not ok then
    error(err)
  end
end

local ok, err = xpcall(function()
  local original_serverstart = vim.fn.serverstart
  vim.fn.serverstart = function()
    return "/tmp/buoy-pty-resize-spec.sock"
  end
  vim.env.BUOY_AGENT = nil

  -- A terminal setup can inoculate immediately through another normal window.
  reset_editor()
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, terminal_buffer())
  with_inoculation_spy(false, function(scratches, current_buftypes)
    fresh_buoy().setup({ agent = "codex" })
    eq(1, #scratches, "terminal setup uses one inoculation scratch buffer")
    eq("", current_buftypes[1], "inoculation runs with the normal window current")
    truthy(not vim.api.nvim_buf_is_valid(scratches[1]), "successful scratch buffer is deleted")
    eq(0, retry_count(), "immediate inoculation leaves no retry")
  end)

  -- When every window is a terminal, terminal entries preserve one retry and
  -- the first normal entry completes inoculation exactly once.
  reset_editor()
  vim.api.nvim_win_set_buf(0, terminal_buffer())
  with_inoculation_spy(false, function(scratches, current_buftypes)
    fresh_buoy().setup({ agent = "codex" })
    eq(0, #scratches, "all-terminal setup does not create a scratch buffer")
    eq(1, retry_count(), "all-terminal setup registers one retry")

    vim.api.nvim_win_set_buf(0, terminal_buffer())
    eq(0, #scratches, "another terminal entry does not inoculate")
    eq(1, retry_count(), "another terminal entry preserves the retry")

    vim.api.nvim_win_set_buf(0, normal_buffer())
    eq(1, #scratches, "the first normal entry inoculates")
    eq("", current_buftypes[1], "deferred inoculation runs in a normal window")
    truthy(not vim.api.nvim_buf_is_valid(scratches[1]), "deferred scratch buffer is deleted")
    eq(0, retry_count(), "successful deferred inoculation removes the retry")

    vim.api.nvim_win_set_buf(0, normal_buffer())
    vim.api.nvim_win_set_buf(0, terminal_buffer())
    eq(1, #scratches, "later buffer entries do not inoculate again")
  end)

  -- A failed option read still cleans up its scratch buffer and leaves the
  -- retry alive for a later safe attempt.
  reset_editor()
  with_inoculation_spy(true, function(scratches)
    fresh_buoy().setup({ agent = "codex" })
    eq(1, #scratches, "failed inoculation creates one scratch buffer")
    truthy(not vim.api.nvim_buf_is_valid(scratches[1]), "failed-read scratch buffer is deleted")
    eq(1, retry_count(), "failed inoculation registers a retry")
  end)
  vim.api.nvim_win_set_buf(0, normal_buffer())
  eq(0, retry_count(), "a later normal entry completes the failed inoculation")

  vim.fn.serverstart = original_serverstart
end, debug.traceback)

if not ok then
  error(err)
end

print("pty_resize_spec: ok")
