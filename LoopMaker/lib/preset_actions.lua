local M = {}

function M.load(store, reaper_api, app, ui, name, now)
  local loaded, reason, warnings = store.load(reaper_api, name)
  if not loaded then
    app.model.error = reason
    return nil
  end

  loaded.preset = name
  local replaced, replace_reason = app:replace_settings(loaded, now)
  if not replaced then
    app.model.error = replace_reason
    return nil
  end

  ui.preset_name = name
  ui.selected_preset = name
  app.model.error = nil
  app.model.warnings = warnings or {}
  return true
end

return M
