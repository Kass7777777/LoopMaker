local core = require("lib.core")

local M = {}

local DEFAULTS = {
  glue = true,
  create_regions = false,
  loops = 1,
  position_space = 0,
  shuffle = false,
  second_snap = false,
  match_overlap = false,
  cf_ratio = 0.1,
  cf_curve = 0,
  cf_max = 0,
  shepard = false,
  pitch = 12,
  offset = 0,
  color_items = false,
  remove_ext = false,
  prefix = "",
  suffix = "",
  separator = "_",
  number = true,
  start_number = 1,
  leading_zeros = 2,
  show_shepard = false,
  show_zc = false,
  show_name = true,
  preset = "Default",
}

local function value_or_default(value, default)
  if type(value) ~= type(default) then
    return default
  end
  if type(default) == "number" and not core.is_finite_number(value) then
    return default
  end
  return value
end

local function integer_in_range(value, minimum, maximum)
  return core.clamp(core.round(value), minimum, maximum)
end

function M.defaults()
  return core.deep_copy(DEFAULTS)
end

function M.sanitize(input)
  input = type(input) == "table" and input or {}
  local result = M.defaults()

  for key, default in pairs(DEFAULTS) do
    if input[key] ~= nil then
      result[key] = value_or_default(input[key], default)
    end
  end

  result.loops = integer_in_range(result.loops, 1, 1000)
  result.start_number = integer_in_range(result.start_number, 0, 999999)
  result.leading_zeros = integer_in_range(result.leading_zeros, 0, 12)
  result.position_space = math.max(0, result.position_space)
  result.cf_ratio = core.clamp(result.cf_ratio, 0, 0.5)
  result.cf_curve = integer_in_range(result.cf_curve, 0, 4)
  result.cf_max = math.max(0, result.cf_max)
  result.pitch = core.clamp(result.pitch, -96, 96)

  return result
end

return M
