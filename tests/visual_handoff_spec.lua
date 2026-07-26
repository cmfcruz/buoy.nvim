local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Neovim's runtimepath loader outranks package.path, so a system-installed
-- buoy.nvim (e.g. the devtainer's site pack) would shadow the checkout under
-- test. Put the checkout first on the runtimepath and drop any copy a plugin
-- already loaded.
vim.opt.runtimepath:prepend(root)
for name in pairs(package.loaded) do
  if name == "buoy" or name:find("^buoy%.") then
    package.loaded[name] = nil
  end
end

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

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")

local ok, err = xpcall(function()
  -- Stub the launcher so the terminal hosts a quiet long-lived process instead
  -- of a real agent CLI; the focus/mode behavior under test is agent-agnostic.
  package.loaded["buoy.launcher"] = {
    resolve = function(_, _, _, callback)
      callback({ "sleep", "300" })
    end,
  }

  require("buoy").setup({ agent = "claude", cmd = "sleep" })

  local file = temp .. "/main.txt"
  vim.fn.writefile({ "line 1", "line 2", "line 3", "line 4" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  file = vim.api.nvim_buf_get_name(0)
  local source_buf = vim.api.nvim_get_current_buf()

  local terminal = require("buoy.terminal")

  -- Open the agent terminal, then focus back to the editor so the window is
  -- open but unfocused — the state where the visual handoff used to leak.
  terminal.open()
  eq("terminal", vim.bo.buftype, "open() focuses the agent terminal")
  local term_buf = vim.api.nvim_get_current_buf()
  terminal.focus_toggle()
  eq(source_buf, vim.api.nvim_get_current_buf(), "focus_toggle returns to the editor")

  -- Enter linewise visual mode over lines 1-2, then hand off to the already
  -- open terminal exactly as the <F2> x-mode mapping does.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ggVj", true, false, true), "nx", false)
  eq("V", vim.fn.mode(), "precondition: editor is in linewise visual mode")
  terminal.focus_toggle()

  eq(term_buf, vim.api.nvim_get_current_buf(), "handoff focuses the agent terminal")
  truthy(
    not vim.fn.mode():match("[vV\22]"),
    "visual mode must not follow focus into the terminal (mode: " .. vim.fn.mode(1) .. ")"
  )

  -- The handoff selection survives the visual-mode exit and the painted
  -- highlight stays in the source buffer, not the terminal.
  local selection = require("buoy.context").state.selection
  truthy(selection, "handoff selection is preserved across the visual exit")
  eq(file, selection.file, "handoff selection keeps the source file")
  eq(1, selection.start_line, "handoff selection start line")
  eq(2, selection.end_line, "handoff selection end line")

  local ns = vim.api.nvim_get_namespaces()["BuoyContextSelection"]
  truthy(ns, "selection highlight namespace exists")
  eq(
    2,
    #vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, {}),
    "selection highlight is painted in the source buffer"
  )
  eq(
    0,
    #vim.api.nvim_buf_get_extmarks(term_buf, ns, 0, -1, {}),
    "no selection highlight leaks into the terminal buffer"
  )

  -- A charwise handoff highlights exact columns through getregionpos(), a
  -- different path from the whole-line linewise highlight above.
  terminal.focus_toggle()
  eq(source_buf, vim.api.nvim_get_current_buf(), "focus_toggle returns to the editor")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gg0vll", true, false, true), "nx", false)
  eq("v", vim.fn.mode(), "precondition: editor is in charwise visual mode")
  terminal.focus_toggle()

  local charwise = require("buoy.context").state.selection
  eq(1, charwise.start_col, "charwise handoff keeps the start column")
  eq(3, charwise.end_col, "charwise handoff keeps the end column")

  local marks = vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, { details = true })
  eq(1, #marks, "a charwise handoff paints one exact-column highlight")
  eq(0, marks[1][2], "the charwise highlight starts on the selected row")
  eq(0, marks[1][3], "the charwise highlight starts at the selected column")
  eq(3, marks[1][4].end_col, "the charwise highlight ends at the exclusive end column")
end, debug.traceback)

vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("visual_handoff_spec: ok")
