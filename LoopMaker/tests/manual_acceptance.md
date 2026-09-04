# LoopMaker 手工验收清单

## 验收环境

- 日期：
- 操作系统：
- REAPER 版本：
- ReaImGui 版本：
- 工程采样率：
- 测试人：

请在专用测试工程中执行。开始前保存工程；涉及 Glue 的项目应确认媒体文件输出目录可写。

## 1. 安装与窗口

- [ ] 从 Action List 运行 `LoopMaker.lua`，窗口正常打开，无控制台报错。
- [ ] 缺少 ReaImGui 时出现明确提示，脚本不修改工程。
- [ ] 顶部 Glue、预设、Loops、Cancel / Preview / Apply 清晰可用；滚动下方参数区时主操作仍保留在顶部。
- [ ] Position、Crossfade 默认展开；Zero-Crossing、Name 可直接折叠；Shepard Tone 位于末尾且普通模式默认收起。
- [ ] 拉窄窗口到最小尺寸、展开预设 Manage 与警告，数值和按钮无重叠，参数可滚动访问；检查旧 ReaImGui 的只读降级。
- [ ] Loops 滑块可快速调整，右侧框可精确输入 1–1000；输入大数后拖动不会因范围每帧缩小而跳变。Shepard 上限仍为 6。
- [ ] Crossfade 25% 保存为 0.25；加载旧预设后比例、曲线 ID、Offset 秒数不变；Max=0 显示 No limit。
- [ ] Manage 默认隐藏编辑控件；展开后可保存、覆盖、删除用户预设，Default 不能删除；加载失败保留旧选项。
- [ ] 填充模式即使收起 Position，顶部仍显示 Filling time selection；展开后可以区分唯一变体数、排列段数、单段时长与总覆盖时长。
- [ ] Warnings 数量在顶部可见，展开后能读到详情；错误始终显示，播放中的停止提示不会被错误遮住。
- [ ] 收起所有高级面板不修改音频参数；启用 Shepard 必须单独勾选，不因展开面板而启用。
- [ ] 100%、125%、150%、200% DPI 下没有文字截断或控件重叠。
- [ ] 关闭窗口等同 Cancel，工程恢复到启动前状态。

记录：

## 1a. 本轮实机缺陷回归

- [ ] 使用一条已经 Glue 的 Item，清除时间选区后启动；Item 长度与 WAV 长度差不足一个源采样周期时仍能生成预览。
- [ ] Loops 在 1、5、2、10、1 间调整，不再弹出 0 或选区终点等纯数字错误；生成数量和参数一致。
- [ ] 有选区时改变 Loops，再清除选区改变 Loops，两种模式正确切换。
- [ ] Cancel 后原 Item 数量、长度、GUID、选区恢复；样本尾差对齐不永久改写输入素材。
- [ ] 真正超出源范围的 Item 仍受到保护，不能把大范围缺失伪装成采样舍入。

记录：原生脚本集成检查通过，鼠标拖动及本机听感由测试人补充。

## 2. 选择与基础预览

准备一个 Mono 48 kHz 音频 Item，再准备一个 MIDI Item。

- [ ] 只选 MIDI 或不选 Item 时，Apply 不可用。
- [ ] 选中音频 Item 后能生成预览，状态显示 `Preview ready`。
- [ ] 有时间选区时，时间选区作为输出覆盖范围，多个等长槽位无缝铺满选区；无时间选区且 `Loops = 1` 时使用 Item 可用长度，`Loops > 1` 时按 Loop 数量等分 Item 生成唯一变体。
- [ ] 点击 Preview 或按空格开始循环试听；结束试听必须使用 REAPER Stop，停止后预览范围、光标和 Repeat 状态恢复。
- [ ] 连续修改参数不会累积旧预览，工程中只保留当前结果。
- [ ] 快速连续拖动参数时，防抖生效，没有每次微小变化都重复重建。

记录：

## 3. 快捷键与焦点

- [ ] 窗口聚焦且无控件编辑、transport 已停止时，空格开始预览；播放中再次按空格不抢占 transport，使用 REAPER Stop 结束。
- [ ] Enter 与数字键盘 Enter 执行 Apply；点击参数子窗口后快捷键仍有效。
- [ ] Apply 按钮不可用时，Enter 也不会应用；预览重建中或播放中，按钮和快捷键均不能提交旧预览。
- [ ] Esc 执行 Cancel。
- [ ] 正在编辑名称或数值输入框时，空格、Enter、Esc 不误触播放、应用或取消整个工具。

记录：

## 4. 普通循环与零交叉

分别使用正弦、噪声、瞬态、立体声和多声道素材。

- [ ] Zero-Crossing 面板显示来源、变体编号和边界时间。
- [ ] Offset 改变后边界和预览随之更新。
- [ ] 找不到零交叉时显示 warning，并使用回退边界生成结果。
- [ ] 循环边界无明显 click/pop；记录不通过的素材和参数。
- [ ] 长时间循环多次后无可听或可测的长度漂移。
- [ ] Crossfade ratio、curve、max 的变化反映到 Item fade。

记录：

## 5. 多 Item 与多变体

- [ ] 多个选中音频 Item 都生成结果；同一时间槽位上的多个 source 使用相同变体序列。
- [ ] 无时间选区时，单个 Item 设置 `Loops = 5` 后生成 5 个独立、等长且内容不同的唯一变体；开启 Glue 并 Apply 后最终正好是 5 个 Item。
- [ ] 5 个唯一变体分别单独循环播放时首尾无爆音；任意顺序首尾相接时没有 click/pop。
- [ ] 每个输出的组件外边界保留 3 ms 安全 Fade；Glue 后用波形放大检查 Fade 已渲染进文件。
- [ ] Shuffle 打开后唯一变体顺序变化但不重复抽取；关闭后结果可重复。
- [ ] 无时间选区时 Position space 正确控制输出间距。
- [ ] Second snap 将合法源边界吸附到整数秒。
- [ ] 跨轨重叠 Item 开启 match overlap 后按连通组匹配长度；同轨 Item 不错误归组。

记录：

## 6. REAPER 时间选区铺满与 Wwise Sample Accurate

准备至少两个足够长的音频 Item，设置 `Loops = 5`、开启 Shuffle，并建立可容纳多于 5 个槽位的时间选区。记录当前项目是否启用采样率、音频设备 `SRATE` 和各 source rate；确认工具按“已启用项目采样率 → 设备 `SRATE` → 所有 source 一致采样率”的顺序选取活动采样率。

### REAPER 铺满与 Glue

- [ ] 时间选区被视为输出覆盖范围，而不是单个 Loop 长度；最终 Item 数可以多于 `Loops`。
- [ ] `Loops = 5` 表示先生成 5 个唯一变体；所有 `asset_variant_index` 完整覆盖 `0..4`。
- [ ] 时间选区内所有槽位连续、等长且无空隙；统一缩短后首槽起点样本等于选区起点，末槽结束样本等于选区终点。
- [ ] `slot_count × slot_samples = total_samples`，每个槽位及每个 source 层的样本数一致。
- [ ] 均衡随机后各变体出现次数最大差为 1；有多个变体可选时没有相邻重复；多个 source 共享同一序列。
- [ ] 铺满模式下 Position Space 控件禁用且实际间距强制为 0；退出铺满模式后原值仍保留并重新可编辑。
- [ ] 每个输出的组件外边界均为 3 ms Fade。
- [ ] 使用 REAPER Stop 结束 Preview；停止后再执行 Apply 或 Cancel，且原 transport/选区/光标状态正确恢复。
- [ ] 经明确确认后启用 Glue 并 Apply；每个 Glue WAV 的样本数与槽位样本数完全一致，所有 WAV 样本数彼此一致。
- [ ] Glue 失败时检查项目目录/媒体目录；如磁盘上遗留了失败过程产生的文件，记录并手动清理。

### Wwise 结构与实听

- [ ] 将 Glue 后的 WAV 导入 Wwise，并配置为 `Random Container → Continuous → Loop → Transition Type: Sample Accurate`。
- [ ] 核对 Random Container 中恰有 5 个唯一资产；不要把时间线上的重复槽位导入成额外唯一变体。
- [ ] 在 Sample Accurate 配置下执行至少 100 次随机切换并全程监听。
- [ ] 逐次记录 click/pop、边界能量下陷，以及任何失败的 `A → B` 变体组合；自动化结构检查不能替代此项实听。
- [ ] 若发现失败组合，在 REAPER 中单独首尾拼接对应 WAV，复查边界波形、3 ms Fade 和精确样本数。

记录：

```text
活动采样率来源（项目 / 设备 / source）：
活动采样率（Hz）：
时间选区 start/end sample：
slot_count × slot_samples = total_samples：
各 WAV 文件名与样本数：
100 次切换 click/pop 次数：
100 次切换能量下陷次数：
失败 A → B 组合：
Glue 遗留文件及清理结果：
```

## 7. Shepard Tone

使用持续音色素材分别测试：Pitch `12`、`-12`、`7`，Loops `1`、`3`、`6`。

- [ ] Shepard 模式与 Zero-Crossing 控制互斥。
- [ ] 层数为 `2 ^ Loops`，Loops 最大为 6。
- [ ] 正 Pitch 产生连续上行错觉，负 Pitch 产生连续下行错觉。
- [ ] `±12` 半音时循环边界没有明显音高跳变。
- [ ] 非整八度 Pitch 显示 warning，并记录实际听感。
- [ ] 每层音量归一化，没有因层数增加造成明显削波。

记录：

## 8. 命名、着色与预设

- [ ] Prefix、Suffix、Separator、编号起点和前导零组合正确。
- [ ] Remove extension 只移除最后一个扩展名。
- [ ] Color output Items 开关正确控制输出颜色。
- [ ] 新建、覆盖、加载和删除预设正常。
- [ ] 预设加载失败时，当前设置和 UI 选中名称不变。
- [ ] 删除当前预设后回到 Default。

记录：

## 9. Apply、Glue、Cancel 与 Undo

- [ ] 播放或录音中启动脚本会被拒绝且不修改工程；播放或录音中执行 Apply、Cancel 或重建也会要求先使用 REAPER Stop。
- [ ] Glue 关闭时，Apply 保留可编辑的拼接 Item。
- [ ] Glue 开启时，预览阶段不产生文件；Apply 后每个输出只剩一个新 Item。
- [ ] Glue 后原组件已移除，输出 Item、Take、名称、颜色和选择状态正确。
- [ ] Apply 在 Undo 历史中只形成一个可识别步骤。
- [ ] Cancel 完整恢复 Item、时间选区、光标、轨道选择、Item 选择和播放状态。
- [ ] 关闭窗口与异常退出不会遗留预览编辑。

记录：

## 10. 项目切换与异常恢复

- [ ] 预览存在时切换项目标签页，脚本停止继续调度。
- [ ] 原项目在后台恢复，当前项目不被写入或停止播放。
- [ ] 模拟第二帧异常后，错误信息可见，脚本不再继续 defer。
- [ ] 恢复失败时保留明确错误信息，`atexit` 仍可执行最后兜底。

记录：

## 11. REAPER 内自检

运行 `reaper_loop_selftest.lua` 前，至少选中 2 个包含活动音频 take 的 Item 并停止 transport。确认提示应明确说明：自检会在事务捕获后主动修改时间选区、循环点、Repeat、编辑光标和 Item，回读确认临时状态确实生效，最终再恢复到启动前基线；默认不执行 Glue。

依次从 Action List 运行：

- [ ] `reaper_audio_selftest.lua`
- [ ] `reaper_state_selftest.lua`
- [ ] `reaper_loop_selftest.lua`
- [ ] Loop 自检成功信息明确报告双 source 共享序列，并确认主动改动过的时间选区、循环点、Repeat、编辑光标及 Item 状态均恢复到事务基线。
- [ ] `reaper_shepard_selftest.lua`

每项记录实际输出：

```text
REAPER:
ReaImGui:
Platform:
Audio selftest:
State selftest:
Loop selftest:
Shepard selftest:
```

## 验收结论

- [ ] 通过
- [ ] 有条件通过
- [ ] 不通过

阻塞问题：

非阻塞问题：

复测结果：


## 2026-09-03 多 Loops Glue 修复的原生验证记录

- 环境：独立 REAPER 7.79/x64、空白专用工程、96 kHz 合成 WAV；Glue 使用该测试工程的 48 kHz 输出设置，媒体写入隔离目录。
- Loops=5、1、10 的 Apply 均成功；10 个循环包含从 1 调到 5，再调到 10 后立即 Apply 的重建路径。
- 每个结果仅一个 Item/Take，输出数量、名称、位置、长度、选择状态均核对通过。
- 16 个实际 WAV 文件头核对通过：5 个循环各 18796 样本；1 个循环 104086 样本；10 个循环各 8387 样本。每组内部长度一致，采样率均为 48000 Hz。
- 3 次 Glue 结果复用了原组件地址但 GUID 已更换，均正确提交。单次 Undo 恢复原 Item 的数量、GUID、小数长度与选择状态。
- 测试素材创建必须先结束自己的 undo block，再启动 LoopMaker，以形成独立的测试前基线。
- 以上是原生 API 自动化验证；物理鼠标点击、多 DPI、不同媒体格式与真实音频听感仍按上方清单验收。
