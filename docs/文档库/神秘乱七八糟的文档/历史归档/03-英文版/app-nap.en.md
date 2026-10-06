# Internals · App Nap Countermeasures

> Implemented in `AuroraDriveApp.swift`, `AppDelegate.applicationDidFinishLaunching`
> Up: [Architecture Overview](01-architecture.en.md) ｜ 中文: [App Nap 对抗](../自动驾驶与功能/app-nap.md)

## 1. Problem

macOS applies App Nap to windows it considers idle: lower CPU priority, squeezed timers (`Timer` drops from 30Hz to 8Hz). This app lives in the background with its window covered by the fullscreen game — the classic Nap target — while the driving decision chain runs on that timer. Timer frame drops = delayed steering output.

## 2. Six locks (applicationDidFinishLaunching)

### Lock 1: disable auto-termination (`disableAutomaticTermination`)

Stops the system from auto-terminating the "idle" app under memory pressure.

### Lock 2: suppress App Nap (`beginActivity`)

```swift
ProcessInfo.processInfo.beginActivity(
    options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled],
    reason: "...")
```

The returned token is held in `napToken` — releasing it deactivates the assertion, so it must be held for the app's lifetime.

### Lock 3: highest process priority (`setpriority`)

```swift
setpriority(PRIO_PROCESS, 0, -20)   // nice=-20, the user-land maximum
```

### Lock 4: CGEventTap real-time protection

A `.listenOnly` **empty tap** added to the RunLoop: holding an HID event listener makes the system consider the process as actively handling input, so it won't freeze it. Handle held as `eventTap`.
> Note the distinction: this tap is for keep-alive; `ControlEngine`'s injection (posting via `.cghidEventTap`) is for keys — two different mechanisms.

### Lock 5: 768MB mlock memory anchor

```swift
let allocSize = 768 * 1024 * 1024        // 196,608 pages
for i in 0..<pageCount {                 // touch the first byte of every page
    buf.advanced(by: i*4096).storeBytes(of: UInt8(i & 0xFF), as: UInt8.self)
}
mlock(buf, allocSize)                    // lock into physical RAM
```

- **Touching every page is mandatory**: macOS allocates pages lazily — untouched pages occupy no physical memory and mlock would lock nothing
- **Why 768MB**: empirically tuned — macOS is extremely conservative about freezing/evicting "large-memory + mlock" processes; small processes get killed freely. **Do not shrink**

### Lock 6: main-thread real-time constraint (`applyMainThreadBoost`)

`THREAD_TIME_CONSTRAINT_POLICY` with period≈33.3ms (30Hz). Invoked by `setGameModeBoost`; `gameModeBoost` defaults to true.

## 3. Timer choice (companion)

The main loop uses `DispatchSource.makeTimerSource` (`com.aurora.tick`, 30Hz) instead of `Timer`: its own queue + `userInteractive` QoS + `leeway: .nanoseconds(0)` (rejects timer coalescing).

## 4. How to verify

1. Launch the app, start driving
2. Cover the app window with the fullscreen game
3. `tickGapMs` should stay at ~33ms (not Napped)
4. Control experiment: comment out the six locks, rebuild — tick drops to ~8Hz fullscreen

## 5. Cost

| Cost | Magnitude | Verdict |
|---|---|---|
| Resident physical memory | 768MB+ | acceptable on 16GB; buys a decision chain that never freezes |
| CPU priority pressure | tiny (tick is lightweight) | game FPS unaffected (GPU-bound) |
| Power | slightly higher | fine for desktop use |
