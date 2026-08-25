# MetalGoose — vendored source (GPL v3.0)

This directory contains the **unmodified** source of
[MetalGoose](https://github.com/Stallion77RepoOfficial/MetalGoose),
vendored into AuroraDrive for use as the display-path upscaler / frame
interpolator.

- **Upstream license:** GNU GPL v3.0 — see `LICENSE` in this folder (verbatim
  copy of the upstream LICENSE).
- **Copyright:** the respective MetalGoose authors (see upstream repository).
- **Files here:** `GooseEngine.swift`, `Shaders.metal`, `CaptureSettings.swift`,
  `WindowCaptureManager.swift`, plus the upstream `LICENSE` and `README.md`.
  These are consumed by the `MetalGooseEngine` SwiftPM target and used ONLY to
  upscale / interpolate the on-screen preview in `UpscaleFrameHostView`.

## Modifications

None. The files are kept byte-for-byte as published by the upstream project
so that AuroraDrive remains a faithful GPL v3.0 derivative.

If AuroraDrive later patches any of these files, the change MUST be recorded
here and the file MUST retain the upstream GPL v3.0 notice, per GPL v3.0
§5 (Modified Source Versions).
