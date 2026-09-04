local helper = require("tests.test_helper")
local settings = require("lib.settings")
local main_window = require("ui.main_window")

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then return true end
  end
  return false
end

local function fake_imgui(options)
  local o = options or {}
  o.controls, o.events, o.ends = {}, {}, {}
  o.texts, o.wrapped_texts, o.bullet_texts = {}, {}, {}
  local disabled = false
  local function control(label, value, results)
    o.controls[#o.controls + 1] = { label = label, disabled = disabled, value = value }
    local result = results and results[label]
    if result ~= nil then return true, result end
    return false, value
  end
  local api = {
    ImGui_Begin = function() return o.visible ~= false, o.open ~= false end,
    ImGui_End = function() o.ends[#o.ends + 1] = "window" end,
    ImGui_BeginChild = function()
      o.events[#o.events + 1] = "parameters"
      return o.child_visible ~= false
    end,
    ImGui_EndChild = function() o.ends[#o.ends + 1] = "child" end,
    ImGui_GetContentRegionAvail = function() return 420, 500 end,
    ImGui_GetFontSize = function() return 14 end,
    ImGui_SetNextItemWidth = function() end,
    ImGui_SetNextWindowSize = function() end,
    ImGui_SetNextWindowSizeConstraints = function() end,
    ImGui_Cond_FirstUseEver = function() return 4 end,
    ImGui_Cond_Once = function() return 2 end,
    ImGui_SetNextItemOpen = function() end,
    ImGui_TreeNodeFlags_DefaultOpen = function() return 32 end,
    ImGui_Text = function(_, text) o.texts[#o.texts + 1] = text end,
    ImGui_TextWrapped = function(_, text) o.wrapped_texts[#o.wrapped_texts + 1] = text end,
    ImGui_BulletText = function(_, text) o.bullet_texts[#o.bullet_texts + 1] = text end,
    ImGui_SameLine = function() end,
    ImGui_Separator = function() end,
    ImGui_Spacing = function() end,
    ImGui_BeginCombo = function(_, label)
      return o.combo_open == true or label == o.combo_label
    end,
    ImGui_EndCombo = function() end,
    ImGui_Selectable = function(_, label) return label == o.select_label end,
    ImGui_SetItemDefaultFocus = function() end,
    ImGui_InputText = function(_, label, value) return control(label, value, o.text_results) end,
    ImGui_Button = function(_, label)
      o.events[#o.events + 1] = label
      control(label)
      return label == o.click
    end,
    ImGui_BeginDisabled = function(_, value) disabled = value end,
    ImGui_EndDisabled = function() disabled = false end,
    ImGui_Checkbox = function(_, label, value) return control(label, value, o.checkbox_results) end,
    ImGui_InputInt = function(_, label, value) return control(label, value, o.int_results) end,
    ImGui_SliderInt = function(_, label, value) return control(label, value, o.slider_results) end,
    ImGui_SliderDouble = function(_, label, value) return control(label, value, o.slider_results) end,
    ImGui_DragDouble = function(_, label, value) return control(label, value, o.drag_results) end,
    ImGui_CollapsingHeader = function(_, label)
      if o.headers and o.headers[label] ~= nil then return o.headers[label] end
      return label == "Position" or label == "Crossfade" or label:match("^Warnings") ~= nil
    end,
    ImGui_FocusedFlags_RootAndChildWindows = function() return 3 end,
    ImGui_IsWindowFocused = function(_, flags) return not o.child_focused or flags == 3 end,
    ImGui_IsAnyItemActive = function() return o.active == true end,
    ImGui_Key_Escape = function() return 27 end,
    ImGui_Key_Enter = function() return 13 end,
    ImGui_Key_KeypadEnter = function() return 271 end,
    ImGui_Key_Space = function() return 32 end,
    ImGui_IsKeyPressed = function(_, key) return key == o.pressed_key end,
  }
  if o.without_begin_disabled then
    api.ImGui_BeginDisabled, api.ImGui_EndDisabled = nil, nil
  end
  return api
end

local function fake_app(can_apply)
  local app = {
    has_preview = true, outputs = { {} }, calls = {},
    model = { settings = settings.defaults(), selected_audio_count = 1,
      warnings = {}, zero_crossings = {}, status = "Ready" },
    can_apply = function() return can_apply end,
  }
  app.set_setting = function(_, key, value, now)
    app.calls[#app.calls + 1] = { key = key, value = value, now = now }
    app.model.settings[key] = value
    return true
  end
  return app
end

local function draw(options, app, ui, callbacks)
  return main_window.draw(fake_imgui(options), {}, app or fake_app(true),
    ui or main_window.new_state(), callbacks or {}, 9)
end

local function find_control(options, label)
  for _, control in ipairs(options.controls) do
    if control.label == label then return control end
  end
end

local function fill_summary()
  return { variation_count = 5, source_count = 2, slot_count = 12,
    slot_samples = 24000, slot_length = 0.5, start = 1, ["end"] = 7 }
end

helper.test("Enter uses the full Apply gate", function()
  for _, enabled in ipairs({ false, true }) do
    local _, action = draw({ pressed_key = 13 }, fake_app(enabled))
    helper.assert_equal(enabled and "apply" or nil, action)
  end
end)

helper.test("Escape cancels only when no input is active", function()
  for _, active in ipairs({ false, true }) do
    local _, action = draw({ pressed_key = 27, active = active })
    helper.assert_equal(not active and "cancel" or nil, action)
  end
end)

helper.test("Space and Enter do not trigger during input editing", function()
  for _, key in ipairs({ 32, 13, 271 }) do
    local _, action = draw({ pressed_key = key, active = true })
    helper.assert_equal(nil, action)
  end
end)

helper.test("failed preset loading preserves the selected preset", function()
  local ui = main_window.new_state({ "Broken" })
  draw({ combo_open = true, select_label = "Broken" }, fake_app(false), ui,
    { load_preset = function() return nil end })
  helper.assert_equal("Default", ui.selected_preset)
end)

helper.test("fill mode shows summary and locks spacing without overwriting its saved value", function()
  local app = fake_app(true)
  app.model.timeline_fill, app.model.settings.position_space = fill_summary(), 1.25
  local o = { drag_results = { ["Position space (s)"] = 0 } }
  draw(o, app)
  helper.assert_true(contains(o.texts, "Fill time selection"))
  helper.assert_true(contains(o.wrapped_texts,
    "5 unique variations · 12 timeline slots · 24000 samples each"))
  helper.assert_true(find_control(o, "Position space (s)").disabled)
  helper.assert_equal(1.25, app.model.settings.position_space)
  helper.assert_equal(0, #app.calls)
end)

helper.test("ordinary mode permits spacing edits", function()
  local app = fake_app(true)
  local o = { drag_results = { ["Position space (s)"] = 2.5 } }
  draw(o, app)
  helper.assert_equal(false, contains(o.texts, "Fill time selection"))
  helper.assert_equal(false, find_control(o, "Position space (s)").disabled)
  helper.assert_equal(2.5, app.model.settings.position_space)
end)

helper.test("fill spacing remains read-only on older ReaImGui", function()
  local app = fake_app(true)
  app.model.timeline_fill, app.model.settings.position_space = fill_summary(), 1.25
  local o = { without_begin_disabled = true, drag_results = { ["Position space (s)"] = 0 } }
  draw(o, app)
  helper.assert_equal(nil, find_control(o, "Position space (s)"))
  helper.assert_true(contains(o.texts, "Position space (s): 0.000 (disabled while filling)"))
  helper.assert_equal(1.25, app.model.settings.position_space)
end)

helper.test("invalid fill summaries do not disable spacing", function()
  local app = fake_app(true)
  app.model.timeline_fill = fill_summary()
  app.model.timeline_fill.variation_count = "five"
  local o = {}
  draw(o, app)
  helper.assert_equal(false, contains(o.texts, "Fill time selection"))
  helper.assert_equal(false, find_control(o, "Position space (s)").disabled)
end)

helper.test("errors remain visible and warning details are accessible", function()
  local app, o = fake_app(false), {}
  app.model.error, app.model.warnings = "preview failed", { "boundary fallback" }
  draw(o, app)
  helper.assert_true(contains(o.wrapped_texts, "Error: preview failed"))
  helper.assert_true(contains(o.bullet_texts, "boundary fallback"))
end)

helper.test("crossfade percentage converts to stored ratio and clamps manual input", function()
  for _, case in ipairs({ { 25, 0.25 }, { 85, 0.5 }, { -10, 0 } }) do
    local app = fake_app(true)
    draw({ slider_results = { ["Length (%)"] = case[1] } }, app)
    helper.assert_equal(case[2], app.model.settings.cf_ratio)
  end
end)

helper.test("unchanged percentage display preserves fractional precision", function()
  local app = fake_app(true)
  app.model.settings.cf_ratio = 0.123456
  draw({}, app)
  helper.assert_equal(0.123456, app.model.settings.cf_ratio)
end)

helper.test("Loops precise entry preserves full range and Shepard limit", function()
  for _, case in ipairs({ { false, 1000, 1000 }, { false, 2000, 1000 },
      { false, -2, 1 }, { true, 1000, 6 } }) do
    local app = fake_app(true)
    app.model.settings.shepard = case[1]
    draw({ int_results = { ["##LoopsExact"] = case[2] } }, app)
    helper.assert_equal(case[3], app.model.settings.loops)
  end
end)

helper.test("Loops slider updates the same setting", function()
  local app = fake_app(true)
  draw({ slider_results = { ["##Loops"] = 8 } }, app)
  helper.assert_equal(8, app.model.settings.loops)
end)

helper.test("actions stay outside the scrolling parameter region", function()
  local o = {}
  draw(o)
  local indices = {}
  for index, event in ipairs(o.events) do indices[event] = index end
  helper.assert_true(indices.parameters and indices.Apply and indices.Preview)
  helper.assert_true(indices.Apply < indices.parameters and indices.Preview < indices.parameters)
end)

helper.test("shortcuts include focused parameter child windows", function()
  local _, action = draw({ child_focused = true, pressed_key = 13 })
  helper.assert_equal("apply", action)
end)

helper.test("dirty preview blocks both buttons and shortcuts", function()
  for _, trigger in ipairs({ { click = "Preview" }, { pressed_key = 32 },
      { click = "Apply" }, { pressed_key = 13 } }) do
    local app = fake_app(true)
    app.model.dirty = true
    local _, action = draw(trigger, app)
    helper.assert_equal(nil, action)
  end
end)

helper.test("missing preview is blocked even without disabled-widget support", function()
  local app = fake_app(true)
  app.has_preview, app.outputs = false, {}
  local _, action = draw({ click = "Preview", without_begin_disabled = true }, app)
  helper.assert_equal(nil, action)
end)

helper.test("active transport blocks Apply and preview with a Stop instruction", function()
  for _, key in ipairs({ 32, 13 }) do
    local app, o = fake_app(true), { pressed_key = key }
    app.api = { GetPlayStateEx = function() return 1 end }
    local _, action = draw(o, app)
    helper.assert_equal(nil, action)
    helper.assert_true(contains(o.wrapped_texts, "Stop playback in REAPER to update or finish."))
  end
end)

helper.test("preset management is on demand and still saves names", function()
  local ui, o, saved = main_window.new_state(), {}, nil
  draw(o, nil, ui)
  helper.assert_equal(nil, find_control(o, "Preset name"))
  draw({ click = "Manage" }, nil, ui)
  draw({ click = "Save / overwrite", text_results = { ["Preset name"] = "Ambience" } },
    nil, ui, { save_preset = function(name) saved = name end })
  helper.assert_equal("Ambience", saved)
end)

helper.test("default preset cannot be deleted even without disabled-widget support", function()
  local ui, deleted = main_window.new_state(), false
  ui.manage_presets = true
  draw({ click = "Delete", without_begin_disabled = true }, nil, ui,
    { delete_preset = function() deleted = true end })
  helper.assert_equal(false, deleted)
end)

helper.test("render exceptions unwind child window and theme scopes", function()
  local o, colors, vars = {}, 0, 0
  local api = fake_imgui(o)
  api.ImGui_Col_WindowBg = function() return 2 end
  api.ImGui_StyleVar_FramePadding = function() return 3 end
  api.ImGui_PushStyleColor = function() colors = colors + 1 end
  api.ImGui_PopStyleColor = function(_, count) colors = colors - count end
  api.ImGui_PushStyleVar = function() vars = vars + 1 end
  api.ImGui_PopStyleVar = function(_, count) vars = vars - count end
  api.ImGui_DragDouble = function() error("render failed") end
  local ok, reason = pcall(main_window.draw, api, {}, fake_app(true), main_window.new_state(), {}, 0)
  helper.assert_equal(false, ok)
  helper.assert_true(tostring(reason):find("render failed", 1, true))
  helper.assert_equal(0, colors)
  helper.assert_equal(0, vars)
  helper.assert_equal("child", o.ends[1])
  helper.assert_equal("window", o.ends[2])
end)

helper.test("false Begin and BeginChild are not ended twice", function()
  for _, o in ipairs({ { visible = false }, { child_visible = false } }) do
    draw(o)
    helper.assert_equal(o.visible == false and 0 or 1, #o.ends)
    if o.visible ~= false then helper.assert_equal("window", o.ends[1]) end
  end
end)


helper.test("action is rechecked after a parameter change in the same frame", function()
  local app = fake_app(true)
  local original = app.set_setting
  app.set_setting = function(self, ...)
    self.model.dirty = true
    return original(self, ...)
  end
  local _, action = draw({ click = "Apply", slider_results = { ["Length (%)"] = 25 } }, app)
  helper.assert_equal(nil, action)
end)

helper.test("fill mode remains explicit when the Position section is collapsed", function()
  local app, o = fake_app(true), { headers = { Position = false } }
  app.model.timeline_fill = fill_summary()
  draw(o, app)
  helper.assert_true(contains(o.wrapped_texts, "Filling time selection · 12 slots"))
end)

helper.test("curve choices preserve REAPER fade IDs", function()
  local app = fake_app(true)
  draw({ combo_label = "Curve", select_label = "REAPER curve 3" }, app)
  helper.assert_equal(3, app.model.settings.cf_curve)
end)

helper.test("transport Stop guidance remains visible with a preview error", function()
  local app, o = fake_app(false), {}
  app.model.error = "preview failed"
  app.api = { GetPlayStateEx = function() return 1 end }
  draw(o, app)
  helper.assert_true(contains(o.wrapped_texts, "Error: preview failed"))
  helper.assert_true(contains(o.wrapped_texts, "Stop playback in REAPER to update or finish."))
end)

helper.test("Region checkbox writes the Apply-only setting", function()
  local app = fake_app(true)
  local options = { headers = { Position = false },
    checkbox_results = { ["Create regions on Apply"] = true } }
  draw(options, app)
  helper.assert_equal(false, find_control(options, "Create regions on Apply").value)
  helper.assert_equal(true, app.model.settings.create_regions)
end)
