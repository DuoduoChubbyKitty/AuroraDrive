# 4. Vision & Inference

> Sources: `CaptureEngine.swift`(639) `InferenceEngine.swift`(432) `YoloEngine.swift`(807) `ConfidenceEstimator.swift`(248) `RecordEngine.swift`(424) `Vendor/MetalGoose/`
> Up: [Developer Guide](DEVELOPER_GUIDE.en.md) ｜ 中文: [视觉与推理子系统](../自动驾驶与功能/04-vision-inference.md)

> **Archive note (verified 2026-09-19, baseline 7b7d2db)**: all sections check out against current code; only line counts / the base map were corrected (InferenceEngine 432 / YoloEngine 807 / RecordEngine 424; the big map was upgraded to 13056×13056 map-2026-08 extended version on 2026-09-13). For the speed-OCR dual-model details see Level-3 doc 3 (3.7 is the glyph-removal archive).

## 4.1 Screen capture (CaptureEngine)

- **Engine**: ScreenCaptureKit (SCStream), `32BGRA` frames, queue depth 3, **30 fps cap**
- **Permission**: Screen Recording; `SCShareableContent.current` triggers the system prompt, denial → `.permissionDenied`
- **Speedometer ROI**: `speedROINorm = CGRect(x:0.455, y:0.885, w:0.080, h:0.050)` — defines the crop region for speed recognition

**Frame fan-out**: every frame is dispatched from the capture queue to 4 callbacks (the "keep only the latest frame" pendingFrame buffering lives in `AuroraDriveApp.swift` (DriveState), not in CaptureEngine; the YOLO-direct / ROI callbacks go through self-owned buffer pools decoupled from the SCStream lifecycle):

| Callback | Consumer |
|---|---|
| `onFrame` | UI main view |
| `onYoloFrame` | YOLO inference |
| `onUpscaleFrame` | MetalGoose display |
| `onNativeFrame` | speed OCR (Ring-1 copies only the ROI, ≈100KB) |

> The "keep only the latest frame" pendingFrame buffering lives in `AuroraDriveApp.swift` (DriveState), not in CaptureEngine.

## 4.2 E2E driving model (InferenceEngine)

- **Model**: `m9_mono` (default); `assistEngine` uses `game_assist_control`. Loading prefers `.mlmodelc` → falls back to `.mlpackage`
- **Inputs**: `image` `[1,3,180,320]` (CHW, /255) + `vehicle_state` `[1,6]` filled per the v2_new contract `[speed_norm, curv*5=0, sin=0, cos=1, limit_norm, 0]` — the 11-dim legacy contract in the header comment is obsolete
- **Outputs**: `steer` / `throttle` / `brake` scalars, read via `readScalar` from `MLMultiArray[1,1]` element `[0,0]`
- **Signature**: `infer(image: CGImage, speedKmh: Double, speedLimitKmh: Double)`

## 4.3 YOLO detection (YoloEngine)

- **Model**: `yolo26s.mlmodelc` preferred → `.mlpackage` fallback; `inputSize = 640`
- **Two inference paths**:
  - `infer(image:)`: CGImage → `draw()` stretched into 640×640 BGRA (slow path)
  - `inferFast(pixelBuffer:)`: zero-copy memcpy of an already-scaled 640 BGRA buffer (fast path)
- **Parsing**: rows of `[x1,y1,x2,y2,conf,cls]` normalized by /640
- **Confidence threshold**: `0.22`
- **CocoLabels**: COCO-80 mapped to 4 business labels — person[0]→`pedestrian`, vehicle[1..8]→`car`, sign[9,11,12]→`sign`, rest→`obstacle`

## 4.4 E2E confidence estimate (ConfidenceEstimator)

The E2E model has no confidence head; three heuristic signals are weighted into a [0,1] score for the degrade state machine:

| Signal | Weight | Computation |
|---|---|---|
| Output consistency | 0.5 | steer std → `1 - std×2` |
| Steering extremity | 0.3 | share of frames with `\|steer\|>0.95` |
| Frame validity | 0.2 | `CIAreaAverage` brightness, valid window [0.08, 0.95] |

- `update(command:image:isLive:)` gates on **isLive** first: a dead link zeroes the score (fixed the "dead model scored 0.70 and never degraded" bug)
- Long-window penalty: >70% saturation over 90 frames (3s@30Hz) caps confidence at `min(conf, 0.30)`
- Brightness is computed on a background queue (`com.aurora.confidence.brightness`)

## 4.5 Recording engine (RecordEngine) — the source of training data

**Standard recording** (`start(perspective:)`) writes to `data/raw_clips/clip_<timestamp>/`:
- `frames/%06d.jpg` (640×360)
- `controls.csv` (header `t_sec,frame,steer,throttle,brake`, frame-aligned with key monitoring)
- `meta.json` + `view.txt` (FPV/TPV)

**Glyph mode** (`glyphMode`): records only the native `speedROINorm` ROI as PNGs into `data/glyph_clips/` — the data source for regenerating the glyph library (the glyph path was removed; the frame data was already lost, see Level-3 doc 3.7 archive).

**Backpressure**: `maxPendingWrites = 1` — drops frames instead of piling up when disk writes lag.

**Disk guardrail**: at recording start the oldest directory is deleted (`raw_clips` and `glyph_clips` share the same cap, preventing unbounded accumulation of 640×360 JPEG at 30fps).

## 4.6 MetalFX display enhancement (Vendor/MetalGoose)

Upstream: <https://github.com/Stallion77RepoOfficial/MetalGoose> (GPL-3.0). MGUP-1 Spatial upscaling in three quality tiers + frame interpolation, presented in a borderless overlay.

**Architecture red line**:

```
capture(native frames) → inference → keys   ← decision path; MetalFX never enters
        ↓
   MetalFX upscale/interpolate → overlay    ← human eyes only
```

## 4.7 Collection map (GameMapView)

Base layer: `bigworldmap-13056.jpg` (**13056×13056, MaaNTE asset, map-2026-08 extended version, upgraded 2026-09-13**; the old 11264×11264 `bigworldmapSecond.png` remains in models/ as a fallback candidate); markers: `FINAL_complete_map_database.json` (nteguide data). Toggleable layers (teleports/materials/chests/essences), pinch-zoom & pan, live player overlay. Works with `MinimapTileCache` (8×8 tile cache — see Level-3 doc 2 for the two-minimap landscape).
