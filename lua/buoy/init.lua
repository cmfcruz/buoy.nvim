--- buoy.nvim
--- Floats or docks — stays anchored to the code.
--- An agent's official TUI (Codex / Claude Code) in a float or split, plus
--- live editor context and navigation through a private agent CLI.

if vim.fn.has("nvim-0.11") == 0 then
  error("buoy.nvim requires Neovim 0.11 or newer")
end

local M = {}

M.config = {
  agent = "auto", -- "auto" | "claude" | "codex"; auto prefers an installed CLI (Claude Code first)
  cmd = nil, -- override the agent's default binary (optional)
  window = {
    style = "auto", -- "auto" | "vsplit" | "float"; auto splits when the code stays wider than width, else floats
    width = 80, -- fixed columns of text for the agent
    border = "rounded",
    stay = false, -- keep the agent split open after all other windows close (default: quit with them)
  },
  keymaps = {
    -- Actions are layout-aware: the primary key does a vsplit's always-on action
    -- (focus) or a float's (show/hide); the secondary key does the other.
    primary = "<F2>", -- focus in a vsplit, show/hide in a float; false to disable
    secondary = "<S-F2>", -- show/hide in a vsplit, focus in a float; false to disable
  },
  -- Gated agent-facing surfaces; keys and defaults live in buoy.capabilities so
  -- no module re-declares them (see that file for per-key descriptions).
  context = vim.deepcopy(require("buoy.capabilities").defaults),
}

-- Built-in agent presets. `cmd` is the CLI launched in the agent window;
-- `title` is its float border label. Both are overridable via setup() opts.
local AGENTS = {
  codex = { cmd = "codex", title = " Codex " },
  claude = { cmd = "claude", title = " Claude Code " },
}

--- Resolve the `"auto"` agent to a concrete one: prefer Claude Code, then
--- Codex, by what's actually on `$PATH`. Falls back to Claude Code to give
--- `open()` a concrete missing command to report if neither CLI is
--- installed. An explicit `agent = "codex"|"claude"` skips this.
local function resolve_agent(agent)
  if agent ~= "auto" then
    return agent
  end
  if vim.fn.executable("claude") == 1 then
    return "claude"
  end
  if vim.fn.executable("codex") == 1 then
    return "codex"
  end
  return "claude"
end

--- Ensure this Neovim instance has an RPC socket for the agent bridge.
local function ensure_rpc_socket()
  local addr = vim.v.servername
  if addr == nil or addr == "" then
    addr = vim.fn.serverstart()
  end

  return addr
end

local context_window_inoculated = false
local context_window_retry = nil
local context_window_inoculating = false

local function clear_context_window_retry()
  if context_window_retry == nil then
    return
  end

  local id = context_window_retry
  context_window_retry = nil
  pcall(vim.api.nvim_del_autocmd, id)
end

--- Neovim (verified on 0.12.3) allocates its hidden autocmd window lazily, on
--- the first buffer-context switch to an undisplayed buffer — e.g. any
--- `vim.bo[buf].x` read. `win_alloc_aucmd_win()` builds that window as a
--- Columns x 5 float initialized from curwin, so for one instant it displays
--- *curwin's buffer* while not yet registered as an autocmd window. If that
--- instant happens while the agent's terminal float is focused,
--- `terminal_check_size()` counts the phantom full-width window and resizes
--- the agent's PTY to (Columns, float height); the TUI then wraps for the
--- wrong width until the float is toggled. The allocation is
--- once per session, so trigger it through a window whose buffer is safe.
local function inoculate_in_current_window()
  if context_window_inoculated then
    clear_context_window_retry()
    return true
  end

  if vim.bo.buftype == "terminal" then
    return false
  end

  local ok, scratch = pcall(vim.api.nvim_create_buf, false, true)
  if not ok then
    return false
  end

  local read_ok = pcall(function()
    local _ = vim.bo[scratch].buflisted
  end)
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })

  if read_ok then
    context_window_inoculated = true
    clear_context_window_retry()
  end
  return read_ok
end

local function register_context_window_retry()
  if context_window_retry ~= nil then
    return
  end

  local group = vim.api.nvim_create_augroup("BuoyContextWindowInoculation", { clear = true })
  context_window_retry = vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      if context_window_inoculated then
        clear_context_window_retry()
        return
      end
      if vim.bo.buftype == "terminal" or context_window_inoculating then
        return
      end

      context_window_inoculating = true
      inoculate_in_current_window()
      context_window_inoculating = false
    end,
  })
end

local function ensure_context_window_inoculated()
  if context_window_inoculated then
    clear_context_window_retry()
    return true
  end
  if context_window_inoculating then
    return false
  end

  context_window_inoculating = true
  local current_is_terminal = vim.bo.buftype == "terminal"
  local inoculated = false
  if current_is_terminal then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local ok, result = pcall(vim.api.nvim_win_call, win, inoculate_in_current_window)
        if ok and result then
          inoculated = true
          break
        end
      end
    end
  else
    inoculated = inoculate_in_current_window()
  end
  context_window_inoculating = false

  if not inoculated then
    register_context_window_retry()
  end
  return inoculated
end

--- Apply configuration once per Neovim session ("restart to reconfigure").
function M.setup(opts)
  if M._did_setup then
    if opts ~= nil then
      vim.notify(
        "buoy: configuration already applied; restart Neovim for changes to take effect",
        vim.log.levels.WARN
      )
    end
    return
  end

  local config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- window.width is a fixed column count: require a whole number, and reject
  -- anything below this floor, where the agent window renders as an unusable
  -- sliver.
  local width = config.window.width
  if type(width) ~= "number" or width % 1 ~= 0 or width < 40 then
    error(
      ("buoy: window.width %s is invalid (expected an integer of at least 40 columns)"):format(
        vim.inspect(width)
      )
    )
  end

  -- $BUOY_AGENT overrides the configured agent (e.g. BUOY_AGENT=codex nvim).
  local env_agent = vim.env.BUOY_AGENT
  if env_agent and env_agent ~= "" then
    config.agent = env_agent
  end

  config.agent = resolve_agent(config.agent)
  local preset = AGENTS[config.agent]
  if not preset then
    error(
      ("buoy: unknown agent %q (expected 'auto', 'codex', or 'claude')"):format(
        tostring(config.agent)
      )
    )
  end
  -- Resolve the launch command and float title; an explicit override wins.
  config.cmd = config.cmd or preset.cmd
  config.title = config.title or preset.title

  M.config = config
  -- Record only after validation, so a rejected config does not lock the
  -- session. The load-time auto-setup in plugin/buoy.lua also uses this flag.
  M._did_setup = true

  M.socket = ensure_rpc_socket()
  ensure_context_window_inoculated()
  require("buoy.context").setup()

  if config.keymaps.primary then
    vim.keymap.set({ "n", "x", "t" }, config.keymaps.primary, function()
      require("buoy.terminal").on_primary()
    end, { desc = "buoy: agent primary (focus in split, show/hide in float)", silent = true })
  end

  if config.keymaps.secondary then
    vim.keymap.set({ "n", "x", "t" }, config.keymaps.secondary, function()
      require("buoy.terminal").on_secondary()
    end, { desc = "buoy: agent secondary (show/hide in split, focus in float)", silent = true })
  end

  -- Keep the agent window's layout in step with the editor size: an "auto"
  -- window flips between split and float across the width boundary, and a float
  -- stays anchored to the resized editor. relayout() only acts on the agent's
  -- own tabpage, so a resize while another tab is active is a no-op there;
  -- TabEnter catches up on that missed relayout when the agent's tab regains
  -- focus.
  local resize_group = vim.api.nvim_create_augroup("BuoyResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = resize_group,
    callback = function()
      require("buoy.terminal").on_resize()
    end,
    desc = "buoy: re-evaluate the agent layout on editor resize",
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = resize_group,
    callback = function()
      require("buoy.terminal").relayout()
    end,
    desc = "buoy: re-evaluate the agent layout when returning to its tab",
  })
end

--- Apply zero-configuration defaults if explicit setup has not run yet.
--- Commands call this synchronously because they can execute before the
--- scheduled startup setup in a newly opened Neovim instance.
function M.ensure_setup()
  if not M._did_setup then
    M.setup()
  end
end

return M
