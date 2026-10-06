# 3. Speed Recognition

> Sources: `SpeedOCRReader.swift` (1243 lines)
> Up: [Developer Guide](DEVELOPER_GUIDE.en.md) ｜ 中文: [速度识别子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/03-speed-ocr.md)

> **Archive note (verified 2026-09-19)**: after the 2026-09 dual-model rework the architecture is **PP-OCRv6 full-line primary + per-digit CNN backup** (the glyph template matcher was deleted); inference throttle changed from 1/30 to 1/15 (15Hz). Sections 3.1–3.6 below are restated for the new architecture; 3.7 is the removal archive of the glyph path.

## 3.1 In one sentence

The speedometer reading is recognized by a **dual-model** engine: the **primary path is a fine-tuned PP-OCRv6 full-line model** (whole ROI slice → CTC decode → last 3 digits of the digit string), the **backup path is a per-digit CNN** (three digits cropped into 3 small images, each fed to a 5-layer CNN recognizing 0–9). When PP-OCR hits a runtime *system-level* fault (inference throw / missing output), the frame is automatically downgraded to the CNN with an orange UI warning (`engineNotice`); "unreadable" business diagnostics are not faults and do not trigger a switch.

The recognized reading then passes **three validation layers** (range / jump / multi-frame confirmation, see 3.6) before reaching the UI.

**Archive**: the early **glyph template matcher** (speed_glyphs.json + 0–300 enumeration) has been fully replaced by the dual models and deleted (see 3.7).

## 3.2 Dual-engine architecture

`infer(nativePixelBuffer:)` is the single entry; every frame passes three gates (throttle constant `inferInterval = 1/15` — a stale "5Hz/200ms" comment remains at gate 1 in the code; the constant wins):

| Gate | Condition | On failure |
|---|---|---|
| 1 | ≥ `inferInterval` (1/15 s) since last inference | silent skip (normal throttle) |
| 2 | previous inference finished (`!isInferencing`) | silent skip |
| 3 | the active engine's model is available (`.ppocr` → `ppocrModel != nil`; `.cnn` → `cnnModel != nil`) | `lastOCRDiagnostic = "current engine X model unavailable"` |

Past the gates, work moves to the background `ocrQueue`, running **PP-OCR first, CNN as backup** (`activeEngine` is set by the init load outcome and runtime fault switching):

```swift
switch engineSnapshot {
case .ppocr where ppocrSnapshot != nil:
    result = Self.recognizePPOCR(roiBuffer:nativePixelBuffer, model: ppocrSnapshot!, keys: ppocrKeysSnapshot, isROISlice: true)  // primary
    if let err = result.error, let cnn = cnnSnapshot {
        // system-level fault → same-frame CNN run, no frame lost (engineNotice surfaces it)
        result = Self.recognizeCNN(slotImages: slots, model: cnn)
    }
case .cnn:
    result = Self.recognizeCNN(slotImages: slots, model: cnn)  // backup (3-slot crop)
}
```

> Both-models-load-failed writes `errorMessage` / `engineNotice` in `init` (e.g. "CNN backup model not loaded (speed_digit_cnn_v4 missing), no downgrade when PP-OCR fails") — never silent.

## 3.3 Primary engine: PP-OCRv6 full-line (recognizePPOCR)

Model: `models/ppocrv6_tiny_ft_int8.mlpackage` (fine-tuned PP-OCRv6 INT8, ≈1.2MB) + charset `models/ppocrv6_tiny_ft_keys.txt` (6904 lines; parsed **newline-strip only, never trimmed** — line 617 is a full-width space U+3000, a legal token).

- **Input**: grayscale → bilinear resize to **48×136** (`ppocrInputHeight/Width`) → duplicated to 3 channels (NCHW)
- **Output**: CTC logits `[1, T, 6906]` (6906 = blank + 6904 keys + space); greedy decode, take the **last 3 digits** of the digit string
- **Gates**: `ppocrMinDigits=2` (digit-string length floor) / `ppocrMinConfidence=0.30` / `ppocrMinForegroundRatio=80/3375≈2.37%` (Otsu foreground ratio below this = "no speedometer on screen", returns an fg diagnostic)
- **Still-frame reuse**: a 16×6 block-mean hash of the ROI grayscale; if unchanged from the previous frame the cached result is returned, skipping Otsu/resize/ANE inference/CTC (measured: skips more than half the frames)

**Model loading** (`loadPPOCRModel`) — newer-macOS pitfall (the CNN path is the same):

```swift
let compiledURL = try MLModel.compileModel(at: url)   // compile .mlpackage → .mlmodelc first
let model = try MLModel(contentsOf: compiledURL)       // then load the compiled product
```

> On newer macOS, feeding a `.mlpackage` directly to `MLModel(contentsOf:)` throws *"Compile the model with Xcode or MLModel.compileModel(at:)"* — you must compile first. Candidate paths (`AuroraPaths.projectRoot()/models/…` and relative); first success wins.

## 3.4 Backup engine: per-digit CNN (recognizeCNN)

Model: `models/speed_digit_cnn_v4.mlpackage` (5 conv layers 16→32→64→128→256 + FC, INT4 quantized, 1.2MB).

**Per-slot flow** (`recognizeCNN`):

1. Grayscale (`grayscalePixels`)
2. Otsu binarization to count foreground pixels (fg check only, not inference input)
3. `resizeNearest` to **90 high × 50 wide** (`templateHeight=90`, `templateWidth=50`)
4. `resizeGray` for the grayscale path, `/255.0` normalization
5. Fill `MLMultiArray` shape `[1, 1, 90, 50]` float32, input name `"digit_input"`
6. `model.prediction(...)` → output `"digit_output"` shape `(1, 10)`
7. argmax for the digit + softmax for confidence

Three slots → `hundreds×100 + tens×10 + ones`; confidence is the mean of the three slots.

## 3.5 Where slots come from (cropSlots — CNN backup path only)

Normalized positions of the three digits (same constants as `tools/build_speed_glyphs.py` — change one side, sync the other):

```swift
slotCentersNorm = [0.479, 0.496, 0.512]  // center x of hundreds/tens/ones
slotWidthNorm   = 0.014                   // slot width
slotYMinNorm    = 0.897                   // slot top y
slotYMaxNorm    = 0.932                   // slot bottom y
```

Cropping uses a **CIImage path** (pure crop, no interpolation). Input is the Ring-1 *native copy* (≈100KB, not downsampled) of the speedometer ROI slice from CaptureEngine; slot coordinates are converted into ROI-relative space via `CaptureEngine.speedROINorm`. The CI coordinate system has y pointing up, so the crop rect mirrors once via `y = sh - yMax`. (The PP-OCR primary path needs no slot cropping — the whole ROI slice goes straight to the model.)

## 3.6 Three validation layers (finish)

Raw output from the recognition engine (PP-OCR or CNN) **never** hits the UI directly; it passes three gates:

| Layer | Rule | On failure |
|---|---|---|
| Layer 1 range | speed within `speedRange = 0...400` | record `errorMessage`, drop frame |
| Layer 2 jump | differs from last valid value by > `maxJumpKmh` (60) | set `confidence = 0` so downstream `speedValid` goes false (degrade); `lastValidSpeed` not updated (anti-poisoning) |
| Layer 3 multi-frame | vote among last `confirmCount=3` frames in a `confirmWindowSec=1.0` window, tolerance `confirmToleranceKmh=2`, at least `minConfirmAgreement = confirmCount/2+1 = 2` agreeing | keep previous value |

> **Why tolerance voting**: integer speed drifts ±1–2 km/h per frame while accelerating; a "strict equality" vote never collects 3 frames. Tolerance groups adjacent readings into "the same reading". Ties resolve to the **newest** timestamp (`confirmedSpeed`).

**Constant cheat sheet**:

| Constant | Value | Meaning |
|---|---|---|
| `speedRange` | 0.0...400.0 | Layer 1 range |
| `minSpeed` / `maxSpeed` | 0 / 300 | 3-digit enumeration range (still used by the self-test path; glyph enumeration is gone) |
| `maxJumpKmh` | 60.0 | Layer 2 jump threshold |
| `confirmCount` | 3 | Layer 3 window frames |
| `confirmWindowSec` | 1.0 | Layer 3 time window |
| `confirmToleranceKmh` | 2 | Layer 3 vote tolerance |
| `minValidForegroundPixels` | 80 | min foreground pixels across slots (CNN path; PP-OCR uses the ratio form `ppocrMinForegroundRatio=80/3375`) |
| `inferInterval` | 1/15 s | inference throttle (was 1/30) |

## 3.7 Glyph template matching (deleted — archive)

> **Archive (removed in the 2026-09 dual-model rework; verified 2026-09-19)**: the glyph engine `recognize(slotImages:glyphs:)` (grayscale → Otsu → nearest-neighbor resize → enumerate 0–300 whole-3-digit match) and `loadGlyphsSync`/`maxSlotResidualRatio` were deleted from SpeedOCRReader, superseded by the PP-OCRv6 primary. `models/speed_glyphs.json` (45×25, older generation) is still in the repo but **no longer referenced by code**; the glyph resampling source data (`data/glyph_clips/*/frames/`) was already lost (the directory is now empty) — a 90×50 library cannot be regenerated. To revive a glyph path in the future: resample glyph frames with `RecordEngine`'s `glyphMode` first, then regenerate via `tools/build_speed_glyphs.py`.

## 3.8 Self-test and debugging

- On low fg (diagnostics starting with `fg=`), saves `/tmp/aurora_ocr_dbg_*.png` (ROI thumbnail, overwrite, non-blocking) to answer "what did the app actually capture"
- `lastOCRDiagnostic` records the latest failure reason: engine model unavailable / slot crop failed / fg too low / confidence too low / digit string too short / unrecognized; engine switch/load notices go through `engineNotice` (orange UI warning)
- `--speed-selftest <dir>` (via `selfTestDirectory`) runs a whole directory of frames, printing speed and confidence per frame
