local M = {}
local Recovery = {}
Recovery.__index = Recovery

function M.new(reason)
  return setmetatable({
    original_reason = tostring(reason or "unknown frame error"),
    pending = true,
    notice_shown = false,
  }, Recovery)
end

function Recovery:is_pending()
  return self.pending == true
end

function Recovery:step(cancel)
  if not self.pending then
    return {
      pending = false,
      finished = true,
      message = self.original_reason,
    }
  end

  local ok, restored, reason = pcall(cancel)
  if ok and restored then
    self.pending = false
    return {
      pending = false,
      finished = true,
      message = self.original_reason,
    }
  end

  local failure = ok and reason or restored
  local notice
  if not self.notice_shown then
    self.notice_shown = true
    failure = tostring(failure or "unknown Cancel failure")
    if failure:find("Stop playback/recording", 1, true) then
      notice = "LoopMaker recovery is pending; stop REAPER transport to restore"
        .. " automatically; 也可手动停止脚本（Actions > Running script）终止，"
        .. "项目将由 atexit 兜底恢复"
    else
      notice = "LoopMaker recovery is pending: " .. failure
    end
  end

  return {
    pending = true,
    finished = false,
    notice = notice,
  }
end

return M
