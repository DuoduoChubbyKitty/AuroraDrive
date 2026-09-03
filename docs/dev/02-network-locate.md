# 二、网络定位子系统

> 覆盖源码：`CoordinateCapture.swift`(576 主力) `NetworkHealer.swift`(377) `VisualLocator.swift`(491 休眠) `MinimapLocatorView.swift`(193) `MinimapTileCache.swift`(175) `NetworkLocator.swift`(626 死代码)
> 上级：[开发者文档](../DEVELOPER_GUIDE.md) ｜ English: [Network Localization](en/02-network-locate.en.md)
> 位级细节：[UE5 位流解析](../internals/ue5-bitstream.md) · [坐标标定](../internals/coordinate-calibration.md) · [BPF/LaunchDaemon](../internals/bpf-daemon.md)

## 2.1 模块全景（活/死判定，写文档前逐文件核实过）

| 文件 | 状态 | 说明 |
|---|---|---|
| `CoordinateCapture.swift` | **活**（主力） | libpcap 抓 tcp/30031 → UE5 位流解码 |
| `NetworkHealer.swift` | **活**（AuroraDriveApp:555 实例化，5s 定时器） | 诊断+修复仲裁 |
| `VisualLocator.swift` | 类活，**NCC 引擎休眠** | `locate(template:)` 全项目唯一调用点是自身自检；视觉态定位恒 nil |
| `MinimapLocatorView` / `MinimapTileCache` | **活**（两套互不引用的小地图） | 分别挂 AuroraDriveApp:2078 与 :1602 |
| `NetworkLocator.swift` | **死代码** | WebSocket 客户端（ws://127.0.0.1:9004），零实例化 |
| `NetworkPacketCapture.swift` | **死代码**（已移 `legacy/`，不编译） | 旧抓包实现 |

## 2.2 抓包（CoordinateCapture.start）

**网卡选择用 `pcap_findalldevs` 枚举**（不是 lookupdev——后者在 macOS 只返回默认路由网卡，游戏流量若走 en8 等非默认网卡会永远 0 包）：

```
pcap_findalldevs 枚举全部网卡
  → 跳过 lo0/pdp_ip/utun/awdl/xhc20 桥接等虚拟网卡
  → 逐个 pcap_open_live(65535, 非混杂, 20ms) + pcap_compile("tcp port 30031") + pcap_setfilter
  → 第一个全流程成功的即工作网卡
```

抓包循环（`captureLoop`）用 `pcap_next_ex` **阻塞拉取**而非 `pcap_loop` 回调——回调形式在 Apple Silicon 上因 PAC（指针认证）崩溃（见踩坑实录）。

## 2.3 包处理管线（processPacket）

```
以太网帧 → 剥 14 字节头
  → IPv4: version==4、IHL*4、protocol==6(TCP)、srcIP/dstIP
  → TCP: srcPort/dstPort、data_offset*4
  → payload → packetDirection: 只放行 c2s（本地→远端；RFC1918 私有地址判定）
  → payload.count ≥ 70（findCandidates 搜索窗需要）
  → UE5Decoder.decode(payload:timestamp:flow:) → Pose(x,y,z,pitch,heading)
  → 30Hz 节流写入 sample（interval = 1/30）
```

## 2.4 世界坐标 → 地图像素（worldToMapPixel）

```swift
mapX = kCalibA * wx + kCalibB * wy + kCalibTX
mapY = kCalibA * wy - kCalibB * wx + kCalibTY
```

常量（`:58-61`）：`kCalibA=0.016394586684750773`、`kCalibB=5.693519256055879e-08`、`kCalibTX=6293.474380746091`、`kCalibTY=3472.664390686138`。这是**线性仿射变换**（kCalibB 是交叉耦合项，含轻微旋转校正）。推导见四级文档。地图整图 11264×11264 定义在 MinimapLocatorView/MinimapTileCache。

## 2.5 自愈引擎（NetworkHealer）

- 实例化：`AuroraDriveApp:555`，`NetworkHealer(capture:mapPath:)`，5 秒定时诊断
- `LocatorMode`：`network="pcap"` / `visual="visual"` / `failed="failed"`
- `Diagnosis` 枚举 7 种，但 **`diagnose()` 实际只返回 5 种**：permissionLost / interfaceDown / bpfDeviceBusy / gameNotRunning / unknownButDead（portChanged 仅在 attemptRepair 处理，mapFileNotFound 来自视觉诊断）
- `currentLocation()`：网络态读 `capture.read(maxAge:1.0)` 转 worldToMapPixel；**视觉态恒 nil**（视觉定位需截图，由上层处理）
- 修复动作：BPF 权限丢失 → `restartCapture()`（**不弹窗**，权限由 BPFSetup/UI 管）；修复后有个 3 秒确认窗避免立即回切

## 2.6 视觉定位（VisualLocator）——休眠状态

NCC（归一化互相关）模板匹配 + 积分图加速 + 多尺度金字塔（2048/1536/1024 + 192 粗扫档，阈值 0.80，vDSP 加速）。**类是活的但引擎休眠**：`locate(template:)` 全项目唯一调用点是自身 `runSelfTest`；NetworkHealer 的视觉分支目前恒返回 nil。即：视觉顶班机制已实现未接线。

## 2.7 小地图渲染（两套并存，互不引用）

| 实现 | 常量 | 用途 |
|---|---|---|
| `MinimapTileCache` | mapPixelSize=11264 / tilesPerSide=8 / tilePixelSize=1408 / minimapPx=200 | 64 瓦片懒加载缓存，挂 FloatingMinimap（AuroraDriveApp:1602） |
| `MinimapLocatorView` | mapSide=11264 / blocksPerEdge=8 / blockSide=1408 / displayMapSide=2816 / viewSize=220 | 定位视图，挂 AuroraDriveApp:2078，内置私有 MinimapBlockCache |

地图源 `bigworldmapSecond.png`（MaaNTE 图源），标记数据 `FINAL_complete_map_database.json`（nteguide）。

## 2.8 死代码说明（NetworkLocator / NetworkPacketCapture）

- `NetworkLocator.swift`（626 行）：WebSocket 客户端连 `ws://127.0.0.1:9004`，纯 JSON 协议（version=1.3.0 / mode=coordinate / x/y/z/pitch/heading）。`DualModeLocator`/`MaaNTESocketClient`/`UE5PacketDecoder` 全部零外部调用。**编译但不跑**。
- `NetworkPacketCapture.swift`（1220 行）：旧抓包实现，不在 Package.swift sources，已移 `legacy/`。
- 保留原因：NetworkLocator 是「外接 MaaNTE 助手进程」的备用定位通道，未来可能启用；死代码保留在仓库供参考。
