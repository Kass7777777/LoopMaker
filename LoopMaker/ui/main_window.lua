local ui_model = require("ui.model")
local theme = require("ui.theme")

local M = {}

local function enum(api, name)
  local fn = api["ImGui_" .. name]
  return type(fn) == "function" and fn() or 0
end

local function available(api, ctx)
  if api.ImGui_GetContentRegionAvail then return api.ImGui_GetContentRegionAvail(ctx) end
  return 420, 500
end

local function width(api, ctx, value)
  if api.ImGui_SetNextItemWidth then api.ImGui_SetNextItemWidth(ctx, value) end
end

local function field_width(api, ctx)
  width(api, ctx, math.max(60, available(api, ctx) - theme.font_size(api, ctx) * 12))
end

local function hint(api, ctx, message)
  if api.ImGui_IsItemHovered and api.ImGui_SetTooltip and api.ImGui_IsItemHovered(ctx) then
    api.ImGui_SetTooltip(ctx, message)
  end
end

local function muted(api, ctx, text)
  theme.scope(api, ctx, { Text = theme.colors.TextDisabled }, nil, function()
    api.ImGui_TextWrapped(ctx, text)
  end)
end

local function disabled_scope(api, ctx, disabled, callback)
  local supported = api.ImGui_BeginDisabled and api.ImGui_EndDisabled
  if supported then api.ImGui_BeginDisabled(ctx, disabled) end
  local result = table.pack(xpcall(callback, debug.traceback))
  if supported then api.ImGui_EndDisabled(ctx) end
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
end

local function set_value(app, key, changed, value, now)
  if changed then return app:set_setting(key, value, now) end
  return false
end

local function checkbox(api, ctx, app, label, key, now)
  local changed, value = api.ImGui_Checkbox(ctx, label, app.model.settings[key])
  return set_value(app, key, changed, value, now)
end

local function input_int(api, ctx, app, label, key, minimum, maximum, now)
  local changed, value = api.ImGui_InputInt(ctx, label, app.model.settings[key], 1, 10)
  if changed then value = math.max(minimum, math.min(maximum, value)) end
  return set_value(app, key, changed, value, now)
end

local function drag(api, ctx, app, label, key, speed, minimum, maximum, format, now)
  field_width(api, ctx)
  local changed, value = api.ImGui_DragDouble(ctx, label, app.model.settings[key],
    speed, minimum, maximum, format, enum(api, "SliderFlags_AlwaysClamp"))
  if changed then value = math.max(minimum, math.min(maximum, value)) end
  return set_value(app, key, changed, value, now)
end

local function input_text(api, ctx, app, label, key, now)
  field_width(api, ctx)
  local changed, value = api.ImGui_InputText(ctx, label, app.model.settings[key])
  return set_value(app, key, changed, value, now)
end

local function section(api, ctx, title, initially_open)
  return api.ImGui_CollapsingHeader(ctx, title,
    initially_open and enum(api, "TreeNodeFlags_DefaultOpen") or 0)
end

local function draw_presets(api, ctx, app, ui, callbacks)
  local u = theme.font_size(api, ctx)
  width(api, ctx, math.max(80, available(api, ctx) - u * 7.5))
  local preview = ui.selected_preset or "Default"
  if api.ImGui_BeginCombo(ctx, "##Preset", preview) then
    if api.ImGui_Selectable(ctx, "Default", preview == "Default") then
      local loaded = not callbacks.load_default or callbacks.load_default()
      if loaded then ui.selected_preset = "Default" end
    end
    for _, name in ipairs(ui.preset_names or {}) do
      local selected = name == preview
      if api.ImGui_Selectable(ctx, name, selected) then
        local loaded = not callbacks.load_preset or callbacks.load_preset(name)
        if loaded then ui.selected_preset = name end
      end
      if selected and api.ImGui_SetItemDefaultFocus then api.ImGui_SetItemDefaultFocus(ctx) end
    end
    api.ImGui_EndCombo(ctx)
  end
  hint(api, ctx, "Load a saved preset.")
  api.ImGui_SameLine(ctx)
  if api.ImGui_Button(ctx, "Manage", -1, 0) then ui.manage_presets = not ui.manage_presets end
  hint(api, ctx, "Show or hide preset save and delete controls.")
  if not ui.manage_presets then return end
  field_width(api, ctx)
  local _, name = api.ImGui_InputText(ctx, "Preset name", ui.preset_name or "")
  ui.preset_name = name
  if api.ImGui_Button(ctx, "Save / overwrite") and callbacks.save_preset then
    callbacks.save_preset(ui.preset_name)
  end
  api.ImGui_SameLine(ctx)
  local can_delete = ui.selected_preset and ui.selected_preset ~= "Default"
  disabled_scope(api, ctx, not can_delete, function()
    if api.ImGui_Button(ctx, "Delete") and can_delete and callbacks.delete_preset then
      callbacks.delete_preset(ui.selected_preset)
    end
  end)
end

local function draw_loops(api, ctx, app, ui, now)
  local u = theme.font_size(api, ctx)
  api.ImGui_Text(ctx, "Loops")
  api.ImGui_SameLine(ctx)
  local count = app.model.selected_audio_count or 0
  muted(api, ctx, app.model.settings.shepard and "Shepard layers"
    or tostring(count) .. " selected · unique variations per item")
  local maximum = app.model.settings.shepard and 6 or 1000
  -- A short quick range gives useful precision; the adjacent input retains 1..1000.
  ui.quick_loop_max = math.min(maximum, math.max(32, ui.quick_loop_max or 32, app.model.settings.loops))
  local quick_max = ui.quick_loop_max
  width(api, ctx, math.max(80, available(api, ctx) - u * 7.6))
  local changed, value = api.ImGui_SliderInt(ctx, "##Loops", app.model.settings.loops,
    1, quick_max, "%d", enum(api, "SliderFlags_AlwaysClamp"))
  if changed then value = math.max(1, math.min(maximum, value)) end
  set_value(app, "loops", changed, value, now)
  hint(api, ctx, "Drag for quick changes. Use the number field for the full range.")
  api.ImGui_SameLine(ctx)
  width(api, ctx, -1)
  input_int(api, ctx, app, "##LoopsExact", "loops", 1, maximum, now)
  hint(api, ctx, "Exact loop count: 1-" .. maximum .. ".")
end

local function transport_active(app)
  if not app.api then return false end
  local fn = app.api.GetPlayStateEx or app.api.GetPlayState
  if not fn then return false end
  local ok, value = pcall(fn, app.project or 0)
  return not ok or type(value) ~= "number" or value ~= 0
end

local function actions_enabled(app)
  local ready = not app.model.dirty and not transport_active(app)
  return ready and app.has_preview == true and #(app.outputs or {}) > 0
    and ui_model.can_apply(app.model), ready and app:can_apply()
end

local function draw_actions(api, ctx, app)
  local can_preview, can_apply = actions_enabled(app)
  local u, total = theme.font_size(api, ctx), available(api, ctx)
  local small, gap, height = total * 0.27, u * 0.6, u * 2.75
  local action
  if api.ImGui_Button(ctx, "Cancel", small, height) then action = "cancel" end
  hint(api, ctx, "Esc: restore the project to its starting state.")
  api.ImGui_SameLine(ctx)
  disabled_scope(api, ctx, not can_preview, function()
    if api.ImGui_Button(ctx, "Preview", small, height) and can_preview then action = "preview" end
  end)
  api.ImGui_SameLine(ctx)
  theme.scope(api, ctx, theme.primary, nil, function()
    disabled_scope(api, ctx, not can_apply, function()
      if api.ImGui_Button(ctx, "Apply", math.max(60, total - small * 2 - gap * 2), height)
          and can_apply then action = "apply" end
    end)
  end)
  muted(api, ctx, "Space  Preview     Enter  Apply     Esc  Cancel")
  return action
end

local function draw_status(api, ctx, app)
  if app.model.error then
    theme.scope(api, ctx, { Text = 0xF3A799FF }, nil, function()
      api.ImGui_TextWrapped(ctx, "Error: " .. app.model.error)
    end)
  end
  if transport_active(app) then
    api.ImGui_TextWrapped(ctx, "Stop playback in REAPER to update or finish.")
  elseif app.model.dirty then
    muted(api, ctx, "Updating preview...")
  elseif not app.model.error then
    muted(api, ctx, app.model.status or "Ready")
  end
  local fill = ui_model.fill_summary(app.model)
  if fill then muted(api, ctx, "Filling time selection · " .. fill.slot_count .. " slots") end
  local count = #(app.model.warnings or {})
  if count > 0 then
    theme.scope(api, ctx, { Text = 0xE4BF7BFF }, nil, function()
      api.ImGui_Text(ctx, count .. (count == 1 and " warning" or " warnings") .. " - see details below")
    end)
  end
end

local function draw_position(api, ctx, app, now)
  if not section(api, ctx, "Position", true) then return end
  local fill = ui_model.fill_summary(app.model)
  if fill then
    api.ImGui_Text(ctx, "Fill time selection")
    api.ImGui_TextWrapped(ctx, string.format(
      "%d unique variations · %d timeline slots · %d samples each",
      fill.variation_count, fill.slot_count, fill.slot_samples))
    muted(api, ctx, string.format("%.3f s per slot · %.3f s total",
      fill.slot_length, fill["end"] - fill.start))
  end
  if fill and not (api.ImGui_BeginDisabled and api.ImGui_EndDisabled) then
    api.ImGui_Text(ctx, "Position space (s): 0.000 (disabled while filling)")
  else
    disabled_scope(api, ctx, fill ~= nil, function()
      field_width(api, ctx)
      local changed, value = api.ImGui_DragDouble(ctx, "Position space (s)",
        fill and 0 or app.model.settings.position_space, 0.01, 0, 60, "%.3f s",
        enum(api, "SliderFlags_AlwaysClamp"))
      if not fill then set_value(app, "position_space", changed, math.max(0, math.min(60, value)), now) end
    end)
  end
  if fill then muted(api, ctx, "Spacing is 0 while filling. Your saved spacing is kept.") end
  checkbox(api, ctx, app, "Shuffle variation positions", "shuffle", now)
  checkbox(api, ctx, app, "Snap boundaries to seconds", "second_snap", now)
  hint(api, ctx, "Snap source boundaries to whole seconds. This may limit valid loop lengths.")
  checkbox(api, ctx, app, "Match overlapping item lengths", "match_overlap", now)
  hint(api, ctx, "Match available loop lengths for overlapping items on different tracks.")

end

local function draw_crossfade(api, ctx, app, now)
  if not section(api, ctx, "Crossfade", true) then return end
  if app.model.settings.shepard then
    muted(api, ctx, "Crossfade controls apply to ordinary loops.")
    return
  end
  field_width(api, ctx)
  local changed, percent = api.ImGui_SliderDouble(ctx, "Length (%)",
    app.model.settings.cf_ratio * 100, 0, 50, "%.1f%%", enum(api, "SliderFlags_AlwaysClamp"))
  set_value(app, "cf_ratio", changed, math.max(0, math.min(50, percent)) / 100, now)
  hint(api, ctx, "Crossfade length as a percentage of loop length. Ctrl+click to type.")
  field_width(api, ctx)
  local curves = { "Linear (0)", "REAPER curve 1", "REAPER curve 2", "REAPER curve 3", "REAPER curve 4" }
  if api.ImGui_BeginCombo(ctx, "Curve", curves[app.model.settings.cf_curve + 1]) then
    for index, label in ipairs(curves) do
      if api.ImGui_Selectable(ctx, label, app.model.settings.cf_curve == index - 1) then
        app:set_setting("cf_curve", index - 1, now)
      end
    end
    api.ImGui_EndCombo(ctx)
  end
  drag(api, ctx, app, "Max length (s)", "cf_max", 0.01, 0, 60,
    app.model.settings.cf_max == 0 and "No limit" or "%.3f s", now)
  hint(api, ctx, "0 means no additional limit. Ctrl+click to type seconds.")
end

local function draw_zero_crossing(api, ctx, app, ui, now)
  if not section(api, ctx, "Zero-Crossing", app.model.settings.show_zc) then return end
  if app.model.settings.shepard then
    muted(api, ctx, "Zero-crossing controls apply to ordinary loops.")
    return
  end
  drag(api, ctx, app, "Search offset (s)", "offset", 0.001, -60, 60, "%.4f s", now)
  hint(api, ctx, "Move the search center in seconds; 0 uses the planned loop boundary.")
  local rows = app.model.zero_crossings or {}
  if #rows == 0 then muted(api, ctx, "No analyzed boundaries") return end
  muted(api, ctx, #rows .. " analyzed boundaries")
  local limit = math.min(#rows, ui.boundary_limit)
  for index = 1, limit do
    local row = rows[index]
    local start_text = type(row.start_time) == "number" and string.format("%.4f", row.start_time) or "-"
    local end_text = type(row.end_time) == "number" and string.format("%.4f", row.end_time) or "-"
    api.ImGui_TextWrapped(ctx, string.format("%s  #%d  %s - %s s",
      tostring(row.name), (row.variation or 0) + 1, start_text, end_text))
  end
  if #rows > limit and api.ImGui_Button(ctx, "Show more boundaries") then
    ui.boundary_limit = ui.boundary_limit + 20
  end
end

local function draw_name(api, ctx, app, now)
  if not section(api, ctx, "Name", app.model.settings.show_name) then return end
  checkbox(api, ctx, app, "Color items", "color_items", now)
  api.ImGui_SameLine(ctx)
  checkbox(api, ctx, app, "Remove extensions", "remove_ext", now)
  input_text(api, ctx, app, "Prefix", "prefix", now)
  input_text(api, ctx, app, "Suffix", "suffix", now)
  input_text(api, ctx, app, "Separator", "separator", now)
  checkbox(api, ctx, app, "Add number", "number", now)
  if app.model.settings.number then
    field_width(api, ctx)
    input_int(api, ctx, app, "Starting number", "start_number", 0, 999999, now)
    field_width(api, ctx)
    input_int(api, ctx, app, "Leading zeros", "leading_zeros", 0, 12, now)
  end
end

local function draw_parameters(api, ctx, app, ui, now)
  local warnings = app.model.warnings or {}
  if #warnings > 0 and section(api, ctx, "Warnings (" .. #warnings .. ")", false) then
    for _, warning in ipairs(warnings) do api.ImGui_BulletText(ctx, warning) end
  end
  draw_position(api, ctx, app, now)
  draw_crossfade(api, ctx, app, now)
  draw_zero_crossing(api, ctx, app, ui, now)
  draw_name(api, ctx, app, now)
  if app.model.settings.shepard and not ui.was_shepard and api.ImGui_SetNextItemOpen then
    api.ImGui_SetNextItemOpen(ctx, true)
  end
  ui.was_shepard = app.model.settings.shepard
  if section(api, ctx, "Shepard Tone (experimental)", app.model.settings.shepard) then
    checkbox(api, ctx, app, "Enable Shepard Tone", "shepard", now)
    if app.model.settings.shepard then
      drag(api, ctx, app, "Pitch (semitones)", "pitch", 0.25, -96, 96, "%.2f", now)
      muted(api, ctx, "Layers = 2 ^ Loops, up to 64. Whole octaves loop most cleanly.")
    else
      muted(api, ctx, "Experimental pitch effect. Leave off for ordinary loops.")
    end
  end
end

local function keyboard_action(api, ctx)
  if api.ImGui_IsWindowFocused
      and not api.ImGui_IsWindowFocused(ctx, enum(api, "FocusedFlags_RootAndChildWindows")) then return end
  if api.ImGui_IsAnyItemActive and api.ImGui_IsAnyItemActive(ctx) then return end
  for _, binding in ipairs({ { "Escape", "cancel" }, { "Enter", "apply" },
      { "KeypadEnter", "apply" }, { "Space", "preview" } }) do
    local key = api["ImGui_Key_" .. binding[1]]
    if key and api.ImGui_IsKeyPressed(ctx, key(), false) then return binding[2] end
  end
end

function M.new_state(preset_names)
  return { preset_names = type(preset_names) == "table" and preset_names or {},
    selected_preset = "Default", preset_name = "", manage_presets = false,
    boundary_limit = 20, was_shepard = false }
end

function M.draw(api, ctx, app, ui, callbacks, now)
  callbacks = callbacks or {}
  return theme.window(api, ctx, function()
    local u = theme.font_size(api, ctx)
    if api.ImGui_SetNextWindowSize then
      api.ImGui_SetNextWindowSize(ctx, u * 34, u * 53, enum(api, "Cond_FirstUseEver"))
    end
    if api.ImGui_SetNextWindowSizeConstraints then
      api.ImGui_SetNextWindowSizeConstraints(ctx, u * 31, u * 34, 10000, 10000)
    end
    local visible, open = api.ImGui_Begin(ctx, "LoopMaker", true)
    if not visible then return open, not open and "cancel" or nil end
    local action
    local ok, reason = xpcall(function()
      local top_width = available(api, ctx)
      if api.ImGui_AlignTextToFramePadding then api.ImGui_AlignTextToFramePadding(ctx) end
      api.ImGui_Text(ctx, "LOOPMAKER")
      api.ImGui_SameLine(ctx, math.max(u * 7, top_width - u * 23))
      checkbox(api, ctx, app, "Create regions on Apply", "create_regions", now)
      hint(api, ctx, "One Region per loop slot. Tracks with the same start and end share a Region.")
      api.ImGui_SameLine(ctx)
      checkbox(api, ctx, app, "Glue on Apply", "glue", now)
      hint(api, ctx, "Create one glued item per output when you apply.")
      draw_presets(api, ctx, app, ui, callbacks)
      draw_loops(api, ctx, app, ui, now)
      action = draw_actions(api, ctx, app)
      draw_status(api, ctx, app)
      api.ImGui_Separator(ctx)
      -- ReaImGui automatically ends invisible children; only end a visible child.
      local child = api.ImGui_BeginChild and api.ImGui_EndChild
      local child_visible = not child or api.ImGui_BeginChild(ctx, "##Parameters", 0, 0)
      if child_visible then
        local drawn, draw_reason = xpcall(function()
          draw_parameters(api, ctx, app, ui, now)
        end, debug.traceback)
        if child then api.ImGui_EndChild(ctx) end
        if not drawn then error(draw_reason, 0) end
      end
      action = ui_model.allowed_action(app.model, action or keyboard_action(api, ctx))
      local can_preview, can_apply = actions_enabled(app)
      if (action == "preview" and not can_preview) or (action == "apply" and not can_apply) then action = nil end
    end, debug.traceback)
    api.ImGui_End(ctx)
    if not ok then error(reason, 0) end
    if not open then action = "cancel" end
    return open, action
  end)
end

return M
