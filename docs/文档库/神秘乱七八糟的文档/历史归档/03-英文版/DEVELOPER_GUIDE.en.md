# AuroraDrive Developer Guide (English)

> This is the **Level-2 entry point** of all development docs. Each chapter links to an independent Level-3 document; for the deepest implementation details, see the Level-4 *Internals*. Chinese version: [DEVELOPER_GUIDE.md](../自动驾驶与功能/DEVELOPER_GUIDE.md)
>
> **Accuracy covenant**: every constant, function name and flow described here is taken directly from the repository source (cited as `file:line`), with zero deviation from code. Where comments contradict implementation, the code wins and the discrepancy is called out explicitly.

---

## Table of Contents (Level 3)

| Ch. | Document | Sources covered (Sources/AuroraDrive/) |
|---|---|---|
| 1 | [Architecture Overview](01-architecture.en.md) | `AuroraDriveApp.swift`(4379) `DegradeStateMachine.swift`(250) |
| 2 | [Network Localization](02-network-locate.en.md) | `CoordinateCapture.swift`(635) ~~`NetworkHealer.swift`~~ (deleted in 76e9027) `VisualLocator.swift`(491) `MinimapLocatorView.swift` `MinimapTileCache.swift` |
| 3 | [Speed Recognition](03-speed-ocr.en.md) | `SpeedOCRReader.swift`(1243, PP-OCRv6 primary / CNN backup) |
| 4 | [Vision & Inference](04-vision-inference.en.md) | `CaptureEngine.swift` `InferenceEngine.swift` `YoloEngine.swift` `ConfidenceEstimator.swift` `RecordEngine.swift` |
| 5 | [Control & Safety](05-control-safety.en.md) | `ControlEngine.swift` `KeyboardMonitor.swift` `RuleController.swift` `EscapeController.swift` |
| 6 | [FAQ](#6-faq) | — |
| 7 | [2026-09-19 Disk Cleanup Note](#7-2026-09-19-disk-cleanup-note) | Migrated path table + MaaNTE status |

### Level 4 — Internals

| Document | Reveals |
|---|---|
| [UE5 Movement Packet Bitstream](ue5-bitstream.en.md) | bit-read primitive / vector block / rotation block / scan-and-locate |
| [Coordinate Calibration](coordinate-calibration.en.md) | kCalibA/B/TX/TY affine transform and the N/E unit vectors |
| [BPF & LaunchDaemon](bpf-daemon.en.md) | in-app password → osascript → boot-time auto-repair |
| [App Nap Countermeasures](app-nap.en.md) | six locks: disable-termination / beginActivity / -20 / EventTap / 768MB mlock / RT policy |
| [Pitfalls](pitfalls.en.md) | PAC crash / unsigned underflow / wrong NIC / CoreML compile, etc. |

---

## 1. Architecture Overview → [Level 3](01-architecture.en.md)

Four lifelines inside the process:

1. **Main thread**: SwiftUI rendering + state write-back (`@Observable DriveState`)
2. **tick queue** (`com.aurora.tick`, 30Hz DispatchSource): `state.tick()` drives capture → inference → keys
3. **Localization queue** (`com.aurora.netlocate`, 10Hz): `runNetworkLocateStep()`
4. **Capture thread** (`com.aurora.coordinate-capture`): blocking `pcap_next_ex` loop

Six App Nap countermeasures (see Internals) keep tick at 30Hz even when the game covers the window. The 4-tier degrade ladder (e2e/yolo/recover/rule) is driven by `DegradeStateMachine` with thresholds: degrade 0.65 / recover 0.80 (hysteresis 0.15) / stuck 3km/h×3s / recovery timeout 30s.

## 2. Network Localization → [Level 3](02-network-locate.en.md)

- **BPF permissions**: in-app password sheet → osascript → `com.aurora.bpf-setup` LaunchDaemon auto-runs `chmod 666 /dev/bpf*` at every boot
- **Capture**: `pcap_findalldevs` enumerates NICs (skipping lo/utun virtuals) → filter `tcp port 30031 or udp` (MaaNTE-aligned; UE5 movement sync may ride UDP) → `pcap_next_ex` loop
- **Decoding**: strip 3 headers → allow c2s only → UE5 bitstream scan → world coordinates + heading → affine map to the 13056×13056 map (map-2026-08, upgraded 2026-09-13)
- **Current localization**: `runNetworkLocateStep()` (10Hz) lazily inits `CoordinateCapture` + `read(maxAge:1.0)` direct link, no self-healing engine (original NetworkHealer removed in 76e9027)
- **Live/dead clarification**: NetworkLocator (WebSocket) compiles but is never instantiated; NetworkPacketCapture moved to legacy/, not compiled; VisualLocator's NCC engine is wired up but idle

## 3. Speed Recognition → [Level 3](03-speed-ocr.en.md)

**Dual engine** (2026-09-19 update): a fine-tuned PP-OCRv6 whole-line model (`ppocrv6_tiny_ft_int8.mlpackage`, int8, GPU inference) is the primary path, backed by a per-digit CNN (`speed_digit_cnn_v4*`); the legacy glyph-template engine has been removed (archive in dev/en/03-speed-ocr.en.md).

Model loading must call `MLModel.compileModel(at:)` first — newer macOS no longer implicitly compiles `.mlpackage`. Three validation layers: range 0–400 → jump ≤60 km/h → 3-frame vote in a 1s window (tolerance ±2).

## 4. Vision & Inference → [Level 3](04-vision-inference.en.md)

- CaptureEngine: ScreenCaptureKit 30fps BGRA; every frame fans out to 4 callbacks (UI / YOLO / MetalFX / native ROI)
- InferenceEngine: m9_mono, input `image[1,3,180,320]` + `vehicle_state[1,6]` (v2_new contract), outputs steer/throttle/brake
- YoloEngine: yolo26s, inputSize 640, confidence threshold 0.22, inferFast zero-copy fast path, CocoLabels 80→4 class mapping
- ConfidenceEstimator: consistency 0.5 + extremity 0.3 + brightness 0.2 estimate E2E confidence (isLive gating zeroes it)
- RecordEngine: dual-mode recording (raw_clips 640×360 + controls.csv, glyph_clips ROI PNGs)
- MetalFX: display overlay only (architecture red line)
- AutomationPanel: 9 automation buttons are UI placeholders only

## 5. Control & Safety → [Level 3](05-control-safety.en.md)

- ControlEngine: `CGEventSource(.hidSystemState)` (the game only reads HID-level events) + `.cghidEventTap` injection; keycodes W13/S1/A0/D2/Space49/Shift56
- KeyboardMonitor: global physical-key listener (display only, **not** an emergency stop)
- RuleController: YOLO detections → decision table (cruise 0.8 throttle / urgency>0.55 hard brake / >0.25 slow down)
- EscapeController: reverse 1.5s → turn 0.8s → forward 2.0s loop, 15s timeout, success at >8km/h
- Emergency stop: `stopDriving()` → `releaseAll()` + `forceRule` one-key rule mode

## 6. FAQ

**Q1: "CNN model and glyphs not loaded" on startup?**
The CNN model failed to load. Check that `models/speed_digit_cnn_v4.mlpackage` exists; the code already uses `MLModel.compileModel(at:)` before loading. If it still fails, open an issue with `/tmp/aurora_pcap.log` attached.

**Q2: Network localization never works?**
Check BPF permissions first: `ls -l /dev/bpf0` should be `crw-rw-rw-`. Otherwise run the in-app BPF installer, or manually `sudo chmod 666 /dev/bpf*` (note it resets on reboot — the in-app installer is the durable fix).

**Q3: Map position is off?**
Lobby/loading screens carry no movement packets — that's normal and recovers once driving. For a persistent offset, verify calibration against known landmarks (see internals/coordinate-calibration).

**Q4: Speed readout occasionally jumps?**
Single-frame misreads are caught by the three validation layers: jumps >60 km/h zero the confidence and trigger degrade; a 3-frame vote in a 1s window (tolerance ±2) must pass before output.

**Q5: Build error "ObservableMacro could not be found"?**
Xcode macro-plugin issue (common with Chinese-path / external-disk Xcode). Build with full permissions, or install Xcode under `/Applications`.

**Q6: What are `speed_digit_cnn` (no v4) and `speed_templates.json` in models/?**
Leftovers from the early CNN v1 / old template pipeline. Current code references neither (SpeedOCRReader loads only `speed_glyphs.json` and v4) — safe to ignore.

---

## 7. 2026-09-19 Disk Cleanup Note

On 2026-09-19 a disk cleanup was performed: the paths below have been **removed from this machine** and migrated to the external drive at
`/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/`.

> ### ⚠️ Path corrected on 2026-09-29
>
> The path previously written here was `/Volumes/代码项目/删除_20260919/自动驾驶系统清理/` —
> **that path does not exist** (`ls` returns *No such file or directory*).
>
> The real location is **two directory levels deeper**, nested inside the
> 「自动驾驶项目半成品版本1.0到10.0」 (early-version archive) folder:
> ```
> /Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/
> ```
>
> **Verified**: that archive holds **22 GB across 9 subdirectories**, matching the
> migration list below one-for-one (`web_frames` / `template_scratch` / `build_contact` /
> `ocr_batch` / `ocr_batch2` / `gray_cache` / `videos` / `build_cache` / `ppocrv6_finetune_output`).
>
> **Following the old path fails with "No such file", which can easily be misread as
> "the data is lost" — in fact all 22 GB is intact.** The Chinese guide had the same
> error and has been corrected too.

Any document still citing these old paths must be read as pointing to the migrated location:

| Former local path | Content |
|---|---|
| `data/web_frames` | 19G, 22741 frames of web video stills |
| `build/vid_*.mp4` | 14 mining videos |
| `build/template_scratch` | template-mining scratch area |
| `build/contact` | contact-detection intermediates |
| `build/ocr_batch(2)` | OCR batch-test intermediates |
| `data/_gray_cache` | 263 grayscale 1280×803 crops (rebuild required before re-running `tools/audit2.py`) |
| `tools/ppocrv6_finetune/output` | PPOCRv6 fine-tune outputs |
| `.build` | build cache |

Data kept locally: `build/new_templates` (291 entries, 268 png final templates incl. the `_rejected` subdirectory), `build/dig_*.json` (52 mining evidence files), `build/maa_pipeline_override.json` (full 250-node override), `data/mac_shots` (208 in-game screenshots).

MaaNTE side status (details: `docs/文档库/Maa深度/MaaNTE移植对照表.md`, `docs/文档库/Maa深度/ROI反推规则.md`, `docs/文档库/探索文档/界面采集作业指令.md`):

- 250 ROI-node overrides generated (181 rule-based + 32 exact back-derivation, +83 offset rule), shipped in `build/maa_pipeline_override.json`
- 24 nodes still missing templates, to be captured on the live game (win/lose loading screens, shop page, cursor; the `'%'` in SceneLoadingType2 and Sync×6 are suspected placeholder/bad upstream definitions and may be skipped)
- Coordinate system fixed at 1470×923 (not resizable); runtime long side scales to 1280 (screenshots 1280×803); OCR must run on GPU; key input goes through ControlEngine CGEvents; click the game window on startup, press T to drive; Maa is used as a tool only — it does not take over the project
- BidKing (auction) PR#434 code has been extracted to a standalone folder `BidKing_PR434/` (git 7b7d2db, not merged into mainline)
