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

local function agent_layout(buf)
  local win = agent_win(buf)
  if not win then
    return nil
  end
  return vim.api.nvim_win_get_config(win).relative ~= "" and "float" or "vsplit"
end

local function code_wins(agent_buf)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      vim.api.nvim_win_get_buf(win) ~= agent_buf
      and vim.api.nvim_win_get_config(win).relative == ""
    then
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
    window = { style = "auto", width = 80, border = "rounded", stay = true },
  }
  package.loaded["buoy"] = {
    config = config,
    socket = "/tmp/buoy-layout-spec.sock",
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

  -- Side-by-side code windows would each become narrower than the configured
  -- agent width, so auto uses an overlay rather than squeezing them.
  vim.cmd("vsplit")
  terminal.open()
  local buf = vim.api.nvim_get_current_buf()
  truthy(vim.bo[buf].buftype == "terminal", "opening starts a terminal session")
  eq("float", agent_layout(buf), "side-by-side code windows make auto choose a float")

  -- Stacked code windows still span the editor width and can share it with the
  -- fixed-width agent split.
  terminal.hide()
  local side_by_side = code_wins(buf)
  eq(2, #side_by_side, "side-by-side setup leaves two code windows")
  vim.api.nvim_win_close(side_by_side[2], true)
  vim.api.nvim_set_current_win(side_by_side[1])
  vim.cmd("split")
  terminal.open()
  eq("vsplit", agent_layout(buf), "stacked code windows make auto choose a vsplit")

  -- The agent owns exactly its configured columns even when Neovim equalizes
  -- the layout or divides a neighboring code window.
  local agent = agent_win(buf)
  truthy(vim.wo[agent].winfixwidth, "the agent split sets winfixwidth")
  eq(80, vim.api.nvim_win_get_width(agent), "the agent split opens at its configured width")
  local code = code_wins(buf)[1]
  vim.api.nvim_win_call(code, function()
    vim.cmd("wincmd =")
  end)
  eq(80, vim.api.nvim_win_get_width(agent), "wincmd = preserves the agent split width")
  vim.api.nvim_win_call(code, function()
    vim.cmd("vsplit")
  end)
  eq(80, vim.api.nvim_win_get_width(agent), "a new code vsplit preserves the agent split width")

  -- Reduce the layout to one code window without using :only, which would also
  -- close the agent window and invalidate the session under test.
  local codes = code_wins(buf)
  local code_win = codes[1]
  for i = 2, #codes do
    vim.api.nvim_win_close(codes[i], true)
  end

  -- A cross-layout rebuild briefly leaves and re-enters the code window.
  -- Preserve the user's live characterwise Visual selection through that swap.
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha beta gamma", "second line" })
  vim.api.nvim_win_set_cursor(code_win, { 1, 0 })
  vim.api.nvim_feedkeys("vll", "x", false)
  eq("v", vim.fn.mode(true), "precondition: code window has a charwise Visual selection")
  local anchor_col = vim.fn.getpos("v")[3]
  local cursor_col = vim.fn.col(".")

  vim.o.columns = 100
  terminal.relayout()
  eq("float", agent_layout(buf), "narrowing rebuilds the agent split as a float")
  eq("v", vim.fn.mode(true), "the rebuild preserves charwise Visual mode")
  eq(anchor_col, vim.fn.getpos("v")[3], "the rebuild preserves the Visual anchor column")
  eq(cursor_col, vim.fn.col("."), "the rebuild preserves the Visual cursor column")

  -- With stay enabled the user can close every code window while the agent
  -- remains. Hiding must restore an ordinary window before closing the agent.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  vim.o.columns = 220
  terminal.relayout()
  eq("vsplit", agent_layout(buf), "widening rebuilds the float as a split")
  code_win = code_wins(buf)[1]
  local closed_code_buf = vim.api.nvim_win_get_buf(code_win)
  vim.api.nvim_win_close(code_win, true)
  vim.api.nvim_buf_delete(closed_code_buf, { force = true })
  eq(1, #vim.api.nvim_tabpage_list_wins(0), "the agent can be the tabpage's only window")

  local hidden, hide_err = pcall(terminal.toggle)
  truthy(hidden, "toggle hides an agent-only split without error: " .. tostring(hide_err))
  truthy(agent_win(buf) == nil, "toggle hides the agent-only split")
  local remaining = vim.api.nvim_tabpage_list_wins(0)
  truthy(#remaining > 0, "hiding an agent-only split leaves an ordinary window")
  for _, win in ipairs(remaining) do
    eq("", vim.api.nvim_win_get_config(win).relative, "the replacement window is ordinary")
  end

  local listed_before = #vim.fn.getbufinfo({ buflisted = 1 })
  local deleted_file = vim.fn.tempname()
  vim.fn.writefile({ "temporary" }, deleted_file)
  vim.cmd("badd " .. vim.fn.fnameescape(deleted_file))
  vim.cmd("buffer " .. vim.fn.bufnr(deleted_file))

  local shown, show_err = pcall(terminal.toggle)
  truthy(shown, "a second toggle reopens the agent without error: " .. tostring(show_err))
  truthy(agent_win(buf) ~= nil, "a second toggle brings the existing agent session back")

  -- Wiping the alternate file while the agent is open strands it again with
  -- no usable '#'. Reuse the fallback buffer buoy already created instead of
  -- leaving another empty listed buffer behind on every such cycle.
  code_win = code_wins(buf)[1]
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("bwipeout")
  vim.fn.delete(deleted_file)
  vim.api.nvim_set_current_win(agent_win(buf))
  local alt = vim.fn.bufnr("#")
  truthy(
    alt <= 0 or not vim.api.nvim_buf_is_valid(alt),
    "precondition: the agent has no reusable alternate buffer"
  )
  terminal.hide()
  eq(
    listed_before,
    #vim.fn.getbufinfo({ buflisted = 1 }),
    "repeated fallback does not accumulate listed buffers"
  )
  terminal.open()

  -- A pinned sidebar (file tree, symbol outline) keeps its columns when the
  -- layout changes, so it is fixed overhead rather than code the agent would
  -- squeeze: a single wide code window beside one still gets a split.
  terminal.hide()
  local survivors = code_wins(buf)
  for i = 2, #survivors do
    vim.api.nvim_win_close(survivors[i], true)
  end
  code_win = survivors[1]
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("topleft vsplit")
  local sidebar = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(sidebar, 30)
  vim.wo[sidebar].winfixwidth = true
  vim.api.nvim_set_current_win(code_win)
  terminal.open()
  eq("vsplit", agent_layout(buf), "a pinned sidebar does not count as squeezable code")
  eq(30, vim.api.nvim_win_get_width(sidebar), "the agent split leaves a pinned sidebar alone")

  -- Fixed-width sidebars stacked in the same column share their horizontal
  -- overhead. Counting each one separately would choose a float even though
  -- the code still has room beside that single sidebar column.
  terminal.hide()
  vim.o.columns = 200
  vim.wait(60)
  vim.api.nvim_set_current_win(sidebar)
  vim.cmd("split")
  local lower_sidebar = vim.api.nvim_get_current_win()
  vim.wo[lower_sidebar].winfixwidth = true
  vim.api.nvim_set_current_win(code_win)
  terminal.open()
  eq("vsplit", agent_layout(buf), "stacked pinned sidebars count their shared columns once")

  -- Dividing the code area beside those sidebars does squeeze real code
  -- windows, so auto overlays instead.
  terminal.hide()
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("vsplit")
  terminal.open()
  eq("float", agent_layout(buf), "a pinned sidebar plus squeezed code windows still overlays")

  vim.fn.termopen = original_termopen
end, debug.traceback)

if not ok then
  error(err)
end

print("layout_spec: ok")
