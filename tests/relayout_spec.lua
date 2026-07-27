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

-- The window (if any) currently displaying the agent's terminal buffer, and the
-- layout it occupies. Tests locate the agent through its buffer because a
-- layout rebuild replaces the window (new id) while keeping the same session.
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

local ok, err = xpcall(function()
  vim.o.lines = 40

  -- style = "auto" resolves to a vsplit while the code buffer would stay wider
  -- than the agent's width, and a float otherwise. With width 80 the boundary
  -- is 161 columns including the separator: 161 floats, 162 splits.
  local config = {
    agent = "codex",
    cmd = vim.o.shell,
    title = " Test ",
    window = { style = "auto", width = 80, border = "rounded", stay = true },
  }
  package.loaded["buoy"] = {
    config = config,
    socket = "/tmp/buoy-relayout-spec.sock",
    ensure_setup = function() end,
  }
  local fake_selection = { text = "selected text" }
  -- Forward-declared so clear_selection's closure captures the local, not a global.
  local context_stub
  context_stub = {
    selection = nil,
    paint_selection = function() end,
    clear_selection = function()
      context_stub.selection = nil
    end,
  }
  package.loaded["buoy.context"] = context_stub
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
  local code_win = vim.api.nvim_get_current_win()

  -- A wide editor opens the agent as a vsplit.
  vim.o.columns = 220
  terminal.open()
  local buf = vim.api.nvim_get_current_buf()
  truthy(vim.bo[buf].buftype == "terminal", "opening starts a terminal session")
  eq("vsplit", agent_layout(buf), "a wide editor opens the agent as a vsplit")

  -- The resolver must be stable on both sides of its exact boundary. Its input
  -- geometry changes when a rebuild adds or removes the agent split; resolving
  -- that new geometry differently would make repeated resize events oscillate.
  vim.o.columns = 161
  terminal.relayout()
  eq("float", agent_layout(buf), "the equality boundary resolves to a float")
  local boundary_win = agent_win(buf)
  terminal.relayout()
  eq(boundary_win, agent_win(buf), "re-resolving the float boundary does not rebuild")

  vim.o.columns = 162
  terminal.relayout()
  eq("vsplit", agent_layout(buf), "one column past the boundary resolves to a split")
  boundary_win = agent_win(buf)
  terminal.relayout()
  eq(boundary_win, agent_win(buf), "re-resolving the split boundary does not rebuild")

  -- Narrowing across the boundary flips it to a float, same session, and
  -- preserves an active visual-selection handoff instead of clearing it.
  context_stub.selection = fake_selection
  vim.o.columns = 100
  terminal.relayout()
  eq("float", agent_layout(buf), "narrowing past the boundary rebuilds as a float")
  truthy(vim.api.nvim_buf_is_valid(buf), "the rebuild reuses the live terminal buffer")
  eq(buf, vim.api.nvim_win_get_buf(agent_win(buf)), "the float shows the same session buffer")
  eq(fake_selection, context_stub.selection, "the rebuild preserves the active selection handoff")

  -- Widening flips it back to a vsplit.
  vim.o.columns = 220
  terminal.relayout()
  eq("vsplit", agent_layout(buf), "widening past the boundary rebuilds as a vsplit")

  -- A resize that stays within the same layout band refreshes geometry in place
  -- (same window id), rather than tearing down and rebuilding.
  local before = agent_win(buf)
  vim.o.columns = 200
  terminal.relayout()
  eq(before, agent_win(buf), "a within-band resize keeps the same window (no rebuild)")
  eq(80, vim.api.nvim_win_get_width(before), "a within-band resize re-asserts the split width")

  -- A pinned split in an editor too narrow for the configured width keeps the
  -- clamped width rather than the configured one.
  config.window.style = "vsplit"
  vim.o.columns = 45
  terminal.relayout()
  eq("vsplit", agent_layout(buf), "a pinned split stays a split in a narrow editor")
  eq(
    43,
    vim.api.nvim_win_get_width(agent_win(buf)),
    "a narrow editor clamps the split to columns - 2"
  )

  -- An explicit style pin is honored regardless of width: pinning float keeps a
  -- float even at a width where "auto" would choose a vsplit.
  config.window.style = "float"
  vim.o.columns = 300
  terminal.relayout()
  eq("float", agent_layout(buf), "an explicit float pin does not switch to a vsplit when wide")

  -- A same-layout resize re-anchors the float to the new editor size instead of
  -- leaving it at the geometry of the old one.
  vim.o.columns = 120
  terminal.relayout()
  local float_config = vim.api.nvim_win_get_config(agent_win(buf))
  eq(80, float_config.width, "the resized float keeps its configured width")
  eq(1, float_config.row, "the resized float stays anchored to the top")
  eq(39, float_config.col, "the resized float re-anchors to the editor's right edge")
  config.window.style = "auto"

  -- Focus is preserved across a rebuild: when the code window holds focus, the
  -- rebuild returns focus to it instead of stealing it into the agent.
  vim.o.columns = 300
  terminal.relayout() -- auto + wide -> vsplit
  eq("vsplit", agent_layout(buf), "auto returns to a vsplit when wide again")
  vim.api.nvim_set_current_win(code_win)
  vim.o.columns = 100
  terminal.relayout() -- crosses to float while code-focused
  eq("float", agent_layout(buf), "the code-focused rebuild still adapts the layout")
  eq(code_win, vim.api.nvim_get_current_win(), "the rebuild keeps focus on the code window")

  -- relayout only acts on the agent's own tabpage. Without that guard a resize
  -- handled while another tab is active would rebuild the agent through
  -- `botright vsplit`, which targets the *current* tabpage — dragging the agent
  -- out of the tab it belongs to.
  local agent_tab = vim.api.nvim_win_get_tabpage(agent_win(buf))
  vim.cmd.tabnew()
  local other_tab = vim.api.nvim_get_current_tabpage()
  vim.o.columns = 220
  terminal.relayout()
  eq("float", agent_layout(buf), "a backgrounded agent is not rebuilt from another tabpage")
  eq(
    agent_tab,
    vim.api.nvim_win_get_tabpage(agent_win(buf)),
    "relayout leaves a backgrounded agent on its own tabpage"
  )
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(other_tab)) do
    truthy(
      vim.api.nvim_win_get_buf(win) ~= buf,
      "relayout creates no agent window on the active tabpage"
    )
  end
  vim.cmd.tabclose()
  vim.api.nvim_set_current_win(code_win)

  -- A hidden agent is left alone; the next show re-detects the layout.
  terminal.hide()
  vim.o.columns = 220
  terminal.relayout()
  truthy(agent_win(buf) == nil, "relayout does not resurrect a hidden agent")

  vim.fn.termopen = original_termopen
  package.loaded["buoy"] = nil
  package.loaded["buoy.context"] = nil
  package.loaded["buoy.launcher"] = nil
  package.loaded["buoy.terminal"] = nil

  -- Returning to the agent's tabpage after a resize that happened elsewhere:
  -- relayout()'s tabpage guard makes that resize a no-op while another tab is
  -- active, so this must exercise the real TabEnter autocmd registered by
  -- buoy.setup() rather than calling relayout() by hand.
  local tabenter_context
  tabenter_context = {
    selection = nil,
    setup = function() end,
    paint_selection = function() end,
    clear_selection = function()
      tabenter_context.selection = nil
    end,
  }
  package.loaded["buoy.context"] = tabenter_context
  package.loaded["buoy.launcher"] = {
    resolve = function(_agent, cmd, _cwd, callback)
      callback({ cmd })
    end,
  }

  local original_serverstart = vim.fn.serverstart
  vim.fn.serverstart = function()
    return "/tmp/buoy-relayout-tabenter-spec.sock"
  end
  vim.fn.termopen = function(_, _opts)
    return vim.api.nvim_open_term(0, {})
  end

  vim.o.columns = 220
  local buoy = require("buoy")
  buoy.setup({
    agent = "codex",
    cmd = vim.o.shell,
    title = " Test ",
    window = { style = "auto", width = 80, border = "rounded", stay = true },
    keymaps = { primary = false, secondary = false },
  })

  local term = require("buoy.terminal")
  term.open()
  local tabenter_buf = vim.api.nvim_get_current_buf()
  eq("vsplit", agent_layout(tabenter_buf), "TabEnter setup: a wide editor opens a vsplit")

  vim.cmd.tabnew()
  -- Narrowing while a different tabpage is active is a no-op for the agent's
  -- backgrounded tab (relayout's tabpage guard); nothing has adapted yet.
  vim.o.columns = 100
  vim.cmd.tabprevious()
  eq(
    "float",
    agent_layout(tabenter_buf),
    "returning to the agent's tab fires TabEnter and relayouts it to a float"
  )

  -- Reverse direction: widen while backgrounded, TabEnter flips it back.
  vim.cmd.tabnext()
  vim.o.columns = 220
  vim.cmd.tabprevious()
  eq(
    "vsplit",
    agent_layout(tabenter_buf),
    "returning to the agent's tab after widening flips it back to a vsplit"
  )

  vim.cmd.tabnext()
  vim.cmd.tabclose()

  vim.fn.termopen = original_termopen
  vim.fn.serverstart = original_serverstart
  package.loaded["buoy"] = nil
  package.loaded["buoy.context"] = nil
  package.loaded["buoy.launcher"] = nil
  package.loaded["buoy.terminal"] = nil
end, debug.traceback)

if not ok then
  error(err)
end

print("relayout_spec: ok")
