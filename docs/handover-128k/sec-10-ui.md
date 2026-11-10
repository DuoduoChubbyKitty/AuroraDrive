# SEC-10 — UI / DriveState / TICK ORDER / PANELS / MAP WIRING

`Sources/AuroraDrive/App` — **17 files / 25,764 lines** (measured). Largest: `AuroraDriveApp.swift`
10,008, `MissionConsole.swift` 8,003, `PerfSelfTest.swift` 992, `MapSelfTest.swift` 985,
`CategoryPanel.swift` 875, `AuroraTheme.swift` 773, `MapLayers.swift` 669, `MapWindow.swift` 648,
`MapWiring.swift` 613, `RouteGraph.swift` 554, `ControlWiring.swift` 542, `RealShotSelfTest.swift` 257,
`AuroraBrand.swift` 246, `MarkerCluster.swift` 240, `MarkerTaxonomy.swift` 201, `GameHUDWindow.swift` 123,
`LocateRuntime.swift` 35.

## 10.1 The tick is the single production loop

`DriveState.tick()` at `AuroraDriveApp.swift:7568`. Both processes run **the same** `tick()`
(`:7578`), and the process is chosen by one early-return:

```swift
// AuroraDriveApp.swift:7682-7689
if EngineClient.shared.isActive {
    tickEngineMode()
    PerfBus.mark("tick.engineMode", from: perfT)
    return
}
```
`tickEngineMode()` is defined at `:7203`. Everything below the return is the **local** path (capture,
inference, control, recording); everything above it runs in **both** processes.

**Line-number drift warning**: the comment at `:7576-7577` cites the early return as `:6886`, and
comments at `:7744`/`:7750` repeat the same figure. The real line is **`:7683`** — the file has grown since
those comments were written. Reading `:6886` now lands in an unrelated observe-only block
(`AuroraFlags.observeOnly` / `controlDisabled`). Any future edit that trusts the comment will edit the wrong
place.

## 10.2 Tick order, with the reason each ordering constraint exists

Ordered facts read from the tick body (`:7568-7692`):

1. **`tickGapMs` measured first** (`:7570-7572`): `tickNow - lastTickTime` in ms, used with `capGap`/`capWork`
   to attribute latency. Comment threshold: `>33 ms` means the main thread dropped a beat or blocked
   (`:7569`).
2. **Emergency-takeover feed, gated to non-engine mode** (`:7574-7605`). Two ordering rules encoded:
   - it **must** precede the engine-mode early return, otherwise the UI process never feeds it (`:7576-7581`);
   - but in engine mode the UI process must **not** compute state locally (`:7600-7605`). Reason recorded
     (`:7588-7596`): the UI process unconditionally calls `yolopxEngine.loadIfNeeded()`, so in `ayolom` tier
     `isDegraded` is permanently true (da=0 cells, ll=0 cells; engine log 121/121). The UI instance would
     `enterSprint()` locally → `takeoverActive=true`, while the engine heartbeat reports the engine's real
     state (possibly false) and `syncFromEngine` writes false back → **the banner flickers on and off**.
     Fix: in engine mode the UI instance is a **display mirror driven by heartbeat only**; only UI-local mode
     (no engine attached) feeds locally. `tickGap` is gated together for semantic clarity (`:7598-7599`).
   - `isDegraded` is only fed when `isLoaded` (`:7602-7604`): before load `isDegraded` defaults to true
     ("no model = degraded"), but that is not "degenerated while running" and must not trigger takeover.
3. **Perf instrumentation start** (`:7607-7614`): `var perfT = PerfBus.stamp()`; `tick.total` is settled with
   `defer { PerfBus.mark("tick.total", from: perfStart) }` **specifically so every return path**
   (engine mode / standby / normal driving) is counted without restructuring branches. When `AURORA_PERF`
   is unset, `stamp()` returns 0 and every `lap` short-circuits, so the whole chain costs one static bool
   per segment (`:7608-7609`).
4. **Even/odd frame phase split** (`:7616-7637`), placed "at the very front of tick" so that the
   `inferFast` path and the slow driving path **share one phase counter** and stay in the same frequency and
   phase (`:7617-7618`):
   - `detectGateA` = yolopx three-in-one (`det/da/ll`) on even frames;
   - `detectGateB` = yolo26s (detection only) on odd frames;
   - rationale (`:7620-7622`): both stopping on the same frame creates "vacuum frames"; offsetting means at
     least one net produces ground truth every frame and boxes stay continuous.
   - **2026-10-07 user decision: the `ayolom` family is not decimated** (`:7624-7629`). The E4 original
     unconditionally gated `yolopxEngine.infer`, which also halved the *default* ayolom small model to
     15 Hz — but ayolom is measured p50 **10.4 ms** on ANE (95.9 Hz; only 31 % of a 30 Hz budget), so it
     neither needs nor deserves decimation. Hence `detectGateA` is **always true for ayolom**
     (`:7637`: `decimateFallback || isAyolom || parityEven`) and the offset applies only to legacy-tier
     yolopx + yolo26s.
   - rollback switch: `AURORA_DETECT_DECIMATE=1` makes both gates always true (`:7631`, `:7634`).
5. **yolo26s tier gate** (`:7639-7642+`): before 2026-10-19 yolo26s had **no** tier gate, so in A-model tier
   it still inferred every other frame.

Consequences that must be stated plainly: tick frequency is not "the model rate" — the tick rate is
`EngineMain.engineTickHz` (15 Hz now, SEC-03 §3.4), and within a tick the *perception nets* are further
gated by tier and by frame parity. Any timing measurement that assumes "one inference per tick" is wrong in
legacy tier and wrong for yolo26s.

## 10.3 Observe-only is enforced in the UI, not only in the engine

`AuroraDriveApp.swift:6886-6896`: `let observeOnly = AuroraFlags.observeOnly`; if set, `controlDisabled = true`
and an `[OBSERVE]` log line states "推理/定位/渲染照跑，按键注入全路径关闭". The next line is a guard that
requests Accessibility permission **or** is already `controlDisabled`.
Cross-reference: the engine narrows its TCC requirement in the same mode (SEC-03 §3.6 step 3), and
`ToolRegistry` refuses injection tools under the same flag (SEC-08 §8.6). Three independent enforcement
points for one flag — a deliberate defence-in-depth pattern.

## 10.4 `DriveState` — the one shared state object

`@MainActor final class DriveState` at `AuroraDriveApp.swift:4235-4236`. It is instantiated **once per
process**: the UI process creates it for real, the engine process creates its own copy
(`EngineMain.swift:1234`) from the same class code. That is why the `@MainActor`-only class can exist in a
process with no run loop: the engine drives it via `MainActor.assumeIsolated` inside `dispatchMain()`.

Marker sections inside `DriveState` (real lines): recording viewpoint fixed to third person
`:4712`; stuck→manual-intervention `:5892`; anti-freeze heartbeat **disabled** `:7055`; one-click training
`:7070`. `UNVERIFIED:` the full field inventory of `DriveState` was not enumerated this session; only the
sections whose behaviour is cited elsewhere were read.

Fields that other sections depend on (each verified where cited):
- `perceptionMode` — a UI-process property; nothing writes it on the engine side (SEC-03 §3.12).
- `locatorFound`, `locatorX/locatorY` — drive the map (§10.7).
- `isDriving`, `isStreaming`, `isRecording`, `mode`, `speedKmh`, `confidence` — echoed in the heartbeat
  (SEC-03 §3.7).
- `speedKmh` is **switched by process role**: `:5592` `var speedKmh: Double { EngineClient.shared.isActive ?
  remoteSpeedKmh : speedOCR.speedKmh }` — i.e. in engine mode the UI shows the engine-reported speed, not a
  local OCR result. Same pattern for detections at `:4304` (`EngineClient.shared.isActive ? remoteDetections
  : yoloEngine.detections`).
- `captureEngine.isEngineHost`, `remoteKeyMask` — the engine has no `NSEvent` source, so recorded keys come
  from the UI (`EngineMain.swift:1235-1237`).

## 10.5 UI composition tree

`MissionConsole.swift` (8,003 lines) holds the whole console as small `View` structs. Real declarations and
lines:
```
ConsoleCard       :29      CardHead        :69      TopBar         :95
BrandMark        :182      TBStat         :202      PillStat       :236
PermissionPill   :271      RCChip         :320      RCBar          :366
KeyBar           :445      MainGrid       :541      LeftColumn     :566
ViewportPanel    :584      WindowPickerRail :838    TagChip       :1139
QuestCard       :1220      RCWarn        :1421      StuckWarn     :1463
TakeoverWarn    :1524      GearRing      :1567      AutoSpeedPill :1635
DualGauge       :1709      GaugeDial     :1740      MidColumn     :1801
MiniMapCard     :1823      MiniMapCanvas :1959      MapTileStore  :2270
MapTileCache    :2367      MapBaseImageProvider :2812  MapTileImage :2862
BaseMapGrade    :2910      MapPin        :3069      MapCorner     :3091
NavLine         :3106      NavGuidance   :3171      HardwareBank  :3268
BankSwitch      :3334      LeanRecordBar :3402      PerceptionPickerCard :3551
RunLogCard      :3664
```
Live composition path for the lean-recorder button, verified end to end in an earlier session and consistent
with the declarations above: `ContentView → MainGrid → MidColumn → HardwareBank → LeanRecordBar`, with
`LeanRecordBar(state: state)` instantiated at **`MissionConsole.swift:3326`**. No conditional wrapper, no
`ScrollView`, no fixed-height clipping in that path — the reason this matters is that a previously shipped
build had the button compiled in but unreachable, and the only valid proof of presence is
`nm <binary> | grep -c LeanRecordBar` (the string table cannot see Chinese literals; `UNVERIFIED:` those
exact command results were produced in an earlier session, not this one).

### 10.5.1 ControlWiring — the "no dead buttons" principle

`ControlWiring.swift:1-15` states the contract for the whole console:
> 原则：界面上的每一个可点元素，背后都必须有一条真的执行路径。没有执行路径的，宁可不画。

Wiring list recorded there (`:8-15`): ① road-condition 4-state → `DriveState.roadCondition` (+ auto-speed
`speedLimit` linkage); ② auto-speed switch → sends `speedLimit` via engine `config`; ③ four-tier degradation
chain → `forceRuleMode` / `degradeThreshold` over the engine `config` channel; ④ speed-limit slider →
`speedLimit` (20…unlimited); ⑤ 18 skills → `AgentSkillCenter.toggleSkill(id:source:.human)`; ⑥ engine's 9
commands → `EngineClient.sendCommand`.
Note the documented mismatch with reality in one line: ③ says 「四挡降级链」 while the shipped ladder is
**three** tiers (SEC-08 §8.8, `.recover` deleted 2026-09-30). The wiring list was not updated.

## 10.6 Map wiring — coordinate transform and the invisible-matrix trap

`MapWiring.swift:1-13` gives the data chain: `CoordinateCapture` packet capture → world coords (UE5 cm) →
`worldToMapPixel()` calibrated transform → map pixels (**13056×13056**) → viewport-normalised coords →
minimap/bigmap render. All of these are **derived quantities computed on the fly, never persisted or cached**
— "定位一变地图立刻跟着动" (`:11`). When the locator is not locked, `mapPixelX/Y` return the map centre
(`:39-46`) and the caller decides display based on `locatorFound` (`:12`). The pure math functions are
`nonisolated` because callers may not be on the main thread (`:24-27`, `:29`, `:34`).

**The documented near-miss** (`MapWiring.swift:52-78`): the inverse transform must **not** reuse
`CoordinateTransform.invert` (`NetworkLocator.swift:55`) because the two are **not the same matrix**:
- `MapWiring.worldToMapPixelX`: `mapX = A·wx + B·wy + TX`
- `CoordinateTransform.apply`:    `x' = a·x − b·y + tx`
The **B term has opposite sign** (`+B` vs `−b`). Numerically `B = 5.69e-08`, which for coordinates of order
1e5 differs by only ~**0.006 px** — invisible to the eye. Therefore taking the wrong inverse **does not
reveal itself**; it merely shifts every click-set destination by a tiny, constant amount. Called out as
"看不见的错"的典型：量小、恒定、永远不崩. Hence the inverse is solved strictly from MapWiring's own equations
and paired with a round-trip selftest (`--route-selftest` asserts deviation < 0.5 px).
Derivation recorded in-source (`:70-78`):
```
mapX = A·wx + B·wy + TX ;  mapY = A·wy − B·wx + TY
dx = mapX − TX ; dy = mapY − TY
[dx]   [ A   B ] [wx]
[dy] = [−B   A ] [wy]      det = A² + B²  (A≠0 always invertible)
wx = (A·dx − B·dy) / det ;  wy = (B·dx + A·dy) / det
```

## 10.7 Map UI layer inventory

| file | lines | content |
|---|---|---|
| `MapWiring.swift` | 613 | world↔pixel transforms, viewport normalisation |
| `MapWindow.swift` | 648 | separate big-map window |
| `MapLayers.swift` | 669 | layer toggles (teleport / material / chest / oracle stone per `README.md:37`) |
| `MarkerCluster.swift` | 240 | marker clustering |
| `MarkerTaxonomy.swift` | 201 | marker categories |
| `MapSelfTest.swift` | 985 | strict map selftest (`--map-selftest`) |
| `RouteGraph.swift` | 554 | route graph (664 nodes / 932 edges per `README.md:38`) |
| `CategoryPanel.swift` | 875 | category panel |
| `LocateRuntime.swift` | 35 | locate runtime holder |

`README.md:38` asserts the route graph is `models/route_graph.json` with **664 nodes / 932 edges** and that
dead-end rate went 19.3 % → 5.4 %; the same README pins the evidence to
`AuroraDriveApp.swift:2135` plus selftest assertions at `:2139-2140`. `UNVERIFIED:` those two lines were not
re-read this session; the numbers are recorded here as README claims with their cited lines, and must be
re-derived from `models/route_graph.json` before being quoted as measured fact.

`LocateRuntime.swift:30-31` is a **dead field**: it holds a `VisualLocator` that is never
assigned, and `grep -rn "VisualLocator(" Sources/` has zero hits. `README.md:62` records that the
self-healing locate engine (`NetworkHealer`) was retired with commit `76e9027` and that
"8 种诊断 + 自动修复" has no implementation in source. The shipped behaviour is network locate plus three
freshness levels (live ≤18 s / recent ≤40 s / stale ≤90 s / lost >90 s; `recent` and older do not participate
in decisions) — cited at `README.md:56` as `AuroraDriveApp.swift:4620-4626`, `UNVERIFIED:` not re-read here.

## 10.8 Display path — MetalFX is display-only

Red line, stated in three independent places: `README.md:100-101` ("插帧/超分只作用于显示叠加层，绝不进入决策
链路"), `CaptureEngine.swift:128-130` (MetalGoose needs full frames for temporal interpolation / spatial
upscaling, served on a separate callback that does not disturb the main path), and
`AuroraDriveApp.swift:6037-6040` ("插帧/超分直通：全分辨率帧 → MetalGoose 引擎（仅显示路径）").
Mechanically this is enforced by the frame fan-out: `onUpscaleFrame` is a separate closure gated by
`isUpscaleWanted()` (SEC-04 §4.8), and the engine process installs a gate that returns false unless the UI
requested full frames (`EngineMain.swift:1248-1250`). The vendored engine is `Vendor/MetalGoose` =
5 Swift files / 2,780 lines under `Vendor/MetalGoose/Engine`, listed in `Package.swift:163-178` as excluded
from the app target except the `Engine` subtree (`Package.swift:189-192`), and `NOTICE:16-27` records it as
GPL-3.0, vendored unmodified, built as a separate target and used **only** on the display path.

## 10.9 Frame delivery into the UI — latest-frame overwrite

`AuroraDriveApp.swift:6018-6027` (field declarations): `nonisolated(unsafe) var frameDeliveryLagMs`,
`private nonisolated(unsafe) var pendingFrame: NSImage?`, `pendingFrameCG: CGImage?`. Pattern: the capture
callback publishes the newest frame, and the tick consumes the newest one each cycle, so backlog is
impossible — old frames are simply overwritten. Comment at `:7690-7692` states this and the consequence:
when the main thread cannot keep up, the intermediate frames are dropped rather than queued.
`frameDeliveryLagMs` exists to make that visible instead of invisible.

This is the same "overwrite = natural frame skip" design used by the engine's full-frame slot
(`EngineMain.swift:1243-1247`, lock-protected single slot) — one pattern, two processes.

## 10.10 Panels and their contents (structural facts only)

- `ViewportPanel` `:584` is the preview frame; `WindowPickerRail` `:838` is the pull-out window list that
  drives capture mode selection (`CaptureEngine.CapturableWindow`, SEC-04 §4.2). Rationale for the rail is
  the user quote in `CaptureEngine.swift:10-15`: a small slider to the right of the preview that pulls out the
  current window list and lets the user choose "full screen" or "only this game window".
- `HardwareBank` `:3268` is the bank containing `BankSwitch` `:3334` and `LeanRecordBar` `:3402` — the lean
  recorder's long flat button, one of five per the design record (the 5th being this one).
- `KeyBar` `:445` renders live key state from `KeyboardMonitor`/`ControlEngine.heldKeys`; `GearRing` `:1567`,
  `DualGauge` `:1709`, `GaugeDial` `:1740`, `AutoSpeedPill` `:1635` are instrumentation.
- Warnings are their own views rather than ad-hoc text: `RCWarn` `:1421`, `StuckWarn` `:1463`,
  `TakeoverWarn` `:1524` — matched to the state machines that raise them (`EmergencyTakeover`,
  `DegradeStateMachine` stuck detection).
- `RunLogCard` `:3664` is the log surface; logs are also mirrored to files with size caps
  (SEC-03 §3.13) because a GUI process's stdout is usually buffered.

## 10.11 Theme / brand

`AuroraTheme.swift` (773) and `AuroraBrand.swift` (246) hold the visual system and the brand layer. The brand
rule that crosses into other files: the upstream name `MaaNTE` may appear in **source comments** as
provenance for the key table but must never appear in user-visible strings or identifiers
(`ControlEngine.swift:4-16`, SEC-07 §7.7.7). `PrivilegePill` (`Core/PrivilegePill.swift`, 472 lines) is the
in-app password + `sudo -S` escalation UI, deliberately replacing native authorisation dialogs
(SEC-07 §7.7.4).

## 10.12 Selftests that cover this layer

`--map-selftest` (985-line `MapSelfTest.swift`), `--route-selftest` (also asserts the inverse-transform
round-trip < 0.5 px, §10.6), `--mc-map` / `--mc-shot` / `--mc-route` / `--mc-quest` / `--mc-map-bench`
(headless `ImageRenderer` captures; must run **before** the run loop or they hang — SEC-07 §7.5.10),
`--agent-ui-shot` / `--agent-layout-shot`, `--tick-profile` / `--tick-bench`, `--perf-selftest`,
`--realshot-selftest`, `--wire-selftest` (engine config channel), `--flags-help`.
`--mc-shot` and `--mc-map` are dispatched at `AuroraDriveApp.swift:787-795` synchronously, and `--mc-map`
renders via `MissionControlShot.renderMapNow()` with `exit(ok ? 0 : 1)`.

## 10.13 UI-layer pitfalls (all sourced)

1. **Engine-mode early return sits above all local work** (`:7682-7689`) — anything that must run in engine
   mode has to be placed **above** it; anything placed below is silently UI-only. Two comments in the file
   exist purely to record bugs caused by getting this wrong (`:7576-7581`, `:7744-7750`).
2. **Comments cite stale line numbers** (`:7576` says `:6886`, real is `:7683`). Treat in-file line
   references as hints, re-grep before editing.
3. **Feeding takeover state locally in engine mode caused banner flicker** (`:7588-7596`) — the UI must be a
   heartbeat mirror in engine mode.
4. **`isDegraded` defaults to true before load** (`:7584-7586`) — feeding it ungated would continuously
   trigger takeover on a fresh process.
5. **A default small model was being decimated for no reason** (`:7624-7629`) — ayolom is 10.4 ms p50 against
   a 66.7 ms budget; the "save budget" instinct was wrong and the user overruled it.
6. **The inverse transform is not the inverse of the other class's transform** (`MapWiring.swift:52-78`) —
   sign difference is invisible at 0.006 px and never crashes.
7. **Wiring list says four degradation tiers while three ship** (`ControlWiring.swift:8-15` vs
   `DegradeStateMachine.swift:5-9`).
8. **A button can be compiled in and still unreachable** — the only valid presence proof is symbol presence
   in the deployed binary (`nm | grep -c`), not string search, because Chinese literals do not land in the
   string table.
9. **Headless render must precede the run loop** (`:787-790`, measured 240 s hang).
