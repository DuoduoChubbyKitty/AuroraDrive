<div align="center">

# AuroraDrive

**Third-party autonomous driving system for Neverness to Everness (NTE) on macOS**

> 📌 **Correction (2026-09-29)**: The game name was previously written as "Where Winds Meet"
> (which is a *different* game, 《燕云十六声》). The correct title is **Neverness to Everness**,
> whose Chinese name is 《异环》 and whose abbreviation **NTE** is used throughout this repo.

Screen capture → CoreML inference → key injection, with packet-capture localization, speed recognition (fine-tuned PP-OCRv6 int8), and MetalFX display enhancement

[中文文档 (Chinese)](README.md) · Developer Guide · [开发者文档 (Chinese)](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md)

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

- **End-to-end driving**: a monocular model (M9) maps raw frames directly to control outputs, backed by a four-tier degrade ladder (E2E → YOLO takeover → stuck-recovery → rule fallback)
- **Packet-capture localization**: libpcap sniffs UE5 movement sync packets on tcp/30031; the bitstream is decoded into world coordinates + heading and mapped onto a 13056×13056 world-map pixel space (map-2026-08, upgraded 2026-09-13)
- **Speed recognition**: a fine-tuned PP-OCRv6 whole-line model (`models/ppocrv6_tiny_ft_int8.mlpackage`, int8-quantized, GPU inference) is the primary path, backed by a per-digit CNN (`speed_digit_cnn_v4*`) as fallback, filtered by a three-layer validation pipeline
- **Zero-friction BPF setup**: enter the admin password once in-app; a LaunchDaemon restores `/dev/bpf*` read/write permissions on every reboot
- **Self-healing localization**: when packet capture fails, a visual template matcher takes over while 8 background diagnoses attempt repair and switch back automatically
- **Interactive collection map**: toggleable layers (teleports / materials / chests / essences) with live player position + heading
- **MetalFX display enhancement**: upscaling + frame interpolation on the display overlay ONLY — it **never** touches the capture → inference → key-injection decision path

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
│ UE5 bitstream → world │   │ 4-tier degrade state     │   │ frame interp       │
│ → 13056px map pixels │   │ machine e2e/yolo/rec/rule│   │ Collection map     │
└───────────────────────┘   └───────────────────────────┘   └────────────────────┘
```

**Architecture red line**: frame interpolation / upscaling applies ONLY to the display overlay. It never enters the capture → inference → key-injection decision path.

## 🧹 2026-09-19 Disk cleanup

To free local disk space, the following paths were moved to the external drive `/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/（⚠️ 2026-09-29 路径订正：实际在「自动驾驶项目半成品版本1.0到10.0」目录内，原文少两级）` (full mapping table: `docs/文档库/英文版/DEVELOPER_GUIDE.en.md` §7):

- `data/web_frames` (19G), `build/vid_*.mp4`, `build/template_scratch`, `build/contact`, `build/ocr_batch(2)`, `data/_gray_cache`
- `tools/ppocrv6_finetune/output` (retrainable/regenerable; contents moved to the external drive, local directory removed)
- `.build` (rebuilt automatically by `swift build`)

Retained locally: `build/new_templates` (291 entries / 268 pngs), `build/dig_*.json` (52 evidence files), `build/maa_pipeline_override.json` (250-node ROI override), `data/mac_shots` (208 screenshots).

Iron rule: **never reduce frame rate, never work around limits with patches**.

## 📚 Documentation

| Level | Document |
|---|---|
| Overview | [README.en (this page)](README.en.md) · [Chinese README](README.md) |
| Level 2 — Developer Guide | [Developer Guide](docs/文档库/英文版/DEVELOPER_GUIDE.en.md) · [中文](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md) |
| Level 3 — Architecture | [01-architecture](docs/文档库/英文版/01-architecture.en.md) |
| Level 3 — Network Localization | [02-network-locate](docs/文档库/英文版/02-network-locate.en.md) |
| Level 3 — Speed Recognition | [03-speed-ocr](docs/文档库/英文版/03-speed-ocr.en.md) |
| Level 3 — Vision & Inference | [04-vision-inference](docs/文档库/英文版/04-vision-inference.en.md) |
| Level 3 — Control & Safety | [05-control-safety](docs/文档库/英文版/05-control-safety.en.md) |
| Level 4 — Internals | [Internals](docs/文档库/英文版/) |

## 📄 License

GPL-3.0 — see [NOTICE](NOTICE) for third-party component licenses. All original source files carry SPDX headers:

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```

Derived from MetalGoose (GPL v3.0, © its authors) — vendored under `Vendor/MetalGoose/` and used solely on the display path.