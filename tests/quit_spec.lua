local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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

local function agent_win(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

local function ordinary_wins(buf)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) ~= buf and vim.api.nvim_win_get_config(win).relative == "" then
      wins[#wins + 1] = win
    end
  end
  return wins
end

local ok, err = xpcall(function()
  vim.o.lines = 40
  vim.o.columns = 220
  vim.wait(60)

  local config = {
    agent = "codex",
    cmd = vim.o.shell,
    title = " Test ",
    window = { style = "vsplit", width = 80, border = "rounded", stay = false },
  }
  package.loaded["buoy"] = {
    config = config,
    socket = "/tmp/buoy-quit-spec.sock",
    ensure_setup = function() end,
  }
  package.loaded["buoy.context"] = {
    selection = nil,
    paint_selection = function() end,
    clear_selection = function() end,
  }
  package.loaded["buoy.launcher"] = {
    resolve = function(_agent, cmd, _cwd, callback)
      callback({ cmd })
    end,
  }

  local original_termopen = vim.fn.termopen
  vim.fn.termopen = function(_, _opts)
    return vim.api.nvim_open_term(0, {})
  end

  local terminal = require("buoy.terminal")
  local code_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { "unsaved" })
  vim.bo[code_buf].modified = true

  terminal.open()
  local term_buf = vim.api.nvim_get_current_buf()
  truthy(
    vim.wait(100, function()
      return vim.bo[term_buf].buftype == "terminal"
    end),
    "opening starts a terminal session"
  )
  local code_win = ordinary_wins(term_buf)[1]
  vim.api.nvim_set_current_win(code_win)

  -- QuitPre hides the nonessential agent first, so :q sees the modified code
  -- window as Neovim's last window and rejects the quit normally. Because that
  -- code window survives, the scheduled check restores the unchanged layout.
  local quit_ok, quit_err = pcall(vim.cmd, "quit")
  truthy(not quit_ok and tostring(quit_err):find("E37", 1, true), ":q preserves the E37 error")
  truthy(
    vim.wait(100, function()
      return agent_win(term_buf) ~= nil
    end),
    ":q restores the agent after the blocked quit"
  )
  eq(code_win, vim.api.nvim_get_current_win(), ":q leaves the modified code window focused")
  eq(code_buf, vim.api.nvim_get_current_buf(), ":q leaves the modified code buffer displayed")
  truthy(vim.api.nvim_buf_is_valid(term_buf), ":q preserves the terminal session")
  eq(2, #vim.api.nvim_tabpage_list_wins(0), ":q restores the original two-window layout")

  -- :close has no QuitPre. The WinClosed fallback tries to quit the stranded
  -- agent; when E37 rejects that quit, it restores the buffer that just closed.
  terminal.open()
  code_win = ordinary_wins(term_buf)[1]
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("close")
  truthy(
    vim.wait(100, function()
      return agent_win(term_buf) ~= nil and vim.api.nvim_get_current_buf() == code_buf
    end),
    ":close restores the modified code buffer after the deferred quit fails"
  )
  eq(2, #vim.api.nvim_tabpage_list_wins(0), ":close recovery restores the two-window layout")

  -- API-driven closure follows the same fallback path.
  code_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(code_win, false)
  truthy(
    vim.wait(100, function()
      return agent_win(term_buf) ~= nil and vim.api.nvim_get_current_buf() == code_buf
    end),
    "API window closure restores the modified code buffer"
  )
  eq(2, #vim.api.nvim_tabpage_list_wins(0), "API recovery restores the two-window layout")

  -- With another ordinary code window present, :q may close one normally and
  -- neither guard should disturb the agent.
  vim.cmd("vnew")
  local extra_code = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "extra unsaved buffer" })
  vim.bo.modified = true
  local multi_ok, multi_err = pcall(vim.cmd, "quit")
  truthy(multi_ok, "multiple code windows permit :q: " .. tostring(multi_err))
  truthy(not vim.api.nvim_win_is_valid(extra_code), ":q closes only the selected code window")
  truthy(agent_win(term_buf) ~= nil, ":q with another code window leaves the agent visible")
  eq(2, #vim.api.nvim_tabpage_list_wins(0), "the agent and original code window remain")

  -- Forced quit closes the tab after QuitPre hides the agent, but the terminal
  -- buffer remains available to reopen in another tab.
  local forced_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local sentinel_tab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(forced_tab)
  code_win = ordinary_wins(term_buf)[1]
  vim.api.nvim_set_current_win(code_win)
  local force_ok, force_err = pcall(vim.cmd, "quit!")
  truthy(force_ok, ":q! closes the code tab: " .. tostring(force_err))
  truthy(not vim.api.nvim_tabpage_is_valid(forced_tab), ":q! removes the original tab")
  eq(sentinel_tab, vim.api.nvim_get_current_tabpage(), ":q! returns to the other tab")
  truthy(agent_win(term_buf) == nil, ":q! leaves the agent hidden")
  truthy(vim.api.nvim_buf_is_valid(term_buf), ":q! preserves the terminal session")
  terminal.open()
  eq(term_buf, vim.api.nvim_get_current_buf(), "the same terminal session reopens after :q!")

  -- :wq writes before QuitPre, then follows the same tab-closing path.
  local written_file = vim.fn.tempname()
  local written_tab = vim.api.nvim_get_current_tabpage()
  code_win = ordinary_wins(term_buf)[1]
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("file " .. vim.fn.fnameescape(written_file))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "written before quit" })
  vim.bo.modified = true
  vim.cmd("tabnew")
  local second_sentinel = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(written_tab)
  vim.api.nvim_set_current_win(code_win)
  local write_ok, write_err = pcall(vim.cmd, "wq")
  truthy(write_ok, ":wq closes the written code tab: " .. tostring(write_err))
  truthy(not vim.api.nvim_tabpage_is_valid(written_tab), ":wq removes the original tab")
  eq(second_sentinel, vim.api.nvim_get_current_tabpage(), ":wq returns to the other tab")
  eq("written before quit", vim.fn.readfile(written_file)[1], ":wq writes the code buffer")
  vim.fn.delete(written_file)
  truthy(vim.api.nvim_buf_is_valid(term_buf), ":wq preserves the terminal session")
  terminal.open()

  -- stay=true intentionally allows an agent-only split and must bypass both
  -- the proactive guard and fallback recovery.
  config.window.stay = true
  code_win = ordinary_wins(term_buf)[1]
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "stay unsaved" })
  vim.bo.modified = true
  local stay_ok, stay_err = pcall(vim.cmd, "quit")
  truthy(stay_ok, "stay=true allows the code window to close: " .. tostring(stay_err))
  eq(1, #vim.api.nvim_tabpage_list_wins(0), "stay=true leaves the agent as the only window")
  eq(term_buf, vim.api.nvim_get_current_buf(), "stay=true keeps the agent displayed")

  -- A float is not part of the ordinary layout, so normal last-window E37
  -- behavior already applies and the QuitPre guard leaves the float alone.
  config.window.stay = false
  terminal.hide()
  config.window.style = "float"
  local replacement = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "also unsaved" })
  vim.bo.modified = true
  terminal.open()
  local float = agent_win(term_buf)
  truthy(vim.api.nvim_win_get_config(float).relative ~= "", "precondition: agent uses a float")
  vim.api.nvim_set_current_win(replacement)
  local float_ok, float_err = pcall(vim.cmd, "quit")
  truthy(
    not float_ok and tostring(float_err):find("E37", 1, true),
    "a float preserves Neovim's normal E37"
  )
  eq(float, agent_win(term_buf), "QuitPre does not hide an agent float")

  terminal.hide()
  vim.fn.termopen = original_termopen
end, debug.traceback)

if not ok then
  error(err)
end

print("quit_spec: ok")
