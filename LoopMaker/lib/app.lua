local loop_builder_module = require("lib.loop_builder")
local settings_module = require("lib.settings")
local regions_module = require("lib.regions")
local shepard_module = require("lib.shepard")
local state_module = require("lib.state")
local ui_model_module = require("ui.model")

local M = {}
local App = {}
App.__index = App
M.App = App

local function append_warnings(target, additions)
  if type(additions) ~= "table" then return end
  for _, warning in ipairs(additions) do
    if type(warning) == "string" and warning ~= "" then
      target[#target + 1] = warning
    end
  end
end

local function append_unique_warnings(target, additions)
  if type(additions) ~= "table" then return end
  local seen = {}
  for _, warning in ipairs(target) do
    seen[warning] = true
  end
  for _, warning in ipairs(additions) do
    if type(warning) == "string" and warning ~= "" and not seen[warning] then
      target[#target + 1] = warning
      seen[warning] = true
    end
  end
end

local function call_api(api, name, ...)
  if type(api) ~= "table" or type(api[name]) ~= "function" then
    return nil, "reaper_api is missing " .. name
  end
  local results = { pcall(api[name], ...) }
  if not results[1] then
    return nil, name .. " failed: " .. tostring(results[2])
  end
  return table.unpack(results, 2)
end

local function call_dependency(target, name, ...)
  if type(target) ~= "table" or type(target[name]) ~= "function" then
    return nil, "dependency is missing " .. name
  end
  local results = table.pack(pcall(target[name], ...))
  if not results[1] then
    return nil, name .. " failed: " .. tostring(results[2])
  end
  return true, table.unpack(results, 2, results.n)
end

local function call_transaction(transaction, name, ...)
  if type(transaction) ~= "table" or type(transaction[name]) ~= "function" then
    return nil, "transaction is missing " .. name
  end
  local results = table.pack(pcall(transaction[name], transaction, ...))
  if not results[1] then
    return nil, name .. " failed: " .. tostring(results[2])
  end
  return true, table.unpack(results, 2, results.n)
end

local function fail(self, reason)
  self.outputs = {}
  self.has_preview = false
  self.model.warnings = {}
  self.model.zero_crossings = {}
  self.model.timeline_fill = nil
  self.model.selected_audio_count = 0
  self.model.error = tostring(reason or "unknown error")
  self.model.status = "Error"
  self.model.dirty = false
  return nil, self.model.error
end

local function transaction_is_active(transaction)
  if type(transaction) ~= "table" then return false end
  if type(transaction.is_active) == "function" then
    local ok, active = pcall(transaction.is_active, transaction)
    return not ok or active == true
  end
  if transaction.active ~= nil then return transaction.active == true end
  return true
end

local function owns_preview_playback(transaction)
  if type(transaction.owns_preview_playback) ~= "function" then
    return transaction.preview_playback_started == true
  end
  local called, owns, reason = call_transaction(
    transaction, "owns_preview_playback")
  if not called then return nil, owns end
  if owns == nil then return nil, reason end
  return owns == true
end

local function sync_preview_playback(self)
  if type(self.transaction.sync_preview_playback) ~= "function" then
    return false
  end
  local called, changed, warnings_or_reason = call_transaction(
    self.transaction, "sync_preview_playback")
  if not called then return nil, changed end
  if changed == nil then return nil, warnings_or_reason end

  append_unique_warnings(self.model.warnings, warnings_or_reason)
  if changed then
    if type(warnings_or_reason) == "table" and #warnings_or_reason > 0 then
      self.model.status = "Recording active"
    elseif self.model.status == "Preview playing" then
      self.model.status = "Preview stopped"
    end
  end
  return changed
end

local function combine_operation_errors(primary, label, secondary)
  local suffix = label .. ": " .. tostring(secondary)
  if primary == nil or tostring(primary) == "" then return suffix end
  return tostring(primary) .. "; " .. suffix
end

local function call_tracked_dependency(self, target, name, ...)
  if type(target) ~= "table" or type(target[name]) ~= "function" then
    return nil, "dependency is missing " .. name, false
  end
  local begin_called, began, begin_reason = call_transaction(
    self.transaction, "begin_preview_mutation")
  if not begin_called then
    return nil, "preview mutation begin failed: " .. tostring(began), false
  end
  if not began then
    return nil, "preview mutation begin failed: " .. tostring(begin_reason), false
  end

  local results = table.pack(call_dependency(target, name, ...))
  local end_called, ended, end_reason = call_transaction(
    self.transaction, "end_preview_mutation")
  local tracking_reason
  if not end_called then
    tracking_reason = ended
  elseif not ended then
    tracking_reason = end_reason
  end
  if tracking_reason ~= nil then
    local primary_reason
    if not results[1] then
      primary_reason = results[2]
    elseif results[2] == nil then
      primary_reason = results[3]
    end
    return nil, combine_operation_errors(
      primary_reason, "preview mutation end failed", tracking_reason), true
  end
  results.n = results.n + 1
  results[results.n] = true
  return table.unpack(results, 1, results.n)
end

local function read_transport_state(self)
  local play_state, reason = call_api(
    self.api, "GetPlayStateEx", self.project)
  if play_state == nil then return nil, reason end
  if type(play_state) ~= "number" or play_state ~= play_state
      or play_state == math.huge or play_state == -math.huge then
    return nil, "GetPlayStateEx returned an invalid playback state"
  end
  return math.floor(play_state)
end

local function ensure_transport_stopped(self, operation)
  local play_state, reason = read_transport_state(self)
  if play_state == nil then return nil, reason end
  if play_state ~= 0 then
    return nil, "Stop playback/recording before " .. operation
  end
  return true
end

local function fail_after_apply(self, reason, existing_warnings)
  reason = tostring(reason or "apply_plan failed")
  local restore_warnings = {}
  append_unique_warnings(restore_warnings, existing_warnings)
  if transaction_is_active(self.transaction) then
    local restore = self.transaction.restore_for_rebuild
    if type(restore) ~= "function" then
      reason = reason .. "; restore failed: transaction is missing restore_for_rebuild"
    else
      local ok, restored, restore_result = pcall(restore, self.transaction)
      if not ok then
        reason = reason .. "; restore failed: " .. tostring(restored)
      elseif not restored then
        reason = reason .. "; restore failed: " .. tostring(restore_result)
      else
        append_unique_warnings(restore_warnings, restore_result)
      end
    end
  end
  if #restore_warnings > 0 then
    reason = reason .. "; restore warnings: "
      .. table.concat(restore_warnings, "; ")
  end
  fail(self, reason)
  append_warnings(self.model.warnings, restore_warnings)
  return nil, self.model.error
end

local function zero_crossing_rows(plans)
  local rows = {}
  for index, plan in ipairs(plans or {}) do
    local snapshot = type(plan) == "table" and plan.source_snapshot or nil
    rows[#rows + 1] = {
      index = index,
      name = snapshot and snapshot.name or "Item " .. index,
      variation = type(plan) == "table" and plan.variation_index or 0,
      start_time = type(plan) == "table" and plan.boundary_anchor or nil,
      end_time = type(plan) == "table" and plan.source_end or nil,
      warning = type(plan) == "table" and plan.warning or nil,
    }
  end
  return rows
end

local MAX_SAMPLE_RATE = 10000000

local function valid_sample_rate(value)
  return type(value) == "number"
    and value > 0
    and value <= MAX_SAMPLE_RATE
    and value < math.huge
    and value == math.floor(value)
end

local function resolve_sample_rate(api, project, snapshots)
  if type(api) == "table" and type(api.GetSetProjectInfo) == "function" then
    local use_ok, use_project_rate = pcall(
      api.GetSetProjectInfo, project, "PROJECT_SRATE_USE", 0, false)
    if use_ok and type(use_project_rate) == "number"
        and use_project_rate ~= 0 then
      local rate_ok, project_rate = pcall(
        api.GetSetProjectInfo, project, "PROJECT_SRATE", 0, false)
      if rate_ok and valid_sample_rate(project_rate) then
        return project_rate
      end
    end
  end

  if type(api) == "table" and type(api.GetAudioDeviceInfo) == "function" then
    local device_ok, retval, description = pcall(
      api.GetAudioDeviceInfo, "SRATE")
    local device_rate = type(description) == "string"
      and tonumber(description) or nil
    if device_ok and retval == true and valid_sample_rate(device_rate) then
      return device_rate
    end
  end

  local snapshot_rate
  for index, snapshot in ipairs(snapshots or {}) do
    local candidate = type(snapshot) == "table" and snapshot.sample_rate or nil
    if candidate == nil then
      return nil, "snapshot " .. index .. " is missing sample rate"
    end
    if not valid_sample_rate(candidate) then
      return nil, "snapshot " .. index
        .. " has an invalid sample rate; expected a finite positive integer"
    end
    if snapshot_rate ~= nil and candidate ~= snapshot_rate then
      return nil, "selected Items have mixed snapshot sample rates"
    end
    snapshot_rate = candidate
  end
  if snapshot_rate ~= nil then return snapshot_rate end
  return nil, "unable to determine a reliable sample rate for time-selection fill"
end

function M.new(reaper_api, options)
  options = type(options) == "table" and options or {}
  local dependencies = type(options.dependencies) == "table"
    and options.dependencies or {}
  local model_module = dependencies.ui_model or ui_model_module
  local initial_settings = settings_module.sanitize(options.settings)
  local model = model_module.new(initial_settings)

  return setmetatable({
    api = reaper_api,
    project = options.project == nil and 0 or options.project,
    color = options.color == nil and 0 or options.color,
    debounce_seconds = type(options.debounce_seconds) == "number"
      and math.max(0, options.debounce_seconds) or 0.15,
    dependencies = {
      loop_builder = dependencies.loop_builder or loop_builder_module,
      shepard = dependencies.shepard or shepard_module,
      regions = dependencies.regions or regions_module,
      state = dependencies.state or state_module,
      ui_model = model_module,
    },
    model = model,
    transaction = nil,
    outputs = {},
    has_preview = false,
    last_change_at = 0,
    closed = false,
  }, App)
end

function App:start()
  if self.transaction ~= nil then
    return nil, "application is already started"
  end
  local safe, transport_reason = ensure_transport_stopped(
    self, "starting LoopMaker")
  if not safe then return nil, transport_reason end
  local transaction, reason = self.dependencies.state.Transaction.capture(
    self.api, self.project)
  if not transaction then
    return fail(self, reason)
  end
  self.transaction = transaction
  if type(transaction.captured) == "table"
      and transaction.captured.project ~= nil then
    self.project = transaction.captured.project
  end
  return self:rebuild(true)
end

function App:rebuild(initial)
  if self.closed then return nil, "application is closed" end
  if self.transaction == nil then return nil, "application is not started" end
  if type(self.transaction.is_same_project) == "function"
      and not self.transaction:is_same_project() then
    return fail(self, "captured project is not the current project")
  end
  local safe, transport_reason = ensure_transport_stopped(self, "rebuild")
  if not safe then return nil, transport_reason end

  local warnings = {}
  if not initial and self.has_preview then
    -- 时间选区被视为"活输入"：先读取用户当前选区（在 restore_for_rebuild
    -- 回滚到启动基线之前），restore 成功后再写回，让本次 fill 使用最新选区。
    -- 循环点、编辑光标、Repeat 不属于活输入，rebuild 仍会回滚到启动基线。
    -- rebuild 只在 transport 停止时执行，写回选区是安全的。
    local current_start, current_end = call_api(
      self.api, "GetSet_LoopTimeRange2", self.project,
      false, false, 0, 0, false)
    if current_start == nil then return fail(self, current_end) end
    local selection_start = 0
    local selection_end = 0
    if type(current_start) == "number" and type(current_end) == "number"
        and current_end > current_start then
      selection_start = current_start
      selection_end = current_end
    end
    local restored, restore_warnings = self.transaction:restore_for_rebuild()
    if not restored then return fail(self, restore_warnings) end
    append_warnings(warnings, restore_warnings)
    -- Native Lua returns start/end times even for writes, not success/error.
    local written_start, written_end = call_api(
      self.api, "GetSet_LoopTimeRange2", self.project,
      true, false, selection_start, selection_end, false)
    if written_start == nil then return fail(self, written_end) end
  end

  local builder = self.dependencies.loop_builder
  local snapshots, snapshot_reason = builder.snapshot_selected(
    self.api, self.project)
  if not snapshots then return fail(self, snapshot_reason) end
  self.snapshots = snapshots
  self.dependencies.ui_model.set_selected_count(self.model, #snapshots)
  self.outputs = {}
  self.has_preview = false
  self.model.error = nil
  self.model.zero_crossings = {}
  self.model.timeline_fill = nil

  if #snapshots == 0 then
    self.model.warnings = warnings
    self.model.status = "Select one or more audio Items"
    self.dependencies.ui_model.mark_clean(self.model)
    return true
  end

  local time_start, time_end = call_api(
    self.api, "GetSet_LoopTimeRange2", self.project,
    false, false, 0, 0, false)
  if time_start == nil then return fail(self, time_end) end
  local time_selection = nil
  if type(time_start) == "number" and type(time_end) == "number"
      and time_end > time_start then
    time_selection = { start = time_start, finish = time_end }
  end

  local plans
  local plan_reason
  local outputs
  local output_warnings
  local options = {
    project = self.project,
    settings = self.model.settings,
    color = self.color,
  }

  local apply_target
  local call_ok
  if self.model.settings.shepard then
    call_ok, plans, plan_reason = call_dependency(
      self.dependencies.shepard, "plan_items", snapshots, self.model.settings)
    if not call_ok then return fail(self, plans) end
    if not plans then return fail(self, plan_reason) end
    apply_target = self.dependencies.shepard
  else
    call_ok, plans, plan_reason = call_dependency(
      builder, "plan_loops", snapshots, self.model.settings, nil)
    if not call_ok then return fail(self, plans) end
    if not plans then return fail(self, plan_reason) end
    call_ok, plans, plan_reason = call_dependency(
      builder, "analyze_plans", self.api, plans, self.model.settings)
    if not call_ok then return fail(self, plans) end
    if not plans then return fail(self, plan_reason) end
    self.model.zero_crossings = zero_crossing_rows(plans)
    if time_selection then
      local sample_rate, sample_rate_reason = resolve_sample_rate(
        self.api, self.project, snapshots)
      if not sample_rate then return fail(self, sample_rate_reason) end
      local summary
      call_ok, plans, summary = call_dependency(
        builder, "fill_time_selection",
        plans, time_selection, sample_rate, self.model.settings)
      if not call_ok then return fail(self, plans) end
      if not plans then return fail(self, summary) end
      self.model.timeline_fill = summary
    end
    apply_target = builder
  end

  call_ok, outputs, output_warnings = call_tracked_dependency(
    self, apply_target, "apply_plan", self.api, plans, options)
  if not call_ok then return fail_after_apply(self, outputs, warnings) end
  if not outputs then
    return fail_after_apply(self, output_warnings, warnings)
  end
  append_warnings(warnings, output_warnings)
  self.outputs = outputs
  self.has_preview = true
  self.model.warnings = warnings
  self.model.status = "Preview ready"
  self.dependencies.ui_model.mark_clean(self.model)
  if type(self.api.UpdateArrange) == "function" then
    pcall(self.api.UpdateArrange)
  end
  return true
end

function App:set_setting(key, value, now)
  local changed, reason = self.dependencies.ui_model.set(
    self.model, key, value)
  if changed == nil then return nil, reason end
  if changed and self.model.dirty then
    self.last_change_at = type(now) == "number" and now or 0
  end
  return changed
end

function App:replace_settings(values, now)
  local replaced, reason = self.dependencies.ui_model.replace_settings(
    self.model, values)
  if not replaced then return nil, reason end
  self.last_change_at = type(now) == "number" and now or 0
  return true
end

function App:tick(now)
  if self.closed then return nil, "application is closed" end
  if self.transaction == nil then return nil, "application is not started" end
  if type(self.transaction.is_same_project) == "function"
      and not self.transaction:is_same_project() then
    return fail(self, "captured project is not the current project")
  end
  local play_state, transport_reason = read_transport_state(self)
  if play_state == nil then return nil, transport_reason end
  if play_state ~= 0 then return false end
  local _, sync_reason = sync_preview_playback(self)
  if sync_reason then return fail(self, sync_reason) end
  if not self.model.dirty then return false end
  now = type(now) == "number" and now or self.last_change_at
  if now - self.last_change_at + 1e-12 < self.debounce_seconds then
    return false
  end
  return self:rebuild(false)
end

function App:can_apply()
  return self.has_preview
    and #self.outputs > 0
    and self.dependencies.ui_model.can_apply(self.model)
end

local function finite_number(value)
  return type(value) == "number"
    and value == value
    and value > -math.huge
    and value < math.huge
end

local function preview_range(self)
  local fill = self.model.timeline_fill
  if fill ~= nil then
    if type(fill) ~= "table"
        or not finite_number(fill.start)
        or not finite_number(fill["end"])
        or fill["end"] <= fill.start then
      return nil, "timeline fill preview range is invalid"
    end
    return fill.start, fill["end"]
  end

  local range_start
  local range_finish
  if type(self.outputs) ~= "table" then
    return nil, "no preview output is available"
  end
  local output_count = 0
  local maximum_index = 0
  for key in pairs(self.outputs) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil, "preview outputs must be a dense array"
    end
    output_count = output_count + 1
    maximum_index = math.max(maximum_index, key)
  end
  if output_count == 0 then
    return nil, "no preview output is available"
  end
  if maximum_index ~= output_count then
    return nil, "preview outputs must be a dense array"
  end
  for index = 1, output_count do
    local output = self.outputs[index]
    local plan = type(output) == "table" and output.plan or nil
    local position = type(plan) == "table" and plan.output_position or nil
    local length = type(plan) == "table" and plan.loop_length or nil
    if not finite_number(position) or not finite_number(length) or length <= 0 then
      return nil, "preview output " .. index
        .. " has an invalid output_position or loop_length"
    end
    local finish = position + length
    if not finite_number(finish) or finish <= position then
      return nil, "preview output " .. index .. " has an invalid end position"
    end
    range_start = range_start == nil and position or math.min(range_start, position)
    range_finish = range_finish == nil and finish or math.max(range_finish, finish)
  end
  if not finite_number(range_start) or not finite_number(range_finish)
      or range_finish <= range_start then
    return nil, "preview output range is invalid"
  end
  return range_start, range_finish
end

local function stop_preview_transport(self)
  local stop_method = type(self.api.OnStopButtonEx) == "function"
    and "OnStopButtonEx" or "OnStopButton"
  local _, stop_reason
  if stop_method == "OnStopButtonEx" then
    _, stop_reason = call_api(self.api, stop_method, self.project)
  else
    _, stop_reason = call_api(self.api, stop_method)
  end
  if stop_reason then return nil, stop_reason end
  self.transaction.preview_playback_started = false
  return true
end

local function release_preview_range(self)
  local called, released, reason = call_transaction(
    self.transaction, "release_preview_range")
  if not called then return nil, released end
  if not released then return nil, reason end
  return true
end

local function cleanup_preview(self, stop_transport)
  local errors = {}
  if stop_transport then
    local stopped, stop_reason = stop_preview_transport(self)
    if not stopped then errors[#errors + 1] = tostring(stop_reason) end
  end
  local released, release_reason = release_preview_range(self)
  if not released then errors[#errors + 1] = tostring(release_reason) end
  if #errors > 0 then return nil, table.concat(errors, "; ") end
  return true
end

local function with_cleanup_error(reason, cleanup_reason)
  if cleanup_reason == nil or cleanup_reason == "" then return tostring(reason) end
  return tostring(reason) .. "; cleanup failed: " .. tostring(cleanup_reason)
end

function App:apply()
  if self.closed then return nil, "application is closed" end
  if self.transaction == nil then return nil, "application is not started" end
  if type(self.transaction.is_same_project) == "function"
      and not self.transaction:is_same_project() then
    return nil, "captured project is not the current project"
  end
  local safe, transport_reason = ensure_transport_stopped(self, "Apply")
  if not safe then return nil, transport_reason end
  local _, sync_reason = sync_preview_playback(self)
  if sync_reason then return nil, sync_reason end
  if self.model.dirty then
    local rebuilt, rebuild_reason = self:rebuild(false)
    if not rebuilt then return nil, rebuild_reason end
  end
  if not self:can_apply() then
    return nil, self.model.error or "no preview output is available"
  end

  local owns_playback, ownership_reason = owns_preview_playback(self.transaction)
  if owns_playback == nil then return nil, ownership_reason end
  if owns_playback or self.transaction.preview_range_state ~= nil then
    local released, release_reason = cleanup_preview(self, false)
    if not released then return nil, release_reason end
  end

  local planned_regions
  if self.model.settings.create_regions then
    local rate, rate_reason = resolve_sample_rate(self.api, self.project, self.snapshots)
    if not rate then return nil, rate_reason end
    local called, planned, plan_reason = call_dependency(
      self.dependencies.regions, "plan_outputs", self.outputs, rate,
      self.model.settings, self.model.settings.color_items and self.color or 0)
    if not called or not planned then return nil, called and plan_reason or planned end
    planned_regions = planned
  end
  if self.model.settings.glue then
    local called, glued, glue_reason, _, invoked = call_tracked_dependency(
      self, self.dependencies.loop_builder, "glue_outputs",
      self.api, self.project, self.outputs, {
        settings = self.model.settings,
        color = self.color,
      })
    if not called then invoked = glue_reason == true end
    if not called or not glued then
      local reason = tostring(called and glue_reason or glued)
      if invoked then
        reason = reason
          .. "; Glue may have created a media file on disk that project restore cannot remove"
      end
      return fail_after_apply(self, reason, self.model.warnings)
    end
    self.outputs = glued
  end

  local created_regions
  if planned_regions then
    local called, created, create_reason = call_dependency(
      self.dependencies.regions, "create", self.api, self.project, planned_regions)
    if not called or not created then
      return fail_after_apply(self, called and create_reason or created, self.model.warnings)
    end
    created_regions = created
  end

  local called, applied, reason = call_transaction(self.transaction, "mark_applied")
  if not called then reason, applied = applied, nil end
  if not applied then
    if created_regions then
      local removed_call, removed, remove_reason = call_dependency(
        self.dependencies.regions, "remove", self.api, self.project, created_regions)
      if not removed_call or not removed then
        reason = with_cleanup_error(reason, removed_call and remove_reason or removed)
      end
    end
    if transaction_is_active(self.transaction) then
      return fail_after_apply(self, reason, self.model.warnings)
    end
    return fail(self, reason)
  end
  self.closed = true
  self.model.status = "Applied"
  return true
end

function App:cancel()
  if self.closed then return true end
  if self.transaction == nil then return nil, "application is not started" end
  local safe, transport_reason = ensure_transport_stopped(self, "Cancel")
  if not safe then return nil, transport_reason end
  local restored, warnings_or_reason
  if type(self.transaction.is_same_project) == "function"
      and not self.transaction:is_same_project()
      and type(self.transaction.restore_in_background) == "function" then
    restored, warnings_or_reason = self.transaction:restore_in_background()
  else
    restored, warnings_or_reason = self.transaction:restore()
  end
  if not restored then return fail(self, warnings_or_reason) end
  self.model.warnings = {}
  append_warnings(self.model.warnings, warnings_or_reason)
  self.closed = true
  self.model.status = "Cancelled"
  return true
end

function App:toggle_preview()
  if self.closed then return nil, "application is closed" end
  if self.transaction == nil then return nil, "application is not started" end
  if type(self.transaction.is_same_project) == "function"
      and not self.transaction:is_same_project() then
    return nil, "captured project is not the current project"
  end
  if not self.has_preview then
    return nil, "no preview output is available"
  end

  local _, sync_reason = sync_preview_playback(self)
  if sync_reason then return nil, sync_reason end

  local play_state, reason = read_transport_state(self)
  if play_state == nil then return nil, reason end
  if play_state ~= 0 then
    self.model.error = nil
    self.model.status =
      "Preview is playing; stop REAPER transport to end preview"
    return true
  end

  local owns_playback, ownership_reason = owns_preview_playback(self.transaction)
  if owns_playback == nil then return nil, ownership_reason end
  if owns_playback or self.transaction.preview_range_state ~= nil then
    local released, release_reason = cleanup_preview(self, false)
    if not released then return nil, release_reason end
  end

  local range_start, range_finish = preview_range(self)
  if range_start == nil then return nil, range_finish end
  local called, prepared, prepare_reason = call_transaction(
    self.transaction, "prepare_preview_range", range_start, range_finish)
  if not called then return nil, prepared end
  if not prepared then return nil, prepare_reason end

  local play_method = type(self.api.OnPlayButtonEx) == "function"
    and "OnPlayButtonEx" or "OnPlayButton"
  local _, play_reason
  if play_method == "OnPlayButtonEx" then
    _, play_reason = call_api(self.api, play_method, self.project)
  else
    _, play_reason = call_api(self.api, play_method)
  end
  if play_reason then
    local _, cleanup_reason = cleanup_preview(self, true)
    return nil, with_cleanup_error(play_reason, cleanup_reason)
  end

  local mark_called, marked, mark_reason = call_transaction(
    self.transaction, "mark_preview_playback_started")
  if not mark_called or not marked then
    local primary_reason = mark_called and mark_reason or marked
    local _, cleanup_reason = cleanup_preview(self, true)
    return nil, with_cleanup_error(primary_reason, cleanup_reason)
  end
  self.model.status = "Preview playing"
  return true
end

return M
