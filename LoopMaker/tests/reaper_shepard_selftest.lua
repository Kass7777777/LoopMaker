local source = debug.getinfo(1, "S").source
local script_path = source:sub(1, 1) == "@" and source:sub(2) or source
local normalized_path = script_path:gsub("\\", "/")
local root = normalized_path:match("^(.*)/tests/[^/]+$")

if not root then
  reaper.ShowMessageBox(
    "无法确定 LoopMaker 项目目录。",
    "LoopMaker Shepard Tone 自检",
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
local shepard = require("lib.shepard")
local state = require("lib.state")

local TEST_COLOR = 0x553377
local EPSILON = 1e-7

local function fail(message)
  error(tostring(message), 0)
end

local function require_result(value, reason)
  if value == nil then fail(reason or "操作失败") end
  return value
end

local function close_enough(expected, actual)
  return type(actual) == "number" and math.abs(expected - actual) <= EPSILON
end

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
  local current_guids = {}
  for index = 0, count - 1 do
    local guid = item_guid(reaper.GetMediaItem(captured.project, index))
    if current_guids[guid] then return nil, "restore 后存在重复 GUID：" .. guid end
    current_guids[guid] = true
  end
  for guid in pairs(captured.initial_guid_set) do
    if not current_guids[guid] then return nil, "restore 后缺少原始 GUID：" .. guid end
  end

  local selected = {}
  local selected_count = reaper.CountSelectedMediaItems(captured.project)
  for index = 0, selected_count - 1 do
    local item = reaper.GetSelectedMediaItem(captured.project, index)
    selected[item_guid(item)] = item
  end
  if selected_count ~= #captured.selected_items then
    return nil, "restore 后选中 Item 数量不一致。"
  end
  for _, baseline in ipairs(captured.selected_items) do
    local item = selected[baseline.guid]
    if not item then return nil, "restore 后未选中原始 Item：" .. baseline.guid end
    local chunk_ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not chunk_ok or chunk ~= baseline.chunk then
      return nil, "restore 后原始 Item chunk 不一致：" .. baseline.guid
    end
  end
  return true
end

local function pitch_points_in_range(envelope, duration)
  local points = {}
  local count = reaper.CountEnvelopePoints(envelope)
  for index = 0, count - 1 do
    local ok, time, value, shape, tension = reaper.GetEnvelopePoint(envelope, index)
    if ok and time >= -EPSILON and time <= duration + EPSILON then
      points[#points + 1] = {
        time = time,
        value = value,
        shape = shape,
        tension = tension,
      }
    end
  end
  table.sort(points, function(left, right) return left.time < right.time end)
  return points
end

local transaction
local run_ok, run_error = xpcall(function()
  transaction = require_result(state.Transaction.capture(reaper, 0))
  local snapshots = require_result(loop_builder.snapshot_selected(reaper, 0))
  if #snapshots == 0 then
    fail("请至少选中一个包含活动音频 take 的 Item；MIDI Item 不参与自检。")
  end

  local settings = {
    loops = 1,
    pitch = 12,
    glue = false,
    prefix = "ShepardSelfTest",
    separator = "_",
    remove_ext = true,
    number = true,
    start_number = 7,
    leading_zeros = 2,
    color_items = true,
  }
  local base_volumes = {}
  for index, snapshot in ipairs(snapshots) do
    base_volumes[index] = reaper.GetMediaItemTakeInfo_Value(snapshot.take, "D_VOL")
  end

  local plans = require_result(shepard.plan_items(snapshots, settings))
  local outputs = require_result(shepard.apply_plan(reaper, plans, {
    project = transaction.captured.project,
    settings = settings,
    color = TEST_COLOR,
  }))
  if #outputs ~= #plans then fail("输出数量与 Shepard 规划数量不一致。") end

  local output_guids = {}
  for plan_index, output in ipairs(outputs) do
    local plan = plans[plan_index]
    local expected_name = require_result(naming.build(
      plan.source_snapshot.name, settings, plan_index - 1))
    if #output.items ~= plan.lane_count or #output.takes ~= plan.lane_count then
      fail("输出 " .. plan_index .. " 的 Item/Take 数量与 Shepard layer 数不一致。")
    end

    for lane_index, item in ipairs(output.items) do
      local lane = plan.lanes[lane_index]
      local take = reaper.GetActiveTake(item)
      if not take or take ~= output.takes[lane_index] then
        fail("输出 " .. plan_index .. " layer " .. lane_index .. " 的活动 Take 不一致。")
      end
      local guid = item_guid(item)
      if output_guids[guid] then fail("Shepard 输出存在重复 GUID：" .. guid) end
      output_guids[guid] = true

      local expected_offset = plan.source_snapshot.start_offset
        + lane.source_offset * plan.source_snapshot.playrate
      local expected_volume = base_volumes[plan_index] * lane.volume
      local _, take_name = reaper.GetSetMediaItemTakeInfo_String(
        take, "P_NAME", "", false)
      if not close_enough(lane.position,
          reaper.GetMediaItemInfo_Value(item, "D_POSITION"))
          or not close_enough(lane.length,
            reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
          or not close_enough(0,
            reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC"))
          or not close_enough(-1,
            reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO"))
          or not close_enough(-1,
            reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO"))
          or not close_enough(expected_offset,
            reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"))
          or not close_enough(plan.source_snapshot.playrate,
            reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
          or not close_enough(expected_volume,
            reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")) then
        fail("输出 " .. plan_index .. " layer " .. lane_index
          .. " 的位置、长度、source offset、playrate 或音量不符合规划。")
      end
      if take_name ~= expected_name then fail("Shepard 输出名称不符合规划。") end
      if reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")
          ~= (TEST_COLOR | 0x1000000) then
        fail("Shepard 输出颜色不符合规划。")
      end
      if not reaper.IsMediaItemSelected(item) then
        fail("Shepard 输出未保持选中。")
      end

      local envelope = reaper.GetTakeEnvelopeByName(take, "Pitch")
      if not envelope then fail("Shepard layer 缺少 Take Pitch Envelope。") end
      local points = pitch_points_in_range(envelope, lane.length)
      if #points ~= #lane.pitch_points then
        fail("Shepard layer 的 Pitch Envelope 点数量不符合规划。")
      end
      for point_index, expected in ipairs(lane.pitch_points) do
        local actual = points[point_index]
        if not close_enough(expected.time, actual.time)
            or not close_enough(expected.value, actual.value)
            or actual.shape ~= expected.shape then
          fail("Shepard layer 的 Pitch Envelope 点不符合规划。")
        end
      end
    end
  end
  reaper.UpdateArrange()
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
  if not run_ok then messages[#messages + 1] = "自检失败：\n" .. tostring(run_error) end
  if transaction == nil then
    messages[#messages + 1] = "未能创建 state transaction；未修改项目。"
  elseif not restore_ok then
    messages[#messages + 1] = "state transaction restore 失败：\n"
      .. tostring(restore_detail)
  else
    messages[#messages + 1] = "state transaction 已恢复，未保留 Shepard 输出。"
  end
  reaper.ShowMessageBox(
    table.concat(messages, "\n\n"),
    "LoopMaker Shepard Tone 自检",
    0)
  return
end

reaper.ShowMessageBox(
  table.concat({
    "Shepard Tone 自检通过。",
    "已验证 2 ^ Loops 分层、输出周期、source offset、playrate、B_LOOPSRC 和音量归一化。",
    "已验证 Take Pitch Envelope 创建、两端点时间/音高、命名、颜色和输出选择。",
    "已核对原始 Item 数量、GUID、选择和 chunk，且 transaction restore 无警告。",
    "本自检不会执行 Glue，也不能替代正向/反向 Shepard 的人工试听与循环边界听感验收。",
    "state transaction 已恢复，未保留 Shepard 输出。",
  }, "\n"),
  "LoopMaker Shepard Tone 自检",
  0)
