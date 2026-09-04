local settings = require("lib.settings")

local M = {}

local SECTION = "Sol_LoopMaker"
local INDEX_KEY = "preset_names"
local PRESET_PREFIX = "preset:"
local MAX_NAME_LENGTH = 64

local function sorted_setting_keys()
  local keys = {}
  for key in pairs(settings.defaults()) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local SETTING_KEYS = sorted_setting_keys()
local DEFAULTS = settings.defaults()

local function encode_setting_string(value)
  local encoded = {}
  for index = 1, #value do
    encoded[index] = string.format("%%%02X", value:byte(index))
  end
  return table.concat(encoded)
end

local function decode_setting_string(value)
  if #value % 3 ~= 0 then
    return nil
  end

  local decoded = {}
  local decoded_index = 1
  for index = 1, #value, 3 do
    if value:sub(index, index) ~= "%" then
      return nil
    end
    local hexadecimal = value:sub(index + 1, index + 2)
    if not hexadecimal:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then
      return nil
    end
    decoded[decoded_index] = string.char(tonumber(hexadecimal, 16))
    decoded_index = decoded_index + 1
  end
  return table.concat(decoded)
end

local function is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function encode_setting_value(value)
  local value_type = type(value)
  if value_type == "boolean" then
    return "boolean:" .. tostring(value)
  end
  if value_type == "number" then
    return "number:" .. string.format("%.17g", value)
  end
  return "string:" .. encode_setting_string(value)
end

local function decode_setting_value(encoded, expected_type)
  local value_type, value = encoded:match("^(%a+):(.*)$")
  if value_type ~= expected_type then
    return nil, false
  end

  if value_type == "boolean" then
    if value == "true" then
      return true, true
    end
    if value == "false" then
      return false, true
    end
    return nil, false
  end

  if value_type == "number" then
    local number = tonumber(value)
    if not is_finite_number(number) then
      return nil, false
    end
    return number, true
  end

  if value_type == "string" then
    local decoded = decode_setting_string(value)
    return decoded, decoded ~= nil
  end

  return nil, false
end

function M.encode_settings(input)
  local sanitized = settings.sanitize(input)
  local lines = {}
  for _, key in ipairs(SETTING_KEYS) do
    lines[#lines + 1] = key .. "=" .. encode_setting_value(sanitized[key])
  end
  return table.concat(lines, ";")
end

function M.decode_settings(text)
  local decoded = {}
  local warnings = {}
  if type(text) == "string" and text ~= "" then
    for token in (text .. ";"):gmatch("(.-);") do
      local key, encoded = token:match("^([^=;]+)=(.*)$")
      if not key then
        warnings[#warnings + 1] = "damaged settings token ignored"
      else
        local default = DEFAULTS[key]
        if default ~= nil then
          local value, valid = decode_setting_value(encoded, type(default))
          if valid then
            decoded[key] = value
          else
            warnings[#warnings + 1] = "damaged setting ignored: " .. key
          end
        end
      end
    end
  elseif type(text) ~= "string" then
    warnings[#warnings + 1] = "settings text must be a string"
  end
  return settings.sanitize(decoded), warnings
end

local function validate_name(name)
  if type(name) ~= "string" then
    return nil, "preset name must be a string"
  end
  -- Only ASCII space, tab, CR, and LF define a blank name. Unicode whitespace is allowed.
  if name == "" or name:match("^[ \t\r\n]*$") then
    return nil, "preset name must not be empty or ASCII-whitespace-only"
  end

  local valid_utf8, length_or_error = pcall(function()
    local length = 0
    for _, codepoint in utf8.codes(name) do
      if (codepoint >= 0xD800 and codepoint <= 0xDFFF) or codepoint > 0x10FFFF then
        error("invalid Unicode scalar")
      end
      if codepoint <= 31 or (codepoint >= 127 and codepoint <= 159) then
        error("control character")
      end
      length = length + 1
    end
    return length
  end)

  if not valid_utf8 then
    local validation_error = tostring(length_or_error)
    if validation_error:find("control character", 1, true) then
      return nil, "preset name must not contain control characters"
    end
    if validation_error:find("invalid Unicode scalar", 1, true) then
      return nil, "preset name must contain only Unicode scalar values"
    end
    return nil, "preset name must be valid UTF-8"
  end
  if length_or_error > MAX_NAME_LENGTH then
    return nil, "preset name must be at most 64 Unicode codepoints"
  end

  return name
end

local function percent_encode(value)
  return (value:gsub(".", function(character)
    if character:match("[A-Za-z0-9%-%._~]") then
      return character
    end
    return string.format("%%%02X", string.byte(character))
  end))
end

local function normalized_names(names)
  local unique = {}
  local result = {}
  if type(names) ~= "table" then
    return result
  end

  for _, name in ipairs(names) do
    local valid_name = validate_name(name)
    if valid_name and not unique[valid_name] then
      unique[valid_name] = true
      result[#result + 1] = valid_name
    end
  end
  table.sort(result)
  return result
end

function M.encode_names(names)
  local encoded = {}
  for _, name in ipairs(normalized_names(names)) do
    encoded[#encoded + 1] = encode_setting_string(name)
  end
  return table.concat(encoded, ";")
end

function M.decode_names(text)
  local names = {}
  local warnings = {}
  local unique = {}
  if type(text) ~= "string" then
    warnings[#warnings + 1] = "preset names text must be a string"
    return names, warnings
  end
  if text == "" then
    return names, warnings
  end

  for token in (text .. ";"):gmatch("(.-);") do
    local decoded = decode_setting_string(token)
    if not decoded then
      warnings[#warnings + 1] = "damaged preset name encoding ignored"
    else
      local valid_name, reason = validate_name(decoded)
      if not valid_name then
        warnings[#warnings + 1] = "invalid preset name ignored: " .. reason
      elseif not unique[valid_name] then
        unique[valid_name] = true
        names[#names + 1] = valid_name
      end
    end
  end
  table.sort(names)
  return names, warnings
end

function M.preset_key(name)
  local valid_name, reason = validate_name(name)
  if not valid_name then
    return nil, reason
  end
  return PRESET_PREFIX .. percent_encode(valid_name)
end

local function require_api(reaper_api, method)
  if type(reaper_api) ~= "table" or type(reaper_api[method]) ~= "function" then
    return nil, "missing REAPER API " .. method
  end
  return reaper_api[method]
end

local function call_api(reaper_api, method, ...)
  local callback, missing_reason = require_api(reaper_api, method)
  if not callback then
    return nil, missing_reason
  end

  local ok, result = pcall(callback, ...)
  if not ok then
    return nil, method .. " failed: " .. tostring(result)
  end
  if result == false then
    return nil, method .. " returned false"
  end
  return result
end

local function get_ext_state(reaper_api, key)
  local value, reason = call_api(reaper_api, "GetExtState", SECTION, key)
  if reason then
    return nil, reason
  end
  if type(value) ~= "string" then
    return nil, "GetExtState returned a non-string value"
  end
  return value
end

local function set_ext_state(reaper_api, key, value, persist)
  local _, reason = call_api(
    reaper_api, "SetExtState", SECTION, key, value, persist ~= false)
  if reason then
    return nil, reason
  end
  return true
end

function M.list(reaper_api)
  local text, reason = get_ext_state(reaper_api, INDEX_KEY)
  if not text then
    return {}, reason, {}
  end
  local names, warnings = M.decode_names(text)
  return names, nil, warnings
end

function M.load(reaper_api, name)
  local key, name_reason = M.preset_key(name)
  if not key then
    return nil, name_reason, {}
  end

  local text, reason = get_ext_state(reaper_api, key)
  if not text then
    return nil, reason, {}
  end
  if text == "" then
    return nil, "preset not found: " .. name, {}
  end
  local decoded, warnings = M.decode_settings(text)
  return decoded, nil, warnings
end

function M.save(reaper_api, name, settings_table, persist)
  local key, name_reason = M.preset_key(name)
  if not key then
    return nil, name_reason
  end

  local _, get_api_reason = require_api(reaper_api, "GetExtState")
  if get_api_reason then
    return nil, get_api_reason
  end
  local _, set_api_reason = require_api(reaper_api, "SetExtState")
  if set_api_reason then
    return nil, set_api_reason
  end

  local index_text, index_reason = get_ext_state(reaper_api, INDEX_KEY)
  if not index_text then
    return nil, index_reason
  end
  local names, warnings = M.decode_names(index_text)
  names[#names + 1] = name
  local encoded_index = M.encode_names(names)

  local written, write_reason = set_ext_state(
    reaper_api, key, M.encode_settings(settings_table), persist)
  if not written then
    return nil, write_reason, warnings
  end

  local indexed, index_write_reason = set_ext_state(
    reaper_api, INDEX_KEY, encoded_index, persist)
  if not indexed then
    return nil,
      "partial save: preset was written but index update failed: " .. index_write_reason,
      warnings
  end

  return true, nil, warnings
end

function M.delete(reaper_api, name, persist)
  local key, name_reason = M.preset_key(name)
  if not key then
    return nil, name_reason
  end

  local _, get_api_reason = require_api(reaper_api, "GetExtState")
  if get_api_reason then
    return nil, get_api_reason
  end
  local _, delete_api_reason = require_api(reaper_api, "DeleteExtState")
  if delete_api_reason then
    return nil, delete_api_reason
  end
  local _, set_api_reason = require_api(reaper_api, "SetExtState")
  if set_api_reason then
    return nil, set_api_reason
  end

  local index_text, index_reason = get_ext_state(reaper_api, INDEX_KEY)
  if not index_text then
    return nil, index_reason
  end
  local indexed_names, warnings = M.decode_names(index_text)
  local remaining = {}
  for _, existing_name in ipairs(indexed_names) do
    if existing_name ~= name then
      remaining[#remaining + 1] = existing_name
    end
  end

  local _, delete_reason = call_api(
    reaper_api, "DeleteExtState", SECTION, key, persist ~= false)
  if delete_reason then
    return nil, delete_reason, warnings
  end

  local indexed, index_write_reason = set_ext_state(
    reaper_api, INDEX_KEY, M.encode_names(remaining), persist)
  if not indexed then
    return nil,
      "partial delete: preset was deleted but index update failed: " .. index_write_reason,
      warnings
  end

  return true, nil, warnings
end

return M
