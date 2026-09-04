local core = require("lib.core")

local M = {}

local DEFAULT_DISTANCE_WEIGHT = 0.001
local DEFAULT_CHUNK_FRAMES = 32768
local FRAME_EPSILON = 1e-9
local MAX_SAFE_TIME_MAGNITUDE = 2 ^ 53

local function is_positive_integer(value)
  return core.is_finite_number(value) and value > 0 and value == math.floor(value)
end

local function get_member(value, key)
  local ok, member = pcall(function()
    return value[key]
  end)
  if not ok then
    return nil
  end
  return member
end

local function validate_time_arguments(value, item_position, start_offset, playrate)
  if not core.is_finite_number(value)
      or not core.is_finite_number(item_position)
      or not core.is_finite_number(start_offset) then
    return nil, "time arguments must be finite numbers"
  end
  if math.abs(value) > MAX_SAFE_TIME_MAGNITUDE
      or math.abs(item_position) > MAX_SAFE_TIME_MAGNITUDE
      or math.abs(start_offset) > MAX_SAFE_TIME_MAGNITUDE then
    return nil, "time arguments exceed the supported numeric range"
  end
  if not core.is_finite_number(playrate) or playrate <= 0 then
    return nil, "playrate must be a finite positive number"
  end
  return true
end

function M.copy_samples(samples, expected_length)
  if not is_positive_integer(expected_length) then
    return nil, "expected sample length must be a positive integer"
  end
  if samples == nil then
    return nil, "sample buffer is required"
  end

  local converted
  local get_alloc = get_member(samples, "get_alloc")
  local to_table = get_member(samples, "table")
  if type(get_alloc) == "function" and type(to_table) == "function" then
    local capacity_ok, capacity = pcall(get_alloc)
    if not capacity_ok or not is_positive_integer(capacity) then
      return nil, "reaper array capacity is invalid"
    end
    if capacity < expected_length then
      return nil, "reaper array capacity is smaller than expected sample length"
    end

    local table_ok, values = pcall(to_table, 1, expected_length)
    if not table_ok or type(values) ~= "table" then
      return nil, "failed to convert reaper array to a Lua table"
    end
    converted = values
  elseif type(samples) == "table" then
    local length_ok, length = pcall(function()
      return #samples
    end)
    if not length_ok or length ~= expected_length then
      return nil, "sample array length does not match buffer dimensions"
    end
    converted = samples
  else
    return nil, "samples must be a Lua table or reaper array"
  end

  local result = {}
  for index = 1, expected_length do
    local value = converted[index]
    if not core.is_finite_number(value) then
      return nil, "samples must contain only finite numbers"
    end
    result[index] = value
  end
  return result
end

function M.is_zero_crossing(previous, current)
  if not core.is_finite_number(previous) or not core.is_finite_number(current) then
    return false
  end
  return (previous > 0 and current <= 0)
    or (previous < 0 and current >= 0)
end

local function crossing_fraction(previous, current)
  if current == 0 then
    return 1
  end
  local previous_abs = math.abs(previous)
  local current_abs = math.abs(current)
  local scale = math.max(previous_abs, current_abs)
  local previous_scaled = previous_abs / scale
  local current_scaled = current_abs / scale
  return previous_scaled / (previous_scaled + current_scaled)
end

function M.find_zero_crossing_in_buffer(samples, channels, frame_count, target_frame, options)
  if not is_positive_integer(channels) then
    return nil, "channels must be a positive integer"
  end
  if not is_positive_integer(frame_count) or frame_count < 2 then
    return nil, "frame_count must be an integer of at least 2"
  end
  if not is_positive_integer(target_frame) or target_frame > frame_count then
    return nil, "target_frame must be within the buffer"
  end
  if options ~= nil and type(options) ~= "table" then
    return nil, "options must be a table"
  end

  options = options or {}
  local distance_weight = options.distance_weight
  if distance_weight == nil then
    distance_weight = DEFAULT_DISTANCE_WEIGHT
  end
  if not core.is_finite_number(distance_weight) or distance_weight < 0 then
    return nil, "distance_weight must be a finite nonnegative number"
  end

  local distance_scale = options.distance_scale
  if distance_scale == nil then
    distance_scale = 1
  end
  if not core.is_finite_number(distance_scale) or distance_scale < 0 then
    return nil, "distance_scale must be a finite nonnegative number"
  end

  local expected_length = channels * frame_count
  if not is_positive_integer(expected_length) then
    return nil, "buffer dimensions are invalid"
  end
  local copied, copy_reason = M.copy_samples(samples, expected_length)
  if not copied then
    return nil, copy_reason
  end

  local target_position = target_frame - 1
  local best
  for frame_index = 2, frame_count do
    local quality_sum = 0
    local chosen_fraction
    local chosen_endpoint_amplitude

    for channel = 1, channels do
      local previous_index = (frame_index - 2) * channels + channel
      local current_index = (frame_index - 1) * channels + channel
      local previous = copied[previous_index]
      local current = copied[current_index]
      local endpoint_amplitude = math.min(math.abs(previous), math.abs(current))
      quality_sum = quality_sum + endpoint_amplitude

      if M.is_zero_crossing(previous, current)
          and (chosen_endpoint_amplitude == nil
            or endpoint_amplitude < chosen_endpoint_amplitude) then
        chosen_endpoint_amplitude = endpoint_amplitude
        chosen_fraction = crossing_fraction(previous, current)
      end
    end

    if chosen_fraction ~= nil then
      local frame_position = (frame_index - 2) + chosen_fraction
      local distance = math.abs(frame_position - target_position)
      local distance_scaled = distance * distance_scale
      local amplitude = quality_sum / channels
      local score = amplitude + distance_scaled * distance_weight
      if not core.is_finite_number(frame_position)
          or not core.is_finite_number(distance_scaled)
          or not core.is_finite_number(score) then
        return nil, "zero crossing score must be finite"
      end

      if not best or score < best.score then
        best = {
          frame_index = frame_index,
          frame_position = frame_position,
          fraction = chosen_fraction,
          score = score,
          amplitude = amplitude,
          endpoint_amplitude = chosen_endpoint_amplitude,
          distance = distance,
          distance_scaled = distance_scaled,
        }
      end
    end
  end

  if not best then
    return nil, "no zero crossing found"
  end
  return best
end

function M.project_to_source_time(project_time, item_position, start_offset, playrate)
  local valid, reason = validate_time_arguments(
    project_time, item_position, start_offset, playrate)
  if not valid then
    return nil, reason
  end
  local source_time = (project_time - item_position) * playrate + start_offset
  if not core.is_finite_number(source_time) then
    return nil, "source time result must be finite"
  end
  return source_time
end

function M.source_to_project_time(source_time, item_position, start_offset, playrate)
  local valid, reason = validate_time_arguments(
    source_time, item_position, start_offset, playrate)
  if not valid then
    return nil, reason
  end
  local project_time = item_position + (source_time - start_offset) / playrate
  if not core.is_finite_number(project_time) then
    return nil, "project time result must be finite"
  end
  return project_time
end

function M.search_buffer_range(target_project_time, window_seconds,
    accessor_start, accessor_end, sample_rate)
  if not core.is_finite_number(target_project_time)
      or not core.is_finite_number(window_seconds)
      or not core.is_finite_number(accessor_start)
      or not core.is_finite_number(accessor_end)
      or not core.is_finite_number(sample_rate) then
    return nil, "search range arguments must be finite numbers"
  end
  if window_seconds <= 0 then
    return nil, "window_seconds must be positive"
  end
  if sample_rate <= 0 then
    return nil, "sample_rate must be positive"
  end
  if accessor_end <= accessor_start then
    return nil, "audio accessor range must be nonempty"
  end

  local start_time = math.max(accessor_start, target_project_time - window_seconds)
  local end_time = math.min(accessor_end, target_project_time + window_seconds)
  if end_time <= start_time then
    return nil, "search window does not overlap the audio accessor"
  end

  local duration_frames = (end_time - start_time) * sample_rate
  if not core.is_finite_number(duration_frames) then
    return nil, "search range frame count must be finite"
  end
  local frame_count = math.ceil(duration_frames - FRAME_EPSILON)
  if frame_count < 2 then
    return nil, "search range must contain at least 2 frames"
  end

  local target_offset_frames = (target_project_time - start_time) * sample_rate
  if not core.is_finite_number(target_offset_frames) then
    return nil, "target frame must be finite"
  end
  local target_frame = core.round(target_offset_frames) + 1
  target_frame = core.clamp(target_frame, 1, frame_count)

  return {
    start_time = start_time,
    end_time = end_time,
    frame_count = frame_count,
    target_frame = target_frame,
  }
end

local REQUIRED_API_FUNCTIONS = {
  "CreateTakeAudioAccessor",
  "GetAudioAccessorStartTime",
  "GetAudioAccessorEndTime",
  "GetMediaItemTake_Source",
  "GetMediaSourceSampleRate",
  "GetMediaSourceNumChannels",
  "GetMediaItemTake_Item",
  "GetMediaItemInfo_Value",
  "GetMediaItemTakeInfo_Value",
  "new_array",
  "GetAudioAccessorSamples",
  "DestroyAudioAccessor",
}

local function validate_reaper_api(reaper_api)
  if type(reaper_api) ~= "table" then
    return nil, "reaper_api must be a table"
  end
  for _, name in ipairs(REQUIRED_API_FUNCTIONS) do
    if type(reaper_api[name]) ~= "function" then
      return nil, "reaper_api is missing " .. name
    end
  end
  return true
end

local function read_metadata(reaper_api, take)
  local source = reaper_api.GetMediaItemTake_Source(take)
  if source == nil then
    return nil, "take has no media source"
  end

  local sample_rate = reaper_api.GetMediaSourceSampleRate(source)
  if not core.is_finite_number(sample_rate) or sample_rate <= 0 then
    return nil, "media source sample rate must be finite and positive"
  end

  local channels = reaper_api.GetMediaSourceNumChannels(source)
  if not is_positive_integer(channels) then
    return nil, "media source channel count must be a positive integer"
  end

  local item = reaper_api.GetMediaItemTake_Item(take)
  if item == nil then
    return nil, "take has no media item"
  end

  local item_position = reaper_api.GetMediaItemInfo_Value(item, "D_POSITION")
  if not core.is_finite_number(item_position) then
    return nil, "item position must be finite"
  end

  local start_offset = reaper_api.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  if not core.is_finite_number(start_offset) then
    return nil, "take start offset must be finite"
  end

  local playrate = reaper_api.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if not core.is_finite_number(playrate) or playrate <= 0 then
    return nil, "take playrate must be finite and positive"
  end

  return {
    sample_rate = sample_rate,
    channels = channels,
    item_position = item_position,
    start_offset = start_offset,
    playrate = playrate,
  }
end

local function chunk_frames_from_options(options)
  if options ~= nil and type(options) ~= "table" then
    return nil, "options must be a table"
  end
  local chunk_frames = options and options.chunk_frames or DEFAULT_CHUNK_FRAMES
  if not is_positive_integer(chunk_frames) or chunk_frames < 2 then
    return nil, "chunk_frames must be an integer of at least 2"
  end
  return chunk_frames
end

local function read_samples_in_chunks(reaper_api, accessor, range, metadata, chunk_frames)
  local samples = {}
  local frame_offset = 0
  local first_chunk = true

  while frame_offset < range.frame_count do
    local frames_to_read = math.min(chunk_frames, range.frame_count - frame_offset)
    local sample_count = frames_to_read * metadata.channels
    if not is_positive_integer(sample_count) then
      return nil, "sample buffer size must be a finite positive integer"
    end

    local chunk = reaper_api.new_array(sample_count)
    if chunk == nil then
      return nil, "failed to allocate sample buffer"
    end

    local chunk_start_time = range.start_time + frame_offset / metadata.sample_rate
    local sample_result = reaper_api.GetAudioAccessorSamples(
      accessor,
      metadata.sample_rate,
      metadata.channels,
      chunk_start_time,
      frames_to_read,
      chunk)
    if sample_result ~= 1 then
      return nil, "GetAudioAccessorSamples returned " .. tostring(sample_result)
    end

    local copied, copy_reason = M.copy_samples(chunk, sample_count)
    if not copied then
      return nil, copy_reason
    end

    local first_sample = first_chunk and 1 or (metadata.channels + 1)
    for index = first_sample, sample_count do
      samples[#samples + 1] = copied[index]
    end
    first_chunk = false

    if frame_offset + frames_to_read >= range.frame_count then
      break
    end
    frame_offset = frame_offset + frames_to_read - 1
  end

  return samples
end

local function source_time_for_project(metadata, project_time)
  return M.project_to_source_time(
    project_time,
    metadata.item_position,
    metadata.start_offset,
    metadata.playrate)
end

local function read_accessor(reaper_api, accessor, take, target_project_time,
    window_seconds, options)
  local chunk_frames, chunk_reason = chunk_frames_from_options(options)
  if not chunk_frames then
    return nil, chunk_reason
  end

  local metadata, metadata_reason = read_metadata(reaper_api, take)
  if not metadata then
    return nil, metadata_reason
  end

  local accessor_start = reaper_api.GetAudioAccessorStartTime(accessor)
  local accessor_end = reaper_api.GetAudioAccessorEndTime(accessor)
  local target_accessor_time = target_project_time - metadata.item_position
  local range, range_reason = M.search_buffer_range(
    target_accessor_time,
    window_seconds,
    accessor_start,
    accessor_end,
    metadata.sample_rate)
  if not range then
    return nil, range_reason
  end

  local samples, sample_reason = read_samples_in_chunks(
    reaper_api, accessor, range, metadata, chunk_frames)
  if not samples then
    return nil, sample_reason
  end

  local buffer_options = {}
  if options then
    for key, value in pairs(options) do
      buffer_options[key] = value
    end
  end
  buffer_options.distance_scale = 1 / metadata.sample_rate

  local crossing, crossing_reason = M.find_zero_crossing_in_buffer(
    samples,
    metadata.channels,
    range.frame_count,
    range.target_frame,
    buffer_options)

  if crossing then
    local project_time = metadata.item_position + range.start_time
      + crossing.frame_position / metadata.sample_rate
    local source_time, source_reason = source_time_for_project(metadata, project_time)
    if not source_time then
      return nil, source_reason
    end

    return {
      project_time = project_time,
      source_time = source_time,
      frame_index = crossing.frame_index,
      frame_position = crossing.frame_position,
      fraction = crossing.fraction,
      score = crossing.score,
      amplitude = crossing.amplitude,
      endpoint_amplitude = crossing.endpoint_amplitude,
      distance = crossing.distance,
      distance_seconds = crossing.distance_scaled,
      sample_rate = metadata.sample_rate,
      channels = metadata.channels,
      fallback = false,
    }
  end

  if crossing_reason ~= "no zero crossing found" then
    return nil, crossing_reason
  end

  local fallback_frame = range.target_frame
  local frame_position = fallback_frame - 1
  local project_time = metadata.item_position
    + range.start_time + frame_position / metadata.sample_rate
  local source_time, source_reason = source_time_for_project(metadata, project_time)
  if not source_time then
    return nil, source_reason
  end

  local warning = "no zero crossing found; using the nearest readable target frame"
  return {
    project_time = project_time,
    source_time = source_time,
    frame_index = fallback_frame,
    frame_position = frame_position,
    distance = 0,
    distance_seconds = 0,
    sample_rate = metadata.sample_rate,
    channels = metadata.channels,
    fallback = true,
    warning = warning,
  }, warning
end

function M.find_zero_crossing(reaper_api, take, target_project_time, window_seconds, options)
  local valid_api, api_reason = validate_reaper_api(reaper_api)
  if not valid_api then
    return nil, api_reason
  end
  if take == nil then
    return nil, "take is required"
  end
  if not core.is_finite_number(target_project_time)
      or not core.is_finite_number(window_seconds) then
    return nil, "target time and window must be finite numbers"
  end
  if window_seconds <= 0 then
    return nil, "window_seconds must be positive"
  end

  local created, accessor_or_error = pcall(reaper_api.CreateTakeAudioAccessor, take)
  if not created then
    return nil, "failed to create audio accessor: " .. tostring(accessor_or_error)
  end
  local accessor = accessor_or_error
  if accessor == nil or accessor == false then
    return nil, "failed to create audio accessor"
  end

  local operation_ok, result, reason = pcall(
    read_accessor,
    reaper_api,
    accessor,
    take,
    target_project_time,
    window_seconds,
    options)
  local destroy_ok, destroy_error = pcall(reaper_api.DestroyAudioAccessor, accessor)

  local operation_error
  if not operation_ok then
    operation_error = "audio accessor operation failed: " .. tostring(result)
  elseif result == nil then
    operation_error = reason or "audio accessor operation failed"
  end

  local cleanup_error
  if not destroy_ok then
    cleanup_error = "failed to destroy audio accessor: " .. tostring(destroy_error)
  end

  if operation_error and cleanup_error then
    return nil, operation_error .. "; " .. cleanup_error
  end
  if operation_error then
    return nil, operation_error
  end
  if cleanup_error then
    return nil, cleanup_error
  end
  return result, reason
end

return M
