# AuroraDrive

Third-party viewpoint driving automation for *NTE* (Neverness to Everness) on macOS.

Screen capture → CoreML inference → key injection, with a dual-path positioning system (network packet capture + visual minimap localization) for in-game driving, route following, and driving-quality scoring.

> ⚠️ **Disclaimer**: This project is for research and personal learning only. Automating game input may violate the game's Terms of Service. The author is not responsible for any consequences, including account suspension.

---

## Acknowledgements

| Project | Usage | License |
|---|---|---|
| [MaaNTE](https://github.com/1bananachicken/MaaNTE) | Network positioning reference (UE5 movement packet parsing and calibration constants), full-collection map source (13056×13056) | AGPL-3.0 |
| [MetalGoose](https://github.com/Stallion77RepoOfficial/MetalGoose) | MetalFX upscaling + frame interpolation (display layer only) | GPL-3.0 |
| [nteguide.com](https://nteguide.com) | Full-collection map marker data | Authorized by author |

MaaNTE source code is NOT distributed with this repository (AGPL-3.0 is viral); it is kept as a local reference only.

## Features

### Driving

- **End-to-end driving**: V3 monocular model outputs vertical/horizontal driving decisions directly from frames
- **Three-tier degradation**: end-to-end → YOLO takeover → rule fallback, automatic downshift on failure
- **Controller**: converts decisions into mouse/keyboard events, with speed cap, gear lock, and emergency stop
- **Shell mode**: RL training engine embedded in the UI process, can train without the game (separate switch, off by default)

### Positioning

- **Network positioning**: libpcap captures UE5 movement sync packets (`tcp/30031 or udp`), decodes world coordinates and heading from the bitstream, maps to a 13056×13056 world map. Higher precision than visual positioning
- **Visual positioning**: the circular minimap region is CLAHE-enhanced and template-matched against the 13056×13056 basemap (circular mask); the first fix does a global search, then a 400² window tracks it frame by frame. Cloud gaming has no decodable movement packets, making this the only available path there
- **Positioning decision**: built-in launcher on cloud → visual; on local → network; when launched by the user with an unknown source, the capture target is checked for a browser window to decide
- **Failure failover**: when network positioning keeps failing while frames are still advancing, visual positioning takes over; switches back once the network recovers. A `stale` state is not treated as failure (ingame coordinate packets are intermittent)
- **Auto-calibration**: minimap ROI calibrated automatically via multi-frame circle detection, no manual coordinates; falls back to a default ROI on timeout

### Route following

- **Guide-line extraction**: extracts the yellow route line from the in-game minimap, outputting nearest-line distance, line heading, and far-end direction
- **Direction verdict**: compares world-coordinate displacement direction against the guide-line heading; a large angle difference is treated as off-route. Reverse driving is judged separately
- **Pixel-distance criterion**: nearest distance from car to guide line, used as a fallback for detecting full departure
- **Replan detection**: distance jumps are treated as the route being redrawn; the baseline resets instead of being flagged as wrong driving
- **Map overlay**: guide line rendered onto both the world map and the in-app minimap, world coordinates derived from a measured minimap span

### Perception

- **YOLOPX triple-head**: a single model emitting detection (det) / drivable area (da) / lane lines (ll)
- **Optical flow extrapolation**: DIS optical flow compensates on ticks without new model detections
- **Lane handling**: lane mask extraction, optical-flow extrapolation, lane keeping
- **Heading reading**: reads car heading and confidence from the minimap pointer arrow

### Speed and quests

- **Speed recognition**: PP-OCRv6 fine-tuned line model as primary path, per-digit CNN as fallback; single-frame read with three-layer validation (range / jump / multi-frame)
- **Quest panel OCR**: reads the in-game quest panel text, looks up an index to obtain world-coordinate targets
- **Road network prior**: `models/route_graph.json` graph used for route planning and turn anticipation

### Display and UI

- **MetalFX enhancement**: upscaling + frame interpolation, display layer only, never entering the decision path
- **Full-collection map**: multi-layer toggles (teleport points / materials / chests / oracle stones), live player position and heading
- **Persistent floating minimap**: shown at app launch, independent of the main map view
- **In-game overlay (ESP)**: entity boxes and labels written by an external backend are read over shared memory and drawn on top of the game with a full-screen transparent window (does not intercept the mouse or obscure the picture); off by default, enable with `AURORA_ESP_OVERLAY=1`
- **AI assistant**: real LLM conversation (streaming), can autonomously call tools to operate the game UI

## Quick Start

**Requirements**: macOS 26+ · Apple Silicon · Xcode Command Line Tools · libpcap (bundled with macOS)

```sh
git clone https://github.com/DuoduoChubbyKitty/AuroraDrive.git
cd AuroraDrive
./run.sh            # build + sign + launch
./run.sh --status   # environment check only
```

**System permissions**: Screen Recording + Accessibility (System Settings → Privacy & Security)

**Permissions for network positioning**: on first install, enter the current macOS admin password inside the app (no default password). The password is passed to the system only via `sudo -S` stdin; it is never written to arguments, files, or logs. Installation creates two root LaunchDaemons:

- `com.aurora.bpf-setup`: fixes `/dev/bpf*` permissions every 3 seconds
- `com.aurora.priority`: runs `renice -20` on AuroraDrive every 5 seconds

> ⚠️ **Security boundary**: the BPF daemon sets `/dev/bpf*` to `0666`, meaning every local user process can read and write the capture devices; the performance daemon periodically raises AuroraDrive to `nice -20`. This is by design. On multi-user or security-sensitive machines, read [`bpf-daemon.md`](docs/文档库/自动驾驶与功能/bpf-daemon.md) first.

## Architecture

Dual process + shared memory:

```
┌─ UI process ─────────┐   shared memory    ┌─ Engine process ─────────────┐
│ SwiftUI console / map │ ← /aurora_frame_v1 → │ ScreenCaptureKit capture      │
│ boxes / masks / state │  frames, detections │ V3 + YOLOPX + OCR (tick)      │
│ MetalFX upscale + FI  │  masks, heartbeat   │ three-tier degradation        │
└──────────────────────┘                    │ CGEvent input injection       │
                                             └──────────┬──────────────────┘
                                                        │
                                  libpcap tcp/30031 → world coords / heading
```

**Architectural red line**: frame interpolation / upscaling applies to the display overlay only — never to the decision path.

**Rates**: tick (inference + control + recording) 15Hz and capture 15fps in normal state; 20Hz / 20fps in emergency sprint. Authoritative values live in `EngineMain.engineTickHz` and the corresponding `tickHz` / `captureHz` mappings.

| Pillar | Description |
|---|---|
| Dual process + shared memory | UI and engine are two long-lived processes exchanging frames and detections via `/aurora_frame_v1`; `EngineClient.protocolVersion = 8` |
| YOLOPX triple-head perception | one model emitting detection / drivable area / lane lines |
| Optical flow + motion prediction | OpenCV DIS optical flow with α-β filtering on ticks without new detections |
| Mask visualization | drivable-area / lane masks returned to the UI via shared memory (160×160 grid, bit-packed) |

## Repository layout

```
Sources/AuroraDrive/
├── Agent/         AI assistant, tool registry, degradation state machine
├── App/           app body, DriveState, map and UI
├── Capture/       screen capture, recording, network coordinate capture
├── Control/       key injection, controller
├── Core/          process body, engine main loop, IPC
├── Inference/     model inference, speed OCR, quest OCR, heading reader
├── Locate/        visual positioning, network positioning, decision and failover
├── Perception/    lane lines, optical flow
└── RL/            online training, policy head, shell mode
Vendor/
├── OpenCVFlow/    OpenCV C bridge (optical flow, map localization, guide-line scan)
└── opencv/        OpenCV static libraries
```

## Command line

```sh
./AuroraDriveUI              # launch GUI
./AuroraDriveUI --engine     # run as the engine process
./run.sh --status            # environment check
```

Main self-test entry points:

```sh
./AuroraDriveUI --maploc-selftest        # visual positioning
./AuroraDriveUI --guideline-selftest     # guide-line detection and direction verdict
./AuroraDriveUI --guideline-replay       # offline guide-line replay (segment selectable)
./AuroraDriveUI --failover-selftest      # network-positioning failover state machine
./AuroraDriveUI --positioning-selftest   # positioning mode decision
./AuroraDriveUI --rl-core-selftest       # RL core
./AuroraDriveUI --capture-selftest       # capture pipeline
./AuroraDriveUI --llm-selftest           # AI assistant
```

See [`代码-33-进程模式与CLI参数全解.md`](docs/文档库/自动驾驶与功能/代码-33-进程模式与CLI参数全解.md) for the full flag list.

## Documentation

- [Developer guide](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md)
- [Full index](docs/文档库/自动驾驶与功能/00-文档索引.md)
- [Source tree and architecture overview](docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md)
- [ESP channel and in-game overlay](docs/文档库/自动驾驶与功能/代码-40-ESP通道与游戏画面浮层.md)
- [Human-in-the-loop and RL training pipeline](docs/v3-design/06-人机共驾与RL训练管线.md)

Per-module docs map one-to-one onto subsystems and locate code by function, type, and variable names rather than line numbers, which drift as the code changes.

## License

GPL-3.0 — see [NOTICE](NOTICE) for third-party component licenses.

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```
