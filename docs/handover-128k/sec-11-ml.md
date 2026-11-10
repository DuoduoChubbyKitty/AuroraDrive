# SEC-11 — ML TRAINING PIPELINE (`src/*`, dataset_v3, model_v3, export)

`src/` — **22 Python files / 17,706 lines** (measured, excluding `__pycache__`). Largest: `train_v2.py`
2317, `model_v2.py` 1930, `risk_head.py` 1822, `model_v3.py` 1648, `dataset_v2.py` 1417,
`model_v3_experiments.py` 1045, `dataset_v3.py` 913, `verify_heads.py` 699, `heading_head.py` 644,
`verify_lane_usage.py` 613, `model.py` 596, `train_mono.py` 558, `temporal.py` 519,
`train_game_assist.py` 498, `world_model.py` 485, `train_v3.py` 449, `mono_dataset.py` 375,
`lane_geometry.py` 330, `config.py` 283.
`tools/` — **219 `.py` files / 53,298 lines**, an append-only archaeology dir (SEC-01 §1.9).

## 11.1 `dataset_v3` — the data contract the recorder must satisfy

`src/dataset_v3.py:257` `class V3KeyDataset(Dataset)` — the class name is
`V3KeyDataset(clips_dir=...)`, **not** `V3ClipDataset`.

### 11.1.1 Required columns (order-independent)

```
src/dataset_v3.py:65-69
REQUIRED_COLUMNS = ["t_sec","frame","w","a","s","d","shift","space","super_brake","ultimate_brake"]
src/dataset_v3.py:72
ATOMIC_KEYS = ["w","a","s","d","shift","space"]
```
The comment at `:65` dates the format: "录制器 2026-11-03 起的必需列（顺序无关）". Note what is **absent**:
`speed_kmh` is not required (it is read opportunistically and may be empty) and there are **no** position /
heading / acceleration columns. This is the upstream reason the recorder dropped those columns
(SEC-05 §5.3).

Header validation (`:456-464`): missing required columns raise `ValueError` naming the missing set, printing
the actual header, and stating that V3 needs the post-2026-11-03 pure-key format — old format must be
rebuilt via `keylog.csv` or re-recorded.

### 11.1.2 Frame-rate contract — a raise, not a warning

```
src/dataset_v3.py:86   EXPECTED_FPS = 15
src/dataset_v3.py:89   FPS_TOLERANCE = 0.15
```
Reasoning recorded at `:80-85`: the deployment tick is 15 Hz (citing `EngineMain.swift:709`), and V3's
24-frame window is designed at 15 Hz = 1.6 s (`model_v3.py:274`). Recording at another rate desynchronises
"how long 24 frames cover" from deployment, so the temporal dynamics the model learns have the wrong scale —
at 10 fps, 24 frames span 2.4 s and the motion looks slower.

Validation (`:427-450`): if `expected_fps is None` or fewer than 2 rows, skip. Parse `t_sec` (a non-numeric
value raises with the clip name). Compute positive deltas only, take the **median**, then
`actual_fps = 1.0/median_dt`; if `abs(actual_fps - expected)/expected > FPS_TOLERANCE` → `ValueError` whose
message quotes the measured fps, the assumed fps, the tolerance, the design rationale, and the remedy
(`--fps 15` re-record, or pass `expected_fps=None` to disable deliberately).
Accepted band is therefore **12.75–17.25 fps**.

### 11.1.3 Sample shape and the two zero-filled inputs

`src/dataset_v3.py:258-278` (docstring). Per sample:
```
image_hi      [3, 224, 384]        current frame (high-res)
image_lo      [21, 3, 112, 192]    previous 21 frames (low-res), padded with earliest frame
lane          [1, 160, 160]        lane mask   → currently a ZERO image
dets          [20, 12]             detection boxes → currently ZERO
det_mask      [20]                 valid mask → all zero
vehicle_state [8]
+ 8 targets
```
**Explicitly recorded gap** (`:275-277`): `lane` and `dets` are zero-padded because the recording data
contains neither; the V3 model accepts them (inheriting V2's contract) but **training with zeros means those
two branches learn nothing**. Marked as a recorded untested/open item requiring the recorder to eventually
persist lane masks and detection boxes.

Constants (`:74-78`): `NUM_HI_FRAMES = 3`, `NUM_TOTAL_FRAMES = 24` (must agree with
`model_v3.V3Config.num_hi_frames`, default 3). Window = 3 high-res (`t, t−1, t−2`) + 21 low-res
(`t−3 … t−23`) = 24 frames @15 Hz = 1.6 s.

Constructor (`:279-307`): `V3KeyDataset(clips_dir, image_size=(224,384), lowres_size=(112,192),
history=21, augment=False, view_filter=None, skip_all_zero=True, seed=42, expected_fps=EXPECTED_FPS)`.
Raises `RuntimeError("需要 Pillow：pip install pillow")` if PIL is missing. Caches: `index: List[(Path,int)]`,
`_rows_cache`, and `_cm_cache` (per-clip `[N,6]` atomic-key matrix for confidence/risk computation).
`_build_index` is called with `view_filter` and `skip_all_zero` (`:307`).

`skip_all_zero=True` drops frames whose 8 keys are all zero (`:386`), erroring with
`"所有 clip 均无有效样本"` if everything is dropped (`:400`). Critically, the docstring at `:321` states that
skipping does **not** shift later frame numbers, because the index keeps the CSV row order.

## 11.2 The 8 output heads and their derived labels

Head names enumerated in `src/dataset_v3.py:15-18` (and the model's forward dict, see §11.4):
```
handbrake    [B,1] 0/1   (= shift)
brake        [B,1] 0/1   (= space)
super_brake  [B,1] 0/1   (= shift ∧ space)
ultimate     [B,1] 0/1   (= shift ∧ space ∧ s)
```
**Combination consistency is validated, not assumed** (`:183-195`): if `super_brake != (shift and space)`
the loader raises naming the row and all three values; likewise
`ultimate != (shift and space and s)`. This is why those two columns are stored rather than recomputed — they
are redundant by construction, so any disagreement proves corruption.

Key semantics (user-authoritative, cross-referenced from `KeyboardMonitor.swift:111-112` and the recorder's
CSV): Shift = handbrake; Space = normal brake; Shift+Space short press = super brake; long press = ultimate
brake; S alone = reverse; S during ultimate braking = anti-rollover. `dataset_v3` encodes the derived heads
as `handbrake=shift`, `brake=space`, `super_brake=shift∧space`, `ultimate=shift∧space∧s` — i.e. **the safety
heads are Boolean functions of the three atomic keys**, which is exactly why recording raw keys is
sufficient and recording continuous values is not needed.

`intent_from_keys(w,a,s,d,shift,space)` at `:160-171` provides the intent-head label.
`risk` labels derive from the same keys (`:231-233`): `ultimate_brake` (Shift+Space+S) → **1.0** (highest
risk, actively limit-braking); `super_brake` (Shift+Space) → **0.8**; `space` or `s` (normal brake /
reverse) → **0.5**.

## 11.3 `model_v3` — structure and its paper provenance

`src/model_v3.py:1-2` — the file is marked `[TRAINING-ONLY]`: used only for offline training/export; at
runtime CoreML / the C++ inference side executes it. Header (`:3-8`) declares it the integrated
implementation of the three `docs/v3-design/` design documents (`01-backbone.md`, `02-temporal.md`,
`03-output-head.md`).

**Paper-derived mechanisms that must be preserved verbatim** (`:11-30`), from
`docs/v3-design/papers/state_aware.txt` (arXiv:2310.20650), *Addressing Limitations of State-Aware Imitation
Learning for Autonomous Driving*:
1. **State Token Propagation** (§IV.A, `:173-207`) — the ego state (`t−1` steer/throttle/brake/speed) becomes
   a special Transformer token, role-equivalent to ViT's CLS token (paper `:193`), but its content comes from
   **measured values**, not learned. Between adjacent stages **only this one state token is propagated**
   (paper `:179-181`), not the visual tokens — so every stage can "look at the image again with a new
   question".
2. **Pixel-State Attention** (§IV.B, `:208-245`) — the conv backbone's feature map is flattened into N visual
   tokens, the state token is prepended, and all do self-attention together, so every pixel attends to other
   pixels **and** to the vehicle state (paper `:236-237`). This is both the multi-stage information path and
   the source of built-in interpretability.
3. Coarse-to-fine multi-stage (§III / §IV.D), continuing past the read window.

`V3Config` at `:329-330`; `num_hi_frames: int = NUM_HI_FRAMES` (`:342`); total-frame property
`num_hi_frames + num_lo_frames` (`:384`); validation that `num_hi_frames ≥ 1` and `num_lo_frames ≥ 0`
(`:438-439`).
Reparameterization: `def reparameterize()` (`:506`, `:1103`) folds training-time branches into the deployment
form (`:1114` comment "折叠 → 部署态"), and `export_coreml()` does not emit certain training-only parameters
(`:209`, `:1124`).

## 11.4 `train_v3` — supervision is raw keys, and model selection is macro recall

`src/train_v3.py:4-9` states the design premise in terms of the user's requirement (「模型直接输出标签，不要油门」):
V3's supervision target **is the raw keys** (`w/a/s/d/shift/space`) expanded into 8 heads; the data flow is
`controls.csv(pure keys) → dataset_v3 → 8 head targets → V3Loss`. **No continuous
(steer/throttle/brake)-to-key conversion exists anywhere in this file.**

Relationship to v2 (`:11-19`): reuses `build_adamw_optimizer` (no weight decay on BN/bias) and
`CosineWithWarmup` from `train_v2.py` — existing implementations, not re-invented — but does **not** reuse
the v2 data pipeline, because v2 reads continuous values and v3 reads pure keys; the target semantics differ.

**CCM is explicitly disabled during training** (`:21-29`), with the measured evidence quoted in-source:
`V3Model.forward` returns keys `['brake','confidence','handbrake','horizontal','intent','risk','super_brake',
'ultimate','vertical']` — **no `ccm`** — and `V3Loss` computes the CCM term only when both `ccm_pred` and
`ccm_target` are passed, otherwise it **silently skips** (no error, no trace). Therefore training passes
`enable_ccm=False` explicitly so that "CCM not enabled" is a **stated decision** rather than a silently
skipped configuration. Enabling requires wiring a ccm output into forward first (a training-only branch).

**Model selection must not use overall accuracy** (`:30-35`), with the measured justification: a trivial
"always output W" solution already scores **80.8 %** overall accuracy while never predicting class S even
once. Therefore the script selects the epoch by **macro recall** (arithmetic mean of per-class recall)
and logs per-class recall plus the confusion-matrix diagonal.

Usage (`:37-44`): inspect distribution first (`python3 src/dataset_v3.py --stats data/raw_clips`) to decide
class weights rather than hand-filling them; then
`python3 src/train_v3.py --clips data/raw_clips --epochs 30 --batch-size 8`; a smoke run uses 2 epochs and a
small batch.

## 11.5 Export chain and its documented pitfalls

Exporters observed in `tools/`: `convert_e2e_to_coreml.py`, `convert_e2e_v2.py`, `convert_e2e_v3.py`,
`convert_yolo_to_coreml.py`, `tools/yolopx/export_yolopx_coreml.py` (+ `verify_yolopx_coreml.py`),
`tools/export_m9_v2_coreml.py` (referenced by `InferenceEngineV2.swift:14-17` as the **authoritative** contract
source, "含 8 个实测坑", and explicitly stated to win over `src/model_v2.py` when the two disagree, because it
decides what lands on disk).

Cross-layer facts that constrain export:
- The Swift side drives CoreML feature names from a single constant table because exported names diverged from
  Python parameter names: `lane` vs `lane_mask`, and an input named `state` gets **silently renamed** to
  `state_workaround` by coremltools 8.3 (`InferenceEngineV2.swift:32-42`, SEC-09 §9.3).
- Model assets live under `models/` (193 top-level entries: 52 `*.mlmodelc`, 105 `*.mlpackage`) and are
  **not** vendored into git-friendly form (`models/` is 3.9 GB, SEC-01 §1.5).
- `NOTICE:30-41` constrains two third-party assets: `bigworldmapSecond.png` is the game publisher's
  copyrighted map and must be supplied locally / not committed; `pointer_model.onnx` and the nteguide marker
  DB are likewise third-party and not redistributed.

## 11.6 Verification scripts

`src/verify_heads.py` (699) and `src/verify_lane_usage.py` (613) exist to verify head behaviour and lane-mask
usage rather than trusting training logs. `tools/v3_contract_test.py` is the contract-level test for the
11-column format referenced by the recorder work.
`UNVERIFIED:` the internals and current pass counts of `verify_heads.py` / `verify_lane_usage.py` /
`tools/v3_contract_test.py` were **not** executed or read this session; they are named as the verification
surface, not asserted as passing.

## 11.7 Configuration that is training-sim, not vehicle runtime

`src/config.py` (283) is a **traffic/world simulation** config, easily mistaken for vehicle parameters. Facts
read: `ROOT_DIR` derived from `__file__` (`:12`), `DATA_DIR`/`MODELS_DIR`/`SRC_DIR`/`CONFIGS_DIR` (`:15-18`),
`AURORA_MAP_DIR` env override (`:25`), `MAP_FILE = fujian_map.bin` with `MAP_MAX_SIZE = 700 MB` (`:35-36`),
`ROAD_TYPES` (`:39`), `WORLD_LOAD_RADIUS = 500.0 m` / `WORLD_UNLOAD_RADIUS = 800.0 m` (`:49-50`),
`EGO_VEHICLE` (`:54`), `VEHICLE_TYPES` (`:66`), `TRAFFIC_MAX_VEHICLES = 150` (`:110`),
`TRAFFIC_UPDATE_HZ = 10` (`:111`), spawn/despawn ranges `200–300 m` / `200 m` (`:112-114`),
`TRAFFIC_DENSITY` (`:117`), `IDM_PARAMS` (`:124`), `MOBIL_PARAMS` (`:134`), `SCENARIO_PROBS` (`:141`),
`INTERSECTION_RULES` (`:152`), `CAMERA_COUNT = 10` (`:172`).
`UNVERIFIED:` whether this module participates in V3 training or only in the separate simulation track — the
import graph was not traced this session.

## 11.8 Training-pipeline pitfalls

1. **Wrong class name**: `V3KeyDataset`, not `V3ClipDataset` (`dataset_v3.py:257`) — importing the wrong
   symbol fails at import time.
2. **Wrong FPS is fatal, not cosmetic**: `expected_fps` mismatch raises and rejects the whole clip
   (`:442-448`); the recorder's 15 Hz gate exists to satisfy this (SEC-05 §5.8).
3. **Empty `speed_kmh` is meaningful**: empty ⇒ `speed_valid=0`; `0` would be read as a true zero speed
   (`LeanRecordEngine.swift:489-491`).
4. **`skip_all_zero` can empty the dataset** and raises rather than returning zero samples (`:400`).
5. **Derived brake heads are validated against atomic keys**, so corruption surfaces as a `ValueError` with
   all three values printed (`:183-195`).
6. **CCM silently does nothing unless enabled** — `V3Loss` skips it without error when the predict/target pair
   is absent (`train_v3.py:21-29`).
7. **Overall accuracy is a trap**: a constant-W model scores 80.8 % (`train_v3.py:30-33`) — select on macro
   recall.
8. **`lane`/`dets` are zero-filled**, so those branches cannot learn from current recordings
   (`dataset_v3.py:275-277`) — a stated open item, not a hidden one.
9. **CoreML feature names ≠ Python parameter names**, and `state` is renamed by coremltools
   (`InferenceEngineV2.swift:32-42`).
10. **Export script wins over model source** for the on-disk contract (`InferenceEngineV2.swift:14-17`).
11. **`config.py` is simulation config**, not vehicle runtime parameters — do not quote its numbers as
    deployed behaviour.
