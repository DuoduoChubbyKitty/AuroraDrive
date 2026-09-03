# 5. Control & Safety

> Sources: `ControlEngine.swift`(236) `KeyboardMonitor.swift`(113) `RuleController.swift`(185) `EscapeController.swift`(217) `DegradeStateMachine.swift`(250)
> Up: [Developer Guide](../../DEVELOPER_GUIDE.en.md) ｜ 中文: [控制与安全子系统](../05-control-safety.md)

## 5.1 Key injection (ControlEngine)

**The event source is the linchpin of this subsystem** (comment at :74-84): `CGEventSource(stateID: .hidSystemState)`. The project tried `.combinedSessionState` — the UI key indicator lit up but the game didn't move; `.privateState` is rejected by the game's input layer. Only HID-level events are read by NTE.

**Injection** (`postKeyEvent`, :199-222):

```swift
let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown)
event.post(tap: .cghidEventTap)     // inject at the hardware event layer
```

The autorepeat field is deliberately NOT set — the game only honors "fresh press" semantics; holding is simulated by `refreshHeldKeys` re-sending keyDown every tick (30Hz).

**Keycodes** (KeyMap, :37-56): W=13 / S=1 / A=0 / D=2 / Space(handbrake)=49 / LeftShift(nitro)=56.

**Actions**:

| Function | Behavior | Detail |
|---|---|---|
| `press` | down → usleep 50ms → up | default single-press rhythm |
| `hold` / `release` | hold / release a key | hold de-dupes presses; release validates heldKeys |
| `refreshHeldKeys` | re-send keyDown for all held keys | called every 30Hz tick to sustain "held" semantics |
| `releaseAll` | unconditionally keyUp all 6 keys | anti-stuck-keys on stop/tier change |

**Permission**: `AXIsProcessTrustedWithOptions` (with `kAXTrustedCheckOptionPrompt` to pop the grant dialog). press/hold/refreshHeldKeys guard on permission; release/releaseAll run unconditionally (you must always be able to let go).

## 5.2 Keyboard monitor (KeyboardMonitor)

`NSEvent.addGlobalMonitorForEvents` for global keyDown/keyUp (:50, :57). `:51`'s `guard !event.isARepeat` matters: it filters system autorepeat, otherwise hold duration keeps resetting to ~50ms.

**Honest note**: this module serves three things only — the UI key bar, hold-duration stats, and `clearAll`. **There is no "press ESC to emergency stop" hook anywhere in the code**; the emergency stop is `stopDriving()` (releaseAll + pause inference).

## 5.3 Rule controller (RuleController) — YOLO detections → control

Translates YOLO detection boxes into driving actions with zero model inference.

**Detection** (:27-68): danger zone `|x - 0.5| < 0.18 && y > 0.45` (lower-center band); `urgency = clamp(area × 8 × centrality)`.

**decide() table** (:114-160):

| Scenario | steer | throttle | brake | confidence |
|---|---|---|---|---|
| No obstacle (cruise) | 0 | 0.8 | 0 | 0.8 |
| urgency > 0.55 (hard brake) | ±1.0 | 0 | 1.0 | obstacle confidence |
| urgency > 0.25 (slow & avoid) | ±1.0 | 0.2 | 0.6 | same |
| Otherwise (gentle avoid) | ±0.5 | 0.6 | 0.1 | same |

**fuse()** (:167-184) for the `.rule` tier: safe → pure E2E; caution → steer averaged, confidence ×0.9; danger/critical → rule fully overrides.

## 5.4 Stuck recovery (EscapeController)

Three-phase loop: **reverse 1.5s → counter-turn 0.8s → forward 2.0s**, total timeout 15s; success when speed > 8 km/h during the forward phase (:59-71).

- `enter()` picks left/right randomly (`Bool.random()`)
- `update(dt:speedKmh:)` advances phases; timeout returns `(confidence 0.3, escaped=false)`
- Phase confidence is a constant 0.3 (signals the state machine this is a low-confidence maneuver)
- Output type `ControlCommand` (:28-44, includes `idle`) is the shared control format for Rule/Escape

## 5.5 Degrade state machine (DegradeStateMachine)

`update()` is a 9-parameter pure function (`@discardableResult`), main-thread only.

**Thresholds**: degrade 0.65, hysteresis 0.15 (recover 0.80), stuck speed 3.0 km/h, stuck time 3.0s, recovery timeout 30s.

**Priority chain**: `forceRule` > `sportMode` > `warmingUp` > stuck detection > health ladder.

**stuckSeconds timing**: frozen when `speedValid=false`; accumulates real elapsed time below 3 km/h; decays at 2× (cleared in 0.5s) once the car moves.

## 5.6 Safety net overview

| Risk | Defense |
|---|---|
| Stuck keys | `stopDriving()` → `releaseAll()`; keys released on tier change |
| Runaway | `forceRule` one-key rule mode; `stopDriving` always available |
| Stale-frame decisions | pendingFrame keeps only the newest frame + generation discards in-flight writes |
| Decisions consuming display frames | architecture red line: MetalFX on the overlay only (Level-3 doc 4) |
| Broken stuck detection | speed comes from real CNN readings; unreadable speed freezes the timer instead of mis-triggering |
| Hysteresis oscillation | recover 0.80 > degrade 0.65 — a 0.15 buffer band |
