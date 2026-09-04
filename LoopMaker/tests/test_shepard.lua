local helper = require("tests.test_helper")
local shepard = require("lib.shepard")

local test = helper.test
local assert_equal = helper.assert_equal
local assert_true = helper.assert_true

local function assert_close(expected, actual, epsilon, message)
  assert_true(type(actual) == "number", message or "expected a number")
  assert_true(math.abs(expected - actual) <= (epsilon or 1e-9),
    message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)))
end

local function assert_contains(text, fragment)
  assert_true(type(text) == "string" and text:find(fragment, 1, true) ~= nil,
    "expected " .. tostring(text) .. " to contain " .. fragment)
end

local function snapshot(overrides)
  local value = {
    item = { id = "item" },
    take = { id = "take" },
    track = { id = "track" },
    position = 10,
    length = 8,
    start_offset = 2,
    playrate = 1,
    source_length = 30,
    name = "source.wav",
    chunk = "<ITEM\nIGUID {ITEM}\n<TAKE\nGUID {TAKE}\n<SOURCE WAVE\nFILE source.wav\n>\n>\n>\n",
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

test("build_plan creates 2 to the power of loops evenly phased lanes", function()
  local plan, reason = shepard.build_plan(snapshot(), {
    loops = 2,
    pitch = 12,
    cf_ratio = 0.1,
    cf_max = 0,
    cf_curve = 1,
  })

  assert_equal(nil, reason)
  assert_equal(4, plan.lane_count)
  assert_equal(4, #plan.lanes)
  assert_close(2, plan.loop_length)
  assert_close(0.2, plan.crossfade_length)
  assert_close(0, plan.lanes[1].source_offset)
  assert_close(2, plan.lanes[2].source_offset)
  assert_close(4, plan.lanes[3].source_offset)
  assert_close(6, plan.lanes[4].source_offset)
  assert_close(2, plan.lanes[1].length)
  assert_close(10, plan.lanes[1].position)
  assert_close(10, plan.lanes[2].position)
  assert_close(-4.5, plan.lanes[1].pitch_points[1].value)
  assert_close(-1.5, plan.lanes[1].pitch_points[2].value)
  assert_close(-1.5, plan.lanes[2].pitch_points[1].value)
  assert_close(1.5, plan.lanes[2].pitch_points[2].value)
end)

test("build_plan creates strictly timed upward and downward pitch ramps", function()
  local upward = assert(shepard.build_plan(snapshot(), { loops = 1, pitch = 7 }))
  local downward = assert(shepard.build_plan(snapshot(), { loops = 1, pitch = -5 }))

  for _, case in ipairs({
    { plan = upward, delta = 3.5 },
    { plan = downward, delta = -2.5 },
  }) do
    for _, lane in ipairs(case.plan.lanes) do
      assert_equal(2, #lane.pitch_points)
      assert_close(0, lane.pitch_points[1].time)
      assert_close(lane.length, lane.pitch_points[2].time)
      assert_true(lane.pitch_points[1].time < lane.pitch_points[2].time)
      assert_close(case.delta,
        lane.pitch_points[2].value - lane.pitch_points[1].value)
      assert_equal(0, lane.pitch_points[1].shape)
      assert_equal(0, lane.pitch_points[2].shape)
    end
  end
end)

test("build_plan phase layers join adjacent pitch ranges at one shared period", function()
  local plan = assert(shepard.build_plan(snapshot(), {
    loops = 3,
    pitch = 12,
    cf_ratio = 0.1,
    cf_curve = 4,
  }))

  assert_equal(8, plan.lane_count)
  assert_close(1, plan.loop_length)
  assert_close(0.1, plan.crossfade_length)
  for index, lane in ipairs(plan.lanes) do
    assert_equal(index - 1, lane.index)
    assert_equal(false, lane.wrap_source)
    assert_close(0, lane.fade_in)
    assert_close(0, lane.fade_out)
    assert_equal(4, lane.fade_shape)
    assert_close(1 / math.sqrt(8), lane.volume)
    if index < #plan.lanes then
      assert_close(lane.pitch_points[2].value,
        plan.lanes[index + 1].pitch_points[1].value)
    end
  end
  assert_close(12, plan.lanes[#plan.lanes].pitch_points[2].value
    - plan.lanes[1].pitch_points[1].value)
end)

test("build_plan rejects invalid snapshots and unsafe layer counts", function()
  for _, invalid in ipairs({
    snapshot({ length = 0 }),
    snapshot({ length = math.huge }),
    snapshot({ start_offset = -1 }),
    snapshot({ playrate = 0 }),
  }) do
    local plan, reason = shepard.build_plan(invalid, { loops = 1, pitch = 12 })
    assert_equal(nil, plan)
    assert_true(type(reason) == "string" and reason ~= "")
  end

  local too_many, reason = shepard.build_plan(snapshot(), {
    loops = 20,
    pitch = 12,
  })
  assert_equal(nil, too_many)
  assert_contains(reason, "layer")
end)

test("ensure_pitch_envelope inserts an empty PITCHENV into the active take", function()
  local item = { chunk = snapshot().chunk }
  local take = { item = item }
  item.take = take
  local set_calls = 0
  local envelope = { id = "pitch" }
  local api = {}

  function api.GetTakeEnvelopeByName(value, name)
    assert_equal(take, value)
    assert_equal("Pitch", name)
    if item.chunk:find("<PITCHENV", 1, true) then return envelope end
    return nil
  end
  function api.GetMediaItemTake_Item(value)
    assert_equal(take, value)
    return item
  end
  function api.GetItemStateChunk(value, _, is_undo)
    assert_equal(item, value)
    assert_equal(false, is_undo)
    return true, item.chunk
  end
  function api.SetItemStateChunk(value, chunk, is_undo)
    assert_equal(item, value)
    assert_equal(false, is_undo)
    set_calls = set_calls + 1
    item.chunk = chunk
    return true
  end
  function api.GetActiveTake(value)
    assert_equal(item, value)
    return take
  end

  local result, reason = shepard.ensure_pitch_envelope(api, take)
  assert_equal(nil, reason)
  assert_equal(envelope, result)
  assert_equal(1, set_calls)
  assert_contains(item.chunk, "<PITCHENV")
  assert_true(item.chunk:find("<PITCHENV", 1, true)
    < item.chunk:find("SOURCE WAVE", 1, true))
end)

test("apply_pitch_envelope replaces points and sorts once", function()
  local envelope = { id = "pitch" }
  local calls = {}
  local api = {}
  function api.DeleteEnvelopePointRange(value, start_time, end_time)
    assert_equal(envelope, value)
    calls[#calls + 1] = { "delete", start_time, end_time }
    return true
  end
  function api.InsertEnvelopePoint(value, time, pitch, shape, tension, selected, no_sort)
    assert_equal(envelope, value)
    calls[#calls + 1] = {
      "insert", time, pitch, shape, tension, selected, no_sort,
    }
    return true
  end
  function api.Envelope_SortPoints(value)
    assert_equal(envelope, value)
    calls[#calls + 1] = { "sort" }
    return true
  end

  local ok, reason = shepard.apply_pitch_envelope(api, envelope, {
    { time = 0, value = 0, shape = 0 },
    { time = 4, value = 12, shape = 0 },
  }, 4)
  assert_equal(nil, reason)
  assert_equal(true, ok)
  assert_equal("delete", calls[1][1])
  assert_close(-1e-9, calls[1][2])
  assert_close(4 + 1e-9, calls[1][3])
  assert_equal("insert", calls[2][1])
  assert_equal(true, calls[2][7])
  assert_equal("insert", calls[3][1])
  assert_equal(true, calls[3][7])
  assert_equal("sort", calls[4][1])
end)

local function shepard_apply_api(configuration)
  configuration = configuration or {}
  local model = {
    project = { id = "project" },
    track = { id = "track" },
    items = {},
    deleted = {},
    guid_index = 0,
    add_calls = 0,
    insert_calls = 0,
    selection_calls = 0,
  }
  local source_chunk = snapshot().chunk
  model.track.project = model.project
  local source_item = {
    id = "source",
    project = model.project,
    track = model.track,
    chunk = source_chunk,
    selected = true,
  }
  source_item.take = {
    item = source_item,
    D_VOL = 0.8,
    guid = "{TAKE}",
  }
  model.source_item = source_item
  model.source_take = source_item.take
  model.items[1] = source_item

  local api = {}

  function api.CountMediaItems(project)
    assert_equal(model.project, project)
    return #model.items
  end
  function api.GetMediaItem(project, index)
    assert_equal(model.project, project)
    return model.items[index + 1]
  end
  function api.SetMediaItemSelected(item, selected)
    model.selection_calls = model.selection_calls + 1
    if configuration.fail_select_at == model.selection_calls then return false end
    item.selected = selected
    return configuration.setters_void and nil or true
  end
  function api.IsMediaItemSelected(item)
    return item.selected == true
  end
  function api.ValidatePtr2(project, pointer, pointer_type)
    if pointer_type == "MediaItem*" then
      return pointer.project == project
    end
    if pointer_type == "MediaItem_Take*" then
      return pointer.item ~= nil and pointer.item.project == project
    end
    if pointer_type == "MediaTrack*" then
      return pointer.project == project
    end
    return false
  end
  function api.AddMediaItemToTrack(track)
    assert_equal(model.track, track)
    model.add_calls = model.add_calls + 1
    local item = {
      id = "clone " .. model.add_calls,
      project = track.project,
      track = track,
    }
    item.take = { item = item, D_VOL = 0.8 }
    model.items[#model.items + 1] = item
    return item
  end
  function api.genGuid()
    model.guid_index = model.guid_index + 1
    return "{S" .. model.guid_index .. "}"
  end
  function api.SetItemStateChunk(item, chunk, is_undo)
    assert_equal(false, is_undo)
    item.chunk = chunk
    local old_take = item.take or {}
    local take = { item = item }
    for key, value in pairs(old_take) do
      if key ~= "envelope" then take[key] = value end
    end
    take.guid = chunk:match("\n%s*GUID%s+(%b{})") or take.guid
    if item == source_item and chunk == source_chunk then
      take.D_VOL = 0.8
    end
    if chunk:find("<PITCHENV", 1, true) then
      take.envelope = { take = take, points = {} }
    end
    item.take = take
    return true
  end
  function api.GetActiveTake(item)
    return item.take
  end
  function api.SetMediaItemInfo_Value(item, key, value)
    item[key] = value
    return configuration.setters_void and nil or true
  end
  function api.SetMediaItemTakeInfo_Value(take, key, value)
    take[key] = value
    return configuration.setters_void and nil or true
  end
  function api.GetMediaItemTakeInfo_Value(take, key)
    return take[key]
  end
  function api.DeleteTrackMediaItem(track, item)
    assert_equal(model.track, track)
    model.deleted[#model.deleted + 1] = item
    for index, candidate in ipairs(model.items) do
      if candidate == item then
        table.remove(model.items, index)
        return true
      end
    end
    return false
  end
  function api.GetTakeEnvelopeByName(take, name)
    assert_equal("Pitch", name)
    return take.envelope
  end
  function api.GetMediaItemTake_Item(take)
    return take.item
  end
  function api.GetMediaItem_Track(item)
    return item.track
  end
  function api.GetItemStateChunk(item, _, is_undo)
    assert_equal(false, is_undo)
    return true, item.chunk
  end
  function api.GetSetMediaItemTakeInfo_String(take, key, value, set_new_value)
    if key == "GUID" and not set_new_value then
      return true, take.guid
    end
    if key == "P_NAME" and set_new_value then
      take.name = value
      return true, value
    end
    return false, ""
  end
  function api.DeleteEnvelopePointRange(envelope)
    envelope.points = {}
    return true
  end
  function api.InsertEnvelopePoint(envelope, time, pitch, shape, tension,
      selected, no_sort)
    model.insert_calls = model.insert_calls + 1
    if configuration.fail_insert_at == model.insert_calls then return false end
    envelope.points[#envelope.points + 1] = {
      time = time,
      value = pitch,
      shape = shape,
      tension = tension,
      selected = selected,
      no_sort = no_sort,
    }
    return true
  end
  function api.Envelope_SortPoints(envelope)
    envelope.sorted = true
    return true
  end

  return api, model
end

test("apply_plan layers items with source offsets pitch volume naming color and selection", function()
  local api, model = shepard_apply_api()
  local source = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = model.source_item.chunk,
  })
  local plan = assert(shepard.build_plan(source, {
    loops = 2,
    pitch = 12,
    prefix = "Shepard",
    separator = "_",
    number = true,
    start_number = 7,
    leading_zeros = 2,
    remove_ext = true,
    color_items = true,
  }))

  local outputs, warnings = shepard.apply_plan(api, { plan }, {
    project = model.project,
    color = 0x123456,
  })

  assert_equal(0, #warnings)
  assert_equal(1, #outputs)
  assert_equal(4, #outputs[1].items)
  assert_equal(model.source_item, outputs[1].items[1])
  assert_equal(3, model.add_calls)
  assert_equal(4, #model.items)
  assert_equal(outputs[1].takes[1], source.take)
  for index, item in ipairs(outputs[1].items) do
    local lane = plan.lanes[index]
    local take = outputs[1].takes[index]
    assert_equal(true, item.selected)
    assert_close(10, item.D_POSITION)
    assert_close(2, item.D_LENGTH)
    assert_equal(0, item.B_LOOPSRC)
    assert_equal(-1, item.D_FADEINLEN_AUTO)
    assert_equal(-1, item.D_FADEOUTLEN_AUTO)
    assert_close(2 + lane.source_offset, take.D_STARTOFFS)
    assert_close(1, take.D_PLAYRATE)
    assert_close(0.4, take.D_VOL)
    assert_equal("Shepard_source_07", take.name)
    assert_true(item.I_CUSTOMCOLOR ~= nil and item.I_CUSTOMCOLOR ~= 0)
    assert_equal(2, #take.envelope.points)
    assert_close(lane.pitch_points[1].value, take.envelope.points[1].value)
    assert_close(lane.pitch_points[2].value, take.envelope.points[2].value)
    assert_equal(true, take.envelope.sorted)
  end
end)

test("apply_plan restores the original and deletes current clones after envelope failure", function()
  local api, model = shepard_apply_api({ fail_insert_at = 3 })
  local original_chunk = model.source_item.chunk
  local source = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = original_chunk,
  })
  local plan = assert(shepard.build_plan(source, { loops = 1, pitch = 12 }))

  local outputs, reason, partial = shepard.apply_plan(api, { plan }, {
    project = model.project,
  })

  assert_equal(nil, outputs)
  assert_contains(reason, "Pitch envelope")
  assert_equal(0, #partial)
  assert_equal(1, #model.deleted)
  assert_equal(1, #model.items)
  assert_equal(original_chunk, model.source_item.chunk)
  assert_equal(model.source_item.take, source.take)
end)

test("apply_plan preflights required APIs before changing any item", function()
  local api, model = shepard_apply_api()
  api.GetMediaItemTakeInfo_Value = nil
  local source = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = model.source_item.chunk,
  })
  local plan = assert(shepard.build_plan(source, { loops = 1, pitch = 12 }))

  local outputs, reason, partial = shepard.apply_plan(api, { plan }, {
    project = model.project,
  })

  assert_equal(nil, outputs)
  assert_contains(reason, "GetMediaItemTakeInfo_Value")
  assert_equal(0, #partial)
  assert_equal(0, model.add_calls)
  assert_equal(source.chunk, model.source_item.chunk)
end)

test("plan_items assigns stable name indices and warns for non-octave pitch cycles", function()
  local first = snapshot({ name = "first.wav" })
  local second = snapshot({
    item = { id = "second item" },
    take = { id = "second take" },
    name = "second.wav",
  })
  local plans = assert(shepard.plan_items({ first, second }, {
    loops = 1,
    pitch = 7,
  }))

  assert_equal(0, plans[1].variation_index)
  assert_equal(1, plans[2].variation_index)
  assert_contains(plans[1].warning, "octave")
  assert_contains(plans[2].warning, "octave")
end)

test("ensure_pitch_envelope targets only the active take in a multi-take chunk", function()
  local original = table.concat({
    "<ITEM",
    "IGUID {ITEM}",
    "<TAKE",
    "GUID {FIRST}",
    "NAME first",
    "<SOURCE WAVE",
    "FILE first.wav",
    ">",
    ">",
    "<TAKE",
    "GUID {SECOND}",
    "NAME second",
    "<SOURCE WAVE",
    "FILE second.wav",
    ">",
    ">",
    ">",
    "",
  }, "\n")
  local item = { chunk = original }
  local take = { item = item, guid = "{SECOND}" }
  item.take = take
  local envelope = { id = "pitch" }
  local api = {}

  function api.GetSetMediaItemTakeInfo_String(value, key, _, set_new_value)
    assert_equal(take, value)
    assert_equal("GUID", key)
    assert_equal(false, set_new_value)
    return true, value.guid
  end
  function api.GetTakeEnvelopeByName(value, name)
    assert_equal(take, value)
    assert_equal("Pitch", name)
    local second_take = item.chunk:find("GUID {SECOND}", 1, true)
    local pitch = item.chunk:find("<PITCHENV", 1, true)
    if pitch and second_take and pitch > second_take then return envelope end
    return nil
  end
  function api.GetMediaItemTake_Item(value)
    assert_equal(take, value)
    return item
  end
  function api.GetItemStateChunk(value, _, is_undo)
    assert_equal(item, value)
    assert_equal(false, is_undo)
    return true, item.chunk
  end
  function api.SetItemStateChunk(value, chunk, is_undo)
    assert_equal(item, value)
    assert_equal(false, is_undo)
    item.chunk = chunk
    return true
  end
  function api.GetActiveTake(value)
    assert_equal(item, value)
    return take
  end

  local result, reason = shepard.ensure_pitch_envelope(api, take)
  assert_equal(nil, reason)
  assert_equal(envelope, result)
  local _, occurrences = item.chunk:gsub("<PITCHENV", "")
  assert_equal(1, occurrences)
  assert_true(item.chunk:find("GUID {FIRST}\nNAME first\n<SOURCE WAVE", 1, true) ~= nil)
  local pitch_position = item.chunk:find("<PITCHENV", 1, true)
  assert_true(pitch_position > item.chunk:find("GUID {SECOND}", 1, true))
  assert_true(pitch_position < item.chunk:find("SOURCE WAVE\nFILE second.wav", 1, true))
end)

test("apply_plan rolls back every earlier output when a later plan fails", function()
  local api, model = shepard_apply_api({ fail_insert_at = 5 })
  local first_chunk = model.source_item.chunk
  local second_chunk = first_chunk
    :gsub("{ITEM}", "{ITEM2}")
    :gsub("{TAKE}", "{TAKE2}")
    :gsub("source.wav", "second.wav")
  local second_item = {
    id = "source 2",
    project = model.project,
    track = model.track,
    chunk = second_chunk,
    selected = true,
  }
  second_item.take = {
    item = second_item,
    D_VOL = 0.6,
    guid = "{TAKE2}",
  }
  model.items[2] = second_item
  local first = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = first_chunk,
  })
  local second = snapshot({
    item = second_item,
    take = second_item.take,
    track = model.track,
    chunk = second_chunk,
    name = "second.wav",
  })
  local plans = assert(shepard.plan_items({ first, second }, {
    loops = 1,
    pitch = 12,
  }))

  local outputs, reason, partial = shepard.apply_plan(api, plans, {
    project = model.project,
  })

  assert_equal(nil, outputs)
  assert_contains(reason, "Pitch envelope")
  assert_equal(0, #partial)
  assert_equal(1, #model.deleted)
  assert_equal(2, #model.items)
  assert_equal(first_chunk, model.source_item.chunk)
  assert_equal(second_chunk, second_item.chunk)
  assert_equal(true, model.source_item.selected)
  assert_equal(true, second_item.selected)
end)

test("apply_plan rolls back geometry and selection when final selection fails", function()
  local api, model = shepard_apply_api({ fail_select_at = 3 })
  local original_chunk = model.source_item.chunk
  local source = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = original_chunk,
  })
  local plan = assert(shepard.build_plan(source, { loops = 1, pitch = 12 }))

  local outputs, reason, partial = shepard.apply_plan(api, { plan }, {
    project = model.project,
  })

  assert_equal(nil, outputs)
  assert_contains(reason, "select Shepard outputs")
  assert_equal(0, #partial)
  assert_equal(1, #model.items)
  assert_equal(original_chunk, model.source_item.chunk)
  assert_equal(true, model.source_item.selected)
end)

test("apply_plan rejects duplicate source items before mutation", function()
  local api, model = shepard_apply_api()
  local first = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = model.source_item.chunk,
  })
  local second = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = model.source_item.chunk,
    name = "alias.wav",
  })
  local first_plan = assert(shepard.build_plan(first, { loops = 1, pitch = 12 }))
  local second_plan = assert(shepard.build_plan(second, { loops = 1, pitch = 12 }))

  local outputs, reason, partial = shepard.apply_plan(api,
    { first_plan, second_plan }, { project = model.project })

  assert_equal(nil, outputs)
  assert_contains(reason, "duplicate source item")
  assert_equal(0, #partial)
  assert_equal(0, model.add_calls)
  assert_equal(first.chunk, model.source_item.chunk)
end)

test("apply_plan rejects mismatched item take and track relationships", function()
  local api, model = shepard_apply_api()
  local other_track = { id = "other track", project = model.project }
  local other_item = {
    id = "other item",
    project = model.project,
    track = other_track,
    chunk = model.source_item.chunk,
    selected = false,
  }
  other_item.take = {
    item = other_item,
    D_VOL = 1,
    guid = "{OTHER}",
  }
  model.items[2] = other_item

  local wrong_take = snapshot({
    item = model.source_item,
    take = other_item.take,
    track = model.track,
    chunk = model.source_item.chunk,
  })
  local outputs, reason, partial = shepard.apply_plan(api,
    { assert(shepard.build_plan(wrong_take, { loops = 1, pitch = 12 })) },
    { project = model.project })
  assert_equal(nil, outputs)
  assert_contains(reason, "take does not belong to its source item")
  assert_equal(0, #partial)
  assert_equal(0, model.add_calls)

  local wrong_track = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = other_track,
    chunk = model.source_item.chunk,
  })
  outputs, reason, partial = shepard.apply_plan(api,
    { assert(shepard.build_plan(wrong_track, { loops = 1, pitch = 12 })) },
    { project = model.project })
  assert_equal(nil, outputs)
  assert_contains(reason, "item does not belong to its source track")
  assert_equal(0, #partial)
  assert_equal(0, model.add_calls)
end)

test("apply_plan rejects source pointers from a different project", function()
  local api, model = shepard_apply_api()
  local foreign_project = { id = "foreign" }
  model.source_item.project = foreign_project
  model.track.project = foreign_project
  local source = snapshot({
    item = model.source_item,
    take = model.source_take,
    track = model.track,
    chunk = model.source_item.chunk,
  })
  local plan = assert(shepard.build_plan(source, { loops = 1, pitch = 12 }))

  local outputs, reason, partial = shepard.apply_plan(api, { plan }, {
    project = model.project,
  })

  assert_equal(nil, outputs)
  assert_contains(reason, "does not belong to the target project")
  assert_equal(0, #partial)
  assert_equal(0, model.add_calls)
end)
