local M = {}

function M.is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

function M.clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

function M.round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

function M.deep_copy(value, memo)
  if type(value) ~= "table" then
    return value
  end

  memo = memo or {}
  if memo[value] then
    return memo[value]
  end

  local copy = {}
  memo[value] = copy
  for key, item in pairs(value) do
    copy[M.deep_copy(key, memo)] = M.deep_copy(item, memo)
  end
  return copy
end

function M.crossfade_length(loop_length, ratio, max_seconds)
  loop_length = M.is_finite_number(loop_length) and math.max(0, loop_length) or 0
  ratio = M.is_finite_number(ratio) and M.clamp(ratio, 0, 0.5) or 0
  max_seconds = M.is_finite_number(max_seconds) and math.max(0, max_seconds) or 0

  local length = math.min(loop_length * ratio, loop_length / 2)
  if max_seconds > 0 then
    length = math.min(length, max_seconds)
  end
  return length
end

return M
