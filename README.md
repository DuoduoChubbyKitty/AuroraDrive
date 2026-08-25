# AuroraDrive

macOS 第三方视角自动驾驶系统(NTE / 异环),捕获游戏画面 → CoreML 推理 → 注入按键,
并附带交互式收集地图与 MetalFX 显示增强。

> ⚠️ 本项目为研究与个人使用用途。使用本软件自动控制游戏可能违反游戏服务条款,
> 作者不对封号或其他后果负责。请自行评估风险。

## 功能

- 端到端驾驶(M9 模型)+ 规则兜底 + YOLO 接管 的多档降级架构
- 屏幕捕获(ScreenCaptureKit)+ CoreML 推理 + CGEvent 按键注入
- 交互式全收集地图(图层开关、传送点 / 材料 / 宝箱 / 谕石等)
- 显示路径 MetalFX 超分 + 插帧(MetalGoose 引擎,可选开启)

## 架构红线

插帧 / 超分**只能**作用于「给人看的显示叠加层」,**绝不**进入
「捕获 → 推理 → 按键注入」决策链路,以避免变相拉长控制延迟。

## 构建

```bash
cd AuroraDrive
swift build -c release
# 产物: .build/release/AuroraDrive
```

需要屏幕录制 + 辅助功能权限(系统设置 > 隐私与安全)。重签后需完全退出重启。

## 第三方组件与许可

本项目以 **GNU GPL v3.0** 完全开源。详见 `NOTICE`。

| 组件 | 用途 | 许可 |
|---|---|---|
| MetalGoose | 显示路径 MetalFX 超分 / 插帧 | GPL v3.0(原样 vendor 于 `Vendor/MetalGoose/`) |
| MaaNTE 资源 | 世界地图 / 朝向模型 | 第三方,本地自备,不随仓库分发 |
| nteguide 数据 | 地图标记 | 粉丝采集数据,运行时抓取,不随仓库分发 |

## License

AuroraDrive is free software, licensed under the **GNU General Public License
v3.0**. See `LICENSE` for the full text.

All original source files carry the SPDX headers:

    SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
    SPDX-License-Identifier: GPL-3.0-or-later

Derived from MetalGoose (GPL v3.0, © its authors) — vendored under
`Vendor/MetalGoose/` and used solely on the display path.
