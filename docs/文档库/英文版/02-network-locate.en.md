# 2. Network Localization

> Sources: `CoordinateCapture.swift`(635, primary) `VisualLocator.swift`(491, idle) `MinimapLocatorView.swift`(196) `MinimapTileCache.swift`(179) `NetworkLocator.swift`(626, dead)
> Up: [Developer Guide](DEVELOPER_GUIDE.en.md) ｜ 中文: [网络定位子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/02-network-locate.md)
> Deep dives: [UE5 Bitstream](ue5-bitstream.en.md) · [Coordinate Calibration](coordinate-calibration.en.md) · [BPF & LaunchDaemon](bpf-daemon.en.md)

> **Archive note (verified 2026-09-19, baseline 7b7d2db)**: `NetworkHealer.swift`(377) was deleted in 76e9027 (self-healing retired; localization is now a lazy `CoordinateCapture` init); the capture filter is now `tcp port 30031 or udp` (MaaNTE-aligned, UDP allowed); minimum payload length relaxed from 70 to 32 bytes; the base map was upgraded to 13056×13056 (map-2026-08, 2026-09-13) with kCalibTX/TY re-calibrated accordingly.

## 2.1 Module landscape (live vs dead, verified per file)

| File | Status | Notes |
|---|---|---|
| `CoordinateCapture.swift` | **live** (primary) | libpcap on `tcp port 30031 or udp` → UE5 bitstream decode |
| ~~`NetworkHealer.swift`~~ | **deleted** (76e9027) | was the diagnosis + repair arbiter; `runNetworkLocateStep()` now lazily inits `CoordinateCapture` directly (`healerInitLock` is a leftover name) |
| `VisualLocator.swift` | class live, **NCC engine idle** | `locate(template:tw:th:scoreThreshold:)` has no caller outside its own self-test; no visual takeover branch remains |
| `MinimapLocatorView` / `MinimapTileCache` | **live** (two independent minimap implementations) | MinimapTileCache mounted on FloatingMinimap (AuroraDriveApp:2353), MinimapLocatorView at :2988 |
| `NetworkLocator.swift` | **dead code** | WebSocket client (`ws://127.0.0.1:9004`), never instantiated |
| `NetworkPacketCapture.swift` | **dead** (moved to `legacy/`, not compiled) | legacy capture implementation |

DriveState lazily instantiates `CoordinateCapture()` inside `runNetworkLocateStep()` — the pcap chain is what actually drives localization.

## 2.2 Capture (CoordinateCapture.start)

NIC selection uses **`pcap_findalldevs` enumeration** (not `lookupdev`, which returns only the default-route NIC on macOS — game traffic on en8 would yield zero packets forever):

```
pcap_findalldevs enumerates all NICs
  → skip virtual NICs with lo/pdp/utun/awdl/bridge/xhc prefixes
  → per NIC: pcap_open_live(65535, non-promisc, 20ms) + pcap_compile("tcp port 30031 or udp") + pcap_setfilter
  → first NIC that passes the whole pipeline becomes the working NIC (filter aligned with MaaNTE: UE5 movement sync may ride UDP)
```

The loop (`captureLoop`) pulls with `pcap_next_ex` instead of the `pcap_loop` callback — the callback form crashes on Apple Silicon due to PAC (see Pitfalls).

## 2.3 Packet pipeline (processPacket)

```
Ethernet frame → strip 14-byte header
  → IPv4: version==4, IHL*4, protocol==6(TCP) or 17(UDP), srcIP/dstIP
  → transport: TCP variable header (data_offset*4) / UDP fixed 8-byte header; the Flow tuple carries a proto field ("TCP"/"UDP")
  → payload → packetDirection: allow c2s only (local→remote; RFC1918 private ranges)
  → payload.count ≥ 32 (findCandidates needs searchEnd > 190 bits; MaaNTE-aligned "try whenever the payload is non-empty" — the old <70 drop blocked all 48-byte c2s movement packets)
  → UE5Decoder.decode(payload:timestamp:flow:) → Pose(x,y,z,pitch,heading)
  → throttled to 30Hz into sample
```

## 2.4 World coordinates → map pixels (worldToMapPixel)

```swift
mapX = kCalibA * wx + kCalibB * wy + kCalibTX
mapY = kCalibA * wy - kCalibB * wx + kCalibTY
```

Constants (`:78-81`): `kCalibA=0.016394586684750773`, `kCalibB=5.693519256055879e-08`, `kCalibTX=6526.474380746091`, `kCalibTY=5210.664390686138`. This is a **linear affine transform** (kCalibB is a cross-coupling term encoding a slight rotation). Derivation in Internals.

**Base-map coordinate system (upgraded 2026-09-13)**: now the MaaNTE-Map **map-2026-08 extended version, 13056×13056** (51×51@512px tiles; added regions: left+1, top+7, right+6 vs the old map) — a whole-map shift of (+233, +1738) relative to the old map-2026-06 (11264), so A/B stay the same and TX/TY absorb the offset (old TX/TY=6293.47…/3472.66… kept in code comments as a historical archive). The 13056×13056 size is defined in MinimapLocatorView(`mapSide`)/MinimapTileCache(`mapPixelSize`), not here.

## 2.5 Self-healing (NetworkHealer) — deleted, direct chain instead

> **Archive (2026-09-19)**: `NetworkHealer.swift`(377) was deleted wholesale in 76e9027; the localization chain was simplified to "DriveState lazily inits `CoordinateCapture` + `runNetworkLocateStep()` at 10Hz" (code comment: "pure network localization, no self-healing engine").

- Current behavior: when `coordinateCapture == nil` (guarded by `healerInitLock`, a leftover name from the healer era) a fresh `CoordinateCapture()` is created and `start()`ed; on success `locateCtx.networkReady = true`. Each step reads `cc.read(maxAge: 1.0)` → `worldToMapPixel` → writes `networkLocateX/Y` and `locatorX/Y` (the two minimaps each consume their own fields); no data → `networkLocateMode = "not_ready"/"no_data"`, score 0
- Pre-deletion behavior (archive): `NetworkHealer(capture:mapPath:)` with a 5-second diagnosis timer; `LocatorMode`: `network="pcap"` / `visual="visual"` / `failed="failed"`; `Diagnosis` declared 7 cases but `diagnose()` actually returned only 5 (permissionLost / interfaceDown / bpfDeviceBusy / gameNotRunning / unknownButDead); permissionLost → `restartCapture()` (no dialogs); a 3s confirmation window prevented flip-flopping; the visual branch always returned nil (the visual takeover was never wired)

## 2.6 Visual locator (VisualLocator) — wired but idle

NCC (normalized cross-correlation) template matching with integral-image acceleration and a multi-scale pyramid (2048/1536/1024 + a 192 global coarse tier, threshold 0.80, vDSP accelerated). **The class is live but the engine is idle**: the only caller of `locate(template:tw:th:scoreThreshold:)` is its own `runSelfTest`; after the healer's deletion no visual takeover branch remains at all. The takeover mechanism is implemented but not connected.

## 2.7 Minimap rendering (two coexisting implementations)

| Impl | Constants | Role |
|---|---|---|
| `MinimapTileCache` | mapPixelSize=13056 / tilesPerSide=8 / tilePixelSize=1632 / minimapPx=200 | 64-tile lazy cache, mounted on FloatingMinimap (AuroraDriveApp:2353) |
| `MinimapLocatorView` | mapSide=13056 / blocksPerEdge=8 / blockSide=1632 / displayMapSide=2816 / viewSize=220 | localization view, mounted at AuroraDriveApp:2988 with its own private block cache |

Map source: `bigworldmap-13056.jpg` (MaaNTE asset, map-2026-08 extended version, preferred candidate; `bigworldmapSecond.png` as fallback); markers: `FINAL_complete_map_database.json` (nteguide).

## 2.8 Dead code (NetworkLocator / NetworkPacketCapture)

- `NetworkLocator.swift` (626 lines): WebSocket client to `ws://127.0.0.1:9004`, plain-JSON protocol (version=1.3.0 / mode=coordinate / x/y/z/pitch/heading). `DualModeLocator`/`MaaNTESocketClient`/`UE5PacketDecoder` have zero external callers. **Compiles but never runs.**
- `NetworkPacketCapture.swift` (1220 lines): legacy capture implementation, not in Package.swift sources, moved to `legacy/`.
- Kept for reference: NetworkLocator is a backup localization channel for an external MaaNTE assistant process that may be enabled in the future.
