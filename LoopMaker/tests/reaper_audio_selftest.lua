local source = debug.getinfo(1, "S").source
local script_path = source:sub(1, 1) == "@" and source:sub(2) or source
local normalized_path = script_path:gsub("\\", "/")
local root = normalized_path:match("^(.*)/tests/[^/]+$")

if not root then
  reaper.ShowMessageBox("无法确定 LoopMaker 项目目录。", "LoopMaker 音频自测", 0)
  return
end

package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, package.config:sub(3, 3))

local audio = require("lib.audio")

local array = reaper.new_array(3)
array[1] = 0.5
array[2] = -0.25
array[3] = 0.125
local copied, copy_reason = audio.copy_samples(array, 3)
if not copied
    or array.get_alloc() < 3
    or copied[1] ~= 0.5
    or copied[2] ~= -0.25
    or copied[3] ~= 0.125 then
  reaper.ShowMessageBox(
    "reaper.array get_alloc/table 兼容测试失败：" .. tostring(copy_reason),
    "LoopMaker 音频自测",
    0)
  return
end

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  reaper.ShowMessageBox(
    "reaper.array 兼容测试通过。\n请选中一个包含音频 take 的媒体项后再次运行，以测试 audio accessor。",
    "LoopMaker 音频自测",
    0)
  return
end

local take = reaper.GetActiveTake(item)
if not take or reaper.TakeIsMIDI(take) then
  reaper.ShowMessageBox(
    "所选媒体项没有可用的音频 take。请选择音频 take 后再次运行。",
    "LoopMaker 音频自测",
    0)
  return
end

local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
if type(item_position) ~= "number"
    or type(item_length) ~= "number"
    or item_position ~= item_position
    or item_length ~= item_length
    or item_length <= 0 then
  reaper.ShowMessageBox(
    "无法读取所选媒体项的有效位置或长度。",
    "LoopMaker 音频自测",
    0)
  return
end

local maximum_window = 0.05
local midpoint = item_position + item_length / 2
local window_seconds
local target_time
if item_length <= maximum_window * 2 then
  window_seconds = item_length / 4
  target_time = midpoint
else
  window_seconds = maximum_window
  local minimum_target = item_position + window_seconds
  local maximum_target = item_position + item_length - window_seconds
  target_time = math.max(minimum_target, math.min(maximum_target, midpoint))
end

local result, reason = audio.find_zero_crossing(
  reaper,
  take,
  target_time,
  window_seconds,
  { chunk_frames = 32768 })

if not result then
  reaper.ShowMessageBox(
    "目标已自动置于所选 Item 内。\nreaper.array 兼容测试通过，但 audio accessor 自测失败：\n" .. tostring(reason),
    "LoopMaker 音频自测",
    0)
  return
end

local status = result.fallback and "未找到零交叉，已使用目标帧 fallback" or "已找到零交叉"
reaper.ShowMessageBox(
  table.concat({
    "reaper.array 兼容测试通过。",
    "audio accessor 自测通过。",
    "目标已自动置于所选 Item 内，未修改项目或编辑光标。",
    status,
    string.format("项目时间：%.9f", result.project_time),
    string.format("源时间：%.9f", result.source_time),
  }, "\n"),
  "LoopMaker 音频自测",
  0)
