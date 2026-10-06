# 四级 · 坐标标定常量推导

> 实现于 `CoordinateCapture.swift`（`worldToMapPixel`）
> 上级：[网络定位子系统](02-network-locate.md) ｜ English: [Coordinate Calibration](../英文版/coordinate-calibration.en.md)

## 1. 问题定义

UE5 解码器输出**游戏世界坐标**（浮点，厘米级），全收集地图需要**底图像素坐标**——当前底图为 **13056×13056 扩图版（map-2026-08，2026-09-13 升级，`models/bigworldmap-13056.jpg`）**，旧图 11264×11264（`bigworldmapSecond.png`）仅保留作回退候选。两者之间隔着一个游戏地图投影，需要标定出变换关系。

## 2. 实际变换（worldToMapPixel）

```swift
mapX = kCalibA * wx + kCalibB * wy + kCalibTX
mapY = kCalibA * wy - kCalibB * wx + kCalibTY
```

**注意这是一个线性仿射变换**：kCalibB 是 wx/wy 的**交叉耦合项**（mapX 加 `+B·wy`、mapY 减 `-B·wx`），构成一个近似旋转——不是二次项。

## 3. 常量精确值（:64-81）

```
kCalibA  = 0.016394586684750773      # 主尺度因子（世界单位 → 像素）
kCalibB  = 5.693519256055879e-08     # 交叉耦合系数（地图轴与游戏轴的微小旋转偏差）
kCalibTX = 6526.474380746091         # X 平移（map-2026-08 扩图版）
kCalibTY = 5210.664390686138         # Y 平移（map-2026-08 扩图版）
kNorth   = (-0.013752068070295848, -0.9999054358407049, 0.0)
kEast    = ( 0.9999054358407049, -0.01375206807029585, 0.0)
kMaxLocationAbs = 2_000_000.0        # 世界坐标绝对值上限（厘米级，非像素）
```

> 旧图 map-2026-06（11264，`bigworldmapSecond.png`，仍作回退候选）的平移项为 TX=6293.474380746091、TY=3472.664390686138；
> 扩图相对旧图整体平移 (+233, +1738)，A/B 不变，仅 TX/TY 加偏移
> （见 CoordinateCapture.swift 常量区注释，2026-09-13 升级；标定点验证 raw(-134394.56, 199913.53) → map(4323, 8488) ✓）。

## 4. 朝向映射（toPose）

世界坐标解决「在哪」，朝向用东北单位向量点积：

```
viewDir = (cos(pitch)cos(yaw), cos(pitch)sin(yaw), sin(pitch))
north = dot(viewDir, kNorth)
east  = dot(viewDir, kEast)
heading = atan2(east, north) × 180/π，负数 +360 → [0, 360)
```

kEast/kNorth 含 ~0.79° 微小旋转偏差——游戏世界坐标轴与地图并非完美正交对齐。

## 5. 标定方法

1. **采样**：游戏内站到若干地标，同时记录 (a) 解码器输出的世界坐标 (b) 地图上该地标的像素坐标
2. **拟合**：最小二乘解仿射参数（先纯线性看残差；残差含微小旋转 → 加交叉项再拟合）
3. **验证**：留出未参与拟合的点做校验
4. **固化**：写死进源码常量（地图版本不变则参数不变）

方法论来自 MaaNTE；A/B 与旧图（map-2026-06）平移项为 MaaNTE 同步值（MaaNTE-Map navi-coordinate-calibration.json 三个标定点 delta 完全一致）。2026-09-13 升级到 map-2026-08 扩图版时，在 MaaNTE 基准的 TX/TY 上直接加整体偏移 (+233, +1738)，A/B 不变。

## 6. 维护提示

- 换显示器分辨率 / 改游戏 UI 缩放：地图固有 13056×13056（map-2026-08 扩图版）不变，**无需重标定**
- 游戏大版本重制地图：全部重采点、重拟合
- 精度检查：驾驶中比对 `locatorX/Y` 与已知地标，误差应稳定在个位数像素
