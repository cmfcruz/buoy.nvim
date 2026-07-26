--- Transport-neutral editor operations. The one-shot agent CLI calls
--- M.dispatch(name, args) via nvim_exec_lua over the RPC socket. Dispatch
--- validates the operation arguments, and operation results are bounded so
--- their encoded JSON stays small.

local M = {}

local MAX_LINES = 500
local MAX_DIAGNOSTICS = 200
local MAX_RESULT_BYTES = 24576

local function ctx()
  return require("buoy.context").state
end

local function config()
  return require("buoy").config
end

local err = require("buoy.error")
local capabilities = require("buoy.capabilities")

local function is_pos_int(value)
  return type(value) == "number" and value >= 1 and value % 1 == 0
end

--- Resolve the target buffer for a read: explicit absolute `file` argument,
--- else the user's current file. Returns (buf, nil, path) or (nil, error).
local function resolve_buffer(args)
  local target = args.file
  if target ~= nil then
    if type(target) ~= "string" or target:sub(1, 1) ~= "/" then
      return nil, err("INVALID_ARGUMENT", "file must be an absolute path.")
    end
  else
    target = ctx().file
    if not target then
      return nil, err("NO_FILE_IN_CONTEXT", "No file argument and no current file in context.")
    end
  end
  target = vim.fn.fnamemodify(target, ":p")
  local buf = vim.fn.bufnr(target)
  if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
    return nil, err("BUFFER_NOT_OPEN", "File is not open in Neovim.")
  end
  return buf, nil, target
end

--- Enforce the encoded-byte bound: drop trailing entries from result[key]
--- until the JSON encoding fits, refreshing continuation fields via `update`.
--- Returns the bounded result, or a structured encoding or output-limit error.
local function bound(result, key, update)
  local ok, encoded = pcall(vim.json.encode, result)
  local dropped = false
  while ok and #encoded > MAX_RESULT_BYTES and #result[key] > 0 do
    table.remove(result[key])
    update(result)
    dropped = true
    ok, encoded = pcall(vim.json.encode, result)
  end
  if not ok then
    return err("ENCODING_ERROR", "Result could not be encoded as JSON.")
  end
  if #encoded > MAX_RESULT_BYTES or (dropped and #result[key] == 0) then
    return err("OUTPUT_LIMIT", "A single result record exceeds the output limit.")
  end
  return result
end

function M.editor_context()
  local c = ctx()
  local has_current = c.file ~= nil
  local current = {
    file = c.file or vim.NIL,
    filetype = (has_current and c.filetype) or vim.NIL,
    cursor = (has_current and c.cursor) or vim.NIL,
  }

  -- Use getbufinfo() instead of reading vim.bo[] for every listed buffer.
  -- Option reads on non-current buffers can switch buffer context and trigger
  -- the terminal resize bug this snapshot must avoid.
  local buffers = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if info.name ~= "" then
      table.insert(buffers, {
        file = info.name,
        modified = info.changed == 1,
      })
    end
  end

  return {
    cwd = vim.fn.getcwd(),
    current = current,
    selection = c.selection or vim.NIL,
    buffers = buffers,
  }
end

local operations = {
  {
    name = "get_buffer_range",
    args = { file = true, start_line = true, end_line = true },
    capability = "expose_buffers",
    handler = function(args)
      if not is_pos_int(args.start_line) or not is_pos_int(args.end_line) then
        return err("INVALID_ARGUMENT", "start_line and end_line must be positive integers.")
      end
      if args.start_line > args.end_line then
        return err("INVALID_ARGUMENT", "start_line must not exceed end_line.")
      end
      local buf, e, target = resolve_buffer(args)
      if not buf then
        return e
      end
      local first = args.start_line
      local capped = math.min(args.end_line, first + MAX_LINES - 1)
      local lines = vim.api.nvim_buf_get_lines(buf, first - 1, capped, false)
      local truncated = capped < args.end_line and vim.api.nvim_buf_line_count(buf) > capped
      local result = {
        kind = "buffer_range",
        file = target,
        first_line = first,
        last_line = #lines > 0 and (first + #lines - 1) or vim.NIL,
        lines = lines,
        truncated = truncated,
        next_start_line = truncated and (capped + 1) or vim.NIL,
      }
      return bound(result, "lines", function(r)
        r.truncated = true
        r.next_start_line = first + #r.lines
        r.last_line = #r.lines > 0 and (first + #r.lines - 1) or vim.NIL
      end)
    end,
  },
  {
    name = "get_diagnostics",
    args = { file = true, offset = true },
    capability = "expose_diagnostics",
    handler = function(args)
      local offset = args.offset or 0
      if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 then
        return err("INVALID_ARGUMENT", "offset must be a non-negative integer.")
      end
      local buf, e, target = resolve_buffer(args)
      if not buf then
        return e
      end
      local all = vim.diagnostic.get(buf)
      table.sort(all, function(a, b)
        if a.lnum ~= b.lnum then
          return a.lnum < b.lnum
        end
        return a.col < b.col
      end)
      local out = {}
      for i = offset + 1, math.min(#all, offset + MAX_DIAGNOSTICS) do
        local d = all[i]
        table.insert(out, {
          line = d.lnum + 1,
          col = d.col + 1,
          severity = vim.diagnostic.severity[d.severity],
          message = d.message,
          source = d.source,
        })
      end
      local truncated = offset + #out < #all
      local result = {
        kind = "diagnostics",
        file = target,
        offset = offset,
        diagnostics = out,
        truncated = truncated,
        next_offset = truncated and (offset + #out) or vim.NIL,
      }
      return bound(result, "diagnostics", function(r)
        r.truncated = true
        r.next_offset = offset + #r.diagnostics
      end)
    end,
  },
  {
    name = "set_cursor_position",
    args = { file = true, line = true, col = true },
    handler = function(args)
      if not is_pos_int(args.line) then
        return err("INVALID_ARGUMENT", "line must be a positive integer.")
      end
      if args.col ~= nil and not is_pos_int(args.col) then
        return err("INVALID_ARGUMENT", "col must be a positive integer.")
      end
      if args.file ~= nil and (type(args.file) ~= "string" or args.file:sub(1, 1) ~= "/") then
        return err("INVALID_ARGUMENT", "file must be an absolute path.")
      end
      return require("buoy.navigate").set_cursor_position(args)
    end,
  },
}

-- Fail fast on a mistyped capability key: a name absent from the registry
-- would silently never gate its operation.
for _, t in ipairs(operations) do
  assert(
    t.capability == nil or capabilities.defaults[t.capability] ~= nil,
    "buoy.tools: unknown capability " .. tostring(t.capability)
  )
end

--- Dispatch one of the three editor operations requested by the agent CLI.
function M.dispatch(name, args)
  for _, t in ipairs(operations) do
    if t.name == name then
      if t.capability and not config().context[t.capability] then
        return err("CAPABILITY_DISABLED", "This capability is disabled by buoy configuration.")
      end
      if args == nil then
        args = {}
      elseif type(args) ~= "table" then
        return err("INVALID_ARGUMENT", "Arguments must be an object.")
      end
      for key in pairs(args) do
        if not t.args[key] then
          return err("INVALID_ARGUMENT", "Unknown argument.")
        end
      end
      local ok, result = pcall(t.handler, args)
      if ok then
        return result
      end
      return err("EDITOR_OPERATION_FAILED", "Editor operation failed.")
    end
  end
  return err("INVALID_OPERATION", "Unknown operation.")
end

return M
