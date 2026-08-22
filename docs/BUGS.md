# AuroraDrive Bug 记录

## Bug 列表

### BUG-001: 屏幕分辨率硬编码

**状态**: Open  
**严重性**: High  
**发现时间**: 2026-08-21  

**问题描述**:  
`AuroraDriveApp.swift` 第 1757 行硬编码了屏幕分辨率：
```swift
let sW = 1920, sH = 1080
```

**影响**:  
- 在非 1920×1080 分辨率下，小地图 ROI 计算错误
- MacBook Pro (3024×1964)、4K 显示器等分辨率下会失败
- 全屏模式下无法正确定位

**上下文**:  
- 异环 macOS 版本只支持全屏，无法调整窗口大小
- MaaNTE (Windows) 可以控制窗口大小到 1280×720
- AuroraDrive 使用相对坐标系统 (minimapROI) 但自检逻辑硬编码了绝对分辨率

**修复方案**:  
```swift
// 方案1: 使用 mainScreen
let display = CGDisplayCreateID()!
let size = CGDisplayPixels(display)
let sW = Int(size.width)
let sH = Int(size.height)

// 方案2: 从 DriveState.screenSize 获取
guard let screenSize = DriveState.screenSize else {
    print("[LOCATELIVE] FAIL: 无法获取屏幕尺寸")
    exit(1)
}
let sW = Int(screenSize.width)
let sH = Int(screenSize.height)
```

**相关文件**:  
- `src/AuroraDrive/AuroraDriveApp.swift:1757`
- `src/AuroraDrive/AuroraDriveApp.swift:313` (minimapROI 定义)

---

## 技术约束记录

### 异环 macOS 版本限制

| 特性 | Windows (MaaNTE) | macOS (AuroraDrive) |
|------|------------------|---------------------|
| 窗口模式 | 支持小窗口 (可调整) | **只能全屏** |
| 网络坐标 | ✅ pcap/pktmon | ✅ WebSocket 定位服务 |
| 视觉定位 | ✅ 备用方案 | ✅ NCC 小地图 + EMA 平滑 |
| 窗口控制 | 可编程控制 | 不可控 |

**结论**:  
- 网络坐标：已通过 `NetworkLocator.swift` 实现 WebSocket 客户端方案，连接本地定位服务 (127.0.0.1:9004)
- 视觉定位：NCC 小地图模板匹配 + EMA 平滑，双定位源联合决策
- 预处理优化（HSV过滤+圆形掩码）已集成到视觉定位管线

---

## 更新日志

- 2026-08-21: 初始创建，记录 BUG-001
