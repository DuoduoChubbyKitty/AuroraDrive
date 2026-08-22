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
| 网络坐标 | ✅ pcap/pktmon | ❌ 不可用 |
| 视觉定位 | ✅ 备用方案 | ✅ 主要方案 |
| 窗口控制 | 可编程控制 | 不可控 |

**结论**:  
- 网络坐标方案在 macOS 上不可行（需要自己实现 BPF 抓包）
- 必须依赖纯视觉定位方案
- 预处理优化（HSV过滤+圆形掩码）是提升匹配率的关键

---

## 待研究课题

### 网络坐标捕获 (macOS)

**目标**: 实现类似 PacketNTE 的 BPF 抓包功能

**现状**:  
- Windows 有编译好的 `.pyd` 二进制文件
- macOS 无对应 `.dylib`
- 需要自己实现 BPF 套接字抓包

**技术路径**:  
1. 使用 BSD BPF 套接字 (macOS 原生)
2. 监听 TCP port 30031 (游戏坐标端口)
3. 解析游戏协议包提取 (x, y, z)
4. 应用标定公式转地图坐标

**风险**:  
- 反作弊检测（网络嗅探行为）
- 协议可能加密/混淆
- 需要 root/sudo 权限

**优先级**: 低（视觉定位优化优先）

---

## 更新日志

- 2026-08-21: 初始创建，记录 BUG-001
