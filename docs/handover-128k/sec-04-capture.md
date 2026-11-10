# SEC-04 — CAPTURE: CaptureEngine / SCStream / FRAME FORMAT / ROI / CAPTURE HZ

Primary source: `Sources/AuroraDrive/Capture/CaptureEngine.swift` (1739 lines). Read regions: header
1-100, `start()` 438-501, `startStream()` 504-567+, config/hot-hz 625-744, exclusion audit 1060-1113,
sample-buffer callback 1116-1179. Line numbers are real.

## 4.1 What this layer is

`final class CaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable` (`CaptureEngine.swift:98`).
A long-lived ScreenCaptureKit stream: the system pushes frames on change, memory stays flat, and one
stream feeds UI display + model inference + recorder (`:92-97`, `:4-8`).

The file header comment block records that the class comment saying "30fps" is historical — actual rate
is dispatched dynamically (see 4.4).

## 4.2 Two capture modes (2026-10-08 dual-mode rework)

Header documents the user requirement verbatim and, more importantly, the **bug it fixed**
(`CaptureEngine.swift:10-27`):
- Original filter was `SCContentFilter(display:excludingWindows: [])` — the exclude array was **empty**,
  i.e. nothing excluded, so the whole display (desktop + AuroraDrive's own UI) was captured.
  Training data contaminated by the app's own windows = poisoned imitation-learning dataset (`:17-19`).
- `.fullScreen` — whole display, **excluding all own windows** (`:22`).
- `.window(id)` — `SCContentFilter(desktopIndependentWindow:)`, which inherently contains neither own UI
  nor desktop (`:23-24`).
- Runtime switching uses `SCStream.updateContentFilter(_:)` (macOS 12.3+) so there is no stream restart
  and no dropped frames (`:26-27`).

Types:
- `enum CaptureMode: Equatable, Sendable` (`:45-63`), cases `.fullScreen` (with `excludedWindowCount`
  used only for diagnostics, `:46-47`) and `.window(id: CGWindowID)` where the id is
  `SCWindow.windowID` = `CGWindowID` (`:48-49`). `isWindowMode` (`:51-54`), `label` (`:57-62`).
  Why an enum rather than a Bool is documented at `:42-44`: the requirement is a two-way choice that may
  later become multi-window, and an enum with associated values removes the illegal state
  "`isWindowMode=true` but `windowID=nil`".
- `struct CapturableWindow: Identifiable, Equatable, Sendable` (`:70-90`) — flat value snapshot for the
  UI selector: `id`, `applicationName`, `bundleIdentifier`, `title`, `width`, `height`, `isGame`, `isOwn`
  (`:72-81`), plus `displayLabel` (`:84-87`) and `sizeLabel` (`:89`). Why flat (`:66-69`): `SCWindow` is
  a system object that dies with the window; holding it in cross-process/cross-thread UI code risks a
  stale object, so the selector holds values and re-resolves by `id` when switching
  (`CaptureEngine.resolveWindow(id:)`).

## 4.3 Stream configuration — resolution, aspect, format

`static func makeStreamConfiguration(configHz: Double, display: SCDisplay) -> SCStreamConfiguration`
(`:632-661`). This is a **static pure function deliberately shared** by `start()`'s first build and by
`setCaptureHz`'s hot-update path, because `updateConfiguration` requires the **full** config, not a
delta (`:625-627`, `:526-529`).

| field | value | line |
|---|---|---|
| `width` | `targetW = 1280` | `:634`, `:646` |
| `height` | `(1280 * aspect).rounded()` | `:647` |
| `aspect` | `screen.frame.height / screen.frame.width` if the `NSScreen` matching `displayID` is found; else `display.height/display.width`; else `9/16` | `:635-645` |
| `scalesToFit` | `false` | `:648` |
| `minimumFrameInterval` | `CMTime(value: 1, timescale: tscale)` where `tscale = max(1, Int(safeHz.rounded()))` and `safeHz = max(1, min(120, finite ? configHz : 20))` | `:650-652` |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` | `:653` |
| `queueDepth` | `3` | `:654` |
| `showsCursor` | `true` | `:655` |

Aspect-ratio correctness is called out as critical (`:517-524`): `SCStreamConfiguration` defaults
`preservesAspectRatio = true` and `scalesToFit = false` (shrink-only, no stretch). Forcing a 3:2 screen
(1470×956 pt) into 16:9 1280×720 would letterbox and **shift every normalised coordinate**
(`speedROINorm`, detection boxes, lane masks) relative to the full frame. Hence height is derived from
the screen's own aspect.

Performance history recorded in the same block (`:509-537`):
- old: native Retina pixels **2940×1912 @30fps = 675 MB/s** through the WindowServer compositor,
  competing with the game for GPU bandwidth; on a fanless Air M3 this caused thermal throttling and the
  game dropped to 1-2 fps (recording and autodrive alike) — and the training data only ever stored
  640×360 JPEG while the model consumes 180×320, i.e. 24× wasted pixels.
- current at 20 fps: 1280×832 @20fps = **85 MB/s**; at 45 fps it was 192 MB/s where every tick consumed
  only 1 frame and the rest were dropped as pure waste. Overall reduction from the original:
  **7.9×** (`:535`).
- The block itself flags its own baseline as historical: frame rate is dispatched by
  `setCaptureHz(_:)` per mode and emergency state; "两档基准都 20fps，应急冲刺提到 45fps" is the text
  at `:536-537`, whereas the current authority in `EngineMain` is 15 fps for both tiers and 20 Hz sprint
  (SEC-03 §; `EngineMain.swift:709-711`, `:868-885`). **Numbers inside comments drift; read
  `EngineMain.engineTickHz` for the live value.**
- The log line printed per configuration build reports `WxH @fps`, aspect and MB/s (`:656-659`).

## 4.4 Frame-rate control — hot update and its unverified assumption

`func setCaptureHz(_ hz: Double) async` (`:710-746`).

Flow:
1. Clamp `newHz` into `1...120`, treating non-finite as 20 (`:711`).
2. Store `targetCaptureHz = newHz` unconditionally, so a later `start()` uses it (`:713`).
3. If not capturing (or no stream/display), log "未在捕获 → 只记 targetCaptureHz，下次 start() 生效" and
   return (`:715-718`).
4. If `newHz == old`, skip `updateConfiguration` entirely (`:719-722`).
5. Primary path: build a fresh full config and `try await stream.updateConfiguration(newConfig)`, then
   `activeCaptureHz = newHz` (`:724-730`).
6. Fallback on throw: await any `pendingStopTask`, then `stop()` + `start()` (`:731-742`).

Two facts that make changing this API risky:
- **The hot update is explicitly documented as unverified** (`:686-700`). `SCStream.h:500` is quoted
  verbatim (`:668-679`) showing the Swift async signature and that `updateConfiguration` has no extra
  availability beyond macOS 12.3, so it is usable at `.macOS(.v26)` (`:680-684`). But the header says
  nothing about which fields may be updated live, and frame rate is a capture throttle that may be
  frozen at stream creation. Therefore **"`updateConfiguration` did not throw" ≠ "the frame rate really
  changed"**, and setting `activeCaptureHz` on the success path is called out as an **optimistic
  assumption** (`:689-690`).
  The author wrote a measurement plan (`:692-699`): observe `[cap-deep] 📥 帧到达 #N` (printed every 60
  frames, so ~3.0 s at 20 fps), call `setCaptureHz(45)` and see whether the interval becomes ~1.33 s, or
  more rigorously count frames in a fixed 5 s window (20 fps → ~100, 45 fps → ~225); if the hot update
  proves ineffective, the fallback must become the primary path. `UNVERIFIED:` whether this measurement
  was executed — the block still says "待批准编译后执行".
- `activeCaptureHz` is deliberately **not** assigned on the fallback path (`:743-744`): it means "actually
  in effect" and is only set by `startStream` after `startCapture` succeeds (`:530`).
- Wiring status note (`:707-709`): as of 2026-10-12 it **is** called from
  `EngineMain.applyPerceptionMode` (two sites: mode switch, and re-switch after recording ends) and from
  `tickOnce`'s emergency-sprint linkage. The newer line numbers in that comment point into `EngineMain`
  and are `UNVERIFIED:` in this session.

## 4.5 `start()` — ordering and races

`func start()` (`:438-501`):
1. Probe log with `isCapturing`, `desiredMode.label`, pid (`:439`).
2. `guard !isCapturing` — repeated calls early-return (`:440-443`).
3. Body runs in a `Task` rather than inline (`:446`).
4. **Await `pendingStopTask` before building a new stream** (`:449-466`). Rationale (`:452-460`):
   `stop()` sets `stream=nil`/`isCapturing=false` **synchronously** precisely so this guard can pass,
   but the old stream's `stopCapture()` is still running asynchronously. Starting a new capture then
   interleaves old-stop with new-start on the same SCStream subsystem; the observed symptom was the
   user-reported "停止后再选就没反应". It must be `await`, not a semaphore, because `start()` is invoked
   from the **main thread** (UI button / socket command) and a synchronous wait would freeze or deadlock
   it if the cleanup task needs main-thread progress (`:458-460`).
5. `SCShareableContent.current` (`:473-482`); on failure it emits both
   `onStatusChange(.error("获取屏幕内容失败（可能未授权）: ..."))` and `onStatusChange(.permissionDenied)`
   (`:479-480`) so the UI can distinguish an authorisation problem.
6. Display selection prefers `CGMainDisplayID()` and only falls back to `content.displays.first`
   (`:484-496`) — reason given: avoid capturing an arbitrary-order display (`:484`).
7. `await startStream(display:content:)` (`:499`).

## 4.6 `startStream()` — filter construction and mode failure policy

`private func startStream(display:content:) async` (`:504-...`):
- Logs `display.frame.size`, `display.width`, `display.height` to confirm whether `SCDisplay.width` is
  pixels or points — the comment states Apple documents pixels but measurement is required, and glyph
  templates depend on native resolution (`:505-507`). `UNVERIFIED:` the measured conclusion is not
  stated in that comment.
- Builds config from `targetCaptureHz` (`:530`).
- Filter by mode (`:545-567`):
  - `.window(id)`: resolve via `Self.findWindow(id:in:)`; if the window is gone it **refuses to silently
    fall back to full screen** (stated reason: that would violate the user's choice), sets
    `lastModeError`, reports `onStatusChange(.error(reason))` **and** `onOwnUIWarning?(reason)` so the UI
    can mark the selector red, then `return` (`:549-557`).
  - `.fullScreen`: `SCContentFilter(display:display, excludingWindows: own)` with
    `excludedOwnWindowCount = own.count` (`:563-567`).

## 4.7 Own-UI exclusion audit — a deterministic invariant instead of a pixel heuristic

`static func auditOwnWindowExclusion(content:display:excludedCount:) -> String?` (`:1076-1093`).

Design reasoning (`:1058-1072`):
- The obvious check — "look at captured pixels and decide whether our own UI is in there" — was
  **deleted**; the stated principle is "宁可漏报也不能误报", because a false positive makes the user think
  recording is broken (`:1060-1061`).
- The single root cause of "we recorded ourselves" is `excludingWindows: []`, so the check asserts the
  invariant directly: in full-screen mode, if own windows really exist on screen then the exclusion list
  **must be non-empty**, and the excluded count must be ≥ the number of own windows overlapping the
  capture region (`:1063-1067`). Called a necessary-and-sufficient check that cannot false-positive and
  exactly blocks the regression "someone changed the filter back to an empty array".
- Cost: evaluated once per `start()`/`applyMode()`, not per frame, reusing the already-obtained
  `SCShareableContent`, so zero extra system calls (`:1071-1072`).

Implementation: collects `ownWindows(in: content)`, filters to `isOnScreen && frame.intersects(display.frame)`
(`:1079-1082`); returns a specific message if the list is empty while overlapping own windows exist
(`:1083-1087`), a different message if `excludedCount < overlapping.count` (`:1088-1091`), else `nil`.
`ownUIWarningFired` makes it **once per session** (`:1095-1096`), skipped entirely in window mode because
that mode inherently cannot contain own UI (`:1100`), and `resetOwnUIWarning()` re-arms it for a new
recording (`:1110-1113`).

## 4.8 Per-frame callback — what runs on the SCStream queue

`func stream(_:didOutputSampleBuffer:of:)` (`:1118-...`).

Hard rules encoded here:
1. Only `.screen` frames (`:1120`) — audio is ignored.
2. `_deepFrameCounter` increments every frame and is published as `capturedFrameCount` (`:1123-1125`).
   That public counter is what other code uses to decide "is capture alive", **independent of whether
   recording is running** (`:1124`). Probes print the first 3 frames then every 60th (`:1126-1128`).
3. **The entire per-frame body is wrapped in `autoreleasepool`** (`:1130-1133`). Reason: the SCStream
   delegate callback does not get an automatic autorelease pool, and at 30 fps the per-frame temporary
   objects (`NSImage`/`CGImage`/`CGDataProvider`/`vImage`) would otherwise accumulate, causing slow memory
   growth over long runs.
4. Timing probes: `lastFrameGapMs` uses `0` for the first frame because `lastFrameTime` starts at
   `.distantPast` and would yield ~5e11 ms of fake gap (`:1137-1144`); a `defer` records
   `lastFrameWorkMs` so **failed frames still get diagnostics** (`:1146`); `updateFPS()` (`:1147`).
5. Fan-out to four optional consumers, each gated **before** its copy:
   - `onNativeFrame` — `copyNativeFrame(from:)`, a private `CVPixelBufferPool` buffer copy that copies row
     order verbatim from `src.bytesPerRow` and does not reinterpret orientation. Reason (`:1149-1154`):
     SCStream's buffer comes from a system pool and may be recycled/overwritten if the main thread is
     slow → use-after-release (garbage crop, or crash). The main thread must own its copy so it is fully
     decoupled from the SCStream lifetime.
   - `onUpscaleFrame` — gated by `isUpscaleWanted()`, `copyUpscaleFrame(from:)` must land in a private
     buffer **with an IOSurface** or downstream `CGImage` creation crashes (cited as `MG-ENG-001`)
     (`:1159-1166`). Gate-before-copy is deliberate: when interpolation/upscaling is off there is no
     consumer, so even the full-resolution copy is skipped (`:1161-1162`).
   - `onRecordFrame` — gated by `isRecordFrameWanted()`; **the copy is synchronous on captureQueue
     (≈4 MB memcpy, sub-millisecond) but JPEG encoding and disk I/O belong to the recorder's own
     background queue** (`:1168-1176`). The comment carries the incident: doing synchronous heavy work
     on this queue previously pushed `capGap` from **11 ms to 2081 ms** (`:1172`). This is a hard
     constraint for anyone touching the recorder.
   - `onYoloFrame` — CPU `vImage` downscale to `YoloEngine.inputSize` (640) at the source, so the large
     image never goes through the `大图 → NSImage → CGImage → 再缩放` chain (`:1178-1179+`); also gated by
     `isYoloWanted()`.
6. `isUpscaleWanted`, `isRecordFrameWanted`, `isYoloWanted` are all `() -> Bool` closures evaluated per
   frame, described as "完全同款模式" (`:136-138`, `:159`, `:163`, `:179`). The engine process installs
   them so work whose consumers are mode-gated away is never done (`EngineMain.swift:1248-1254`).

Summary table of the frame fan-out (`:148` and neighbours):

| closure | resolution | gated by | consumed by |
|---|---|---|---|
| `onNativeFrame` | native copy, row order preserved | always (if set) | display path |
| `onUpscaleFrame` | true full resolution | `isUpscaleWanted()` | MetalGoose interpolation/upscale |
| `onRecordFrame` | full resolution | `isRecordFrameWanted()` | lean recorder |
| `onYoloFrame` | 640×640 CPU-scaled | `isYoloWanted()` | yolo26s / optical flow |

## 4.9 Operational invariants for this layer

- One `CaptureEngine` instance serves recording **and** autodrive; changing capture config in this file
  affects all three paths (`:514-515`).
- Never do JPEG encoding, OCR, inference, or any blocking I/O on the SCStream callback queue
  (`:1170-1172`; the 11 ms → 2081 ms incident).
- `start()` after `stop()` must await `pendingStopTask`, else "stop then select again does nothing"
  (`:452-456`).
- Frame rate is dispatched at runtime; the `CMTime(value:1, timescale:45)` seen in older code is an
  upper bound / initial value, not the operating rate — this point is stated in `EngineMain.swift:724-725`.
- Window mode never falls back to full screen on a missing window; it reports an error (`:549-556`).
- Own-window exclusion is a necessary-and-sufficient invariant (`:1063-1069`); breaking it silently
  contaminates training data (`:17-19`).
