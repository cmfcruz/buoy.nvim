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

local ok, err = xpcall(function()
  local original_serverstart = vim.fn.serverstart
  vim.fn.serverstart = function()
    return "/tmp/buoy-startup-spec.sock"
  end
  local original_agent = vim.env.BUOY_AGENT
  vim.env.BUOY_AGENT = "codex"

  package.loaded["buoy"] = nil
  local opened = 0
  local toggled = 0
  local captured
  local events = {}
  package.loaded["buoy.context"] = {
    setup = function() end,
    capture_command_selection = function(first_line, last_line)
      captured = { first_line, last_line }
      events[#events + 1] = "capture"
    end,
  }
  package.loaded["buoy.terminal"] = {
    toggle = function()
      toggled = toggled + 1
      events[#events + 1] = "toggle"
    end,
    open = function()
      opened = opened + 1
      events[#events + 1] = "open"
    end,
  }

  vim.g.loaded_buoy = nil
  dofile(root .. "/plugin/buoy.lua")
  truthy(vim.fn.exists(":Buoy") == 2, ":Buoy is registered")
  truthy(vim.fn.exists(":BuoyToggle") == 2, ":BuoyToggle is registered")

  vim.cmd("Buoy")

  local buoy = require("buoy")
  truthy(buoy._did_setup, ":Buoy performs setup before the deferred startup callback")
  truthy(buoy.config.agent == "codex", ":Buoy applies the pinned agent before opening")
  truthy(buoy.config.cmd == "codex", ":Buoy resolves the pinned command before opening")
  truthy(buoy.config.title == " Codex ", ":Buoy resolves the pinned title before opening")
  truthy(type(buoy.socket) == "string", ":Buoy publishes the socket before opening")
  truthy(opened == 1, ":Buoy opens the agent after setup")
  truthy(toggled == 0, ":Buoy does not toggle the agent window")
  truthy(captured == nil, "plain :Buoy does not invent a selection range")

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
  events = {}
  vim.cmd("2,3Buoy")
  truthy(vim.deep_equal({ 2, 3 }, captured), ":Buoy forwards a supplied selection range")
  truthy(vim.deep_equal({ "capture", "open" }, events), ":Buoy captures before opening")
  truthy(opened == 2, "ranged :Buoy opens the agent")

  captured = nil
  events = {}
  vim.cmd("1,2BuoyToggle")
  truthy(vim.deep_equal({ 1, 2 }, captured), ":BuoyToggle forwards a supplied selection range")
  truthy(vim.deep_equal({ "capture", "toggle" }, events), ":BuoyToggle captures before toggling")
  truthy(toggled == 1, "ranged :BuoyToggle toggles the agent window")

  package.loaded["buoy.context"] = nil
  package.loaded["buoy.terminal"] = nil

  -- Hiding and reopening keeps the live terminal session even if the command
  -- is no longer available for starting a new one.
  package.loaded["buoy"] = {
    config = {
      agent = "codex",
      cmd = vim.o.shell,
      title = " Test ",
      window = { style = "vsplit", width = 80, border = "rounded", stay = true },
    },
    socket = "/tmp/buoy-startup-spec.sock",
    ensure_setup = function() end,
  }
  package.loaded["buoy.context"] = {
    paint_selection = function() end,
    clear_selection = function() end,
  }
  package.loaded["buoy.launcher"] = {
    resolve = function(_agent, cmd, _cwd, callback)
      callback({ cmd })
    end,
  }

  local terminal_exit
  local original_termopen = vim.fn.termopen
  vim.fn.termopen = function(_, opts)
    terminal_exit = opts.on_exit
    return vim.api.nvim_open_term(0, {})
  end

  local terminal = require("buoy.terminal")
  terminal.open()
  local terminal_buf = vim.api.nvim_get_current_buf()
  truthy(vim.bo[terminal_buf].buftype == "terminal", "opening starts a terminal session")
  terminal.hide()

  local original_executable = vim.fn.executable
  vim.fn.executable = function()
    return 0
  end
  terminal.open()
  truthy(
    vim.api.nvim_get_current_buf() == terminal_buf,
    "reopening restores the live session without rechecking its command"
  )
  vim.fn.executable = original_executable

  truthy(type(terminal_exit) == "function", "opening registers terminal exit cleanup")
  local agent_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= agent_win and vim.api.nvim_win_get_config(win).relative == "" then
      vim.api.nvim_win_close(win, true)
    end
  end
  truthy(
    #vim.api.nvim_tabpage_list_wins(0) == 1,
    "the stayed agent can be the tabpage's only window"
  )

  local exited, exit_err = pcall(terminal_exit)
  truthy(exited, "an agent-only terminal exits without E444: " .. tostring(exit_err))
  truthy(not vim.api.nvim_buf_is_valid(terminal_buf), "the test terminal exits cleanly")
  local remaining = vim.api.nvim_tabpage_list_wins(0)
  truthy(#remaining == 1, "terminal exit leaves one replacement window")
  truthy(
    vim.api.nvim_win_get_config(remaining[1]).relative == "",
    "the replacement window is ordinary"
  )

  terminal.open()
  truthy(
    vim.api.nvim_get_current_buf() ~= terminal_buf,
    "opening after terminal exit starts a fresh session"
  )
  terminal_exit()
  vim.fn.termopen = original_termopen

  package.loaded["buoy.context"] = nil
  package.loaded["buoy.launcher"] = nil
  package.loaded["buoy.terminal"] = nil
  vim.env.BUOY_AGENT = original_agent
  vim.fn.serverstart = original_serverstart
end, debug.traceback)

if not ok then
  error(err)
end

print("startup_spec: ok")
