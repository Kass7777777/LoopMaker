local core = require("lib.core")

local M = {}

local MAX_SAFE_SAMPLE = 9007199254740991
local MAX_SAMPLE_RATE = 10000000
-- Limits divisor enumeration to sqrt(2^40) = 1,048,576 candidates (~265 days at 48 kHz).
local MAX_TOTAL_SAMPLES = 1099511627776
local FIRST_UNSAFE_FRACTIONAL_SAMPLE = 4503599627370496

local function finite_positive(value)
  return core.is_finite_number(value) and value > 0
end

local function round_samples(seconds, sample_rate, field)
  local limit = MAX_SAFE_SAMPLE / sample_rate
  if seconds > limit or seconds < -limit then
    return nil, field .. " cannot be quantized safely to an integer sample position"
  end

  local samples = seconds * (sample_rate + 0.0)
  if not core.is_finite_number(samples)
      or samples > MAX_SAFE_SAMPLE
      or samples < -MAX_SAFE_SAMPLE then
    return nil, field .. " cannot be quantized safely to an integer sample position"
  end

  local integer = math.tointeger(samples)
  if integer ~= nil then return integer end
  if samples >= FIRST_UNSAFE_FRACTIONAL_SAMPLE
      or samples <= -FIRST_UNSAFE_FRACTIONAL_SAMPLE then
    return nil, field .. " cannot be rounded safely to an integer sample position"
  end

  local rounded
  if samples >= 0 then
    rounded = math.floor(samples + 0.5)
  else
    rounded = math.ceil(samples - 0.5)
  end
  integer = math.tointeger(rounded)
  if integer == nil
      or integer > MAX_SAFE_SAMPLE
      or integer < -MAX_SAFE_SAMPLE then
    return nil, field .. " cannot be represented safely as an integer sample position"
  end
  return integer
end

local function ceil_divide(dividend, divisor)
  return dividend // divisor + (dividend % divisor == 0 and 0 or 1)
end

local function integer_square_root(value)
  local root = math.floor(math.sqrt(value))
  while root > value // root do root = root - 1 end
  while root + 1 <= value // (root + 1) do root = root + 1 end
  return root
end

local function smallest_divisor_in_range(value, first, last)
  if first > last then return nil end
  if value % first == 0 then return first end

  local best
  local root = integer_square_root(value)
  for divisor = 1, root do
    if value % divisor == 0 then
      if divisor >= first and divisor <= last
          and (best == nil or divisor < best) then
        best = divisor
      end

      local paired = value // divisor
      if paired >= first and paired <= last
          and (best == nil or paired < best) then
        best = paired
      end
    end
  end
  return best
end

local function no_divisor_reason(total_samples, first_count, last_count)
  return string.format(
    "no legal divisor for quantized total_samples=%d in count range [%d, %d]",
    total_samples, first_count, last_count)
end

function M.choose_layout(options)
  if type(options) ~= "table" then
    return nil, "options must be a table"
  end

  for _, field in ipairs({ "selection_start", "selection_finish" }) do
    if not core.is_finite_number(options[field]) then
      return nil, field .. " must be a finite number"
    end
  end
  if options.selection_finish <= options.selection_start then
    return nil, "selection_finish must be greater than selection_start"
  end

  local sample_rate = math.tointeger(options.sample_rate)
  if not finite_positive(options.sample_rate) or sample_rate == nil then
    return nil, "sample_rate must be a finite positive integer no greater than 10000000 Hz"
  end
  if sample_rate > MAX_SAMPLE_RATE then
    return nil, "sample_rate must be no greater than 10000000 Hz"
  end

  for _, field in ipairs({
    "natural_loop_length",
    "minimum_loop_length",
  }) do
    if not finite_positive(options[field]) then
      return nil, field .. " must be a finite positive number"
    end
  end
  local variation_count = math.tointeger(options.variation_count)
  if not finite_positive(options.variation_count) or variation_count == nil then
    return nil, "variation_count must be a finite positive integer"
  end

  local start_sample, start_reason = round_samples(
    options.selection_start, sample_rate, "selection_start")
  if start_sample == nil then return nil, start_reason end
  local end_sample, end_reason = round_samples(
    options.selection_finish, sample_rate, "selection_finish")
  if end_sample == nil then return nil, end_reason end

  local total_samples = end_sample - start_sample
  if total_samples <= 0 then
    return nil, "total_samples must be positive after selection quantization"
  end
  if total_samples > MAX_TOTAL_SAMPLES then
    return nil, string.format(
      "quantized total_samples=%d exceeds maximum %d; this limit bounds divisor search safely",
      total_samples, MAX_TOTAL_SAMPLES)
  end

  local natural_samples, natural_reason = round_samples(
    options.natural_loop_length, sample_rate, "natural_loop_length")
  if natural_samples == nil then return nil, natural_reason end
  if natural_samples <= 0 then
    return nil, "natural_loop_length must quantize to a positive sample count"
  end
  local minimum_samples, minimum_reason = round_samples(
    options.minimum_loop_length, sample_rate, "minimum_loop_length")
  if minimum_samples == nil then return nil, minimum_reason end
  if minimum_samples <= 0 then
    return nil, "minimum_loop_length must quantize to a positive sample count"
  end

  local minimum_count = math.max(
    variation_count,
    ceil_divide(total_samples, natural_samples))
  local maximum_count = total_samples // minimum_samples
  local count = smallest_divisor_in_range(
    total_samples, minimum_count, maximum_count)
  if count == nil then
    return nil, no_divisor_reason(
      total_samples, minimum_count, maximum_count)
  end

  local slot_samples = total_samples // count
  if slot_samples > natural_samples or slot_samples < minimum_samples then
    return nil, no_divisor_reason(
      total_samples, minimum_count, maximum_count)
  end

  return {
    start_sample = start_sample,
    end_sample = end_sample,
    total_samples = total_samples,
    natural_samples = natural_samples,
    minimum_samples = minimum_samples,
    minimum_count = minimum_count,
    slot_count = count,
    slot_samples = slot_samples,
    slot_length = slot_samples / sample_rate,
    quantized_start = start_sample / sample_rate,
    quantized_finish = end_sample / sample_rate,
  }
end

function M.balanced_sequence(variation_count, slot_count, shuffle, rng)
  local variations = math.tointeger(variation_count)
  if not finite_positive(variation_count) or variations == nil then
    return nil, "variation_count must be a finite positive integer"
  end

  local slots = math.tointeger(slot_count)
  if not finite_positive(slot_count) or slots == nil then
    return nil, "slot_count must be a finite positive integer"
  end
  if slots < variations then
    return nil, "slot_count must be greater than or equal to variation_count"
  end
  if type(shuffle) ~= "boolean" then
    return nil, "shuffle must be a boolean"
  end

  local random = rng == nil and math.random or rng
  if type(random) ~= "function" then
    return nil, "rng must be a function"
  end

  local sequence = {}
  while #sequence < slots do
    local round_size = math.min(variations, slots - #sequence)
    local round = {}
    for variation = 0, variations - 1 do
      round[#round + 1] = variation
    end

    if shuffle then
      for index = variations, 2, -1 do
        local ok, sample = pcall(random)
        if not ok then
          return nil, "rng failed: " .. tostring(sample)
        end
        if not core.is_finite_number(sample) or sample < 0 or sample > 1 then
          return nil, "rng must return a finite number in [0, 1]"
        end
        local swap_index = math.min(index, math.floor(sample * index) + 1)
        round[index], round[swap_index] = round[swap_index], round[index]
      end

      local previous = sequence[#sequence]
      if previous ~= nil and round[1] == previous then
        for index = 2, variations do
          if round[index] ~= previous then
            round[1], round[index] = round[index], round[1]
            break
          end
        end
      end
    end

    for index = 1, round_size do
      sequence[#sequence + 1] = round[index]
    end
  end

  return sequence
end

return M
