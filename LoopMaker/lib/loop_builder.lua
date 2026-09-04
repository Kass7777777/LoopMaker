local audio = require("lib.audio")
local core = require("lib.core")
local naming = require("lib.naming")
local settings_module = require("lib.settings")
local timeline_fill = require("lib.timeline_fill")

local M = {}

M.GLUE_COMMAND = 40362
M.BOUNDARY_SAFETY_FADE = 0.003
M.MIN_MULTI_LOOP_SOURCE_SPAN = M.BOUNDARY_SAFETY_FADE * 8
M.MAX_TIMELINE_SLOTS = 10000
M.MAX_TIMELINE_INSTANCES = 20000

local EPSILON = 1e-7

local function append_warning(current, addition)
  if type(addition) ~= "string" or addition == "" then
    return current
  end
  if type(current) ~= "string" or current == "" then
    return addition
  end
  if current:find(addition, 1, true) then
    return current
  end
  return current .. "; " .. addition
end

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
  if result == false then
    error(name .. " returned false", 0)
  end
  return true
end

local function valid_time_selection(time_selection)
  return type(time_selection) == "table"
    and core.is_finite_number(time_selection.start)
    and core.is_finite_number(time_selection.finish)
    and time_selection.finish > time_selection.start
end

function M.resolve_loop_length(snapshot, input_settings, time_selection)
  if type(snapshot) ~= "table" then
    return nil, "snapshot must be a table"
  end

  local sanitized = settings_module.sanitize(input_settings)
  local requested_length
  if valid_time_selection(time_selection) then
    requested_length = time_selection.finish - time_selection.start
  elseif sanitized.loops > 1 then
    requested_length = snapshot.length / sanitized.loops
  else
    requested_length = snapshot.length
  end

  if not core.is_finite_number(requested_length) or requested_length <= 0 then
    return nil, "source span length must be a finite positive number"
  end
  if sanitized.loops > 1
      and requested_length < M.MIN_MULTI_LOOP_SOURCE_SPAN - EPSILON then
    return nil, "multi-loop source span is too short for boundary safety fades"
  end

  local crossfade_length = core.crossfade_length(
    requested_length, sanitized.cf_ratio, sanitized.cf_max)
  local loop_length = requested_length - crossfade_length
  if not core.is_finite_number(crossfade_length)
      or crossfade_length < 0
      or crossfade_length > requested_length / 2
      or loop_length <= 0 then
    return nil, "source span is too short for a valid crossfade"
  end

  return {
    length = loop_length,
    requested_length = requested_length,
    source_span_length = requested_length,
    loop_length = loop_length,
    cf = crossfade_length,
    crossfade_length = crossfade_length,
  }
end

local function build_components(plan)
  local source_start = plan.source_project_start
  local source_end = plan.source_end
  local anchor = plan.boundary_anchor
  local crossfade_length = plan.crossfade_length
  local components = {}

  local boundary_fade = plan.boundary_fade_length or 0
  local main_length = source_end - anchor
  if main_length > 0 then
    components[#components + 1] = {
      kind = "main",
      position = plan.output_position,
      length = main_length,
      source_project_start = anchor,
      fade_in = math.min(
        boundary_fade, math.max(0, main_length - crossfade_length)),
      fade_out = crossfade_length,
      fade_shape = plan.settings.cf_curve,
      wrap_source = false,
    }
  end

  local continuation_length = anchor - source_start
  if continuation_length > 0 then
    components[#components + 1] = {
      kind = "head",
      position = plan.output_position + main_length - crossfade_length,
      length = continuation_length,
      source_project_start = source_start,
      fade_in = crossfade_length,
      fade_out = math.min(
        boundary_fade, math.max(0, continuation_length - crossfade_length)),
      fade_shape = plan.settings.cf_curve,
      wrap_source = false,
    }
  end
  if #components == 1 and boundary_fade > 0 then
    components[1].fade_out = math.min(
      boundary_fade,
      math.max(0, components[1].length - (components[1].fade_in or 0)))
  end
  return components
end

local function validate_snapshot(snapshot, index)
  if type(snapshot) ~= "table" then
    return nil, "snapshot " .. index .. " must be a table"
  end
  local finite_fields = { "position", "length", "start_offset", "playrate" }
  for _, field in ipairs(finite_fields) do
    if not core.is_finite_number(snapshot[field]) then
      return nil, "snapshot " .. index .. " has invalid " .. field
    end
  end
  if snapshot.length <= 0 then
    return nil, "snapshot " .. index .. " length must be positive"
  end
  if snapshot.start_offset < 0 then
    return nil, "snapshot " .. index .. " start_offset must not be negative"
  end
  if snapshot.playrate <= 0 then
    return nil, "snapshot " .. index .. " playrate must be positive"
  end
  if snapshot.item == nil or snapshot.take == nil or snapshot.track == nil then
    return nil, "snapshot " .. index .. " is missing item, take, or track"
  end
  return true
end

local function snapshot_intervals_overlap(left, right)
  return left.position < right.position + right.length
    and right.position < left.position + left.length
end

local function source_warning(snapshot, source_project_start, source_span_length)
  local source_start = snapshot.start_offset
    + (source_project_start - snapshot.position) * snapshot.playrate
  local source_finish = source_start + source_span_length * snapshot.playrate
  if source_start < -EPSILON then
    return "source start is before the available source"
  end
  if core.is_finite_number(snapshot.source_length)
      and source_finish > snapshot.source_length + EPSILON then
    return "source span exceeds the available source for this variation"
  end
  return nil
end

local function geometry_for_interval(source_project_start, source_end,
    boundary_anchor, sanitized)
  if not core.is_finite_number(source_project_start)
      or not core.is_finite_number(source_end)
      or not core.is_finite_number(boundary_anchor) then
    return nil, "source interval and anchor must be finite numbers"
  end
  if source_end <= source_project_start then
    return nil, "source span length must be a finite positive number"
  end
  if boundary_anchor < source_project_start
      or boundary_anchor >= source_end then
    return nil, "boundary anchor must be inside the source interval"
  end

  local source_span_length = source_end - source_project_start
  if sanitized.loops > 1
      and source_span_length < M.MIN_MULTI_LOOP_SOURCE_SPAN - EPSILON then
    return nil, "multi-loop source span is too short for boundary safety fades"
  end
  local nominal_crossfade = core.crossfade_length(
    source_span_length, sanitized.cf_ratio, sanitized.cf_max)
  local boundary_safety_fade = sanitized.loops > 1
    and M.BOUNDARY_SAFETY_FADE
    or 0
  local crossfade_length = math.min(
    nominal_crossfade,
    math.max(0, boundary_anchor - source_project_start
      - boundary_safety_fade),
    math.max(0, source_end - boundary_anchor
      - boundary_safety_fade))
  return {
    source_project_start = source_project_start,
    source_end = source_end,
    source_span_length = source_span_length,
    boundary_anchor = boundary_anchor,
    nominal_crossfade_length = nominal_crossfade,
    crossfade_length = crossfade_length,
    boundary_safety_fade = boundary_safety_fade,
    loop_length = source_span_length - crossfade_length,
    crossfade_shortened = crossfade_length < nominal_crossfade - EPSILON,
  }
end

local function random_fraction(rng)
  local ok, value = pcall(rng)
  if not ok then
    return nil, "rng failed: " .. tostring(value)
  end
  if not core.is_finite_number(value) or value < 0 or value > 1 then
    return nil, "rng must return a finite number in [0, 1]"
  end
  return value
end

local function variation_order(loop_count, shuffle, rng)
  local order = {}
  for index = 0, loop_count - 1 do
    order[#order + 1] = index
  end
  if shuffle and loop_count > 1 then
    for index = loop_count, 2, -1 do
      local fraction, reason = random_fraction(rng)
      if fraction == nil then return nil, reason end
      local swap_index = math.min(index, math.floor(fraction * index) + 1)
      order[index], order[swap_index] = order[swap_index], order[index]
    end
  end
  return order
end

local function source_span_for_output_length(output_length, sanitized)
  local ratio = sanitized.cf_ratio
  if ratio <= 0 then return output_length end
  if sanitized.cf_max > 0 then
    local uncapped_span = output_length / (1 - ratio)
    if uncapped_span * ratio <= sanitized.cf_max + EPSILON then
      return uncapped_span
    end
    return output_length + sanitized.cf_max
  end
  return output_length / (1 - ratio)
end

local function rebuild_plan_geometry(plan, source_project_start, source_end,
    boundary_anchor)
  local snapshot = plan.source_snapshot
  local item_start = snapshot.position
  local item_end = item_start + snapshot.length
  if source_project_start < item_start then
    if source_project_start < item_start - EPSILON then
      return nil, "source interval cannot fit inside the Item"
    end
    source_project_start = item_start
  end
  if source_end > item_end then
    if source_end > item_end + EPSILON then
      return nil, "source interval cannot fit inside the Item"
    end
    source_end = item_end
  end

  local geometry, reason = geometry_for_interval(
    source_project_start, source_end, boundary_anchor, plan.settings)
  if not geometry then return nil, reason end

  plan.source_project_start = geometry.source_project_start
  plan.source_end = geometry.source_end
  plan.source_span_length = geometry.source_span_length
  plan.boundary_anchor = geometry.boundary_anchor
  plan.crossfade_length = geometry.crossfade_length
  plan.loop_length = geometry.loop_length
  plan.boundary_fade_length = geometry.boundary_safety_fade
  plan.wrap_source = false
  if geometry.crossfade_shortened then
    plan.warning = append_warning(plan.warning, "crossfade shortened")
  end
  plan.components = build_components(plan)
  return plan
end

function M.plan_loops(snapshots, input_settings, time_selection, rng)
  if type(snapshots) ~= "table" then
    return nil, "snapshots must be a table"
  end

  local sanitized = settings_module.sanitize(input_settings)
  local has_time_selection = valid_time_selection(time_selection)
  local resolved = {}
  for index, source_snapshot in ipairs(snapshots) do
    local valid, valid_reason = validate_snapshot(source_snapshot, index)
    if not valid then return nil, valid_reason end
    local value, reason = M.resolve_loop_length(
      source_snapshot, sanitized, time_selection)
    if not value then return nil, reason end
    if value.requested_length > source_snapshot.length then
      return nil, "requested source span is longer than the Item"
    end
    resolved[index] = value
  end

  local plans = {}
  local random = rng or math.random

  for snapshot_index, source_snapshot in ipairs(snapshots) do
    local requested_length = resolved[snapshot_index].requested_length
    local available_span = math.max(0, source_snapshot.length - requested_length)
    local item_start = source_snapshot.position
    local item_end = item_start + source_snapshot.length
    local item_center = item_start + source_snapshot.length / 2
    local output_position = item_start
    local integer_start
    local integer_end
    if sanitized.second_snap then
      integer_start = math.ceil(item_start)
      integer_end = math.floor(item_end)
      if integer_end <= integer_start then
        return nil, "second snap requires two distinct integer boundaries inside the Item"
      end
      if not has_time_selection and sanitized.loops > 1 then
        for boundary_index = 0, sanitized.loops do
          local boundary = item_start + requested_length * boundary_index
          if math.abs(boundary - core.round(boundary)) > EPSILON then
            return nil,
              "second snap cannot preserve equal unique multi-loop divisions"
          end
        end
      end
    end

    local order, order_reason = variation_order(
      sanitized.loops, sanitized.shuffle, random)
    if not order then return nil, order_reason end
    local snapped_span_length
    local snapped_intervals = {}

    for variation_index = 0, sanitized.loops - 1 do
      local fraction = 0.5
      if sanitized.loops > 1 then
        fraction = order[variation_index + 1] / (sanitized.loops - 1)
      elseif sanitized.shuffle then
        local random_reason
        fraction, random_reason = random_fraction(random)
        if fraction == nil then return nil, random_reason end
      end

      local source_project_start
      if sanitized.loops == 1 then
        if sanitized.shuffle then
          local minimum_start = math.max(
            item_start, item_center - requested_length)
          local maximum_start = math.min(
            item_center, item_end - requested_length)
          source_project_start = minimum_start
            + (maximum_start - minimum_start) * fraction
        else
          source_project_start = core.clamp(
            item_center - requested_length / 2,
            item_start, item_end - requested_length)
        end
      else
        source_project_start = item_start + available_span * fraction
      end
      local source_end = source_project_start + requested_length

      if sanitized.second_snap then
        local original_source_center = (source_project_start + source_end) / 2
        source_project_start = core.clamp(
          core.round(source_project_start), integer_start, integer_end)
        source_end = core.clamp(
          core.round(source_end), integer_start, integer_end)
        if source_end <= source_project_start then
          local pair_start = core.clamp(
            math.floor(original_source_center), integer_start, integer_end - 1)
          source_project_start = pair_start
          source_end = pair_start + 1
        end
        if sanitized.loops > 1 then
          local current_span_length = source_end - source_project_start
          if snapped_span_length == nil then
            snapped_span_length = current_span_length
          elseif math.abs(current_span_length - snapped_span_length) > EPSILON then
            return nil,
              "second snap cannot preserve equal unique multi-loop divisions"
          end
          for _, interval in ipairs(snapped_intervals) do
            if math.abs(interval.start - source_project_start) <= EPSILON
                and math.abs(interval.finish - source_end) <= EPSILON then
              return nil,
                "second snap cannot preserve equal unique multi-loop divisions"
            end
          end
          snapped_intervals[#snapped_intervals + 1] = {
            start = source_project_start,
            finish = source_end,
          }
        end
      end

      local source_span_length = source_end - source_project_start
      local boundary_margin = sanitized.loops > 1
        and M.BOUNDARY_SAFETY_FADE
        or 0
      local legal_minimum_anchor = source_project_start + boundary_margin
      local legal_maximum_anchor = source_end - math.max(
        boundary_margin, math.min(EPSILON, source_span_length / 2))

      local boundary_anchor = source_project_start + source_span_length / 2
      local requested_anchor = boundary_anchor + sanitized.offset
      boundary_anchor = core.clamp(
        requested_anchor, legal_minimum_anchor, legal_maximum_anchor)
      local offset_clamped = math.abs(requested_anchor - boundary_anchor) > EPSILON

      local warning = source_warning(
        source_snapshot, source_project_start, source_span_length)
      if offset_clamped then
        warning = append_warning(warning, "offset clamped")
      end
      local plan = {
        source_snapshot = source_snapshot,
        variation_index = variation_index,
        output_position = output_position,
        requested_length = requested_length,
        warning = warning,
        settings = core.deep_copy(sanitized),
      }
      local rebuilt, rebuild_reason = rebuild_plan_geometry(
        plan, source_project_start, source_end, boundary_anchor)
      if not rebuilt then return nil, rebuild_reason end
      plans[#plans + 1] = rebuilt
      output_position = output_position + rebuilt.loop_length
        + sanitized.position_space
    end
  end

  return plans
end

local function copy_plan(plan)
  local memo = {}
  if type(plan.source_snapshot) == "table" then
    memo[plan.source_snapshot] = plan.source_snapshot
  end
  return core.deep_copy(plan, memo)
end

function M.apply_analysis(plan, start_result, end_result)
  if type(plan) ~= "table" or type(plan.source_snapshot) ~= "table" then
    return nil, "plan and source snapshot must be tables"
  end

  local copy = copy_plan(plan)
  copy.settings = settings_module.sanitize(copy.settings)
  local source_project_start = copy.source_project_start
  local original_anchor = copy.boundary_anchor
  local original_end = copy.source_end
    or (copy.source_project_start + copy.source_span_length)
  local item_end = copy.source_snapshot.position + copy.source_snapshot.length
  if not core.is_finite_number(source_project_start)
      or not core.is_finite_number(original_anchor)
      or not core.is_finite_number(original_end)
      or source_project_start < copy.source_snapshot.position
      or original_anchor < source_project_start
      or original_anchor >= original_end
      or original_end > item_end then
    return nil, "plan has invalid source geometry"
  end

  local analyzed_anchor = type(start_result) == "table"
    and start_result.project_time or nil
  local start_valid = core.is_finite_number(analyzed_anchor)
    and analyzed_anchor >= source_project_start
    and analyzed_anchor < item_end

  local analyzed_end = type(end_result) == "table"
    and end_result.project_time or nil
  local end_valid = core.is_finite_number(analyzed_end)
    and analyzed_end > source_project_start
    and analyzed_end <= item_end
    and (not start_valid or analyzed_end > analyzed_anchor)

  local boundary_anchor
  if start_valid then
    boundary_anchor = analyzed_anchor
  elseif end_valid and original_anchor >= analyzed_end then
    boundary_anchor = source_project_start
    copy.warning = append_warning(copy.warning,
      "start analysis result invalid; original boundary anchor does not precede valid source end; using source start")
  else
    boundary_anchor = original_anchor
    copy.warning = append_warning(
      copy.warning, "start analysis result invalid; using original boundary anchor")
  end
  if type(start_result) == "table" and start_result.fallback then
    copy.warning = append_warning(copy.warning,
      start_result.warning or "start analysis used fallback")
  end

  local source_end
  if end_valid then
    source_end = analyzed_end
  elseif start_valid and original_end <= boundary_anchor then
    source_end = item_end
    copy.warning = append_warning(copy.warning,
      "end analysis result invalid; original source end does not follow valid boundary anchor; using Item end at the Item boundary")
  else
    source_end = original_end
    copy.warning = append_warning(
      copy.warning, "end analysis result invalid; using original source end")
  end
  if type(end_result) == "table" and end_result.fallback then
    copy.warning = append_warning(copy.warning,
      end_result.warning or "end analysis used fallback")
  end

  if source_end > source_project_start and copy.settings.loops > 1 then
    local boundary_margin = M.BOUNDARY_SAFETY_FADE
    local safe_anchor = core.clamp(
      boundary_anchor,
      source_project_start + boundary_margin,
      source_end - boundary_margin)
    if math.abs(safe_anchor - boundary_anchor) > EPSILON then
      copy.warning = append_warning(
        copy.warning, "analysis anchor clamped for boundary fade")
      boundary_anchor = safe_anchor
    end
  end

  if boundary_anchor < source_project_start
      or boundary_anchor >= source_end
      or source_end > item_end then
    return nil, "analysis boundaries cannot form a valid anchored interval"
  end

  local rebuilt, rebuild_reason = rebuild_plan_geometry(
    copy, source_project_start, source_end, boundary_anchor)
  if not rebuilt then return nil, rebuild_reason end
  copy.warning = append_warning(copy.warning, source_warning(
    copy.source_snapshot, copy.source_project_start, copy.source_span_length))
  return copy
end

local SNAPSHOT_API_FUNCTIONS = {
  "CountSelectedMediaItems",
  "GetSelectedMediaItem",
  "GetActiveTake",
  "TakeIsMIDI",
  "GetMediaItemTrack",
  "GetMediaItemInfo_Value",
  "GetMediaItemTakeInfo_Value",
  "GetMediaItemTake_Source",
  "GetMediaSourceLength",
  "GetItemStateChunk",
}

local function validate_api_functions(api, names)
  if type(api) ~= "table" then
    return nil, "reaper_api must be a table"
  end
  for _, name in ipairs(names) do
    if type(api[name]) ~= "function" then
      return nil, "reaper_api is missing " .. name
    end
  end
  return true
end

local function snapshot_selected_internal(reaper_api, project)
  local count = call_api(reaper_api, "CountSelectedMediaItems", project)
  if not core.is_finite_number(count) or count < 0 or count ~= math.floor(count) then
    error("CountSelectedMediaItems returned an invalid count", 0)
  end

  local snapshots = {}
  for index = 0, count - 1 do
    local item = call_api(reaper_api, "GetSelectedMediaItem", project, index)
    if item == nil then
      error("GetSelectedMediaItem returned nil at index " .. index, 0)
    end
    local take = call_api(reaper_api, "GetActiveTake", item)
    if take ~= nil and not call_api(reaper_api, "TakeIsMIDI", take) then
      local track = call_api(reaper_api, "GetMediaItemTrack", item)
      if track == nil then error("selected item has no track", 0) end

      local position = call_api(
        reaper_api, "GetMediaItemInfo_Value", item, "D_POSITION")
      local length = call_api(
        reaper_api, "GetMediaItemInfo_Value", item, "D_LENGTH")
      local start_offset = call_api(
        reaper_api, "GetMediaItemTakeInfo_Value", take, "D_STARTOFFS")
      local playrate = call_api(
        reaper_api, "GetMediaItemTakeInfo_Value", take, "D_PLAYRATE")
      if not core.is_finite_number(position)
          or not core.is_finite_number(length) or length <= 0
          or not core.is_finite_number(start_offset)
          or not core.is_finite_number(playrate) or playrate <= 0 then
        error("selected audio item has invalid position, length, offset, or playrate", 0)
      end

      local source = call_api(reaper_api, "GetMediaItemTake_Source", take)
      if source == nil then error("selected audio take has no source", 0) end
      local source_length, is_qn = call_api(
        reaper_api, "GetMediaSourceLength", source)
      if not core.is_finite_number(source_length) or source_length < 0 then
        error("GetMediaSourceLength returned an invalid length", 0)
      end
      local sample_rate
      if type(reaper_api.GetMediaSourceSampleRate) == "function" then
        local rate_ok, candidate = pcall(
          reaper_api.GetMediaSourceSampleRate, source)
        if rate_ok and core.is_finite_number(candidate) and candidate > 0
            and candidate == math.floor(candidate) then
          sample_rate = candidate
        end
      end

      -- Glue writes whole source samples, while the Item may retain a
      -- fractional-sample end. Bound only that rounding tail before planning;
      -- do not relax component source checks or truncate genuinely long Items.
      local readable_length = length
      if not is_qn and sample_rate then
        local source_overrun = start_offset + length * playrate - source_length
        local available_length = (source_length - start_offset) / playrate
        if source_overrun > 0 and source_overrun <= 1 / sample_rate
            and available_length > 0 then
          readable_length = math.min(length, available_length)
        end
      end

      local chunk_ok, chunk = call_api(
        reaper_api, "GetItemStateChunk", item, "", false)
      if chunk_ok ~= true or type(chunk) ~= "string" then
        error("GetItemStateChunk failed for selected audio item", 0)
      end

      snapshots[#snapshots + 1] = {
        item = item,
        take = take,
        track = track,
        position = position,
        length = readable_length,
        start_offset = start_offset,
        playrate = playrate,
        sample_rate = sample_rate,
        source_length = is_qn and nil or source_length,
        source_length_is_qn = is_qn == true,
        name = naming.source_name(reaper_api, take),
        chunk = chunk,
      }
    end
  end
  return snapshots
end

function M.snapshot_selected(reaper_api, project)
  local valid, reason = validate_api_functions(
    reaper_api, SNAPSHOT_API_FUNCTIONS)
  if not valid then return nil, reason end
  if project == nil then return nil, "project is required; use 0 for the current project" end

  local ok, result = pcall(snapshot_selected_internal, reaper_api, project)
  if not ok then
    return nil, "failed to snapshot selected items: " .. tostring(result)
  end
  return result
end

local CLONE_API_FUNCTIONS = {
  "AddMediaItemToTrack",
  "genGuid",
  "SetItemStateChunk",
  "GetActiveTake",
  "SetMediaItemInfo_Value",
  "SetMediaItemTakeInfo_Value",
  "DeleteTrackMediaItem",
}

local function replace_chunk_guids(reaper_api, chunk)
  local prefixed = "\n" .. chunk
  local replaced = prefixed:gsub("(\n[ \t]*I?GUID[ \t]+)%b{}", function(prefix)
    local guid = call_api(reaper_api, "genGuid")
    if type(guid) ~= "string" or not guid:match("^%b{}$") then
      error("genGuid returned an invalid GUID", 0)
    end
    return prefix .. guid
  end)
  return replaced:sub(2)
end

local function apply_component_values(reaper_api, item, take, source_snapshot, component)
  if not core.is_finite_number(component.position)
      or not core.is_finite_number(component.length) or component.length <= 0
      or not core.is_finite_number(component.source_project_start) then
    error("component has invalid position, length, or source start", 0)
  end

  if component.wrap_source then
    error("component source wrapping is not supported", 0)
  end
  local source_start = source_snapshot.start_offset
    + (component.source_project_start - source_snapshot.position)
      * source_snapshot.playrate
  local source_finish = source_start + component.length * source_snapshot.playrate
  if source_start < -EPSILON then
    error("component source range starts before the available source", 0)
  elseif not core.is_finite_number(source_snapshot.source_length) then
    error("component source length is unavailable", 0)
  elseif source_finish > source_snapshot.source_length + EPSILON then
    error("component source range exceeds the available source", 0)
  end

  set_api(reaper_api, "SetMediaItemInfo_Value", item,
    "D_POSITION", component.position)
  set_api(reaper_api, "SetMediaItemInfo_Value", item,
    "D_LENGTH", component.length)
  set_api(reaper_api, "SetMediaItemInfo_Value", item,
    "B_LOOPSRC", 0)
  set_api(reaper_api, "SetMediaItemInfo_Value", item,
    "D_FADEINLEN_AUTO", -1)
  set_api(reaper_api, "SetMediaItemInfo_Value", item,
    "D_FADEOUTLEN_AUTO", -1)

  local fade_in = component.fade_in or 0
  local fade_out = component.fade_out or 0
  local fade_shape = component.fade_shape or 0
  set_api(reaper_api, "SetMediaItemInfo_Value", item,
    "D_FADEINLEN", fade_in)
  set_api(reaper_api, "SetMediaItemInfo_Value", item,
    "D_FADEOUTLEN", fade_out)
  if fade_in > 0 then
    set_api(reaper_api, "SetMediaItemInfo_Value", item,
      "C_FADEINSHAPE", fade_shape)
  end
  if fade_out > 0 then
    set_api(reaper_api, "SetMediaItemInfo_Value", item,
      "C_FADEOUTSHAPE", fade_shape)
  end

  set_api(reaper_api, "SetMediaItemTakeInfo_Value", take,
    "D_STARTOFFS", source_start)
  set_api(reaper_api, "SetMediaItemTakeInfo_Value", take,
    "D_PLAYRATE", source_snapshot.playrate)
end

local function cleanup_clone(reaper_api, snapshot, item, reason)
  local ok, deleted_or_error = pcall(
    reaper_api.DeleteTrackMediaItem, snapshot.track, item)
  if not ok then
    return nil, reason .. "; DeleteTrackMediaItem failed: " .. tostring(deleted_or_error)
  end
  if deleted_or_error == false then
    return nil, reason .. "; DeleteTrackMediaItem returned false"
  end
  return nil, reason
end

function M.clone_from_chunk(reaper_api, source_snapshot, component)
  local valid, reason = validate_api_functions(
    reaper_api, CLONE_API_FUNCTIONS)
  if not valid then return nil, reason end
  if type(source_snapshot) ~= "table" or source_snapshot.track == nil
      or type(source_snapshot.chunk) ~= "string" then
    return nil, "snapshot track and chunk are required"
  end
  if type(component) ~= "table" then
    return nil, "component must be a table"
  end

  local added_ok, item_or_error = pcall(
    reaper_api.AddMediaItemToTrack, source_snapshot.track)
  if not added_ok then
    return nil, "AddMediaItemToTrack failed: " .. tostring(item_or_error)
  end
  local item = item_or_error
  if item == nil or item == false then
    return nil, "AddMediaItemToTrack failed to create an item"
  end

  local operation_ok, take_or_error = pcall(function()
    local chunk = replace_chunk_guids(reaper_api, source_snapshot.chunk)
    set_api(reaper_api, "SetItemStateChunk", item, chunk, false)
    local take = call_api(reaper_api, "GetActiveTake", item)
    if take == nil then error("cloned item has no active take", 0) end
    apply_component_values(
      reaper_api, item, take, source_snapshot, component)
    return take
  end)

  if not operation_ok then
    return cleanup_clone(reaper_api, source_snapshot, item,
      "failed to initialize cloned item: " .. tostring(take_or_error))
  end
  return item, take_or_error
end

local APPLY_API_FUNCTIONS = {
  "CountMediaItems",
  "GetMediaItem",
  "SetMediaItemSelected",
  "AddMediaItemToTrack",
  "genGuid",
  "SetItemStateChunk",
  "GetActiveTake",
  "SetMediaItemInfo_Value",
  "SetMediaItemTakeInfo_Value",
  "DeleteTrackMediaItem",
  "GetSetMediaItemTakeInfo_String",
}

local function deselect_project_items(reaper_api, project)
  local count = call_api(reaper_api, "CountMediaItems", project)
  if not core.is_finite_number(count) or count < 0 or count ~= math.floor(count) then
    error("CountMediaItems returned an invalid count", 0)
  end
  for index = 0, count - 1 do
    local item = call_api(reaper_api, "GetMediaItem", project, index)
    if item == nil then error("GetMediaItem returned nil at index " .. index, 0) end
    set_api(reaper_api, "SetMediaItemSelected", item, false)
  end
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

local function cleanup_failed_output(reaper_api, source_snapshot, created_clones,
    restore_original)
  local errors = {}
  for index = #created_clones, 1, -1 do
    local deleted_ok, deleted = pcall(
      reaper_api.DeleteTrackMediaItem, source_snapshot.track, created_clones[index])
    if not deleted_ok then
      errors[#errors + 1] = "DeleteTrackMediaItem failed: " .. tostring(deleted)
    elseif deleted == false then
      errors[#errors + 1] = "DeleteTrackMediaItem returned false"
    end
  end
  if restore_original then
    local restored_ok, restored = pcall(
      reaper_api.SetItemStateChunk, source_snapshot.item,
      source_snapshot.chunk, false)
    if not restored_ok then
      errors[#errors + 1] = "SetItemStateChunk restore failed: " .. tostring(restored)
    elseif restored == false then
      errors[#errors + 1] = "SetItemStateChunk restore returned false"
    else
      local take_ok, take = pcall(reaper_api.GetActiveTake, source_snapshot.item)
      if not take_ok or take == nil then
        errors[#errors + 1] = "GetActiveTake failed after original restore: "
          .. tostring(take)
      else
        source_snapshot.take = take
      end
    end
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

  local colors = {}
  for plan_index, plan in ipairs(plans) do
    if type(plan) ~= "table" or type(plan.source_snapshot) ~= "table"
        or type(plan.components) ~= "table" or #plan.components < 1 then
      return nil, "plan " .. plan_index .. " is invalid", {}
    end
    local sanitized = settings_module.sanitize(options.settings or plan.settings)
    local color, color_reason = output_color(options, plan, plan_index,
      sanitized.color_items)
    if color_reason then return nil, color_reason, {} end
    colors[plan_index] = color
  end

  local project = options.project
  if project == nil then project = 0 end
  local outputs = {}
  local warnings = {}
  local used_original = {}

  for plan_index, plan in ipairs(plans) do
    local source_snapshot = plan.source_snapshot
    local sanitized = settings_module.sanitize(options.settings or plan.settings)
    local color = colors[plan_index]
    local output = { plan = plan, items = {} }
    local takes = {}
    local created_clones = {}
    local reused_original = false

    local ok, operation_error = pcall(function()
      for component_index, component in ipairs(plan.components) do
        local item, take
        if component.kind == "main" and not used_original[source_snapshot] then
          item = source_snapshot.item
          take = source_snapshot.take
          if item == nil or take == nil then
            error("source snapshot has no original item or take", 0)
          end
          reused_original = true
          apply_component_values(
            reaper_api, item, take, source_snapshot, component)
        else
          local clone_reason
          item, take = M.clone_from_chunk(
            reaper_api, source_snapshot, component)
          if not item then
            clone_reason = take
            error("plan " .. plan_index .. " component " .. component_index
              .. " failed: " .. tostring(clone_reason), 0)
          end
          created_clones[#created_clones + 1] = item
        end
        output.items[#output.items + 1] = item
        takes[#takes + 1] = take
        if component.kind == "main" then output.main = item end
      end

      if output.main == nil then error("output has no main component", 0) end
      local loop_name, name_reason = naming.build(
        source_snapshot.name, sanitized, plan.variation_index)
      if not loop_name then error(name_reason, 0) end
      for item_index, item in ipairs(output.items) do
        local named, naming_reason = naming.apply_to_take(
          reaper_api, takes[item_index], loop_name)
        if not named then error(naming_reason, 0) end
        local colored, apply_color_reason = naming.apply_color(
          reaper_api, item, color, sanitized.color_items)
        if not colored then error(apply_color_reason, 0) end
      end
    end)

    if not ok then
      local cleaned, cleanup_reason = cleanup_failed_output(
        reaper_api, source_snapshot, created_clones, reused_original)
      local nested_cleanup_failed = tostring(operation_error):find(
        "DeleteTrackMediaItem", 1, true) ~= nil
      local cleanup_status = cleaned and not nested_cleanup_failed
        and "current output cleaned"
        or "cleanup failed: " .. tostring(cleanup_reason or operation_error)
      return nil, "failed to apply loop plans: " .. tostring(operation_error)
        .. "; " .. cleanup_status, outputs
    end

    if reused_original then used_original[source_snapshot] = true end
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
    return nil, "failed to select loop outputs: " .. tostring(selection_error), outputs
  end
  return outputs, warnings
end

local function glue_item_guid(reaper_api, item)
  local ok, guid = call_api(
    reaper_api, "GetSetMediaItemInfo_String", item, "GUID", "", false)
  if not ok or type(guid) ~= "string" or guid == "" then
    error("GetSetMediaItemInfo_String failed to return an item GUID", 0)
  end
  return guid
end

local GLUE_API_FUNCTIONS = {
  "GetSetMediaItemInfo_String",
  "CountMediaItems",
  "GetMediaItem",
  "SetMediaItemSelected",
  "Main_OnCommandEx",
  "CountSelectedMediaItems",
  "GetSelectedMediaItem",
}

function M.glue_outputs(reaper_api, project, outputs, options)
  if project == nil then return nil, "project is required", {} end
  if type(outputs) ~= "table" then return nil, "outputs must be a table", {} end
  if options ~= nil and type(options) ~= "table" then
    return nil, "options must be a table", {}
  end
  local effective_options = options or {}
  local required = {}
  for _, name in ipairs(GLUE_API_FUNCTIONS) do required[#required + 1] = name end
  required[#required + 1] = "GetActiveTake"
  required[#required + 1] = "GetSetMediaItemTakeInfo_String"
  local valid, reason = validate_api_functions(reaper_api, required)
  if not valid then return nil, reason, {} end

  local colors = {}
  local final_names = {}
  local final_settings = {}
  local needs_color_api = false
  for output_index, output in ipairs(outputs) do
    if type(output) ~= "table" or type(output.items) ~= "table"
        or #output.items == 0 or output.main == nil then
      return nil, "output " .. output_index .. " has no components", {}
    end
    for item_index, item in ipairs(output.items) do
      if item == nil then
        return nil, "output " .. output_index .. " item " .. item_index
          .. " is invalid", {}
      end
    end
    if type(output.plan) ~= "table"
        or type(output.plan.source_snapshot) ~= "table" then
      return nil, "output " .. output_index .. " has no valid plan", {}
    end
    local sanitized = settings_module.sanitize(
      effective_options.settings or output.plan.settings)
    local name_index = nonnegative_integer(output.name_index)
      and output.name_index or output.plan.variation_index
    local loop_name, name_reason = naming.build(
      output.plan.source_snapshot.name, sanitized, name_index)
    if not loop_name then return nil, name_reason, {} end
    local color, color_reason = output_color(
      effective_options, output.plan, output_index, sanitized.color_items)
    if color_reason then return nil, color_reason, {} end
    colors[output_index] = color
    final_names[output_index] = loop_name
    final_settings[output_index] = sanitized
    if sanitized.color_items then needs_color_api = true end
  end
  if needs_color_api and type(reaper_api.SetMediaItemInfo_Value) ~= "function" then
    return nil, "reaper_api is missing SetMediaItemInfo_Value", {}
  end

  -- Capture identities before any render. Glue may reuse a deleted Item's
  -- address, so pointer equality alone cannot identify an original component.
  local identities_ok, original_identities = pcall(function()
    local identities = {}
    for output_index, output in ipairs(outputs) do
      local components = {}
      for _, item in ipairs(output.items) do
        components[item] = glue_item_guid(reaper_api, item)
      end
      identities[output_index] = components
    end
    return identities
  end)
  if not identities_ok then
    return nil, "failed to identify Glue components: " .. tostring(original_identities), {}
  end

  local partial = {}
  for output_index, output in ipairs(outputs) do
    local original_components = original_identities[output_index]
    local function is_original_component(item)
      local original_guid = original_components[item]
      return original_guid ~= nil
        and original_guid == glue_item_guid(reaper_api, item)
    end
    local failed_context = {
      output = output,
      index = output_index,
      glue_side_effect_possible = true,
    }
    local ok, operation_error = pcall(function()
      deselect_project_items(reaper_api, project)
      for _, item in ipairs(output.items) do
        set_api(reaper_api, "SetMediaItemSelected", item, true)
      end
      call_api(reaper_api, "Main_OnCommandEx", M.GLUE_COMMAND, 0, project)
      local selected_count = call_api(
        reaper_api, "CountSelectedMediaItems", project)
      if selected_count ~= 1 then
        error("Glue must leave exactly one selected item; got "
          .. tostring(selected_count), 0)
      end
      local glued = call_api(
        reaper_api, "GetSelectedMediaItem", project, 0)
      if glued == nil then error("Glue returned no selected item", 0) end
      failed_context.glued_item = glued
      if is_original_component(glued) then
        error("Glue must create and select a new item", 0)
      end
      local current_count = call_api(reaper_api, "CountMediaItems", project)
      if not core.is_finite_number(current_count) or current_count < 0
          or current_count ~= math.floor(current_count) then
        error("CountMediaItems returned an invalid count", 0)
      end
      for item_index = 0, current_count - 1 do
        local current_item = call_api(
          reaper_api, "GetMediaItem", project, item_index)
        if current_item == nil then
          error("GetMediaItem returned nil at index " .. item_index, 0)
        end
        if is_original_component(current_item) then
          error("Glue original components remain in the project", 0)
        end
      end

      local take = call_api(reaper_api, "GetActiveTake", glued)
      if take == nil then error("glued item has no active take", 0) end
      local named, naming_reason = naming.apply_to_take(
        reaper_api, take, final_names[output_index])
      if not named then error(naming_reason, 0) end
      local sanitized = final_settings[output_index]
      local colored, color_reason = naming.apply_color(
        reaper_api, glued, colors[output_index], sanitized.color_items)
      if not colored then error(color_reason, 0) end

      output.items = { glued }
      output.takes = { take }
      output.main = glued
    end)
    if not ok then
      return nil, "failed to Glue output " .. output_index .. ": "
        .. tostring(operation_error)
        .. "; Glue side effects and rendered disk files may remain",
        partial, failed_context
    end
    partial[#partial + 1] = output
  end

  local selected_ok, selected_error = pcall(function()
    deselect_project_items(reaper_api, project)
    for _, output in ipairs(outputs) do
      set_api(reaper_api, "SetMediaItemSelected", output.main, true)
    end
  end)
  if not selected_ok then
    return nil, "failed to select glued outputs: " .. tostring(selected_error),
      partial, { glue_side_effect_possible = true }
  end
  return outputs
end

local function snapshot_groups(plans)
  local snapshots = {}
  local indices = {}
  for _, plan in ipairs(plans) do
    local source_snapshot = plan.source_snapshot
    if indices[source_snapshot] == nil then
      snapshots[#snapshots + 1] = source_snapshot
      indices[source_snapshot] = #snapshots
    end
  end

  local parent = {}
  for index = 1, #snapshots do parent[index] = index end
  local function root(index)
    while parent[index] ~= index do
      parent[index] = parent[parent[index]]
      index = parent[index]
    end
    return index
  end
  local function union(left, right)
    local left_root, right_root = root(left), root(right)
    if left_root ~= right_root then parent[right_root] = left_root end
  end
  for left = 1, #snapshots do
    for right = left + 1, #snapshots do
      if snapshots[left].track ~= snapshots[right].track
          and snapshot_intervals_overlap(snapshots[left], snapshots[right]) then
        union(left, right)
      end
    end
  end

  local groups = {}
  for source_snapshot, index in pairs(indices) do
    groups[source_snapshot] = root(index)
  end
  return groups
end

local function matched_interval(plan, target)
  local snapshot = plan.source_snapshot
  local item_start = snapshot.position
  local item_end = item_start + snapshot.length
  local anchor = plan.boundary_anchor
  if not core.is_finite_number(anchor)
      or anchor < item_start - EPSILON
      or anchor >= item_end then
    return nil, "fixed anchor cannot fit the matched overlap length"
  end

  local nominal_span = source_span_for_output_length(target, plan.settings)
  local nominal_crossfade = nominal_span - target
  local boundary_safety_fade = plan.settings.loops > 1
    and M.BOUNDARY_SAFETY_FADE
    or 0
  local best
  local best_distance
  local function consider(source_start, source_end)
    if source_start < item_start - EPSILON
        or source_end > item_end + EPSILON then
      return
    end
    local geometry = geometry_for_interval(
      source_start, source_end, anchor, plan.settings)
    if not geometry or math.abs(geometry.loop_length - target) > EPSILON then
      return
    end
    local distance = math.abs(source_start - plan.source_project_start)
    if best == nil or distance < best_distance then
      best = geometry
      best_distance = distance
    end
  end

  local minimum_start = math.max(
    item_start, anchor - target + boundary_safety_fade)
  local maximum_start = math.min(
    item_end - nominal_span,
    anchor - nominal_crossfade - boundary_safety_fade)
  if nominal_crossfade <= EPSILON then
    minimum_start = math.max(
      minimum_start, anchor - target + math.min(EPSILON, target / 2))
  end
  if minimum_start <= maximum_start + EPSILON then
    local source_start = core.clamp(
      plan.source_project_start, minimum_start, maximum_start)
    consider(source_start, source_start + nominal_span)
  end

  local maximum_edge_crossfade = math.max(0, math.min(
    nominal_crossfade, target - 2 * boundary_safety_fade))
  local left_limited_end = anchor - boundary_safety_fade + target
  if left_limited_end <= item_end + EPSILON then
    local minimum_left_start = math.max(
      item_start,
      anchor - boundary_safety_fade - maximum_edge_crossfade)
    local maximum_left_start = anchor - boundary_safety_fade
    if minimum_left_start <= maximum_left_start + EPSILON then
      local source_start = core.clamp(
        plan.source_project_start, minimum_left_start, maximum_left_start)
      consider(source_start, left_limited_end)
    end
  end

  local right_limited_start = anchor + boundary_safety_fade - target
  if right_limited_start >= item_start - EPSILON then
    local minimum_right_end = anchor + boundary_safety_fade
    local maximum_right_end = math.min(
      item_end,
      anchor + boundary_safety_fade + maximum_edge_crossfade)
    if minimum_right_end <= maximum_right_end + EPSILON then
      local source_end = core.clamp(
        plan.source_end, minimum_right_end, maximum_right_end)
      consider(right_limited_start, source_end)
    end
  end

  if not best then
    return nil, "fixed anchor cannot produce the matched overlap length"
  end
  return best
end

local function fit_plan_to_length(plan, target_length)
  if not core.is_finite_number(target_length) or target_length <= 0 then
    return nil, "target loop length must be a finite positive number"
  end
  if not core.is_finite_number(plan.loop_length) or plan.loop_length <= 0 then
    return nil, "plan loop length must be a finite positive number"
  end
  if target_length > plan.loop_length + EPSILON then
    return nil, "timeline fitting cannot stretch a variation"
  end

  local fitted = copy_plan(plan)
  fitted.settings = settings_module.sanitize(fitted.settings)
  local rebuilt, reason
  if math.abs(fitted.loop_length - target_length) <= EPSILON then
    rebuilt, reason = rebuild_plan_geometry(
      fitted, fitted.source_project_start, fitted.source_end,
      fitted.boundary_anchor)
  else
    local geometry
    geometry, reason = matched_interval(fitted, target_length)
    if geometry then
      rebuilt, reason = rebuild_plan_geometry(
        fitted, geometry.source_project_start, geometry.source_end,
        geometry.boundary_anchor)
    end
  end
  if not rebuilt then return nil, reason end

  if plan.loop_length > target_length + EPSILON then
    fitted.warning = append_warning(
      fitted.warning, "matched timeline slot length")
  end
  fitted.warning = append_warning(fitted.warning, source_warning(
    fitted.source_snapshot, fitted.source_project_start,
    fitted.source_span_length))
  return fitted
end

local function validate_analyzed_plan(plan, plan_index, variation_count)
  if type(plan) ~= "table" then
    return nil, "plan " .. plan_index .. " must be a table"
  end
  if type(plan.source_snapshot) ~= "table" then
    return nil, "plan " .. plan_index .. " source_snapshot must be a table"
  end
  local snapshot_valid, snapshot_reason = validate_snapshot(
    plan.source_snapshot, plan_index)
  if not snapshot_valid then
    return nil, "plan " .. plan_index .. " source_snapshot: "
      .. tostring(snapshot_reason)
  end
  if type(plan.settings) ~= "table" then
    return nil, "plan " .. plan_index .. " settings must be a table"
  end
  if type(plan.components) ~= "table" then
    return nil, "plan " .. plan_index .. " components must be a table"
  end

  for _, field in ipairs({
    "loop_length",
    "source_project_start",
    "source_end",
    "boundary_anchor",
    "source_span_length",
    "crossfade_length",
    "output_position",
  }) do
    if not core.is_finite_number(plan[field]) then
      return nil, "plan " .. plan_index .. " has invalid " .. field
    end
  end
  if plan.loop_length <= 0 then
    return nil, "plan " .. plan_index .. " loop_length must be positive"
  end
  if plan.source_end <= plan.source_project_start then
    return nil, "plan " .. plan_index
      .. " source_end must be greater than source_project_start"
  end
  if plan.boundary_anchor < plan.source_project_start
      or plan.boundary_anchor >= plan.source_end then
    return nil, "plan " .. plan_index
      .. " boundary_anchor cannot fit inside the source interval"
  end

  local item_start = plan.source_snapshot.position
  local item_end = item_start + plan.source_snapshot.length
  if plan.source_project_start < item_start - EPSILON then
    return nil, "plan " .. plan_index
      .. " source_project_start must be inside the source_snapshot Item"
  end
  if plan.source_end > item_end + EPSILON then
    return nil, "plan " .. plan_index
      .. " source_end must be inside the source_snapshot Item"
  end

  if not core.is_finite_number(plan.variation_index) then
    return nil, "plan " .. plan_index .. " has an invalid variation index"
  end
  local variation = math.tointeger(plan.variation_index)
  if variation == nil or variation < 0 or variation >= variation_count then
    return nil, "plan " .. plan_index .. " has an invalid variation index"
  end
  local sanitized = settings_module.sanitize(plan.settings)
  if sanitized.loops ~= variation_count then
    return nil, "plan " .. plan_index
      .. " variation count does not match input settings"
  end

  local geometry, geometry_reason = geometry_for_interval(
    plan.source_project_start, plan.source_end,
    plan.boundary_anchor, sanitized)
  if not geometry then
    return nil, "plan " .. plan_index .. " derived geometry is invalid: "
      .. tostring(geometry_reason)
  end
  local function require_derived_match(field, actual, expected)
    if not core.is_finite_number(actual)
        or math.abs(actual - expected) > EPSILON then
      return nil, "plan " .. plan_index .. " derived geometry " .. field
        .. " does not match its source interval, anchor, and settings"
    end
    return true
  end
  for field, expected in pairs({
    loop_length = geometry.loop_length,
    source_span_length = geometry.source_span_length,
    crossfade_length = geometry.crossfade_length,
  }) do
    local matched, match_reason = require_derived_match(
      field, plan[field], expected)
    if not matched then return nil, match_reason end
  end
  if plan.boundary_fade_length ~= nil then
    local matched, match_reason = require_derived_match(
      "boundary_fade_length", plan.boundary_fade_length,
      geometry.boundary_safety_fade)
    if not matched then return nil, match_reason end
  end

  local expected_components = build_components({
    source_project_start = geometry.source_project_start,
    source_end = geometry.source_end,
    boundary_anchor = geometry.boundary_anchor,
    crossfade_length = geometry.crossfade_length,
    boundary_fade_length = geometry.boundary_safety_fade,
    output_position = plan.output_position,
    settings = sanitized,
  })
  if #plan.components ~= #expected_components then
    return nil, "plan " .. plan_index
      .. " derived geometry components have an unexpected count"
  end
  for component_index, expected in ipairs(expected_components) do
    local actual = plan.components[component_index]
    if type(actual) ~= "table" then
      return nil, "plan " .. plan_index .. " derived geometry component "
        .. component_index .. " must be a table"
    end
    for _, field in ipairs({
      "position",
      "length",
      "source_project_start",
      "fade_in",
      "fade_out",
    }) do
      local matched, match_reason = require_derived_match(
        "component " .. component_index .. " " .. field,
        actual[field], expected[field])
      if not matched then return nil, match_reason end
    end
    for _, field in ipairs({ "kind", "fade_shape", "wrap_source" }) do
      if actual[field] ~= expected[field] then
        return nil, "plan " .. plan_index .. " derived geometry component "
          .. component_index .. " " .. field .. " does not match"
      end
    end
  end
  return variation
end

local function dense_array_length(values, name)
  if type(values) ~= "table" then
    return nil, name .. " must be a table"
  end

  local count = 0
  local maximum = 0
  for key in next, values do
    local integer = type(key) == "number" and math.tointeger(key) or nil
    if integer == nil or integer < 1 then
      return nil, name .. " must be a dense array with keys exactly 1..N; invalid key "
        .. tostring(key)
    end
    count = count + 1
    maximum = math.max(maximum, integer)
  end
  if maximum ~= count then
    for index = 1, count do
      if rawget(values, index) == nil then
        return nil, name .. " must be a dense array with keys exactly 1..N; missing index "
          .. index
      end
    end
    return nil, name .. " must be a dense array with keys exactly 1..N; unexpected index "
      .. maximum
  end
  return count
end

local function collect_variation_groups(plans, variation_count)
  local plan_count, array_reason = dense_array_length(plans, "plans")
  if plan_count == nil then return nil, array_reason end
  if plan_count == 0 then return nil, "plans must contain analyzed variations" end

  local groups = {}
  local groups_by_snapshot = {}
  for plan_index = 1, plan_count do
    local plan = plans[plan_index]
    local variation, validation_reason = validate_analyzed_plan(
      plan, plan_index, variation_count)
    if variation == nil then return nil, validation_reason end

    local snapshot = plan.source_snapshot
    local group = groups_by_snapshot[snapshot]
    if group == nil then
      group = {
        source_snapshot = snapshot,
        plans_by_variation = {},
        count = 0,
      }
      groups[#groups + 1] = group
      groups_by_snapshot[snapshot] = group
    end
    if group.plans_by_variation[variation] ~= nil then
      return nil, "source group " .. #groups
        .. " has duplicate variation index " .. variation
    end
    group.plans_by_variation[variation] = plan
    group.count = group.count + 1
  end

  for group_index, group in ipairs(groups) do
    if group.count ~= variation_count then
      return nil, "source group " .. group_index
        .. " does not contain the complete variation set"
    end
    for variation = 0, variation_count - 1 do
      if group.plans_by_variation[variation] == nil then
        return nil, "source group " .. group_index
          .. " is missing variation index " .. variation
      end
    end
  end
  return groups
end

local function fill_time_selection(plans, time_selection, sample_rate,
    input_settings, rng)
  if type(input_settings) ~= "table" then
    return nil, "input_settings must be a table"
  end
  if type(time_selection) ~= "table" then
    return nil, "time_selection must be a table"
  end
  if rng ~= nil and type(rng) ~= "function" then
    return nil, "rng must be a function"
  end

  local sanitized = settings_module.sanitize(input_settings)
  local variation_count = sanitized.loops
  local groups, group_reason = collect_variation_groups(plans, variation_count)
  if not groups then return nil, group_reason end

  local natural_loop_length = math.huge
  for _, group in ipairs(groups) do
    for variation = 0, variation_count - 1 do
      natural_loop_length = math.min(
        natural_loop_length,
        group.plans_by_variation[variation].loop_length)
    end
  end

  local layout, layout_reason = timeline_fill.choose_layout({
    selection_start = time_selection.start,
    selection_finish = time_selection.finish,
    sample_rate = sample_rate,
    natural_loop_length = natural_loop_length,
    variation_count = variation_count,
    minimum_loop_length = M.MIN_MULTI_LOOP_SOURCE_SPAN,
  })
  if not layout then
    if type(layout_reason) == "string"
        and layout_reason:find("no legal divisor", 1, true)
        and core.is_finite_number(time_selection.start)
        and core.is_finite_number(time_selection.finish)
        and math.tointeger(sample_rate) ~= nil then
      local total_samples = core.round(time_selection.finish * sample_rate)
        - core.round(time_selection.start * sample_rate)
      local minimum_samples = core.round(
        M.MIN_MULTI_LOOP_SOURCE_SPAN * sample_rate)
      if total_samples < variation_count * minimum_samples then
        return nil, "time selection is too short to include every variation"
      end
    end
    return nil, layout_reason
  end

  if layout.slot_count > M.MAX_TIMELINE_SLOTS then
    return nil, string.format(
      "timeline slot_count=%d exceeds maximum %d",
      layout.slot_count, M.MAX_TIMELINE_SLOTS)
  end
  local source_count = #groups
  local instance_count = source_count * layout.slot_count
  if instance_count > M.MAX_TIMELINE_INSTANCES then
    return nil, string.format(
      "timeline instance_count=%d exceeds maximum %d (%d sources x %d slots)",
      instance_count, M.MAX_TIMELINE_INSTANCES,
      source_count, layout.slot_count)
  end

  local fitted_groups = {}
  for group_index, group in ipairs(groups) do
    local fitted = {}
    for variation = 0, variation_count - 1 do
      local fit_ok, template, fit_reason = pcall(
        fit_plan_to_length,
        group.plans_by_variation[variation], layout.slot_length)
      if not fit_ok then
        return nil, "source group " .. group_index .. " variation "
          .. variation .. " fit failed: " .. tostring(template)
      end
      if not template then
        return nil, "source group " .. group_index .. " variation "
          .. variation .. " cannot fit the timeline slot length: "
          .. tostring(fit_reason)
      end
      if core.round(template.loop_length * sample_rate)
          ~= layout.slot_samples then
        return nil, "source group " .. group_index .. " variation "
          .. variation .. " cannot fit the exact slot sample length"
      end
      fitted[variation] = template
    end
    fitted_groups[group_index] = fitted
  end

  local sequence, sequence_reason = timeline_fill.balanced_sequence(
    variation_count, layout.slot_count, sanitized.shuffle, rng)
  if not sequence then return nil, sequence_reason end

  local expanded = {}
  for group_index = 1, #groups do
    local templates = fitted_groups[group_index]
    for sequence_offset, variation in ipairs(sequence) do
      local sequence_index = sequence_offset - 1
      local instance = copy_plan(templates[variation])
      instance.variation_index = variation
      instance.asset_variant_index = variation
      instance.sequence_index = sequence_index
      instance.slot_samples = layout.slot_samples
      instance.output_position = (layout.start_sample
        + sequence_index * layout.slot_samples) / sample_rate
      instance.components = build_components(instance)
      expanded[#expanded + 1] = instance
    end
  end

  local summary = {
    start_sample = layout.start_sample,
    end_sample = layout.end_sample,
    total_samples = layout.total_samples,
    start = layout.quantized_start,
    ["end"] = layout.quantized_finish,
    total = layout.total_samples / sample_rate,
    slot_count = layout.slot_count,
    slot_samples = layout.slot_samples,
    slot_length = layout.slot_length,
    variation_count = variation_count,
    source_count = #groups,
  }
  return expanded, summary
end

function M.fill_time_selection(...)
  local results = table.pack(pcall(fill_time_selection, ...))
  if not results[1] then
    return nil, "fill_time_selection failed: " .. tostring(results[2])
  end
  return table.unpack(results, 2, results.n)
end

local function match_variation_lengths(plans)
  local minimums = {}
  local counts = {}
  for _, plan in ipairs(plans) do
    local source_snapshot = plan.source_snapshot
    minimums[source_snapshot] = math.min(
      minimums[source_snapshot] or plan.loop_length, plan.loop_length)
    counts[source_snapshot] = (counts[source_snapshot] or 0) + 1
  end

  for _, plan in ipairs(plans) do
    local source_snapshot = plan.source_snapshot
    local target = minimums[source_snapshot]
    if counts[source_snapshot] > 1 and plan.loop_length > target + EPSILON then
      local geometry, reason = matched_interval(plan, target)
      if not geometry then
        return nil, "variation anchor " .. tostring(plan.boundary_anchor)
          .. " cannot fit the common loop length: " .. tostring(reason)
      end
      local rebuilt, rebuild_reason = rebuild_plan_geometry(
        plan, geometry.source_project_start, geometry.source_end,
        geometry.boundary_anchor)
      if not rebuilt then
        return nil, "variation anchor " .. tostring(plan.boundary_anchor)
          .. " cannot fit the common loop length: "
          .. tostring(rebuild_reason)
      end
      plan.warning = append_warning(plan.warning, "matched variation length")
      plan.warning = append_warning(plan.warning, source_warning(
        plan.source_snapshot, plan.source_project_start,
        plan.source_span_length))
    end
  end
  return true
end

local function match_analyzed_lengths(plans, enabled)
  if not enabled then return true end
  local groups = snapshot_groups(plans)
  local minimums = {}
  for _, plan in ipairs(plans) do
    local group = groups[plan.source_snapshot]
    minimums[group] = minimums[group] or {}
    local variation = plan.variation_index
    minimums[group][variation] = math.min(
      minimums[group][variation] or plan.loop_length, plan.loop_length)
  end

  for _, plan in ipairs(plans) do
    local target = minimums[groups[plan.source_snapshot]][plan.variation_index]
    if plan.loop_length > target + EPSILON then
      local geometry, reason = matched_interval(plan, target)
      if not geometry then
        return nil, "fixed anchor " .. tostring(plan.boundary_anchor)
          .. " cannot fit the matched overlap length: " .. tostring(reason)
      end
      local rebuilt, rebuild_reason = rebuild_plan_geometry(
        plan, geometry.source_project_start, geometry.source_end,
        geometry.boundary_anchor)
      if not rebuilt then
        return nil, "fixed anchor " .. tostring(plan.boundary_anchor)
          .. " cannot fit the matched overlap length: "
          .. tostring(rebuild_reason)
      end
      plan.warning = append_warning(plan.warning, "matched overlap length")
      plan.warning = append_warning(plan.warning, source_warning(
        plan.source_snapshot, plan.source_project_start,
        plan.source_span_length))
    end
  end
  return true
end

local function relayout_plans(plans)
  local positions = {}
  for _, plan in ipairs(plans) do
    local source_snapshot = plan.source_snapshot
    local output_position = positions[source_snapshot] or source_snapshot.position
    plan.output_position = output_position
    plan.components = build_components(plan)
    positions[source_snapshot] = output_position + plan.loop_length
      + plan.settings.position_space
  end
end

local function merged_plan_settings(plan_settings, input_settings)
  local merged = {}
  if type(plan_settings) == "table" then
    for key, value in pairs(plan_settings) do merged[key] = value end
  end
  if type(input_settings) == "table" then
    for key, value in pairs(input_settings) do
      if key ~= "analysis_window" then merged[key] = value end
    end
  end
  return settings_module.sanitize(merged)
end

function M.analyze_plans(reaper_api, plans, input_settings)
  if type(plans) ~= "table" then return nil, "plans must be a table" end
  local analyzed = {}
  local requested_window = type(input_settings) == "table"
    and input_settings.analysis_window or nil

  for index, plan in ipairs(plans) do
    if type(plan) ~= "table" or type(plan.source_snapshot) ~= "table" then
      return nil, "plan " .. index .. " is invalid"
    end
    local effective_plan = copy_plan(plan)
    effective_plan.settings = merged_plan_settings(
      plan.settings, input_settings)
    local window = math.min(0.05, effective_plan.source_span_length / 4)
    if core.is_finite_number(requested_window) and requested_window > 0 then
      window = math.min(requested_window, effective_plan.source_span_length / 4)
    end

    local start_target = effective_plan.boundary_anchor
    local end_target = effective_plan.source_end
      or (effective_plan.source_project_start
        + effective_plan.source_span_length)
    local start_result, start_reason = audio.find_zero_crossing(
      reaper_api, effective_plan.source_snapshot.take, start_target, window)
    local end_result, end_reason = audio.find_zero_crossing(
      reaper_api, effective_plan.source_snapshot.take, end_target, window)
    if not start_result then
      start_result = {
        project_time = start_target,
        fallback = true,
        warning = start_reason or "start zero-crossing analysis failed",
      }
    end
    if not end_result then
      end_result = {
        project_time = end_target,
        fallback = true,
        warning = end_reason or "end zero-crossing analysis failed",
      }
    end

    local adjusted, analysis_reason = M.apply_analysis(
      effective_plan, start_result, end_result)
    if adjusted then
      analyzed[#analyzed + 1] = adjusted
    else
      local fallback = copy_plan(effective_plan)
      fallback.warning = append_warning(fallback.warning, analysis_reason)
      analyzed[#analyzed + 1] = fallback
    end
  end

  local variations_matched, variation_reason = match_variation_lengths(analyzed)
  if not variations_matched then return nil, variation_reason end

  local match_overlap
  if type(input_settings) == "table"
      and input_settings.match_overlap ~= nil then
    match_overlap = settings_module.sanitize({
      match_overlap = input_settings.match_overlap,
    }).match_overlap
  else
    match_overlap = false
    for _, plan in ipairs(analyzed) do
      if plan.settings.match_overlap then
        match_overlap = true
        break
      end
    end
  end
  local matched, match_reason = match_analyzed_lengths(
    analyzed, match_overlap)
  if not matched then return nil, match_reason end
  relayout_plans(analyzed)
  return analyzed
end

return M
