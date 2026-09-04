local settings_module = require("lib.settings")
local core = require("lib.core")

local M = {}

local function nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function nonnegative_integer(value)
  if not core.is_finite_number(value) or value < 0 or value ~= math.floor(value) then
    return nil
  end
  return math.tointeger(value)
end

local function api_function(reaper_api, name)
  if type(reaper_api) ~= "table" or type(reaper_api[name]) ~= "function" then
    return nil
  end
  return reaper_api[name]
end

function M.remove_extension(name)
  if type(name) ~= "string" then
    return ""
  end
  return name:match("^(.+)%.[^%.]+$") or name
end

function M.build(original_name, input_settings, zero_based_index)
  local sanitized = settings_module.sanitize(input_settings)
  local original = type(original_name) == "string" and original_name or ""
  local index = nonnegative_integer(zero_based_index)
  if index == nil then
    return nil, "zero_based_index must be a non-negative integer"
  end

  if sanitized.remove_ext then
    original = M.remove_extension(original)
  end

  local components = {}
  if sanitized.prefix ~= "" then
    components[#components + 1] = sanitized.prefix
  end
  if original ~= "" then
    components[#components + 1] = original
  end
  if sanitized.number then
    local start_number = math.tointeger(sanitized.start_number) or 0
    if index > math.maxinteger - start_number then
      return nil, "number overflow"
    end
    local number_text = tostring(start_number + index)
    local padding = sanitized.leading_zeros - #number_text
    if padding > 0 then
      number_text = string.rep("0", padding) .. number_text
    end
    components[#components + 1] = number_text
  end
  if sanitized.suffix ~= "" then
    components[#components + 1] = sanitized.suffix
  end

  if #components == 0 then
    return "Loop"
  end
  return table.concat(components, sanitized.separator)
end

function M.source_name(reaper_api, take)
  local take_name_api = api_function(reaper_api, "GetSetMediaItemTakeInfo_String")
  if take_name_api then
    local ok, retval, take_name = pcall(take_name_api, take, "P_NAME", "", false)
    if ok and retval == true and nonempty_string(take_name) then
      return take_name
    end
  end

  local source_api = api_function(reaper_api, "GetMediaItemTake_Source")
  local filename_api = api_function(reaper_api, "GetMediaSourceFileName")
  if source_api and filename_api then
    local source_ok, source = pcall(source_api, take)
    if source_ok and source ~= nil then
      local filename_ok, filename = pcall(filename_api, source, "")
      if filename_ok and nonempty_string(filename) then
        local basename = filename:gsub("\\", "/"):match("([^/]+)$")
        if nonempty_string(basename) then
          return basename
        end
      end
    end
  end

  return "Item"
end

function M.apply_to_take(reaper_api, take, name)
  if not nonempty_string(name) then
    return nil, "take name must be a non-empty string"
  end

  local setter = api_function(reaper_api, "GetSetMediaItemTakeInfo_String")
  if not setter then
    return nil, "GetSetMediaItemTakeInfo_String API is unavailable"
  end

  local ok, result = pcall(setter, take, "P_NAME", name, true)
  if not ok then
    return nil, "failed to set take name: " .. tostring(result)
  end
  if result == false then
    return nil, "failed to set take name"
  end
  return true
end

function M.apply_color(reaper_api, item, color, enabled)
  if enabled ~= true then
    return true
  end

  local native_color = nonnegative_integer(color)
  if native_color == nil then
    return nil, "color must be a non-negative native integer"
  end

  local setter = api_function(reaper_api, "SetMediaItemInfo_Value")
  if not setter then
    return nil, "SetMediaItemInfo_Value API is unavailable"
  end

  local ok, result = pcall(setter, item, "I_CUSTOMCOLOR", native_color | 0x1000000)
  if not ok then
    return nil, "failed to set item color: " .. tostring(result)
  end
  if result == false then
    return nil, "failed to set item color"
  end
  return true
end

return M
