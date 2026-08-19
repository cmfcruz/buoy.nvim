--- PostToolUse hook, run after a native edit or write tool call completes.
---
--- Checks the running Neovim instance for externally changed buffers. Neovim
--- reloads only clean buffers with 'autoread' enabled; modified buffers retain
--- its normal warning and reload-choice behavior.
---
--- The hook must not read stdin or produce output: neither agent needs a
--- response from it, and a failed refresh must never keep the agent running.

pcall(function()
  local script_dir = arg[0]:match("^(.*)[/\\\\]") or "."
  local rpc = dofile(script_dir .. "/nvim_rpc.lua")

  local chan = rpc.connect()
  if not chan then
    return
  end

  -- A non-interactive :checktime only refreshes buffers displayed in a window,
  -- so check each loaded buffer explicitly to include hidden file buffers.
  local code = [[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        pcall(vim.cmd, "checktime " .. buf)
      end
    end
  ]]
  pcall(rpc.exec, chan, code, {})
  pcall(vim.fn.chanclose, chan)
end)

os.exit(0)
