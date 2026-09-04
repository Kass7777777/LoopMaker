local helper = require("tests.test_helper")
local timeline_fill = require("lib.timeline_fill")

local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local function assert_close(expected, actual, epsilon)
  assert_true(type(actual) == "number", "expected a number")
  assert_true(math.abs(expected - actual) <= (epsilon or 1e-12),
    "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assert_rejected(options, expected_fragment)
  local layout, reason = timeline_fill.choose_layout(options)
  assert_equal(nil, layout)
  assert_true(type(reason) == "string" and reason ~= "",
    "expected a clear rejection reason")
  if expected_fragment then
    assert_true(reason:find(expected_fragment, 1, true) ~= nil,
      "expected " .. reason .. " to contain " .. expected_fragment)
  end
  return reason
end

local function call_with_instruction_limit(callback, maximum_batches)
  local batches = 0
  debug.sethook(function()
    batches = batches + 1
    if batches > maximum_batches then
      error("instruction limit exceeded", 0)
    end
  end, "", 1000)
  local results = { pcall(callback) }
  debug.sethook()
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2)
end

local function options(overrides)
  local value = {
    sample_rate = 48000,
    selection_start = 1,
    selection_finish = 3,
    natural_loop_length = 1,
    variation_count = 1,
    minimum_loop_length = 0.024,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

test("choose_layout finds 32 equal sample slots for a 61 second selection", function()
  local layout, reason = timeline_fill.choose_layout(options({
    selection_finish = 62,
    natural_loop_length = 2,
    variation_count = 5,
  }))

  assert_equal(nil, reason)
  assert_equal(2928000, layout.total_samples)
  assert_equal(96000, layout.natural_samples)
  assert_equal(31, layout.minimum_count)
  assert_equal(32, layout.slot_count)
  assert_equal(91500, layout.slot_samples)
  assert_equal("integer", math.type(layout.slot_samples))
  assert_close(1.90625, layout.slot_length)
end)

test("choose_layout quantizes both selection boundaries to sample positions", function()
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 10,
    selection_start = 1.24,
    selection_finish = 2.76,
    natural_loop_length = 0.8,
    variation_count = 2,
    minimum_loop_length = 0.1,
  })))

  assert_equal(12, layout.start_sample)
  assert_equal(28, layout.end_sample)
  assert_equal(16, layout.total_samples)
  assert_close(1.2, layout.quantized_start)
  assert_close(2.8, layout.quantized_finish)
end)

test("choose_layout accepts a selection starting at zero", function()
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 10,
    selection_start = 0,
    selection_finish = 0.8,
    natural_loop_length = 0.4,
    minimum_loop_length = 0.1,
  })))

  assert_equal(0, layout.start_sample)
  assert_equal(8, layout.end_sample)
end)

test("choose_layout rounds negative half samples away from zero", function()
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 10,
    selection_start = -1.25,
    selection_finish = -0.45,
    natural_loop_length = 0.4,
    minimum_loop_length = 0.1,
  })))

  assert_equal(-13, layout.start_sample)
  assert_equal(-5, layout.end_sample)
  assert_equal(8, layout.total_samples)
  assert_close(-1.3, layout.quantized_start)
  assert_close(-0.5, layout.quantized_finish)
end)

test("choose_layout never returns fewer slots than variation_count", function()
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 1000,
    selection_finish = 1.12,
    natural_loop_length = 0.1,
    variation_count = 7,
    minimum_loop_length = 0.001,
  })))

  assert_equal(7, layout.minimum_count)
  assert_equal(8, layout.slot_count)
  assert_true(layout.slot_count >= 7)
end)

test("choose_layout does not stretch slots beyond the natural loop length", function()
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 1000,
    selection_finish = 1.1,
    natural_loop_length = 0.03,
    minimum_loop_length = 0.005,
  })))

  assert_equal(30, layout.natural_samples)
  assert_equal(4, layout.slot_count)
  assert_equal(25, layout.slot_samples)
  assert_true(layout.slot_samples <= layout.natural_samples)
  assert_true(layout.slot_length <= 0.03)
end)

test("choose_layout accepts slots exactly at the 24 millisecond lower limit", function()
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 1000,
    selection_finish = 1.12,
    natural_loop_length = 0.024,
    minimum_loop_length = 0.024,
  })))

  assert_equal(24, layout.minimum_samples)
  assert_equal(5, layout.slot_count)
  assert_equal(24, layout.slot_samples)
  assert_close(0.024, layout.slot_length)
end)

test("choose_layout searches a huge count range without scanning every count", function()
  local layout = call_with_instruction_limit(function()
    return assert(timeline_fill.choose_layout(options({
      sample_rate = 1,
      selection_start = 0,
      selection_finish = 4000000000,
      natural_loop_length = 2,
      variation_count = 2000000001,
      minimum_loop_length = 1,
    })))
  end, 5000)

  assert_equal(4000000000, layout.slot_count)
  assert_equal(1, layout.slot_samples)
  assert_equal("integer", math.type(layout.slot_samples))
end)

test("choose_layout preserves large odd integer sample coordinates", function()
  local start_sample = 4503599627370497
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 1,
    selection_start = start_sample,
    selection_finish = start_sample + 8,
    natural_loop_length = 8,
    minimum_loop_length = 1,
  })))

  assert_equal(start_sample, layout.start_sample)
  assert_equal(start_sample + 8, layout.end_sample)
  assert_equal(8, layout.total_samples)
end)

test("choose_layout accepts total_samples at the bounded search limit", function()
  local maximum_total = 1099511627776
  local layout = assert(timeline_fill.choose_layout(options({
    sample_rate = 1,
    selection_start = 0,
    selection_finish = maximum_total,
    natural_loop_length = maximum_total,
    minimum_loop_length = 1,
  })))

  assert_equal(maximum_total, layout.total_samples)
  assert_equal(1, layout.slot_count)
end)

test("choose_layout rejects total_samples above the bounded search limit", function()
  local maximum_total = 1099511627776
  local reason = assert_rejected(options({
    sample_rate = 1,
    selection_start = 0,
    selection_finish = maximum_total + 1,
    natural_loop_length = maximum_total + 1,
    minimum_loop_length = 1,
  }), "total_samples")

  assert_true(reason:find(tostring(maximum_total), 1, true) ~= nil)
  assert_true(reason:find("maximum", 1, true) ~= nil)
end)

test("choose_layout rejects sample coordinates beyond the safe integer range", function()
  assert_rejected(options({
    sample_rate = 1,
    selection_start = 0,
    selection_finish = 9007199254740992,
    natural_loop_length = 9007199254740992,
    minimum_loop_length = 1,
  }), "safely")
end)

test("choose_layout rejects before integer sample multiplication can wrap", function()
  assert_rejected(options({
    sample_rate = 1024,
    selection_start = 0,
    selection_finish = 9007199254740991,
    natural_loop_length = 1,
    minimum_loop_length = 1,
  }), "safely")
end)

test("choose_layout rejects an unsafe quantized total from safe endpoints", function()
  local reason = assert_rejected(options({
    sample_rate = 1,
    selection_start = -4503599627370496,
    selection_finish = 4503599627370496,
    natural_loop_length = 4503599627370496,
    minimum_loop_length = 1,
  }), "total_samples")
  assert_true(reason:find("safely", 1, true) ~= nil)
end)

test("choose_layout rejection reports quantized total and count search range", function()
  local reason = assert_rejected(options({
    sample_rate = 1000,
    selection_finish = 1.01,
    natural_loop_length = 0.004,
    variation_count = 3,
    minimum_loop_length = 0.003,
  }), "divisor")
  assert_true(reason:find("total_samples=10", 1, true) ~= nil)
  assert_true(reason:find("count range [3, 3]", 1, true) ~= nil)
end)

test("choose_layout rejects nonnumeric positions and nonpositive sizing inputs", function()
  assert_rejected(nil, "options")
  assert_rejected(options({ selection_start = "invalid" }), "selection_start")
  assert_rejected(options({ selection_finish = "invalid" }), "selection_finish")
  for _, field in ipairs({
    "sample_rate",
    "natural_loop_length",
    "variation_count",
    "minimum_loop_length",
  }) do
    for _, invalid in ipairs({ "invalid", 0, -1 }) do
      assert_rejected(options({ [field] = invalid }), field)
    end
  end
end)

test("choose_layout accepts common integer sample rates", function()
  for _, sample_rate in ipairs({ 44100, 48000, 96000, 192000 }) do
    local layout = assert(timeline_fill.choose_layout(options({
      sample_rate = sample_rate,
      selection_start = 0,
      selection_finish = 1,
      natural_loop_length = 1,
      minimum_loop_length = 0.024,
    })))
    assert_equal(sample_rate, layout.total_samples)
  end
end)

test("choose_layout rejects fractional sample rates", function()
  local reason = assert_rejected(options({ sample_rate = 48000.5 }), "sample_rate")
  assert_true(reason:find("integer", 1, true) ~= nil)
end)

test("choose_layout rejects sample rates above the supported maximum", function()
  local reason = assert_rejected(options({ sample_rate = 10000001 }), "sample_rate")
  assert_true(reason:find("10000000", 1, true) ~= nil)
end)

test("choose_layout rejects huge integer sample rates before float conversion", function()
  local reason = assert_rejected(options({
    sample_rate = 9007199254740993,
  }), "sample_rate")
  assert_true(reason:find("10000000", 1, true) ~= nil)
end)

test("choose_layout rejects a noninteger variation_count", function()
  assert_rejected(options({ variation_count = 1.5 }), "variation_count")
end)

test("choose_layout rejects NaN and infinite inputs", function()
  for _, field in ipairs({
    "sample_rate",
    "selection_start",
    "selection_finish",
    "natural_loop_length",
    "variation_count",
    "minimum_loop_length",
  }) do
    for _, invalid in ipairs({ 0 / 0, math.huge, -math.huge }) do
      assert_rejected(options({ [field] = invalid }), field)
    end
  end
end)

test("choose_layout rejects ranges and lengths that quantize to zero samples", function()
  assert_rejected(options({
    sample_rate = 1000,
    selection_start = 1.0001,
    selection_finish = 1.0002,
  }), "total_samples")
  assert_rejected(options({
    sample_rate = 1000,
    natural_loop_length = 0.0001,
  }), "natural_loop_length")
  assert_rejected(options({
    sample_rate = 1000,
    minimum_loop_length = 0.0001,
  }), "minimum_loop_length")
end)

local function variation_counts(sequence, variation_count)
  local counts = {}
  for variation = 0, variation_count - 1 do counts[variation] = 0 end
  for _, variation in ipairs(sequence) do
    assert_true(variation >= 0 and variation < variation_count,
      "variation index out of range: " .. tostring(variation))
    counts[variation] = counts[variation] + 1
  end
  return counts
end

local function assert_no_adjacent_duplicates(sequence)
  for index = 2, #sequence do
    assert_true(sequence[index] ~= sequence[index - 1],
      "adjacent duplicate at slot " .. tostring(index))
  end
end

local function assert_sequence(expected, actual)
  assert_equal(#expected, #actual)
  for index, value in ipairs(expected) do
    assert_equal(value, actual[index], "unexpected value at slot " .. tostring(index))
  end
end

local function assert_sequence_rejected(variation_count, slot_count, shuffle, rng, fragment)
  local sequence, reason = timeline_fill.balanced_sequence(
    variation_count, slot_count, shuffle, rng)
  assert_equal(nil, sequence)
  assert_true(type(reason) == "string" and reason ~= "",
    "expected a clear rejection reason")
  assert_true(reason:find(fragment, 1, true) ~= nil,
    "expected " .. reason .. " to contain " .. fragment)
end

test("balanced_sequence balances five variations across 31 shuffled slots", function()
  local sequence, reason = timeline_fill.balanced_sequence(5, 31, true, function()
    return 0
  end)

  assert_equal(nil, reason)
  assert_equal(31, #sequence)
  local counts = variation_counts(sequence, 5)
  local minimum, maximum = counts[0], counts[0]
  for variation = 0, 4 do
    minimum = math.min(minimum, counts[variation])
    maximum = math.max(maximum, counts[variation])
    assert_true(counts[variation] >= 1)
  end
  assert_true(maximum - minimum <= 1)
  assert_no_adjacent_duplicates(sequence)
end)

test("balanced_sequence without shuffle uses fixed round robin order", function()
  local sequence = assert(timeline_fill.balanced_sequence(3, 8, false))
  assert_sequence({ 0, 1, 2, 0, 1, 2, 0, 1 }, sequence)
end)

test("balanced_sequence shuffles a partial round without repeating a variation", function()
  local calls = 0
  local sequence = assert(timeline_fill.balanced_sequence(4, 6, true, function()
    calls = calls + 1
    return 1
  end))
  assert_sequence({ 0, 1, 2, 3, 0, 1 }, sequence)
  assert_equal(6, calls)
  local counts = variation_counts(sequence, 4)
  assert_equal(2, counts[0])
  assert_equal(2, counts[1])
  assert_equal(1, counts[2])
  assert_equal(1, counts[3])
end)

test("balanced_sequence accepts rng endpoints zero and one without out of range indexes", function()
  for _, value in ipairs({ 0, 1 }) do
    local sequence = assert(timeline_fill.balanced_sequence(5, 9, true, function()
      return value
    end))
    assert_equal(9, #sequence)
    variation_counts(sequence, 5)
  end
end)

test("balanced_sequence permits unavoidable adjacency for one variation", function()
  local sequence = assert(timeline_fill.balanced_sequence(1, 4, true, function()
    return 0
  end))
  assert_sequence({ 0, 0, 0, 0 }, sequence)
end)

test("balanced_sequence rejects invalid arguments", function()
  for _, invalid in ipairs({ "invalid", true, 0, -1, 1.5, 0 / 0, math.huge }) do
    assert_sequence_rejected(invalid, 3, true, function() return 0 end,
      "variation_count")
    assert_sequence_rejected(2, invalid, true, function() return 0 end,
      "slot_count")
  end
  assert_sequence_rejected(nil, 3, true, function() return 0 end, "variation_count")
  assert_sequence_rejected(2, nil, true, function() return 0 end, "slot_count")
  assert_sequence_rejected(3, 2, true, function() return 0 end, "slot_count")
  assert_sequence_rejected(2, 2, nil, function() return 0 end, "shuffle")
  assert_sequence_rejected(2, 2, 1, function() return 0 end, "shuffle")
  assert_sequence_rejected(2, 2, true, false, "rng")
  assert_sequence_rejected(2, 2, true, "invalid", "rng")
end)

test("balanced_sequence rejects non-finite and out of range rng values", function()
  for _, invalid in ipairs({ "invalid", -0.1, 1.1, 0 / 0, math.huge }) do
    assert_sequence_rejected(2, 2, true, function() return invalid end, "rng")
  end
end)

test("balanced_sequence converts a throwing rng into a clear error", function()
  assert_sequence_rejected(2, 2, true, function()
    error("rng exploded")
  end, "rng")
end)

test("balanced_sequence adjacency repair preserves variation counts", function()
  local values = { 1, 1, 0, 1 }
  local call = 0
  local sequence = assert(timeline_fill.balanced_sequence(3, 6, true, function()
    call = call + 1
    return values[call]
  end))

  assert_sequence({ 0, 1, 2, 1, 2, 0 }, sequence)
  assert_no_adjacent_duplicates(sequence)
  local counts = variation_counts(sequence, 3)
  assert_equal(2, counts[0])
  assert_equal(2, counts[1])
  assert_equal(2, counts[2])
end)

return true
