local helper = require("tests.test_helper")
local state = require("lib.state")

local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local function assert_contains(text, fragment)
  assert_true(type(text) == "string" and text:find(fragment, 1, true) ~= nil,
    "expected " .. tostring(text) .. " to contain " .. fragment)
end

local function warnings_contain(warnings, fragment)
  if type(warnings) ~= "table" then
    return false
  end
  for _, warning in ipairs(warnings) do
    if tostring(warning):find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function tracked_contains(transaction, item, guid)
  for _, entry in ipairs(transaction.tracked_preview_items or {}) do
    if entry.item == item and entry.guid == guid then return true end
  end
  return false
end

local function new_fake()
  local project_a = { name = "A" }
  local project_b = { name = "B" }
  local track = { name = "track" }
  local item_a = { guid = "{A}", chunk = "CHUNK A", selected = true, track = track, valid = true }
  local item_b = { guid = "{B}", chunk = "CHUNK B", selected = false, track = track, valid = true }
  local item_c = { guid = "{C}", chunk = "CHUNK C", selected = true, track = track, valid = true }
  local model = {
    current_project = project_a,
    project_a = project_a,
    project_b = project_b,
    items = { item_a, item_b, item_c },
    initial_items = { item_a, item_b, item_c },
    time_start = 2,
    time_end = 7,
    loop_start = 11,
    loop_end = 13,
    repeat_state = 0,
    cursor = 4,
    play_state = 0,
    play_position = 3.5,
    ui_depth = 0,
    ui_calls = {},
    undo_begin = 0,
    undo_end = {},
    deletes = 0,
    chunk_writes = 0,
    stop_calls = 0,
    stop_ex_calls = 0,
    stop_global_calls = 0,
    stopped_projects = {},
    loop_set_calls = 0,
    cursor_set_calls = 0,
    repeat_set_calls = 0,
    update_calls = 0,
    atexit_callback = nil,
    console_messages = {},
    enum_calls = {},
    delete_order = {},
    delete_failures = 0,
    open_projects = { project_a, project_b },
    undo_end_failures = 0,
    undo_end_false_returns = 0,
    atexit_error = nil,
    throw_on = nil,
    throw_counts = {},
    chunk_false_returns = 0,
    chunk_ignored_writes = 0,
    chunk_ignored_returns_true = false,
    selection_writes = 0,
    add_item_calls = 0,
    add_item_failures = 0,
    track = track,
    chunk_guids = {
      ["CHUNK A"] = "{A}",
      ["CHUNK B"] = "{B}",
      ["CHUNK C"] = "{C}",
    },
  }
  local api = {}

  local function maybe_throw(name)
    if model.throw_counts[name] and model.throw_counts[name] > 0 then
      model.throw_counts[name] = model.throw_counts[name] - 1
      error(name .. " transient failure")
    end
    if model.throw_on == name then
      error(name .. " exploded")
    end
  end

  function api.EnumProjects(index, ...)
    maybe_throw("EnumProjects")
    assert_equal(0, select("#", ...), "EnumProjects must receive exactly one argument")
    model.enum_calls[#model.enum_calls + 1] = index
    if index == -1 then
      return model.current_project, model.current_project.name
    end
    return model.open_projects[index + 1]
  end

  function api.CountMediaItems(project)
    maybe_throw("CountMediaItems")
    assert_equal(project_a, project)
    return #model.items
  end

  function api.GetMediaItem(project, index)
    maybe_throw("GetMediaItem")
    assert_equal(project_a, project)
    return model.items[index + 1]
  end

  function api.CountSelectedMediaItems(project)
    maybe_throw("CountSelectedMediaItems")
    assert_equal(project_a, project)
    local count = 0
    for _, item in ipairs(model.items) do
      if item.selected then
        count = count + 1
      end
    end
    return count
  end

  function api.GetSelectedMediaItem(project, index)
    maybe_throw("GetSelectedMediaItem")
    assert_equal(project_a, project)
    local selected = {}
    for _, item in ipairs(model.items) do
      if item.selected then
        selected[#selected + 1] = item
      end
    end
    return selected[index + 1]
  end

  function api.GetItemStateChunk(item, buffer, is_undo)
    maybe_throw("GetItemStateChunk")
    assert_equal("", buffer)
    assert_equal(false, is_undo)
    return true, item.chunk
  end

  function api.GetSetMediaItemInfo_String(item, key, value, set_new_value)
    maybe_throw("GetSetMediaItemInfo_String")
    assert_equal("GUID", key)
    assert_equal("", value)
    assert_equal(false, set_new_value)
    return true, item.guid
  end

  function api.IsMediaItemSelected(item)
    maybe_throw("IsMediaItemSelected")
    return item.selected
  end

  function api.GetSet_LoopTimeRange2(project, is_set, is_loop, start_time, end_time, allow_autoseek)
    maybe_throw("GetSet_LoopTimeRange2")
    assert_equal(project_a, project)
    assert_equal(false, allow_autoseek)
    if is_set then
      model.loop_set_calls = model.loop_set_calls + 1
      if is_loop then
        model.loop_start = start_time
        model.loop_end = end_time
      else
        model.time_start = start_time
        model.time_end = end_time
      end
      return
    end
    if is_loop then
      return model.loop_start, model.loop_end
    end
    return model.time_start, model.time_end
  end

  function api.GetSetRepeatEx(project, value)
    maybe_throw("GetSetRepeatEx")
    assert_equal(project_a, project)
    if value >= 0 then
      model.repeat_set_calls = model.repeat_set_calls + 1
      model.repeat_state = value > 0 and 1 or 0
    end
    return model.repeat_state
  end

  function api.GetCursorPositionEx(project)
    maybe_throw("GetCursorPositionEx")
    assert_equal(project_a, project)
    return model.cursor
  end

  function api.GetPlayStateEx(project)
    maybe_throw("GetPlayStateEx")
    assert_equal(project_a, project)
    return model.play_state
  end

  function api.GetPlayPositionEx(project)
    maybe_throw("GetPlayPositionEx")
    assert_equal(project_a, project)
    return model.play_position
  end

  function api.PreventUIRefresh(delta)
    model.ui_depth = model.ui_depth + delta
    model.ui_calls[#model.ui_calls + 1] = delta
  end

  function api.Undo_BeginBlock2(project)
    maybe_throw("Undo_BeginBlock2")
    assert_equal(project_a, project)
    model.undo_begin = model.undo_begin + 1
  end

  function api.Undo_EndBlock2(project, description, flags)
    maybe_throw("Undo_EndBlock2")
    assert_equal(project_a, project)
    if model.undo_end_failures > 0 then
      model.undo_end_failures = model.undo_end_failures - 1
      error("Undo_EndBlock2 transient failure")
    end
    if model.undo_end_false_returns > 0 then
      model.undo_end_false_returns = model.undo_end_false_returns - 1
      return false
    end
    model.undo_end[#model.undo_end + 1] = { description = description, flags = flags }
  end

  function api.ValidatePtr2(project, item, kind)
    maybe_throw("ValidatePtr2")
    assert_equal(project_a, project)
    if kind == "MediaTrack*" then
      return item == track and item.valid ~= false
    end
    assert_equal("MediaItem*", kind)
    return type(item) == "table" and item.valid == true
  end

  function api.GetMediaItemTrack(item)
    maybe_throw("GetMediaItemTrack")
    return item.track
  end

  function api.DeleteTrackMediaItem(item_track, item)
    maybe_throw("DeleteTrackMediaItem")
    assert_equal(track, item_track)
    if model.delete_failures > 0 then
      model.delete_failures = model.delete_failures - 1
      return false
    end
    for index, candidate in ipairs(model.items) do
      if candidate == item then
        table.remove(model.items, index)
        item.valid = false
        model.deletes = model.deletes + 1
        model.delete_order[#model.delete_order + 1] = item.guid
        return true
      end
    end
    return false
  end

  function api.AddMediaItemToTrack(item_track)
    maybe_throw("AddMediaItemToTrack")
    assert_equal(track, item_track)
    model.add_item_calls = model.add_item_calls + 1
    if model.add_item_failures > 0 then
      model.add_item_failures = model.add_item_failures - 1
      return nil
    end
    local item = {
      guid = "{ADDED-" .. model.add_item_calls .. "}",
      chunk = "",
      selected = false,
      track = track,
      valid = true,
    }
    model.items[#model.items + 1] = item
    return item
  end

  function api.SetItemStateChunk(item, chunk, is_undo)
    maybe_throw("SetItemStateChunk")
    assert_equal(false, is_undo)
    model.chunk_writes = model.chunk_writes + 1
    if model.chunk_false_returns > 0 then
      model.chunk_false_returns = model.chunk_false_returns - 1
      return false
    end
    if model.chunk_ignored_writes > 0 then
      model.chunk_ignored_writes = model.chunk_ignored_writes - 1
      if model.chunk_ignored_returns_true then return true end
      return nil
    end
    item.chunk = chunk
    if model.chunk_guids[chunk] ~= nil then
      item.guid = model.chunk_guids[chunk]
    end
    return true
  end

  function api.SetMediaItemSelected(item, selected)
    maybe_throw("SetMediaItemSelected")
    model.selection_writes = model.selection_writes + 1
    item.selected = selected
  end

  function api.SetEditCurPos2(project, position, move_view, seek_play)
    maybe_throw("SetEditCurPos2")
    assert_equal(project_a, project)
    assert_equal(false, move_view)
    assert_equal(false, seek_play)
    model.cursor_set_calls = model.cursor_set_calls + 1
    model.cursor = position
  end

  function api.UpdateArrange()
    maybe_throw("UpdateArrange")
    model.update_calls = model.update_calls + 1
  end

  function api.OnStopButtonEx(project)
    maybe_throw("OnStopButtonEx")
    assert_equal(project_a, project)
    model.stop_calls = model.stop_calls + 1
    model.stop_ex_calls = model.stop_ex_calls + 1
    model.stopped_projects[#model.stopped_projects + 1] = project
    model.play_state = 0
  end

  function api.OnStopButton()
    maybe_throw("OnStopButton")
    model.stop_calls = model.stop_calls + 1
    model.stop_global_calls = model.stop_global_calls + 1
    model.play_state = 0
  end

  function api.atexit(callback)
    maybe_throw("atexit")
    if model.atexit_error then
      error(model.atexit_error)
    end
    model.atexit_callback = callback
  end

  function api.ShowConsoleMsg(message)
    model.console_messages[#model.console_messages + 1] = message
  end

  function model.add_preview(guid)
    local item = {
      guid = guid or "{PREVIEW}",
      chunk = "PREVIEW CHUNK",
      selected = true,
      track = track,
      valid = true,
    }
    model.items[#model.items + 1] = item
    return item
  end

  return api, model
end

test("project_is_open enumerates open projects with one argument", function()
  local api, model = new_fake()

  assert_equal(true, state.project_is_open(api, model.project_a))
  assert_equal(true, state.project_is_open(api, model.project_b))
  local closed = { name = "closed" }
  assert_equal(false, state.project_is_open(api, closed))
  assert_equal(0, model.enum_calls[1])
end)

test("capture validates the injected API and explicit current project", function()
  local transaction, reason = state.Transaction.capture({}, 0)
  assert_equal(nil, transaction)
  assert_contains(reason, "missing")

  local api, model = new_fake()
  local wrong, wrong_reason = state.Transaction.capture(api, model.project_b)
  assert_equal(nil, wrong)
  assert_contains(wrong_reason, "current project")
  assert_equal(0, model.undo_begin)

  local transaction_ok, capture_reason = state.Transaction.capture(api, 0)
  assert_true(transaction_ok ~= nil, capture_reason)
  assert_equal(0, transaction_ok.captured.initial_play_state)
  assert_equal(11, transaction_ok.captured.loop_start)
  assert_equal(13, transaction_ok.captured.loop_end)
  assert_equal(0, transaction_ok.captured.repeat_state)
  assert_true(transaction_ok:is_active())
  assert_true(transaction_ok:is_same_project())
  assert_equal(1, model.undo_begin)
end)

test("capture rejects empty official GUIDs", function()
  local api, model = new_fake()
  model.initial_items[2].guid = ""

  local transaction, reason = state.Transaction.capture(api, 0)

  assert_equal(nil, transaction)
  assert_contains(reason, "GUID")
  assert_equal(0, model.undo_begin)
end)

test("capture requires AddMediaItemToTrack for recoverable Glue replacement", function()
  local api, model = new_fake()
  api.AddMediaItemToTrack = nil

  local transaction, reason = state.Transaction.capture(api, 0)

  assert_equal(nil, transaction)
  assert_contains(reason, "AddMediaItemToTrack")
  assert_equal(0, model.undo_begin)
end)

test("capture failures return a reason without opening Undo", function()
  local api, model = new_fake()
  model.throw_on = "GetItemStateChunk"

  local transaction, reason = state.Transaction.capture(api, 0)

  assert_equal(nil, transaction)
  assert_contains(reason, "GetItemStateChunk")
  assert_equal(0, model.undo_begin)
end)

test("final restore removes previews and restores chunks global state and every selection", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local item_a, item_b, item_c = model.initial_items[1], model.initial_items[2], model.initial_items[3]
  assert_equal(true, transaction:begin_preview_mutation())
  model.add_preview()
  assert_equal(true, transaction:end_preview_mutation())
  item_a.chunk = "MUTATED A"
  item_c.chunk = "MUTATED C"
  item_a.selected = false
  item_b.selected = true
  item_c.selected = false
  model.time_start, model.time_end, model.cursor = 20, 30, 25
  model.loop_start, model.loop_end, model.repeat_state = 40, 50, 1

  local restored, warnings = transaction:restore()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(3, #model.items)
  assert_equal(1, model.deletes)
  assert_equal("CHUNK A", item_a.chunk)
  assert_equal("CHUNK B", item_b.chunk)
  assert_equal("CHUNK C", item_c.chunk)
  assert_equal(true, item_a.selected)
  assert_equal(false, item_b.selected)
  assert_equal(true, item_c.selected)
  assert_equal(2, model.time_start)
  assert_equal(7, model.time_end)
  assert_equal(11, model.loop_start)
  assert_equal(13, model.loop_end)
  assert_equal(0, model.repeat_state)
  assert_equal(4, model.cursor)
  assert_equal(0, model.ui_depth)
  assert_equal(1, model.update_calls)
  assert_equal(false, transaction:is_active())
  assert_equal(1, #model.undo_end)
  assert_equal("LoopMaker: Cancel", model.undo_end[1].description)
end)

test("restore accepts void SetItemStateChunk success", function()
  local api, model = new_fake()
  local original_set_chunk = api.SetItemStateChunk
  function api.SetItemStateChunk(item, chunk, is_undo)
    original_set_chunk(item, chunk, is_undo)
    return nil
  end
  local transaction = assert(state.Transaction.capture(api, 0))
  model.initial_items[1].chunk = "MUTATED"
  local restored, warnings = transaction:restore()
  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal("CHUNK A", model.initial_items[1].chunk)
end)

test("SetItemStateChunk false keeps restore active and succeeds on retry", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{CHUNK-RETRY}")
  assert_equal(true, transaction:end_preview_mutation())
  local item = model.initial_items[1]
  item.chunk = "MUTATED"
  model.chunk_false_returns = 1

  local restored, reason = transaction:restore()

  assert_equal(nil, restored)
  assert_contains(reason, "SetItemStateChunk")
  assert_equal("MUTATED", item.chunk)
  assert_equal(false, preview.valid)
  assert_true(tracked_contains(transaction, preview, "{CHUNK-RETRY}"))
  assert_true(transaction:is_active())
  assert_equal(0, #model.undo_end)

  local retried, warnings = transaction:restore()
  assert_equal(true, retried)
  assert_equal(0, #warnings)
  assert_equal("CHUNK A", item.chunk)
  assert_equal(false, tracked_contains(transaction, preview, "{CHUNK-RETRY}"))
  assert_equal(false, transaction:is_active())
end)

test("chunk restore verifies readback for true and void setters", function()
  for _, case in ipairs({
    { returns_true = true },
    { returns_true = false },
  }) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    local item = model.initial_items[1]
    item.chunk = "MUTATED"
    model.chunk_ignored_writes = 1
    model.chunk_ignored_returns_true = case.returns_true

    local restored, reason = transaction:restore()

    assert_equal(nil, restored)
    assert_contains(reason, "chunk setter did not take effect")
    assert_equal("MUTATED", item.chunk)
    assert_true(transaction:is_active())
    assert_equal(0, #model.undo_end)

    local retried, warnings = transaction:restore()
    assert_equal(true, retried)
    assert_equal(0, #warnings)
    assert_equal("CHUNK A", item.chunk)
  end
end)

test("restore rebuilds a selected original deleted by Glue", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local original = model.initial_items[1]
  assert_equal(model.track, transaction.captured.selected_items[1].track)
  assert_equal(true, transaction:begin_preview_mutation())
  table.remove(model.items, 1)
  original.valid = false
  local glued = model.add_preview("{GLUED}")
  assert_equal(true, transaction:end_preview_mutation())

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(false, glued.valid)
  assert_equal(1, model.add_item_calls)
  assert_equal(3, #model.items)
  local rebuilt = transaction.captured.selected_items[1].item
  assert_true(rebuilt ~= original)
  assert_equal(true, rebuilt.valid)
  assert_equal("{A}", rebuilt.guid)
  assert_equal("CHUNK A", rebuilt.chunk)
  assert_equal(true, rebuilt.selected)
  assert_equal(rebuilt, transaction.captured.all_items[1].item)
end)

test("failed original rebuild deletes its half-created Item and remains retryable", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local original = model.initial_items[1]
  table.remove(model.items, 1)
  original.valid = false
  model.chunk_false_returns = 1

  local restored, reason = transaction:restore()

  assert_equal(nil, restored)
  assert_contains(reason, "SetItemStateChunk")
  assert_equal(1, model.add_item_calls)
  assert_equal(1, model.deletes)
  assert_equal(2, #model.items)
  assert_true(transaction:is_active())
  assert_equal(0, #model.undo_end)

  local retried, warnings = transaction:restore()
  assert_equal(true, retried)
  assert_equal(0, #warnings)
  assert_equal(2, model.add_item_calls)
  assert_equal(3, #model.items)
  assert_equal("{A}", transaction.captured.selected_items[1].item.guid)
end)

test("restore preserves selection of untracked user Items", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local user_selected = model.add_preview("{USER-SELECTED}")
  user_selected.selected = true
  local user_unselected = model.add_preview("{USER-UNSELECTED}")
  user_unselected.selected = false
  model.initial_items[1].selected = false
  model.initial_items[2].selected = true
  model.initial_items[3].selected = false

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(true, model.initial_items[1].selected)
  assert_equal(false, model.initial_items[2].selected)
  assert_equal(true, model.initial_items[3].selected)
  assert_equal(true, user_selected.selected)
  assert_equal(false, user_unselected.selected)
  assert_equal(3, model.selection_writes)
end)

test("restore deletes consecutive preview items in reverse project order", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  model.add_preview("{PREVIEW-1}")
  model.add_preview("{PREVIEW-2}")
  model.add_preview("{PREVIEW-3}")
  assert_equal(true, transaction:end_preview_mutation())

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(3, model.deletes)
  assert_equal("{PREVIEW-3}", model.delete_order[1])
  assert_equal("{PREVIEW-2}", model.delete_order[2])
  assert_equal("{PREVIEW-1}", model.delete_order[3])
end)

test("restore preserves every untracked Item added after capture", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local recorded = model.add_preview("{RECORDED}")

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(true, recorded.valid)
  assert_equal(4, #model.items)
  assert_equal(0, model.deletes)
end)

test("restore deletes only GUIDs created inside a preview mutation", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local recorded = model.add_preview("{RECORDED}")
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{PREVIEW}")
  assert_equal(true, transaction:end_preview_mutation())

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(true, recorded.valid)
  assert_equal(false, preview.valid)
  assert_equal(1, model.deletes)
  assert_equal("{PREVIEW}", model.delete_order[1])
end)

test("preview mutation tracks pointer reuse when its GUID changes", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local reused = model.add_preview("{USER-BEFORE}")

  assert_equal(true, transaction:begin_preview_mutation())
  reused.guid = "{PREVIEW-ONE}"
  assert_equal(true, transaction:end_preview_mutation())
  assert_true(tracked_contains(transaction, reused, "{PREVIEW-ONE}"))

  assert_equal(true, transaction:begin_preview_mutation())
  reused.guid = "{PREVIEW-TWO}"
  assert_equal(true, transaction:end_preview_mutation())
  assert_true(tracked_contains(transaction, reused, "{PREVIEW-ONE}"))
  assert_true(tracked_contains(transaction, reused, "{PREVIEW-TWO}"))
  assert_equal(2, #(transaction.tracked_preview_items or {}))
end)

test("preview mutation restores selection of pre-existing user Items only", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local user_item = model.add_preview("{USER-SELECTION}")
  user_item.selected = true

  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{PREVIEW-SELECTION}")
  for _, item in ipairs(model.items) do
    item.selected = false
  end
  assert_equal(true, transaction:end_preview_mutation())

  assert_equal(true, user_item.selected)
  assert_equal(false, preview.selected)
  assert_equal(false, model.initial_items[1].selected)
  assert_equal(false, model.initial_items[3].selected)
end)

test("preview mutation rejects nesting while preserving its retryable baseline", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))

  assert_equal(true, transaction:begin_preview_mutation())
  local baseline = transaction.preview_mutation_state
  local nested, nested_reason = transaction:begin_preview_mutation()

  assert_equal(nil, nested)
  assert_contains(nested_reason, "mutation")
  assert_equal(baseline, transaction.preview_mutation_state)
  model.add_preview("{PARTIAL}")
  assert_equal(true, transaction:end_preview_mutation())
  assert_equal(nil, transaction.preview_mutation_state)

  model.current_project = model.project_b
  local switched, switched_reason = transaction:begin_preview_mutation()
  assert_equal(nil, switched)
  assert_contains(switched_reason, "current project")
end)

test("end mutation failure retains baseline and restore retries the delta", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{PARTIAL-RETRY}")
  model.throw_counts.CountMediaItems = 1

  local ended, end_reason = transaction:end_preview_mutation()

  assert_equal(nil, ended)
  assert_contains(end_reason, "CountMediaItems")
  assert_true(transaction.preview_mutation_state ~= nil)
  assert_equal(true, preview.valid)
  assert_equal(0, model.deletes)

  local restored, warnings = transaction:restore_for_rebuild()
  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(false, preview.valid)
  assert_equal(nil, transaction.preview_mutation_state)
  assert_equal(1, model.deletes)
end)

test("background restore completes a pending mutation after project switch", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{BACKGROUND-PARTIAL}")
  model.throw_counts.CountMediaItems = 1

  local ended, end_reason = transaction:end_preview_mutation()
  assert_equal(nil, ended)
  assert_contains(end_reason, "CountMediaItems")
  assert_true(transaction.preview_mutation_state ~= nil)

  model.current_project = model.project_b
  local foreground, foreground_reason = transaction:end_preview_mutation()
  assert_equal(nil, foreground)
  assert_contains(foreground_reason, "current project")
  assert_true(transaction.preview_mutation_state ~= nil)
  assert_equal(true, preview.valid)

  local restored, warnings = transaction:restore_in_background()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(false, preview.valid)
  assert_equal(nil, transaction.preview_mutation_state)
  assert_equal(0, #(transaction.tracked_preview_items or {}))
  assert_equal(false, transaction:is_active())
  assert_equal(1, model.deletes)
end)

test("background mutation end rejects a closed captured project", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{CLOSED-PARTIAL}")
  model.current_project = model.project_b
  model.open_projects = { model.project_b }

  local ended, reason = transaction:end_preview_mutation(true)

  assert_equal(nil, ended)
  assert_contains(reason, "closed")
  assert_true(transaction.preview_mutation_state ~= nil)
  assert_equal(true, preview.valid)
end)

test("restore fails before writes when pending mutation enumeration still fails", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{PENDING}")
  model.throw_counts.CountMediaItems = 2
  assert_equal(nil, transaction:end_preview_mutation())
  local chunk_writes = model.chunk_writes
  local loop_writes = model.loop_set_calls

  local restored, reason = transaction:restore()

  assert_equal(nil, restored)
  assert_contains(reason, "end preview mutation")
  assert_equal(true, preview.valid)
  assert_equal(chunk_writes, model.chunk_writes)
  assert_equal(loop_writes, model.loop_set_calls)
  assert_equal(0, #model.undo_end)
  assert_true(transaction.preview_mutation_state ~= nil)
  assert_true(transaction:is_active())
end)

test("GUID reincarnation never deletes a different user Item pointer", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{REUSED-GUID}")
  assert_equal(true, transaction:end_preview_mutation())
  assert_true(tracked_contains(transaction, preview, "{REUSED-GUID}"))

  table.remove(model.items, #model.items)
  preview.valid = false
  local user_item = model.add_preview("{REUSED-GUID}")
  user_item.selected = true

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal(true, user_item.valid)
  assert_equal(true, user_item.selected)
  assert_equal(0, model.deletes)
  assert_equal(0, #(transaction.tracked_preview_items or {}))
end)

test("failed tracked preview deletion remains tracked and succeeds on retry", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{PREVIEW-RETRY}")
  assert_equal(true, transaction:end_preview_mutation())
  model.delete_failures = 1

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_true(warnings_contain(warnings, "failed to delete"))
  assert_equal(true, preview.valid)
  assert_true(tracked_contains(transaction, preview, "{PREVIEW-RETRY}"))

  local retried, retry_warnings = transaction:restore_for_rebuild()
  assert_equal(true, retried)
  assert_equal(0, #retry_warnings)
  assert_equal(false, preview.valid)
  assert_equal(false, tracked_contains(transaction, preview, "{PREVIEW-RETRY}"))
end)

test("final restore is idempotent after a successful Cancel", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  model.add_preview()
  assert_equal(true, transaction:end_preview_mutation())

  local first = transaction:restore()
  local deletes = model.deletes
  local writes = model.chunk_writes
  local second, warnings = transaction:restore()

  assert_equal(true, first)
  assert_equal(true, second)
  assert_true(type(warnings) == "table")
  assert_equal(deletes, model.deletes)
  assert_equal(writes, model.chunk_writes)
  assert_equal(1, #model.undo_end)
end)

test("restore_for_rebuild can restore repeatedly while keeping one Undo block active", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local item_a = model.initial_items[1]

  assert_equal(true, transaction:begin_preview_mutation())
  model.add_preview("{PREVIEW-1}")
  assert_equal(true, transaction:end_preview_mutation())
  item_a.chunk = "FIRST MUTATION"
  assert_equal(true, transaction:restore_for_rebuild())
  assert_equal("CHUNK A", item_a.chunk)
  assert_true(transaction:is_active())
  assert_equal(0, #model.undo_end)

  assert_equal(true, transaction:begin_preview_mutation())
  model.add_preview("{PREVIEW-2}")
  assert_equal(true, transaction:end_preview_mutation())
  item_a.chunk = "SECOND MUTATION"
  assert_equal(true, transaction:restore_for_rebuild())
  assert_equal("CHUNK A", item_a.chunk)
  assert_equal(2, model.deletes)
  assert_true(transaction:is_active())
  assert_equal(1, model.undo_begin)
  assert_equal(0, #model.undo_end)

  assert_equal(true, transaction:restore())
  assert_equal(1, #model.undo_end)
end)

test("capture returns nil when atexit registration fails and second Undo close succeeds", function()
  local api, model = new_fake()
  model.atexit_error = "registration failed"
  model.undo_end_failures = 1

  local transaction, reason = state.Transaction.capture(api, 0)

  assert_equal(nil, transaction)
  assert_contains(reason, "registration failed")
  assert_contains(reason, "first cleanup")
  assert_equal(1, #model.undo_end)
  assert_equal("LoopMaker: Abandon", model.undo_end[1].description)
end)

test("capture returns nil and combined errors when atexit cleanup keeps failing", function()
  local api, model = new_fake()
  model.atexit_error = "registration failed"
  model.undo_end_failures = 2

  local transaction, reason = state.Transaction.capture(api, 0)

  assert_equal(nil, transaction)
  assert_contains(reason, "registration failed")
  assert_contains(reason, "first cleanup")
  assert_contains(reason, "second cleanup")
  assert_equal(0, #model.undo_end)
  assert_true(#model.console_messages >= 1)
end)

test("capture registers optional atexit restoration and Apply disables it", function()
  local api_cancel, cancel_model = new_fake()
  local cancel_transaction = assert(state.Transaction.capture(api_cancel, 0))
  assert_equal(true, cancel_transaction:begin_preview_mutation())
  cancel_model.add_preview()
  assert_equal(true, cancel_transaction:end_preview_mutation())
  assert_true(type(cancel_model.atexit_callback) == "function")

  cancel_model.atexit_callback()
  assert_equal(false, cancel_transaction:is_active())
  assert_equal(1, cancel_model.deletes)
  assert_equal(1, #cancel_model.undo_end)
  assert_equal("LoopMaker: Cancel", cancel_model.undo_end[1].description)

  local api_apply, apply_model = new_fake()
  local apply_transaction = assert(state.Transaction.capture(api_apply, 0))
  local preview = apply_model.add_preview()
  assert_equal(true, apply_transaction:mark_applied())
  apply_model.atexit_callback()
  assert_equal(true, preview.valid)
  assert_equal(1, #apply_model.undo_end)
end)

test("mark_applied closes once and permanently forbids restoration", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local preview = model.add_preview()

  local applied, warnings = transaction:mark_applied()
  assert_equal(true, applied)
  assert_equal(0, #warnings)
  assert_equal(false, transaction:is_active())
  assert_equal(1, #model.undo_end)
  assert_equal("LoopMaker: Apply", model.undo_end[1].description)

  local applied_again, applied_reason = transaction:mark_applied()
  assert_equal(nil, applied_again)
  assert_contains(applied_reason, "applied")

  local restored, reason = transaction:restore()
  assert_equal(nil, restored)
  assert_contains(reason, "applied")
  assert_equal(true, preview.valid)
  assert_equal(1, #model.undo_end)
end)

test("atexit restores the open captured project in the background", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local item_a, item_b = model.initial_items[1], model.initial_items[2]
  assert_equal(true, transaction:begin_preview_mutation())
  model.add_preview()
  assert_equal(true, transaction:end_preview_mutation())
  item_a.chunk = "MUTATED"
  item_a.selected = false
  item_b.selected = true
  model.time_start, model.time_end, model.cursor = 20, 30, 25
  model.current_project = model.project_b

  model.atexit_callback()

  assert_equal(false, transaction:is_active())
  assert_equal(1, model.deletes)
  assert_equal("CHUNK A", item_a.chunk)
  assert_equal(true, item_a.selected)
  assert_equal(false, item_b.selected)
  assert_equal(2, model.time_start)
  assert_equal(7, model.time_end)
  assert_equal(4, model.cursor)
  assert_equal(1, #model.undo_end)
  assert_equal("LoopMaker: Cancel", model.undo_end[1].description)
  assert_equal(0, #model.console_messages)
end)

test("background atexit never stops active transport and leaves recovery active", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  transaction:mark_preview_playback_started()
  model.play_state = 1
  model.play_position = 22
  model.current_project = model.project_b
  local loop_writes = model.loop_set_calls

  model.atexit_callback()

  assert_equal(0, model.stop_calls)
  assert_equal(loop_writes, model.loop_set_calls)
  assert_equal(true, transaction.preview_playback_started)
  assert_equal(true, transaction:is_active())
  local messages = table.concat(model.console_messages, "\n")
  assert_contains(messages, "Stop playback/recording")
  assert_contains(messages, "manual Undo")
end)

test("foreground restore refuses active playback without any project writes", function()
  for _, play_state in ipairs({ 1, 2, 3, 4, 5, 6, 7 }) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    assert_equal(true, transaction:prepare_preview_range(20, 25))
    transaction:mark_preview_playback_started()
    model.play_state = play_state
    model.play_position = 22
    local deletes = model.deletes
    local chunks = model.chunk_writes
    local selection_writes = model.selection_writes
    local loop_writes = model.loop_set_calls
    local cursor_writes = model.cursor_set_calls
    local repeat_writes = model.repeat_set_calls

    local restored, reason = transaction:restore_for_rebuild()

    assert_equal(nil, restored)
    assert_contains(reason, "Stop playback/recording")
    assert_equal(0, model.stop_calls)
    assert_equal(deletes, model.deletes)
    assert_equal(chunks, model.chunk_writes)
    assert_equal(selection_writes, model.selection_writes)
    assert_equal(loop_writes, model.loop_set_calls)
    assert_equal(cursor_writes, model.cursor_set_calls)
    assert_equal(repeat_writes, model.repeat_set_calls)
    assert_true(transaction.preview_range_state ~= nil)
    assert_true(transaction:is_active())

    model.play_state = 0
    assert_equal(true, transaction:restore_for_rebuild())
  end
end)

test("atexit logs abandon warnings when the original project was closed", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.current_project = model.project_b
  model.open_projects = { model.project_b }

  model.atexit_callback()

  assert_equal(false, transaction:is_active())
  assert_equal(0, #model.undo_end)
  assert_true(#model.console_messages >= 1)
  assert_contains(table.concat(model.console_messages, "\n"), "closed")
end)

test("project switching prevents writes Apply and Cancel until safely abandoned", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.add_preview()
  model.current_project = model.project_b

  local restored, restore_reason = transaction:restore()
  assert_equal(nil, restored)
  assert_contains(restore_reason, "current project")
  assert_equal(0, model.deletes)
  assert_equal(0, #model.undo_end)
  assert_true(transaction:is_active())
  assert_equal(false, transaction:is_same_project())

  local applied, apply_reason = transaction:mark_applied()
  assert_equal(nil, applied)
  assert_contains(apply_reason, "current project")
  assert_equal(0, #model.undo_end)

  local abandoned, abandon_reason = transaction:abandon()
  assert_equal(true, abandoned)
  assert_equal(nil, abandon_reason)
  assert_equal(false, transaction:is_active())
  assert_equal(1, #model.undo_end)
  assert_equal("LoopMaker: Abandon", model.undo_end[1].description)
end)

test("abandon closes locally with a warning when the original project is closed", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.current_project = model.project_b
  model.open_projects = { model.project_b }

  local abandoned, warning = transaction:abandon()

  assert_equal(true, abandoned)
  assert_contains(warning, "closed")
  assert_equal(false, transaction:is_active())
  assert_equal(0, #model.undo_end)
end)

test("abandon ends Undo only while the captured project is current", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, model.project_a))

  local abandoned, reason = transaction:abandon()

  assert_equal(true, abandoned)
  assert_equal(nil, reason)
  assert_equal(false, transaction:is_active())
  assert_equal(1, #model.undo_end)
  assert_contains(model.undo_end[1].description, "Abandon")
end)

test("Undo_EndBlock2 throw keeps Cancel active and succeeds on retry", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.undo_end_failures = 1

  local restored, reason = transaction:restore()
  assert_equal(nil, restored)
  assert_contains(reason, "Undo_EndBlock2")
  assert_true(transaction:is_active())
  assert_equal(0, #model.undo_end)

  local retried, warnings = transaction:restore()
  assert_equal(true, retried)
  assert_equal(0, #warnings)
  assert_equal(false, transaction:is_active())
  assert_equal(1, #model.undo_end)
end)

-- Defensive fault injection: REAPER documents Undo_EndBlock2 as void, but false is rejected safely.
test("Undo_EndBlock2 false keeps Apply and abandon active for retry", function()
  local api_apply, apply_model = new_fake()
  local apply_transaction = assert(state.Transaction.capture(api_apply, 0))
  apply_model.undo_end_false_returns = 1
  local applied, apply_reason = apply_transaction:mark_applied()
  assert_equal(nil, applied)
  assert_contains(apply_reason, "false")
  assert_true(apply_transaction:is_active())
  assert_equal(true, apply_transaction:mark_applied())

  local api_abandon, abandon_model = new_fake()
  local abandon_transaction = assert(state.Transaction.capture(api_abandon, 0))
  abandon_model.undo_end_false_returns = 1
  local abandoned, abandon_reason = abandon_transaction:abandon()
  assert_equal(nil, abandoned)
  assert_contains(abandon_reason, "false")
  assert_true(abandon_transaction:is_active())
  assert_equal(true, abandon_transaction:abandon())
end)

test("invalid or GUID-mismatched selected originals are rebuilt without overwriting replacements", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local invalid = model.initial_items[1]
  local reincarnated = model.initial_items[3]
  table.remove(model.items, 1)
  invalid.valid = false
  reincarnated.guid = "{REPLACED}"

  local restored, warnings = transaction:restore_for_rebuild()

  assert_equal(true, restored)
  assert_equal(0, #warnings)
  assert_equal("{REPLACED}", reincarnated.guid)
  assert_equal(2, model.add_item_calls)
  assert_equal("{A}", transaction.captured.selected_items[1].item.guid)
  assert_equal("{C}", transaction.captured.selected_items[2].item.guid)
  assert_equal(0, model.ui_depth)
end)

test("restore balances UI refresh when a REAPER API call throws and remains retryable", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.initial_items[1].chunk = "MUTATED"
  model.throw_on = "SetItemStateChunk"

  local restored, reason = transaction:restore_for_rebuild()

  assert_equal(nil, restored)
  assert_contains(reason, "SetItemStateChunk")
  assert_equal(0, model.ui_depth)
  assert_equal(1, model.ui_calls[#model.ui_calls - 1])
  assert_equal(-1, model.ui_calls[#model.ui_calls])
  assert_true(transaction:is_active())

  model.throw_on = nil
  assert_equal(true, transaction:restore_for_rebuild())
  assert_equal("CHUNK A", model.initial_items[1].chunk)
end)

test("restore refuses unrelated active playback without ownership", function()
  local api, model = new_fake()
  model.play_state = 1
  local transaction = assert(state.Transaction.capture(api, 0))
  local writes = model.chunk_writes

  local restored, reason = transaction:restore_for_rebuild()

  assert_equal(nil, restored)
  assert_contains(reason, "Stop playback/recording")
  assert_equal(writes, model.chunk_writes)
  assert_equal(0, model.stop_calls)
  assert_true(transaction:is_active())
end)

test("Apply refuses every active transport state and is retryable", function()
  for _, play_state in ipairs({ 1, 2, 3, 4, 5, 6, 7 }) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    model.play_state = play_state

    local applied, reason = transaction:mark_applied()

    assert_equal(nil, applied)
    assert_contains(reason, "Stop playback/recording")
    assert_equal(0, model.stop_calls)
    assert_equal(0, #model.undo_end)
    assert_true(transaction:is_active())

    model.play_state = 0
    assert_equal(true, transaction:mark_applied())
  end
end)

test("atexit retries a transient Undo close through restore", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.undo_end_failures = 1

  model.atexit_callback()

  assert_equal(false, transaction:is_active())
  assert_equal(1, #model.undo_end)
  assert_equal("LoopMaker: Cancel", model.undo_end[1].description)
  assert_equal(false, table.concat(model.console_messages, "\n"):find("Abandon", 1, true) ~= nil)
end)

test("atexit retries a transient restore operation", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.initial_items[1].chunk = "MUTATED"
  model.throw_counts.SetItemStateChunk = 1

  model.atexit_callback()

  assert_equal(false, transaction:is_active())
  assert_equal("CHUNK A", model.initial_items[1].chunk)
  assert_equal(1, #model.undo_end)
  assert_equal("LoopMaker: Cancel", model.undo_end[1].description)
end)

test("atexit keeps an open failed transaction active with manual Undo guidance", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.initial_items[1].chunk = "MUTATED"
  model.throw_on = "SetItemStateChunk"

  model.atexit_callback()

  assert_true(transaction:is_active())
  assert_equal(0, #model.undo_end)
  local combined = table.concat(model.console_messages, "\n")
  assert_contains(combined, "SetItemStateChunk")
  assert_contains(combined, "manual Undo")
  assert_equal(false, combined:find("Abandon", 1, true) ~= nil)
end)

test("Undo begin and end occur exactly once for final Apply or Cancel", function()
  local api_cancel, cancel_model = new_fake()
  local cancel_transaction = assert(state.Transaction.capture(api_cancel, 0))
  assert_equal(true, cancel_transaction:restore_for_rebuild())
  assert_equal(true, cancel_transaction:restore_for_rebuild())
  assert_equal(true, cancel_transaction:restore())
  assert_equal(1, cancel_model.undo_begin)
  assert_equal(1, #cancel_model.undo_end)

  local api_apply, apply_model = new_fake()
  local apply_transaction = assert(state.Transaction.capture(api_apply, 0))
  assert_equal(true, apply_transaction:mark_applied())
  assert_equal(1, apply_model.undo_begin)
  assert_equal(1, #apply_model.undo_end)
end)

test("capture requires the project-specific repeat API", function()
  local api = new_fake()
  api.GetSetRepeatEx = nil

  local transaction, reason = state.Transaction.capture(api, 0)

  assert_equal(nil, transaction)
  assert_contains(reason, "GetSetRepeatEx")
end)

test("prepare and idempotent release preserve time selection loop cursor and repeat", function()
  for _, initial_repeat in ipairs({ 0, 1 }) do
    local api, model = new_fake()
    model.repeat_state = initial_repeat
    local transaction = assert(state.Transaction.capture(api, 0))

    assert_equal(true, transaction:prepare_preview_range(20, 25))
    assert_equal(2, model.time_start)
    assert_equal(7, model.time_end)
    assert_equal(20, model.loop_start)
    assert_equal(25, model.loop_end)
    assert_equal(20, model.cursor)
    assert_equal(1, model.repeat_state)

    assert_equal(true, transaction:release_preview_range())
    assert_equal(2, model.time_start)
    assert_equal(7, model.time_end)
    assert_equal(11, model.loop_start)
    assert_equal(13, model.loop_end)
    assert_equal(4, model.cursor)
    assert_equal(initial_repeat, model.repeat_state)

    local loop_writes = model.loop_set_calls
    local cursor_writes = model.cursor_set_calls
    local repeat_writes = model.repeat_set_calls
    assert_equal(true, transaction:release_preview_range())
    assert_equal(loop_writes, model.loop_set_calls)
    assert_equal(cursor_writes, model.cursor_set_calls)
    assert_equal(repeat_writes, model.repeat_set_calls)
  end
end)

test("prepare validates active same-project finite ranges before writing", function()
  local invalid_ranges = {
    { 5, 5 },
    { 6, 5 },
    { 0 / 0, 5 },
    { 1, math.huge },
  }
  for _, range in ipairs(invalid_ranges) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    local prepared, reason = transaction:prepare_preview_range(range[1], range[2])
    assert_equal(nil, prepared)
    assert_true(type(reason) == "string")
    assert_equal(0, model.loop_set_calls)
    assert_equal(0, model.cursor_set_calls)
    assert_equal(0, model.repeat_set_calls)
  end

  local api_switched, switched_model = new_fake()
  local switched = assert(state.Transaction.capture(api_switched, 0))
  switched_model.current_project = switched_model.project_b
  local prepared, reason = switched:prepare_preview_range(20, 25)
  assert_equal(nil, prepared)
  assert_contains(reason, "current project")
  assert_equal(0, switched_model.loop_set_calls)
  assert_equal(0, switched_model.cursor_set_calls)
  assert_equal(0, switched_model.repeat_set_calls)

  local api_closed, closed_model = new_fake()
  local closed = assert(state.Transaction.capture(api_closed, 0))
  assert_equal(true, closed:restore())
  local prepared_closed, closed_reason = closed:prepare_preview_range(20, 25)
  assert_equal(nil, prepared_closed)
  assert_contains(closed_reason, "cancelled")
end)

test("prepare failure rolls back every captured transport field and combines rollback errors", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local original_loop_range = api.GetSet_LoopTimeRange2
  local loop_writes = 0
  api.GetSet_LoopTimeRange2 = function(project, is_set, is_loop, start_time, end_time, allow_autoseek)
    if is_set and is_loop then
      loop_writes = loop_writes + 1
      if loop_writes == 2 then error("rollback loop exploded") end
    end
    return original_loop_range(project, is_set, is_loop, start_time, end_time, allow_autoseek)
  end
  local original_repeat = api.GetSetRepeatEx
  api.GetSetRepeatEx = function(project, value)
    if value > 0 then error("enable repeat exploded") end
    return original_repeat(project, value)
  end

  local prepared, reason = transaction:prepare_preview_range(20, 25)

  assert_equal(nil, prepared)
  assert_contains(reason, "enable repeat exploded")
  assert_contains(reason, "rollback loop exploded")
  assert_equal(4, model.cursor)
  assert_equal(0, model.repeat_state)
  assert_true(type(transaction.preview_range_state) == "table")

  api.GetSet_LoopTimeRange2 = original_loop_range
  api.GetSetRepeatEx = original_repeat
  assert_equal(true, transaction:release_preview_range())
  assert_equal(11, model.loop_start)
  assert_equal(13, model.loop_end)
  assert_equal(nil, transaction.preview_range_state)
end)

test("release refuses a switched project without writing either project", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  local loop_writes = model.loop_set_calls
  local cursor_writes = model.cursor_set_calls
  local repeat_writes = model.repeat_set_calls
  model.current_project = model.project_b

  local released, reason = transaction:release_preview_range()

  assert_equal(nil, released)
  assert_contains(reason, "current project")
  assert_equal(loop_writes, model.loop_set_calls)
  assert_equal(cursor_writes, model.cursor_set_calls)
  assert_equal(repeat_writes, model.repeat_set_calls)
  assert_equal(20, model.loop_start)
  assert_equal(25, model.loop_end)
  assert_equal(20, model.cursor)
end)

test("rebuild restore waits for explicit Preview stop before restoring range", function()
  for _, initial_repeat in ipairs({ 0, 1 }) do
    local api, model = new_fake()
    model.repeat_state = initial_repeat
    local transaction = assert(state.Transaction.capture(api, 0))
    assert_equal(true, transaction:prepare_preview_range(20, 25))
    assert_equal(true, transaction:mark_preview_playback_started())
    model.play_state = 1
    model.play_position = 22

    local restored, reason = transaction:restore_for_rebuild()
    assert_equal(nil, restored)
    assert_contains(reason, "Stop playback/recording")
    assert_equal(0, model.stop_calls)
    assert_equal(true, transaction.preview_playback_started)
    assert_true(transaction.preview_range_state ~= nil)

    model.play_state = 0
    assert_equal(true, transaction:restore_for_rebuild())
    assert_equal(false, transaction.preview_playback_started)
    assert_equal(nil, transaction.preview_range_state)
    assert_equal(11, model.loop_start)
    assert_equal(13, model.loop_end)
    assert_equal(4, model.cursor)
    assert_equal(initial_repeat, model.repeat_state)
  end
end)

test("Apply waits for stopped transport before releasing prepared range", function()
  local api, model = new_fake()
  model.repeat_state = 0
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  assert_equal(true, transaction:mark_preview_playback_started())
  model.play_state = 1
  model.play_position = 22

  local applied, reason = transaction:mark_applied()
  assert_equal(nil, applied)
  assert_contains(reason, "Stop playback/recording")
  assert_equal(0, model.stop_calls)
  assert_true(transaction.preview_range_state ~= nil)
  assert_true(transaction:is_active())

  model.play_state = 0
  assert_equal(true, transaction:mark_applied())
  assert_equal(11, model.loop_start)
  assert_equal(13, model.loop_end)
  assert_equal(4, model.cursor)
  assert_equal(0, model.repeat_state)
  assert_equal(nil, transaction.preview_range_state)
end)

test("release clears preview playback ownership", function()
  local api = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  assert_equal(true, transaction:mark_preview_playback_started())

  assert_equal(true, transaction:release_preview_range())

  assert_equal(false, transaction.preview_playback_started)
  assert_equal(false, transaction:owns_preview_playback())
end)

test("sync preview playback is a no-op without ownership", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  model.throw_on = "GetPlayStateEx"

  local changed, warnings = transaction:sync_preview_playback()

  assert_equal(false, changed)
  assert_equal(0, #warnings)
end)

test("sync releases preview range after an external stop", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  assert_equal(true, transaction:mark_preview_playback_started())
  model.play_state = 0

  local changed, warnings = transaction:sync_preview_playback()

  assert_equal(true, changed)
  assert_equal(0, #warnings)
  assert_equal(false, transaction:owns_preview_playback())
  assert_equal(nil, transaction.preview_range_state)
  assert_equal(11, model.loop_start)
  assert_equal(13, model.loop_end)
  assert_equal(4, model.cursor)
  assert_equal(0, model.repeat_state)
  assert_equal(0, model.stop_calls)
end)

test("sync preserves ownership marker and range while transport is active", function()
  for _, play_state in ipairs({ 1, 2, 3, 4, 5, 6, 7 }) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    assert_equal(true, transaction:prepare_preview_range(20, 25))
    assert_equal(true, transaction:mark_preview_playback_started())
    model.play_state = play_state
    local loop_writes = model.loop_set_calls
    local cursor_writes = model.cursor_set_calls
    local repeat_writes = model.repeat_set_calls

    local changed, status = transaction:sync_preview_playback()

    assert_equal(false, changed)
    assert_true(type(status) == "table")
    assert_equal(true, transaction.preview_playback_started)
    assert_true(transaction.preview_range_state ~= nil)
    assert_equal(0, model.stop_calls)
    assert_equal(loop_writes, model.loop_set_calls)
    assert_equal(cursor_writes, model.cursor_set_calls)
    assert_equal(repeat_writes, model.repeat_set_calls)
  end
end)

test("pending preview range releases only after transport becomes stopped", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  assert_equal(true, transaction:mark_preview_playback_started())
  model.play_state = 5

  local recording_changed = transaction:sync_preview_playback()
  assert_equal(false, recording_changed)
  assert_equal(true, transaction.preview_playback_started)
  assert_true(transaction.preview_range_state ~= nil)

  model.play_state = 0
  local released, warnings = transaction:sync_preview_playback()
  assert_equal(true, released)
  assert_equal(0, #warnings)
  assert_equal(false, transaction.preview_playback_started)
  assert_equal(nil, transaction.preview_range_state)
  assert_equal(11, model.loop_start)
  assert_equal(13, model.loop_end)
  assert_equal(4, model.cursor)
  assert_equal(0, model.repeat_state)
end)

test("recording blocks restore without changing Items or transport and remains retryable", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:begin_preview_mutation())
  local preview = model.add_preview("{PREVIEW-RECORDING}")
  assert_equal(true, transaction:end_preview_mutation())
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  assert_equal(true, transaction:mark_preview_playback_started())
  model.play_state = 5
  local deletes = model.deletes
  local chunks = model.chunk_writes
  local loop_writes = model.loop_set_calls
  local cursor_writes = model.cursor_set_calls
  local repeat_writes = model.repeat_set_calls

  local restored, reason = transaction:restore_for_rebuild()

  assert_equal(nil, restored)
  assert_contains(reason, "Stop playback/recording")
  assert_equal(true, preview.valid)
  assert_equal(deletes, model.deletes)
  assert_equal(chunks, model.chunk_writes)
  assert_equal(loop_writes, model.loop_set_calls)
  assert_equal(cursor_writes, model.cursor_set_calls)
  assert_equal(repeat_writes, model.repeat_set_calls)
  assert_true(transaction:is_active())
  assert_true(transaction.preview_range_state ~= nil)

  model.play_state = 0
  assert_equal(true, transaction:restore_for_rebuild())
  assert_equal(false, preview.valid)
  assert_equal(nil, transaction.preview_range_state)
end)

test("ownership requires live LoopMaker repeat loop and playback context", function()
  local cases = {
    {
      mutate = function(model) model.repeat_state = 0 end,
    },
    {
      mutate = function(model) model.loop_start, model.loop_end = 21, 26 end,
    },
    {
      mutate = function(model) model.play_state = 5 end,
    },
    {
      mutate = function(model) model.play_position = 30 end,
    },
  }

  for _, case in ipairs(cases) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    assert_equal(true, transaction:prepare_preview_range(20, 25))
    assert_equal(true, transaction:mark_preview_playback_started())
    model.play_state = 1
    model.play_position = 22
    case.mutate(model)

    assert_equal(false, transaction:owns_preview_playback())
    assert_equal(false, transaction.preview_playback_started)
    assert_equal(0, model.stop_calls)
  end
end)

test("ownership is unconfirmed when GetPlayPositionEx is unavailable", function()
  local api, model = new_fake()
  api.GetPlayPositionEx = nil
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  assert_equal(true, transaction:mark_preview_playback_started())
  model.play_state = 1

  local owns, reason = transaction:owns_preview_playback()

  assert_equal(nil, owns)
  assert_contains(reason, "GetPlayPositionEx")
  assert_equal(true, transaction.preview_playback_started)
  assert_equal(0, model.stop_calls)
end)

test("prepare rejects an ignored cursor setter and rolls back", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  local original = api.SetEditCurPos2
  api.SetEditCurPos2 = function(project, position, move_view, seek_play)
    if position == 20 then return end
    return original(project, position, move_view, seek_play)
  end

  local prepared, reason = transaction:prepare_preview_range(20, 25)

  assert_equal(nil, prepared)
  assert_contains(reason, "cursor")
  assert_equal(11, model.loop_start)
  assert_equal(13, model.loop_end)
  assert_equal(4, model.cursor)
  assert_equal(0, model.repeat_state)
  assert_equal(nil, transaction.preview_range_state)
end)

test("release detects ignored transport restore and preserves pending range", function()
  local api, model = new_fake()
  local transaction = assert(state.Transaction.capture(api, 0))
  assert_equal(true, transaction:prepare_preview_range(20, 25))
  local original = api.GetSetRepeatEx
  api.GetSetRepeatEx = function(project, value)
    if value == 0 then return model.repeat_state end
    return original(project, value)
  end

  local released, reason = transaction:release_preview_range()

  assert_equal(nil, released)
  assert_contains(reason, "repeat")
  assert_true(transaction.preview_range_state ~= nil)
  api.GetSetRepeatEx = original
  assert_equal(true, transaction:release_preview_range())
  assert_equal(nil, transaction.preview_range_state)
end)

test("global restore verifies every transport field and keeps retry state", function()
  local cases = {
    {
      marker = "time selection",
      disable = function(api, model)
        local original = api.GetSet_LoopTimeRange2
        api.GetSet_LoopTimeRange2 = function(project, is_set, is_loop,
            start_time, end_time, allow_autoseek)
          if is_set and not is_loop and start_time == 2 and end_time == 7 then
            return
          end
          return original(project, is_set, is_loop,
            start_time, end_time, allow_autoseek)
        end
        return function() api.GetSet_LoopTimeRange2 = original end
      end,
    },
    {
      marker = "loop points",
      disable = function(api, model)
        local original = api.GetSet_LoopTimeRange2
        api.GetSet_LoopTimeRange2 = function(project, is_set, is_loop,
            start_time, end_time, allow_autoseek)
          if is_set and is_loop and start_time == 11 and end_time == 13 then
            return
          end
          return original(project, is_set, is_loop,
            start_time, end_time, allow_autoseek)
        end
        return function() api.GetSet_LoopTimeRange2 = original end
      end,
    },
    {
      marker = "cursor",
      disable = function(api, model)
        local original = api.SetEditCurPos2
        api.SetEditCurPos2 = function(project, position, move_view, seek_play)
          if position == 4 then return end
          return original(project, position, move_view, seek_play)
        end
        return function() api.SetEditCurPos2 = original end
      end,
    },
    {
      marker = "repeat",
      disable = function(api, model)
        local original = api.GetSetRepeatEx
        api.GetSetRepeatEx = function(project, value)
          if value == 0 then return model.repeat_state end
          return original(project, value)
        end
        return function() api.GetSetRepeatEx = original end
      end,
    },
  }

  for index, case in ipairs(cases) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    assert_equal(true, transaction:begin_preview_mutation())
    local preview = model.add_preview("{RESTORE-" .. index .. "}")
    assert_equal(true, transaction:end_preview_mutation())
    assert_equal(true, transaction:prepare_preview_range(20, 25))
    model.time_start, model.time_end = 30, 40
    local enable = case.disable(api, model)

    local restored, reason = transaction:restore_for_rebuild()

    assert_equal(nil, restored)
    assert_contains(reason, case.marker)
    assert_true(transaction.preview_range_state ~= nil)
    assert_true(tracked_contains(transaction, preview, "{RESTORE-" .. index .. "}"))
    assert_true(transaction:is_active())

    enable()
    assert_equal(true, transaction:restore_for_rebuild())
    assert_equal(nil, transaction.preview_range_state)
    assert_equal(false, tracked_contains(transaction, preview, "{RESTORE-" .. index .. "}"))
  end
end)

test("prepare rejects loop points or repeat setters that do not take effect", function()
  local cases = {
    {
      marker = "loop points",
      disable_write = function(api)
        local original = api.GetSet_LoopTimeRange2
        api.GetSet_LoopTimeRange2 = function(project, is_set, is_loop,
            start_time, end_time, allow_autoseek)
          if is_set and is_loop and start_time == 20 and end_time == 25 then
            return false
          end
          return original(project, is_set, is_loop,
            start_time, end_time, allow_autoseek)
        end
      end,
    },
    {
      marker = "repeat",
      disable_write = function(api)
        local original = api.GetSetRepeatEx
        api.GetSetRepeatEx = function(project, value)
          if value > 0 then return end
          return original(project, value)
        end
      end,
    },
  }

  for _, case in ipairs(cases) do
    local api, model = new_fake()
    local transaction = assert(state.Transaction.capture(api, 0))
    case.disable_write(api)

    local prepared, reason = transaction:prepare_preview_range(20, 25)

    assert_equal(nil, prepared)
    assert_contains(reason, case.marker)
    assert_equal(11, model.loop_start)
    assert_equal(13, model.loop_end)
    assert_equal(4, model.cursor)
    assert_equal(0, model.repeat_state)
    assert_equal(nil, transaction.preview_range_state)
  end
end)

return true
