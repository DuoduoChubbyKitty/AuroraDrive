# Internals · UE5 Movement Packet Bitstream

> Source: reverse-engineered from MaaNTE's `nte_coordinate_api.py`; Swift port in `CoordinateCapture.swift` (`UE5Decoder`)
> Up: [Network Localization](../dev/02-network-locate.en.md) ｜ 中文: [UE5 位流解析](../ue5-bitstream.md)

## 1. Where the packet comes from

The game client sends the local player's movement state (UE5 `FVector` position/acceleration + FRotator rotation) as a **compact bitstream** (not byte-aligned) over TCP 30031. After libpcap captures a c2s TCP payload and strips the Ethernet(14)/IP(IHL)/TCP(data_offset) headers, the remainder is the bitstream.

**No magic number, no packet header** — pure bit data; valid blocks can only be found by "scan + validate".

## 2. Bit-read primitive (`bits`)

```swift
func bits(_ data: [UInt8], offset: Int, count: Int) -> UInt64 {
    if count <= 0 || count > 63 || offset < 0 { return 0 }  // guards 1<<count overflow
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

Reads any width (1–63 bits) at any bit offset. The `count > 63` guard exists because `1 << 64` traps on UInt64.

## 3. Vector block (`ue5Vector`)

```
┌──────────────────────┬────────────────────────────────┐
│ 7-bit header          │ 3 components (width bits each) │
│ low 6 bits = width    │ signed two's complement         │
│ bit6 = isScaled       │                                │
└──────────────────────┴────────────────────────────────┘
```

- `width`: bits per component (valid: acceleration 1–16, position 20–32)
- `isScaled`: value ÷ scale (acceleration scale=10, position scale=100, passed in)
- Signed decode: `if v & sign != 0 { v = v &- modulus }` — **must use wrapping `&-`**; `v -= modulus` traps on UInt64 underflow (real crash)

## 4. Rotation block (`ue5Rotator`)

```
Per axis (Pitch/Yaw/Roll ×3):
  present(1bit) → 0 skips; 1 then compressed(16bit)
angle = compressed × 360 / 65536
if angle > 180 { angle -= 360 }        // fold into [-180, 180]
```

**Validity** (`hasValidRotation`): `flags[1] && !flags[2]` (Yaw present, Roll absent — movement sync carries no Roll) + `abs(pitch) ≤ 90.001` + per-axis magnitude caps.

## 5. Pose synthesis (`toPose`)

```swift
viewDir = (cos(pitch)cos(yaw), cos(pitch)sin(yaw), sin(pitch))
north = dot(viewDir, kNorth)     // kNorth=(-0.0138, -0.9999, 0)
east  = dot(viewDir, kEast)      // kEast =( 0.9999, -0.0138, 0)
heading = atan2(east, north) × 180/π; if < 0 { += 360 }
```

kNorth/kEast are the game-world north/east axes projected onto the map pixel plane (with a ~0.79° slight rotation).

## 6. Scan-and-locate (`findCandidates`)

```
searchEnd = min(512, payload.count × 8 - 60)
guard searchEnd > 190                       // short-packet guard
for offset in 190..<searchEnd:
    1. 32-bit Float32 timestamp; isFinite && 0..<100_000
    2. ue5Vector acceleration(scale=10); width 1..16; |component| < 50000
    3. ue5Vector position(scale=100); width 20..32; ≤ kMaxLocationAbs(2_000_000)
    4. hasValidRotation(locEnd + 7)
    → all pass = Candidate(time, offset, accel, location)
```

One payload may yield several candidates. `decode()` picks the one continuous with the previous frame via a state machine: flow change → `confirmFlow`; time error >1s → `reacquireCandidates`; same-offset candidates preferred (`trackingKey`).

## 7. Validation summary

| Layer | Check | Threshold |
|---|---|---|
| payload | min length | ≥70 bytes |
| timestamp | finite & range | isFinite, 0..<100_000 |
| acceleration | width / magnitude | 1..16, <50000 |
| position | width / magnitude | 20..32, ≤2,000,000 |
| rotation | present bits | Yaw yes & Roll no, pitch≤90.001 |
| sequence | continuity | timestamp/offset physically reachable |
| throttle | sample interval | 1/30 s |
