--- buoy.nvim
--- Floats on the surface, anchored to the code.
--- An agent's official TUI (Codex / Claude Code) in a floating window, plus
--- pull-based editor context via MCP.

local M = {}

M.config = {
  agent = "codex",          -- "codex" | "claude" — picks the CLI + popup title
  cmd = nil,                -- override the agent's default binary (optional)
  window = {
    style = "float",        -- "float" | "vsplit"
    width = 0.40,           -- fraction of editor width
    border = "rounded",
  },
  keymaps = {
    toggle = "<F2>",        -- set to false to disable
  },
}

-- Built-in agent presets. `cmd` is the CLI launched in the popup; `title`
-- is the float border label. Both are overridable via setup() opts.
local AGENTS = {
  codex  = { cmd = "codex",  title = " Codex " },
  claude = { cmd = "claude", title = " Claude Code " },
}

--- Ensure this Neovim instance has an RPC socket and record it in a
--- well-known lockfile so the MCP bridge can find us even if the agent
--- does not forward environment variables to MCP child processes.
local function publish_socket()
  local addr = vim.v.servername
  if addr == nil or addr == "" then
    addr = vim.fn.serverstart()
  end

  local dir = vim.fn.stdpath("cache") .. "/buoy"
  vim.fn.mkdir(dir, "p")

  -- Per-project lockfile (keyed by cwd) + a "latest" fallback.
  local cwd_key = vim.fn.sha256(vim.fn.getcwd()):sub(1, 16)
  for _, name in ipairs({ cwd_key, "latest" }) do
    local f = io.open(dir .. "/" .. name .. ".sock", "w")
    if f then
      f:write(addr)
      f:close()
    end
  end

  return addr
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local preset = AGENTS[M.config.agent]
  if not preset then
    error(("buoy: unknown agent %q (expected 'codex' or 'claude')")
      :format(tostring(M.config.agent)))
  end
  -- Resolve launch command and popup title; an explicit override wins.
  M.config.cmd = M.config.cmd or preset.cmd
  M.config.title = M.config.title or preset.title

  M.socket = publish_socket()
  require("buoy.context").setup()

  if M.config.keymaps.toggle then
    vim.keymap.set({ "n", "t" }, M.config.keymaps.toggle, function()
      require("buoy.terminal").toggle()
    end, { desc = "buoy: toggle", silent = true })
  end
end

return M
