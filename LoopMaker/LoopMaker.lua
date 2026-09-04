local source = debug.getinfo(1, "S").source
local script_path = source:sub(1, 1) == "@" and source:sub(2) or source
local normalized_path = script_path:gsub("\\", "/")
local root = normalized_path:match("^(.*)/[^/]+$") or "."
local separator = package.config:sub(3, 3)
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, separator)

local app_module = require("lib.app")
local deferred_loop = require("lib.deferred_loop")
local preset_actions = require("lib.preset_actions")
local presets = require("lib.presets")
local recovery_loop = require("lib.recovery_loop")
local settings = require("lib.settings")
local main_window = require("ui.main_window")

local function show_error(message)
  if type(reaper.ShowMessageBox) == "function" then
    reaper.ShowMessageBox(tostring(message), "LoopMaker", 0)
  elseif type(reaper.ShowConsoleMsg) == "function" then
    reaper.ShowConsoleMsg("LoopMaker: " .. tostring(message) .. "\n")
  end
end

if type(reaper) ~= "table" or type(reaper.ImGui_CreateContext) ~= "function" then
  show_error("ReaImGui is required. Install it through ReaPack, restart REAPER, and run LoopMaker again.")
  return
end

local function native_color()
  if type(reaper.ColorToNative) ~= "function" then return 0 end
  local ok, value = pcall(reaper.ColorToNative, 63, 143, 191)
  if ok and type(value) == "number" and value >= 0 then return value end
  return 0
end

local app = app_module.new(reaper, {
  project = 0,
  color = native_color(),
  debounce_seconds = 0.15,
})
local started, start_reason = app:start()
if not started then
  show_error(start_reason)
  return
end

local preset_names, preset_reason, preset_warnings = presets.list(reaper)
if preset_reason then preset_names = {} end
local ui = main_window.new_state(preset_names)
for _, warning in ipairs(preset_warnings or {}) do
  app.model.warnings[#app.model.warnings + 1] = warning
end
if preset_reason then
  app.model.warnings[#app.model.warnings + 1] = preset_reason
end

local ctx = reaper.ImGui_CreateContext("LoopMaker")
local finished = false
local recovery_pending
local deferred_step

local function refresh_presets()
  local names, reason, warnings = presets.list(reaper)
  if reason then
    app.model.error = reason
    return nil
  end
  ui.preset_names = names
  for _, warning in ipairs(warnings or {}) do
    app.model.warnings[#app.model.warnings + 1] = warning
  end
  return true
end

local function current_time()
  if type(reaper.time_precise) == "function" then return reaper.time_precise() end
  return os.clock()
end

local callbacks = {}

function callbacks.load_default()
  local replaced, reason = app:replace_settings(
    settings.defaults(), current_time())
  if not replaced then
    app.model.error = reason
    return nil
  end
  ui.selected_preset = "Default"
  ui.preset_name = ""
  app.model.error = nil
  return true
end

function callbacks.load_preset(name)
  return preset_actions.load(
    presets, reaper, app, ui, name, current_time())
end

function callbacks.save_preset(name)
  local saved, reason, warnings = presets.save(
    reaper, name, app.model.settings, true)
  if not saved then
    app.model.error = reason
    return nil
  end
  local changed, setting_reason = app:set_setting(
    "preset", name, current_time())
  if changed == nil then
    app.model.error = setting_reason
    return nil
  end
  ui.selected_preset = name
  app.model.error = nil
  app.model.warnings = warnings or {}
  local refreshed = refresh_presets()
  return refreshed == true
end

function callbacks.delete_preset(name)
  local deleted, reason, warnings = presets.delete(reaper, name, true)
  if not deleted then
    app.model.error = reason
    return nil
  end
  app.model.warnings = warnings or {}
  local loaded = callbacks.load_default()
  if not loaded then return nil end
  local refreshed = refresh_presets()
  return refreshed == true
end

local function finish(action)
  if finished then return end
  local ok, reason
  if action == "apply" then
    ok, reason = app:apply()
  else
    ok, reason = app:cancel()
  end
  if not ok then
    show_error(reason)
    return
  end
  finished = true
end

local function frame()
  if finished then return false end
  if recovery_pending ~= nil then
    local result = recovery_pending:step(function()
      return app:cancel()
    end)
    if result.notice then show_error(result.notice) end
    if result.finished then
      finished = true
      show_error(result.message)
      return false
    end
    return true
  end

  local now = current_time()
  local rebuilt, rebuild_reason = app:tick(now)
  if rebuilt == nil then error(rebuild_reason, 0) end

  local open, action = main_window.draw(
    reaper, ctx, app, ui, callbacks, now)
  if action == "preview" then
    local ok, reason = app:toggle_preview()
    if not ok then app.model.error = reason end
  elseif action == "apply" then
    finish("apply")
  elseif action == "cancel" or not open then
    finish("cancel")
  end

  return not finished
end

local function handle_frame_error(reason)
  if finished then return end
  if recovery_pending == nil then
    recovery_pending = recovery_loop.new(reason)
  end
  if type(deferred_step) == "function" then
    reaper.defer(deferred_step)
  end
end

deferred_step = deferred_loop.create(reaper, frame, handle_frame_error)
reaper.defer(deferred_step)
