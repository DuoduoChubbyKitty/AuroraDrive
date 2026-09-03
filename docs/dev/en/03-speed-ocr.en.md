# 3. Speed Recognition

> Sources: `SpeedOCRReader.swift` (1061 lines)
> Up: [Developer Guide](../../DEVELOPER_GUIDE.en.md) ｜ 中文: [速度识别子系统](../03-speed-ocr.md)

## 3.1 In one sentence

The three digits on the speedometer (e.g. `120`) are cropped into 3 small images; each is fed to a **5-layer convolutional network** that recognizes 0–9; the three digits combine into a speed value, which then passes **three validation gates** before reaching the UI.

When the network cannot read (e.g. no speedometer on screen), a **glyph template matcher** acts as a fallback — currently disabled (see 3.6).

## 3.2 Dual-engine architecture

`infer(nativePixelBuffer:)` is the single entry; every frame passes three gates:

| Gate | Condition | On failure |
|---|---|---|
| 1 | ≥ `inferInterval` (1/30 s) since last inference | silent skip (normal throttle) |
| 2 | previous inference finished (`!isInferencing`) | silent skip |
| 3 | `cnnModel != nil` **or** glyph library non-empty | `lastOCRDiagnostic = "CNN model and glyphs not loaded"` |

Past the gates, work moves to the background `ocrQueue` and picks **CNN first, glyph fallback**:

```swift
if let cnn = cnnSnapshot {
    result = Self.recognizeCNN(slotImages: slotImages, model: cnn)   // primary
} else {
    result = Self.recognize(slotImages: slotImages, glyphs: glyphsSnapshot)  // fallback
}
```

## 3.3 Primary engine: CNN (recognizeCNN)

Model: `models/speed_digit_cnn_v4.mlpackage` (5 conv layers 16→32→64→128→256 + FC, INT4 quantized, 1.2MB).

**Model loading** (`loadCNNModel`) — a newer-macOS pitfall:

```swift
let compiledURL = try MLModel.compileModel(at: url)   // compile .mlpackage → .mlmodelc first
let model = try MLModel(contentsOf: compiledURL)       // then load the compiled product
```

> On newer macOS, feeding a `.mlpackage` directly to `MLModel(contentsOf:)` throws *"Compile the model with Xcode or MLModel.compileModel(at:)"* — you must compile first. Two candidate paths (relative `models/…` and absolute); first success wins; total failure is silent (gate 3 surfaces the diagnostic in the UI).

**Per-slot flow** (`recognizeCNN`):

1. Grayscale (`grayscalePixels`)
2. Otsu binarization to count foreground pixels (fg check only, not inference input)
3. `resizeNearest` to **90 high × 50 wide** (`templateHeight=90`, `templateWidth=50`)
4. `resizeGray` for the grayscale path, `/255.0` normalization
5. Fill `MLMultiArray` shape `[1, 1, 90, 50]` float32, input name `"digit_input"`
6. `model.prediction(...)` → output `"digit_output"` shape `(1, 10)`
7. argmax for the digit + softmax for confidence

Three slots → `hundreds×100 + tens×10 + ones`; confidence is the mean of the three slots.

## 3.4 Where slots come from (cropSlots)

Normalized positions of the three digits (same constants as `tools/build_speed_glyphs.py` — change one side, sync the other):

```swift
slotCentersNorm = [0.479, 0.496, 0.512]  // center x of hundreds/tens/ones
slotWidthNorm   = 0.014                   // slot width
slotYMinNorm    = 0.897                   // slot top y
slotYMaxNorm    = 0.932                   // slot bottom y
```

Cropping uses a **CIImage path** (pure crop, no interpolation). Input is the Ring-1 downsampled speedometer ROI slice from CaptureEngine; slot coordinates are converted into ROI-relative space via `CaptureEngine.speedROINorm`. The CI coordinate system has y pointing up, so the crop rect mirrors once via `y = sh - yMax`.

## 3.5 Three validation layers (finish)

Raw CNN output **never** hits the UI directly; it passes three gates:

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
| `minSpeed` / `maxSpeed` | 0 / 300 | 3-digit enumeration range |
| `maxJumpKmh` | 60.0 | Layer 2 jump threshold |
| `confirmCount` | 3 | Layer 3 window frames |
| `confirmWindowSec` | 1.0 | Layer 3 time window |
| `confirmToleranceKmh` | 2 | Layer 3 vote tolerance |
| `minValidForegroundPixels` | 80 | min foreground pixels across slots (below = no speedometer) |
| `maxSlotResidualRatio` | 0.30 | glyph-match residual cap (fallback engine only) |
| `inferInterval` | 1/30 s | inference throttle |

## 3.6 Fallback engine: glyph template matching (currently disabled)

`recognize(slotImages:glyphs:)`: grayscale → Otsu → nearest-neighbor resize → enumerate 0–300 for a whole-3-digit match (±1px 9-offset voting, minimal residual wins).

**Current status: unavailable.** Why:

1. The glyph library `models/speed_glyphs.json` is **45×25** (older generation)
2. The CNN version raised `templateHeight/Width` to **90×50**
3. `loadGlyphsSync`'s size check `45 != 90` fails → silently rejected → empty glyph library
4. The glyph resampling source data (`data/glyph_clips/*/frames/`) is lost — a 90×50 library cannot be regenerated

**Impact: none.** Once the CNN primary loads, `infer` always takes the CNN branch. To revive the fallback: resample glyph frames with `RecordEngine`'s `glyph_mode`, then regenerate via `tools/build_speed_glyphs.py` (template size already synced to 50×90).

## 3.7 Self-test and debugging

- On low fg, saves `/tmp/aurora_ocr_dbg_*.png` (full-screen thumbnail + 3 slot crops) to answer "what did the app actually capture"
- `lastOCRDiagnostic` records the latest failure reason: neither engine loaded / slot crop failed / fg too low / CNN inference failed
- `--speed-selftest <dir>` runs a whole directory of frames, printing speed and confidence per frame
