<div align="center">

# AuroraDrive

**Third-party autonomous driving system for Where Winds Meet (NTE) on macOS**

Screen capture → CoreML inference → key injection, with packet-capture localization, speedometer CNN recognition, and MetalFX display enhancement

[中文文档 (Chinese)](README.md) · Developer Guide · [开发者文档 (Chinese)](docs/DEVELOPER_GUIDE.md)

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
- **Packet-capture localization**: libpcap sniffs UE5 movement sync packets on tcp/30031; the bitstream is decoded offline into world coordinates + heading and mapped onto an 11264×11264 world-map pixel space
- **Speedometer CNN**: a 5-layer convolutional network (`speed_digit_cnn_v4.mlpackage`, INT4-quantized) reads three digit slots, filtered by a three-layer validation pipeline
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
├─ Locate ──────────────┤   │ Speed CNN (v4) 30Hz      │   ├─ Display ──────────┤
│ libpcap tcp/30031     │   ├─ Decide ────────────────┤   │ MetalFX upscale +  │
│ UE5 bitstream → world │   │ 4-tier degrade state     │   │ frame interp       │
│ → 11264px map pixels  │   │ machine e2e/yolo/rec/rule│   │ Collection map     │
└───────────────────────┘   └───────────────────────────┘   └────────────────────┘
```

**Architecture red line**: frame interpolation / upscaling applies ONLY to the display overlay. It never enters the capture → inference → key-injection decision path.

## 📚 Documentation

| Level | Document |
|---|---|
| Overview | [README.en (this page)](README.en.md) · [Chinese README](README.md) |
| Level 2 — Developer Guide | [Developer Guide](docs/DEVELOPER_GUIDE.en.md) · [中文](docs/DEVELOPER_GUIDE.md) |
| Level 3 — Architecture | [01-architecture](docs/dev/en/01-architecture.en.md) |
| Level 3 — Network Localization | [02-network-locate](docs/dev/en/02-network-locate.en.md) |
| Level 3 — Speed Recognition | [03-speed-ocr](docs/dev/en/03-speed-ocr.en.md) |
| Level 3 — Vision & Inference | [04-vision-inference](docs/dev/en/04-vision-inference.en.md) |
| Level 3 — Control & Safety | [05-control-safety](docs/dev/en/05-control-safety.en.md) |
| Level 4 — Internals | [Internals](docs/internals/en/) |

## 📄 License

GPL-3.0 — see [NOTICE](NOTICE) for third-party component licenses. All original source files carry SPDX headers:

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```

Derived from MetalGoose (GPL v3.0, © its authors) — vendored under `Vendor/MetalGoose/` and used solely on the display path.