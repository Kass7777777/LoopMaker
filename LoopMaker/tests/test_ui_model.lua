local helper = require("tests.test_helper")
local ui_model = require("ui.model")

helper.test("Shepard and zero-crossing panels are mutually exclusive", function()
  local model = ui_model.new({ show_zc = true })

  local changed = ui_model.set(model, "show_shepard", true)

  helper.assert_true(changed)
  helper.assert_true(model.settings.show_shepard)
  helper.assert_equal(false, model.settings.show_zc)
end)

helper.test("opening zero-crossing closes Shepard panel", function()
  local model = ui_model.new({ show_shepard = true, shepard = true })

  ui_model.set(model, "show_zc", true)

  helper.assert_true(model.settings.show_zc)
  helper.assert_equal(false, model.settings.show_shepard)
end)

helper.test("result settings mark preview dirty while presentation settings do not", function()
  local model = ui_model.new({ loops = 1, show_name = true })

  ui_model.set(model, "show_name", false)
  helper.assert_equal(false, model.dirty)

  ui_model.set(model, "loops", 2)
  helper.assert_true(model.dirty)

  ui_model.mark_clean(model)
  ui_model.set(model, "loops", 2)
  helper.assert_equal(false, model.dirty)
end)

helper.test("keyboard shortcuts map to apply preview and cancel", function()
  helper.assert_equal("apply", ui_model.action_for_key("enter"))
  helper.assert_equal("apply", ui_model.action_for_key("keypad_enter"))
  helper.assert_equal("preview", ui_model.action_for_key("space"))
  helper.assert_equal("cancel", ui_model.action_for_key("escape"))
  helper.assert_equal(nil, ui_model.action_for_key("a"))
end)

helper.test("apply is disabled without selected audio items or with an error", function()
  local model = ui_model.new()
  helper.assert_equal(false, ui_model.can_apply(model))

  ui_model.set_selected_count(model, 2)
  helper.assert_true(ui_model.can_apply(model))

  ui_model.set_error(model, "preview failed")
  helper.assert_equal(false, ui_model.can_apply(model))

  ui_model.set_error(model, nil)
  helper.assert_true(ui_model.can_apply(model))
end)

helper.test("loading settings sanitizes values and marks the preview dirty", function()
  local model = ui_model.new({ loops = 1 })

  ui_model.replace_settings(model, {
    loops = 5000,
    show_shepard = true,
    show_zc = true,
  })

  helper.assert_equal(1000, model.settings.loops)
  helper.assert_true(model.settings.show_shepard)
  helper.assert_equal(false, model.settings.show_zc)
  helper.assert_true(model.dirty)
end)

helper.test("enabling Shepard mode clamps the layer exponent to its safe maximum", function()
  local model = ui_model.new({ loops = 10, shepard = false })

  ui_model.set(model, "shepard", true)

  helper.assert_true(model.settings.shepard)
  helper.assert_equal(6, model.settings.loops)
  helper.assert_true(model.dirty)
end)

helper.test("Apply-only Glue changes do not rebuild preview", function()
  local model = ui_model.new({ glue = true })

  ui_model.set(model, "glue", false)

  helper.assert_equal(false, model.dirty)
end)

helper.test("replacing only presentation settings does not rebuild preview", function()
  local model = ui_model.new({ show_name = true, preset = "Default" })
  local replacement = ui_model.new({
    show_name = false,
    preset = "Presentation only",
  }).settings

  ui_model.replace_settings(model, replacement)

  helper.assert_equal(false, model.dirty)
end)

helper.test("disabled Apply shortcut is ignored", function()
  local model = ui_model.new()

  helper.assert_equal(nil, ui_model.allowed_action(model, "apply"))
  helper.assert_equal("preview", ui_model.allowed_action(model, "preview"))
  ui_model.set_selected_count(model, 1)
  helper.assert_equal("apply", ui_model.allowed_action(model, "apply"))
end)

helper.test("UI model initializes without timeline fill mode", function()
  local model = ui_model.new()

  helper.assert_equal(nil, model.timeline_fill)
  helper.assert_equal(nil, ui_model.fill_summary(model))
end)

helper.test("fill summary accepts every valid timeline field", function()
  local summary = {
    variation_count = 5,
    source_count = 2,
    slot_count = 12,
    slot_samples = 24000,
    slot_length = 0.5,
    start = -1,
    ["end"] = 5,
  }

  local result = ui_model.fill_summary({ timeline_fill = summary })
  helper.assert_true(result ~= summary)
  helper.assert_equal(5, result.variation_count)
  helper.assert_equal("integer", math.type(result.variation_count))
  helper.assert_equal(2, result.source_count)
  helper.assert_equal("integer", math.type(result.source_count))
  helper.assert_equal(12, result.slot_count)
  helper.assert_equal("integer", math.type(result.slot_count))
  helper.assert_equal(24000, result.slot_samples)
  helper.assert_equal("integer", math.type(result.slot_samples))
end)

helper.test("fill summary safely rejects huge floating-point counts", function()
  local fields = {
    "variation_count",
    "source_count",
    "slot_count",
    "slot_samples",
  }
  for _, field in ipairs(fields) do
    local summary = {
      variation_count = 5,
      source_count = 2,
      slot_count = 12,
      slot_samples = 24000,
      slot_length = 0.5,
      start = 1,
      ["end"] = 7,
    }
    summary[field] = 1e100

    local ok, result = pcall(ui_model.fill_summary, { timeline_fill = summary })
    helper.assert_true(ok)
    helper.assert_equal(nil, result)
  end
end)

helper.test("fill summary rejects missing malformed and inconsistent fields", function()
  local valid = {
    variation_count = 5,
    source_count = 2,
    slot_count = 12,
    slot_samples = 24000,
    slot_length = 0.5,
    start = 1,
    ["end"] = 7,
  }
  local invalid = {
    false,
    {},
    { variation_count = 5 },
  }
  local fields = {
    "variation_count",
    "source_count",
    "slot_count",
    "slot_samples",
    "slot_length",
    "start",
    "end",
  }
  for _, field in ipairs(fields) do
    local missing = {}
    for key, value in pairs(valid) do missing[key] = value end
    missing[field] = nil
    invalid[#invalid + 1] = missing
  end
  local bad_integer = {}
  for key, value in pairs(valid) do bad_integer[key] = value end
  bad_integer.slot_count = 1.5
  invalid[#invalid + 1] = bad_integer
  local bad_number = {}
  for key, value in pairs(valid) do bad_number[key] = value end
  bad_number.slot_length = 0 / 0
  invalid[#invalid + 1] = bad_number
  local reversed = {}
  for key, value in pairs(valid) do reversed[key] = value end
  reversed["end"] = reversed.start
  invalid[#invalid + 1] = reversed

  for _, summary in ipairs(invalid) do
    local ok, result = pcall(ui_model.fill_summary, { timeline_fill = summary })
    helper.assert_true(ok)
    helper.assert_equal(nil, result)
  end
end)

helper.test("Region toggle defaults off and does not rebuild audio", function()
  local model = ui_model.new({})
  helper.assert_equal(false, model.settings.create_regions)
  helper.assert_true(ui_model.set(model, "create_regions", true))
  helper.assert_equal(true, model.settings.create_regions)
  helper.assert_equal(false, model.dirty)
end)
