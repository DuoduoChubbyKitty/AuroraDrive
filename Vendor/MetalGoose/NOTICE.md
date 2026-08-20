# MetalGoose — vendored source (GPL v3.0)

This directory contains the vendored source of
[MetalGoose](https://github.com/Stallion77RepoOfficial/MetalGoose),
vendored into AuroraDrive for use as the display-path upscaler / frame
interpolator.

- **Upstream license:** GNU GPL v3.0 — see `LICENSE` in this folder (verbatim
  copy of the upstream LICENSE).
- **Copyright:** the respective MetalGoose authors (see upstream repository).
- **Files here:** `GooseEngine.swift`, `Shaders.metal`, `CaptureSettings.swift`,
  `WindowCaptureManager.swift`, plus the upstream `LICENSE` and `README.md`.
  These are consumed by the `MetalGooseEngine` SwiftPM target. `GooseEngine.swift`
  carries two documented extensions (below); all other files are byte-for-byte upstream. and used ONLY to
  upscale / interpolate the on-screen preview in `UpscaleFrameHostView`.

## Modifications

Two documented, minimal extensions (not behavioral patches) are applied to
`GooseEngine.swift` so AuroraDrive can feed its **own** already-captured frames
into the engine's display path without starting a second ScreenCaptureKit stream:

1. Added a `public func ingest(cgImage:timestamp:)` method that converts a
   `CGImage` → `CVPixelBuffer` (BGRA, with IOSurface) → calls the existing private
   `processSurface(...)`.

2. Changed `setupPipelines()` to compile `Shaders.metal` from source at runtime
   via `Bundle.module` (the `.metal` is declared as a copied resource in
   Package.swift). SwiftPM does not auto-compile `.metal` into a `default.metallib`,
   so without this the engine could not build its compute pipelines. It falls back
   to `makeDefaultLibrary()` when a prebuilt metallib is present.

AuroraDrive additionally adds `Vendor/MetalGoose/Engine/GooseUpscaler.swift` — a
NEW, AuroraDrive-owned (GPL-3.0) public façade that re-exposes the minimal surface
AuroraDrive needs without altering `GooseEngine`'s internal API. Everything else in
the vendored files is unchanged.

All other vendored files are byte-for-byte upstream (only `GooseEngine.swift`
carries the two extensions above). Per GPL v3.0 §5, this file
retains its upstream GPL v3.0 notice and this modification is recorded here.
