--- MCP tool surface. The bridge calls M.dispatch(name, args) via
--- nvim_exec_lua over the RPC socket. Every handler returns a plain
--- table; the bridge JSON-encodes it into the MCP tool result.

local M = {}

local function ctx()
  return require("buoy.context").state
end

M.tools = {
  {
    name = "get_current_file",
    description = "Path and filetype of the file the user is editing in Neovim. "
      .. "Call this when the user says 'this file', 'the current file', or similar.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
    handler = function()
      return {
        file = ctx().file,
        filetype = ctx().filetype,
        cwd = vim.fn.getcwd(),
      }
    end,
  },
  {
    name = "get_cursor_position",
    description = "The user's cursor position (1-based line and column) plus a few "
      .. "surrounding lines for context. Call this when the user says 'here', "
      .. "'this line', or 'where my cursor is'.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
    handler = function()
      local c = ctx()
      local around = nil
      if c.file and c.cursor then
        local buf = vim.fn.bufnr(c.file)
        if buf ~= -1 then
          local first = math.max(c.cursor.line - 5, 1)
          local lines = vim.api.nvim_buf_get_lines(buf, first - 1, c.cursor.line + 5, false)
          around = { first_line = first, lines = lines }
        end
      end
      return { file = c.file, cursor = c.cursor, surrounding = around }
    end,
  },
  {
    name = "get_buffer_range",
    description = "Lines from a file open in Neovim, by line range, reflecting unsaved "
      .. "edits (unlike reading from disk). Defaults to the file the user is editing. "
      .. "Call this after get_cursor_position to widen the view around the cursor — to "
      .. "pull in the enclosing function, imports, or nearby code.",
    inputSchema = {
      type = "object",
      properties = {
        file = { type = "string", description = "Absolute path; defaults to current file" },
        start_line = { type = "integer", description = "1-based, inclusive" },
        end_line = { type = "integer", description = "1-based, inclusive" },
      },
      required = { "start_line", "end_line" },
    },
    handler = function(args)
      local target = (args and args.file) or ctx().file
      if not target then
        return { error = "No file in context." }
      end
      local buf = vim.fn.bufnr(target)
      if buf == -1 then
        return { error = "File is not open in Neovim: " .. target }
      end
      local first = math.max(args.start_line, 1)
      local lines = vim.api.nvim_buf_get_lines(buf, first - 1, args.end_line, false)
      return { file = target, first_line = first, lines = lines }
    end,
  },
  {
    name = "get_current_selection",
    description = "The user's most recent visual selection in Neovim: file, line range, "
      .. "and the selected text. Call this when the user says 'this code', "
      .. "'the selected/highlighted part', or refers to something without pasting it.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
    handler = function()
      return ctx().selection or { error = "No visual selection has been made yet." }
    end,
  },
  {
    name = "get_open_buffers",
    description = "All files currently open in Neovim (listed buffers).",
    inputSchema = { type = "object", properties = vim.empty_dict() },
    handler = function()
      local out = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buflisted and vim.api.nvim_buf_get_name(buf) ~= "" then
          table.insert(out, {
            file = vim.api.nvim_buf_get_name(buf),
            modified = vim.bo[buf].modified,
          })
        end
      end
      return { buffers = out }
    end,
  },
  {
    name = "get_diagnostics",
    description = "LSP diagnostics (errors/warnings) for the current file, or for the "
      .. "file given in the optional 'file' argument.",
    inputSchema = {
      type = "object",
      properties = { file = { type = "string", description = "Absolute file path" } },
    },
    handler = function(args)
      local target = (args and args.file) or ctx().file
      if not target then
        return { error = "No file in context." }
      end
      local buf = vim.fn.bufnr(target)
      if buf == -1 then
        return { error = "File is not open in Neovim: " .. target }
      end
      local out = {}
      for _, d in ipairs(vim.diagnostic.get(buf)) do
        table.insert(out, {
          line = d.lnum + 1,
          col = d.col + 1,
          severity = vim.diagnostic.severity[d.severity],
          message = d.message,
          source = d.source,
        })
      end
      return { file = target, diagnostics = out }
    end,
  },
}

--- Schema list for MCP tools/list (handlers stripped).
function M.list()
  local out = {}
  for _, t in ipairs(M.tools) do
    table.insert(out, {
      name = t.name,
      description = t.description,
      inputSchema = t.inputSchema,
    })
  end
  return out
end

--- Entry point invoked by the bridge.
function M.dispatch(name, args)
  for _, t in ipairs(M.tools) do
    if t.name == name then
      local ok, result = pcall(t.handler, args)
      if ok then
        return result
      end
      return { error = "Tool failed: " .. tostring(result) }
    end
  end
  return { error = "Unknown tool: " .. tostring(name) }
end

return M
