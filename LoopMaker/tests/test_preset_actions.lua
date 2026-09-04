local helper = require("tests.test_helper")
local preset_actions = require("lib.preset_actions")

helper.test("preset load keeps UI selection unchanged when settings replacement fails", function()
  local store = {
    load = function()
      return { loops = 4 }, nil, { "loaded warning" }
    end,
  }
  local app = {
    model = { error = nil, warnings = { "old warning" } },
    replace_settings = function()
      return nil, "replacement failed"
    end,
  }
  local ui = {
    selected_preset = "Default",
    preset_name = "",
  }

  local loaded = preset_actions.load(store, {}, app, ui, "Broken", 12.5)

  helper.assert_equal(nil, loaded)
  helper.assert_equal("Default", ui.selected_preset)
  helper.assert_equal("", ui.preset_name)
  helper.assert_equal("replacement failed", app.model.error)
  helper.assert_equal("old warning", app.model.warnings[1])
end)

helper.test("preset load updates UI only after settings replacement succeeds", function()
  local replaced_settings
  local replaced_now
  local store = {
    load = function(_, name)
      helper.assert_equal("Working", name)
      return { loops = 4 }, nil, { "loaded warning" }
    end,
  }
  local app = {
    model = { error = "old error", warnings = {} },
    replace_settings = function(_, values, now)
      replaced_settings = values
      replaced_now = now
      return true
    end,
  }
  local ui = {
    selected_preset = "Default",
    preset_name = "",
  }

  local loaded = preset_actions.load(store, {}, app, ui, "Working", 12.5)

  helper.assert_equal(true, loaded)
  helper.assert_equal("Working", replaced_settings.preset)
  helper.assert_equal(12.5, replaced_now)
  helper.assert_equal("Working", ui.selected_preset)
  helper.assert_equal("Working", ui.preset_name)
  helper.assert_equal(nil, app.model.error)
  helper.assert_equal("loaded warning", app.model.warnings[1])
end)
