local helper = require("tests.test_helper")
local app_module = require("lib.app")
local state_module = require("lib.state")

local function fake_environment(snapshot_count, config)
  config = config or {}
  if config.time_start == nil then config.time_start = 1 end
  if config.time_end == nil then config.time_end = 4 end

  local calls = {}
  local observations = {}
  local restore_count = 0
  config.baseline_time_start = config.time_start
  config.baseline_time_end = config.time_end
  local tx = {
    active = true,
    same_project = true,
    preview_playback_started = false,
    preview_range_state = nil,
    preview_mutation_active = false,
    captured = { project = "captured-project" },
  }
  local function stop_owned_preview(transaction)
    local play_state = config.play_state or 0
    if transaction.preview_playback_started
        and (play_state & 0x3) ~= 0
        and (play_state & 0x4) == 0 then
      calls[#calls + 1] = "stop:captured-project"
      config.play_state = 0
    end
  end
  function tx:restore_for_rebuild()
    calls[#calls + 1] = "restore"
    restore_count = restore_count + 1
    if config.restore_error then error(config.restore_error) end
    if config.restore_reason then return nil, config.restore_reason end
    self.preview_playback_started = false
    self.preview_range_state = nil
    config.mutated = false
    config.time_start = config.baseline_time_start
    config.time_end = config.baseline_time_end
    if type(config.restore_warning_sequence) == "table" then
      return true, config.restore_warning_sequence[restore_count] or {}
    end
    return true, config.restore_warnings or {}
  end
  function tx:is_active()
    return self.active
  end
  function tx:mark_applied()
    calls[#calls + 1] = "apply"
    if config.apply_commit_error then error(config.apply_commit_error) end
    if config.apply_commit_reason then return nil, config.apply_commit_reason end
    self.preview_playback_started = false
    self.preview_range_state = nil
    self.active = false
    return true, {}
  end
  function tx:restore()
    calls[#calls + 1] = "cancel"
    self.preview_playback_started = false
    self.preview_range_state = nil
    self.active = false
    config.time_start = config.baseline_time_start
    config.time_end = config.baseline_time_end
    return true, {}
  end
  function tx:restore_in_background()
    calls[#calls + 1] = "cancel background"
    self.preview_playback_started = false
    self.preview_range_state = nil
    self.active = false
    return true, {}
  end
  function tx:is_same_project()
    return self.same_project
  end
  function tx:is_recording()
    calls[#calls + 1] = "check recording"
    if config.recording_check_error then error(config.recording_check_error) end
    return ((config.play_state or 0) & 0x4) ~= 0
  end
  function tx:begin_preview_mutation()
    calls[#calls + 1] = "begin mutation"
    if config.begin_mutation_error then error(config.begin_mutation_error) end
    if config.begin_mutation_reason then return nil, config.begin_mutation_reason end
    if self.preview_mutation_active then return nil, "preview mutation is already active" end
    self.preview_mutation_active = true
    return true
  end
  function tx:end_preview_mutation()
    calls[#calls + 1] = "end mutation"
    self.preview_mutation_active = false
    if config.end_mutation_error then error(config.end_mutation_error) end
    if config.end_mutation_reason then return nil, config.end_mutation_reason end
    return true
  end
  function tx:prepare_preview_range(start_time, end_time)
    calls[#calls + 1] = "prepare preview"
    observations.preview_start = start_time
    observations.preview_end = end_time
    if config.prepare_error then error(config.prepare_error) end
    if config.prepare_reason then return nil, config.prepare_reason end
    self.preview_range_state = { start = start_time, finish = end_time }
    return true
  end
  function tx:release_preview_range()
    calls[#calls + 1] = "release preview"
    if config.release_error then error(config.release_error) end
    if config.release_reason then return nil, config.release_reason end
    self.preview_range_state = nil
    self.preview_playback_started = false
    return true
  end
  function tx:owns_preview_playback()
    calls[#calls + 1] = "check preview ownership"
    if config.ownership_reason then return nil, config.ownership_reason end
    if config.owns_preview ~= nil then return config.owns_preview end
    return self.preview_playback_started == true
  end
  function tx:sync_preview_playback()
    calls[#calls + 1] = "sync preview"
    if config.sync_error then error(config.sync_error) end
    if config.sync_reason then return nil, config.sync_reason end
    local play_state = config.play_state or 0
    if play_state ~= 0 then
      return false, { state = play_state }
    end
    if self.preview_range_state ~= nil then
      local released, reason = self:release_preview_range()
      if not released then return nil, reason end
      return true, {}
    end
    if not self.preview_playback_started then return false, {} end
    return false, {}
  end
  function tx:mark_preview_playback_started()
    calls[#calls + 1] = "marked playback"
    if config.mark_error then error(config.mark_error) end
    if config.mark_reason then return nil, config.mark_reason end
    self.preview_playback_started = true
    return true
  end

  local snapshots = {}
  local explicit_sample_rates = type(config.snapshot_sample_rates) == "table"
  for index = 1, snapshot_count or 1 do
    local sample_rate
    if explicit_sample_rates then
      sample_rate = config.snapshot_sample_rates[index]
    elseif config.snapshot_sample_rate ~= nil then
      sample_rate = config.snapshot_sample_rate
    else
      sample_rate = 48000
    end
    snapshots[index] = {
      id = index,
      name = "source-" .. index,
      sample_rate = sample_rate,
    }
  end

  local planned = { {
    normal = true,
    stage = "planned",
    source_snapshot = snapshots[1],
    variation_index = 0,
    boundary_anchor = 1.25,
    source_end = 4,
  } }
  local analyzed = { {
    normal = true,
    stage = "analyzed",
    source_snapshot = snapshots[1],
    variation_index = 0,
    boundary_anchor = 1.5,
    source_end = 4,
    output_position = 8,
    loop_length = 2,
  } }
  local expanded = {
    {
      normal = true,
      stage = "expanded",
      sequence_index = 0,
      output_position = 1,
      loop_length = 1.5,
    },
    {
      normal = true,
      stage = "expanded",
      sequence_index = 1,
      output_position = 2.5,
      loop_length = 1.5,
    },
  }
  local fill_summary = {
    variation_count = 1,
    source_count = snapshot_count or 1,
    slot_count = 2,
    slot_samples = 72000,
    slot_length = 1.5,
    start = 1,
    ["end"] = 4,
  }
  observations.planned = planned
  observations.analyzed = analyzed
  observations.expanded = expanded
  observations.fill_summary = fill_summary

  local dependencies = {
    state = {
      Transaction = {
        capture = function(_, project)
          calls[#calls + 1] = "capture:" .. tostring(project)
          return tx
        end,
      },
    },
    loop_builder = {
      snapshot_selected = function(_, project)
        calls[#calls + 1] = "snapshot:" .. tostring(project)
        observations.snapshot_saw_mutation = config.mutated == true
        return snapshots
      end,
      plan_loops = function(received, settings, time_selection)
        calls[#calls + 1] = "plan normal"
        if config.plan_error then error(config.plan_error) end
        if config.plan_reason then return nil, config.plan_reason end
        helper.assert_equal(snapshots, received)
        helper.assert_equal(nil, time_selection)
        planned[1].settings = settings
        return planned
      end,
      analyze_plans = function(_, plans)
        calls[#calls + 1] = "analyze"
        if config.analyze_error then error(config.analyze_error) end
        if config.analyze_reason then return nil, config.analyze_reason end
        helper.assert_equal(planned, plans)
        return analyzed
      end,
      fill_time_selection = function(plans, time_selection, sample_rate, settings)
        calls[#calls + 1] = "fill"
        if config.fill_error then error(config.fill_error) end
        observations.fill_plans = plans
        observations.time_selection = time_selection
        observations.sample_rate = sample_rate
        observations.fill_settings = settings
        if config.fill_reason then return nil, config.fill_reason end
        return expanded, fill_summary
      end,
      apply_plan = function(_, plans)
        calls[#calls + 1] = "build normal"
        observations.applied_plans = plans
        if config.normal_apply_error then
          config.mutated = true
          error(config.normal_apply_error)
        end
        if config.normal_apply_reason then
          config.mutated = true
          return nil, config.normal_apply_reason,
            config.normal_partial_outputs or { { partial = "normal" } }
        end
        return { { main = "normal", items = { "normal" }, plan = plans[1] } },
          { "normal warning" }
      end,
      glue_outputs = function(_, project, outputs)
        calls[#calls + 1] = "glue:" .. tostring(project)
        if config.glue_error then
          config.mutated = true
          error(config.glue_error)
        end
        if config.glue_reason then
          config.mutated = true
          return nil, config.glue_reason,
            config.glue_partial_outputs or { { partial = "glue" } }
        end
        return outputs
      end,
    },
    shepard = {
      plan_items = function(received, settings)
        calls[#calls + 1] = "plan shepard"
        if config.shepard_plan_error then error(config.shepard_plan_error) end
        if config.shepard_plan_reason then
          return nil, config.shepard_plan_reason
        end
        helper.assert_equal(snapshots, received)
        return { { shepard = true, settings = settings } }
      end,
      apply_plan = function(_, plans)
        calls[#calls + 1] = "build shepard"
        if config.shepard_apply_error then
          config.mutated = true
          error(config.shepard_apply_error)
        end
        if config.shepard_apply_reason then
          config.mutated = true
          return nil, config.shepard_apply_reason,
            config.shepard_partial_outputs or { { partial = "shepard" } }
        end
        return { { main = "shepard", items = { "shepard" }, plan = plans[1] } },
          { "shepard warning" }
      end,
    },
  }

  local api = {
    GetSet_LoopTimeRange2 = function(received, is_set, is_loop, start_time, end_time)
      if is_set then
        if is_loop then return end
        calls[#calls + 1] = "set time selection"
        observations.time_selection_write = {
          start = start_time,
          finish = end_time,
        }
        config.time_start = start_time
        config.time_end = end_time
        return config.time_start, config.time_end
      end
      calls[#calls + 1] = "read time selection"
      return config.time_start, config.time_end
    end,
    UpdateArrange = function()
      calls[#calls + 1] = "arrange"
    end,
    GetPlayStateEx = function()
      if config.play_state_error then error(config.play_state_error) end
      return config.play_state or 0
    end,
    OnPlayButtonEx = function(project)
      calls[#calls + 1] = "play:" .. tostring(project)
      if config.play_error then error(config.play_error) end
      config.play_state = 1
    end,
    OnStopButtonEx = function(project)
      calls[#calls + 1] = "stop:" .. tostring(project)
      if config.stop_error then error(config.stop_error) end
      config.play_state = 0
    end,
  }
  if config.project_rate ~= nil or config.project_rate_error
      or config.project_rate_use ~= nil or config.project_rate_use_error then
    api.GetSetProjectInfo = function(project, key, value, set_new_value)
      helper.assert_equal("captured-project", project)
      helper.assert_equal(0, value)
      helper.assert_equal(false, set_new_value)
      if key == "PROJECT_SRATE_USE" then
        calls[#calls + 1] = "project rate use"
        if config.project_rate_use_error then
          error(config.project_rate_use_error)
        end
        if config.project_rate_use ~= nil then
          return config.project_rate_use
        end
        return 1
      end
      helper.assert_equal("PROJECT_SRATE", key)
      calls[#calls + 1] = "project rate"
      if config.project_rate_error then error(config.project_rate_error) end
      return config.project_rate
    end
  end
  if config.device_rate ~= nil or config.device_rate_error
      or config.device_retval ~= nil then
    api.GetAudioDeviceInfo = function(key)
      calls[#calls + 1] = "device rate"
      helper.assert_equal("SRATE", key)
      if config.device_rate_error then error(config.device_rate_error) end
      local retval = config.device_retval
      if retval == nil then retval = true end
      return retval, config.device_rate
    end
  end

  return api, dependencies, tx, calls, observations, config
end

local function count_call(calls, target)
  local count = 0
  for _, value in ipairs(calls) do
    if value == target then count = count + 1 end
  end
  return count
end

local function call_index(calls, target)
  for index, value in ipairs(calls) do
    if value == target then return index end
  end
  return nil
end

local function last_call_index(calls, target)
  local found
  for index, value in ipairs(calls) do
    if value == target then found = index end
  end
  return found
end

helper.test("app start rejects every active transport state before capture", function()
  for _, play_state in ipairs({ 1, 2, 3, 4, 5, 6, 7 }) do
    local api, dependencies, _, calls = fake_environment(1, {
      play_state = play_state,
    })
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })

    local started, reason = app:start()

    helper.assert_equal(nil, started)
    helper.assert_equal(
      "Stop playback/recording before starting LoopMaker", reason)
    helper.assert_equal(nil, app.transaction)
    helper.assert_equal(0, count_call(calls, "capture:0"))
    helper.assert_equal(0, count_call(calls, "begin mutation"))
    helper.assert_equal(0, count_call(calls, "build normal"))
  end
end)

helper.test("app start fails closed when playback state cannot be read", function()
  local cases = {
    {
      configure = function(api) api.GetPlayStateEx = nil end,
      expected = "GetPlayStateEx",
    },
    {
      config = { play_state_error = "transport exploded" },
      expected = "transport exploded",
    },
    {
      configure = function(api)
        api.GetPlayStateEx = function() return "playing" end
      end,
      expected = "invalid playback state",
    },
  }
  for _, case in ipairs(cases) do
    local api, dependencies, _, calls = fake_environment(1, case.config)
    if case.configure then case.configure(api) end
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })

    local started, reason = app:start()

    helper.assert_equal(nil, started)
    helper.assert_true(type(reason) == "string"
      and reason:find(case.expected, 1, true) ~= nil)
    helper.assert_equal(nil, app.transaction)
    helper.assert_equal(0, count_call(calls, "capture:0"))
  end
end)

helper.test("app start captures one transaction and builds a normal preview", function()
  local api, dependencies, _, calls, observed = fake_environment(2)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  local started = app:start()

  helper.assert_true(started)
  helper.assert_equal(2, app.model.selected_audio_count)
  helper.assert_equal("normal", app.outputs[1].main)
  helper.assert_equal("normal warning", app.model.warnings[1])
  helper.assert_equal(1, count_call(calls, "capture:0"))
  helper.assert_equal(1, count_call(calls, "snapshot:captured-project"))
  helper.assert_equal(0, count_call(calls, "restore"))
  helper.assert_equal(1, count_call(calls, "plan normal"))
  helper.assert_equal(1, count_call(calls, "analyze"))
  helper.assert_equal(1, count_call(calls, "fill"))
  helper.assert_true(call_index(calls, "snapshot:captured-project")
    < call_index(calls, "plan normal"))
  helper.assert_true(call_index(calls, "plan normal")
    < call_index(calls, "analyze"))
  helper.assert_true(call_index(calls, "analyze") < call_index(calls, "fill"))
  helper.assert_true(call_index(calls, "fill") < call_index(calls, "build normal"))
  helper.assert_equal(observed.analyzed, observed.fill_plans)
  helper.assert_equal(observed.expanded, observed.applied_plans)
  helper.assert_equal(1, observed.time_selection.start)
  helper.assert_equal(4, observed.time_selection.finish)
  helper.assert_equal(app.model.settings, observed.fill_settings)
  helper.assert_equal(48000, observed.sample_rate)
  helper.assert_equal(observed.fill_summary, app.model.timeline_fill)
  helper.assert_equal(1, #app.model.zero_crossings)
  helper.assert_equal(1.5, app.model.zero_crossings[1].start_time)
  helper.assert_equal(4, app.model.zero_crossings[1].end_time)
end)

helper.test("normal mode without a time selection skips fill and clears its summary", function()
  local api, dependencies, _, calls, observed = fake_environment(1, {
    time_start = 0,
    time_end = 0,
    project_rate = 96000,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(0, count_call(calls, "fill"))
  helper.assert_equal(0, count_call(calls, "project rate"))
  helper.assert_equal(observed.analyzed, observed.applied_plans)
  helper.assert_equal(nil, app.model.timeline_fill)
end)

helper.test("initial rebuild does not rewrite the captured time selection", function()
  local api, dependencies, _, calls, observed = fake_environment(1)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(0, count_call(calls, "set time selection"))
  helper.assert_equal(nil, observed.time_selection_write)
end)

helper.test("dirty rebuild re-reads the user's current time selection before fill", function()
  local api, dependencies, _, calls, observed, config = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    debounce_seconds = 0.1,
  })
  helper.assert_true(app:start())

  config.time_start = 10
  config.time_end = 20
  helper.assert_true(app:set_setting("loops", 3, 10))
  helper.assert_true(app:tick(10.1))

  helper.assert_equal(1, count_call(calls, "restore"))
  helper.assert_equal(2, count_call(calls, "fill"))
  helper.assert_equal(10, observed.time_selection.start)
  helper.assert_equal(20, observed.time_selection.finish)
  local write = observed.time_selection_write
  helper.assert_true(type(write) == "table", "time selection was not written back")
  helper.assert_equal(10, write.start)
  helper.assert_equal(20, write.finish)
  helper.assert_true(call_index(calls, "restore")
    < call_index(calls, "set time selection"))
  helper.assert_true(call_index(calls, "set time selection")
    < last_call_index(calls, "fill"))
end)

helper.test("cancel after a dirty rebuild restores the captured startup time selection", function()
  local api, dependencies, _, calls, observed, config = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    debounce_seconds = 0.1,
  })
  helper.assert_true(app:start())

  config.time_start = 10
  config.time_end = 20
  helper.assert_true(app:set_setting("loops", 2, 10))
  helper.assert_true(app:tick(10.1))
  helper.assert_equal(10, config.time_start)
  helper.assert_equal(20, config.time_end)

  helper.assert_true(app:cancel())
  helper.assert_equal(1, config.time_start)
  helper.assert_equal(4, config.time_end)
end)

helper.test("dirty rebuild writes back an empty selection and skips fill when the user clears it", function()
  local api, dependencies, _, calls, observed, config = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    debounce_seconds = 0.1,
  })
  helper.assert_true(app:start())
  helper.assert_equal(1, count_call(calls, "fill"))

  config.time_start = 20
  config.time_end = 10
  helper.assert_true(app:set_setting("loops", 2, 10))
  helper.assert_true(app:tick(10.1))

  helper.assert_equal(1, count_call(calls, "fill"))
  helper.assert_equal(nil, app.model.timeline_fill)
  local write = observed.time_selection_write
  helper.assert_true(type(write) == "table", "time selection was not written back")
  helper.assert_equal(0, write.start)
  helper.assert_equal(0, write.finish)
end)

helper.test("enabled valid project sample rate is the active timeline rate", function()
  local api, dependencies, _, calls, observed = fake_environment(1, {
    project_rate_use = 1,
    project_rate = 96000,
    device_rate = "48000",
    snapshot_sample_rate = 44100,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(1, count_call(calls, "project rate use"))
  helper.assert_equal(1, count_call(calls, "project rate"))
  helper.assert_equal(0, count_call(calls, "device rate"))
  helper.assert_equal(96000, observed.sample_rate)
end)

helper.test("disabled project sample rate is ignored in favor of device rate", function()
  local api, dependencies, _, calls, observed = fake_environment(1, {
    project_rate_use = 0,
    project_rate = 192000,
    device_rate = "48000",
    snapshot_sample_rate = 44100,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(1, count_call(calls, "project rate use"))
  helper.assert_equal(0, count_call(calls, "project rate"))
  helper.assert_equal(1, count_call(calls, "device rate"))
  helper.assert_equal(48000, observed.sample_rate)
end)

helper.test("missing project API still uses a valid device sample rate", function()
  local api, dependencies, _, calls, observed = fake_environment(1, {
    device_rate = "88200",
    snapshot_sample_rate = 44100,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(0, count_call(calls, "project rate use"))
  helper.assert_equal(1, count_call(calls, "device rate"))
  helper.assert_equal(88200, observed.sample_rate)
end)

helper.test("device failures fall back to consistent snapshot sample rates", function()
  local cases = {
    { device_retval = false, device_rate = "96000" },
    { device_rate = "not-a-rate" },
    { device_rate = "10000001" },
    { device_rate_error = "device unavailable" },
  }
  for _, config in ipairs(cases) do
    config.project_rate_use = 0
    config.project_rate = 192000
    config.snapshot_sample_rates = { 44100, 44100 }
    local api, dependencies, _, calls, observed = fake_environment(2, config)
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })

    helper.assert_true(app:start())

    helper.assert_equal(0, count_call(calls, "project rate"))
    helper.assert_equal(1, count_call(calls, "device rate"))
    helper.assert_equal(44100, observed.sample_rate)
  end
end)

helper.test("missing rate APIs fall back to consistent snapshot sample rates", function()
  local api, dependencies, _, calls, observed = fake_environment(2, {
    snapshot_sample_rates = { 32000, 32000 },
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(0, count_call(calls, "project rate use"))
  helper.assert_equal(0, count_call(calls, "device rate"))
  helper.assert_equal(32000, observed.sample_rate)
end)

helper.test("valid project sample rate ignores unavailable snapshot rates", function()
  local api, dependencies, _, calls, observed = fake_environment(2, {
    project_rate = 96000,
    snapshot_sample_rates = { 0 },
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(96000, observed.sample_rate)
  helper.assert_equal(1, count_call(calls, "fill"))
  helper.assert_equal(1, count_call(calls, "build normal"))
end)

helper.test("no time selection does not require snapshot sample rates", function()
  local api, dependencies, _, calls = fake_environment(1, {
    time_start = 0,
    time_end = 0,
    snapshot_sample_rates = {},
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(0, count_call(calls, "project rate use"))
  helper.assert_equal(0, count_call(calls, "project rate"))
  helper.assert_equal(0, count_call(calls, "device rate"))
  helper.assert_equal(0, count_call(calls, "fill"))
  helper.assert_equal(1, count_call(calls, "build normal"))
end)

helper.test("Shepard mode does not require snapshot sample rates", function()
  local api, dependencies, _, calls = fake_environment(1, {
    snapshot_sample_rates = { 0 },
  })
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    settings = { shepard = true },
  })

  helper.assert_true(app:start())

  helper.assert_equal(0, count_call(calls, "project rate use"))
  helper.assert_equal(0, count_call(calls, "project rate"))
  helper.assert_equal(0, count_call(calls, "device rate"))
  helper.assert_equal(0, count_call(calls, "fill"))
  helper.assert_equal(1, count_call(calls, "build shepard"))
end)

helper.test("zero project sample rate falls back to the snapshot sample rate", function()
  local api, dependencies, _, calls, observed = fake_environment(1, {
    project_rate = 0,
    snapshot_sample_rate = 44100,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(1, count_call(calls, "project rate"))
  helper.assert_equal(44100, observed.sample_rate)
end)

helper.test("invalid and unavailable project rates fall back to snapshots", function()
  for _, config in ipairs({
    { project_rate = 48000.5, snapshot_sample_rate = 32000 },
    { project_rate_error = "rate unavailable", snapshot_sample_rate = 22050 },
  }) do
    local api, dependencies, _, _, observed = fake_environment(1, config)
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })

    helper.assert_true(app:start())
    helper.assert_equal(config.snapshot_sample_rate, observed.sample_rate)
  end
end)

helper.test("mixed snapshot sample rates fail before apply mutation", function()
  local api, dependencies, _, calls = fake_environment(2, {
    project_rate = 0,
    snapshot_sample_rates = { 44100, 48000 },
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  local started, reason = app:start()

  helper.assert_equal(nil, started)
  helper.assert_true(type(reason) == "string"
    and reason:find("sample rate", 1, true) ~= nil
    and reason:find("mixed", 1, true) ~= nil)
  helper.assert_equal(0, count_call(calls, "fill"))
  helper.assert_equal(0, count_call(calls, "build normal"))
  helper.assert_equal(false, app.has_preview)
  helper.assert_equal(0, #app.outputs)
  helper.assert_equal(nil, app.model.timeline_fill)
end)

helper.test("snapshot fallback rejects every missing or invalid sample rate before apply", function()
  local cases = {
    {
      rates = { [1] = 44100 },
      category = "missing",
    },
    {
      rates = { 44100, 0 },
      category = "invalid",
    },
    {
      rates = { 44100, 0 / 0 },
      category = "invalid",
    },
    {
      rates = { 44100, 48000.5 },
      category = "invalid",
    },
  }

  for _, case in ipairs(cases) do
    local api, dependencies, _, calls = fake_environment(2, {
      project_rate = 0,
      snapshot_sample_rates = case.rates,
    })
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })

    local started, reason = app:start()

    helper.assert_equal(nil, started)
    helper.assert_true(type(reason) == "string"
      and reason:find("sample rate", 1, true) ~= nil
      and reason:find(case.category, 1, true) ~= nil,
      "expected " .. case.category .. " sample rate error, got " .. tostring(reason))
    helper.assert_equal(0, count_call(calls, "fill"))
    helper.assert_equal(0, count_call(calls, "build normal"))
  end
end)

helper.test("snapshot fallback accepts only when every sample rate is consistent", function()
  local api, dependencies, _, calls, observed = fake_environment(2, {
    project_rate = 0,
    snapshot_sample_rates = { 44100, 44100 },
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  helper.assert_true(app:start())

  helper.assert_equal(44100, observed.sample_rate)
  helper.assert_equal(1, count_call(calls, "fill"))
  helper.assert_equal(1, count_call(calls, "build normal"))
end)

helper.test("missing reliable sample rate fails before apply mutation", function()
  local api, dependencies, _, calls = fake_environment(2, {
    project_rate = 0,
    snapshot_sample_rate = 0,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  local started, reason = app:start()

  helper.assert_equal(nil, started)
  helper.assert_true(type(reason) == "string"
    and reason:find("sample rate", 1, true) ~= nil)
  helper.assert_equal(0, count_call(calls, "fill"))
  helper.assert_equal(0, count_call(calls, "build normal"))
  helper.assert_equal(false, app.has_preview)
  helper.assert_equal(0, #app.outputs)
  helper.assert_equal(nil, app.model.timeline_fill)
end)

helper.test("fill failure clears preview outputs and summary without applying", function()
  local api, dependencies, _, calls, _, config = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    debounce_seconds = 0.1,
  })
  helper.assert_true(app:start())
  helper.assert_true(app.has_preview)
  helper.assert_true(app.model.timeline_fill ~= nil)
  helper.assert_equal(1, count_call(calls, "build normal"))

  config.fill_reason = "cannot fill this selection"
  helper.assert_true(app:set_setting("loops", 2, 10))
  local rebuilt, reason = app:tick(10.1)

  helper.assert_equal(nil, rebuilt)
  helper.assert_equal("cannot fill this selection", reason)
  helper.assert_equal("Error", app.model.status)
  helper.assert_equal(false, app.has_preview)
  helper.assert_equal(0, #app.outputs)
  helper.assert_equal(nil, app.model.timeline_fill)
  helper.assert_equal(2, count_call(calls, "fill"))
  helper.assert_equal(1, count_call(calls, "build normal"))
end)

helper.test("normal and Shepard successful apply calls are enclosed by mutation tracking", function()
  for _, case in ipairs({
    { settings = {}, build = "build normal" },
    { settings = { shepard = true }, build = "build shepard" },
  }) do
    local api, dependencies, _, calls = fake_environment(1)
    local app = app_module.new(api, {
      dependencies = dependencies,
      project = 0,
      settings = case.settings,
    })

    helper.assert_true(app:start())

    helper.assert_equal(1, count_call(calls, "begin mutation"))
    helper.assert_equal(1, count_call(calls, "end mutation"))
    helper.assert_true(call_index(calls, "begin mutation") < call_index(calls, case.build))
    helper.assert_true(call_index(calls, case.build) < call_index(calls, "end mutation"))
  end
end)

helper.test("mutation end failure is combined with apply failure before restore", function()
  local api, dependencies, _, calls = fake_environment(1, {
    normal_apply_reason = "apply left partial Items",
    end_mutation_reason = "GUID delta failed",
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  local started, reason = app:start()

  helper.assert_equal(nil, started)
  helper.assert_true(reason:find("apply left partial Items", 1, true) ~= nil)
  helper.assert_true(reason:find("GUID delta failed", 1, true) ~= nil)
  helper.assert_equal(1, count_call(calls, "begin mutation"))
  helper.assert_equal(1, count_call(calls, "end mutation"))
  helper.assert_equal(1, count_call(calls, "restore"))
end)

helper.test("normal and Shepard partial apply failures restore the active transaction", function()
  local cases = {
    {
      reason_key = "normal_apply_reason",
      reason = "normal apply failed after mutation",
      settings = {},
    },
    {
      reason_key = "shepard_apply_reason",
      reason = "Shepard apply failed after mutation",
      settings = { shepard = true },
    },
  }

  for _, case in ipairs(cases) do
    local config = {}
    config[case.reason_key] = case.reason
    local api, dependencies, _, calls, observed = fake_environment(1, config)
    local app = app_module.new(api, {
      dependencies = dependencies,
      project = 0,
      settings = case.settings,
    })
    app.model.warnings = { "stale warning" }

    local started, reason = app:start()

    helper.assert_equal(nil, started)
    helper.assert_true(reason:find(case.reason, 1, true) ~= nil)
    local build_call = case.settings.shepard and "build shepard" or "build normal"
    helper.assert_equal(1, count_call(calls, "begin mutation"))
    helper.assert_equal(1, count_call(calls, "end mutation"))
    helper.assert_true(call_index(calls, "begin mutation") < call_index(calls, build_call))
    helper.assert_true(call_index(calls, build_call) < call_index(calls, "end mutation"))
    helper.assert_true(call_index(calls, "end mutation") < call_index(calls, "restore"))
    helper.assert_equal(1, count_call(calls, "restore"))
    helper.assert_equal(false, config.mutated)
    helper.assert_equal(false, app.has_preview)
    helper.assert_equal(0, #app.outputs)
    helper.assert_equal(0, #app.model.warnings)
    helper.assert_equal(nil, app.model.timeline_fill)
    helper.assert_equal(0, #app.model.zero_crossings)
    helper.assert_equal(0, app.model.selected_audio_count)

    config[case.reason_key] = nil
    helper.assert_true(app:rebuild(false))
    helper.assert_equal(false, observed.snapshot_saw_mutation)
    helper.assert_equal(1, count_call(calls, "restore"))
  end
end)

helper.test("dirty rebuild preserves and deduplicates warnings from both restores", function()
  local cases = {
    {
      sequence = {
        { "warning A" },
        { "warning A", "warning B" },
      },
      expected = { "warning A", "warning B" },
    },
    {
      sequence = {
        { "warning A" },
        {},
      },
      expected = { "warning A" },
    },
  }

  for _, case in ipairs(cases) do
    local api, dependencies, _, calls, _, config = fake_environment(1, {
      restore_warning_sequence = case.sequence,
    })
    local app = app_module.new(api, {
      dependencies = dependencies,
      project = 0,
      debounce_seconds = 0.1,
    })
    helper.assert_true(app:start())

    config.normal_apply_reason = "rebuild apply failed"
    helper.assert_true(app:set_setting("loops", 2, 10))
    local rebuilt, reason = app:tick(10.1)

    helper.assert_equal(nil, rebuilt)
    helper.assert_equal(2, count_call(calls, "restore"))
    helper.assert_true(reason:find("restore warnings", 1, true) ~= nil)
    helper.assert_equal(#case.expected, #app.model.warnings)
    for index, warning in ipairs(case.expected) do
      helper.assert_equal(warning, app.model.warnings[index])
      local _, occurrences = reason:gsub(warning, "")
      helper.assert_equal(1, occurrences)
    end
  end
end)

helper.test("successful apply recovery preserves restore warnings in fail state", function()
  local restore_warnings = {
    "preview clone could not be removed",
    "original selection may be incomplete",
  }
  local api, dependencies, _, calls = fake_environment(1, {
    normal_apply_reason = "normal apply failed after mutation",
    restore_warnings = restore_warnings,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  local started, reason = app:start()

  helper.assert_equal(nil, started)
  helper.assert_true(reason:find("normal apply failed after mutation", 1, true) ~= nil)
  helper.assert_true(reason:find("restore warnings", 1, true) ~= nil)
  helper.assert_equal(1, count_call(calls, "restore"))
  helper.assert_equal(2, #app.model.warnings)
  helper.assert_equal(restore_warnings[1], app.model.warnings[1])
  helper.assert_equal(restore_warnings[2], app.model.warnings[2])
  helper.assert_equal(false, app.has_preview)
  helper.assert_equal(0, #app.outputs)
end)

helper.test("normal and Shepard apply exceptions restore before entering fail state", function()
  local cases = {
    {
      error_key = "normal_apply_error",
      marker = "normal apply exploded",
      settings = {},
    },
    {
      error_key = "shepard_apply_error",
      marker = "Shepard apply exploded",
      settings = { shepard = true },
    },
  }

  for _, case in ipairs(cases) do
    local config = {}
    config[case.error_key] = case.marker
    local api, dependencies, _, calls = fake_environment(1, config)
    local app = app_module.new(api, {
      dependencies = dependencies,
      project = 0,
      settings = case.settings,
    })

    local started, reason = app:start()

    helper.assert_equal(nil, started)
    helper.assert_true(type(reason) == "string"
      and reason:find(case.marker, 1, true) ~= nil)
    local build_call = case.settings.shepard and "build shepard" or "build normal"
    helper.assert_equal(1, count_call(calls, "begin mutation"))
    helper.assert_equal(1, count_call(calls, "end mutation"))
    helper.assert_true(call_index(calls, "begin mutation") < call_index(calls, build_call))
    helper.assert_true(call_index(calls, build_call) < call_index(calls, "end mutation"))
    helper.assert_true(call_index(calls, "end mutation") < call_index(calls, "restore"))
    helper.assert_equal(1, count_call(calls, "restore"))
    helper.assert_equal(false, config.mutated)
    helper.assert_equal("Error", app.model.status)
    helper.assert_equal(false, app.has_preview)
    helper.assert_equal(0, #app.outputs)
  end
end)

helper.test("apply and restore failures are combined", function()
  local api, dependencies, _, calls = fake_environment(1, {
    normal_apply_reason = "apply left partial outputs",
    restore_reason = "baseline restore failed",
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  local started, reason = app:start()

  helper.assert_equal(nil, started)
  helper.assert_true(reason:find("apply left partial outputs", 1, true) ~= nil)
  helper.assert_true(reason:find("baseline restore failed", 1, true) ~= nil)
  helper.assert_equal(1, count_call(calls, "restore"))
  helper.assert_equal(false, app.has_preview)
  helper.assert_equal(0, #app.outputs)
end)

helper.test("planning dependency exceptions enter App fail state", function()
  local cases = {
    { key = "plan_error", marker = "plan exploded", settings = {} },
    { key = "analyze_error", marker = "analysis exploded", settings = {} },
    { key = "fill_error", marker = "fill exploded", settings = {} },
    {
      key = "shepard_plan_error",
      marker = "Shepard plan exploded",
      settings = { shepard = true },
    },
  }

  for _, case in ipairs(cases) do
    local config = {}
    config[case.key] = case.marker
    local api, dependencies, _, calls = fake_environment(1, config)
    local app = app_module.new(api, {
      dependencies = dependencies,
      project = 0,
      settings = case.settings,
    })

    local started, reason = app:start()

    helper.assert_equal(nil, started)
    helper.assert_true(type(reason) == "string"
      and reason:find(case.marker, 1, true) ~= nil)
    helper.assert_equal("Error", app.model.status)
    helper.assert_equal(0, count_call(calls, "restore"))
  end
end)

helper.test("dirty settings rebuild after debounce and route Shepard mode", function()
  local api, dependencies, _, calls = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    debounce_seconds = 0.2,
  })
  helper.assert_true(app:start())

  helper.assert_true(app:set_setting("shepard", true, 10.0))
  helper.assert_equal(false, app:tick(10.1))
  helper.assert_true(app:tick(10.2))

  helper.assert_equal(1, count_call(calls, "restore"))
  helper.assert_equal(1, count_call(calls, "plan shepard"))
  helper.assert_equal(1, count_call(calls, "build shepard"))
  helper.assert_equal(1, count_call(calls, "fill"))
  helper.assert_equal(nil, app.model.timeline_fill)
  helper.assert_equal(false, app.model.dirty)
end)

helper.test("apply optionally glues current preview then commits the transaction", function()
  local api, dependencies, tx, calls = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    settings = { glue = true },
  })
  helper.assert_true(app:start())

  local applied = app:apply()

  helper.assert_true(applied)
  helper.assert_equal(false, tx.active)
  helper.assert_equal(1, count_call(calls, "glue:captured-project"))
  helper.assert_equal(2, count_call(calls, "begin mutation"))
  helper.assert_equal(2, count_call(calls, "end mutation"))
  helper.assert_true(call_index(calls, "glue:captured-project")
    < call_index(calls, "apply"))
  helper.assert_equal(1, count_call(calls, "apply"))
end)

helper.test("Glue failure and exception immediately restore baseline and invalidate outputs", function()
  for _, case in ipairs({
    { key = "glue_reason", marker = "Glue rejected" },
    { key = "glue_error", marker = "Glue exploded" },
  }) do
    local config = {}
    local api, dependencies, tx, calls = fake_environment(1, config)
    local app = app_module.new(api, {
      dependencies = dependencies,
      project = 0,
      settings = { glue = true },
    })
    helper.assert_true(app:start())
    config[case.key] = case.marker
    local restores = count_call(calls, "restore")

    local applied, reason = app:apply()

    helper.assert_equal(nil, applied)
    helper.assert_true(type(reason) == "string"
      and reason:find(case.marker, 1, true) ~= nil)
    helper.assert_true(reason:find("Glue", 1, true) ~= nil
      and reason:find("file", 1, true) ~= nil)
    helper.assert_equal(2, count_call(calls, "begin mutation"))
    helper.assert_equal(2, count_call(calls, "end mutation"))
    helper.assert_equal(restores + 1, count_call(calls, "restore"))
    helper.assert_equal(false, config.mutated)
    helper.assert_equal(false, tx.preview_mutation_active)
    helper.assert_equal(true, tx.active)
    helper.assert_equal(false, app.has_preview)
    helper.assert_equal(0, #app.outputs)
    helper.assert_equal(0, count_call(calls, "apply"))

    config[case.key] = nil
    helper.assert_true(app:rebuild(false))
  end
end)

helper.test("Glue failure deletes its result and rebuilds the deleted original Item", function()
  local api, dependencies, _, _, _, config = fake_environment(1)
  local project = { name = "stateful-project" }
  local track = { valid = true }
  local original_chunk = "<ITEM\nGUID {ORIGINAL}\n>"
  local original = {
    guid = "{ORIGINAL}", chunk = original_chunk,
    selected = true, track = track, valid = true,
  }
  local items = { original }
  local captured_transaction
  local next_guid = 0
  local time_start, time_finish = 0, 0
  local loop_start, loop_finish = 11, 13
  local cursor, repeat_state = 4, 0

  api.EnumProjects = function(index)
    if index == -1 or index == 0 then return project, "stateful-project" end
    return nil
  end
  api.CountMediaItems = function(received)
    helper.assert_equal(project, received)
    return #items
  end
  api.GetMediaItem = function(received, index)
    helper.assert_equal(project, received)
    return items[index + 1]
  end
  api.CountSelectedMediaItems = function(received)
    helper.assert_equal(project, received)
    local count = 0
    for _, item in ipairs(items) do
      if item.selected then count = count + 1 end
    end
    return count
  end
  api.GetSelectedMediaItem = function(received, index)
    helper.assert_equal(project, received)
    local selected = {}
    for _, item in ipairs(items) do
      if item.selected then selected[#selected + 1] = item end
    end
    return selected[index + 1]
  end
  api.GetItemStateChunk = function(item)
    return true, item.chunk
  end
  api.SetItemStateChunk = function(item, chunk)
    item.chunk = chunk
    item.guid = chunk:match("GUID%s+({[^}]+})") or item.guid
    return true
  end
  api.GetSetMediaItemInfo_String = function(item)
    return true, item.guid
  end
  api.IsMediaItemSelected = function(item)
    return item.selected
  end
  api.GetSet_LoopTimeRange2 = function(received, is_set, is_loop, start_time, end_time)
    helper.assert_equal(project, received)
    if is_set then
      if is_loop then
        loop_start, loop_finish = start_time, end_time
      else
        time_start, time_finish = start_time, end_time
      end
      return
    end
    if is_loop then return loop_start, loop_finish end
    return time_start, time_finish
  end
  api.GetSetRepeatEx = function(received, value)
    helper.assert_equal(project, received)
    if value >= 0 then repeat_state = value > 0 and 1 or 0 end
    return repeat_state
  end
  api.GetCursorPositionEx = function(received)
    helper.assert_equal(project, received)
    return cursor
  end
  api.GetPlayStateEx = function(received)
    helper.assert_equal(project, received)
    return config.play_state or 0
  end
  api.PreventUIRefresh = function() end
  api.Undo_BeginBlock2 = function(received) helper.assert_equal(project, received) end
  api.Undo_EndBlock2 = function(received) helper.assert_equal(project, received) end
  api.ValidatePtr2 = function(received, pointer, kind)
    helper.assert_equal(project, received)
    if kind == "MediaTrack*" then return pointer == track and track.valid end
    return type(pointer) == "table" and pointer.valid == true
  end
  api.GetMediaItemTrack = function(item) return item.track end
  api.AddMediaItemToTrack = function(received_track)
    helper.assert_equal(track, received_track)
    next_guid = next_guid + 1
    local item = {
      guid = "{ADDED-" .. next_guid .. "}", chunk = "",
      selected = false, track = track, valid = true,
    }
    items[#items + 1] = item
    return item
  end
  api.DeleteTrackMediaItem = function(received_track, item)
    helper.assert_equal(track, received_track)
    for index, candidate in ipairs(items) do
      if candidate == item then
        table.remove(items, index)
        item.valid = false
        return true
      end
    end
    return false
  end
  api.SetMediaItemSelected = function(item, selected) item.selected = selected end
  api.SetEditCurPos2 = function(received, position)
    helper.assert_equal(project, received)
    cursor = position
  end
  api.UpdateArrange = function() end
  api.OnStopButton = function() config.play_state = 0 end

  dependencies.state.Transaction.capture = function(injected_api, requested_project)
    captured_transaction = assert(state_module.Transaction.capture(
      injected_api, requested_project))
    return captured_transaction
  end
  dependencies.loop_builder.glue_outputs = function(_, received_project)
    helper.assert_equal(project, received_project)
    for _, item in ipairs(items) do item.selected = false end
    for index, item in ipairs(items) do
      if item == original then
        table.remove(items, index)
        original.valid = false
        break
      end
    end
    local glued = {
      guid = "{GLUED}", chunk = "GLUED", selected = true,
      track = track, valid = true,
    }
    items[#items + 1] = glued
    return nil, "Glue failed after replacement", { { main = glued } }
  end

  local app = app_module.new(api, {
    dependencies = dependencies,
    project = project,
    settings = { glue = true },
  })
  helper.assert_true(app:start())
  local user_item = {
    guid = "{USER}", chunk = "USER", selected = true,
    track = track, valid = true,
  }
  items[#items + 1] = user_item

  local applied, reason = app:apply()

  helper.assert_equal(nil, applied)
  helper.assert_true(type(reason) == "string"
    and reason:find("Glue failed after replacement", 1, true) ~= nil)
  helper.assert_equal(2, #items)
  helper.assert_equal(true, user_item.valid)
  helper.assert_equal(true, user_item.selected)
  local rebuilt = captured_transaction.captured.selected_items[1].item
  helper.assert_true(rebuilt ~= original)
  helper.assert_equal(true, rebuilt.valid)
  helper.assert_equal("{ORIGINAL}", rebuilt.guid)
  helper.assert_equal(original_chunk, rebuilt.chunk)
  helper.assert_equal(true, rebuilt.selected)
  helper.assert_equal(true, captured_transaction:is_active())
  helper.assert_equal(false, app.has_preview)
  helper.assert_equal(0, #app.outputs)
end)

helper.test("mark_applied failure restores an active transaction before failing", function()
  local api, dependencies, tx, calls, _, config = fake_environment(1, {
    apply_commit_reason = "Undo close failed",
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  config.mutated = true
  local restores = count_call(calls, "restore")

  local applied, reason = app:apply()

  helper.assert_equal(nil, applied)
  helper.assert_true(type(reason) == "string"
    and reason:find("Undo close failed", 1, true) ~= nil)
  helper.assert_equal(restores + 1, count_call(calls, "restore"))
  helper.assert_equal(false, config.mutated)
  helper.assert_equal(true, tx.active)
  helper.assert_equal(false, app.has_preview)
  helper.assert_equal(0, #app.outputs)
end)

helper.test("missing Glue dependency does not claim a disk file was created", function()
  local api, dependencies, tx, calls = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    settings = { glue = true },
  })
  helper.assert_true(app:start())
  dependencies.loop_builder.glue_outputs = nil

  local applied, reason = app:apply()

  helper.assert_equal(nil, applied)
  helper.assert_true(reason:find("missing glue_outputs", 1, true) ~= nil)
  helper.assert_equal(nil, reason:find("disk", 1, true))
  helper.assert_equal(1, count_call(calls, "begin mutation"))
  helper.assert_equal(true, tx.active)
end)

helper.test("Glue begin-tracking failure does not claim a disk file was created", function()
  local api, dependencies, tx, calls, _, config = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    settings = { glue = true },
  })
  helper.assert_true(app:start())
  config.begin_mutation_reason = "cannot snapshot Items"

  local applied, reason = app:apply()

  helper.assert_equal(nil, applied)
  helper.assert_true(reason:find("cannot snapshot Items", 1, true) ~= nil)
  helper.assert_equal(nil, reason:find("disk", 1, true))
  helper.assert_equal(0, count_call(calls, "glue:captured-project"))
  helper.assert_equal(true, tx.active)
end)

helper.test("cancel restores the transaction and empty selection disables apply", function()
  local api, dependencies, tx, calls = fake_environment(0)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })

  local started = app:start()
  helper.assert_true(started)
  helper.assert_equal(false, app:can_apply())
  local applied, apply_reason = app:apply()
  helper.assert_equal(nil, applied)
  helper.assert_true(type(apply_reason) == "string")

  helper.assert_true(app:cancel())
  helper.assert_equal(false, tx.active)
  helper.assert_equal(1, count_call(calls, "cancel"))
end)

helper.test("second preview toggle never stops active transport", function()
  local api, dependencies, tx, calls, observed = fake_environment(1)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())

  helper.assert_true(app:toggle_preview())
  helper.assert_equal(1, observed.preview_start)
  helper.assert_equal(4, observed.preview_end)
  helper.assert_true(call_index(calls, "prepare preview")
    < call_index(calls, "play:captured-project"))
  helper.assert_true(call_index(calls, "play:captured-project")
    < call_index(calls, "marked playback"))
  helper.assert_equal(true, tx.preview_playback_started)

  helper.assert_true(app:toggle_preview())
  helper.assert_equal(0, count_call(calls, "stop:captured-project"))
  helper.assert_equal(0, count_call(calls, "release preview"))
  helper.assert_equal(true, tx.preview_playback_started)
  helper.assert_true(tx.preview_range_state ~= nil)
  helper.assert_equal(
    "Preview is playing; stop REAPER transport to end preview",
    app.model.status)
end)

helper.test("project switching blocks Glue and transport before side effects", function()
  local api, dependencies, tx, calls = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    settings = { glue = true },
  })
  helper.assert_true(app:start())
  tx.same_project = false

  local applied, apply_reason = app:apply()
  helper.assert_equal(nil, applied)
  helper.assert_true(type(apply_reason) == "string")
  helper.assert_equal(0, count_call(calls, "glue:captured-project"))
  helper.assert_equal(0, count_call(calls, "apply"))

  local previewed, preview_reason = app:toggle_preview()
  helper.assert_equal(nil, previewed)
  helper.assert_true(type(preview_reason) == "string")
  helper.assert_equal(0, count_call(calls, "play:captured-project"))
end)

helper.test("idle tick detects a switched project without waiting for dirty settings", function()
  local api, dependencies, tx = fake_environment(1)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  helper.assert_equal(false, app.model.dirty)
  tx.same_project = false

  local ticked, reason = app:tick(20)

  helper.assert_equal(nil, ticked)
  helper.assert_equal("captured project is not the current project", reason)
end)

helper.test("preview without fill spans every output plan", function()
  local api, dependencies, _, calls, observed = fake_environment(1, {
    time_start = 0,
    time_end = 0,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  app.outputs = {
    { plan = { output_position = 12, loop_length = 3 } },
    { plan = { output_position = 7.5, loop_length = 2 } },
    { plan = { output_position = 20, loop_length = 1.25 } },
  }

  helper.assert_true(app:toggle_preview())

  helper.assert_equal(7.5, observed.preview_start)
  helper.assert_equal(21.25, observed.preview_end)
  helper.assert_equal(1, count_call(calls, "prepare preview"))
end)

helper.test("preview validates output ranges before preparing transport", function()
  local invalid_values = {
    {},
    { value = 0 / 0 },
    { value = math.huge },
    { value = -math.huge },
    { value = 0 },
  }
  for _, case in ipairs(invalid_values) do
    local api, dependencies, _, calls = fake_environment(1, {
      time_start = 0,
      time_end = 0,
    })
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })
    helper.assert_true(app:start())
    app.outputs = { { plan = { output_position = 2, loop_length = case.value } } }

    local previewed, reason = app:toggle_preview()

    helper.assert_equal(nil, previewed)
    helper.assert_true(type(reason) == "string")
    helper.assert_equal(0, count_call(calls, "prepare preview"))
    helper.assert_equal(0, count_call(calls, "play:captured-project"))
  end
end)

helper.test("preview rejects sparse or non-array output plans", function()
  local api, dependencies, _, calls = fake_environment(1, {
    time_start = 0,
    time_end = 0,
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  app.outputs = {
    [1] = { plan = { output_position = 2, loop_length = 1 } },
    [3] = { plan = { output_position = 5, loop_length = 1 } },
  }

  local previewed, reason = app:toggle_preview()

  helper.assert_equal(nil, previewed)
  helper.assert_true(type(reason) == "string"
    and reason:find("output", 1, true) ~= nil)
  helper.assert_equal(0, count_call(calls, "prepare preview"))
end)

helper.test("preview requires an available preview before inspecting or stopping playback", function()
  local api, dependencies, _, calls, _, config = fake_environment(0)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  config.play_state = 1

  local previewed, reason = app:toggle_preview()

  helper.assert_equal(nil, previewed)
  helper.assert_true(type(reason) == "string"
    and reason:find("no preview", 1, true) ~= nil)
  helper.assert_equal(0, count_call(calls, "stop:captured-project"))
  helper.assert_equal(1, config.play_state)
end)

helper.test("preview toggle treats every active transport as user-owned", function()
  local api, dependencies, tx, calls, _, config = fake_environment(1)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  helper.assert_equal(false, tx.preview_playback_started)
  config.play_state = 1

  local previewed, reason = app:toggle_preview()

  helper.assert_equal(true, previewed)
  helper.assert_equal(nil, reason)
  helper.assert_equal(
    "Preview is playing; stop REAPER transport to end preview",
    app.model.status)
  helper.assert_equal(0, count_call(calls, "check preview ownership"))
  helper.assert_equal(0, count_call(calls, "stop:captured-project"))
  helper.assert_equal(0, count_call(calls, "release preview"))
  helper.assert_equal(1, config.play_state)
end)

helper.test("prepare failure prevents playback", function()
  local api, dependencies, _, calls = fake_environment(1, {
    prepare_reason = "prepare rejected",
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())

  local previewed, reason = app:toggle_preview()

  helper.assert_equal(nil, previewed)
  helper.assert_true(reason:find("prepare rejected", 1, true) ~= nil)
  helper.assert_equal(0, count_call(calls, "play:captured-project"))
  helper.assert_equal(0, count_call(calls, "marked playback"))
end)

helper.test("play failure stops and releases the prepared preview range", function()
  local api, dependencies, tx, calls = fake_environment(1, {
    play_error = "play exploded",
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())

  local previewed, reason = app:toggle_preview()

  helper.assert_equal(nil, previewed)
  helper.assert_true(reason:find("play exploded", 1, true) ~= nil)
  helper.assert_equal(1, count_call(calls, "prepare preview"))
  helper.assert_equal(1, count_call(calls, "stop:captured-project"))
  helper.assert_equal(1, count_call(calls, "release preview"))
  helper.assert_equal(nil, tx.preview_range_state)
end)

helper.test("mark failure combines stop and release failures", function()
  local api, dependencies, tx, calls = fake_environment(1, {
    mark_reason = "mark rejected",
    stop_error = "stop exploded",
    release_reason = "release rejected",
  })
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())

  local previewed, reason = app:toggle_preview()

  helper.assert_equal(nil, previewed)
  helper.assert_true(reason:find("mark rejected", 1, true) ~= nil)
  helper.assert_true(reason:find("stop exploded", 1, true) ~= nil)
  helper.assert_true(reason:find("release rejected", 1, true) ~= nil)
  helper.assert_equal(1, count_call(calls, "stop:captured-project"))
  helper.assert_equal(1, count_call(calls, "release preview"))
  helper.assert_equal(false, tx.preview_playback_started)
end)

helper.test("preview uses non-Ex play fallback but never stops on a later toggle", function()
  local api, dependencies, _, calls, observed, config = fake_environment(1)
  api.OnPlayButtonEx = nil
  api.OnStopButtonEx = nil
  api.OnPlayButton = function()
    calls[#calls + 1] = "play"
    config.play_state = 1
  end
  api.OnStopButton = function()
    calls[#calls + 1] = "stop"
    config.play_state = 0
  end
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())

  helper.assert_true(app:toggle_preview())
  helper.assert_equal(1, observed.preview_start)
  helper.assert_equal(1, count_call(calls, "play"))
  helper.assert_true(app:toggle_preview())
  helper.assert_equal(0, count_call(calls, "stop"))
  helper.assert_equal(0, count_call(calls, "release preview"))
  helper.assert_equal(
    "Preview is playing; stop REAPER transport to end preview",
    app.model.status)
end)

helper.test("Apply Cancel rebuild and tick never stop or mutate active transport", function()
  for _, play_state in ipairs({ 1, 2, 3, 4, 5, 6, 7 }) do
    for _, action in ipairs({ "apply", "cancel", "rebuild", "tick" }) do
      local api, dependencies, tx, calls, _, config = fake_environment(1)
      local app = app_module.new(api, {
        dependencies = dependencies,
        project = 0,
        debounce_seconds = 0,
        settings = { glue = true },
      })
      helper.assert_true(app:start())
      helper.assert_true(app:toggle_preview())
      config.play_state = play_state
      if action == "rebuild" or action == "tick" then
        helper.assert_true(app:set_setting("loops", 2, 10))
      end
      local restores = count_call(calls, "restore")
      local begins = count_call(calls, "begin mutation")
      local builds = count_call(calls, "build normal")
      local glues = count_call(calls, "glue:captured-project")
      local stops = count_call(calls, "stop:captured-project")
      local syncs = count_call(calls, "sync preview")

      local result, reason
      if action == "apply" then
        result, reason = app:apply()
      elseif action == "cancel" then
        result, reason = app:cancel()
      elseif action == "rebuild" then
        result, reason = app:rebuild(false)
      else
        result, reason = app:tick(10)
      end

      if action == "tick" then
        helper.assert_equal(false, result)
        helper.assert_equal(nil, reason)
      else
        helper.assert_equal(nil, result)
        helper.assert_true(type(reason) == "string"
          and reason:find("Stop playback/recording", 1, true) ~= nil)
      end
      helper.assert_equal(stops, count_call(calls, "stop:captured-project"))
      helper.assert_equal(syncs, count_call(calls, "sync preview"))
      helper.assert_equal(restores, count_call(calls, "restore"))
      helper.assert_equal(begins, count_call(calls, "begin mutation"))
      helper.assert_equal(builds, count_call(calls, "build normal"))
      helper.assert_equal(glues, count_call(calls, "glue:captured-project"))
      helper.assert_equal(true, tx.preview_playback_started)
      helper.assert_true(tx.preview_range_state ~= nil)
      helper.assert_equal(true, tx.active)

      config.play_state = 0
      local resumed = app:tick(11)
      if action == "rebuild" or action == "tick" then
        helper.assert_true(resumed)
      else
        helper.assert_equal(false, resumed)
      end
      if action == "apply" then
        helper.assert_true(app:apply())
      elseif action == "cancel" then
        helper.assert_true(app:cancel())
      elseif action == "rebuild" then
        helper.assert_true(app:rebuild(false))
      else
        helper.assert_equal(false, app:tick(12))
      end
    end
  end
end)

helper.test("preview playback tick stays alive and defers dirty rebuild until stopped", function()
  local api, dependencies, tx, calls, _, config = fake_environment(1)
  local app = app_module.new(api, {
    dependencies = dependencies,
    project = 0,
    debounce_seconds = 0,
  })
  helper.assert_true(app:start())
  helper.assert_true(app:toggle_preview())
  helper.assert_true(app:set_setting("loops", 2, 10))
  local builds = count_call(calls, "build normal")
  local restores = count_call(calls, "restore")
  local syncs = count_call(calls, "sync preview")

  local ticked, reason = app:tick(10)

  helper.assert_equal(false, ticked)
  helper.assert_equal(nil, reason)
  helper.assert_equal(true, app.model.dirty)
  helper.assert_equal(builds, count_call(calls, "build normal"))
  helper.assert_equal(restores, count_call(calls, "restore"))
  helper.assert_equal(syncs, count_call(calls, "sync preview"))
  helper.assert_equal(0, count_call(calls, "stop:captured-project"))
  helper.assert_equal(true, tx.preview_playback_started)

  config.play_state = 0
  helper.assert_true(app:tick(11))
  helper.assert_equal(false, app.model.dirty)
  helper.assert_equal(builds + 1, count_call(calls, "build normal"))
end)

helper.test("external Stop releases preview and permits a later preview start", function()
  local api, dependencies, tx, calls, _, config = fake_environment(1)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  helper.assert_true(app:toggle_preview())
  config.play_state = 0
  local sync_calls = count_call(calls, "sync preview")

  local rebuilt = app:tick(20)

  helper.assert_equal(false, rebuilt)
  helper.assert_equal(sync_calls + 1, count_call(calls, "sync preview"))
  helper.assert_equal(false, tx.preview_playback_started)
  helper.assert_equal(nil, tx.preview_range_state)
  helper.assert_equal(1, count_call(calls, "release preview"))

  helper.assert_true(app:toggle_preview())
  helper.assert_equal(2, count_call(calls, "play:captured-project"))
  helper.assert_equal(true, tx.preview_playback_started)
  helper.assert_true(tx.preview_range_state ~= nil)
end)

helper.test("external restart blocks later transaction actions without stopping playback", function()
  local actions = { "cancel", "apply", "rebuild" }
  for _, action in ipairs(actions) do
    local api, dependencies, tx, calls, _, config = fake_environment(1)
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })
    helper.assert_true(app:start())
    helper.assert_true(app:toggle_preview())

    config.play_state = 0
    helper.assert_equal(false, app:tick(20))
    helper.assert_equal(false, tx.preview_playback_started)
    config.play_state = 1

    local result, reason
    if action == "cancel" then
      result, reason = app:cancel()
    elseif action == "apply" then
      result, reason = app:apply()
    else
      result, reason = app:rebuild(false)
    end

    helper.assert_equal(nil, result)
    helper.assert_true(reason:find("Stop playback/recording", 1, true) ~= nil)
    helper.assert_equal(0, count_call(calls, "stop:captured-project"))
    helper.assert_equal(1, config.play_state)
    helper.assert_equal(true, tx.active)

    config.play_state = 0
    if action == "cancel" then
      helper.assert_true(app:cancel())
    elseif action == "apply" then
      helper.assert_true(app:apply())
    else
      helper.assert_true(app:rebuild(false))
    end
  end
end)

helper.test("recording tick preserves ownership and range until transport stops", function()
  local api, dependencies, tx, calls, _, config = fake_environment(1)
  local app = app_module.new(api, { dependencies = dependencies, project = 0 })
  helper.assert_true(app:start())
  helper.assert_true(app:toggle_preview())
  config.play_state = 5

  local ticked, reason = app:tick(20)

  helper.assert_equal(false, ticked)
  helper.assert_equal(nil, reason)
  helper.assert_equal(true, tx.preview_playback_started)
  helper.assert_true(tx.preview_range_state ~= nil)
  helper.assert_equal(0, count_call(calls, "stop:captured-project"))

  config.play_state = 0
  helper.assert_equal(false, app:tick(21))
  helper.assert_equal(false, tx.preview_playback_started)
  helper.assert_equal(nil, tx.preview_range_state)
  helper.assert_true(app:cancel())
  helper.assert_equal(1, count_call(calls, "cancel"))
end)

helper.test("recording blocks Apply Cancel and rebuild before any transaction mutation", function()
  for _, action in ipairs({ "apply", "cancel", "rebuild" }) do
    local api, dependencies, tx, calls, _, config = fake_environment(1, {
      glue = true,
    })
    local app = app_module.new(api, {
      dependencies = dependencies,
      project = 0,
      settings = { glue = true },
    })
    helper.assert_true(app:start())
    config.play_state = 5
    local restores = count_call(calls, "restore")
    local begins = count_call(calls, "begin mutation")
    local ends = count_call(calls, "end mutation")
    local builds = count_call(calls, "build normal")
    local glues = count_call(calls, "glue:captured-project")

    local result, reason
    if action == "apply" then
      result, reason = app:apply()
    elseif action == "cancel" then
      result, reason = app:cancel()
    else
      result, reason = app:rebuild(false)
    end

    helper.assert_equal(nil, result)
    helper.assert_true(type(reason) == "string"
      and reason:find("Stop playback/recording", 1, true) ~= nil)
    helper.assert_equal(restores, count_call(calls, "restore"))
    helper.assert_equal(begins, count_call(calls, "begin mutation"))
    helper.assert_equal(ends, count_call(calls, "end mutation"))
    helper.assert_equal(builds, count_call(calls, "build normal"))
    helper.assert_equal(glues, count_call(calls, "glue:captured-project"))
    helper.assert_equal(0, count_call(calls, "apply"))
    helper.assert_equal(0, count_call(calls, "cancel"))
    helper.assert_equal(true, tx.active)

    config.play_state = 0
    if action == "apply" then
      helper.assert_true(app:apply())
    elseif action == "cancel" then
      helper.assert_true(app:cancel())
    else
      helper.assert_true(app:rebuild(false))
    end
  end
end)

helper.test("active preview toggle does not inspect ownership or stop transport", function()
  for _, ownership in ipairs({
    { reason = "GetPlayPositionEx is unavailable; preview ownership cannot be confirmed" },
    { owns = false },
    { owns = true },
  }) do
    local api, dependencies, tx, calls, _, config = fake_environment(1, {
      ownership_reason = ownership.reason,
      owns_preview = ownership.owns,
    })
    local app = app_module.new(api, { dependencies = dependencies, project = 0 })
    helper.assert_true(app:start())
    config.play_state = 1
    tx.preview_playback_started = true
    tx.preview_range_state = { start = 1, finish = 4 }

    local previewed, reason = app:toggle_preview()

    helper.assert_equal(true, previewed)
    helper.assert_equal(nil, reason)
    helper.assert_equal(0, count_call(calls, "check preview ownership"))
    helper.assert_equal(0, count_call(calls, "stop:captured-project"))
    helper.assert_equal(0, count_call(calls, "release preview"))
    helper.assert_equal(1, config.play_state)
    helper.assert_equal(
      "Preview is playing; stop REAPER transport to end preview",
      app.model.status)
  end
end)

helper.test("dirty rebuild accepts native numeric time-selection write results", function()
  for _, finish in ipairs({ 0, 64.55093202541 }) do
    local config = { time_start = 0, time_end = finish }
    local api, dependencies = fake_environment(1, config)
    local app = app_module.new(api, { dependencies = dependencies, debounce_seconds = 0 })
    helper.assert_true(app:start())
    app:set_setting("loops", 5, 10)
    local ok, reason = app:tick(10)
    helper.assert_true(ok, tostring(reason))
    helper.assert_equal(nil, app.model.error)
    helper.assert_true(app.has_preview)
  end
end)

helper.test("time-selection write exceptions still fail rebuild", function()
  local api, dependencies = fake_environment(1)
  local app = app_module.new(api, { dependencies = dependencies, debounce_seconds = 0 })
  helper.assert_true(app:start())
  local original = api.GetSet_LoopTimeRange2
  api.GetSet_LoopTimeRange2 = function(project, write, ...)
    if write then error("write unavailable") end
    return original(project, write, ...)
  end
  app:set_setting("loops", 5, 10)
  local ok, reason = app:tick(10)
  helper.assert_equal(nil, ok)
  helper.assert_true(reason:find("write unavailable", 1, true))
end)
