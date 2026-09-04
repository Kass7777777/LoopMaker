local core = require("lib.core")
local settings_module = require("lib.settings")

local M = {}

local PRESENTATION_KEYS = {
  glue = true,
  show_shepard = true,
  show_zc = true,
  show_name = true,
  preset = true,
}

local function enforce_panel_exclusion(values, preferred_key)
  if not values.show_shepard or not values.show_zc then
    return
  end
  if preferred_key == "show_zc" then
    values.show_shepard = false
  else
    values.show_zc = false
  end
end

local function enforce_shepard_limit(values)
  if values.shepard and values.loops > 6 then
    values.loops = 6
  end
end

function M.new(input_settings)
  local values = settings_module.sanitize(input_settings)
  enforce_panel_exclusion(values, "show_shepard")
  enforce_shepard_limit(values)
  return {
    settings = values,
    dirty = false,
    selected_audio_count = 0,
    timeline_fill = nil,
    error = nil,
    warnings = {},
    status = "Ready",
  }
end

function M.set(model, key, value)
  if type(model) ~= "table" or type(model.settings) ~= "table" then
    return nil, "model is invalid"
  end
  local defaults = settings_module.defaults()
  if defaults[key] == nil then
    return nil, "unknown setting: " .. tostring(key)
  end

  local candidate = core.deep_copy(model.settings)
  candidate[key] = value
  candidate = settings_module.sanitize(candidate)
  enforce_panel_exclusion(candidate, key)
  enforce_shepard_limit(candidate)

  local changed = false
  for setting_key in pairs(defaults) do
    if model.settings[setting_key] ~= candidate[setting_key] then
      changed = true
      if not PRESENTATION_KEYS[setting_key] then
        model.dirty = true
      end
    end
  end
  model.settings = candidate
  return changed
end

function M.replace_settings(model, input_settings)
  if type(model) ~= "table" then
    return nil, "model is invalid"
  end
  local values = settings_module.sanitize(input_settings)
  enforce_panel_exclusion(values, "show_shepard")
  enforce_shepard_limit(values)
  local defaults = settings_module.defaults()
  local result_changed = false
  for key in pairs(defaults) do
    if not PRESENTATION_KEYS[key] and model.settings[key] ~= values[key] then
      result_changed = true
      break
    end
  end
  model.settings = values
  model.dirty = model.dirty or result_changed
  return true
end

function M.mark_clean(model)
  if type(model) ~= "table" then
    return nil, "model is invalid"
  end
  model.dirty = false
  return true
end

function M.set_selected_count(model, count)
  if type(model) ~= "table" then
    return nil, "model is invalid"
  end
  if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
    return nil, "selected audio count must be a non-negative integer"
  end
  model.selected_audio_count = count
  return true
end

function M.set_error(model, message)
  if type(model) ~= "table" then
    return nil, "model is invalid"
  end
  if message ~= nil and type(message) ~= "string" then
    return nil, "error must be a string or nil"
  end
  model.error = message
  return true
end

local MAX_SAFE_INTEGER = 9007199254740991

local function safe_positive_integer(value)
  if not core.is_finite_number(value) then return nil end
  local integer = math.tointeger(value)
  if integer == nil or integer <= 0 or integer > MAX_SAFE_INTEGER then
    return nil
  end
  return integer
end

function M.fill_summary(model)
  if type(model) ~= "table" or type(model.timeline_fill) ~= "table" then
    return nil
  end
  local summary = model.timeline_fill
  local variation_count = safe_positive_integer(summary.variation_count)
  local source_count = safe_positive_integer(summary.source_count)
  local slot_count = safe_positive_integer(summary.slot_count)
  local slot_samples = safe_positive_integer(summary.slot_samples)
  if variation_count == nil
      or source_count == nil
      or slot_count == nil
      or slot_samples == nil
      or not core.is_finite_number(summary.slot_length)
      or summary.slot_length <= 0
      or not core.is_finite_number(summary.start)
      or not core.is_finite_number(summary["end"])
      or summary["end"] <= summary.start then
    return nil
  end
  local duration = summary["end"] - summary.start
  local covered = slot_count * summary.slot_length
  local tolerance = 1e-9 * math.max(1, math.abs(duration))
  if math.abs(covered - duration) > tolerance then return nil end

  local normalized = {}
  for key, value in pairs(summary) do normalized[key] = value end
  normalized.variation_count = variation_count
  normalized.source_count = source_count
  normalized.slot_count = slot_count
  normalized.slot_samples = slot_samples
  return normalized
end

function M.can_apply(model)
  return type(model) == "table"
    and type(model.selected_audio_count) == "number"
    and model.selected_audio_count > 0
    and model.error == nil
end

function M.action_for_key(key)
  if key == "enter" or key == "keypad_enter" then
    return "apply"
  end
  if key == "space" then
    return "preview"
  end
  if key == "escape" then
    return "cancel"
  end
  return nil
end

function M.allowed_action(model, action)
  if action == "apply" and not M.can_apply(model) then
    return nil
  end
  return action
end

return M
