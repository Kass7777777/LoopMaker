local M = {}

local Transaction = {}
Transaction.__index = Transaction
M.Transaction = Transaction

local log_message

local REQUIRED_API_FUNCTIONS = {
  "EnumProjects",
  "CountMediaItems",
  "GetMediaItem",
  "CountSelectedMediaItems",
  "GetSelectedMediaItem",
  "GetItemStateChunk",
  "SetItemStateChunk",
  "GetSetMediaItemInfo_String",
  "IsMediaItemSelected",
  "GetSet_LoopTimeRange2",
  "GetSetRepeatEx",
  "GetCursorPositionEx",
  "GetPlayStateEx",
  "PreventUIRefresh",
  "Undo_BeginBlock2",
  "Undo_EndBlock2",
  "ValidatePtr2",
  "GetMediaItemTrack",
  "AddMediaItemToTrack",
  "DeleteTrackMediaItem",
  "SetMediaItemSelected",
  "SetEditCurPos2",
  "UpdateArrange",
  "OnStopButton",
}

local function validate_api(api)
  if type(api) ~= "table" then
    return nil, "reaper_api must be a table"
  end
  for _, name in ipairs(REQUIRED_API_FUNCTIONS) do
    if type(api[name]) ~= "function" then
      return nil, "reaper_api is missing " .. name
    end
  end
  return true
end

local function call_api(api, name, ...)
  local results = { pcall(api[name], ...) }
  if not results[1] then
    error(name .. " failed: " .. tostring(results[2]), 0)
  end
  return table.unpack(results, 2)
end

local function is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value > -math.huge
    and value < math.huge
end

local function same_time(left, right)
  return is_finite_number(left)
    and is_finite_number(right)
    and math.abs(left - right) <= 1e-9
end

local function read_current_project(api)
  local ok, project, identifier = pcall(api.EnumProjects, -1)
  if not ok then
    return nil, "EnumProjects failed: " .. tostring(project)
  end
  if project == nil then
    return nil, "EnumProjects did not return the current project"
  end
  return project, identifier
end

local function project_is_open(api, project)
  local index = 0
  while true do
    local ok, candidate = pcall(api.EnumProjects, index)
    if not ok then
      return nil, "EnumProjects failed while enumerating open projects: " .. tostring(candidate)
    end
    if candidate == nil then
      return false
    end
    if candidate == project then
      return true
    end
    index = index + 1
  end
end

local function read_guid(api, item)
  local ok, guid = call_api(api, "GetSetMediaItemInfo_String", item, "GUID", "", false)
  if not ok or type(guid) ~= "string" or guid == "" then
    error("GetSetMediaItemInfo_String failed to return an item GUID", 0)
  end
  return guid
end

local function enumerate_item_state(api, project)
  local state = { items = {}, by_item = {}, by_guid = {} }
  local item_count = call_api(api, "CountMediaItems", project)
  if type(item_count) ~= "number" or item_count < 0
      or item_count ~= math.floor(item_count) then
    error("CountMediaItems returned an invalid count", 0)
  end
  for index = 0, item_count - 1 do
    local item = call_api(api, "GetMediaItem", project, index)
    if item == nil then
      error("GetMediaItem returned nil at index " .. index, 0)
    end
    local guid = read_guid(api, item)
    if state.by_item[item] ~= nil then
      error("duplicate media item pointer found at index " .. index, 0)
    end
    if state.by_guid[guid] ~= nil then
      error("duplicate media item GUID found: " .. guid, 0)
    end
    local entry = {
      item = item,
      guid = guid,
      selected = call_api(api, "IsMediaItemSelected", item) == true,
    }
    state.items[#state.items + 1] = entry
    state.by_item[item] = guid
    state.by_guid[guid] = item
  end
  return state
end

local function capture_data(api, project, identifier)
  local all_items = {}
  local all_items_by_pointer = {}
  local guid_set = {}
  local item_count = call_api(api, "CountMediaItems", project)
  if type(item_count) ~= "number" or item_count < 0 then
    error("CountMediaItems returned an invalid count", 0)
  end

  for index = 0, item_count - 1 do
    local item = call_api(api, "GetMediaItem", project, index)
    if item == nil then
      error("GetMediaItem returned nil at index " .. index, 0)
    end
    local guid = read_guid(api, item)
    if guid_set[guid] then
      error("duplicate media item GUID captured: " .. guid, 0)
    end
    local selected = call_api(api, "IsMediaItemSelected", item) == true
    local snapshot = {
      item = item,
      guid = guid,
      selected = selected,
      valid = true,
    }
    all_items[#all_items + 1] = snapshot
    all_items_by_pointer[item] = snapshot
    guid_set[guid] = true
  end

  local selected_items = {}
  local selected_count = call_api(api, "CountSelectedMediaItems", project)
  if type(selected_count) ~= "number" or selected_count < 0 then
    error("CountSelectedMediaItems returned an invalid count", 0)
  end

  for index = 0, selected_count - 1 do
    local item = call_api(api, "GetSelectedMediaItem", project, index)
    if item == nil then
      error("GetSelectedMediaItem returned nil at index " .. index, 0)
    end
    local guid = read_guid(api, item)
    local chunk_ok, chunk = call_api(api, "GetItemStateChunk", item, "", false)
    if not chunk_ok or type(chunk) ~= "string" then
      error("GetItemStateChunk failed for selected item " .. guid, 0)
    end
    local track = call_api(api, "GetMediaItemTrack", item)
    if track == nil then
      error("GetMediaItemTrack failed for selected item " .. guid, 0)
    end
    selected_items[#selected_items + 1] = {
      item = item,
      guid = guid,
      chunk = chunk,
      track = track,
      all_item_snapshot = all_items_by_pointer[item],
      valid = true,
    }
  end

  local time_start, time_end = call_api(
    api, "GetSet_LoopTimeRange2", project, false, false, 0, 0, false)
  if not is_finite_number(time_start) or not is_finite_number(time_end) then
    error("GetSet_LoopTimeRange2 returned an invalid time selection", 0)
  end

  local loop_start, loop_end = call_api(
    api, "GetSet_LoopTimeRange2", project, false, true, 0, 0, false)
  if not is_finite_number(loop_start) or not is_finite_number(loop_end) then
    error("GetSet_LoopTimeRange2 returned invalid loop points", 0)
  end

  local repeat_state = call_api(api, "GetSetRepeatEx", project, -1)
  if not is_finite_number(repeat_state) then
    error("GetSetRepeatEx returned an invalid repeat state", 0)
  end
  repeat_state = repeat_state > 0 and 1 or 0

  local cursor = call_api(api, "GetCursorPositionEx", project)
  if type(cursor) ~= "number" then
    error("GetCursorPositionEx returned an invalid cursor position", 0)
  end

  -- Diagnostic metadata only. Restore never restarts or recreates the user's initial playback.
  local initial_play_state = call_api(api, "GetPlayStateEx", project)
  if type(initial_play_state) ~= "number" then
    error("GetPlayStateEx returned an invalid playback state", 0)
  end

  return {
    project = project,
    project_identifier = identifier,
    all_items = all_items,
    selected_items = selected_items,
    time_start = time_start,
    time_end = time_end,
    loop_start = loop_start,
    loop_end = loop_end,
    repeat_state = repeat_state,
    cursor = cursor,
    initial_play_state = initial_play_state,
  }
end

function Transaction.capture(reaper_api, project)
  local valid, reason = validate_api(reaper_api)
  if not valid then
    return nil, reason
  end
  if project == nil then
    return nil, "project is required; use 0 for the current project"
  end

  local current_project, identifier_or_reason = read_current_project(reaper_api)
  if not current_project then
    return nil, identifier_or_reason
  end
  if project ~= 0 and project ~= current_project then
    return nil, "the explicit project is not the current project"
  end

  local captured_ok, captured_or_error = pcall(
    capture_data, reaper_api, current_project, identifier_or_reason)
  if not captured_ok then
    return nil, "failed to capture project state: " .. tostring(captured_or_error)
  end

  local undo_ok, undo_error = pcall(reaper_api.Undo_BeginBlock2, current_project)
  if not undo_ok then
    return nil, "Undo_BeginBlock2 failed: " .. tostring(undo_error)
  end

  local transaction = setmetatable({
    api = reaper_api,
    captured = captured_or_error,
    status = "active",
    preview_playback_started = false,
    preview_range_state = nil,
    tracked_preview_items = {},
    preview_mutation_state = nil,
    undo_open = true,
    final_warnings = nil,
  }, Transaction)

  if type(reaper_api.atexit) == "function" then
    local registered, register_error = pcall(reaper_api.atexit, function()
      if not transaction:is_active() then return end

      local function attempt_restore()
        if transaction:is_same_project() then
          return transaction:restore()
        end
        return transaction:restore_in_background()
      end

      local result, result_reason = attempt_restore()
      if not result and transaction:is_active() then
        result, result_reason = attempt_restore()
      end
      if result then
        if type(result_reason) == "table" and #result_reason > 0 then
          log_message(reaper_api, table.concat(result_reason, "; "))
        elseif type(result_reason) == "string" and result_reason ~= "" then
          log_message(reaper_api, result_reason)
        end
        return
      end

      local open, open_reason = project_is_open(
        reaper_api, transaction.captured.project)
      if open == false then
        local abandoned, abandon_reason = transaction:abandon()
        if not abandoned then
          log_message(reaper_api,
            "atexit abandon failed after project close: " .. tostring(abandon_reason))
        elseif abandon_reason then
          log_message(reaper_api, abandon_reason)
        end
        return
      end

      local reason = tostring(result_reason or "atexit restore failed")
      if open == nil then
        reason = reason .. "; project-open check failed: " .. tostring(open_reason)
      end
      log_message(reaper_api, reason
        .. "; transaction remains active; use manual Undo if automatic recovery is unavailable")
    end)
    if not registered then
      local reasons = {
        "atexit registration failed: " .. tostring(register_error),
      }
      local abandoned, abandon_reason = transaction:abandon()
      if not abandoned then
        reasons[#reasons + 1] = "first cleanup failed: " .. tostring(abandon_reason)
        local retried, retry_reason = transaction:abandon()
        if not retried then
          reasons[#reasons + 1] = "second cleanup failed: " .. tostring(retry_reason)
        elseif retry_reason then
          reasons[#reasons + 1] = "second cleanup warning: " .. tostring(retry_reason)
        end
      elseif abandon_reason then
        reasons[#reasons + 1] = "first cleanup warning: " .. tostring(abandon_reason)
      end
      local reason = table.concat(reasons, "; ")
      log_message(reaper_api, reason)
      return nil, reason
    end
  end

  return transaction
end

function Transaction:is_active()
  return self.status == "active"
end

function Transaction:is_same_project()
  local project = read_current_project(self.api)
  return project ~= nil and project == self.captured.project
end

local function active_or_reason(self)
  if self.status == "active" then
    return true
  end
  if self.status == "applied" then
    return nil, "transaction was applied and cannot be restored"
  end
  if self.status == "cancelled" then
    return nil, "transaction was already cancelled"
  end
  return nil, "transaction was abandoned"
end

local function same_project_or_reason(self)
  local project, identifier_or_reason = read_current_project(self.api)
  if not project then
    return nil, identifier_or_reason
  end
  if project ~= self.captured.project then
    return nil, "captured project is not the current project"
  end
  return true
end

local function item_identity_exists(entries, item, guid)
  for _, entry in ipairs(entries or {}) do
    if entry.item == item and entry.guid == guid then return true end
  end
  return false
end

function Transaction:begin_preview_mutation()
  local active, active_reason = active_or_reason(self)
  if not active then return nil, active_reason end
  if self.preview_mutation_state ~= nil then
    return nil, "a preview mutation is already active"
  end
  local same, project_reason = same_project_or_reason(self)
  if not same then return nil, project_reason end

  local ok, state_or_reason = pcall(
    enumerate_item_state, self.api, self.captured.project)
  if not ok then
    return nil, "failed to begin preview mutation: " .. tostring(state_or_reason)
  end
  state_or_reason.user_selections = {}
  for _, entry in ipairs(state_or_reason.items) do
    if not item_identity_exists(self.captured.all_items, entry.item, entry.guid)
        and not item_identity_exists(
          self.tracked_preview_items, entry.item, entry.guid) then
      state_or_reason.user_selections[#state_or_reason.user_selections + 1] = {
        item = entry.item,
        guid = entry.guid,
        selected = entry.selected,
      }
    end
  end
  self.preview_mutation_state = state_or_reason
  return true
end

local function restore_mutation_selections(self, before)
  for _, snapshot in ipairs(before.user_selections or {}) do
    local valid = call_api(
      self.api, "ValidatePtr2", self.captured.project,
      snapshot.item, "MediaItem*") == true
    if valid then
      local guid_ok, current_guid = call_api(
        self.api, "GetSetMediaItemInfo_String",
        snapshot.item, "GUID", "", false)
      if guid_ok and current_guid == snapshot.guid then
        call_api(self.api, "SetMediaItemSelected", snapshot.item, snapshot.selected)
        local actual = call_api(self.api, "IsMediaItemSelected", snapshot.item) == true
        if actual ~= snapshot.selected then
          error("selection setter did not take effect for " .. snapshot.guid, 0)
        end
      end
    end
  end
end

function Transaction:end_preview_mutation(allow_background)
  local before = self.preview_mutation_state
  if before == nil then
    return nil, "no preview mutation is active"
  end

  local active, active_reason = active_or_reason(self)
  if not active then return nil, active_reason end
  if allow_background then
    local open, open_reason = project_is_open(self.api, self.captured.project)
    if open == nil then return nil, open_reason end
    if not open then return nil, "captured project is closed" end
  else
    local same, project_reason = same_project_or_reason(self)
    if not same then return nil, project_reason end
  end

  local ok, after_or_reason = pcall(
    enumerate_item_state, self.api, self.captured.project)
  if not ok then
    return nil, "failed to end preview mutation: " .. tostring(after_or_reason)
  end
  for _, entry in ipairs(after_or_reason.items) do
    if before.by_item[entry.item] ~= entry.guid
        and not item_identity_exists(
          self.tracked_preview_items, entry.item, entry.guid) then
      self.tracked_preview_items[#self.tracked_preview_items + 1] = {
        item = entry.item,
        guid = entry.guid,
      }
    end
  end

  local restored, restore_reason = pcall(restore_mutation_selections, self, before)
  if not restored then
    return nil, "failed to restore user Item selection after preview mutation: "
      .. tostring(restore_reason)
  end
  self.preview_mutation_state = nil
  return true
end

local function attempt_restore(errors, label, callback)
  local ok, reason = pcall(callback)
  if not ok then
    errors[#errors + 1] = label .. " failed: " .. tostring(reason)
  end
end

local function restore_preview_range_state(self)
  local preview = self.preview_range_state
  if preview == nil then return true end

  local errors = {}
  attempt_restore(errors, "repeat restore", function()
    call_api(self.api, "GetSetRepeatEx", self.captured.project, preview.repeat_state)
    local actual = call_api(self.api, "GetSetRepeatEx", self.captured.project, -1)
    local normalized = is_finite_number(actual) and (actual > 0 and 1 or 0) or nil
    if normalized ~= preview.repeat_state then
      error("repeat setter did not take effect", 0)
    end
  end)
  attempt_restore(errors, "cursor restore", function()
    call_api(self.api, "SetEditCurPos2", self.captured.project,
      preview.cursor, false, false)
    local actual = call_api(self.api, "GetCursorPositionEx", self.captured.project)
    if not same_time(actual, preview.cursor) then
      error("cursor setter did not take effect", 0)
    end
  end)
  attempt_restore(errors, "loop points restore", function()
    call_api(self.api, "GetSet_LoopTimeRange2", self.captured.project,
      true, true, preview.loop_start, preview.loop_end, false)
    local actual_start, actual_finish = call_api(
      self.api, "GetSet_LoopTimeRange2", self.captured.project,
      false, true, 0, 0, false)
    if not same_time(actual_start, preview.loop_start)
        or not same_time(actual_finish, preview.loop_end) then
      error("loop points setter did not take effect", 0)
    end
  end)

  if #errors > 0 then return nil, table.concat(errors, "; ") end
  self.preview_range_state = nil
  return true
end

local function read_play_state(self)
  local play_state = call_api(
    self.api, "GetPlayStateEx", self.captured.project)
  if not is_finite_number(play_state) then
    error("GetPlayStateEx returned an invalid playback state", 0)
  end
  return math.floor(play_state)
end

function Transaction:is_recording()
  local active, active_reason = active_or_reason(self)
  if not active then return nil, active_reason end
  local ok, play_state_or_reason = pcall(read_play_state, self)
  if not ok then
    return nil, "failed to inspect recording state: " .. tostring(play_state_or_reason)
  end
  return (play_state_or_reason & 0x4) ~= 0
end

local function transport_stopped_guard(self, operation)
  local ok, play_state_or_reason = pcall(read_play_state, self)
  if not ok then
    return nil, "failed to inspect transport before " .. operation .. ": "
      .. tostring(play_state_or_reason)
  end
  if play_state_or_reason ~= 0 then
    return nil, "Stop playback/recording before " .. operation
  end
  return true
end

function Transaction:prepare_preview_range(start_time, finish_time)
  local active, active_reason = active_or_reason(self)
  if not active then return nil, active_reason end
  local same, project_reason = same_project_or_reason(self)
  if not same then return nil, project_reason end
  local safe, transport_reason = transport_stopped_guard(self, "preparing preview")
  if not safe then return nil, transport_reason end
  if not is_finite_number(start_time) or not is_finite_number(finish_time)
      or finish_time <= start_time then
    return nil, "preview range must have finite start and finish with finish greater than start"
  end
  if self.preview_range_state ~= nil then
    return nil, "a preview range is already prepared"
  end

  local captured_ok, preview_or_reason = pcall(function()
    local cursor = call_api(self.api, "GetCursorPositionEx", self.captured.project)
    local loop_start, loop_end = call_api(
      self.api, "GetSet_LoopTimeRange2", self.captured.project,
      false, true, 0, 0, false)
    local repeat_state = call_api(
      self.api, "GetSetRepeatEx", self.captured.project, -1)
    if not is_finite_number(cursor) then
      error("GetCursorPositionEx returned an invalid cursor position", 0)
    end
    if not is_finite_number(loop_start) or not is_finite_number(loop_end) then
      error("GetSet_LoopTimeRange2 returned invalid loop points", 0)
    end
    if not is_finite_number(repeat_state) then
      error("GetSetRepeatEx returned an invalid repeat state", 0)
    end
    return {
      cursor = cursor,
      loop_start = loop_start,
      loop_end = loop_end,
      repeat_state = repeat_state > 0 and 1 or 0,
      start = start_time,
      finish = finish_time,
    }
  end)
  if not captured_ok then
    return nil, "failed to capture preview transport state: "
      .. tostring(preview_or_reason)
  end

  self.preview_range_state = preview_or_reason
  local prepared_ok, prepare_reason = pcall(function()
    call_api(self.api, "GetSet_LoopTimeRange2", self.captured.project,
      true, true, start_time, finish_time, false)
    local actual_start, actual_finish = call_api(
      self.api, "GetSet_LoopTimeRange2", self.captured.project,
      false, true, 0, 0, false)
    if not same_time(actual_start, start_time)
        or not same_time(actual_finish, finish_time) then
      error("loop points setter did not take effect", 0)
    end

    call_api(self.api, "SetEditCurPos2", self.captured.project,
      start_time, false, false)
    local actual_cursor = call_api(
      self.api, "GetCursorPositionEx", self.captured.project)
    if not same_time(actual_cursor, start_time) then
      error("cursor setter did not take effect", 0)
    end

    call_api(self.api, "GetSetRepeatEx", self.captured.project, 1)
    local actual_repeat = call_api(
      self.api, "GetSetRepeatEx", self.captured.project, -1)
    if not is_finite_number(actual_repeat) or actual_repeat <= 0 then
      error("repeat setter did not take effect", 0)
    end
  end)
  if prepared_ok then return true end

  local restored, restore_reason = restore_preview_range_state(self)
  local reason = "failed to prepare preview range: " .. tostring(prepare_reason)
  if not restored then
    reason = reason .. "; rollback failed: " .. tostring(restore_reason)
  end
  return nil, reason
end

function Transaction:release_preview_range()
  local active, active_reason = active_or_reason(self)
  if not active then return nil, active_reason end
  local same, project_reason = same_project_or_reason(self)
  if not same then return nil, project_reason end
  local safe, transport_reason = transport_stopped_guard(self, "releasing preview")
  if not safe then return nil, transport_reason end
  local restored, restore_reason = restore_preview_range_state(self)
  if not restored then return nil, restore_reason end
  self.preview_playback_started = false
  return true
end

function Transaction:owns_preview_playback()
  if self.status ~= "active" or not self.preview_playback_started then
    return false
  end
  local preview = self.preview_range_state
  if preview == nil then
    self.preview_playback_started = false
    return false
  end
  if type(self.api.GetPlayPositionEx) ~= "function" then
    return nil, "GetPlayPositionEx is unavailable; preview playback ownership cannot be confirmed"
  end

  local ok, owns_or_reason = pcall(function()
    local play_state = read_play_state(self)
    if (play_state & 0x4) ~= 0 or (play_state & 0x3) == 0 then
      return false
    end

    local repeat_state = call_api(
      self.api, "GetSetRepeatEx", self.captured.project, -1)
    if not is_finite_number(repeat_state) or repeat_state <= 0 then
      return false
    end
    local loop_start, loop_finish = call_api(
      self.api, "GetSet_LoopTimeRange2", self.captured.project,
      false, true, 0, 0, false)
    if not same_time(loop_start, preview.start)
        or not same_time(loop_finish, preview.finish) then
      return false
    end

    local position = call_api(
      self.api, "GetPlayPositionEx", self.captured.project)
    if not is_finite_number(position)
        or position < preview.start - 1e-9
        or position > preview.finish + 1e-9 then
      return false
    end
    return true
  end)
  if not ok then
    return nil, "failed to verify preview playback ownership: "
      .. tostring(owns_or_reason)
  end
  if not owns_or_reason then
    self.preview_playback_started = false
    return false
  end
  return true
end

log_message = function(api, message)
  if type(api.ShowConsoleMsg) == "function" then
    pcall(api.ShowConsoleMsg, "LoopMaker state: " .. tostring(message) .. "\n")
  end
end

local function append_warning(warnings, seen, message)
  if not seen[message] then
    warnings[#warnings + 1] = message
    seen[message] = true
  end
end

local function validate_original_item(self, snapshot, warnings, warning_set)
  local valid = call_api(
    self.api, "ValidatePtr2", self.captured.project, snapshot.item, "MediaItem*") == true
  snapshot.valid = valid
  if not valid then
    append_warning(warnings, warning_set,
      "initial item is invalid: " .. tostring(snapshot.guid))
    return false
  end

  local guid_ok, current_guid = call_api(
    self.api, "GetSetMediaItemInfo_String", snapshot.item, "GUID", "", false)
  if not guid_ok or current_guid ~= snapshot.guid then
    snapshot.valid = false
    append_warning(warnings, warning_set,
      "initial item GUID no longer matches: " .. tostring(snapshot.guid))
    return false
  end
  return true
end

local function original_item_matches(self, snapshot)
  local valid = call_api(
    self.api, "ValidatePtr2", self.captured.project,
    snapshot.item, "MediaItem*") == true
  if not valid then return false end
  return read_guid(self.api, snapshot.item) == snapshot.guid
end

local function restore_item_chunk(self, snapshot, item)
  local restored = call_api(
    self.api, "SetItemStateChunk", item, snapshot.chunk, false)
  if restored == false then
    error("SetItemStateChunk returned false for " .. snapshot.guid, 0)
  end
  local chunk_ok, actual_chunk = call_api(
    self.api, "GetItemStateChunk", item, "", false)
  if not chunk_ok or actual_chunk ~= snapshot.chunk then
    error("chunk setter did not take effect for " .. snapshot.guid, 0)
  end
end

local function cleanup_rebuilt_item(self, track, item)
  local valid = call_api(
    self.api, "ValidatePtr2", self.captured.project, item, "MediaItem*") == true
  if not valid then return true end
  local deleted = call_api(self.api, "DeleteTrackMediaItem", track, item)
  if not deleted then
    error("failed to delete half-created replacement Item", 0)
  end
  return true
end

local function rebuild_original_item(self, snapshot)
  local track_valid = call_api(
    self.api, "ValidatePtr2", self.captured.project,
    snapshot.track, "MediaTrack*") == true
  if not track_valid then
    error("original track is invalid for " .. snapshot.guid, 0)
  end

  local replacement = call_api(self.api, "AddMediaItemToTrack", snapshot.track)
  if replacement == nil then
    error("AddMediaItemToTrack failed for " .. snapshot.guid, 0)
  end

  local rebuilt, rebuild_reason = pcall(function()
    restore_item_chunk(self, snapshot, replacement)
    local current_guid = read_guid(self.api, replacement)
    if current_guid ~= snapshot.guid then
      error("rebuilt Item GUID does not match " .. snapshot.guid, 0)
    end
  end)
  if not rebuilt then
    local cleaned, cleanup_reason = pcall(
      cleanup_rebuilt_item, self, snapshot.track, replacement)
    local reason = tostring(rebuild_reason)
    if not cleaned then
      reason = reason .. "; replacement cleanup failed: " .. tostring(cleanup_reason)
    end
    error(reason, 0)
  end

  snapshot.item = replacement
  snapshot.valid = true
  if snapshot.all_item_snapshot ~= nil then
    snapshot.all_item_snapshot.item = replacement
    snapshot.all_item_snapshot.valid = true
  end
  return replacement
end

local function restore_selected_item(self, snapshot)
  if original_item_matches(self, snapshot) then
    restore_item_chunk(self, snapshot, snapshot.item)
    snapshot.valid = true
    return snapshot.item
  end
  return rebuild_original_item(self, snapshot)
end

function Transaction:sync_preview_playback()
  local active, active_reason = active_or_reason(self)
  if not active then return nil, active_reason end
  if not self.preview_playback_started and self.preview_range_state == nil then
    return false, {}
  end

  local read_ok, play_state = pcall(read_play_state, self)
  if not read_ok then
    return nil, "failed to sync preview playback: " .. tostring(play_state)
  end
  if play_state ~= 0 then
    return false, { transport_state = play_state }
  end

  self.preview_playback_started = false
  if self.preview_range_state == nil then return true, {} end
  local released, release_reason = self:release_preview_range()
  if not released then return nil, release_reason end
  return true, {}
end

local function copy_tracked_items(source)
  local result = {}
  for _, entry in ipairs(source or {}) do
    result[#result + 1] = { item = entry.item, guid = entry.guid }
  end
  return result
end

local function delete_preview_items(self, warnings, warning_set)
  local api = self.api
  local project = self.captured.project
  local tracked = copy_tracked_items(self.tracked_preview_items)
  local remaining_reverse = {}

  for index = #tracked, 1, -1 do
    local entry = tracked[index]
    local valid = call_api(
      api, "ValidatePtr2", project, entry.item, "MediaItem*") == true
    if valid then
      local guid_ok, current_guid = call_api(
        api, "GetSetMediaItemInfo_String", entry.item, "GUID", "", false)
      if not guid_ok or type(current_guid) ~= "string" or current_guid == "" then
        append_warning(warnings, warning_set,
          "could not verify tracked preview item GUID: " .. tostring(entry.guid))
        remaining_reverse[#remaining_reverse + 1] = entry
      elseif current_guid == entry.guid then
        local track = call_api(api, "GetMediaItemTrack", entry.item)
        if track == nil then
          append_warning(warnings, warning_set,
            "preview item has no track and was not deleted: " .. entry.guid)
          remaining_reverse[#remaining_reverse + 1] = entry
        else
          local deleted = call_api(api, "DeleteTrackMediaItem", track, entry.item)
          if not deleted then
            append_warning(warnings, warning_set,
              "failed to delete preview item: " .. entry.guid)
            remaining_reverse[#remaining_reverse + 1] = entry
          end
        end
      end
    end
  end

  local remaining = {}
  for index = #remaining_reverse, 1, -1 do
    remaining[#remaining + 1] = remaining_reverse[index]
  end
  return remaining
end

local function restore_captured_transport(self)
  local api = self.api
  local captured = self.captured
  local errors = {}

  attempt_restore(errors, "time selection restore", function()
    call_api(api, "GetSet_LoopTimeRange2", captured.project,
      true, false, captured.time_start, captured.time_end, false)
    local actual_start, actual_finish = call_api(
      api, "GetSet_LoopTimeRange2", captured.project,
      false, false, 0, 0, false)
    if not same_time(actual_start, captured.time_start)
        or not same_time(actual_finish, captured.time_end) then
      error("time selection setter did not take effect", 0)
    end
  end)
  attempt_restore(errors, "loop points restore", function()
    call_api(api, "GetSet_LoopTimeRange2", captured.project,
      true, true, captured.loop_start, captured.loop_end, false)
    local actual_start, actual_finish = call_api(
      api, "GetSet_LoopTimeRange2", captured.project,
      false, true, 0, 0, false)
    if not same_time(actual_start, captured.loop_start)
        or not same_time(actual_finish, captured.loop_end) then
      error("loop points setter did not take effect", 0)
    end
  end)
  attempt_restore(errors, "cursor restore", function()
    call_api(api, "SetEditCurPos2", captured.project, captured.cursor, false, false)
    local actual = call_api(api, "GetCursorPositionEx", captured.project)
    if not same_time(actual, captured.cursor) then
      error("cursor setter did not take effect", 0)
    end
  end)
  attempt_restore(errors, "repeat restore", function()
    call_api(api, "GetSetRepeatEx", captured.project, captured.repeat_state)
    local actual = call_api(api, "GetSetRepeatEx", captured.project, -1)
    local normalized = is_finite_number(actual) and (actual > 0 and 1 or 0) or nil
    if normalized ~= captured.repeat_state then
      error("repeat setter did not take effect", 0)
    end
  end)

  if #errors > 0 then return nil, table.concat(errors, "; ") end
  return true
end

local function restore_captured_state(self, allow_background)
  local warnings = {}
  local warning_set = {}
  local api = self.api
  local captured = self.captured

  local remaining_tracked = delete_preview_items(self, warnings, warning_set)

  for _, snapshot in ipairs(captured.selected_items) do
    restore_selected_item(self, snapshot)
  end

  for _, snapshot in ipairs(captured.all_items) do
    if validate_original_item(self, snapshot, warnings, warning_set) then
      call_api(api, "SetMediaItemSelected", snapshot.item, snapshot.selected)
    end
  end

  local transport_restored, transport_reason = restore_captured_transport(self)
  if not transport_restored then error(transport_reason, 0) end
  call_api(api, "UpdateArrange")

  self.preview_playback_started = false
  self.preview_range_state = nil
  self.tracked_preview_items = remaining_tracked
  return warnings, remaining_tracked
end

local function with_ui_refresh(api, callback)
  local entered, enter_error = pcall(api.PreventUIRefresh, 1)
  if not entered then
    return nil, "PreventUIRefresh(1) failed: " .. tostring(enter_error)
  end

  local operation_results = { pcall(callback) }
  local exited, exit_error = pcall(api.PreventUIRefresh, -1)

  if not operation_results[1] then
    local reason = tostring(operation_results[2])
    if not exited then
      reason = reason .. "; PreventUIRefresh(-1) failed: " .. tostring(exit_error)
    end
    return nil, reason
  end
  if not exited then
    return nil, "PreventUIRefresh(-1) failed: " .. tostring(exit_error)
  end
  return true, table.unpack(operation_results, 2)
end

local function end_undo(self, description)
  if not self.undo_open then
    return true
  end
  local ok, result = pcall(
    self.api.Undo_EndBlock2, self.captured.project, description, -1)
  if not ok then
    return nil, "Undo_EndBlock2 failed: " .. tostring(result)
  end
  if result == false then
    return nil, "Undo_EndBlock2 returned false"
  end
  self.undo_open = false
  return true
end

function Transaction:mark_preview_playback_started()
  local active, reason = active_or_reason(self)
  if not active then
    return nil, reason
  end
  self.preview_playback_started = true
  return true
end

local function restore_internal(self, allow_background, final)
  local active, active_reason = active_or_reason(self)
  if not active then
    return nil, active_reason
  end
  if allow_background then
    local open, open_reason = project_is_open(self.api, self.captured.project)
    if open == nil then
      return nil, open_reason
    end
    if not open then
      return nil, "captured project is closed"
    end
  else
    local same, project_reason = same_project_or_reason(self)
    if not same then
      return nil, project_reason
    end
  end

  if self.preview_mutation_state ~= nil then
    local ended, end_reason = self:end_preview_mutation(allow_background)
    if not ended then
      return nil, "failed to end preview mutation before restore: "
        .. tostring(end_reason)
    end
  end

  local safe, transport_reason = transport_stopped_guard(self, "restoring LoopMaker")
  if not safe then return nil, transport_reason end

  local ok, warnings_or_reason = with_ui_refresh(self.api, function()
    local warnings, remaining_tracked = restore_captured_state(self, allow_background)
    if final and #remaining_tracked > 0 then
      error("tracked preview Items remain; retry Cancel after resolving deletion warnings: "
        .. table.concat(warnings, "; "), 0)
    end
    if final then
      local ended, end_reason = end_undo(self, "LoopMaker: Cancel")
      if not ended then
        error(end_reason, 0)
      end
    end
    return warnings
  end)
  if not ok then
    return nil, (final and "failed to cancel transaction: "
      or "failed to restore project state: ") .. tostring(warnings_or_reason)
  end

  if final then
    self.status = "cancelled"
    self.final_warnings = warnings_or_reason
  end
  return true, warnings_or_reason
end

function Transaction:restore_for_rebuild()
  return restore_internal(self, false, false)
end

function Transaction:restore()
  if self.status == "cancelled" then
    return true, self.final_warnings or {}
  end
  return restore_internal(self, false, true)
end

function Transaction:restore_in_background()
  if self.status == "cancelled" then
    return true, self.final_warnings or {}
  end
  return restore_internal(self, true, true)
end

function Transaction:mark_applied()
  local active, active_reason = active_or_reason(self)
  if not active then
    return nil, active_reason
  end
  local same, project_reason = same_project_or_reason(self)
  if not same then
    return nil, project_reason
  end
  if self.preview_mutation_state ~= nil then
    local ended, end_reason = self:end_preview_mutation()
    if not ended then return nil, end_reason end
  end
  local safe, transport_reason = transport_stopped_guard(self, "applying LoopMaker")
  if not safe then return nil, transport_reason end

  local cleanup_errors = {}
  local released, release_reason = restore_preview_range_state(self)
  if not released then
    cleanup_errors[#cleanup_errors + 1] = "preview range release failed: "
      .. tostring(release_reason)
  end
  if #cleanup_errors > 0 then
    return nil, table.concat(cleanup_errors, "; ")
  end

  local ended, end_reason = end_undo(self, "LoopMaker: Apply")
  if not ended then
    return nil, end_reason
  end
  self.status = "applied"
  self.preview_mutation_state = nil
  self.tracked_preview_items = {}
  self.final_warnings = {}
  return true, self.final_warnings
end

function Transaction:abandon()
  if self.status ~= "active" then
    return true, "transaction is already closed"
  end

  local open, open_reason = project_is_open(self.api, self.captured.project)
  if open == nil then
    return nil, open_reason
  end
  if not open then
    self.status = "abandoned"
    self.undo_open = false
    self.preview_playback_started = false
    self.preview_range_state = nil
    self.preview_mutation_state = nil
    self.tracked_preview_items = {}
    return true, "captured project is closed; its Undo context is no longer available"
  end

  local ended, end_reason = end_undo(self, "LoopMaker: Abandon")
  if not ended then
    return nil, end_reason
  end
  self.status = "abandoned"
  self.preview_playback_started = false
  self.preview_range_state = nil
  self.preview_mutation_state = nil
  self.tracked_preview_items = {}
  return true
end

M.REQUIRED_API_FUNCTIONS = REQUIRED_API_FUNCTIONS
M.project_is_open = project_is_open

return M
