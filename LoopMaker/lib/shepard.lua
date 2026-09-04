local core = require("lib.core")
local loop_builder = require("lib.loop_builder")
local naming = require("lib.naming")
local settings_module = require("lib.settings")

local M = {}

local EPSILON = 1e-9
local MAX_LAYERS = 64

local function call_api(api, name, ...)
  if type(api) ~= "table" or type(api[name]) ~= "function" then
    error("reaper_api is missing " .. name, 0)
  end
  local results = { pcall(api[name], ...) }
  if not results[1] then
    error(name .. " failed: " .. tostring(results[2]), 0)
  end
  return table.unpack(results, 2)
end

local function set_api(api, name, ...)
  local result = call_api(api, name, ...)
  if result == false then error(name .. " returned false", 0) end
  return true
end

local function validate_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return nil, "snapshot must be a table"
  end
  for _, field in ipairs({ "position", "length", "start_offset", "playrate" }) do
    if not core.is_finite_number(snapshot[field]) then
      return nil, "snapshot has invalid " .. field
    end
  end
  if snapshot.length <= 0 then return nil, "snapshot length must be positive" end
  if snapshot.start_offset < 0 then return nil, "snapshot start_offset must not be negative" end
  if snapshot.playrate <= 0 then return nil, "snapshot playrate must be positive" end
  if snapshot.item == nil or snapshot.take == nil or snapshot.track == nil then
    return nil, "snapshot is missing item, take, or track"
  end
  if type(snapshot.chunk) ~= "string" or snapshot.chunk == "" then
    return nil, "snapshot chunk is required"
  end
  return true
end

function M.build_plan(snapshot, input_settings)
  local valid, reason = validate_snapshot(snapshot)
  if not valid then return nil, reason end

  local sanitized = settings_module.sanitize(input_settings)
  local lane_count = 2 ^ sanitized.loops
  if not core.is_finite_number(lane_count) or lane_count > MAX_LAYERS then
    return nil, "Shepard layer count exceeds the safe maximum of " .. MAX_LAYERS
  end

  local loop_length = snapshot.length / lane_count
  if not core.is_finite_number(loop_length) or loop_length <= 0 then
    return nil, "Shepard loop length must be a finite positive number"
  end

  local pitch_step = sanitized.pitch / lane_count
  local first_pitch = -((lane_count - 1) / 2) * pitch_step
  local volume = 1 / math.sqrt(lane_count)
  local crossfade_length = core.crossfade_length(
    loop_length, sanitized.cf_ratio, sanitized.cf_max)
  local lanes = {}

  for zero_based_index = 0, lane_count - 1 do
    local pitch_start = first_pitch + zero_based_index * pitch_step
    lanes[#lanes + 1] = {
      index = zero_based_index,
      position = snapshot.position,
      length = loop_length,
      source_project_start = snapshot.position + zero_based_index * loop_length,
      source_offset = zero_based_index * loop_length,
      wrap_source = false,
      fade_in = 0,
      fade_out = 0,
      fade_shape = sanitized.cf_curve,
      volume = volume,
      pitch_points = {
        { time = 0, value = pitch_start, shape = 0, tension = 0 },
        { time = loop_length, value = pitch_start + pitch_step,
          shape = 0, tension = 0 },
      },
    }
  end

  local octave_count = sanitized.pitch / 12
  local octave_equivalent = math.abs(octave_count - core.round(octave_count))
    <= EPSILON
  local warning
  if not octave_equivalent then
    warning = "Shepard pitch is not an integer number of octaves; "
      .. "the loop boundary may not be pitch-equivalent"
  end

  return {
    source_snapshot = snapshot,
    settings = core.deep_copy(sanitized),
    variation_index = 0,
    lane_count = lane_count,
    loop_length = loop_length,
    crossfade_length = crossfade_length,
    pitch_step = pitch_step,
    lanes = lanes,
    warning = warning,
  }
end

function M.build_pitch_lanes(length, pitch, loops, input_settings)
  local settings = core.deep_copy(type(input_settings) == "table" and input_settings or {})
  settings.pitch = pitch
  settings.loops = loops
  local placeholder = {
    item = true,
    take = true,
    track = true,
    position = 0,
    length = length,
    start_offset = 0,
    playrate = 1,
    source_length = length,
    chunk = "<ITEM\n<TAKE\n<SOURCE EMPTY\n>\n>\n>\n",
  }
  local plan, reason = M.build_plan(placeholder, settings)
  if not plan then return nil, reason end
  return plan.lanes, plan
end

function M.plan_items(snapshots, input_settings)
  if type(snapshots) ~= "table" then return nil, "snapshots must be a table" end
  local plans = {}
  for index, snapshot in ipairs(snapshots) do
    local plan, reason = M.build_plan(snapshot, input_settings)
    if not plan then
      return nil, "snapshot " .. index .. ": " .. tostring(reason)
    end
    plan.variation_index = index - 1
    plans[#plans + 1] = plan
  end
  return plans
end

local function split_lines(chunk)
  local newline = chunk:find("\r\n", 1, true) and "\r\n" or "\n"
  local lines = {}
  local start = 1
  while true do
    local finish = chunk:find(newline, start, true)
    if not finish then
      lines[#lines + 1] = chunk:sub(start)
      break
    end
    lines[#lines + 1] = chunk:sub(start, finish - 1)
    start = finish + #newline
  end
  return lines, newline
end

local function take_ranges(lines)
  local ranges = {}
  local depth = 0
  local current
  for index, line in ipairs(lines) do
    if line:match("^%s*<") then
      depth = depth + 1
      if line:match("^%s*<TAKE%s*$") or line:match("^%s*<TAKE[%s>]") then
        current = { first = index, depth = depth }
      end
    elseif line:match("^%s*>%s*$") then
      if current and depth == current.depth then
        current.last = index
        ranges[#ranges + 1] = current
        current = nil
      end
      depth = depth - 1
    end
  end
  return ranges
end

local function range_has_guid(lines, range, guid)
  if type(guid) ~= "string" or guid == "" then return false end
  for index = range.first + 1, range.last - 1 do
    local value = lines[index]:match("^%s*GUID%s+(%b{})%s*$")
    if value == guid then return true end
  end
  return false
end

local function active_take_guid(reaper_api, take)
  if type(reaper_api.GetSetMediaItemTakeInfo_String) ~= "function" then return nil end
  local ok, retval, guid = pcall(
    reaper_api.GetSetMediaItemTakeInfo_String, take, "GUID", "", false)
  if ok and retval == true and type(guid) == "string" and guid ~= "" then
    return guid
  end
  return nil
end

local function pitch_envelope_lines(reaper_api)
  local lines = { "<PITCHENV" }
  if type(reaper_api.genGuid) == "function" then
    local ok, guid = pcall(reaper_api.genGuid)
    if ok and type(guid) == "string" and guid:match("^%b{}$") then
      lines[#lines + 1] = "EGUID " .. guid
    end
  end
  lines[#lines + 1] = "ACT 1 -1"
  lines[#lines + 1] = "VIS 1 1 1"
  lines[#lines + 1] = "LANEHEIGHT 0 0"
  lines[#lines + 1] = "ARM 0"
  lines[#lines + 1] = "DEFSHAPE 0 -1 -1"
  lines[#lines + 1] = ">"
  return lines
end

local function insert_pitch_envelope(reaper_api, take, item, chunk)
  local lines, newline = split_lines(chunk)
  local ranges = take_ranges(lines)
  if #ranges == 0 then return nil, "item chunk has no TAKE block" end

  local target
  local guid = active_take_guid(reaper_api, take)
  if guid then
    for _, range in ipairs(ranges) do
      if range_has_guid(lines, range, guid) then target = range break end
    end
    if not target then return nil, "active take GUID was not found in the item chunk" end
  elseif #ranges == 1 then
    target = ranges[1]
  else
    return nil, "cannot identify the active take in a multi-take item"
  end

  local insert_at = target.last
  local depth = target.depth
  for index = target.first + 1, target.last - 1 do
    local line = lines[index]
    if line:match("^%s*<SOURCE[%s>]") and depth == target.depth then
      insert_at = index
      break
    end
    if line:match("^%s*<") then
      depth = depth + 1
    elseif line:match("^%s*>%s*$") then
      depth = depth - 1
    end
  end

  local envelope = pitch_envelope_lines(reaper_api)
  for index = #envelope, 1, -1 do
    table.insert(lines, insert_at, envelope[index])
  end
  local updated = table.concat(lines, newline)
  set_api(reaper_api, "SetItemStateChunk", item, updated, false)
  return updated
end

function M.ensure_pitch_envelope(reaper_api, take)
  if take == nil then return nil, "take is required" end
  for _, name in ipairs({
    "GetTakeEnvelopeByName", "GetMediaItemTake_Item", "GetItemStateChunk",
    "SetItemStateChunk", "GetActiveTake",
  }) do
    if type(reaper_api) ~= "table" or type(reaper_api[name]) ~= "function" then
      return nil, "reaper_api is missing " .. name
    end
  end

  local ok, envelope_or_error, refreshed_take = pcall(function()
    local envelope = call_api(reaper_api, "GetTakeEnvelopeByName", take, "Pitch")
    if envelope ~= nil then return envelope, take end

    local item = call_api(reaper_api, "GetMediaItemTake_Item", take)
    if item == nil then error("take has no media item", 0) end
    local chunk_ok, chunk = call_api(
      reaper_api, "GetItemStateChunk", item, "", false)
    if chunk_ok ~= true or type(chunk) ~= "string" then
      error("GetItemStateChunk failed", 0)
    end
    local updated, insert_reason = insert_pitch_envelope(
      reaper_api, take, item, chunk)
    if not updated then error(insert_reason, 0) end

    local current_take = call_api(reaper_api, "GetActiveTake", item)
    if current_take == nil then error("item has no active take after chunk update", 0) end
    envelope = call_api(reaper_api, "GetTakeEnvelopeByName", current_take, "Pitch")
    if envelope == nil then error("REAPER did not create the Pitch envelope", 0) end
    return envelope, current_take
  end)
  if not ok then return nil, "failed to ensure Pitch envelope: " .. tostring(envelope_or_error) end
  return envelope_or_error, nil, refreshed_take
end

function M.apply_pitch_envelope(reaper_api, envelope, points, duration)
  if envelope == nil then return nil, "envelope is required" end
  if type(points) ~= "table" or #points < 2 then
    return nil, "at least two pitch points are required"
  end
  if not core.is_finite_number(duration) or duration <= 0 then
    return nil, "duration must be a finite positive number"
  end
  for _, name in ipairs({
    "DeleteEnvelopePointRange", "InsertEnvelopePoint", "Envelope_SortPoints",
  }) do
    if type(reaper_api) ~= "table" or type(reaper_api[name]) ~= "function" then
      return nil, "reaper_api is missing " .. name
    end
  end

  local previous_time = -math.huge
  for index, point in ipairs(points) do
    if type(point) ~= "table"
        or not core.is_finite_number(point.time)
        or not core.is_finite_number(point.value)
        or point.time < 0 or point.time > duration
        or point.time <= previous_time then
      return nil, "pitch point " .. index .. " is invalid or not strictly increasing"
    end
    previous_time = point.time
  end

  local ok, operation_error = pcall(function()
    set_api(reaper_api, "DeleteEnvelopePointRange", envelope,
      -EPSILON, duration + EPSILON)
    for _, point in ipairs(points) do
      set_api(reaper_api, "InsertEnvelopePoint", envelope,
        point.time, point.value, point.shape or 0, point.tension or 0,
        false, true)
    end
    set_api(reaper_api, "Envelope_SortPoints", envelope)
  end)
  if not ok then
    return nil, "failed to write Pitch envelope: " .. tostring(operation_error)
  end
  return true
end

local APPLY_API_FUNCTIONS = {
  "CountMediaItems",
  "GetMediaItem",
  "SetMediaItemSelected",
  "IsMediaItemSelected",
  "ValidatePtr2",
  "AddMediaItemToTrack",
  "genGuid",
  "SetItemStateChunk",
  "GetItemStateChunk",
  "GetActiveTake",
  "GetTakeEnvelopeByName",
  "GetMediaItemTake_Item",
  "GetMediaItem_Track",
  "SetMediaItemInfo_Value",
  "SetMediaItemTakeInfo_Value",
  "GetMediaItemTakeInfo_Value",
  "GetSetMediaItemTakeInfo_String",
  "DeleteEnvelopePointRange",
  "InsertEnvelopePoint",
  "Envelope_SortPoints",
  "DeleteTrackMediaItem",
}

local function validate_api_functions(reaper_api, names)
  if type(reaper_api) ~= "table" then return nil, "reaper_api must be a table" end
  for _, name in ipairs(names) do
    if type(reaper_api[name]) ~= "function" then
      return nil, "reaper_api is missing " .. name
    end
  end
  return true
end

local function nonnegative_integer(value)
  return core.is_finite_number(value) and value >= 0
    and value == math.floor(value)
end

local function output_color(options, plan, output_index, enabled)
  if not enabled then return 0 end
  local color = options.color
  if type(color) == "function" then
    local ok, result = pcall(color, plan, output_index)
    if not ok then return nil, "color function failed: " .. tostring(result) end
    color = result
  end
  if not nonnegative_integer(color) then
    return nil, "color must be a non-negative native integer when color_items is enabled"
  end
  return color
end

local function lane_source_start(snapshot, lane)
  local source_start = snapshot.start_offset
    + (lane.source_project_start - snapshot.position) * snapshot.playrate
  local source_finish = source_start + lane.length * snapshot.playrate
  if not core.is_finite_number(source_start)
      or not core.is_finite_number(source_finish) then
    return nil, "Shepard lane source range must be finite"
  end
  if source_start < -EPSILON then
    return nil, "Shepard lane source range starts before the available source"
  end
  if not core.is_finite_number(snapshot.source_length) then
    return nil, "Shepard source length is unavailable"
  end
  if source_finish > snapshot.source_length + EPSILON then
    return nil, "Shepard lane source range exceeds the available source"
  end
  return math.max(0, source_start)
end

local function apply_original_lane_geometry(reaper_api, snapshot, lane)
  local source_start, reason = lane_source_start(snapshot, lane)
  if not source_start then error(reason, 0) end
  if not core.is_finite_number(lane.position)
      or not core.is_finite_number(lane.length) or lane.length <= 0 then
    error("Shepard lane has invalid position or length", 0)
  end
  if lane.wrap_source then error("Shepard source wrapping is not supported", 0) end

  local item = snapshot.item
  local take = snapshot.take
  set_api(reaper_api, "SetMediaItemInfo_Value", item, "D_POSITION", lane.position)
  set_api(reaper_api, "SetMediaItemInfo_Value", item, "D_LENGTH", lane.length)
  set_api(reaper_api, "SetMediaItemInfo_Value", item, "B_LOOPSRC", 0)
  set_api(reaper_api, "SetMediaItemInfo_Value", item, "D_FADEINLEN_AUTO", -1)
  set_api(reaper_api, "SetMediaItemInfo_Value", item, "D_FADEOUTLEN_AUTO", -1)
  set_api(reaper_api, "SetMediaItemInfo_Value", item, "D_FADEINLEN", lane.fade_in or 0)
  set_api(reaper_api, "SetMediaItemInfo_Value", item, "D_FADEOUTLEN", lane.fade_out or 0)
  if (lane.fade_in or 0) > 0 then
    set_api(reaper_api, "SetMediaItemInfo_Value", item,
      "C_FADEINSHAPE", lane.fade_shape or 0)
  end
  if (lane.fade_out or 0) > 0 then
    set_api(reaper_api, "SetMediaItemInfo_Value", item,
      "C_FADEOUTSHAPE", lane.fade_shape or 0)
  end
  set_api(reaper_api, "SetMediaItemTakeInfo_Value", take,
    "D_STARTOFFS", source_start)
  set_api(reaper_api, "SetMediaItemTakeInfo_Value", take,
    "D_PLAYRATE", snapshot.playrate)
end

local function configure_lane(reaper_api, item, take, lane, loop_name,
    color, color_enabled)
  local envelope, envelope_reason, refreshed_take = M.ensure_pitch_envelope(
    reaper_api, take)
  if not envelope then error(envelope_reason, 0) end
  take = refreshed_take or take

  local existing_volume = call_api(
    reaper_api, "GetMediaItemTakeInfo_Value", take, "D_VOL")
  if not core.is_finite_number(existing_volume) or existing_volume < 0 then
    error("take volume must be a finite non-negative number", 0)
  end
  local volume = existing_volume * lane.volume
  if not core.is_finite_number(volume) then
    error("normalized Shepard lane volume must be finite", 0)
  end
  set_api(reaper_api, "SetMediaItemTakeInfo_Value", take, "D_VOL", volume)

  local applied, pitch_reason = M.apply_pitch_envelope(
    reaper_api, envelope, lane.pitch_points, lane.length)
  if not applied then error(pitch_reason, 0) end
  local named, name_reason = naming.apply_to_take(reaper_api, take, loop_name)
  if not named then error(name_reason, 0) end
  local colored, color_reason = naming.apply_color(
    reaper_api, item, color, color_enabled)
  if not colored then error(color_reason, 0) end
  return take
end

local function cleanup_failed_output(reaper_api, snapshot, clones, restore_original)
  local errors = {}
  for index = #clones, 1, -1 do
    local ok, deleted = pcall(
      reaper_api.DeleteTrackMediaItem, snapshot.track, clones[index])
    if not ok then
      errors[#errors + 1] = "DeleteTrackMediaItem failed: " .. tostring(deleted)
    elseif deleted == false then
      errors[#errors + 1] = "DeleteTrackMediaItem returned false"
    end
  end
  if restore_original then
    local ok, restored = pcall(
      reaper_api.SetItemStateChunk, snapshot.item, snapshot.chunk, false)
    if not ok then
      errors[#errors + 1] = "SetItemStateChunk restore failed: " .. tostring(restored)
    elseif restored == false then
      errors[#errors + 1] = "SetItemStateChunk restore returned false"
    else
      local take_ok, take = pcall(reaper_api.GetActiveTake, snapshot.item)
      if not take_ok or take == nil then
        errors[#errors + 1] = "GetActiveTake failed after original restore: "
          .. tostring(take)
      else
        snapshot.take = take
      end
    end
  end
  if #errors > 0 then return nil, table.concat(errors, "; ") end
  return true
end

local function deselect_project_items(reaper_api, project)
  local count = call_api(reaper_api, "CountMediaItems", project)
  if not nonnegative_integer(count) then
    error("CountMediaItems returned an invalid count", 0)
  end
  for index = 0, count - 1 do
    local item = call_api(reaper_api, "GetMediaItem", project, index)
    if item == nil then error("GetMediaItem returned nil at index " .. index, 0) end
    set_api(reaper_api, "SetMediaItemSelected", item, false)
  end
end

local function capture_project_selection(reaper_api, project)
  local count = call_api(reaper_api, "CountMediaItems", project)
  if not nonnegative_integer(count) then
    error("CountMediaItems returned an invalid count", 0)
  end
  local captured = {}
  for index = 0, count - 1 do
    local item = call_api(reaper_api, "GetMediaItem", project, index)
    if item == nil then error("GetMediaItem returned nil at index " .. index, 0) end
    local selected = call_api(reaper_api, "IsMediaItemSelected", item)
    if type(selected) ~= "boolean" then
      error("IsMediaItemSelected returned an invalid value", 0)
    end
    captured[#captured + 1] = { item = item, selected = selected }
  end
  return captured
end

local function restore_project_selection(reaper_api, project, captured)
  deselect_project_items(reaper_api, project)
  for _, state in ipairs(captured) do
    if state.selected then
      set_api(reaper_api, "SetMediaItemSelected", state.item, true)
    end
  end
end

local function rollback_actions(reaper_api, project, actions, selection)
  local errors = {}
  for index = #actions, 1, -1 do
    local action = actions[index]
    local cleaned, reason = cleanup_failed_output(
      reaper_api, action.snapshot, action.clones, action.reused_original)
    if not cleaned then errors[#errors + 1] = tostring(reason) end
  end
  local selected, selection_error = pcall(
    restore_project_selection, reaper_api, project, selection)
  if not selected then
    errors[#errors + 1] = "selection restore failed: " .. tostring(selection_error)
  end
  if #errors > 0 then return nil, table.concat(errors, "; ") end
  return true
end

function M.apply_plan(reaper_api, plans, options)
  options = options or {}
  if type(options) ~= "table" then return nil, "options must be a table", {} end
  if type(plans) ~= "table" then return nil, "plans must be a table", {} end
  local valid, reason = validate_api_functions(reaper_api, APPLY_API_FUNCTIONS)
  if not valid then return nil, reason, {} end

  local project = options.project
  if project == nil then project = 0 end
  local prepared = {}
  local seen_items = {}
  for plan_index, plan in ipairs(plans) do
    if type(plan) ~= "table" or type(plan.lanes) ~= "table" or #plan.lanes < 1
        or type(plan.source_snapshot) ~= "table" then
      return nil, "Shepard plan " .. plan_index .. " is invalid", {}
    end
    local snapshot = plan.source_snapshot
    local snapshot_valid, snapshot_reason = validate_snapshot(snapshot)
    if not snapshot_valid then
      return nil, "Shepard plan " .. plan_index .. ": " .. snapshot_reason, {}
    end
    if seen_items[snapshot.item] then
      return nil, "Shepard plan " .. plan_index .. " has a duplicate source item", {}
    end
    seen_items[snapshot.item] = true
    for _, pointer in ipairs({
      { value = snapshot.item, kind = "MediaItem*" },
      { value = snapshot.take, kind = "MediaItem_Take*" },
      { value = snapshot.track, kind = "MediaTrack*" },
    }) do
      local pointer_ok, belongs = pcall(
        reaper_api.ValidatePtr2, project, pointer.value, pointer.kind)
      if not pointer_ok then
        return nil, "ValidatePtr2 failed for Shepard plan " .. plan_index
          .. ": " .. tostring(belongs), {}
      end
      if belongs ~= true then
        return nil, "Shepard plan " .. plan_index
          .. " does not belong to the target project", {}
      end
    end
    local take_item_ok, take_item = pcall(
      reaper_api.GetMediaItemTake_Item, snapshot.take)
    if not take_item_ok then
      return nil, "GetMediaItemTake_Item failed for Shepard plan "
        .. plan_index .. ": " .. tostring(take_item), {}
    end
    if take_item ~= snapshot.item then
      return nil, "Shepard plan " .. plan_index
        .. " take does not belong to its source item", {}
    end
    local item_track_ok, item_track = pcall(
      reaper_api.GetMediaItem_Track, snapshot.item)
    if not item_track_ok then
      return nil, "GetMediaItem_Track failed for Shepard plan "
        .. plan_index .. ": " .. tostring(item_track), {}
    end
    if item_track ~= snapshot.track then
      return nil, "Shepard plan " .. plan_index
        .. " item does not belong to its source track", {}
    end
    local sanitized = settings_module.sanitize(options.settings or plan.settings)
    local color, color_reason = output_color(
      options, plan, plan_index, sanitized.color_items)
    if color_reason then return nil, color_reason, {} end
    local name_index = nonnegative_integer(plan.variation_index)
      and plan.variation_index or plan_index - 1
    local loop_name, name_reason = naming.build(
      snapshot.name, sanitized, name_index)
    if not loop_name then return nil, name_reason, {} end
    prepared[plan_index] = {
      settings = sanitized,
      color = color,
      loop_name = loop_name,
      name_index = name_index,
    }
  end
  local selection_ok, initial_selection = pcall(
    capture_project_selection, reaper_api, project)
  if not selection_ok then
    return nil, "failed to capture project selection: "
      .. tostring(initial_selection), {}
  end

  local outputs = {}
  local warnings = {}
  local used_original = {}
  local applied_actions = {}

  for plan_index, plan in ipairs(plans) do
    local snapshot = plan.source_snapshot
    local setup = prepared[plan_index]
    local output = {
      plan = plan,
      name_index = setup.name_index,
      items = {},
      takes = {},
    }
    local action = {
      snapshot = snapshot,
      clones = {},
      reused_original = false,
    }
    applied_actions[#applied_actions + 1] = action

    local ok, operation_error = pcall(function()
      for lane_index, lane in ipairs(plan.lanes) do
        local item
        local take
        if not used_original[snapshot.item] and lane_index == 1 then
          item = snapshot.item
          take = snapshot.take
          action.reused_original = true
          apply_original_lane_geometry(reaper_api, snapshot, lane)
        else
          item, take = loop_builder.clone_from_chunk(reaper_api, snapshot, lane)
          if not item then
            error("Shepard plan " .. plan_index .. " lane " .. lane_index
              .. " failed: " .. tostring(take), 0)
          end
          action.clones[#action.clones + 1] = item
        end
        take = configure_lane(reaper_api, item, take, lane,
          setup.loop_name, setup.color, setup.settings.color_items)
        if action.reused_original and lane_index == 1 then snapshot.take = take end
        output.items[#output.items + 1] = item
        output.takes[#output.takes + 1] = take
      end
      output.main = output.items[1]
    end)

    if not ok then
      local rolled_back, rollback_reason = rollback_actions(
        reaper_api, project, applied_actions, initial_selection)
      local rollback_status = rolled_back and "all outputs rolled back"
        or "rollback failed: " .. tostring(rollback_reason)
      return nil, "failed to apply Shepard plans: " .. tostring(operation_error)
        .. "; " .. rollback_status, {}
    end

    if action.reused_original then used_original[snapshot.item] = true end
    outputs[#outputs + 1] = output
    if type(plan.warning) == "string" and plan.warning ~= "" then
      warnings[#warnings + 1] = plan.warning
    end
  end

  local selection_ok, selection_error = pcall(function()
    deselect_project_items(reaper_api, project)
    for _, output in ipairs(outputs) do
      for _, item in ipairs(output.items) do
        set_api(reaper_api, "SetMediaItemSelected", item, true)
      end
    end
  end)
  if not selection_ok then
    local rolled_back, rollback_reason = rollback_actions(
      reaper_api, project, applied_actions, initial_selection)
    local rollback_status = rolled_back and "all outputs rolled back"
      or "rollback failed: " .. tostring(rollback_reason)
    return nil, "failed to select Shepard outputs: " .. tostring(selection_error)
      .. "; " .. rollback_status, {}
  end
  return outputs, warnings
end

return M
