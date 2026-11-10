# SEC-12 — LOCATE / MAP / CONTROL INJECTION / KEY SEMANTICS / SAFETY

Sources: `Capture/CoordinateCapture.swift` (1811), `Locate/NetworkLocator.swift` (668),
`Locate/VisualLocator.swift` (491), `Control/ControlEngine.swift` (718),
`Control/KeyboardMonitor.swift` (231), `Control/MouseController.swift` (219),
`Control/EscapeController.swift` (44), `Core/GameModeDefender.swift` (217),
`Core/BPFSetup.swift` (134), `Core/PrioritySetup.swift` (74), `Core/PrivilegePill.swift` (472),
`Perception/*` (620).

## 12.1 Network locate — ported code with a licence obligation

`CoordinateCapture.swift:4-18` is an explicit provenance block that must not be removed:
- The file is **ported wholesale from the upstream open-source project MaaNTE's
  `nte_coordinate_api.py` (AGPL-3.0)**.
- Both reasons are stated as hard: **AGPL-3.0's attribution obligation** means removing the provenance is a
  licence violation (`:11-13`); and the port-30031 filter, the `kCalibA/B/TX/TY` constants are
  "upstream-measured + our re-measurement" conclusions that cannot be re-verified once the provenance is
  gone (`:13-16`).
- Same brand rule as elsewhere: provenance retained in comments; brand-visible strings/identifiers must not
  contain the upstream name (SEC-07 §7.7.7).

Mechanism: libpcap capture → UE5 movement-packet parse → world coordinate + heading
(`CoordinateCapture.swift:19-20`). C bindings are `@_silgen_name` declarations:
`pcap_open_live` (`:37-38`), `pcap_compile` (`:40-41`), `pcap_setfilter`; `libpcap` is linked via
`Package.swift:207` (`.linkedLibrary("pcap")`), and its presence check has the dyld-cache caveat
(SEC-02 §2.1.2).

Filter and port: `tcp port 30031 or udp` (`:12`), `pcap_open_live` at the real call site. `README.md:47`
pins the call to `CoordinateCapture.swift:1052` and the filter to `:1100`. **`UNVERIFIED:`** those two exact
lines were not re-read this session; the port/filter text and the `pcap_open_live` symbol are confirmed, the
line numbers are README claims.

Calibration constants (`:112-115`) — these are the transform between UE5 world centimetres and map pixels:
```
kCalibA  = 0.016394586684750773
kCalibB  = 5.693519256055879e-08
kCalibTX = 6526.474380746091
kCalibTY = 5210.664390686138
```
Base map: `map-2026-08`, MaaNTE-Map **13056×13056** expanded edition, upgraded 2026-09-13 (`:106`).
Cross-reference: `MapWiring.swift:8-12` consumes exactly this chain and notes that the inverse transform is a
**different matrix** with an opposite B sign (`MapWiring.swift:52-78`, SEC-10 §10.6).

## 12.2 A refuted hypothesis whose evidence is retained

`CoordinateCapture.swift:301` records that on **2026-09-25** the project concluded that the 30031 S2C
76-byte packet was protobuf-encoded; that conclusion is now marked **被推翻** (refuted). The replacement
explanation and the packet-layout work sit around `:301-320`, which also notes that a `port 30031` filter had
been keeping UDP 30212 entirely outside the capture window (`:315`).
Why this matters beyond archaeology: the filter string is not incidental — narrowing to the wrong predicate
silently discards the packets that actually carry position, and the visible symptom would be "locating works
sometimes".

## 12.3 Traffic is bursty — NIC probing takes many rounds

`CoordinateCapture.swift:704` — measured with `tcpdump` over a 30 s sample while the game was running: port
30031 traffic is **bursty**, not steady. Further measured facts:
- `lsof` shows `30031 ESTABLISHED` and `tcpdump -i en8 port 30031` does capture, yet a 3-second probe window
  can find nothing (`:718-722`).
- The project measured **23 consecutive probe rounds at 14:15–14:16 all reporting "均无 30031 流量"** (`:753`),
  i.e. a short probe cannot distinguish "wrong NIC" from "quiet moment".
- Consequences recorded: a missing/failed capture path leaves the whole column blank, which is exactly why the
  recorder dropped position columns (SEC-05 §5.3) and why BPF permissions are installed up-front
  (`Core/BPFSetup.swift`, `:90-99` documents the retired native-authorisation path).

## 12.4 Locate freshness — four tiers, and why 18 s

`CoordinateCapture.swift:1738` defines `enum PoseTier` (cases `:1739-1742`):
```
case live      // ≤ liveWindow (default 18s)  : full function
case recent    // ≤ recentWindow (default 40s ≈ 2–3 periods) : UI normal, decision down-weighted
case stale     // ≤ staleWindow (default 90s) : UI marks "stale", decisions do not trust it
case lost      // > staleWindow : UI marks "no locate"
```
Thresholds: `poseFreshWindow = 18.0` (`:848`), `poseRecentWindow = 40.0` (`:1747`, ≈2.6 × 15 s periods),
`poseStaleWindow = 90.0` (≈6 periods). `.live` is **exactly** the pre-existing `poseFreshWindow` so old
behaviour is preserved verbatim while two wider tiers are added (`:1747-1748`).

Why 18 s and not 12 s (`:818`, `:842-846`): the game's **real coordinate period is 15 s** (2026-09-30 final
measurement), so a 12 s window expired on every cycle and produced **location flicker**; 18 s = 15 s period +
3 s margin, and 18 s is only 3 s more than 15 s so the "stale position" perception impact is negligible.
The tier system removed the flicker without creating "ghost positions", because `stale`/`lost` are
down-weighted, `lost` is explicitly labelled "no locate" in the UI, and the `hasRecentTraffic` pre-gate
remains (`:1735-1738`).

API: `readWithTier(live:recent:stale:) -> (tier, pose?, ageSeconds?)` (`:1753`), lock-protected, returning
`.lost` with nil pose only when there has never been a sample.

## 12.5 Two dead classes — verified zero instantiation

Measured this session:
```
grep -rn "NetworkLocator(" Sources/ | grep -v 'class |//'   → 0 hits
grep -rn "VisualLocator("  Sources/ | grep -v 'class |//'   → 0 hits
```
`Locate/NetworkLocator.swift` (668 lines) and `Locate/VisualLocator.swift` (491 lines) **compile but are never
instantiated**. `LocateRuntime.swift:30-31` holds fields that are never assigned.
`README.md:62` records the history: the self-healing locate engine `NetworkHealer` was retired with commit
`76e9027`, and the "8 kinds of diagnostics + auto-repair" claim has **no implementation** in source, so the
README deleted the whole feature line rather than keep an unverifiable claim.
The shipped behaviour is network locate + the four-tier freshness model above (`README.md:64`).
Operational consequence: do not "wire up" `NetworkLocator` thinking it is missing — it was deliberately
superseded, and `VisualLocator`'s `CoordinateTransform.invert` is explicitly **not** interchangeable with the
map inverse (SEC-10 §10.6).

## 12.6 Key semantics — the user-authoritative contract

Key codes (`ControlEngine.swift:48-53`):
```
throttle   = 13   // W
brake      = 1    // S
steerLeft  = 0    // A
steerRight = 2    // D
handbrake  = 49   // Space
boost      = 56   // Left Shift
```
`Action` enum (`:34-40`): `throttle`, `brake`, `steerLeft`, `steerRight`, `handbrake` (+ boost mapping).
Semantics (user-confirmed, recorded at `KeyboardMonitor.swift:111-112` and encoded in `dataset_v3`):
| gesture | meaning |
|---|---|
| Shift | **handbrake** |
| Space | normal brake |
| Shift+Space (short press) | super brake |
| Shift+Space (long press) | ultimate brake |
| S alone | reverse |
| S during ultimate braking | anti-rollover |
This table is why the training targets are Boolean functions of atomic keys
(`dataset_v3.py:15-18`, SEC-11 §11.2) — `handbrake=shift`, `brake=space`, `super_brake=shift∧space`,
`ultimate=shift∧space∧s`.
**The dangerous overlap**: in this game `brake` **is the S key, which is also reverse** — recorded as the
cause of a real incident where the ego-box fallback output `brake 0.8` and the car kept braking *and*
reversing (SEC-08 §8.10, `EgoBoxFilter.swift:12-17`).

## 12.7 Injection layer — three independent constraints

`ControlEngine.swift:183-198`: the event source must be `.hidSystemState`, and the tap `.cghidEventTap`.
Measured basis: the target game's input layer reads only the HID system state layer;
`.combinedSessionState` is ignored by the game even though system UI reacts; `.privateState` is banned.
`ControlEngine.swift:504-507`: `autorepeat` must stay `false` because the game ignores auto-repeat events and
only accepts "new key down".
`MouseController.swift:10-19`: identical strategy — `CGEventSource(stateID: .hidSystemState)` and
`.cghidEventTap` — with a coordinate warning recorded from a near-miss:
- CGEvent mouse coordinates are **global display coordinates in points**, origin at the **main display's
  top-left**, y growing downward — same orientation as screenshot pixels, differing only by
  `backingScaleFactor` (2× on Retina);
- `NSScreen.frame` uses **bottom-left AppKit coordinates** — the two must not be mixed;
- conversion: `CGEvent point = screenshot pixel / backingScaleFactor` (main display case).

Hold/press/release bookkeeping (`:361-390`): `press` posts down then up; `hold` is idempotent via
`guard !heldKeys.contains(keyCode)` before posting down and inserting; `release` only posts up if the key is
in `heldKeys`; every entry point guards `hasAccessibilityPermission` (`:357`, `:371`).
`releaseAll()` (`:436-443`) unconditionally posts key-up for **all six mapped keys** and clears the set — it is
deliberately not conditional, because it also carries the safety duty of clearing **system-level stuck keys
left by a previously crashed process** (`:468-471`). The throttled per-tick variant `releaseAllIfNeeded()`
(`:486-496`) skips redundant sweeps when nothing is held and a sweep happened within the last second, without
changing `releaseAll` semantics (SEC-07 §7.4.6).

## 12.8 Control output type — the only survivor of the escape tier

`EscapeController.swift:8-14`: the file now contains **only** the public `ControlCommand` type —
`steer[-1,1] + throttle[0,1] + brake[0,1] + confidence[0,1]` — the unified output of the two remaining
decision sources (`E2E` / `Rule`), which `DriveState` maps to `ControlEngine` key injection (`:9-10`).
`EscapeController` itself was deleted on 2026-09-30 at the user's request: the escape tier compressed speed and
could not exit, so autodrive survived only ≈**12 s** before being interrupted by the escape loop (`:11-13`);
its timeout protection was removed with it.
`RuleController.swift:157` and `:164` define the rule tier's discipline: **steer only, throttle only, never
brake automatically**; emergency avoidance = no throttle + full opposite steer, `b` always 0, never reverses
on its own.

## 12.9 Game Mode suppression — measured, and countered in two ways

`GameModeDefender.swift:4-18`. Measured 2026-09-13: after the game enters full-screen Game Mode, AuroraDrive's
auxiliary frame rate holds ~30 fps for about **40 s**, then `gamepolicyd` suppresses it to single digits. The
lesson recorded: a one-off setup at launch (nice value, activity assertion) is **not enough** — it is
progressively suppressed.
Two complementary measures:
1. **Silent audio (the `audible` dimension)** (`:8-15`): Apple documents "it isn't audible" as one of App
   Nap's criteria, and audio playback is an independent exemption; Game Mode plausibly uses the same
   dimension. The CoreAudio audio thread runs at **realtime priority without root**, which bypasses the
   earlier blocker "realtime threads need root". Implemented as an `AudioQueue` loop emitting zero samples;
   it needs no `NSApplication`, so the **engine process can use it too**.
2. **Persistent re-assertion** (`:16-18`): re-claim every 3 s rather than once.
Engagement: `GameModeDefender.shared.start()` at `EngineMain.swift:1157-1159`, with the stated reason that the
engine is the process doing detection and therefore needs the audible dimension and continuous re-assertion
most.
Related: `ProcessInfo.beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])` plus
`setpriority(PRIO_PROCESS, 0, -20)` in the engine (`EngineMain.swift:1161-1168`, SEC-03 §3.6).

## 12.10 Privilege escalation — in-app only, one action only

`PrivilegePill.swift:1-28`: never use macOS native authorisation dialogs
(`do shell script ... with administrator privileges`) — repeated permission prompts get the app flagged as
suspicious, which harms an open-source project's reputation (`:9-13`); instead an in-app glass dialog takes
the password and escalates silently in the background via `sudo -S` (password on **stdin**, because argv is
visible to `ps`; the old implementation put it into an AppleScript string = plaintext in process arguments,
`:20-23`). Passwords are never hardcoded (the old `"123456"` "发布版必然失效且是安全隐患", `:18-19`), live only
in memory, are cleared after use, never written to disk or logs, and escalation is strictly limited to
installing one LaunchDaemon script (`:24-28`).
Both legacy native-auth entry points are `@available(*, deprecated)` and **return failure immediately**:
`BPFSetup.swift:96-99`, `PrioritySetup.swift:53-58`.
`AuroraFlags.swift:146-151`: the LLM API key is likewise "绝不打印、绝不落盘"; the GUI path stores user keys in
a local mode-0600 notebook (`AgentSettings.swift:14-17`).

## 12.11 Safety invariants — consolidated

Because this list is the part a maintainer must never break, it is restated here as one block with pointers:

1. **Every exit path releases all keys before exiting**; SIGKILL is a last resort precisely because it loses
   that guarantee. `EngineMain.swift:20`, `:2377-2394`; `EngineClient.swift:1058-1062`.
2. **Observe-only (`AURORA_OBSERVE_ONLY=1`) refuses all injection** at three independent layers: engine TCC
   predicate narrowed to screen-only (`EngineMain.swift:1132-1138`), UI `controlDisabled=true`
   (`AuroraDriveApp.swift:6886-6896`), and `ToolRegistry` guard ① (`ToolRegistry.swift:26-27`, `:405`).
   Even if injection were attempted, `ControlEngine.hold()`'s permission guard returns early
   (`EngineMain.swift:1136-1138`).
3. **No injection without Accessibility permission**, and the permission query must never prompt on the hot
   path (`ControlEngine.swift:210-232`, SEC-07 §7.4.5).
4. **Handover/engine restart is refused while driving** — losing the engine mid-drive is more dangerous than a
   protocol mismatch (`EngineClient.swift:344`; the handover pair in SEC-03 §3.9).
5. **Recorded keys must be released, not inferred**: the engine has no `NSEvent` source, so it uses the
   UI-forwarded `remoteKeyMask` (`EngineMain.swift:1235-1237`).
6. **Stuck detection is independent of the model** — the car not moving triggers intervention even if the
   model is confident (`DegradeStateMachine.swift:12-13`).
7. **Fallbacks are fail-open and bounded**: never guess a direction, never full throttle, require N-frame
   confirmation, discard sudden jumps (`LaneFallback.swift:10-18`; `FallbackGuard.swift:26-31`;
   `MotionPredictor.swift:29-33`; `LaneBridge.swift:168-176`).
8. **Rule tier never brakes automatically and never reverses on its own** (`RuleController.swift:157`, `:164`).
9. **Recording must never be corrupted silently**: CSV row ⇄ image pairing, no `speed_kmh=0`, no name-collision
   reuse, stop with an explicit reason on frame-rate breach (SEC-05 §5.4, §5.8–5.9).
10. **Permissions are inherited through the process chain**, and TCC self-check fails fast at startup
    (`EngineMain.swift:107-1155`, exit code 2).
11. **Never click anything labelled login globally**, to avoid clicking another app's login button
    (`AIAgentPanel.swift:703`); never press F1–F12 because the game cannot receive macOS system function keys
    (`AIAgentPanel.swift:305`).
12. **No synthetic network traffic, no proxy pools, no CAPTCHA evasion**; search tools fail honestly
    (`WebSearch.swift:31-36`, SEC-07 §7.7.5).

## 12.12 Cross-process role switching that affects control interpretation

Two values change meaning depending on which process is asking, both verified:
- `speedKmh`: `AuroraDriveApp.swift:5592` — `EngineClient.shared.isActive ? remoteSpeedKmh : speedOCR.speedKmh`.
- `detections`: `:4304` — `EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections`.
So a UI-side reading of either field reflects the **engine's** answer whenever an engine is attached, not a
local computation. Any bug report of the form "the UI shows a different speed than the numbers in the log"
must first establish which process produced each number.

## 12.13 Open items for this subsystem

1. Real-gameplay validation of locating + control end to end was never exercised in this session;
   `recordings/` is 0 B and the last recorded note states `data/raw_clips` and `clips` were empty.
2. NIC auto-selection under bursty 30031 traffic is measured as needing many rounds; a fast probe is not
   sufficient (`CoordinateCapture.swift:704-753`).
3. `NetworkLocator` / `VisualLocator` remain compiled dead code with zero instantiation — a deliberate
   supersession, but any future re-enable must first reconcile `CoordinateTransform` with the map inverse.
4. The 30031 packet-format conclusion was refuted once already (`:301`); treat the current explanation as
   measured but re-checkable.
5. `brake` == `S` == reverse remains an inherent hazard of this game's key layout; any component that emits
   `brake` must be reviewed for whether it actually wants to reverse (the ego-box incident is the precedent).
