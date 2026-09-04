local source = debug.getinfo(1, "S").source
local script_path = source:sub(1, 1) == "@" and source:sub(2) or source
local root = script_path:gsub("\\", "/"):match("^(.*)/tests/[^/]+$")
if not root then
  reaper.ShowMessageBox("无法确定 LoopMaker 项目目录。", "LoopMaker 状态事务自测", 0)
  return
end
package.path = table.concat({ root .. "/?.lua", root .. "/?/init.lua", package.path }, package.config:sub(3, 3))

local state = require("lib.state")

local function with_ui_refresh(callback)
  local entered, enter_error = pcall(reaper.PreventUIRefresh, 1)
  if not entered then error("PreventUIRefresh(1) 失败：" .. tostring(enter_error), 0) end
  local ok, err = pcall(callback)
  local exited, exit_error = pcall(reaper.PreventUIRefresh, -1)
  if not ok then
    if not exited then err = tostring(err) .. "; PreventUIRefresh(-1) 失败：" .. tostring(exit_error) end
    error(err, 0)
  end
  if not exited then error("PreventUIRefresh(-1) 失败：" .. tostring(exit_error), 0) end
end

local function setter(name, callback)
  local ok, result = pcall(callback)
  if not ok then error(name .. " 抛错：" .. tostring(result), 0) end
  if result == false then error(name .. " 返回 false", 0) end
end

local function guid(item)
  local ok, value = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if not ok or type(value) ~= "string" or value == "" then error("无法读取非空媒体项 GUID", 0) end
  return value
end

local function chunk(item)
  local ok, value = reaper.GetItemStateChunk(item, "", false)
  if not ok or type(value) ~= "string" then error("无法读取媒体项 chunk", 0) end
  return value
end

local function snapshot(project)
  local result = { all = {}, all_set = {}, selected = {}, chunks = {} }
  result.count = reaper.CountMediaItems(project)
  for index = 0, result.count - 1 do
    local value = guid(reaper.GetMediaItem(project, index))
    result.all[#result.all + 1] = value
    result.all_set[value] = true
  end
  for index = 0, reaper.CountSelectedMediaItems(project) - 1 do
    local item = reaper.GetSelectedMediaItem(project, index)
    local value = guid(item)
    result.selected[#result.selected + 1] = value
    result.chunks[value] = chunk(item)
  end
  result.time_start, result.time_end = reaper.GetSet_LoopTimeRange2(project, false, false, 0, 0, false)
  result.cursor = reaper.GetCursorPositionEx(project)
  return result
end

local function compare(expected, actual, phase)
  if actual.count ~= expected.count then error(phase .. "：媒体项数量未恢复", 0) end
  for _, value in ipairs(expected.all) do
    if not actual.all_set[value] then error(phase .. "：缺少原始媒体项 " .. value, 0) end
  end
  for _, value in ipairs(actual.all) do
    if not expected.all_set[value] then error(phase .. "：遗留额外媒体项 " .. value, 0) end
  end
  if #actual.selected ~= #expected.selected then error(phase .. "：选择数量未恢复", 0) end
  for index, value in ipairs(expected.selected) do
    if actual.selected[index] ~= value then error(phase .. "：选择 GUID 顺序未恢复", 0) end
    if actual.chunks[value] ~= expected.chunks[value] then error(phase .. "：chunk 未恢复 " .. value, 0) end
  end
  if actual.time_start ~= expected.time_start or actual.time_end ~= expected.time_end then
    error(phase .. "：时间选择未恢复", 0)
  end
  if actual.cursor ~= expected.cursor then error(phase .. "：编辑光标未恢复", 0) end
end

local function same_sequence(left, right)
  if #left ~= #right then return false end
  for index, value in ipairs(left) do
    if right[index] ~= value then return false end
  end
  return true
end

local project = reaper.EnumProjects(-1)
if reaper.CountSelectedMediaItems(project) == 0 then
  reaper.ShowMessageBox("请先选中至少一个媒体项。\n项目未被修改。", "LoopMaker 状态事务自测", 0)
  return
end

local baseline_ok, baseline = pcall(snapshot, project)
if not baseline_ok then
  reaper.ShowMessageBox("建立基线失败，项目未被修改：\n" .. tostring(baseline), "LoopMaker 状态事务自测", 0)
  return
end

local first_selected = reaper.GetSelectedMediaItem(project, 0)
local first_guid = guid(first_selected)
local track = reaper.GetMediaItemTrack(first_selected)
local baseline_volume = reaper.GetMediaItemInfo_Value(first_selected, "D_VOL")
local changed_volume = baseline_volume == 1 and 0.5 or 1
if changed_volume <= 0 or changed_volume == baseline_volume then changed_volume = 0.75 end

local transaction, capture_reason = state.Transaction.capture(reaper, project)
if not transaction then
  reaper.ShowMessageBox("状态捕获失败：\n" .. tostring(capture_reason), "LoopMaker 状态事务自测", 0)
  return
end

local temporary_items = {}
local function corrupt_project(temp_count)
  with_ui_refresh(function()
    for _ = 1, temp_count do
      local item = reaper.AddMediaItemToTrack(track)
      if not item then error("AddMediaItemToTrack 失败", 0) end
      temporary_items[#temporary_items + 1] = item
    end
    for index = 0, reaper.CountMediaItems(project) - 1 do
      local item = reaper.GetMediaItem(project, index)
      setter("SetMediaItemSelected", function()
        return reaper.SetMediaItemSelected(item, not reaper.IsMediaItemSelected(item))
      end)
    end
    setter("GetSet_LoopTimeRange2(set)", function()
      return reaper.GetSet_LoopTimeRange2(project, true, false,
        baseline.time_start + 1.25, baseline.time_end + 2.5, false)
    end)
    setter("SetEditCurPos2", function()
      return reaper.SetEditCurPos2(project, baseline.cursor + 3.75, false, false)
    end)
    setter("SetMediaItemInfo_Value(D_VOL)", function()
      return reaper.SetMediaItemInfo_Value(first_selected, "D_VOL", changed_volume)
    end)
    reaper.UpdateArrange()
  end)

  local damaged = snapshot(project)
  if damaged.count ~= baseline.count + temp_count then error("破坏验证：媒体项数量未改变", 0) end
  local extra_guid_found = false
  for _, value in ipairs(damaged.all) do
    if not baseline.all_set[value] then extra_guid_found = true break end
  end
  if not extra_guid_found then error("破坏验证：GUID 集合未改变", 0) end
  if same_sequence(damaged.selected, baseline.selected) then error("破坏验证：选择未改变", 0) end
  if damaged.time_start == baseline.time_start and damaged.time_end == baseline.time_end then
    error("破坏验证：时间选择未改变", 0)
  end
  if damaged.cursor == baseline.cursor then error("破坏验证：编辑光标未改变", 0) end
  if chunk(first_selected) == baseline.chunks[first_guid] then
    error("破坏验证：首个选中项 chunk 未改变", 0)
  end
end

local operation_ok, operation_error = pcall(function()
  corrupt_project(3)
  local rebuilt, warnings = transaction:restore_for_rebuild()
  if not rebuilt then error("restore_for_rebuild 失败：" .. tostring(warnings), 0) end
  if type(warnings) ~= "table" or #warnings ~= 0 then error("restore_for_rebuild 返回 warning", 0) end
  for _, item in ipairs(temporary_items) do
    if reaper.ValidatePtr2(project, item, "MediaItem*") then error("rebuild 遗留临时媒体项", 0) end
  end
  temporary_items = {}
  compare(baseline, snapshot(project), "rebuild 后")
  corrupt_project(1)
end)

local restored, final_warnings = transaction:restore()
if restored and (type(final_warnings) ~= "table" or #final_warnings ~= 0) then
  restored = nil
  final_warnings = "最终 restore 返回 warning"
end

local final_ok, final_error = pcall(function()
  compare(baseline, snapshot(project), "最终 restore 后")
end)
local live_temporary_item = false
for _, item in ipairs(temporary_items) do
  if reaper.ValidatePtr2(project, item, "MediaItem*") then live_temporary_item = true break end
end

local cleanup_errors = {}
local needs_cleanup = not operation_ok or not restored or live_temporary_item or not final_ok
if needs_cleanup then
  local cleanup_ok, cleanup_error = pcall(function()
    with_ui_refresh(function()
      for index = #temporary_items, 1, -1 do
        local item = temporary_items[index]
        if reaper.ValidatePtr2(project, item, "MediaItem*") then
          local item_track = reaper.GetMediaItemTrack(item)
          local deleted = item_track and reaper.DeleteTrackMediaItem(item_track, item)
          if deleted ~= true then
            cleanup_errors[#cleanup_errors + 1] = "临时项删除未返回 true"
          elseif reaper.ValidatePtr2(project, item, "MediaItem*") then
            cleanup_errors[#cleanup_errors + 1] = "临时项删除后仍有效"
          end
        end
      end
      setter("兜底 SetMediaItemInfo_Value(D_VOL)", function()
        return reaper.SetMediaItemInfo_Value(first_selected, "D_VOL", baseline_volume)
      end)
      local count = reaper.CountMediaItems(project)
      for index = 0, count - 1 do
        local item = reaper.GetMediaItem(project, index)
        setter("兜底 SetMediaItemSelected(false)", function()
          return reaper.SetMediaItemSelected(item, false)
        end)
      end
      for _, expected_guid in ipairs(baseline.selected) do
        for index = 0, count - 1 do
          local item = reaper.GetMediaItem(project, index)
          if guid(item) == expected_guid then
            setter("兜底 SetMediaItemSelected(true)", function()
              return reaper.SetMediaItemSelected(item, true)
            end)
            break
          end
        end
      end
      setter("兜底 GetSet_LoopTimeRange2(set)", function()
        return reaper.GetSet_LoopTimeRange2(
          project, true, false, baseline.time_start, baseline.time_end, false)
      end)
      setter("兜底 SetEditCurPos2", function()
        return reaper.SetEditCurPos2(project, baseline.cursor, false, false)
      end)
      reaper.UpdateArrange()
    end)
  end)
  if not cleanup_ok then cleanup_errors[#cleanup_errors + 1] = tostring(cleanup_error) end
end

if not operation_ok or not restored or #cleanup_errors > 0 or not final_ok then
  local messages = { "状态事务自测失败。" }
  if not operation_ok then messages[#messages + 1] = tostring(operation_error) end
  if not restored then messages[#messages + 1] = "最终 restore 失败：" .. tostring(final_warnings) end
  for _, message in ipairs(cleanup_errors) do messages[#messages + 1] = "兜底清理：" .. message end
  if not final_ok then messages[#messages + 1] = tostring(final_error) end
  reaper.ShowMessageBox(table.concat(messages, "\n"), "LoopMaker 状态事务自测", 0)
  return
end

reaper.ShowMessageBox(table.concat({
  "状态事务自测通过。",
  "已实际验证连续临时项、选择、时间选择、编辑光标及首个选中项音量/chunk 的破坏与恢复。",
  "rebuild 与最终 restore 均完成完整比对且无 warning。",
  "正常成功路径在事务关闭后未执行任何兜底 setter/delete。",
  "未验证：项目 dirty 状态、Undo 历史内容、播放状态、内部 UI refresh 深度。",
}, "\n"), "LoopMaker 状态事务自测", 0)
