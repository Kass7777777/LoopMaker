local helper = require("tests.test_helper")
local audio = require("lib.audio")

local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local function assert_close(expected, actual, epsilon, message)
  assert_true(type(actual) == "number", message or "expected a number")
  assert_true(math.abs(expected - actual) <= (epsilon or 1e-9),
    message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)))
end

local function assert_rejected(result, reason)
  assert_equal(nil, result)
  assert_true(type(reason) == "string" and reason ~= "", "expected a clear rejection reason")
end

local function assert_contains(text, fragment)
  assert_true(type(text) == "string" and text:find(fragment, 1, true) ~= nil,
    "expected " .. tostring(text) .. " to contain " .. fragment)
end

local function fake_reaper_array(size)
  local storage = {}
  local methods = {}

  function methods.get_alloc()
    return size
  end

  function methods.table(first, last)
    local result = {}
    for index = first, last do
      result[#result + 1] = storage[index]
    end
    return result
  end

  return setmetatable({}, {
    __index = function(_, key)
      if type(key) == "number" then
        return storage[key]
      end
      return methods[key]
    end,
    __newindex = function(_, key, value)
      storage[key] = value
    end,
    __len = function()
      error("reaper.array has no ordinary length semantics")
    end,
  })
end

test("copy_samples copies an ordinary Lua table", function()
  local copied = audio.copy_samples({ 0.5, -0.25 }, 2)
  assert_equal(2, #copied)
  assert_close(0.5, copied[1])
  assert_close(-0.25, copied[2])
end)

test("copy_samples uses reaper array capacity and table conversion without length", function()
  local samples = fake_reaper_array(3)
  samples[1] = 0.5
  samples[2] = -0.25
  samples[3] = 0.125

  local copied, reason = audio.copy_samples(samples, 3)

  assert_equal(nil, reason)
  assert_equal(3, #copied)
  assert_close(0.5, copied[1])
  assert_close(-0.25, copied[2])
  assert_close(0.125, copied[3])
end)

test("copy_samples rejects insufficient reaper array capacity", function()
  local copied, reason = audio.copy_samples(fake_reaper_array(1), 2)
  assert_rejected(copied, reason)
end)

test("is_zero_crossing recognizes sign changes and arrivals at zero", function()
  assert_equal(true, audio.is_zero_crossing(1, -1))
  assert_equal(true, audio.is_zero_crossing(-1, 1))
  assert_equal(true, audio.is_zero_crossing(1, 0))
  assert_equal(true, audio.is_zero_crossing(-1, 0))
end)

test("is_zero_crossing does not recount departures from zero", function()
  assert_equal(false, audio.is_zero_crossing(0, 1))
  assert_equal(false, audio.is_zero_crossing(0, -1))
  assert_equal(false, audio.is_zero_crossing(0, 0))
  assert_equal(false, audio.is_zero_crossing(1, 1))
  assert_equal(false, audio.is_zero_crossing(-1, -1))
  assert_equal(false, audio.is_zero_crossing(0 / 0, 1))
end)

test("find_zero_crossing_in_buffer interpolates when the previous endpoint is smaller", function()
  local result = audio.find_zero_crossing_in_buffer(
    { 0.1, -0.9 }, 1, 2, 1, { distance_weight = 0 })

  assert_equal(2, result.frame_index)
  assert_close(0.1, result.fraction)
  assert_close(0.1, result.frame_position)
  assert_close(0.1, result.endpoint_amplitude)
  assert_close(0.1, result.amplitude)
end)

test("find_zero_crossing_in_buffer interpolates when the current endpoint is smaller", function()
  local result = audio.find_zero_crossing_in_buffer(
    { 0.9, -0.1 }, 1, 2, 2, { distance_weight = 0 })

  assert_equal(2, result.frame_index)
  assert_close(0.9, result.fraction)
  assert_close(0.9, result.frame_position)
end)

test("find_zero_crossing_in_buffer places an arrival at zero on the current frame", function()
  local result = audio.find_zero_crossing_in_buffer(
    { 1, 0 }, 1, 2, 2, { distance_weight = 0 })

  assert_close(1, result.fraction)
  assert_close(1, result.frame_position)
end)

test("find_zero_crossing_in_buffer interpolates extreme finite endpoints without overflow", function()
  local result, reason = audio.find_zero_crossing_in_buffer(
    { 1e308, -1e308 }, 1, 2, 1, { distance_weight = 0 })

  assert_equal(nil, reason)
  assert_close(0.5, result.fraction)
  assert_close(0.5, result.frame_position)
end)

test("find_zero_crossing_in_buffer averages channel quality", function()
  local result = audio.find_zero_crossing_in_buffer({
    0.8, 0.4,
    0.3, -0.2,
  }, 2, 2, 2, { distance_weight = 0 })

  assert_equal(2, result.frame_index)
  assert_close(2 / 3, result.fraction)
  assert_close(0.25, result.amplitude)
  assert_close(0.2, result.endpoint_amplitude)
  assert_close(0.25, result.score)
end)

test("find_zero_crossing_in_buffer uses distance_scale for normalized scoring", function()
  local result = audio.find_zero_crossing_in_buffer(
    { 1, -1, -1 }, 1, 3, 3,
    { distance_weight = 2, distance_scale = 0.001 })

  assert_close(0.5, result.frame_position)
  assert_close(1.5, result.distance)
  assert_close(0.0015, result.distance_scaled)
  assert_close(1.003, result.score)
end)

test("distance scaling keeps equivalent seconds comparable across sample rates", function()
  local low_rate = audio.find_zero_crossing_in_buffer(
    { 1, 0, -1 }, 1, 3, 3,
    { distance_weight = 2, distance_scale = 0.001 })
  local high_rate = audio.find_zero_crossing_in_buffer(
    { 1, 0, -1, -1 }, 1, 4, 4,
    { distance_weight = 2, distance_scale = 0.0005 })

  assert_close(0.001, low_rate.distance_scaled)
  assert_close(0.001, high_rate.distance_scaled)
  assert_close(low_rate.score, high_rate.score)
end)

test("find_zero_crossing_in_buffer returns a reason when no crossing exists", function()
  local result, reason = audio.find_zero_crossing_in_buffer({ 0.4, 0.2, 0.1 }, 1, 3, 2)
  assert_rejected(result, reason)
end)

test("find_zero_crossing_in_buffer validates dimensions samples target and options", function()
  local invalid_cases = {
    { { 1, -1 }, 0, 2, 1 },
    { { 1, -1 }, 1.5, 2, 1 },
    { { 1 }, 1, 1, 1 },
    { { 1 }, 1, 2, 1 },
    { { 1, -1, 0 }, 1, 2, 1 },
    { { 1, -1 }, 1, 2, 0 },
    { { 1, -1 }, 1, 2, 3 },
    { { 1, 0 / 0 }, 1, 2, 1 },
  }

  for _, case in ipairs(invalid_cases) do
    local result, reason = audio.find_zero_crossing_in_buffer(
      case[1], case[2], case[3], case[4])
    assert_rejected(result, reason)
  end

  local bad_options = {
    { distance_weight = math.huge },
    { distance_scale = -1 },
    { distance_scale = 0 / 0 },
  }
  for _, options in ipairs(bad_options) do
    local result, reason = audio.find_zero_crossing_in_buffer(
      { 1, -1 }, 1, 2, 1, options)
    assert_rejected(result, reason)
  end
end)

test("project and source time conversion round trips", function()
  local source_time = audio.project_to_source_time(12.5, 10, 3, 1.5)
  assert_close(6.75, source_time)

  local project_time = audio.source_to_project_time(source_time, 10, 3, 1.5)
  assert_close(12.5, project_time)
end)

test("time conversion rejects invalid rates and non-finite values", function()
  local calls = {
    function() return audio.project_to_source_time(1, 0, 0, 0) end,
    function() return audio.project_to_source_time(math.huge, 0, 0, 1) end,
    function() return audio.source_to_project_time(1, 0 / 0, 0, 1) end,
    function() return audio.source_to_project_time(1, 0, -math.huge, 1) end,
    function() return audio.project_to_source_time(1e308, -1e308, 0, 1) end,
    function() return audio.source_to_project_time(1e308, -1e308, 0, 1) end,
  }

  for _, call in ipairs(calls) do
    local result, reason = call()
    assert_rejected(result, reason)
  end
end)

test("search_buffer_range keeps an integer half-open frame count exact", function()
  local range = audio.search_buffer_range(10, 1, 9, 11, 4)

  assert_close(9, range.start_time)
  assert_close(11, range.end_time)
  assert_equal(8, range.frame_count)
  assert_equal(5, range.target_frame)
end)

test("search_buffer_range rounds a fractional half-open duration up", function()
  local range = audio.search_buffer_range(1.5, 2, 0, 2.625, 4)

  assert_equal(11, range.frame_count)
end)

test("search_buffer_range tolerates tiny floating error around an integer boundary", function()
  local slightly_above = audio.search_buffer_range(1, 2, 0, 2.00000000005, 4)
  local slightly_below = audio.search_buffer_range(1, 2, 0, 1.99999999995, 4)

  assert_equal(8, slightly_above.frame_count)
  assert_equal(8, slightly_below.frame_count)
end)

test("search_buffer_range includes the last legal frame before a non-aligned accessor end", function()
  local range = audio.search_buffer_range(1.5, 2, 0, 2.625, 4)

  assert_close(2.625, range.end_time)
  assert_equal(11, range.frame_count)
  assert_true(range.start_time + (range.frame_count - 1) / 4 < range.end_time)
end)

test("search_buffer_range rejects invalid and sub-two-frame ranges", function()
  local invalid_cases = {
    { 0, 0.009, 0, 0.009, 100 },
    { 0, -1, 0, 1, 100 },
    { 0, 1, 1, 0, 100 },
    { math.huge, 1, 0, 1, 100 },
    { 0, 1, 0, 1, 0 },
    { 0, 1e308, -1e308, 1e308, 2 },
  }

  for _, case in ipairs(invalid_cases) do
    local result, reason = audio.search_buffer_range(
      case[1], case[2], case[3], case[4], case[5])
    assert_rejected(result, reason)
  end
end)

local function successful_fake(samples, configuration)
  configuration = configuration or {}
  local sample_rate = configuration.sample_rate or 1000
  local channels = configuration.channels or 1
  local accessor_start = configuration.accessor_start or 10
  local accessor_end = configuration.accessor_end
    or (accessor_start + (#samples / channels) / sample_rate)
  local state = { destroyed = 0, calls = {}, allocations = {} }
  local accessor = {}
  local source = {}
  local item = {}
  local api = {}

  function api.CreateTakeAudioAccessor(take)
    state.take = take
    return accessor
  end

  function api.GetAudioAccessorStartTime(value)
    assert_equal(accessor, value)
    return accessor_start
  end

  function api.GetAudioAccessorEndTime(value)
    assert_equal(accessor, value)
    return accessor_end
  end

  function api.GetMediaItemTake_Source(take)
    state.source_take = take
    return source
  end

  function api.GetMediaSourceSampleRate(value)
    assert_equal(source, value)
    return sample_rate
  end

  function api.GetMediaSourceNumChannels(value)
    assert_equal(source, value)
    return channels
  end

  function api.GetMediaItemTake_Item(take)
    state.item_take = take
    return item
  end

  function api.GetMediaItemInfo_Value(value, key)
    assert_equal(item, value)
    assert_equal("D_POSITION", key)
    return configuration.item_position or 8
  end

  function api.GetMediaItemTakeInfo_Value(take, key)
    state.metadata_take = take
    if key == "D_STARTOFFS" then
      return configuration.start_offset or 2
    end
    if key == "D_PLAYRATE" then
      return configuration.playrate or 2
    end
    error("unexpected take metadata key: " .. tostring(key))
  end

  function api.new_array(size)
    state.allocations[#state.allocations + 1] = size
    return fake_reaper_array(size)
  end

  function api.GetAudioAccessorSamples(value, requested_rate, requested_channels,
      start_time, frame_count, array)
    assert_equal(accessor, value)
    assert_equal(sample_rate, requested_rate)
    assert_equal(channels, requested_channels)
    state.calls[#state.calls + 1] = {
      start_time = start_time,
      frame_count = frame_count,
    }

    local first_frame = math.floor((start_time - accessor_start) * sample_rate + 0.5) + 1
    for local_frame = 1, frame_count do
      local source_frame = first_frame + local_frame - 1
      for channel = 1, channels do
        local source_index = (source_frame - 1) * channels + channel
        local target_index = (local_frame - 1) * channels + channel
        array[target_index] = samples[source_index]
      end
    end

    if type(configuration.sample_result) == "function" then
      return configuration.sample_result(#state.calls)
    end
    if configuration.sample_result ~= nil then
      return configuration.sample_result
    end
    return 1
  end

  function api.DestroyAudioAccessor(value)
    assert_equal(accessor, value)
    state.destroyed = state.destroyed + 1
    if configuration.destroy_error then
      error(configuration.destroy_error)
    end
  end

  return api, state
end

test("find_zero_crossing reads half-open samples and returns interpolated project and source time", function()
  local api, state = successful_fake({ 0.8, 0.2, -0.1, -0.4 })
  local take = {}
  local result, reason = audio.find_zero_crossing(api, take, 10.002, 0.002,
    { distance_weight = 0 })

  assert_equal(nil, reason)
  assert_equal(take, state.take)
  assert_equal(take, state.source_take)
  assert_equal(take, state.item_take)
  assert_equal(take, state.metadata_take)
  assert_equal(1, #state.calls)
  assert_close(10, state.calls[1].start_time)
  assert_equal(4, state.calls[1].frame_count)
  assert_equal(4, state.allocations[1])
  assert_equal(1, state.destroyed)

  assert_close(10.001666666666667, result.project_time)
  assert_close(6.003333333333334, result.source_time)
  assert_equal(3, result.frame_index)
  assert_close(5 / 3, result.frame_position)
  assert_close(1 / 3000, result.distance_seconds)
  assert_equal(false, result.fallback)
  assert_equal(1000, result.sample_rate)
  assert_equal(1, result.channels)
end)

test("find_zero_crossing reads chunks with overlap and finds a cross-chunk boundary", function()
  local api, state = successful_fake({ 1, 1, 1, -1, -1, -1 })

  local result, reason = audio.find_zero_crossing(api, {}, 10.003, 0.003,
    { chunk_frames = 3, distance_weight = 0 })

  assert_equal(nil, reason)
  assert_equal(false, result.fallback)
  assert_equal(4, result.frame_index)
  assert_close(10.0025, result.project_time)
  assert_true(#state.calls > 1)
  for index, call in ipairs(state.calls) do
    assert_true(call.frame_count <= 3, "chunk " .. index .. " exceeded chunk_frames")
    assert_true(state.allocations[index] <= 3, "allocation exceeded chunk_frames")
  end
  assert_close(10, state.calls[1].start_time)
  assert_close(10.002, state.calls[2].start_time)
  assert_equal(1, state.destroyed)
end)

test("find_zero_crossing averages channel amplitude so duplicated channels keep score scale", function()
  local mono = audio.find_zero_crossing_in_buffer(
    { 0.5, -0.5 }, 1, 2, 1, { distance_weight = 0 })
  local stereo = audio.find_zero_crossing_in_buffer(
    { 0.5, 0.5, -0.5, -0.5 }, 2, 2, 1, { distance_weight = 0 })

  assert_close(mono.amplitude, stereo.amplitude)
  assert_close(mono.score, stereo.score)
end)

test("find_zero_crossing returns a clamped target fallback when no crossing exists", function()
  local api, state = successful_fake({ 0.8, 0.6, 0.4, 0.2 })

  local result, warning = audio.find_zero_crossing(api, {}, 10.005, 0.01)

  assert_true(result ~= nil)
  assert_equal(true, result.fallback)
  assert_contains(warning, "no zero crossing")
  assert_contains(result.warning, "no zero crossing")
  assert_equal(4, result.frame_index)
  assert_close(3, result.frame_position)
  assert_close(10.003, result.project_time)
  assert_close(6.006, result.source_time)
  assert_equal(1, state.destroyed)
end)

test("find_zero_crossing accepts only sample return code 1", function()
  for _, return_code in ipairs({ 0, -1 }) do
    local api, state = successful_fake({ 1, -1, -1, -1 }, {
      sample_result = return_code,
    })
    local result, reason = audio.find_zero_crossing(api, {}, 10.002, 0.002)
    assert_rejected(result, reason)
    assert_contains(reason, tostring(return_code))
    assert_equal(1, state.destroyed)
  end
end)

test("find_zero_crossing destroys the accessor when sampling throws", function()
  local api, state = successful_fake({ 1, -1, -1, -1 })
  function api.GetAudioAccessorSamples()
    error("sampling failed")
  end

  local result, reason = audio.find_zero_crossing(api, {}, 10.002, 0.002)

  assert_rejected(result, reason)
  assert_contains(reason, "sampling failed")
  assert_equal(1, state.destroyed)
end)

test("find_zero_crossing preserves operation and destroy failures", function()
  local api, state = successful_fake({ 1, -1, -1, -1 }, {
    destroy_error = "destroy failed",
  })
  function api.GetAudioAccessorSamples()
    error("sampling failed")
  end

  local result, reason = audio.find_zero_crossing(api, {}, 10.002, 0.002)

  assert_rejected(result, reason)
  assert_contains(reason, "sampling failed")
  assert_contains(reason, "destroy failed")
  assert_equal(1, state.destroyed)
end)

test("find_zero_crossing fails when only accessor destruction fails", function()
  local api = successful_fake({ 1, -1, -1, -1 }, {
    destroy_error = "destroy failed",
  })

  local result, reason = audio.find_zero_crossing(api, {}, 10.002, 0.002)

  assert_rejected(result, reason)
  assert_contains(reason, "destroy failed")
end)

test("find_zero_crossing rejects invalid item and take metadata safely", function()
  local api, state = successful_fake({ 1, -1, -1, -1 })
  function api.GetMediaItemInfo_Value()
    return 0 / 0
  end

  local result, reason = audio.find_zero_crossing(api, {}, 10.002, 0.002)

  assert_rejected(result, reason)
  assert_contains(reason, "item position")
  assert_equal(1, state.destroyed)
end)

test("find_zero_crossing rejects invalid source metadata safely", function()
  local api, state = successful_fake({ 1, -1, -1, -1 })
  function api.GetMediaSourceSampleRate()
    return 0 / 0
  end

  local result, reason = audio.find_zero_crossing(api, {}, 10.002, 0.002)

  assert_rejected(result, reason)
  assert_equal(1, state.destroyed)
end)

test("find_zero_crossing rejects chunk sizes below two", function()
  local api, state = successful_fake({ 1, -1, -1, -1 })

  local result, reason = audio.find_zero_crossing(api, {}, 10.002, 0.002,
    { chunk_frames = 1 })

  assert_rejected(result, reason)
  assert_contains(reason, "chunk_frames")
  assert_equal(1, state.destroyed)
end)

return true
