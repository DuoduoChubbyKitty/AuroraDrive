# 4. Vision & Inference

> Sources: `CaptureEngine.swift`(639) `InferenceEngine.swift`(432) `YoloEngine.swift`(807) `ConfidenceEstimator.swift`(248) `RecordEngine.swift`(424) `YolopxEngine.swift` `OpticalFlowBridge.swift` `MotionPredictor.swift` `FallbackGuard.swift` `Vendor/MetalGoose/` `Vendor/OpenCVFlow/`
> Up: [Developer Guide](DEVELOPER_GUIDE.en.md) ｜ 中文: [视觉与推理子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/04-vision-inference.md)

> **Archive note (verified 2026-09-19, baseline 7b7d2db)**: all sections check out against current code; only line counts / the base map were corrected (InferenceEngine 432 / YoloEngine 807 / RecordEngine 424; the big map was upgraded to 13056×13056 map-2026-08 extended version on 2026-09-13). For the speed-OCR dual-model details see Level-3 doc 3 (3.7 is the glyph-removal archive).
>
> **Archive note (added 2026-09-27)**: sections 4.8 (YOLOPX tri-head perception) and 4.9
> (optical flow + motion prediction) are new. They predate this file's 4.1–4.7 baseline and
> had not been documented here. Full delivery notes (measurements / production config /
> 13 pitfalls) live in the Chinese-only
> [探索文档/光流-运动预测-兜底-交付说明.md](../探索文档/光流-运动预测-兜底-交付说明.md).

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


## 4.8 YOLOPX tri-head perception (YolopxEngine)

> ⚠️ **Core asset — the model files must not change by a single byte.** The client's
> investment is built around YOLOPX; swapping the model means the project is dissolved.
> Everything in this section and 4.9 only wraps around it.

- **Model**: `models/yolopx/yolopx3_pal8_detfp.mlmodelc` (first candidate, falls back down the list)
- **Scale**: 33.03M params / 148.11 GFLOPs; `inputSize = 640` (own letterbox, does not reuse YoloEngine's stretched fast path)
- **Three outputs**: `det` (YOLOX detection, nc=1 car only) / `da` (drivable area) / `ll` (lane lines)
- **Masks**: downsampled to a `maskGridSize = 160` `MaskGrid` (saves 1.0–2.4 ms, mathematically equivalent)
- **Measured**: `pal8_detfp` 62.15 ms min / 66.86 ms med → **15.0 Hz**; `w8a16` 15.1 Hz; `int8` 12.6 Hz
- **Physical floor**: 148.11 GFLOPs ÷ 9.26 TFLOPS (measured ANE peak) = **16.0 ms**; a 10 ms whole-net pass would need 14.81 TFLOPS (~160% of peak — physically impossible)
- **Degradation**: `isDegraded` starts true (nothing is trusted until the model runs); `loadAttemptLog` records each candidate attempt
- **Re-entrancy guard**: `isInferencing` flag + dedicated serial queue `com.aurora.yolopx`

> ⚠️ Optimizations already measured and rejected (do not retry): quantization
> (w8 no gain / w4 ll IoU 0.7808 / w8a8 ll IoU 0.4395 / a8 93.58 ms),
> stem stride change (74.37 ms, slower), disabling decode (no change),
> baking normalization into convolution (58.18 ms, no gain).

### 4.8.1 Mask validity: **two-sided** thresholds (lower *and* upper bound) — added 2026-09-27 (t47)

> Section 4.8 above covers the model and its performance but **not the mask decision thresholds**.
> Added here: this is the core defence for seg-head trustworthiness, and it involved a
> publicly recorded self-correction.

**Constants** (`YolopxEngine.swift:202–254`):

| Constant | Value | Meaning |
|---|---|---|
| `lanePositiveFloor` | **0.002** | Lane-line positive-pixel ratio lower bound (below → head failed) |
| `drivablePositiveFloor` | **0.02** | Drivable-area lower bound |
| `lanePositiveCeil` | **0.25** | Lane-line **upper** bound (above → abnormal inflation) |
| `drivablePositiveCeil` | **0.70** | Drivable-area **upper** bound |

**Why an upper bound is needed** (source comment, lines 209–215):
> The original check had **only a lower bound**. Measured (t31 §3.1 foreground-ratio sweep):
> ll foreground went from 1.70% all the way up to **38.89%** (= 10× the real ceiling),
> yet `isDegraded` stayed **false the whole time**, `LaneFallback` kept giving advice and
> `confidence` reached 1.00. Large-area foreground is one of the most typical failure
> modes of a seg head … a mask that is "lane lines everywhere" yields seemingly valid
> advice (steer=±0.25, conf=1.00) that **downstream cannot detect**.

**★ Self-correction record (source lines 219–228 — keep this):**
> ⚠️ 2026-09-27 self-correction: v1 set the ll ceiling to **0.10**, based on t31's reported
> "real ll is only 1.3–3.9%". Then I measured the real distribution with pal8_detfp on
> **169 real driving images** (`data/validation_clips`, 8 condition classes) and found that
> value **would be triggered by genuine frames**:
> ```
> ll coverage  min=0.0000 P05=0.0002 P50=0.0266 P95=0.0694 max=0.1072
> da coverage  min=0.0000 P05=0.0102 P50=0.1159 P95=0.3237 max=0.3812
> ```
> A 0.10 ceiling falsely flags degradation during real driving → the fallback goes silent
> (fail-open is the safe direction, but this is a **pointless functional failure**).
> So ll was raised to 0.25 and da to 0.70.
> **Lesson**: t31's 1.3–3.9% was based on a small sample from the t30 era; using its ceiling
> as the threshold means treating a *sample* maximum as a *population* maximum.
> **Thresholds must come from a full current-batch measurement.**

**v2 values**:
- ll ceiling 0.25 = **2.33×** the real max (0.1072) — all 169/169 real frames pass
- da ceiling 0.70 = **1.84×** the real max (0.3812)

**⚠️ Honest limitations (source lines 237–246 — do not delete):**
1. This is a **margin method** (real ceiling × safety factor), **not** quantile calibration —
   the available material is insufficient to fix quantiles
2. **Uncovered range**: ll 10.7%–25% and da 38.1%–70% are still accepted. **This is a known gap, not "solved"**
3. The chosen direction is deliberately conservative: a loose ceiling only misses some collapses,
   a tight one causes false degradation
4. Once real "seg-head collapse" material exists, re-calibrate by quantile (accuracy-track task)

**★ Complement to the "Degradation" bullet in 4.8**: `isDegraded` is not only "the model has not
loaded yet" (initially true) — at runtime it is driven by the **two-sided** check: below the floor
(collapse) or above the ceiling (inflation) both flag degradation.

## 4.9 Optical flow + motion prediction (OpticalFlowBridge / MotionPredictor / FallbackGuard)

**Problem**: YOLOPX runs at ~15 Hz while the main loop runs at 30 Hz. If each frame simply
reads "the most recent detection result", boxes are **completely static** between two
inferences — targets move, boxes do not, and the decision layer drives on stale positions.

**Solution**: optical flow estimates inter-frame motion → an α-β filter maintains each
target's (position, velocity) → truth corrects, absence extrapolates. This fills 15 Hz
truth up to 30 Hz.

### 4.9.1 Optical flow (`Vendor/OpenCVFlow` + `OpticalFlowBridge.swift`)

- **Algorithm**: OpenCV `cv::DISOpticalFlow` **PRESET_ULTRAFAST** (Dense Inverse Search,
  a **CVPR 2016** algorithm, built into OpenCV's official `video` module — **not hand-rolled**)
- **Why not Apple's built-in** (hard requirement ≤5 ms; same-batch 640×640 measurements):

  | Approach | p95 | Verdict |
  |---|---|---|
  | Apple `VTOpticalFlow` (VideoToolbox hardware) | 10.28 ms | ✗ |
  | Vision `VNGenerateOpticalFlow` | 27.43 ms | ✗ |
  | **OpenCV DIS ULTRAFAST** | **1.91 ms** | ✓ |

- **Production config (two tuned knobs — do not change)**:
  1. **4:1 sampling for the median** (`kMedianSampleStep`): full-density p99 was 5.32 ms,
     right at the limit → sampled p95 becomes 1.91 ms. Driving flow fields are highly
     smooth, so the median is insensitive to sampling
  2. **`setNumThreads(2)`** (`kOpenCVThreads`): more threads ≠ faster. Default (all cores)
     hit p95 20.9 ms under 7-way load; fixed 2 threads gives 3.53 ms
- **Accuracy**: 0.07 px on synthetic; 0.12–0.33 px on **real driving texture** (limit 0.5 px)
- **No phantom motion on static scenes**: a stationary recording yields dx=0.000 (correct — it invents nothing)
- **Interface**: pure C (`ad_dis_create/destroy/compute`) returning only an "ego-motion summary"
  (dx/dy/divergence), never the dense flow field (3.3 MB of cross-language copying would cost
  more than the computation itself)
- **Thread safety**: `ad_dis_compute` is **not** thread-safe; one ctx must not be called
  concurrently. The Swift side serializes with a private lock
- **fail-open**: failures always return `valid=0`, never throw or crash; callers degrade to "no prediction"

### 4.9.2 Motion prediction (`MotionPredictor.swift`)

- **Filter**: α-β (the closed-form Kalman solution for a constant-velocity model with steady-state gain). α=0.55 / β=0.25
- **Velocity is normalized-coordinate per second**, so frame-rate changes need no parameter edits
- **Association**: greedy IoU matching, threshold 0.25
- **Extrapolation gate**: velocity must be consistent for 3 consecutive frames (prevents single-frame jitter from inventing motion)
- **Hard clamp**: per-frame extrapolation step ≤0.15 (15% of the view) so a diverging filter cannot fling boxes off-screen
- **Timeouts**: stop extrapolating after 10 frames without truth; drop the target after 30
- **Frame-driven semantics**: **`predict` is called exactly once per tick** — it means "time advanced one frame";
  `ingest` only corrects, it does not keep time. `missedFrames` increments inside `predict`
  (the first version incremented it in `ingest`, which made extrapolation never fire)
- **Measured**: 0.0009 position error after 3 extrapolated frames (threshold 0.03)

### 4.9.3 Dual-structure geometric fallback (`FallbackGuard.swift`)

Two purely geometric criteria, independent of model confidence:

- **Structure A — ego/lead position**: the **largest-area** box inside the image centre band
  (`egoCenterHalfWidth=0.25`). Area is a monotonic proxy for distance and the centre band
  gates lateral offset — together they mean "the nearest obstacle straight ahead"
- **Structure B — box overlap = collision**: IoU ≥0.15 **or** centre distance ≤0.06 → overlap
  → emergency avoidance (centre distance covers IoU's blind spot: a large box containing a
  small one can have low IoU yet be equally dangerous)

**Two key differences from `LaneFallback`**:

1. **Not gated on `decided` state** — collision is a hard safety constraint, not a driving
   style for some state. No matter how healthy the primary model is, two overlapping boxes
   ahead must brake
2. **Keeps working while degraded** — it depends only on detection boxes, not masks. Mask
   degradation often means "the model is half-broken", which is exactly when geometric
   fallback matters most (the opposite direction from LaneFallback's fail-open)

**False-positive protection lives inside the class**: 3-frame confirmation + geometric
validity checks (out-of-range data discarded) + conservative output (throttle capped at 0.2,
steer clamped to ±0.25).

### 4.9.4 Wiring (inside the tick)

```
CaptureEngine fast-path frame (640x640 BGRA)
       |
       +--> runOpticalFlow() --> gray --> DIS --> (dx, dy, divergence)
       |        WARNING: must run synchronously at the frame consumption point.
       |        The fast-path buffer is pooled private memory; holding it across
       |        steps is a use-after-recycle hazard.
       v
YOLOPX / yolo26s truth --> MotionPredictor.ingest()
                                |
                    predict(dt) <- exactly once per tick
                                |
                    predictorDetections (per-tick cached snapshot)
                                |
                    +--> effectiveDetections (decision layer)
                    +--> FallbackGuard --> advice() --> applyLaneAdvice (step 5.5)
```

- WARNING: `effectiveDetections` **only reads the cache** and must not call `predict()` itself —
  that property is read multiple times per tick, which would advance the frame counter
  repeatedly and corrupt the velocity estimate
- Truth source: YOLOPX first, falling back to yolo26s

### 4.9.5 Self-tests

```bash
./AuroraDriveUI --opticalflow-selftest   # C-layer availability / displacement accuracy / latency limit / degraded paths
./AuroraDriveUI --motion-selftest        # extrapolation accuracy / fail-open / dual-structure criteria
./AuroraDriveUI --yolopx-selftest        # model accuracy has not regressed
```

All three pass with **zero failures**. Extreme-load boundary (recorded honestly — do not misread):

| Scenario | p95 | Verdict |
|---|---|---|
| Idle | 1.7 ms | ✓ |
| 7-way load @ **UTILITY** (game/background — this is production) | 3.7 ms | ✓ |
| 7-way load @ **same priority as the flow** (saturating all 8 cores) | ~9 ms | ✗ |

The production tick is driven by `DispatchQueue(qos: .userInteractive)` and the game runs at
normal priority, so it falls in the second row. The third row does not occur in reality
(with 7 saturated userInteractive threads the app's 30 Hz would fail first). The self-test
explicitly raises its thread priority (`elevateCurrentThreadPriority()`), otherwise it
measures a false overrun.

> **Status (2026-09-27)**: implemented and self-test clean, **not yet driven on real hardware**.
> Optical flow currently runs only while the YOLO fast path is active; if the fast path fails
> it degrades to "no prediction" (fail-open — no error, one layer less).
