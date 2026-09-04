# LoopMaker

LoopMaker 是一个面向 REAPER 7 的 Lua ReaScript，用来把选中的音频 Item 制作成可循环素材。它会在目标位置附近分析零交叉点，生成非破坏式 Item 拼接预览；确认后可保留拼接结构，也可调用 REAPER 原生 Glue 输出单个 Item。

## 运行要求

- REAPER 7，64 位
- ReaImGui
- Windows、macOS 或 Linux
- 输入必须是带活动 Take 的音频 Item，不支持 MIDI Item

## 安装

1. 在 REAPER 中打开 `Options > Show REAPER resource path in explorer/finder`。
2. 把整个 `LoopMaker` 文件夹复制到资源目录下的 `Scripts` 文件夹中。不要只复制入口脚本，`lib` 和 `ui` 目录也必须保留。
3. 如果尚未安装 ReaImGui：
   - 安装 ReaPack。
   - 打开 `Extensions > ReaPack > Browse packages`。
   - 搜索并安装 `ReaImGui: ReaScript binding for Dear ImGui`。
   - 重启 REAPER。
4. 打开 `Actions > Show action list`，选择 `New action > Load ReaScript`。
5. 载入 `LoopMaker/LoopMaker.lua`，之后可为它设置快捷键或工具栏按钮。

## 基本用法

1. 先停止 REAPER 播放或录音，再在同一个项目中选中一个或多个音频 Item。
2. 可选：建立时间选区。时间选区表示输出覆盖范围，LoopMaker 会用多个等长槽位连续铺满它；没有时间选区时才按普通多变体方式排列。
3. 运行 `LoopMaker.lua`。脚本会保存项目基线并立即生成预览。
4. 修改参数。影响结果的参数会在短暂防抖后重新构建预览；旧预览会先恢复，不会逐次累积。
5. 使用以下操作结束：
   - `Preview` 或空格：从预览范围起点开始循环播放。开始播放后请使用 REAPER Stop 结束试听；再次点击 Preview 不会接管或停止正在运行的 transport。
   - `Apply` 或 Enter：在 transport 已停止时保留结果；如果启用 Glue，此时才执行 Glue。
   - `Cancel`、Esc 或关闭窗口：在 transport 已停止时恢复脚本启动前的项目状态。

输入框或其他控件正在编辑时，空格、Enter 和 Esc 都不会触发全局快捷键；输入框内的 Esc 由 ReaImGui 处理为退出编辑。播放或录音中 Cancel 会要求先 Stop。

时间选区是唯一被视为"活输入"的项目状态：fill 始终使用当前时间选区，每次参数重建都会重新读取并写回；而循环点、编辑光标、Repeat 在重建时仍会回滚到启动捕获的基线。Cancel 恢复启动时的选区。

## 2026-09-03 实机问题修复

- 修复修改 Loops 后弹出纯数字并退出：写回时间选区时正确处理 REAPER 返回的起点和终点，不再把结束时间当成错误。
- 修复某些 Glue 后的 Item 在无选区启动时报告素材越界：Item 保留的小数长度可能比 WAV 实际终点多不到一个采样点。规划前仅对齐不超过一个源采样周期的尾差，不修改原 Item / chunk，也不放行真正越界的读取。
- 独立 REAPER 7.79 工程已完成 27 项原生检查：启动、Loops 1→5→2→10→1、活时间选区、清除选区、Cancel 恢复，以及原生 ReaImGui 绘制。参数通过原生脚本设置；物理鼠标拖动、多 DPI 和听感仍需手工验收。
- 修复多 Loops 在 Apply 时误报 `Glue must create and select a new item`：REAPER 可能给 Glue 结果复用已删除组件的内存地址，现在结合 Item GUID 验证身份。Glue 未执行和旧组件残留仍会报错；所有输入组件的 GUID 在渲染前完成读取检查。
- 独立 REAPER 7.79 已验证 Loops 1、5、10 的原生 Glue/Apply，包含修改 Loops 后立即 Apply、输出数量/名称/位置、一次 Undo 恢复。16 个实际 WAV 已核对文件头，每组样本数一致；该测试使用合成音频与隔离项目，不能代替用户素材实听。
- 更新文件后关闭旧 LoopMaker 窗口再运行；已经运行的脚本不会自动重载修改后的模块。

## 界面布局

- 顶部固定显示 Glue、预设、Loops、Cancel / Preview / Apply；展开或滚动参数时，主操作仍在顶部。
- Loops 滑块用于快速调整，右侧数值框可精确输入普通模式的 1–1000；滑块初始范围为 1–32，输入更大数值后扩展，拖动过程中范围保持稳定。
- Position 和 Crossfade 默认展开；Zero-Crossing、Name 可按需折叠。Shepard Tone 放在最下方，普通模式默认收起。
- 参数区单独滚动，窗口可调整大小；控件宽度随窗口和当前字体尺寸变化。
- Preview 重建中、播放中或不可用时，按钮与快捷键都不会提交旧结果；播放中显示在 REAPER 停止的提示。
- 错误直接显示在顶部；警告显示数量，在参数区展开 Warnings 查看详情。
- 填充模式顶部显示 `Filling time selection` 和排列段数；Position 中进一步显示唯一变体数、每段时长和总覆盖时长。

### 时间选区与参考工具说明的区别

本项目的时间选区表示**整段输出的覆盖范围**，不是每个循环的长度。例如 60 秒选区由多个等长循环段共同铺满，变体不足时重复排列。没有时间选区时，Loops = 1 使用整个 Item 的可用范围，Loops > 1 则等分 Item 生成不同内容的变体。不需要铺满选区时，请在运行前清除时间选区。

## 参数

### 常用操作与 Position

| 参数 | 作用 |
|---|---|
| Glue on Apply | 仅在 Apply 时调用 REAPER 原生 Glue。关闭时保留可编辑的拼接 Item。 |
| Loops | 普通模式下表示每个 source 先生成的唯一变体数，不保证等于最终 Item 数：有时间选区时，唯一变体会按槽位重复使用并铺满选区；无时间选区且 `Loops > 1` 时，Item 会被等分为对应数量的不同取料区间。Shepard 模式下决定层数，层数为 `2 ^ Loops`。 |
| Position space | 无时间选区时控制多个输出之间的间隔，单位为秒。有时间选区时控件禁用、实际间距强制为 0，但设置值会保留，退出铺满模式后恢复使用。 |
| Shuffle variation positions | 随机重排唯一变体；时间选区铺满时采用均衡随机，各变体出现次数最多相差 1，并在可避免时不产生相邻重复。 |
| Snap boundaries to seconds | 将源区间边界吸附到整数秒。若无时间选区的等分边界无法同时保持整数秒、等长和唯一，工具会拒绝生成并提示关闭此选项。 |
| Match overlapping item lengths | 对跨轨重叠 Item 按组匹配可用循环长度。 |

### 时间选区铺满与活动采样率

时间选区只定义输出覆盖范围，不再直接定义单个 Loop 的长度。LoopMaker 先按 `Loops` 生成完整的唯一变体集，再根据选区总样本数统一缩短所有变体到同一槽长，并以整数样本边界连续排列；`slot_count × slot_samples = total_samples`，最后一个槽位精确结束在量化后的选区终点。多个 source 会共用同一变体序列和槽位位置。

样本计算使用以下活动采样率优先级：

1. 项目已启用的 `PROJECT_SRATE`；
2. 当前音频设备报告的 `SRATE`；
3. 所有选中 source 都存在且完全一致的 source rate。

三种来源都不可用，或回退时 source rate 不一致，铺满会在修改 Item 前停止并报告错误。

使用铺满时请注意：

- 铺满输出会覆盖时间选区所在轨的现有内容（可通过 REAPER Undo 撤销）。建议在空轨上使用，或先确认时间选区所在轨没有需要保留的 Item。
- `Snap boundaries to seconds` 与铺满同时开启时，整秒吸附不保证成立：fill 会按样本栅格与零交叉重新排列边界。
- 每次参数重建都会重新读取当前时间选区；Cancel 恢复脚本启动时的选区。

### Wwise Sample Accurate 使用边界

面向 Wwise 时，建议先 Glue 为每槽样本数完全一致的 WAV，再配置为 `Random Container → Continuous → Loop → Transition Type: Sample Accurate`。Random Container 中应放入 `Loops` 指定数量的唯一资产，而不是把时间线上的重复槽位都当作新变体。

自动化可证明变体索引完整、槽位样本数一致、选区起止样本精确、均衡分布及不存在可避免的相邻重复，但不能证明真实音频切换无感。发布前必须按 `tests/manual_acceptance.md` 至少执行 100 次随机切换实听，记录 click/pop、能量下陷和失败的 `A → B` 组合；这不是已完成真实 Wwise 验证的声明。

### Crossfade

| 参数 | 作用 |
|---|---|
| Length (%) | Crossfade 长度占循环长度的百分比，范围 0–50%。例如 25% 对应原预设比例 0.25；旧预设无需转换。 |
| Curve | 下拉选择 REAPER Item Fade 曲线，Linear (0) 或 REAPER curve 1–4，保留原有编号。 |
| Max length (s) | Crossfade 时长上限。设为 0 表示不额外限制。 |

Crossfade 只用于普通零交叉循环。素材太短时会自动缩短到合法范围。生成多个 Loop 时，每个输出的组件外边界保留 3 ms 安全 Fade，降低不同变体直接首尾连接时的爆点风险；Glue 会把这些 Fade 渲染进最终文件。安全 Fade 不能替代 Wwise Sample Accurate 配置、逐样本长度核对和真实随机切换实听。

### Shepard Tone（低优先级实验功能）

在最下方展开 `Shepard Tone (experimental)`，再勾选 `Enable Shepard Tone` 才会切换模式；单纯展开面板不会改变音频。

| 参数 | 作用 |
|---|---|
| Pitch per cycle | 每个周期的音高变化，单位为半音；正值上行，负值下行。 |

Shepard 模式最多使用 6 个 Loops，也就是 64 层。`±12` 半音等整八度变化通常更容易形成连续边界；非整八度设置会显示听感风险提示。

### Zero-Crossing

| 参数 | 作用 |
|---|---|
| Search offset | 调整零交叉搜索中心，单位为秒。 |
| Boundary list | 显示每个来源和变体分析到的起止边界，先显示 20 条，可点击 Show more boundaries 逐步展开。 |

找不到合适零交叉时，工具会回退到安全目标点并显示警告，不会直接中止整批处理。

### Name

| 参数 | 作用 |
|---|---|
| Color items | 为输出 Item 应用脚本颜色。 |
| Remove extensions | 命名前移除源名称最后一个扩展名。 |
| Prefix / Suffix | 添加前缀或后缀。 |
| Separator | 名称各部分之间的分隔符。 |
| Add number | 为输出追加编号。 |
| Starting number | 起始编号；关闭 Add number 后隐藏，原值仍保留。 |
| Leading zeros | 编号最小位数。 |

## 预设

- 点击顶部 `Manage` 展开管理控件，在 `Preset name` 中输入名称，然后点击 `Save / overwrite`；再次点击 Manage 收起。
- 从下拉框选择已有预设即可加载。
- `Default` 是内置默认设置，不能删除。
- 删除用户预设后会回到 `Default`。
- 预设保存在 REAPER ExtState 中，不会写入工程文件。

## Undo 与项目安全

- 播放或录音中不能启动 LoopMaker；预览播放、用户播放或录音尚未停止时，Apply、Cancel 和预览重建也会被拒绝。先使用 REAPER Stop，再继续操作。
- 从启动、预览重建到 Apply/Cancel 使用一个事务生命周期；时间选区、循环点、Repeat、编辑光标、Item 内容与选择都纳入恢复。
- 每次预览重建前都会恢复基线，再按新参数生成；唯一例外是时间选区作为活输入被重新读取并写回（见上）。新建 Item 通过 mutation tracking 跟踪，避免误删脚本运行期间出现的非预览 Item。
- Preview 会临时设置循环范围并启动播放，但不会停止任何活动 transport。使用 REAPER Stop 结束试听后，脚本才释放并恢复临时试听状态。
- 切换项目标签页会停止脚本并尝试在原项目后台恢复。
- 异常退出时会通过 `reaper.atexit` 再做一次恢复兜底。
- Glue 只在 Apply 阶段执行，预览不会生成 Glue 文件；项目事务能恢复 Item，但无法保证删除 Glue 已写入磁盘的媒体文件。

## 已知限制

- 多声道或相位关系复杂的素材可能找不到理想零交叉，届时会使用回退边界。
- 多 Loop 模式要求每个取料区间至少 24 ms，以便为两端保留完整的 3 ms 防爆点安全 Fade。
- Shepard Tone 对素材内容、Pitch 和层数较敏感，需要试听判断。
- 原生 Glue 的文件位置、格式和命名受当前 REAPER 项目设置影响；若 Glue 已写入文件后又失败，项目可恢复，但磁盘文件可能仍需手动清理。
- 当前自动化测试只能证明 Lua 逻辑和 REAPER 对象结构，不能替代真实 REAPER 中的听感、窗口焦点、DPI 和平台验证，也不代表已经完成真实 Wwise 验证。
- Sample Accurate、等样本数和安全 Fade 仍不能保证任意素材组合都没有 click/pop 或能量下陷，必须进行真实 Wwise 随机切换实听。
- 如果脚本报告项目已切换，请回到原项目检查恢复结果，再重新运行。

## 开发期快速回归

使用 Lua 5.4，或已安装 Lupa 的 Python 环境。默认仅输出失败详情与汇总；不逐条输出通过记录。

```text
python LoopMaker/tests/run.py --ui
python LoopMaker/tests/run.py --modules main_window,ui_model
python LoopMaker/tests/run.py --full --syntax
```

- `--ui` 只加载界面模型、窗口、预设操作三个模块，用于 UI 修改期间的快速反馈。
- `--modules` 指定受影响模块；未知名称或空列表会报错，不会以“零用例通过”结束。
- 交付前使用一次 `--full --syntax` 检查全部回归和 Lua 语法；只有排查个别通过记录时才加 `--verbose`。
- 原生 Lua 入口同样支持 `lua LoopMaker/tests/run.lua --ui`、`--modules=main_window,ui_model` 和 `--verbose`。
- 界面改动不能替代 REAPER 主机内的窗口、DPI 和焦点验收。测试耗时指测试执行时间，不包含工具启动或人工操作。

## 自检

`tests` 目录包含四个 REAPER 内自检脚本：

- `reaper_audio_selftest.lua`
- `reaper_state_selftest.lua`
- `reaper_loop_selftest.lua`
- `reaper_shepard_selftest.lua`

这些脚本应在空白或专用测试工程中运行。执行前先保存工程、停止播放/录音，并按脚本提示确认。循环自检要求至少选中 2 个包含活动音频 take 的 Item，以真实验证多个 source 共用同一变体序列。状态、循环和 Shepard 自检会在事务中临时修改工程；循环自检捕获基线后会主动把时间选区、循环点、Repeat 和编辑光标改为与基线不同的合法值并回读确认，再以稳定 RNG 验证 5 个唯一变体铺满多于 5 个槽位、精确样本边界、均衡分布、3 ms Fade 和 mutation tracking，最后逐项确认项目状态恢复到事务基线。循环自检默认不调用 Glue，避免遗留磁盘文件。

当前开发环境中的纯 Lua 回归结果为 `431 passed, 0 failed`。全部 38 个 Lua 文件已通过 `loadfile` 语法检查；本轮最终回归含语法检查执行约 0.061 秒。纯 Lua 自动化验证逻辑与结构；本轮另完成隔离 REAPER 的原生 Glue/Apply 与 WAV 样本数检查。不同媒体/项目设置、物理 UI 操作及 Wwise 至少 100 次随机切换实听仍需按 `tests/manual_acceptance.md` 验收。

## 故障排查

- 提示缺少 ReaImGui：通过 ReaPack 安装 ReaImGui，重启 REAPER。
- Apply / Preview 灰色：等待参数重建完成、停止 REAPER 播放，确认已生成有效预览并检查顶部错误信息。
- 预览没有变化：确认修改的是结果参数；Glue、面板开关和预设名称不会触发重建。
- Glue 失败：确认输出仍在原项目中、REAPER 的 Glue 动作可用，并检查窗口错误信息；再检查项目/媒体目录，手动清理由失败过程遗留的 Glue 文件。
- 脚本异常后项目未恢复：先不要继续编辑，使用 REAPER Undo，并保留控制台错误信息用于排查。
