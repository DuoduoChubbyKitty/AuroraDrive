# 四级 · UE5 移动包位流逐字段解析

> 来源：MaaNTE `nte_coordinate_api.py` 位级协议逆向，Swift 移植于 `Sources/AuroraDrive/CoordinateCapture.swift`（`UE5Decoder`）
> 上级：[网络定位子系统](../dev/02-network-locate.md) ｜ English: [UE5 Bitstream](en/ue5-bitstream.en.md)

## 1. 包从哪来

《异环》客户端把本机玩家移动状态（UE5 `FVector` 位置/加速度 + FRotator 朝向）以**紧凑位流**（非字节对齐）通过 TCP 30031 发往服务器。libpcap 抓到 c2s 方向 TCP payload，剥掉 Ethernet(14)/IP(IHL)/TCP(data_offset) 三层头后就是位流。

**无包魔数、无包头标志**——纯位数据，只能「扫描 + 校验」定位有效块。

## 2. 位读取原语（`bits`，:72）

```swift
func bits(_ data: [UInt8], offset: Int, count: Int) -> UInt64 {
    if count <= 0 || count > 63 || offset < 0 { return 0 }  // 防 1<<count 溢出
    let firstByte = offset / 8
    let lastByte = (offset + count + 7) / 8
    if firstByte < 0 || lastByte > data.count || lastByte <= firstByte { return 0 }
    var value: UInt64 = 0
    for i in stride(from: lastByte - 1, through: firstByte, by: -1) {
        value = (value << 8) | UInt64(data[i])
    }
    return (value >> UInt64(offset % 8)) & ((UInt64(1) << UInt64(count)) - 1)
}
```

任意 bit 偏移读任意宽度（1~63 位）。`count > 63` 防护因为 `1 << 64` 在 UInt64 是运行时陷阱。

## 3. 向量块（`ue5Vector`，:89）

```
┌───────────────────────┬──────────────────────────────┐
│ 7 位头                 │ 3 分量（各 width 位，有符号补码）│
│ 低 6 位 = width        │                              │
│ bit6   = isScaled      │                              │
└───────────────────────┴──────────────────────────────┘
```

- `width`：每分量位宽（加速度 1~16、位置 20~32 有效）
- `isScaled`：true 时值 ÷ scale（加速度 scale=10，位置 scale=100，调用处传入）
- 有符号解码：`if v & sign != 0 { v = v &- modulus }`——**必须用 `&-` 回绕减法**，`v -= modulus` 在 UInt64 上会触发下溢陷阱（踩过：SIGTRAP 闪退）

## 4. 旋转块（`ue5Rotator`，:109）

```
每轴（Pitch/Yaw/Roll 共 3 次）:
  present(1bit) → 0 则跳过；1 则 compressed(16bit)
angle = compressed × 360 / 65536
if angle > 180 { angle -= 360 }        // 折叠到 [-180, 180]
```

**有效性校验**（`hasValidRotation`，:128）：`flags[1] && !flags[2]`（Yaw 存在且 Roll 不存在——移动同步不带 Roll）+ `abs(pitch) ≤ 90.001` + 各轴幅值上限。

## 5. 姿态合成（`toPose`，:158）

```swift
viewDir = (cos(pitch)cos(yaw), cos(pitch)sin(yaw), sin(pitch))
north = dot(viewDir, kNorth)     // kNorth=(-0.0138, -0.9999, 0)
east  = dot(viewDir, kEast)      // kEast =( 0.9999, -0.0138, 0)
heading = atan2(east, north) × 180/π，负数 +360
```

kNorth/kEast 是「游戏世界坐标系的北/东方向投影到地图像素平面」的基底（含 ~0.79° 轻微旋转偏差）。

## 6. 扫描定位（`findCandidates`，:270）

```
searchEnd = min(512, payload.count × 8 - 60)
guard searchEnd > 190                       // 短包防护（防 Range 陷阱）
for offset in 190..<searchEnd:
    1. 32bit Float32 时间戳，isFinite && 0..<100_000
    2. ue5Vector 加速度(scale=10)，width 1..16，分量绝对值 < 50000
    3. ue5Vector 位置(scale=100)，width 20..32，分量 ≤ kMaxLocationAbs(2_000_000)
    4. hasValidRotation(locEnd + 7)
    → 全过 = Candidate(time, offset, accel, location)
```

一个 payload 可能扫出多个候选。`decode()`（:217）用状态机挑出与上一帧衔接的：换 flow → `confirmFlow` 确认；时间误差 >1s → `reacquireCandidates` 重捕获；同 offset 候选优先（`trackingKey`）。

## 7. 校验汇总

| 层 | 校验 | 阈值 |
|---|---|---|
| payload | 最小长度 | ≥70 字节 |
| 时间戳 | 有限 & 范围 | isFinite, 0..<100_000 |
| 加速度 | 位宽/幅值 | 1..16, <50000 |
| 位置 | 位宽/幅值 | 20..32, ≤2,000,000 |
| 旋转 | present 位 | Yaw 有 & Roll 无，pitch≤90.001 |
| 时序 | 连续性 | 时间戳/offset 物理可达 |
| 节流 | 采样间隔 | 1/30 s |
