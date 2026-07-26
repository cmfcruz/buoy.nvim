--- Structured error result shared by the editor operations. Handlers and the
--- dispatch layer return `err(code, message)` tables; the agent CLI maps the
--- `code` to a process exit status. The bridge scripts build the same shape
--- independently because they run in a separate process that cannot require
--- this module.
return function(code, message)
  return { kind = "error", code = code, message = message }
end
