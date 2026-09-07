--- Adapt Copilot's userPromptTransformed hook event to buoy's context hook.
local M = {}

local INPUT_LIMIT = 10 * 1024 * 1024

function M.run(context_text)
  local input = io.read(INPUT_LIMIT + 1)
  if not input or #input > INPUT_LIMIT then
    return
  end

  local ok, event = pcall(vim.json.decode, input)
  if
    not ok
    or type(event) ~= "table"
    or type(event.transformedPrompt) ~= "string"
    or event.transformedPrompt == ""
  then
    return
  end

  local content = context_text()
  if not content then
    return
  end

  local encoded = vim.json.encode({
    modifiedTransformedPrompt = event.transformedPrompt .. "\n\n" .. content,
  })
  if #encoded <= INPUT_LIMIT then
    io.write(encoded .. "\n")
    io.flush()
  end
end

return M
