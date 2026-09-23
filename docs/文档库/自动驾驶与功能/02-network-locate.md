# 二、网络定位子系统

> 覆盖源码：`CoordinateCapture.swift`(635 主力) `VisualLocator.swift`(491 休眠) `MinimapLocatorView.swift`(196) `MinimapTileCache.swift`(179) `NetworkLocator.swift`(626 死代码)
> 上级：[开发者文档](DEVELOPER_GUIDE.md) ｜ English: [Network Localization](../英文版/02-network-locate.en.md)
> 位级细节：[UE5 位流解析](ue5-bitstream.md) · [坐标标定](coordinate-calibration.md) · [BPF/LaunchDaemon](bpf-daemon.md)

> **档案标注（2026-09-19 核对更新，基线 7b7d2db）**：`NetworkHealer.swift`(377) 已在 76e9027 删除（自愈引擎退役，定位改为 `CoordinateCapture` 懒初始化）；抓包过滤器改为 `tcp port 30031 or udp`（对齐 MaaNTE，UDP 也放行）；payload 最小长度由 70 放宽到 32 字节；底图 2026-09-13 升级为 13056×13056（map-2026-08 扩图版），kCalibTX/TY 随之重标定。

## 2.1 模块全景（活/死判定，写文档前逐文件核实过）

| 文件 | 状态 | 说明 |
|---|---|---|
| `CoordinateCapture.swift` | **活**（主力） | libpcap 抓 `tcp port 30031 or udp` → UE5 位流解码 |
| ~~`NetworkHealer.swift`~~ | **已删除**（76e9027） | 原诊断+修复仲裁；现由 `runNetworkLocateStep()` 直接懒初始化 `CoordinateCapture`（`healerInitLock` 为遗留命名） |
| `VisualLocator.swift` | 类活，**NCC 引擎休眠** | `locate(template:tw:th:scoreThreshold:)` 全项目唯一调用点是自身自检；无视觉顶班分支 |
| `MinimapLocatorView` / `MinimapTileCache` | **活**（两套互不引用的小地图） | MinimapTileCache 挂 FloatingMinimap（AuroraDriveApp:2353），MinimapLocatorView 挂 :2988 |
| `NetworkLocator.swift` | **死代码** | WebSocket 客户端（ws://127.0.0.1:9004），零实例化 |
| `NetworkPacketCapture.swift` | **死代码**（已移 `legacy/`，不编译） | 旧抓包实现 |

## 2.2 抓包（CoordinateCapture.start）

**网卡选择用 `pcap_findalldevs` 枚举**（不是 lookupdev——后者在 macOS 只返回默认路由网卡，游戏流量若走 en8 等非默认网卡会永远 0 包）：

```
pcap_findalldevs 枚举全部网卡
  → 跳过 lo/pdp/utun/awdl/bridge/xhc 前缀的虚拟网卡
  → 逐个 pcap_open_live(65535, 非混杂, 20ms) + pcap_compile("tcp port 30031 or udp") + pcap_setfilter
  → 第一个全流程成功的即工作网卡（过滤器对齐 MaaNTE 原版：UE5 移动同步可能走 UDP）
```

抓包循环（`captureLoop`）用 `pcap_next_ex` **阻塞拉取**而非 `pcap_loop` 回调——回调形式在 Apple Silicon 上因 PAC（指针认证）崩溃（见踩坑实录）。

## 2.3 包处理管线（processPacket）

```
以太网帧 → 剥 14 字节头
  → IPv4: version==4、IHL*4、protocol==6(TCP) 或 17(UDP)、srcIP/dstIP
  → 传输层: TCP 可变头（data_offset*4）/ UDP 固定 8 字节头；Flow 元组含 proto 字段（"TCP"/"UDP"）
  → payload → packetDirection: 只放行 c2s（本地→远端；RFC1918 私有地址判定）
  → payload.count ≥ 32（findCandidates 需 searchEnd > 190 位；对齐 MaaNTE「payload 非空即试」——旧 <70 丢弃把 48 字节 c2s 移动包全挡在 decode 外）
  → UE5Decoder.decode(payload:timestamp:flow:) → Pose(x,y,z,pitch,heading)
  → 30Hz 节流写入 sample（interval = 1/30）
```

## 2.4 世界坐标 → 地图像素（worldToMapPixel）

```swift
mapX = kCalibA * wx + kCalibB * wy + kCalibTX
mapY = kCalibA * wy - kCalibB * wx + kCalibTY
```

常量（`:78-81`）：`kCalibA=0.016394586684750773`、`kCalibB=5.693519256055879e-08`、`kCalibTX=6526.474380746091`、`kCalibTY=5210.664390686138`。这是**线性仿射变换**（kCalibB 是交叉耦合项，含轻微旋转校正）。推导见四级文档。

**底图坐标系（2026-09-13 升级）**：现为 MaaNTE-Map **map-2026-08 扩图版 13056×13056**（51×51@512px 瓦片，新增区域：旧图左侧+1、顶部+7、右侧+6）；相对旧图 map-2026-06 (11264) 整体平移 (+233, +1738)，故 A/B 不变、TX/TY 直接加偏移（旧 TX/TY=6293.47…/3472.66… 保留在代码注释作历史档案）。地图 13056×13056 定义在 MinimapLocatorView(`mapSide`)/MinimapTileCache(`mapPixelSize`)。

## 2.5 自愈引擎（NetworkHealer）——已删除，改为直连

> **档案（2026-09-19）**：`NetworkHealer.swift`(377) 已在 76e9027 整体删除，定位链路简化为「DriveState 懒初始化 `CoordinateCapture` + `runNetworkLocateStep()` 10Hz 轮询」，代码注释自述「纯网络定位，无自愈引擎」。

- 现状：`coordinateCapture == nil` 时（`healerInitLock` 保护，该锁名为自愈时代遗留）新建 `CoordinateCapture()` 并 `start()`；成功 → `locateCtx.networkReady = true`。每步读 `cc.read(maxAge: 1.0)` → `worldToMapPixel` → 写 `networkLocateX/Y` 与 `locatorX/Y`（两套小地图各自消费）；无数据 → `networkLocateMode = "not_ready"/"no_data"`、score 置 0
- 删除前的历史行为（档案）：`NetworkHealer(capture:mapPath:)` + 5 秒定时诊断；`LocatorMode`：`network="pcap"` / `visual="visual"` / `failed="failed"`；`Diagnosis` 枚举 7 种但 `diagnose()` 实际只返回 5 种（permissionLost / interfaceDown / bpfDeviceBusy / gameNotRunning / unknownButDead）；权限丢失 → `restartCapture()` 不弹窗；修复后 3 秒确认窗防横跳。视觉态定位恒 nil（视觉顶班机制从未接线）

## 2.6 视觉定位（VisualLocator）——休眠状态

NCC（归一化互相关）模板匹配 + 积分图加速 + 多尺度金字塔（2048/1536/1024 + 192 粗扫档，阈值 0.80，vDSP 加速）。**类是活的但引擎休眠**：`locate(template:tw:th:scoreThreshold:)` 全项目唯一调用点是自身 `runSelfTest`；自愈引擎删除后已无任何视觉顶班分支。即：视觉顶班机制已实现未接线。

## 2.7 小地图渲染（两套并存，互不引用）

| 实现 | 常量 | 用途 |
|---|---|---|
| `MinimapTileCache` | mapPixelSize=13056 / tilesPerSide=8 / tilePixelSize=1632 / minimapPx=200 | 64 瓦片懒加载缓存，挂 FloatingMinimap（AuroraDriveApp:2353） |
| `MinimapLocatorView` | mapSide=13056 / blocksPerEdge=8 / blockSide=1632 / displayMapSide=2816 / viewSize=220 | 定位视图，挂 AuroraDriveApp:2988，内置私有 MinimapBlockCache |

地图源 `bigworldmap-13056.jpg`（MaaNTE 图源 map-2026-08 扩图版，优先候选；`bigworldmapSecond.png` 为回退候选），标记数据 `FINAL_complete_map_database.json`（nteguide）。

## 2.8 死代码说明（NetworkLocator / NetworkPacketCapture）

- `NetworkLocator.swift`（626 行）：WebSocket 客户端连 `ws://127.0.0.1:9004`，纯 JSON 协议（version=1.3.0 / mode=coordinate / x/y/z/pitch/heading）。`DualModeLocator`/`MaaNTESocketClient`/`UE5PacketDecoder` 全部零外部调用。**编译但不跑**。
- `NetworkPacketCapture.swift`（1220 行）：旧抓包实现，不在 Package.swift sources，已移 `legacy/`。
- 保留原因：NetworkLocator 是「外接 MaaNTE 助手进程」的备用定位通道，未来可能启用；死代码保留在仓库供参考。
