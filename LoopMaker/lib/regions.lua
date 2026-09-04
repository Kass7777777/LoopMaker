local core = require("lib.core")
local naming = require("lib.naming")

local M = {}
local COLOR_FLAG = 0x1000000

local function rounded_sample(value, sample_rate)
  local scaled = value * sample_rate
  if scaled >= 0 then return math.floor(scaled + 0.5) end
  return math.ceil(scaled - 0.5)
end

function M.plan_outputs(outputs, sample_rate, settings, color)
  if type(outputs) ~= "table" then return nil, "outputs must be a table" end
  sample_rate = math.tointeger(sample_rate)
  if sample_rate == nil or sample_rate <= 0 then
    return nil, "sample_rate must be a positive integer"
  end
  local by_key, groups = {}, {}
  for index, output in ipairs(outputs) do
    local plan = type(output) == "table" and output.plan or nil
    local source = type(plan) == "table" and plan.source_snapshot or nil
    if type(source) ~= "table"
        or not core.is_finite_number(plan.output_position)
        or not core.is_finite_number(plan.loop_length)
        or plan.loop_length <= 0 then
      return nil, "output " .. index .. " has invalid Region geometry"
    end
    local start_sample = rounded_sample(plan.output_position, sample_rate)
    local end_sample = rounded_sample(
      plan.output_position + plan.loop_length, sample_rate)
    if end_sample <= start_sample then
      return nil, "output " .. index .. " Region is empty after sample quantization"
    end
    local key = start_sample .. ":" .. end_sample
    if by_key[key] == nil then
      local group = {
        start_sample = start_sample,
        end_sample = end_sample,
        source_name = source.name or "Loop",
      }
      by_key[key] = group
      groups[#groups + 1] = group
    end
  end
  table.sort(groups, function(left, right)
    if left.start_sample == right.start_sample then
      return left.end_sample < right.end_sample
    end
    return left.start_sample < right.start_sample
  end)
  local native_color = math.tointeger(color) or 0
  native_color = native_color > 0 and (native_color | COLOR_FLAG) or 0
  local planned = {}
  for index, group in ipairs(groups) do
    local name, reason = naming.build(group.source_name, settings, index - 1)
    if not name then return nil, reason end
    planned[index] = {
      start = group.start_sample / sample_rate,
      finish = group.end_sample / sample_rate,
      name = name,
      color = native_color,
    }
  end
  return planned
end

local function validate_api(api)
  if type(api) ~= "table" then return nil, "reaper_api must be a table" end
  for _, name in ipairs({ "AddProjectMarker2", "DeleteProjectMarker" }) do
    if type(api[name]) ~= "function" then
      return nil, "reaper_api is missing " .. name
    end
  end
  return true
end

function M.remove(api, project, created)
  local valid, reason = validate_api(api)
  if not valid then return nil, reason end
  local errors = {}
  for index = #(created or {}), 1, -1 do
    local entry = created[index]
    local ok, deleted = pcall(api.DeleteProjectMarker, project, entry.index, true)
    if not ok or deleted == false then
      errors[#errors + 1] = "DeleteProjectMarker failed for Region "
        .. tostring(entry.index) .. ": " .. tostring(deleted)
    end
  end
  if #errors > 0 then return nil, table.concat(errors, "; ") end
  return true
end

function M.create(api, project, planned)
  local valid, reason = validate_api(api)
  if not valid then return nil, reason end
  if type(planned) ~= "table" then return nil, "planned Regions must be a table" end
  local created = {}
  for plan_index, plan in ipairs(planned) do
    local ok, result = pcall(api.AddProjectMarker2, project, true,
      plan.start, plan.finish, plan.name, -1, plan.color)
    local region_index = ok and math.tointeger(result) or nil
    if region_index == nil or region_index < 0 then
      local _, cleanup_reason = M.remove(api, project, created)
      local failure = ok and "AddProjectMarker2 returned " .. tostring(result)
        or "AddProjectMarker2 failed: " .. tostring(result)
      if cleanup_reason then failure = failure .. "; cleanup failed: " .. cleanup_reason end
      return nil, "failed to create Region " .. plan_index .. ": " .. failure
    end
    created[#created + 1] = { index = region_index }
  end
  return created
end

return M