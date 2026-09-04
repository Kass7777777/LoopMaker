local source = debug.getinfo(1, "S").source
local script_path = source:sub(1, 1) == "@" and source:sub(2) or source
local normalized_path = script_path:gsub("\\", "/")
local root = normalized_path:match("^(.*)/tests/[^/]+$")

if not root then
  reaper.ShowMessageBox(
    "无法确定 LoopMaker 项目目录。",
    "LoopMaker 循环构造自检",
    0)
  return
end

package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, package.config:sub(3, 3))

local loop_builder = require("lib.loop_builder")
local naming = require("lib.naming")
local state = require("lib.state")

local function fail(message)
  error(tostring(message), 0)
end

local function require_result(value, reason)
  if value == nil then fail(reason or "操作失败") end
  return value
end

local function close_enough(expected, actual)
  return type(actual) == "number" and math.abs(expected - actual) <= 1e-7
end

local function rounded_sample(seconds, sample_rate)
  local samples = seconds * sample_rate
  if samples >= 0 then return math.floor(samples + 0.5) end
  return math.ceil(samples - 0.5)
end

local function valid_sample_rate(value)
  return type(value) == "number"
    and value > 0
    and value <= 10000000
    and value < math.huge
    and value == math.floor(value)
end

local function stable_rng(seed)
  local value = seed % 2147483647
  if value <= 0 then value = 1 end
  return function()
    value = (value * 48271) % 2147483647
    return (value - 1) / 2147483646
  end
end

local function resolve_sample_rate(project, snapshots)
  if type(reaper.GetSetProjectInfo) == "function" then
    local use_ok, use_project_rate = pcall(
      reaper.GetSetProjectInfo, project, "PROJECT_SRATE_USE", 0, false)
    if use_ok and type(use_project_rate) == "number"
        and use_project_rate ~= 0 then
      local rate_ok, project_rate = pcall(
        reaper.GetSetProjectInfo, project, "PROJECT_SRATE", 0, false)
      if rate_ok and valid_sample_rate(project_rate) then
        return project_rate, "project rate"
      end
    end
  end

  if type(reaper.GetAudioDeviceInfo) == "function" then
    local device_ok, retval, description = pcall(
      reaper.GetAudioDeviceInfo, "SRATE")
    local device_rate = type(description) == "string"
      and tonumber(description) or nil
    if device_ok and retval == true and valid_sample_rate(device_rate) then
      return device_rate, "device SRATE"
    end
  end

  local source_rate
  for index, snapshot in ipairs(snapshots) do
    if not valid_sample_rate(snapshot.sample_rate) then
      fail("无法从项目、设备或 source " .. index .. " 取得可靠的整数采样率。")
    end
    if source_rate ~= nil and snapshot.sample_rate ~= source_rate then
      fail("项目和设备采样率不可用，且所选 source 的采样率不一致。")
    end
    source_rate = snapshot.sample_rate
  end
  if source_rate == nil then
    fail("无法从项目、设备或一致 source rate 取得活动采样率。")
  end
  return source_rate, "consistent source rate"
end

local TEST_COLOR = 0x335577
local VARIATION_COUNT = 5
local TARGET_SLOT_COUNT = 7
local BOUNDARY_FADE = 0.003

local function item_guid(item)
  local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if not ok or type(guid) ~= "string" or guid == "" then
    fail("无法读取 Item GUID。")
  end
  return guid
end

local function verify_restored_state(captured)
  local count = reaper.CountMediaItems(captured.project)
  if count ~= #captured.all_items then
    return nil, "restore 后项目 Item 数量未恢复。"
  end

  local current_by_guid = {}
  for index = 0, count - 1 do
    local item = reaper.GetMediaItem(captured.project, index)
    local guid = item_guid(item)
    if current_by_guid[guid] then return nil, "restore 后存在重复 GUID：" .. guid end
    current_by_guid[guid] = item
  end
  for _, baseline in ipairs(captured.all_items) do
    local item = current_by_guid[baseline.guid]
    if not item then return nil, "restore 后缺少原始 GUID：" .. baseline.guid end
    if reaper.IsMediaItemSelected(item) ~= baseline.selected then
      return nil, "restore 后 Item 选择状态不一致：" .. baseline.guid
    end
  end

  for _, baseline in ipairs(captured.selected_items) do
    local item = current_by_guid[baseline.guid]
    local chunk_ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not chunk_ok or chunk ~= baseline.chunk then
      return nil, "restore 后原始 Item chunk 不一致：" .. baseline.guid
    end
  end

  local time_start, time_end = reaper.GetSet_LoopTimeRange2(
    captured.project, false, false, 0, 0, false)
  if not close_enough(captured.time_start, time_start)
      or not close_enough(captured.time_end, time_end) then
    return nil, "restore 后时间选区不一致。"
  end
  local loop_start, loop_end = reaper.GetSet_LoopTimeRange2(
    captured.project, false, true, 0, 0, false)
  if not close_enough(captured.loop_start, loop_start)
      or not close_enough(captured.loop_end, loop_end) then
    return nil, "restore 后循环点不一致。"
  end
  if not close_enough(captured.cursor,
      reaper.GetCursorPositionEx(captured.project)) then
    return nil, "restore 后编辑光标不一致。"
  end
  local repeat_state = reaper.GetSetRepeatEx(captured.project, -1)
  repeat_state = type(repeat_state) == "number" and repeat_state > 0 and 1 or 0
  if repeat_state ~= captured.repeat_state then
    return nil, "restore 后 Repeat 状态不一致。"
  end
  if reaper.GetPlayStateEx(captured.project) ~= 0 then
    return nil, "restore 后 transport 未保持停止。"
  end
  return true
end

local function mutate_transport_state(transaction, snapshots)
  local project = transaction.captured.project
  if reaper.GetPlayStateEx(project) ~= 0 then
    fail("transport 必须保持停止，才能修改并验证临时项目状态。")
  end

  local latest_source_end = 0
  for _, snapshot in ipairs(snapshots) do
    latest_source_end = math.max(
      latest_source_end, snapshot.position + snapshot.length)
  end
  local loop_start = math.max(0, latest_source_end + 2)
  local loop_end = loop_start + 1
  if close_enough(loop_start, transaction.captured.loop_start)
      and close_enough(loop_end, transaction.captured.loop_end) then
    loop_start = loop_end + 1
    loop_end = loop_start + 1
  end
  local cursor = loop_start + 0.25
  if close_enough(cursor, transaction.captured.cursor) then
    cursor = loop_start + 0.5
  end
  local repeat_state = transaction.captured.repeat_state == 1 and 0 or 1

  reaper.GetSet_LoopTimeRange2(
    project, true, true, loop_start, loop_end, false)
  local actual_loop_start, actual_loop_end = reaper.GetSet_LoopTimeRange2(
    project, false, true, 0, 0, false)
  if not close_enough(loop_start, actual_loop_start)
      or not close_enough(loop_end, actual_loop_end)
      or (close_enough(transaction.captured.loop_start, actual_loop_start)
        and close_enough(transaction.captured.loop_end, actual_loop_end)) then
    fail("临时循环点修改未生效或仍与事务基线相同。")
  end

  reaper.GetSetRepeatEx(project, repeat_state)
  local actual_repeat = reaper.GetSetRepeatEx(project, -1)
  actual_repeat = type(actual_repeat) == "number" and actual_repeat > 0 and 1 or 0
  if actual_repeat ~= repeat_state
      or actual_repeat == transaction.captured.repeat_state then
    fail("临时 Repeat 修改未生效或仍与事务基线相同。")
  end

  reaper.SetEditCurPos2(project, cursor, false, false)
  local actual_cursor = reaper.GetCursorPositionEx(project)
  if not close_enough(cursor, actual_cursor)
      or close_enough(transaction.captured.cursor, actual_cursor) then
    fail("临时编辑光标修改未生效或仍与事务基线相同。")
  end

  if reaper.GetPlayStateEx(project) ~= 0 then
    fail("临时项目状态修改后 transport 不再是停止状态。")
  end
end

local function validate_unique_variations(plans, snapshots)
  if #plans ~= #snapshots * VARIATION_COUNT then
    fail("Loops=5 时，每个 source 必须先生成 5 个唯一变体。")
  end

  local groups = {}
  for _, snapshot in ipairs(snapshots) do
    groups[snapshot] = { count = 0, variations = {}, starts = {} }
  end
  for index, plan in ipairs(plans) do
    local group = groups[plan.source_snapshot]
    if not group then fail("唯一变体规划 " .. index .. " 引用了未知 source。") end
    local variation = math.tointeger(plan.variation_index)
    if variation == nil or variation < 0 or variation >= VARIATION_COUNT then
      fail("唯一变体规划 " .. index .. " 的 variation_index 超出 0..4。")
    end
    if group.variations[variation] then
      fail("同一 source 重复生成 variation_index=" .. variation .. "。")
    end
    for _, source_start in ipairs(group.starts) do
      if close_enough(source_start, plan.source_project_start) then
        fail("同一 source 的 5 个变体未使用唯一取料区间。")
      end
    end
    group.count = group.count + 1
    group.variations[variation] = true
    group.starts[#group.starts + 1] = plan.source_project_start
  end

  for _, snapshot in ipairs(snapshots) do
    local group = groups[snapshot]
    if group.count ~= VARIATION_COUNT then
      fail("source 未完整生成 5 个唯一变体。")
    end
    for variation = 0, VARIATION_COUNT - 1 do
      if not group.variations[variation] then
        fail("source 缺少 variation_index=" .. variation .. "。")
      end
    end
  end
end

local function establish_time_selection(transaction, analyzed, sample_rate)
  local natural_length = math.huge
  local latest_source_end = 0
  for _, plan in ipairs(analyzed) do
    natural_length = math.min(natural_length, plan.loop_length)
    local snapshot = plan.source_snapshot
    latest_source_end = math.max(
      latest_source_end, snapshot.position + snapshot.length)
  end

  local slot_samples = math.floor(natural_length * sample_rate + 1e-7)
  local minimum_samples = rounded_sample(
    loop_builder.MIN_MULTI_LOOP_SOURCE_SPAN, sample_rate)
  if slot_samples < minimum_samples then
    fail("所选素材分析后的自然 Loop 太短，无法建立至少 24 ms 的样本精确槽位。")
  end

  local start_sample = rounded_sample(math.max(0, latest_source_end + 1), sample_rate)
  local end_sample = start_sample + TARGET_SLOT_COUNT * slot_samples
  if rounded_sample(transaction.captured.time_start, sample_rate) == start_sample
      and rounded_sample(transaction.captured.time_end, sample_rate) == end_sample then
    start_sample = start_sample + sample_rate
    end_sample = end_sample + sample_rate
  end
  local start_time = start_sample / sample_rate
  local end_time = end_sample / sample_rate
  reaper.GetSet_LoopTimeRange2(
    transaction.captured.project, true, false, start_time, end_time, false)
  local actual_start, actual_end = reaper.GetSet_LoopTimeRange2(
    transaction.captured.project, false, false, 0, 0, false)
  if rounded_sample(actual_start, sample_rate) ~= start_sample
      or rounded_sample(actual_end, sample_rate) ~= end_sample
      or (close_enough(transaction.captured.time_start, actual_start)
        and close_enough(transaction.captured.time_end, actual_end)) then
    fail("临时时间选区修改未生效或仍与事务基线相同。")
  end
  return {
    start = actual_start,
    finish = actual_end,
    start_sample = start_sample,
    end_sample = end_sample,
    slot_samples = slot_samples,
  }
end

local function validate_fill(plans, summary, snapshots, selection, sample_rate)
  if summary.start_sample ~= selection.start_sample
      or summary.end_sample ~= selection.end_sample then
    fail("fill summary 的精确 start/end sample 与临时时间选区不一致。")
  end
  if summary.total_samples ~= summary.end_sample - summary.start_sample then
    fail("fill summary 的 total_samples 不等于 end_sample-start_sample。")
  end
  if summary.slot_count <= VARIATION_COUNT then
    fail("时间选区必须把 5 个唯一变体扩展到多于 5 个槽位。")
  end
  if summary.slot_count ~= TARGET_SLOT_COUNT then
    fail("确定性时间选区应产生 " .. TARGET_SLOT_COUNT .. " 个槽位。")
  end
  if summary.slot_count * summary.slot_samples ~= summary.total_samples then
    fail("slot_count*slot_samples 不等于 total_samples。")
  end
  if summary.slot_samples ~= selection.slot_samples then
    fail("fill 使用的 slot_samples 与确定性槽长不一致。")
  end
  if summary.variation_count ~= VARIATION_COUNT
      or summary.source_count ~= #snapshots then
    fail("fill summary 的 variation/source 数量不一致。")
  end
  if #plans ~= summary.slot_count * #snapshots then
    fail("fill 后规划数量不等于 source_count*slot_count。")
  end

  local groups = {}
  for _, snapshot in ipairs(snapshots) do
    groups[snapshot] = {}
  end
  for index, plan in ipairs(plans) do
    local group = groups[plan.source_snapshot]
    if not group then fail("fill 规划 " .. index .. " 引用了未知 source。") end
    group[#group + 1] = plan
  end

  local shared_sequence
  for _, snapshot in ipairs(snapshots) do
    local group = groups[snapshot]
    if #group ~= summary.slot_count then
      fail("每个 source 的 fill 槽位数必须等于 summary.slot_count。")
    end
    local counts = {}
    for variation = 0, VARIATION_COUNT - 1 do counts[variation] = 0 end
    local sequence = {}
    for index, plan in ipairs(group) do
      local variation = math.tointeger(plan.asset_variant_index)
      if variation == nil or variation < 0 or variation >= VARIATION_COUNT then
        fail("asset_variant_index 必须完整限制在 0..4。")
      end
      counts[variation] = counts[variation] + 1
      sequence[index] = variation
      if plan.variation_index ~= variation then
        fail("asset_variant_index 与 variation_index 不一致。")
      end
      if plan.sequence_index ~= index - 1 then
        fail("sequence_index 不连续。")
      end
      if plan.slot_samples ~= summary.slot_samples
          or rounded_sample(plan.loop_length, sample_rate) ~= summary.slot_samples then
        fail("槽位 " .. index .. " 未保持精确等长样本数。")
      end
      local expected_start = summary.start_sample
        + (index - 1) * summary.slot_samples
      if rounded_sample(plan.output_position, sample_rate) ~= expected_start then
        fail("槽位 " .. index .. " 未从精确样本位置开始。")
      end
      if not close_enough(BOUNDARY_FADE, plan.components[1].fade_in)
          or not close_enough(BOUNDARY_FADE,
            plan.components[#plan.components].fade_out) then
        fail("槽位 " .. index .. " 的组件外边界未保留 3 ms Fade。")
      end
      if index > 1 and sequence[index] == sequence[index - 1] then
        fail("5 个变体可避免相邻重复，但槽位序列出现了相邻重复。")
      end
    end

    local minimum, maximum = math.huge, -math.huge
    for variation = 0, VARIATION_COUNT - 1 do
      if counts[variation] == 0 then
        fail("asset_variant_index 未完整覆盖 0..4。")
      end
      minimum = math.min(minimum, counts[variation])
      maximum = math.max(maximum, counts[variation])
    end
    if maximum - minimum > 1 then
      fail("均衡随机失败：变体出现次数最大差超过 1。")
    end

    if shared_sequence == nil then
      shared_sequence = sequence
    else
      for index, variation in ipairs(sequence) do
        if variation ~= shared_sequence[index] then
          fail("多个 source 未共享同一槽位变体序列。")
        end
      end
    end

    local last = group[#group]
    if rounded_sample(
        last.output_position + last.loop_length, sample_rate) ~= summary.end_sample then
      fail("最后槽位的结束 sample 不等于 summary.end_sample。")
    end
  end
end

local function apply_with_mutation_tracking(transaction, plans, settings)
  local began, begin_reason = transaction:begin_preview_mutation()
  if not began then fail("preview mutation begin 失败：" .. tostring(begin_reason)) end

  local results = table.pack(pcall(loop_builder.apply_plan, reaper, plans, {
    project = transaction.captured.project,
    settings = settings,
    color = TEST_COLOR,
  }))
  local ended, end_reason = transaction:end_preview_mutation()
  if not ended then
    fail("preview mutation end 失败：" .. tostring(end_reason))
  end
  if not results[1] then
    fail("apply_plan 抛出异常：" .. tostring(results[2]))
  end
  if results[2] == nil then
    fail("apply_plan 失败：" .. tostring(results[3]))
  end
  if #transaction.tracked_preview_items == 0 then
    fail("mutation tracking 未记录 apply 创建的预览 Item。")
  end
  return results[2], results[3]
end

local function validate_outputs(outputs, plans, summary, sample_rate, settings,
    captured, snapshots)
  if #outputs ~= #plans then
    fail("输出数量与 fill 后规划数量不一致。")
  end

  local output_guids = {}
  local component_count = 0
  for index, output in ipairs(outputs) do
    local plan = plans[index]
    if output.main == nil or output.main ~= output.items[1] then
      fail("输出 " .. index .. " 缺少 main component。")
    end
    if #output.items ~= #plan.components then
      fail("输出 " .. index .. " 的 Item 数量与 components 不一致。")
    end

    local expected_name = require_result(naming.build(
      plan.source_snapshot.name, settings, plan.asset_variant_index))
    local first_sample = math.huge
    local last_sample = -math.huge
    for component_index, item in ipairs(output.items) do
      component_count = component_count + 1
      local component = plan.components[component_index]
      if not component then
        fail("输出 " .. index .. " 缺少对应的 component 规划。")
      end
      if component.wrap_source then
        fail("输出 " .. index .. " 的 component 不得启用 source wrap。")
      end
      local guid = item_guid(item)
      if output_guids[guid] then fail("输出存在重复 GUID：" .. guid) end
      output_guids[guid] = true
      local take = reaper.GetActiveTake(item)
      if not take then fail("输出 " .. index .. " 缺少活动 take。") end
      local _, take_name = reaper.GetSetMediaItemTakeInfo_String(
        take, "P_NAME", "", false)
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local expected_offset = plan.source_snapshot.start_offset
        + (component.source_project_start - plan.source_snapshot.position)
          * plan.source_snapshot.playrate
      local expected_fade_in = component.fade_in or 0
      local expected_fade_out = component.fade_out or 0
      if not close_enough(component.position, position)
          or not close_enough(component.length, length)
          or not close_enough(expected_offset,
            reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"))
          or not close_enough(plan.source_snapshot.playrate,
            reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
          or not close_enough(0,
            reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC"))
          or not close_enough(expected_fade_in,
            reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"))
          or not close_enough(expected_fade_out,
            reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"))
          or not close_enough(-1,
            reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO"))
          or not close_enough(-1,
            reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO")) then
        fail("输出 " .. index .. " component 参数或自动 Fade 状态不符合规划。")
      end
      if expected_fade_in > 0 and not close_enough(component.fade_shape or 0,
          reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE")) then
        fail("输出 " .. index .. " component 淡入曲线不符合规划。")
      end
      if expected_fade_out > 0 and not close_enough(component.fade_shape or 0,
          reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE")) then
        fail("输出 " .. index .. " component 淡出曲线不符合规划。")
      end
      if take_name ~= expected_name then fail("输出名称不符合变体规划。") end
      if not reaper.IsMediaItemSelected(item) then
        fail("输出 " .. index .. " 未保持选中。")
      end
      if reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")
          ~= (TEST_COLOR | 0x1000000) then
        fail("输出颜色不符合规划。")
      end
      first_sample = math.min(first_sample, rounded_sample(position, sample_rate))
      last_sample = math.max(
        last_sample, rounded_sample(position + length, sample_rate))
    end

    local expected_start = summary.start_sample
      + plan.sequence_index * summary.slot_samples
    if first_sample ~= expected_start
        or last_sample ~= expected_start + summary.slot_samples then
      fail("输出 " .. index .. " 的实际 Item 边界未精确覆盖一个槽位。")
    end
    if not close_enough(BOUNDARY_FADE,
        reaper.GetMediaItemInfo_Value(output.items[1], "D_FADEINLEN"))
        or not close_enough(BOUNDARY_FADE,
          reaper.GetMediaItemInfo_Value(
            output.items[#output.items], "D_FADEOUTLEN")) then
      fail("输出 " .. index .. " apply 后的组件外边界不是 3 ms Fade。")
    end
  end

  local expected_project_items = #captured.all_items
    + component_count - #snapshots
  if reaper.CountMediaItems(captured.project) ~= expected_project_items then
    fail("apply 后项目 Item 数量与组件规划不一致。")
  end
end

local transaction
local outputs
local snapshots
local analyzed
local expanded
local summary
local sample_rate
local sample_rate_source
local selection
local settings = {
  loops = VARIATION_COUNT,
  glue = false,
  shuffle = true,
  position_space = 0,
  cf_ratio = 0.05,
  color_items = true,
}

if reaper.GetPlayStateEx(0) ~= 0 then
  reaper.ShowMessageBox(
    "请先停止 REAPER 播放/录音，再运行循环构造自检。",
    "LoopMaker 循环构造自检",
    0)
  return
end

local confirmed = reaper.ShowMessageBox(
  table.concat({
    "此自检要求至少选中 2 个包含活动音频 take 的 Item，以真实验证多个 source 共享同一变体序列。",
    "自检会在事务中临时修改时间选区、循环点、Repeat、编辑光标和 Item，然后验证全部恢复到启动前基线。",
    "默认不会调用 Glue，也不会主动生成 Glue 磁盘文件。",
    "请先保存专用测试工程。是否继续？",
  }, "\n"),
  "LoopMaker 循环构造自检",
  4)
if confirmed ~= 6 then return end

local run_ok, run_error = xpcall(function()
  if reaper.GetPlayStateEx(0) ~= 0 then
    fail("确认后 transport 已启动；请先停止 REAPER 播放/录音再重试。")
  end
  transaction = require_result(state.Transaction.capture(reaper, 0))
  snapshots = require_result(loop_builder.snapshot_selected(
    reaper, transaction.captured.project))
  if #snapshots < 2 then
    fail("请至少选中 2 个包含活动音频 take 的 Item，以验证多个 source 共享同一变体序列；MIDI Item 不计入。")
  end
  mutate_transport_state(transaction, snapshots)
  sample_rate, sample_rate_source = resolve_sample_rate(
    transaction.captured.project, snapshots)
  if not valid_sample_rate(sample_rate) then
    fail("活动采样率验证失败。")
  end

  local unique = require_result(loop_builder.plan_loops(
    snapshots, settings, nil, stable_rng(13579)))
  validate_unique_variations(unique, snapshots)

  analyzed = require_result(loop_builder.analyze_plans(reaper, unique, settings))
  validate_unique_variations(analyzed, snapshots)
  for index, plan in ipairs(analyzed) do
    if type(plan.warning) == "string"
        and plan.warning:find("audio accessor", 1, true) then
      fail("规划 " .. index .. " 的零交叉搜索超出 audio accessor："
        .. plan.warning)
    end
    if not close_enough(BOUNDARY_FADE, plan.components[1].fade_in)
        or not close_enough(BOUNDARY_FADE,
          plan.components[#plan.components].fade_out) then
      fail("分析后规划 " .. index .. " 丢失 3 ms 外边界安全 Fade。")
    end
  end

  selection = establish_time_selection(transaction, analyzed, sample_rate)
  expanded, summary = loop_builder.fill_time_selection(
    analyzed,
    { start = selection.start, finish = selection.finish },
    sample_rate,
    settings,
    stable_rng(24680))
  expanded = require_result(expanded, summary)
  validate_fill(expanded, summary, snapshots, selection, sample_rate)

  outputs = apply_with_mutation_tracking(transaction, expanded, settings)
  validate_outputs(outputs, expanded, summary, sample_rate, settings,
    transaction.captured, snapshots)
end, debug.traceback)

local restore_ok = true
local restore_detail
if transaction then
  restore_ok, restore_detail = transaction:restore()
  if restore_ok and type(restore_detail) == "table" and #restore_detail > 0 then
    restore_ok = false
    restore_detail = "restore 返回警告：" .. table.concat(restore_detail, "; ")
  end
  if restore_ok then
    restore_ok, restore_detail = verify_restored_state(transaction.captured)
  end
end

if not run_ok or not restore_ok then
  local messages = {}
  if not run_ok then
    messages[#messages + 1] = "自检失败：\n" .. tostring(run_error)
  end
  if transaction == nil then
    messages[#messages + 1] = "未能创建 state transaction；未修改项目。"
  elseif not restore_ok then
    messages[#messages + 1] = "state transaction restore 失败：\n"
      .. tostring(restore_detail)
  else
    messages[#messages + 1] = "state transaction 已恢复，未保留循环输出。"
  end
  reaper.ShowMessageBox(
    table.concat(messages, "\n\n"),
    "LoopMaker 循环构造自检",
    0)
  return
end

reaper.ShowMessageBox(
  table.concat({
    "循环构造自检通过。",
    "活动采样率：" .. tostring(sample_rate) .. " Hz（" .. sample_rate_source .. "）。",
    "已临时建立样本对齐时间选区，并验证 Loops=5 先生成完整唯一变体集，再稳定随机填充为 "
      .. tostring(summary.slot_count) .. " 个槽位。",
    "已验证 summary 精确起止样本、slot_count*slot_samples=total、每槽等长且最后结束 sample=end。",
    "已验证 asset_variant_index 完整覆盖 0..4、出现次数最大差 1、无相邻重复；多个 source 共用同一序列。",
    "已验证每个输出的组件外边界 3 ms Fade，以及 apply 后 Item 数量、几何、source offset、playrate、命名、颜色和选择状态。",
    "apply 已由 preview mutation tracking 包围；自检主动改动过时间选区、循环点、Repeat 和光标，并已确认原始 GUID、chunk、选择及这些项目状态全部恢复到事务基线。",
    "几何与 REAPER 属性检查已完成；自动化只能证明结构，click/pop、能量下陷和 Wwise 切换仍必须人工实听。",
    "默认未调用 Glue，未生成 Glue 磁盘文件；Glue 样本数与失败清理由人工验收单独确认。",
  }, "\n"),
  "LoopMaker 循环构造自检",
  0)
