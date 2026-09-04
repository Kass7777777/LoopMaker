# LoopMaker

Create seamless audio loops in REAPER 7 with a Lua ReaScript and ReaImGui interface.

LoopMaker 可将选中的音频 Item 制作为循环变体，支持时间选区铺满、交叉淡化、过零点分析、命名与颜色，以及预览、Apply、Cancel 和原生 Glue。

## 安装与使用

1. 安装 REAPER 7（64 位）和 ReaImGui。
2. 下载本仓库，将完整的 `LoopMaker` 文件夹复制到 REAPER 资源目录的 `Scripts` 文件夹中。
3. 在 REAPER 的 Actions 列表中载入 `LoopMaker/LoopMaker.lua`。
4. 停止播放，选择音频 Item 后运行脚本；调整参数并预览，使用 Apply 保留结果或 Cancel 恢复。

详细参数、时间选区行为及限制见 [使用说明](LoopMaker/README.md)。实机验收见 [验收清单](LoopMaker/tests/manual_acceptance.md)。

## 开发与验证

使用 Lua 5.4，或安装了 Lupa 的 Python 环境：

```sh
python -m pip install lupa
python LoopMaker/tests/run.py --ui
python LoopMaker/tests/run.py --modules loop_builder,app,state
python LoopMaker/tests/run.py --full --syntax
```

当前版本包含 UI 易用性改进，以及 Loops 时间选区返回值、源音频采样尾差和 Glue Item 身份误判修复。431 项回归测试与 38 个 Lua 文件语法检查通过；独立 REAPER 7.79 工程验证了 1、5、10 个 Loops 的 Glue/Apply、导出文件和撤销。自动化验证不替代实际素材听感验收。

Shepard Tone 属于实验性功能，优先级很低。

## License

[MIT](LICENSE)
