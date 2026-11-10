# SEC-09 — INFERENCE / PERCEPTION

Sources: `Sources/AuroraDrive/Inference` — **15 files / 14,706 lines**; `Sources/AuroraDrive/Perception`
— **3 files / 620 lines** (measured `wc -l`). Read headers of all 18 and key contracts.

| file | lines | role |
|---|---|---|
| `InferenceEngineV2.swift` | 3820 | M9-V2 multi-input end-to-end |
| `SpeedOCRReader.swift` | 1924 | speedometer OCR (PP-OCRv6 + CNN fallback) |
| `YolopxEngine.swift` | 1814 | YOLOPX three-in-one perception |
| `QuestPanelReader.swift` | 1160 | quest panel OCR → world coords |
| `PointerHeadingReader.swift` | 1027 | minimap arrow → body heading |
| `YoloEngine.swift` | 918 | yolo26s detection |
| `RoadCornerGuide.swift` | 757 | corner waypoint set runtime query |
| `MotionPredictor.swift` | 575 | α-β extrapolation 15→30 Hz |
| `InferenceEngine.swift` | 522 | legacy m9_mono engine |
| `LaneFallback.swift` | 461 | lane/drivable-area fallback决策 |
| `EgoMotionModel.swift` | 399 | ego radial motion from flow |
| `OpticalFlowBridge.swift` | 384 | OpenCV DIS dense flow |
| `RoadMapPrior.swift` | 360 | 2048² road-network bitmap prior |
| `ConfidenceEstimator.swift` | 357 | E2E confidence heuristic |
| `LaneKeepRealityTest.swift` | 228 | real-material lane-keep measurement |
| `Perception/LaneExtrapolator.swift` | 348 | lane flow extrapolation |
| `Perception/LaneBridge.swift` | 178 | lane mask bridge + validity |
| `Perception/LaneExtrapolatorSelfTest.swift` | 94 | its selftest |

## 9.1 YOLOPX — the core perception asset

`YolopxEngine.swift:5-31`.
Model: `models/yolopx/yolopx3_pal8_detfp.mlmodelc` (first candidate, 8-bit palette, det precision 100 %);
candidates listed in `modelCandidates`, each probe-loaded and the next tried on failure (`:8-10`).
Exported by `tools/yolopx/export_yolopx_coreml.py`, parity-verified by
`tools/yolopx/verify_yolopx_coreml.py` (`:10-11`).

Measured output shapes (`:13-16`):
```
det  [1, 8400, 6]      cx, cy, w, h, obj_conf, cls_conf   (640-input pixel coords, NOT NMS'd)
da   [1, 2, 640, 640]  drivable-area binary logits
ll   [1, 2, 640, 640]  lane-line binary logits
```

**Three differences from `YoloEngine`(yolo26s) where any mistake fails silently** (`:18-27`):
1. Input is **letterbox** (aspect-preserving scale + 114 grey padding), **not** whole-frame stretch.
   The model was trained on BDD100K with letterbox; feeding a stretched image changes object aspect
   ratios and distorts **both** boxes and masks.
2. The `det` head is YOLOX (anchor-free) and **output is not NMS'd**; coordinates are `(cx,cy,w,h)`.
   yolo26s is NMS-free end-to-end and directly emits `(x1,y1,x2,y2)`, so this engine must do its own
   coordinate transform + NMS + grey-padding box rejection.
3. `nc = 1` — only the "car" class, all mapped to `Detection.Label.car`.

Coexistence guarantee (`:29-31`): this engine loads independently with independent buffers, does not touch
the incumbent detection chain, and can be disabled to roll back with zero impact.

Mask downsampling rationale (start of `MaskGrid` section, `:38+`): the raw `da`/`ll` output is a
640×640×2 fp16 tensor; moving 1.6 MB per frame is wasteful, so it is downsampled to a 160×160 grid by
`gridStride` before storage — the same grid dimension that appears in the shared-memory mask area
(SEC-03 §3.11).

Frequency by tier (cross-reference, `README.md:111`): in `ayolom` tier this runs every tick; in `legacy`
tier every even frame. `UNVERIFIED:` the exact gating line inside `YolopxEngine`/`DriveState` for that
split was not re-read this session; the tier-mapping functions themselves are pinned at
`EngineMain.swift:868-885`.

## 9.2 yolo26s — a different contract, easy to confuse with YOLOPX

`YoloEngine.swift:5-25`. Model `models/yolo26s.mlmodelc` (YOLOv26s, **NMS-free end-to-end**), exported by
Ultralytics with automatic `colorSpace=RGB`.
- input `image`: 640×640 `CVPixelBuffer`, colorSpace RGB — the app feeds 32BGRA and CoreML extracts R/G/B
  in RGB order automatically, no manual channel swap (`:12-14`).
- output `[1, maxDet, 6]` Float32, each row `[x1, y1, x2, y2, conf, class_id]`, coordinates in pixels
  relative to the 640 input; Swift `parse()` divides by 640 to normalise (`:15-17`).
- because it is NMS-free with no anchors, dedup happens inside the model; Swift only does confidence
  filter + descending sort + truncation + class mapping (`:19-21`).
- **preprocessing is whole-frame non-proportional stretch to 640×640 (no letterbox)**, matching training,
  so pixel/640 is exactly whole-frame normalised coordinates (`:23-25`).

This is the exact opposite of §9.1 item 1: swapping preprocessors between the two engines would produce
plausible-looking but wrong boxes and masks.

## 9.3 M9-V2 — multi-input end-to-end

`InferenceEngineV2.swift:4-42`. Why a new file instead of editing `InferenceEngine.swift`: the original
runs `m9_mono` (2 inputs: image + `vehicle_state[6]`) and is the chain **currently driving**; the new model
is 5 inputs with 8-dim state — a structural change. Editing in place would turn "roll back to the old
model" into a large refactor, so the new engine is a separate file behind a switch and the old file is
untouched (`:6-11`).

Authoritative contract source (`:13-17`): `src/model_v2.py` (M2Model forward signature and branch encoders)
and `tools/export_m9_v2_coreml.py` (**the script that actually produces the CoreML**, containing 8 measured
pitfalls). **When the two disagree, the export script wins**, because it decides what lands on disk
(`:17`).

Input/output table (`:19-30`):
```
image         [1,3,180,320]  f32  third-person screenshot CHW in [0,1]
lane          [1,1,160,160]  f32  lane mask binary 0/1
dets          [1,20,12]      f32  detection boxes in fixed slots, empty slots zero-padded
det_mask      [1,20]         f32  1=valid box, 0=empty slot
vehicle_state [1,8]          f32  vehicle state
steer         [1,1]          f32  tanh    ∈ [-1,1]
throttle      [1,1]          f32  sigmoid ∈ [0,1]
brake         [1,1]          f32  sigmoid ∈ [0,1]
```

**The two naming traps**, both quoted with evidence:
1. **The input name is `lane`, NOT `lane_mask`** (`:32-39`). `src/model_v2.py`'s forward *parameter* is
   `lane_mask`, but the exported CoreML *feature name* is `lane`. The verbatim runtime error is recorded:
   `KeyError: Provided key "state" ... does not match any of the model input name(s), which are:
   {'dets','det_mask','lane','state_workaround','image'}`. Looking up by parameter name raises `KeyError`
   at runtime. The file therefore drives everything from a single `V2InputContract.featureName` constant
   table to make this class of mismatch impossible.
2. **An input name must never be `state`** (`:41-42`): coremltools 8.3 **silently renames** it to
   `state_workaround` because `state` collides with a MIL reserved word, and the failure surfaces at
   inference time, not conversion time.

## 9.4 Speed OCR — dual model, three layers, honest degradation

`SpeedOCRReader.swift:4-30`. Architecture (2026-09 dual-model rework; template matching removed):
- **primary**: PP-OCRv6 full-line inference — ROI slice → grey → bilinear to 48×136 → replicate to 3
  channels → CTC decode → take the last 3 digits → confidence threshold (`:6-8`);
- **fallback**: per-digit CNN (`speed_digit_cnn_v4`) — `cropSlots` cuts 3 slots → each 90×50 → softmax per
  digit (`:9-10`);
- **switching rule** (`:11-14`): only a system-level runtime fault (inference throw / missing output)
  degrades to CNN **within the same frame** and writes `engineNotice` (orange banner in UI + orange engine
  label beside the speed). "Can't read" business diagnostics (low foreground / low confidence / short digit
  string) are **not** treated as faults and do not trigger switching. Both models failing to load writes
  `errorMessage`/`engineNotice` at `init` — never silent.
- history (`:15-17`): the earlier glyph-template matching (`speed_glyphs.json` + 0–300 enumeration
  residual) was fully replaced and deleted; `cropSlots` slot constants are still used by the CNN path.

Why the primary path is a finetuned PP-OCRv6 full-line model (`:19-25`), with the comparative reasoning
recorded:
- generic Vision OCR has a high misread rate on the HUD's hollow digits (`"000"` → `"NTO0U"`);
- a self-trained per-digit CNN reaching 99.98 % is an **in-distribution** result and may collapse when
  resolution/game/UI change;
- the finetuned PP-OCRv6 = official general pretraining representation + project-scene alignment;
  frozen test set (5077 images from unseen clips) **99.9803 %**; strongest generalisation
  (report referenced as `PPOCRV6_FINETUNE_REPORT.md`).

Threading (`:27-30`): `infer()` is entered on main → inference on a background `ocrQueue` → a
`Task @MainActor` applies `applyEngineUse()` (engine state) and `finish()` writes the latest snapshot; a
`generation` counter prevents in-flight results from landing after `reset()`.

Invalid-frame pre-check (`:32-35`): loading/view-misaligned frames contain no speedometer; an
Otsu-foreground ratio below threshold marks the frame invalid and it never enters inference (preventing
garbage output); the PP-OCR side additionally has a confidence threshold and digit-string-length rule.
Three-layer validation is cited at `README.md:49` as `SpeedOCRReader.swift:638-653`
(Layer 1 range / Layer 2 jump / Layer 3 multi-frame confirmation) — `UNVERIFIED:` those exact lines were
not re-read this session.

## 9.5 Minimap arrow heading — the body-heading source

`PointerHeadingReader.swift:4-30`. **Why it exists** (`:5-10`): network locate
(`CoordinateCapture` / MaaNTE `nte_coordinate_api`) yields UE5 **ControlRotation** — the camera/view
heading. In third person the camera rotates independently, so **view heading ≠ body heading**, and
road-network following would use the wrong direction. This file reads the arrow on the minimap, which
represents **body heading** (cross-validated against in-game world-coordinate trajectories).

Model (`:12-18`):
```
models/tiny_arrow_v2.mlmodelc
  self-trained; training data = arrow sprites cut from real frames, programmatically
  rotated 0–360° and composited onto real minimap backgrounds, 20000 synthetic images
  generated at /tmp (label accuracy 0°, not human annotation)
  size 44 KB / 11962 params / input 64×64
  contract: image [1,3,64,64] Float32 (RGB, normalised to [-1,1])
            → heading_sincos [1,2] Float32 = (sinθ, cosθ)
  measured: val angle error p50 0.56° / p95 1.81°; 180° flip rate 0.0%;
            CPU_ONLY single-frame p50 0.087 ms; CoreML vs PyTorch max diff 0.272°
```

**θ₀ = 332.0°** (`:20-26`): the model learns "rotation relative to the sprite's native orientation", not an
absolute compass angle, so `true compass angle = model output + θ₀`. θ₀ was calibrated **objectively**
using in-game world-coordinate trajectories — the video's top-left corner permanently displays XYZ
readouts that can be read frame by frame. Compass angle is defined as `atan2(ΔX, −ΔY)` (i.e. +X = east,
+Y = south, compatible with UE5's left-handed X-forward/Y-right). Four independent measurements were used
(`:26`, list continues past the read window).

Selector wiring: 5 Hz dedicated lightweight channel (`EngineMain.swift:712` — "地图指针读数 5Hz = 15Hz ÷ 3,
独立轻量 `pointer` 通道"), which is why this reader cannot run at tick rate.

## 9.6 Optical flow — OpenCV DIS, chosen by measurement

`OpticalFlowBridge.swift:4-30`. Problem statement: YOLOPX single inference is measured ≈60 ms
(148 GFLOPs against measured ANE peak 9.26 TFLOPS ⇒ 16 ms physical floor, current efficiency ≈26 %), so it
cannot reach the main loop rate; the intermediate frames must not be blind.

Same-batch ABBA measurement at 640×640 on this machine (`:13-19`), driven by the user's 「光流 ≤5ms」 red
line:
```
Apple VTOpticalFlow (VideoToolbox hardware)   10.28 ms   ✗
Vision VNGenerateOpticalFlow                   27.43 ms   ✗
OpenCV DISOpticalFlow ULTRAFAST                 1.91 ms   ✓
same, restricted to 1 core (extreme case)       3.78 ms   ✓
```
Official hardware paths are **5–14× slower**. DIS is the formal CVPR 2016 algorithm built into OpenCV's
`video` module, not custom code (`:19-21`). Accuracy (`:23`): displacement error **0.07 px**
(measured `dx = 1.930` vs ground truth 2.000 on a natural-texture image).

Threading (`:25-30`): the C layer `ad_dis_compute` is **not** thread-safe — the same ctx must not be called
concurrently — so the class serialises `compute` behind a private lock and permits calls from any thread
while serialising internally. `Vendor/OpenCVFlow/README.md` referenced for details; the build wiring
(`Package.swift:59-71`) and the static-link pitfalls are in SEC-01 §1.3.3 / SEC-02.

## 9.7 Motion prediction — α-β filter instead of Kalman

`MotionPredictor.swift:1-30`. The stale-box problem (`:5-11`): between two inferences the boxes are
**completely static** while targets move, so the car decides on stale positions.
Solution shape (user's proposal, `:13-18`): YOLOPX low-rate ground truth (~15 Hz) + optical flow
inter-frame motion vectors (measured p95 **3.7 ms**) + an α-β filter maintaining per-target position and
velocity + extrapolation between frames with correction when new observations arrive.

**Why α-β rather than Kalman** (`:20-27`), stated as an analytic argument: α-β is Kalman's closed-form
solution under a "constant-velocity model + steady-state gain". Covariance matrices are unnecessary here
because the motion model is simple (near-constant velocity, lane scenes), observation noise is relatively
stable (YOLO box jitter is measurable), and it must run every frame at 30 Hz where α-β costs two
multiply-adds versus matrix operations.

Design discipline (`:29-33`, same family as `LaneFallback`): ① fail-open — if flow is unavailable, ground
truth is stale, or a target is lost past timeout, **do not extrapolate**, return the un-predicted original
detection, "绝不编造运动"; ② predicted results are explicitly marked `isPredicted = true` so the decision
layer can down-weight them.

## 9.8 Ego motion — the missing consumer that was found by static audit

`EgoMotionModel.swift:4-30`. This file exists because of a **dead-data** finding: `OpticalFlowBridge` had
long computed `dx/dy/divergence` that had **zero readers repo-wide** (2026-09-30 static audit). Its stated
design purpose — "cross-check global motion direction" — had **never been implemented**: interface
reserved, data fed in, consumer never wired (`:7-12`). This file is that missing consumer: it turns
flow-estimated **ego motion** into a usable criterion for validating `MotionPredictor`'s target velocities
computed from box differencing (`:10-12`).

Why the model is **radial**, not translational (`:14-28`): `MotionPredictor`'s velocity comes from α-β
updates on box differences, which has an inherent weakness — when a **target is static and the ego is
moving**, it misinterprets "my own motion" as "the target is moving". The intuitive fix (subtract flow's
global median translation `dx/dy`) **is wrong**:
- ego **lateral** movement → whole image pans → `dx` describes it ✓
- ego **forward** movement → image content expands **radially toward the vanishing point** → not a
  translation ✗
When moving forward, targets near the centre barely move while edge targets fly outward — exactly what
`divergence` measures. Hence a radial expansion field is required.
Geometry (`:24-30`): vanishing point at image centre (valid when the optical axis is horizontal); for a
point at radius vector `r = (px − cx, py − cy)`, ego-motion displacement is
`u_ego = forwardRate · r_x`, `v_ego = forwardRate · r_y`.

## 9.9 Road prior — bitmap prior, heading only, never lateral

`RoadMapPrior.swift:4-30`. Purpose: when lane lines are entirely lost (junction / U-turn / occlusion /
game stutter), supply the "which way does the road turn" dimension that pure vision cannot (`:5-8`).
**Hard boundary** (`:10-12`): this prior provides **heading only, never lateral offset**. Lateral (is the
car left or right of centre) must come from real-time vision (lane lines / drivable area), because the map
is a player-annotated version with metre-level deviation from reality; using it for lateral would directly
mis-steer.

Data source (`:14-16`): `models/road_prior_2048_t70_fixed.png`, generated offline from
`models/bigworldmap-13056.jpg` by `models/tools/make_road_prior_t70.py` and
`make_road_corners_v2.py`, reproducible.

**Three major corrections (2026-09-30), all three previously wrong and pointed out by the user on the spot**
(`:18-30`, with a 2026-10-18 note fixing a "two vs three" typo):
1. **Threshold**: an earlier threshold of 45 captured **16.1 % extra contour noise** (measured
   677,265 pixels), causing 83 % of corner waypoints to land on buildings/contours. Full-image grey
   histogram measured: 0–8 pure black 47.6 % / 16–24 dark ground 45.0 % / 24–56 buildings+contours 4.8 % /
   **80–88 real road 1.95 % (the only one)**. Threshold 70 gives 98.6 % connectivity; threshold 80 collapses
   to **37 %**.
2. **Scaling**: the old code used `H//2048=6` (integer truncation) → each cell was really 6 px rather than
   6.375 px, and `2048*6=12288` **discarded the map's last 768 px (468 m)** → systematic coordinate offset,
   measured 66.6 % of waypoints more than 24 m from real road. BOX-scaling to exactly 6.375 px/cell
   covering the full extent brought the median deviation to **0.0 m**, 94.3 % within 1.8 m, 100 % within
   9.8 m.
3. (Third correction continues past the read window; `UNVERIFIED:` its exact content — must be re-read
   before quoting.)

## 9.10 Corner waypoints — v1's three mistakes

`RoadCornerGuide.swift:4-30`. Why waypoints rather than pure vision (`:6-10`): lane-line vision frequently
fails or is ambiguous at corners/junctions, whereas the map is a **fixed** prior that knows where the road
bends; the user explicitly required map-guided steering where turns belong.

**Three key properties of v2, where v1 was wrong on all three and the user said so on 2026-09-30
(`:12-22`)**:
1. **Dense** — one point every ~23 m along the bend (**952 positions**), not one point per corner;
   otherwise entering from another position or lane would miss it.
2. **Bidirectional** — each position produces two records (one per approach direction, with opposite
   `turnSign`), because a bend can be driven both ways and reverse entry reverses left/right. Matching must
   select the record whose direction agrees with the ego's current heading, otherwise the wheel is turned
   the wrong way.
3. Junction data is retained (`branchCount ≥ 3`, recording branch directions) but **turning decisions do
   not yet cover junctions** (corners first); it is used only for logging and future extension.

Division of labour with the prior (`:24-29`): `RoadMapPrior` = bitmap prior (2048² road grid) →
`isOnRoad` / `roadHeadingCandidates`; `RoadCornerGuide` = waypoint set (discrete corner records) →
`cornerAhead` / `steerForCorner`. The waypoint set answers "is there a known corner ahead and which way",
the bitmap answers "am I on the road right now".

## 9.11 Quest panel OCR — text to world coordinate

`QuestPanelReader.swift:4-30`. The chain: the game's left quest panel says e.g. "与路边着急的研究员对话" —
the player understands it, the car does not. Python-side tooling compiled 39 quest tables
(`tools/nte_datatables`) into `models/quest_index.json` — **1372 exact texts → 2938 located objectives** —
and this file wires that index into the runtime (`:6-11`).

Data path (`:13-25`):
```
CaptureEngine frame (tick主线程取 currentFrameCG)
  → crop questROI (normalised, top-left origin)
  → Vision VNRecognizeTextRequest (zh-Hans)
  → filter hint lines → join multiple lines into a query text
  → voting buffer (3 consecutive identical results required to confirm)
  → 4-way match: exact → substr → core → fuzzy (+ byname fallback)
  → verdict (ok / ambiguous / low / miss)
  → on ambiguous, disambiguate via the NextQuests chain
  → state.setLocatorTarget(x:y:) + state.questName
```
**Red line 1: coordinate system — not a single conversion is performed** (`:27-28`). The file then
continues into the coordinate contract; `UNVERIFIED:` the remainder of red lines 1..n were not read this
session, so nothing further about them is asserted here.

Runtime cadence: `minInterval = 0.7` s (`README.md:54` cites `:414-431`; `UNVERIFIED:` not re-read) and
default-enabled via `AuroraFlags.questOCR = true` (`AuroraFlags.swift:209`) — note this is a
**default-on** switch, unlike most.

## 9.12 Confidence estimator — the dead-model equilibrium bug

`ConfidenceEstimator.swift:4-30`. E2E outputs no confidence, so this heuristic estimates it from output
history plus the current image; the score in [0,1] feeds the degradation state machine (`:5-6`).
Gating + three fused signals (`:8-22`):
0. **Link-liveness gate** — model not loaded / no result / result stale ⇒ confidence 0. Reason recorded
   (`:9-11`): the old formula computed **0.70** for a dead E2E that always outputs `idle`/constant values,
   which is above the degradation threshold 0.65, so a **dead model stayed in the end-to-end tier forever**.
1. Output consistency — smaller steer jitter over the last N frames is more trustworthy (stable model).
2. Steer extremeness — steer pinned at the limit for a long time (`|steer| > 0.95`) is treated as
   degeneration. Throttle/brake at the edge is normal driving behaviour and no longer penalised — fixing
   the defect where "healthy cruise sat at exactly 0.70, could never reach the 0.75 recovery threshold, and
   stayed stuck in the rule tier" (`:14-17`). Stable output is **not** judged as frozen, because on a
   straight road the model is *supposed* to be stable (`:17-18`).
3. Frame validity — abnormal brightness (all black / all white) ⇒ low confidence.
Design (`:24-28`): sliding window of the last N outputs with O(1) update; three signals weighted, weights
adjustable; main-thread only (synchronous with tick).

## 9.13 Lane fallback — the four disciplines

`LaneFallback.swift:4-24`. Positioning statement: this is **fallback, not main driver**; every principle
serves one goal — the fallback must never itself become the accident source (`:8-9`):
1. **fail-open** — if any input is untrustworthy (degraded / empty mask / size mismatch) return nil
   immediately and the caller keeps its original decision; never "guess a direction" (`:10-11`);
2. **bounded output** — steer correction hard-clamped (±`maxSteer`), throttle may only decrease, never
   full throttle, because the fallback cannot judge whether acceleration is safe (`:12-14`);
3. **multi-frame confirmation** — the same directional deviation must hold N consecutive frames before
   being adopted, avoiding direction flapping from single-frame mask jitter (`:15-16`);
4. **discard sudden changes** — inter-frame deviation jumps beyond a threshold are treated as anomalous
   frames and the previous valid value is retained (`:17-18`).
Pure functional style (same as `RuleController`): no side effects, unit-testable; the only internal state is
a stability counter fed per frame by the caller (`:20-22`).

`Perception/LaneBridge.swift:168-176` supplies the same fail-open red line for mask geometry: `isUsable`
only checks "dimensions positive + cells long enough" — deliberately **not** a strict `== 160` gate, which
is `LaneFallback`'s job (its guard ②). The stated reason for still needing this check: if `cells` is shorter
than `width*height`, `LaneFallback` would later `SIGTRAP`, so it must be intercepted early.

`Perception/LaneExtrapolator.swift:57` restates it for lanes themselves: on a malformed mask return `.empty`
and **never fabricate lane lines**; the malformed-input guard shares its origin with `MaskGrid.at`.

## 9.14 Engine-vs-local asymmetry (critical for interpreting tests)

`EngineMain.swift:22-34` — YOLOPX **never runs in engine mode** because `tick()` early-returns via
`tickEngineMode()` and the single `yolopxEngine.infer(image:)` call site sits after that return. Test
implication, stated in-source: **local selftests cannot catch engine-mode perception bugs**, because the
code paths differ. Consequence chain: `MaskOverlay` reads empty masks locally-only-valid data,
`yolopxEngine.isDegraded` stays initially `true`, so `LaneFallback` does not engage in engine mode.
This is the root cause of the bug in SEC-07 §7.8.1 (mask guard on a field the protocol never sent), which
was invisible to every local selftest.

## 9.15 Testing surface for this subsystem

Registered one-shot modes (SEC-06 §6.7.3) that exercise perception: `--yolopx-selftest`,
`--yolo-selftest`, `--yolo-bench`, `--speed-selftest`, `--pointer-selftest`, `--opticalflow-selftest`,
`--motion-selftest`, `--corner-selftest`, `--route-selftest`, `--taxonomy-selftest`,
`--perception-selftest`, `--ayolom-selftest`, `--v2-selftest`, `--lanekeep-selftest`,
`--lanekeep-reality`, `--lane-extrapolator-selftest`, `--capture-selftest`, `--quest-selftest`,
`--egobox-selftest`, `--fit-selftest`, `--realshot-selftest`.

Two measurement semantics that must be respected when reading any of their outputs:
1. `--lanekeep-reality` exists to answer "does lane keeping actually work", because existing self-checks
   only validated contracts and **never measured real behaviour** (`AuroraDriveApp.swift:1022-1026`).
2. Absolute timings from any of these are not comparable across sessions — 2–2.5× drift on the same binary
   (`PerfSelfTest.swift:868-874`, SEC-07 §7.6.1). Use same-session back-to-back A/B or
   `scripts/paired-ab.sh --metric tick`.

## 9.16 Pitfalls summary for this subsystem

1. **YOLOPX letterbox ≠ yolo26s stretch** — feeding the wrong preprocessor silently distorts boxes and
   masks (`YolopxEngine.swift:18-22`).
2. **YOLOPX `det` is not NMS'd and is `(cx,cy,w,h)`** — unlike yolo26s which is NMS-free `(x1,y1,x2,y2)`
   (`:23-25`).
3. **CoreML feature name `lane`, not `lane_mask`**; and never name an input `state`
   (`InferenceEngineV2.swift:32-42`).
4. **`OpticalFlowBridge`'s `dx/dy/divergence` had zero readers until `EgoMotionModel` was written** — a
   dead-data class of bug that static audit found, not tests (`EgoMotionModel.swift:7-12`).
5. **Ego motion must be radial, not translational** — subtracting global median `dx/dy` is wrong for
   forward motion (`EgoMotionModel.swift:18-28`).
6. **Road prior gives heading only** — using it for lateral offset mis-steers by metres
   (`RoadMapPrior.swift:10-12`).
7. **Corner matching must respect ego heading** — otherwise the wheel turns the wrong way on bidirectional
   records (`RoadCornerGuide.swift:16-19`).
8. **A dead E2E model scored 0.70** — above the 0.65 degradation threshold, so it never degraded; fixed by
   the liveness gate (`ConfidenceEstimator.swift:9-11`).
9. **A healthy cruise scored exactly 0.70** — could never reach the 0.75 recovery threshold and stayed
   stuck in the rule tier (`ConfidenceEstimator.swift:14-17`).
10. **Double-model switching must trigger only on system faults, not on "can't read"** — otherwise normal
    low-confidence frames churn the engines (`SpeedOCRReader.swift:11-14`).
11. **θ₀ = 332.0° is a calibrated constant, not a guess** — omitting it makes every heading off by a fixed
    rotation (`PointerHeadingReader.swift:20-26`).
12. **Engine-mode blindness**: local selftests validate a different perception path than production engine
    mode (`EngineMain.swift:22-34`).
