# 2. Network Localization

> Sources: `CoordinateCapture.swift`(576, primary) `NetworkHealer.swift`(377) `VisualLocator.swift`(491, idle) `MinimapLocatorView.swift`(193) `MinimapTileCache.swift`(175) `NetworkLocator.swift`(626, dead)
> Up: [Developer Guide](../../DEVELOPER_GUIDE.en.md) ｜ 中文: [网络定位子系统](../02-network-locate.md)
> Deep dives: [UE5 Bitstream](../../internals/en/ue5-bitstream.en.md) · [Coordinate Calibration](../../internals/en/coordinate-calibration.en.md) · [BPF & LaunchDaemon](../../internals/en/bpf-daemon.en.md)

## 2.1 Module landscape (live vs dead, verified per file)

| File | Status | Notes |
|---|---|---|
| `CoordinateCapture.swift` | **live** (primary) | libpcap on tcp/30031 → UE5 bitstream decode |
| `NetworkHealer.swift` | **live** (instantiated at AuroraDriveApp:555, 5s timer) | diagnosis + repair arbiter |
| `VisualLocator.swift` | class live, **NCC engine idle** | `locate(template:)` has no caller outside its own self-test; visual mode always returns nil |
| `MinimapLocatorView` / `MinimapTileCache` | **live** (two independent minimap implementations) | mounted at AuroraDriveApp:2078 and :1602 |
| `NetworkLocator.swift` | **dead code** | WebSocket client (`ws://127.0.0.1:9004`), never instantiated |
| `NetworkPacketCapture.swift` | **dead** (moved to `legacy/`, not compiled) | legacy capture implementation |

The primary App instantiates `CoordinateCapture()` + `NetworkHealer(capture:mapPath:)` (AuroraDriveApp:555-558) — the pcap chain is what actually drives localization.

## 2.2 Capture (CoordinateCapture.start)

NIC selection uses **`pcap_findalldevs` enumeration** (not `lookupdev`, which returns only the default-route NIC on macOS — game traffic on en8 would yield zero packets forever):

```
pcap_findalldevs enumerates all NICs
  → skip lo0/pdp_ip/utun/awdl/xhc20 bridge virtual NICs
  → per NIC: pcap_open_live(65535, non-promisc, 20ms) + pcap_compile("tcp port 30031") + pcap_setfilter
  → first NIC that passes the whole pipeline becomes the working NIC
```

The loop (`captureLoop`) pulls with `pcap_next_ex` instead of the `pcap_loop` callback — the callback form crashes on Apple Silicon due to PAC (see Pitfalls).

## 2.3 Packet pipeline (processPacket)

```
Ethernet frame → strip 14-byte header
  → IPv4: version==4, IHL*4, protocol==6(TCP), srcIP/dstIP
  → TCP: srcPort/dstPort, data_offset*4
  → payload → packetDirection: allow c2s only (local→remote; RFC1918 private ranges)
  → payload.count ≥ 70 (scan window requirement)
  → UE5Decoder.decode(payload:timestamp:flow:) → Pose(x,y,z,pitch,heading)
  → throttled to 30Hz into sample
```

## 2.4 World coordinates → map pixels (worldToMapPixel)

```swift
mapX = kCalibA * wx + kCalibB * wy + kCalibTX
mapY = kCalibA * wy - kCalibB * wx + kCalibTY
```

Constants: `kCalibA=0.016394586684750773`, `kCalibB=5.693519256055879e-08`, `kCalibTX=6293.474380746091`, `kCalibTY=3472.664390686138`. This is a **linear affine transform** (kCalibB is a cross-coupling term encoding a slight rotation). Derivation in Internals. The 11264×11264 map size is defined in MinimapLocatorView/MinimapTileCache, not here.

## 2.5 Self-healing (NetworkHealer)

- Instantiated at AuroraDriveApp:555 with a 5-second diagnosis timer
- `LocatorMode`: `network="pcap"` / `visual="visual"` / `failed="failed"`
- `Diagnosis` declares 7 cases, but **`diagnose()` actually returns only 5**: permissionLost / interfaceDown / bpfDeviceBusy / gameNotRunning / unknownButDead (portChanged is only handled in attemptRepair; mapFileNotFound comes from the visual path)
- `currentLocation()`: network mode reads `capture.read(maxAge:1.0)` → worldToMapPixel; **visual mode always returns nil** (visual fixing requires a screenshot, handled upstream)
- Repair actions per diagnosis; permissionLost → `restartCapture()` only (**no dialogs** — permissions are owned by BPFSetup/UI); a 3s confirmation window prevents flip-flopping back too early

## 2.6 Visual locator (VisualLocator) — wired but idle

NCC (normalized cross-correlation) template matching with integral-image acceleration and a multi-scale pyramid (2048/1536/1024 + a 192 global coarse tier, threshold 0.80, vDSP accelerated). **The class is live but the engine is idle**: the only caller of `locate(template:)` is its own `runSelfTest`; the healer's visual branch currently always returns nil. The takeover mechanism is implemented but not connected.

## 2.7 Minimap rendering (two coexisting implementations)

| Impl | Constants | Role |
|---|---|---|
| `MinimapTileCache` | mapPixelSize=11264 / tilesPerSide=8 / tilePixelSize=1408 / minimapPx=200 | 64-tile lazy cache, mounted on FloatingMinimap (AuroraDriveApp:1602) |
| `MinimapLocatorView` | mapSide=11264 / blocksPerEdge=8 / blockSide=1408 / displayMapSide=2816 / viewSize=220 | localization view, mounted at AuroraDriveApp:2078 with its own private block cache |

Map source: `bigworldmapSecond.png` (MaaNTE asset, distributed with permission); markers: `FINAL_complete_map_database.json` (nteguide).

## 2.8 Dead code (NetworkLocator / NetworkPacketCapture)

- `NetworkLocator.swift` (626 lines): WebSocket client to `ws://127.0.0.1:9004`, plain-JSON protocol (version=1.3.0 / mode=coordinate / x/y/z/pitch/heading). `DualModeLocator`/`MaaNTESocketClient`/`UE5PacketDecoder` have zero external callers. **Compiles but never runs.**
- `NetworkPacketCapture.swift` (1220 lines): legacy capture implementation, not in Package.swift sources, moved to `legacy/`.
- Kept for reference: NetworkLocator is a backup localization channel for an external MaaNTE assistant process that may be enabled in the future.
