# Internals · UE5 Movement Packet Bitstream

> Source: reverse-engineered from MaaNTE's `nte_coordinate_api.py`; Swift port in `CoordinateCapture.swift` (`UE5Decoder`)
> Up: [Network Localization](02-network-locate.en.md) ｜ 中文: [UE5 位流解析](../自动驾驶与功能/ue5-bitstream.md)

> **Archive note (verified 2026-09-19)**: the bitstream protocol itself is unchanged; the capture side was aligned with MaaNTE's "tcp port 30031 or udp + try whenever the payload is ≥32 bytes", and 2026-09-13 fixed the `hasValidRotation` argument (`locEnd + 7` → `locEnd`). Line references below updated to current code.

## 1. Where the packet comes from

The game client sends the local player's movement state (UE5 `FVector` position/acceleration + FRotator rotation) as a **compact bitstream** (not byte-aligned) over TCP 30031 (the capture filter is `tcp port 30031 or udp` — UE5 movement sync may also ride UDP, MaaNTE-aligned). After libpcap captures a c2s payload and strips the Ethernet(14)/IP(IHL)/transport (TCP data_offset / UDP fixed 8-byte) headers, the remainder is the bitstream.

**No magic number, no packet header** — pure bit data; valid blocks can only be found by "scan + validate".

## 2. Bit-read primitive (`bits`, :92)

```swift
func bits(_ data: [UInt8], offset: Int, count: Int) -> UInt64 {
    if count <= 0 || count > 63 || offset < 0 { return 0 }  // guards 1<<count overflow
    let firstByte = offset / 8
    let lastByte = (offset + count + 7) / 8
    if firstByte < 0 || lastByte > data.count || lastByte <= firstByte { return 0 }
    var value: UInt64 = 0
    for i in stride(from: lastByte - 1, through: firstByte, by: -1) {
        if i < 0 || i >= data.count { return 0 }   // in-loop bounds guard
        value = (value << 8) | UInt64(data[i])
    }
    return (value >> UInt64(offset % 8)) & ((UInt64(1) << UInt64(count)) - 1)
}
```

Reads any width (1–63 bits) at any bit offset. The `count > 63` guard exists because `1 << 64` traps on UInt64.

## 3. Vector block (`ue5Vector`, :109)

```
┌──────────────────────┬────────────────────────────────┐
│ 7-bit header          │ 3 components (width bits each) │
│ low 6 bits = width    │ signed two's complement         │
│ bit6 = isScaled       │                                │
└──────────────────────┴────────────────────────────────┘
```

- `width`: bits per component (valid: acceleration 1–16, position 20–32)
- `isScaled`: value ÷ scale (acceleration scale=10, position scale=100, passed in)
- Signed decode: `if v & sign != 0 { v = v &- modulus }` — **wrapping `&-` is required**; `v -= modulus` traps on UInt64 underflow (a real crash). The current code writes it as `Int64(bitPattern: v &- modulus)` (a comment notes that using the UInt64 `&-` result as an unsigned value wraps to a huge positive number — it must pass through `bitPattern` to get two's-complement Int64 semantics)

## 4. Rotation block (`ue5Rotator`, :132)

```
Per axis (Pitch/Yaw/Roll ×3):
  present(1bit) → 0 skips; 1 then compressed(16bit)
angle = compressed × 360 / 65536
if angle > 180 { angle -= 360 }        // fold into [-180, 180]
```

**Validity** (`hasValidRotation`, :151): `flags[1] && !flags[2]` (Yaw present, Roll absent — movement sync carries no Roll) + `abs(pitch) ≤ 90.001` + per-axis magnitude caps (`kMaxRotationAbs=180.001`).

## 5. Pose synthesis (`toPose`, :181)

```swift
viewDir = (cos(pitch)cos(yaw), cos(pitch)sin(yaw), sin(pitch))
north = dot(viewDir, kNorth)     // kNorth=(-0.0138, -0.9999, 0)
east  = dot(viewDir, kEast)      // kEast =( 0.9999, -0.0138, 0)
heading = atan2(east, north) × 180/π; if < 0 { += 360 }
```

kNorth/kEast are the game-world north/east axes projected onto the map pixel plane (with a ~0.79° slight rotation).

## 6. Scan-and-locate (`findCandidates`, :297)

```
searchEnd = min(512, payload.count × 8 - 60)
guard searchEnd > 190                       // short-packet guard
for offset in 190..<searchEnd:
    1. 32-bit Float32 timestamp; isFinite && 0..<100_000
    2. ue5Vector acceleration(scale=10); width 1..16; |component| < 50000 (and isScaled)
    3. ue5Vector position(scale=100); width 20..32; ≤ kMaxLocationAbs(2_000_000) (and isScaled)
    4. hasValidRotation(locEnd)   ← 20260913 fix: the old locEnd+7 read 7 extra bits
                                     (locEnd is already "end of the location vector = start of
                                      rotation"; +7 misaligned and made hasValidRotation
                                      always fail → 0 candidates)
    → all pass = Candidate(time, offset, accel, location)
```

One payload may yield several candidates. `decode()` (:243) picks the one continuous with the previous frame via a state machine: flow change → `confirmFlow`; time error >1s → `reacquireCandidates`; candidate selection uses `trackingKey` = time error + spatial penalty (distance² from the previous frame's location / 5000², capped at 100; same-offset candidates preferred).

## 7. Validation summary

| Layer | Check | Threshold |
|---|---|---|
| payload | min length | ≥32 bytes (was ≥70; MaaNTE-aligned "try whenever the payload is non-empty" — the old <70 drop blocked all 48-byte c2s movement packets) |
| timestamp | finite & range | isFinite, 0..<100_000 |
| acceleration | width / magnitude | 1..16, <50000 |
| position | width / magnitude | 20..32, ≤2,000,000 |
| rotation | present bits | Yaw yes & Roll no, pitch≤90.001 |
| sequence | continuity | timestamp/offset physically reachable |
| throttle | sample interval | 1/30 s |
