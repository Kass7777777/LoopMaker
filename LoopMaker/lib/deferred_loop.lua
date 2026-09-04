local M = {}

function M.create(api, frame_callback, error_callback)
  assert(type(api) == "table" and type(api.defer) == "function",
    "deferred loop requires api.defer")
  assert(type(frame_callback) == "function",
    "deferred loop requires a frame callback")
  assert(type(error_callback) == "function",
    "deferred loop requires an error callback")

  local step
  step = function()
    local ok, keep_running = xpcall(frame_callback, debug.traceback)
    if not ok then
      error_callback(keep_running)
      return
    end
    if keep_running then api.defer(step) end
  end
  return step
end

return M
