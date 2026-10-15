# Maa深度 —— 本目录索引（15 篇）

> 生成于 **2026-10-02** · 上级：[`../../00-文档总索引.md`](../../00-文档总索引.md)

## 性质

本目录是 **MaaNTE / MaaFramework 的深度解剖与移植评估**，供 AI 用作工具时参考。

> 铁律提醒（项目级）：**Maa 绝不允许整体接管项目**（红线），只能作为 AI 的工具。

## §1 深度解剖系列

| 文档 | 一句话 |
|---|---|
| [`MAA深度文档_完整版.md`](MAA深度文档_完整版.md) | 完整版（**本目录主文档，先看这篇**） |
| [`MAA深度文档_架构篇.md`](MAA深度文档_架构篇.md) | 架构 |
| [`MAA深度文档_功能篇.md`](MAA深度文档_功能篇.md) | 功能 |
| [`MAA深度文档_扩展篇.md`](MAA深度文档_扩展篇.md) | 扩展 |

## §2 源码逐模块（编号 `Maa-09`~`Maa-15`）

| 文档 | 对应模块 |
|---|---|
| [`Maa-09-main.py入口与MaaFramework核心流.md`](Maa-09-main.py入口与MaaFramework核心流.md) | 入口与核心流 |
| [`Maa-10-agent-utils基础设施六件套.md`](Maa-10-agent-utils基础设施六件套.md) | agent/utils 基础设施 |
| [`Maa-11-Navi导航系统全链.md`](Maa-11-Navi导航系统全链.md) | Navi 导航全链（**与本项目定位/导航最相关**） |
| [`Maa-12-MapTeleport地图传送系统.md`](Maa-12-MapTeleport地图传送系统.md) | 地图传送 |
| [`Maa-13-小游戏三件套Tetris-Rhythm-AutoPiano.md`](Maa-13-小游戏三件套Tetris-Rhythm-AutoPiano.md) | 小游戏三件套 |
| [`Maa-14-实时辅助SoundTrigger与排球.md`](Maa-14-实时辅助SoundTrigger与排球.md) | 实时辅助 |
| [`Maa-15-生活任务与长尾模块与任务JSON体系.md`](Maa-15-生活任务与长尾模块与任务JSON体系.md) | 生活任务与任务 JSON |

## §3 移植评估

| 文档 | 一句话 |
|---|---|
| [`MaaNTE移植对照表.md`](MaaNTE移植对照表.md) | 移植对照表 |
| [`MaaNTE-macOS适配验证.md`](MaaNTE-macOS适配验证.md) | macOS 适配验证 |
| [`Maa移植难度评估报告.md`](Maa移植难度评估报告.md) | 移植难度评估 |
| [`ROI反推规则.md`](ROI反推规则.md) | ROI 反推规则 |

## §4 与本项目的关系（已核实）

- MaaNTE 参考实现在仓库 `MaaNTE/`（1.4G）。
- 已核实的坐标系差异（**记录在案，勿再当成 bug**）：
  `MaaNTE/agent/custom/action/Navi/coordinate_position.py` 的 `apply()` 返回 `(a*x - b*y + tx, b*x + a*y + ty)`，
  `_CALIBRATION_TX = 6293.474380746091`、`_CALIBRATION_TY = 3472.664390686138`、`COORDINATE_MAP_SIZE = (11264, 11264)`；
  本项目 `Sources/AuroraDrive/Capture/CoordinateCapture.swift:1694–1698` 的 `worldToMapPixel` **两个 B 项符号都相反**。
  **但 `B/A = 3.47e-6`，绝对误差 ≤ 约 0.02 px ≈ 1.2 cm，数值上无害。**
