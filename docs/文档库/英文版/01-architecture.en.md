# 1. Architecture Overview

> Sources: `AuroraDriveApp.swift`(4379) `DegradeStateMachine.swift`(250)
> Up: [Developer Guide](DEVELOPER_GUIDE.en.md) ｜ 中文: [系统架构总览](../自动驾驶与功能/01-architecture.md)

> **Archive note (verified 2026-09-19, baseline 7b7d2db)**: `AuroraDriveApp.swift` grew from 3276 to 4379 lines; `NetworkHealer` was removed (76e9027 — network localization is now a lazy `CoordinateCapture` init, no self-healing engine); a new "engine mode" was added (`EngineClient`/`EngineMain`: a background engine process, the UI only forwards commands).

## 1.1 Engine inventory (DriveState)

`DriveState` is an `@Observable @MainActor final class`; engines are plain `let` constants (`@ObservationIgnored` is used for hot internal state such as pendingFrame/pendingYoloFrame/pendingNativeFrame (plus `nonisolated(unsafe)`) and the localization fields coordinateCapture/locateCtx/locateGate; the old healer field was removed together with NetworkHealer):

| Field | Engine | Model / role |
|---|---|---|
| `captureEngine` | CaptureEngine | ScreenCaptureKit 30fps |
| `controlEngine` | ControlEngine | CGEvent key injection |
| `keyboardMonitor` | KeyboardMonitor | global key listener |
| `degradeStm` | DegradeStateMachine | 4-tier degrade |
| `recordEngine` | RecordEngine | recording (training data) |
| `escapeController` | EscapeController | stuck recovery |
| `ruleController` | RuleController | YOLO→rule control |
| `confidenceEst` | ConfidenceEstimator | E2E confidence estimate |
| `inferenceEngine` | InferenceEngine | m9_mono (tier 1) |
| `assistEngine` | InferenceEngine("game_assist_control") | tier 2 |
| `yoloEngine` | YoloEngine | yolo26s |
| `speedOCR` | SpeedOCRReader | speed CNN |
| `coordinateCapture` | CoordinateCapture | network localization (lazy init inside `runNetworkLocateStep`, 10Hz poll; no self-healing — healer removed) |

## 1.2 Thread model

| Queue/thread | QoS | Rate | Duty |
|---|---|---|---|
| Main thread | — | event-driven | SwiftUI render, state write-back |
| `com.aurora.tick` | userInteractive | **30Hz** | `state.tick()` main loop (DispatchSource) |
| `com.aurora.netlocate` | userInteractive | **10Hz** | `runNetworkLocateStep()` |
| `com.aurora.coordinate-capture` | default | blocking | `pcap_next_ex` capture loop |
| `com.aurora.inference` | userInitiated | ~24Hz | E2E/YOLO inference (serial, no overlap) |
| `com.aurora.confidence.brightness` | background | on demand | brightness probe |

**Key design**: the main loop uses `DispatchSource.makeTimerSource` instead of `Timer` — a `Timer` on the main RunLoop gets squeezed to 8Hz by App Nap; a DispatchSource on its own queue is immune:

```swift
let timerQueue = DispatchQueue(label: "com.aurora.tick", qos: .userInteractive)
let timer = DispatchSource.makeTimerSource(queue: timerQueue)
timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .nanoseconds(0))
timer.setEventHandler { DispatchQueue.main.async { state.tick() } }
```

## 1.3 Six App Nap countermeasures (applicationDidFinishLaunching)

| Lock | Implementation |
|---|---|
| 1 Disable auto-termination | `disableAutomaticTermination` |
| 2 Suppress App Nap | `beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])` → hold `napToken` |
| 3 Highest priority | `setpriority(PRIO_PROCESS, 0, -20)` |
| 4 CGEventTap | `.listenOnly` empty tap on RunLoop → system sees real-time input handling |
| 5 Memory anchor | 768MB page-by-page touched + `mlock` (held as `memoryAnchor`) |
| 6 Main-thread RT constraint | `THREAD_TIME_CONSTRAINT_POLICY`, period≈33.3ms (`applyMainThreadBoost`; `gameModeBoost` defaults true) |

## 1.4 BPF permission auto-install

On launch, `access("/dev/bpf0", O_RDWR)` is probed; if unavailable and no LaunchDaemon is installed, `showBPFPasswordSheet = true` pops the in-app password sheet. The password drives `BPFSetupManager.install()` which uses osascript with admin privileges to deploy `/usr/local/bin/aurora-bpf-setup.sh` (`chmod 666 /dev/bpf*`) plus `/Library/LaunchDaemons/com.aurora.bpf-setup.plist` (RunAtLoad) — enter once, restored at every boot. Details in Internals.

## 1.5 Four-tier degrade state machine

**DriveMode**: `e2e` / `yolo` / `recover` / `rule`. **DriveModeGroup** merges them into two user-visible tiers: `e2eDrive` ([e2e, yolo]) and `ruleFallback` ([recover, rule]).

**Thresholds**: degrade 0.65, recover 0.80 (hysteresis 0.15), stuck 3.0 km/h for 3.0s, recovery timeout 30s.

**Priority**: `forceRule` > `sportMode` > `warmingUp` > stuck detection > health ladder.

```
e2e  --(!m9Live || health<0.65)-->  yolo
yolo --(!assistLive || health<0.65)-->  rule
yolo --(m9Live && health>0.80)-->  e2e
rule --(assistLive && health>0.80)-->  yolo
*    --(stuckSeconds≥3.0)-->  recover
recover --(speedValid && speed>6.0)-->  e2e   |   --(30s)-->  rule
```

**stuckSeconds details**: frozen when `speedValid=false` (neither accumulates nor clears); accumulates with real elapsed time at low speed; decays at 2× (cleared within 0.5s) once the car moves.

> ⚠️ Comment/code mismatch: the localization timer comment says "4Hz" but the code schedules 10Hz — the code wins.

## 1.6 Lifecycle

- **Engine mode first**: when `EngineClient.shared.isActive`, `startDriving()`/`stopDriving()` only forward start/stop commands to the background engine process (`EngineMain`); the UI does not start the local capture/inference/injection chain (`remoteDetections`/`remoteSpeedKmh` stream back to the UI)
- `startDriving()` (local mode): permission check (opens Accessibility settings on failure) → `releaseAll()` (anti-stuck-keys) → `isDriving=true` → keyboardMonitor.start → captureEngine.start → three models `loadIfNeeded()` (inferenceEngine m9_mono / assistEngine game_assist_control / yoloEngine yolo26s; the speed-OCR dual models load at SpeedOCRReader construction)
- `stopDriving()`: `releaseAll()` → inference paused
- `--auto-drive` CLI: unattended end-to-end self test
- Localization is a side-channel: `runNetworkLocateStep()` (10Hz) only feeds the map display — **driving consumes frames, not map coordinates**, so localization being down never affects driving
