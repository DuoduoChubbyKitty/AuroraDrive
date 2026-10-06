<div align="center">

# AuroraDrive

**Third-party autonomous driving system for Neverness to Everness (NTE) on macOS**

> 📌 **Correction (2026-09-29)**: The game name was previously written as "Where Winds Meet"
> (which is a *different* game, 《燕云十六声》). The correct title is **Neverness to Everness**,
> whose Chinese name is 《异环》 and whose abbreviation **NTE** is used throughout this repo.

Screen capture → CoreML inference → key injection, with packet-capture localization, speed recognition (fine-tuned PP-OCRv6 int8), an in-game AI assistant, and MetalFX display enhancement

[中文文档 (Chinese)](README.md) · [Developer Guide](docs/文档库/英文版/DEVELOPER_GUIDE.en.md)

</div>

> ⚠️ **Disclaimer**: This project is for research and personal learning only. Automating game input may violate the game's Terms of Service. The author is not responsible for any consequences, including account suspension. Evaluate the risks yourself.

---

## 🙏 Acknowledgements

| Resource | Purpose | License |
|---|---|---|
| [**MaaNTE**](https://github.com/1bananachicken/MaaNTE) | Blueprint for network localization: UE5 movement-packet bitstream parsing and coordinate calibration were ported from its `nte_coordinate_api.py`; the full-collection map source `bigworldmapSecond.png` also comes from this project | AGPL-3.0 |
| [**MetalGoose**](https://github.com/Stallion77RepoOfficial/MetalGoose) | MetalFX upscaling + frame-generation engine (`Vendor/MetalGoose`, display path only) | GPL-3.0 |
| [**nteguide.com**](https://nteguide.com) | Full-collection map marker data | Used with author's permission |

> 📌 **Copyright note**: The MaaNTE source tree is NOT distributed with this repository (AGPL-3.0 is viral to dependents); it is kept as a local reference and credited above. Map assets are distributed with the MaaNTE maintainer's permission; all rights remain with the original authors.

## ✨ Features

- **End-to-end driving**: a monocular model (M9) maps raw frames directly to control outputs, backed by a **three-tier** degrade ladder (E2E → YOLO takeover → rule fallback). The former "stuck-recovery" tier was removed on 2026-09-30 — field testing showed it capped speed and could not exit, interrupting autonomous driving after ~12 s
- **Packet-capture localization**: libpcap sniffs UE5 movement sync packets on tcp/30031; the bitstream is decoded into world coordinates + heading and mapped onto a 13056×13056 world-map pixel space (map-2026-08, upgraded 2026-09-13). Staleness is graded rather than binary — `live` ≤18 s, `recent` ≤40 s, `stale` ≤90 s, `lost` beyond that — so the UI keeps showing the last known position instead of flickering, while the decision layer stops trusting it once it leaves `live`
  > ⚠️ **Clarification (2026-10-07)**: the legacy `NetworkPacketCapture` class and `NetworkLocator.start()` are gone — the call site is commented out as "old packet-capture localization removed". **The feature itself is alive**, now running through `CoordinateCapture`: `AuroraDriveApp.swift:4447-4461` lazily constructs it and calls `cc.start()`, with the comment "pure network localization, no self-healing engine". `NetworkLocator.swift` (the WebSocket path) still compiles but is never instantiated
- **Speed recognition**: a fine-tuned PP-OCRv6 whole-line model (`models/ppocrv6_tiny_ft_int8.mlpackage`, int8-quantized, GPU inference) is the primary path, backed by a per-digit CNN (`speed_digit_cnn_v4*`) as fallback, filtered by a three-layer validation pipeline (range → jump → multi-frame confirmation; `Sources/AuroraDrive/Inference/SpeedOCRReader.swift:638-653`)
- **In-game AI assistant**: a real conversational agent that drives the game on your behalf — it answers questions and, on request, calls its own tools (key presses, typing, mouse, screenshots) to complete tasks. Streaming replies are throttled to 15 Hz so token-by-token updates never saturate the main thread, and the candidate chain tries up to 4 providers before falling back to a clearly-labelled "offline reply". **30 tools** are registered (18 skills + 4 key primitives + 1 text + 3 mouse + 2 observation + 2 web); 7 provider channels cover a keyless tier (OVHcloud / OpenCode Zen / Pollinations) and a registered-free tier (Zhipu GLM / Groq / OpenRouter), plus any OpenAI-compatible custom endpoint, behind an automatic health-checked fallback chain. Chat history slides at 200 messages (~100 turns)
- **Quest-panel OCR**: `QuestPanelReader` reads the on-screen quest title every 0.7 s, looks it up in `models/quest_index.json`, and resolves it to a world coordinate that feeds the navigation card. **On by default**; set `AURORA_QUEST_OCR=0` to disable
- **Repaired road network**: the routing graph was rebuilt on 2026-10-06 — dead ends cut from 118 (19.3%) to 36 (5.4%), yielding **664 nodes / 932 edges** at 0.61 m per pixel, driving turn-by-turn routing and curvature lookahead
- **Zero-friction BPF setup**: enter the admin password once in-app; a LaunchDaemon restores `/dev/bpf*` read/write permissions on every reboot
- **Interactive collection map**: toggleable layers (exploration / resources / teleports / monsters) over 1777 markers in 42 categories, with live player position + heading
- **MetalFX display enhancement**: upscaling + frame interpolation on the display overlay ONLY — it **never** touches the capture → inference → key-injection decision path
  > ⚠️ **Removed claim (2026-10-07)**: an earlier version of this file advertised "self-healing localization — visual template matching takes over, 8 background diagnoses repair and switch back automatically". That entry has been **deleted**: the `NetworkHealer` engine was retired in 76e9027, `VisualLocator` exists but is **never instantiated** (`grep "VisualLocator("` returns zero hits repo-wide), and no "8 diagnoses" implementation exists in the source. **Claims that cannot be verified are not kept.** The current behaviour is network localization plus the four freshness tiers described above.

## 🚀 Quick Start

**Requirements**: macOS 26+ · Apple Silicon · Xcode Command Line Tools · libpcap (bundled with macOS)

```sh
git clone https://github.com/DuoduoChubbyKitty/AuroraDrive.git
cd AuroraDrive
./run.sh            # build + ad-hoc sign + launch
./run.sh --status   # environment check only
```

**macOS permissions required**: Screen Recording + Accessibility (System Settings → Privacy & Security). Fully restart the app after re-signing.

**BPF permissions (required for network localization)**: on first launch an in-app password sheet appears (default `123456`). After installing, the `com.aurora.bpf-setup` LaunchDaemon restores permissions on every reboot — you never enter it again.

## 🏗️ Architecture

```
┌─ Capture ─────────────┐   ┌─ Inference ──────────────┐   ┌─ Actuate ─────────┐
│ ScreenCaptureKit      │ → │ E2E (m9_mono) 30Hz       │ → │ CGEvent key        │
│ 30Hz CVPixelBuffer    │   │ YOLO (yolo26s) detection │   │ injection          │
├─ Locate ──────────────┤   │ Speed OCR (PP-OCR) 30Hz │   ├─ Display ──────────┤
│ libpcap tcp/30031     │   ├─ Decide ────────────────┤   │ MetalFX upscale +  │
│ UE5 bitstream → world │   │ 3-tier degrade state     │   │ frame interp       │
│ → 13056px map pixels  │   │ machine e2e/yolo/rule    │   │ Collection map     │
└───────────────────────┘   └───────────────────────────┘   └────────────────────┘
```

**Architecture red line**: frame interpolation / upscaling applies ONLY to the display overlay. It never enters the capture → inference → key-injection decision path.

### ⚠️ The diagram above shows the early, single-process shape

Since it was drawn, the project has grown **four pillars** that the diagram does not yet reflect.
**The authoritative description lives in the Chinese overview `docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md`.**

| Pillar | What it is | Why the diagram misses it |
|---|---|---|
| **① Dual process + shared memory v3** | The UI and the engine are two long-lived processes exchanging frames and detections through `/aurora_frame_v1` shared memory (~72 MB); `EngineClient.protocolVersion = 3` | Written while the app was still single-process |
| **② YOLOPX three-in-one perception** | `YolopxEngine` emits `det` (detection) / `da` (drivable area) / `ll` (lane lines) from one model | Only `yolo26s` existed at the time |
| **③ Optical flow + motion prediction** | OpenCV DIS optical flow (`Vendor/OpenCVFlow`, ≤5 ms red line) extrapolates low-rate detections to 30 Hz via an α-β filter | Added later |
| **④ Mask visualization** | Drivable-area / lane-line masks return to the UI over shared memory (bit-packed, 160×160 grid) | Added later |

> Note: the diagram's `YOLO (yolo26s) detection` label deserves a caveat — `yolo26s` is used mainly on the *prediction* side, while in-game object detection runs through the **YOLOPX `det` head**. See `04-vision-inference` §4.8.

## 🤖 AI Assistant

The assistant is a full agent loop, not a canned chat panel:

- **Conversation**: streaming responses (SSE), history trimming, and a single shared system prompt that carries the NTE domain knowledge (`AgentChatService`)
- **Autonomous key injection**: **30 tools** are registered in one table (`ToolRegistry`) — 18 game skills, 4 key primitives (press / hold / release / release-all), text typing, 3 mouse primitives, 2 observation tools (screenshot / status) and 2 web tools (search / fetch). Every call returns the number of CGEvents it actually posted, so "it worked" is measurable rather than assumed
- **Autonomous tool selection**: the planner calls one tool per step and reads the result before choosing the next. UI interaction follows an `ESC → screenshot → mouse click` path, because F1–F12 are macOS system keys and never reach the game
- **Provider fallback chain**: the health monitor probes candidates in order and degrades automatically; the keyless tier needs no registration, and each channel's failure risk is stated honestly in the settings UI
- **Four guardrails**: observe-only mode, game-window visibility, Accessibility permission, and a dry-run mode that exercises the full path without injecting a single event

Free channels are best-effort: anonymous quotas are rate-limited and providers tighten access without notice, so treat them as a convenience rather than a guarantee.

## 🗺️ Quest OCR & Road Network

- **Quest panel OCR** (`QuestPanelReader`): a fixed ROI over the quest-title row, Vision OCR on a background queue (never on the render path), a 3-frame agreement vote to reject OCR jitter, and fuzzy matching (0.62 to qualify, 0.75 to trust) against the quest index; hint lines such as "press V to track" are filtered out before matching. Ambiguous matches within 25 m of each other are treated as equivalent and accepted
- **Quest card**: the resolved quest and its route render into a dedicated card that degrades to `--` rather than inventing numbers when data is missing
- **Road network repair** (`tools/roadnet/fix_roadnet.py`, 2026-10-06): removed 7 self-loops and 5 duplicate edges, merged 14 fork dead ends, and snapped 80 dead ends by splitting the target edge and inserting a node — iterated to convergence, because one pass leaves fake fixes with distance ≈0 that are still disconnected. 36 dead ends farther than 30 m were deliberately kept as "map to be explored later"

## 🧹 2026-09-19 Disk cleanup

To free local disk space, the following paths were moved to the external drive `/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/（⚠️ 2026-09-29 路径订正：实际在「自动驾驶项目半成品版本1.0到10.0」目录内，原文少两级）` — measured at **22 GB across 9 subdirectories**, matching the migration list below one-to-one (full mapping table: `docs/文档库/英文版/DEVELOPER_GUIDE.en.md` §7):

- `data/web_frames` (19G), `build/vid_*.mp4`, `build/template_scratch`, `build/contact`, `build/ocr_batch(2)`, `data/_gray_cache`
- `tools/ppocrv6_finetune/output` (retrainable/regenerable; contents moved to the external drive, local directory removed)
- `.build` (rebuilt automatically by `swift build`)

> 📌 The original text gave the path as `/Volumes/代码项目/删除_20260919/自动驾驶系统清理/`, which **does not exist** (`ls` reports No such file); it is nested inside the 「自动驾驶项目半成品版本1.0到10.0」 directory. **Corrected against measurement.**

✅ **Verified**: all 7 items above are now gone locally — the migration is complete, not pending.

Retained locally: `build/new_templates` (**265 entries / 264 pngs** as measured 2026-09-29; the original figure of 291/268 is stale — plus 27 rejected candidates under `_rejected/`), `build/dig_*.json` (52 evidence files), `build/maa_pipeline_override.json` (250-node ROI override), `data/mac_shots` (208 screenshots).

Iron rule: **never reduce frame rate, never work around limits with patches**.

## 📚 Documentation

English translations live in `docs/文档库/英文版/`; the documents they translate are cited next to each entry.

> ⚠️ **Link-status note (2026-10-07)**: the Level-3 English pages below translate the *early Chinese drafts* of `01-architecture` … `05-control-safety`, which were moved into `历史归档/05-自动驾驶与功能-早期稿/` on 2026-10-02. The English files themselves were restored to `docs/文档库/英文版/` on 2026-10-07 so that every link on this page resolves.
> **The authoritative current text is the Chinese `代码-XX` series** (`代码-00` is the entry page); the early drafts are for historical traceability only, and the English translations inherit that status.

| Level | English | Chinese original |
|---|---|---|
| Overview | [README.en (this page)](README.en.md) | [README.md](README.md) |
| Level 2 — Developer Guide | [Developer Guide](docs/文档库/英文版/DEVELOPER_GUIDE.en.md) | [开发者文档](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md) |
| Level 3 — Architecture *(early draft)* | [Architecture](docs/文档库/英文版/01-architecture.en.md) | [系统架构](docs/文档库/神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/01-architecture.md) |
| Level 3 — Network Localization *(early draft)* | [Network Localization](docs/文档库/英文版/02-network-locate.en.md) | [网络定位](docs/文档库/神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/02-network-locate.md) |
| Level 3 — Speed Recognition *(early draft)* | [Speed Recognition](docs/文档库/英文版/03-speed-ocr.en.md) | [速度识别](docs/文档库/神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/03-speed-ocr.md) |
| Level 3 — Vision & Inference *(early draft)* | [Vision & Inference](docs/文档库/英文版/04-vision-inference.en.md) | [视觉与推理](docs/文档库/神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/04-vision-inference.md) |
| Level 3 — Control & Safety *(early draft)* | [Control & Safety](docs/文档库/英文版/05-control-safety.en.md) | [控制与安全](docs/文档库/神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/05-control-safety.md) |
| Level 4 — Internals | [English docs index](docs/文档库/英文版/00-本目录索引.md) | [核心实现原理：代码-00 源码树与架构总览](docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md) · [全文索引](docs/文档库/自动驾驶与功能/00-文档索引.md) |

Level-4 English topics: [UE5 bitstream](docs/文档库/英文版/ue5-bitstream.en.md) · [coordinate calibration](docs/文档库/英文版/coordinate-calibration.en.md) · [BPF & LaunchDaemon](docs/文档库/英文版/bpf-daemon.en.md) · [App Nap countermeasures](docs/文档库/英文版/app-nap.en.md) · [pitfalls](docs/文档库/英文版/pitfalls.en.md)

> ⚠️ **Translation freshness**: the English documents are translations of their Chinese counterparts and are not guaranteed to move in lockstep. When the two disagree, **the Chinese original wins**.

## 📄 License

GPL-3.0 — see [NOTICE](NOTICE) for third-party component licenses. All original source files carry SPDX headers:

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```

Derived from MetalGoose (GPL v3.0, © its authors) — vendored under `Vendor/MetalGoose/` and used solely on the display path.
