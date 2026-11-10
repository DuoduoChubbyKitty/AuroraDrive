# SEC-03 — DUAL PROCESS / IPC / SINGLETON LOCK / ENGINE HANDOVER

Read from `Sources/AuroraDrive/Core/EngineMain.swift` (2395 lines; header, run(), shutdown, socket
server, globals) and `Sources/AuroraDrive/Core/EngineClient.swift` (1121 lines, all key regions).
Line numbers are real.

## 3.1 Two processes, one binary

The project is **two long-lived processes sharing one executable**. There is no separate engine
binary in `Package.swift`; `AuroraDrive` is one executableTarget (`Package.swift:77-79`) and the mode
is selected by argv.

| aspect | detail | evidence |
|---|---|---|
| UI process | normal SwiftUI app, `@main AuroraDriveLauncher` | `EngineMain.swift:7` |
| engine process | same binary invoked with `--engine` | `EngineMain.swift:5`, `EngineClient.swift:404` |
| dispatch point | `@main AuroraDriveLauncher` splits at the very front of the process, **before** SwiftUI is touched | `EngineMain.swift:7-9` |
| engine never touches | SwiftUI, window creation, `NSApp.run()` | `EngineMain.swift:7-8` |
| TCC inheritance | permissions inherited through the process chain (parent already authorised → no prompt) | `EngineMain.swift:9` |
| engine entry | `static func run() -> Never` | `EngineMain.swift:1077` |

Consequence of sharing the binary: the engine process contains the entire SwiftUI/AppKit code and the
whole `DriveState`; it simply never enters the UI run loop. It builds its own `DriveState()`
(`EngineMain.swift:1234`) from the same class code (stated "照搬主程序组装（同一份类代码）" at
`EngineMain.swift:19`). Any state that lives only in a SwiftUI `@State` is therefore **absent** in the
engine process — this is the root cause of several "works locally, broken in engine mode" bugs
(see 3.8).

## 3.2 UI-side startup ladder — `EngineClient.startup()`

`EngineClient.swift:231-270`.

```
if AuroraFlags.uiLocal:  wantsEngineMode=false; return     :232-237   (AURORA_UI_LOCAL=1)
wantsEngineMode = true                                     :238
if tryConnect(): activate(); return                        :240-243   (health engine already there)
if !spawnEngine(): log "引擎 spawn 失败 → 回退本地模式"; return :245-248
poll tryConnect every 0.3s, up to 20 attempts (6 s)        :250-269
on attempt 20 fail: log "等待引擎超时 → 回退本地模式"        :261-263
```
Key design point: **connection attempt happens before spawn**. If a healthy engine is already
listening (from a previous UI session, or the engine outlived the UI), the new UI attaches to it
instead of starting a second one (`EngineClient.swift:8-9`). All failures degrade to local mode with
`isActive == false`; the UI keeps working on its own code path (`EngineClient.swift:14`).

`activate()` (`:272-280`) sets `isActive=true`, `isConnected=true`, stamps `lastHeartbeat`,
`attachShm()`, then calls `onActivated?()` so the UI can push its current display mode / upscale state
to the freshly attached engine (`:278-279`).
`tryConnect()` (`:286-322`) builds `sockaddr_un`, guards `pathBytes.count <= sun_path` size
(`:294-296`), `connect`, installs a `DispatchSource.makeReadSource` on the fd (`:313-318`), and
immediately sends `status` (`:320`).

## 3.3 Spawning the engine child

`EngineClient.swift:394-418`:
```
exeURL = CommandLine.arguments[0] standardized + resolvingSymlinksInPath()   :396-397
guard isExecutableFile(atPath:) else log + return false                     :398-401
process.executableURL = exeURL
process.arguments = ["--engine"]                                            :404
stdout & stderr appended to Self.engineLogPath via one FileHandle opened for writing :405-409
try process.run(); log "spawn 引擎 pid=\(pid)"                                :410-413
catch: log "spawn 失败: \(error)"; return false                              :414-417
```
Notes that matter operationally:
- The child is launched from `argv[0]` **resolved through symlinks**, not from `Bundle.main`. So a
  bare-executable launch and a bundle launch both spawn the correct binary, and the engine inherits the
  same code as the UI. `UNVERIFIED:` bundle-relative restart after the binary is replaced on disk mid-
  session — not tested this session.
- The child's stdout/stderr go to the **engine** log file, not the UI's. This is why engine `print` was
  invisible until the buffering fix at `EngineMain.swift:1078-1085` (see 3.6).
- `Process` inherits the environment by default. `EngineMain.swift:906-907` relies on exactly that: the
  UI does not set `environment` when spawning, so both processes read the same env vars
  (`AURORA_FORCE_YOLO26S` is the documented example).

## 3.4 Socket: path, protocol version, staleness

- Path: `~/Library/Application Support/AuroraDrive/engine.sock` (`EngineMain.swift:17`, built at
  `:1189-1191`); the parent dir is created at `:1089-1090`.
- `EngineClient.protocolVersion = 3` (`EngineClient.swift:115`). Version history is inline (`:108-114`):
  1 = original `start/stop/bye/status/upscale/ping`; 2 = added `record/reloadmodel/config` plus
  heartbeat `recording/frames/proto`; 3 = shared memory gained the **mask area** and `pixelsOffset`
  moved `20480 → 28672` — an explicit layout change, so old UI reading a new engine would interpret
  mask bytes as pixels (screen garbage), hence the version bump.
- Staleness predicate: `isEngineStale = sawHeartbeat && engineProtocol != protocolVersion`
  (`EngineClient.swift:330-332`). The comment at `:324-329` records the trap: it **must** be keyed on
  `sawHeartbeat`, not `engineProtocol != 0`, because an old engine never sends a `proto` field at all,
  so `engineProtocol` stays 0 — using 0 as "unknown, not a mismatch" would precisely miss the
  "new UI × old engine" case this guard exists for (2026-09-12, measured).

### 3.4.1 Killing and relaunching a stale engine — three documented traps

`relaunchStaleEngine()` (`:345-...`); the three pitfalls are listed at `:336-343`:
1. **`bye` does not stop the engine.** It only calls `pauseDriving()` and then waits 30 s idle before
   exiting, so a real `kill` is mandatory — you cannot negotiate via `bye`.
2. **Must wait for the old process to be truly dead before `startup()`.** Otherwise `tryConnect()`
   reattaches to the old engine, producing the loop "connect → detect stale → restart → connect to
   stale again"; worse, the flock singleton makes the *new* engine `exit(0)` immediately because the
   old one still holds the lock, so the new engine cannot even start.
3. **Must reset `sawHeartbeat`**, else the mismatch predicate stays true right after restart and it
   immediately re-declares staleness.

Sequence (`:351-380+`): cancel read source, close fd, `detachShm()`, cancel connect timer (`:352-357`);
clear all version/connection state `isActive/isConnected/engineProtocol/sawHeartbeat/lastHeartbeat/
enginePID` (`:358-364`); `kill(pid, SIGTERM)` (`:366-368`); poll every 0.4 s up to 8 s, escalate to
`SIGKILL` once `waited >= 1.2` while still alive (`:369-380`); only after death does it `startup()`.
Documented restriction: only called when **not driving** — losing the engine mid-drive is more
dangerous than a version mismatch (`:344`).

## 3.5 Engine-side singleton lock — flock, not a pid file

`EngineMain.swift:1092-1105`:
```
lockPath = AppSupport/engine.lock                                :1093
lockFD = open(lockPath, O_CREAT|O_RDWR, 0o600); if <0 → exit(3)  :1094-1098
if flock(lockFD, LOCK_EX|LOCK_NB) != 0:
    log "已有引擎实例在运行（flock 失败），本进程退出"; exit(0)   :1099-1102
ftruncate(lockFD, 0); write pid + "\n"                           :1103-1105
```
Properties that must be stated explicitly:
- The lock is released by the **kernel on process exit**, so no stale-lock cleanup code exists and none
  is needed (`:1092` states "进程退出自动释放").
- A second engine exits with **code 0**, not an error code — i.e. "someone else is doing the job" is a
  normal, non-failure outcome. This is why `resumeAfterLeanRecording` (3.9) must wait for the old
  process to die before spawning; otherwise the new engine silently `exit(0)`s and the UI waits for a
  socket that will never appear.
- The pid is written into the lock file purely for post-mortem inspection; authority is the flock, not
  the contents.
- Distinct from `scripts/build-lock.sh`, which is a **build-time** `mkdir`-based lock (SEC-02 §2.3) and
  unrelated to this runtime lock.

## 3.6 Engine startup sequence — ordered, fail-fast

`run()` performs these steps in order (`EngineMain.swift:1077-1256+`):

0. `setvbuf(stdout/_IOLBF)` + `setvbuf(stderr/_IOLBF)` (`:1084-1085`). Reason at `:1078-1083`: the
   engine's stdout is redirected to a file by the parent; stdio defaults to **block buffering** (4 KB)
   when writing to a file, so every `print("[cap-deep] ...")` sat in memory and the log was empty —
   during diagnosis this was misread as "the code never ran". The UI path already set line buffering at
   `AuroraDriveApp.swift:751`; the engine path had missed it.
1. Create `~/Library/Application Support/AuroraDrive` (`:1088-1090`).
2. **flock singleton** (see 3.5).
3. **TCC self-check, fail-fast** (`:1107-1155`): `axOK = AXIsProcessTrusted()`,
   `screenOK = CGPreflightScreenCaptureAccess()`. Default predicate `axOK && screenOK`; failure →
   `exit(2)` with "权限须由父进程链继承". Bypass `AURORA_ENGINE_DIAG_SKIP_TCC=1` logs a warning and
   continues, explicitly "仅供无 TCC 环境验证非权限逻辑，正常路径禁用" (`:14-15`, `:1142-1143`).
   **Observe-only relaxation** (`:1114-1155`): under `AURORA_OBSERVE_ONLY=1` the predicate narrows to
   `screenOK` only, because that mode forces `controlDisabled = true` and therefore injects zero keys,
   making Accessibility permission useless to it while screen capture remains essential. The comment
   stresses this is **not** "skipping permission checks": the non-observe predicate is unchanged
   verbatim, and even if injection were attempted, `ControlEngine.hold()`'s own
   `guard hasAccessibilityPermission` returns early, so nothing can physically be injected (`:1132-1138`).
4. `GameModeDefender.shared.start()` (`:1157-1159`) — engine is the process that needs the audible
   dimension and repeated re-assertion (mutes audio + re-asserts every 3 s).
5. **Anti-freeze**: `ProcessInfo.beginActivity([.latencyCritical, .userInteractive,
   .idleSystemSleepDisabled])` with the token retained (`:1161-1165`; comment: must be held or the
   activity releases immediately), then `setpriority(PRIO_PROCESS, 0, -20)` (`:1166-1168`).
6. **Signal handling** (`:1170-1187`): first `signal(SIGTERM, SIG_IGN)` and `signal(SIGINT, SIG_IGN)` to
   defeat default behaviour, then a `DispatchSource.makeSignalSource` per signal on its own queue. The
   handler sets `EngineGlobals.shutdownRequested = true` and hops to main to call
   `performShutdown(reason: "signal \(sig)")`. Two-stage intentionally: the flag is visible to the tick
   loop (`:1309-1310` also performs shutdown when it observes the flag) while the main-actor call
   guarantees `releaseAll()` runs on the main actor before exit.
7. **Socket server** (`:1189-1224`): `EngineSocketServer(path:)`; three callbacks wired
   (`onLine → handleCommand`, `onClientDisconnected`, `onClientConnected`); `start()` failure →
   `exit(4)`.
8. **Shared memory** (`:1226-1230`): `EngineFrameShm()`; failure → `exit(5)`.
9. `DriveState` assembly on the main actor inside `MainActor.assumeIsolated` (`:1232-1250+`): sets
   `EngineGlobals.state = DriveState()`, then `state?.isEngineHost = true` with the reason that this
   process has no run loop (`dispatchMain`) and therefore receives no `NSEvent`, so recorded keys must
   come from the UI-forwarded `remoteKeyMask` (`:1235-1237`). It then overrides the upscale wiring
   (`:1240-1250`): the engine has no window/MTKView, so interpolation renders in the UI and the engine
   only forwards full-resolution frames through a lock-protected slot; gating closures
   `isUpscaleWanted` and `isYoloWanted` are installed to avoid doing work whose consumers are disabled
   by the mode gate (`:1248-1254`).

Exit codes are therefore a usable diagnostic ladder: `2` = TCC, `3` = cannot create lock file,
`4` = socket start failed, `5` = shm failed, `0` = another engine already running (non-error).

## 3.7 Command channel

`handleCommand(_:server:)` at `EngineMain.swift:1862+`. Parsing is one line of JSON per line
(`:1862-1870`); an unparseable line logs "无法解析命令" and is dropped. An optional `id` field is
echoed back for acks; when absent, **no ack is sent**, preserving pre-ack behaviour verbatim
(`:1872-1874`).

Dispatch table (`switch type`), with the line where each case starts:

| command | line | behaviour summary |
|---|---|---|
| `start` | `:1874` | main-async `startDriving()`, clears `clientSaidBye` |
| `stop` | `:1887` | stop driving |
| `bye` | `:1899` | UI-initiated close: `pauseDriving`, engine keeps running waiting for reconnect |
| `status` | `:1910` | reply with state |
| `upscale` | `:1921` | `wantFullFrame` toggle |
| `record` | `:1934` | recording control |
| `reloadmodel` | `:2026` | model reload |
| `config` | `:2060` | config push (`perceptionMode` etc.), main-async |
| `set_capture_mode`, `capture` | `:2196` | capture mode / hz |
| `state` | `:2257` | state query |
| `ping` | `:2271` | liveness |

Heartbeat (engine → UI) is a single JSON line built at `:2307`, carrying
`type/proto/ts/fps/detections/isDriving/isStreaming/mode/modeRaw/speed/speedKmh/confidence/recording/
frames/pid/takeover/userHolding/reason`. `recording` uses `st.recordEngine.frameCount` and `frames`
the same value — i.e. the heartbeat's `frames` field is the recording frame count, not a capture count.

## 3.8 Connection-loss, reconnect window, idle exit

UI side: `readSocket()` (`EngineClient.swift:422-453`) accumulates bytes into `lineBuffer` and splits on
`0x0A` (`:428-436`); each line hops to main for `handleHeartbeatLine`. On EOF/error it **cancels the read
source synchronously on the read queue** before hopping to main (`:447-451`). The comment at `:439-446`
records the measured bug: killing the engine once produced **12+ consecutive "连接断开"** log lines,
because `read()` returning 0 left `readSource` alive, so the same EOF was re-delivered every event-loop
turn; the old code also cancelled inside an async block, which was too late. `handleConnectionLoss` is at
`:628`; `tryReconnectSoon()` (`:455-474`) polls `tryConnect` every 0.5 s and only while `isActive`
(`:456`).

Engine side: `onClientDisconnected` (`EngineMain.swift:1195-1210`):
- if `clientSaidBye`: log "UI 主动关闭（bye），引擎继续运行等待重连" — no reconnect window;
- else: log "UI 连接异常断开，进入 3 秒重连窗口" and `startReconnectWindow()`;
- **both** cases start the idle-exit countdown (`:1205-1207`).
`onClientConnected` (`:1211-1220`) cancels both windows, clears `clientSaidBye`, and sends a heartbeat
with `reason: "client-connected"` immediately (so the UI does not wait a full period for the first
heartbeat).

`startIdleExitCountdown()` (`:2336-2352`): 30 s `DispatchQueue.main.asyncAfter`; the work item re-checks
`EngineGlobals.socket?.hasClient == true` and returns if a client reattached (`:2345`), otherwise logs
"30 秒无人使用，自动退出（先释放全部按键）" and calls `performShutdown(reason: "idle-exit")`.
Rationale at `:2336-2338`: the engine is designed as resident (it can keep driving with the UI closed),
but holding resources with nobody attached is unreasonable, hence the backstop. Cancel is via
`cancelIdleExitCountdown()` (`:2354-2358`).

`pauseDriving(_:)` (`:2360-2375`) is the safety-side pause used by `bye` and watchdog timeout: sets
`isDriving=false`, `controlEngine.releaseAll()`, and **also stops recording** if running (`:2370-2373`).
The stated reason is data quality: otherwise the engine keeps recording for 30 s frames of "car stopped,
labels still the previous AI decision", and those frames get treated as valid samples by the next
training run, poisoning the imitation dataset (`:2367-2369`). Capture and inference keep running,
waiting for reconnect.

## 3.9 Handover: UI ⇄ engine yield and reclaim

This is the mechanism that lets the lean recorder take over the screen stream without fighting the
engine. Two functions, both on `EngineClient`.

### 3.9.1 Yield — `suspendForLeanRecording() -> Bool` (`:1011-1068`)

Ordered steps, each with a stated reason:
1. Cancel any pending "reclaim" poll **before** the guard (`:1012-1018`). Reason (`:1013-1015`): while
   the engine is leaving, `isActive`/`enginePID` are already empty, so a guard placed first would return
   false and skip the cancellation; the pending poll would then fire and `startup()` the engine again,
   making it contend for the same screen stream as local capture.
2. Idempotence: if `suspendedByLeanRecording` is already true, return true without re-signalling
   (`:1020-1025`). Reason: `enginePID` is already zero, so the only available pid is `suspendedPID`,
   which by then is long dead — and that pid may have been **reused by an unrelated process**, so a
   second kill would kill an innocent process. Returning true still tells the caller "remember to
   reclaim".
3. `hadPendingResume` also counts as "engine already yielded" (`:1027-1029`) — otherwise the caller would
   not record the need to reclaim and the engine would never come back.
4. Turn off the reconnect basis first: `wantsEngineMode = false`, cancel `connectTimer`
   (`:1031-1034`) — otherwise reconnect polling would immediately re-spawn the engine.
5. `sendByeSync()` before killing (`:1035-1036`) so the engine knows this is an intentional disconnect
   and does not enter its 3 s abnormal-loss window.
6. `pid = enginePID > 0 ? enginePID : suspendedPID`, then store into `suspendedPID` before zeroing
   `enginePID` (`:1037-1042`). Reason: when the reclaim flow is already in flight `enginePID` is already
   zero, and reclaim must poll "is the old engine really dead" — without the stored pid it would skip
   that wait and hit the flock `exit(0)`.
7. Tear down the local connection: cancel read source, close fd, `detachShm()`, clear
   `isActive/isConnected/enginePID/engineProtocol/sawHeartbeat/lastHeartbeat` (`:1043-1053`). Shm must
   be unmapped or the new engine would still be pointed at the old memory (`:1043`).
8. `kill(pid, SIGTERM)` and log; **15 s** backstop to `SIGKILL` (`:1054-1063`). The comment states
   SIGKILL loses the "keys were released" guarantee and is a last resort only.
9. If no pid was known, log that only the connection was dropped (`:1064-1066`).

### 3.9.2 Reclaim — `resumeAfterLeanRecording() -> Bool` (`:1084-1120`)

- Guard on `suspendedByLeanRecording`; clears it and sets `wantsEngineMode = true` (`:1085-1087`).
- Reads `suspendedPID` then zeroes it (`:1090-1092`).
- If no pid: `startup()` directly (`:1096-1099`).
- Else poll every 0.3 s, up to 8 s, for `kill(pid, 0) != 0` (old process gone) then `startup()`
  (`:1100-1119`). If it is still alive at 8 s it logs "⚠️ 旧引擎 pid=… 8 秒未退出，仍尝试拉起" and
  starts anyway.
- The reason `startup()` is re-run rather than just flipping `wantsEngineMode`: SIGTERM made the engine
  **exit the process**, so the desire to connect is not enough — `startup()` respawns it (`:1072-1074`).
- The reason for waiting out the old process (`:1076-1080`): after SIGTERM the engine still has to run
  `releaseAll → stopDriving → flushSync → exit(0)`, which takes hundreds of ms; during that time the
  socket file still exists and the flock is still held, so a new engine spawned then would `exit(0)` for
  want of the singleton lock, presenting as "the engine never comes back". The comment cross-references
  the same incident as `relaunchStaleEngine`'s trap 2.

### 3.9.3 Invariants of the handover (cross-checked against both sides)

- `bye` alone never stops the engine (3.4.1 trap 1); only `SIGTERM` does. Therefore a yield must be
  `wantsEngineMode=false` **plus** a real SIGTERM, and the reclaim must not assume the pid is gone.
- Shm must be unmapped before a new engine maps `/aurora_frame_v1`.
- Ordering is strict: cancel pending reclaim → disable reconnect → bye → remember pid → drop
  connection → SIGTERM → (later) wait for death → startup.
- Handover is refused while driving — `UNVERIFIED:` the exact guard line; the project note states it,
  and `relaunchStaleEngine` carries the same "not while driving" restriction at `EngineClient.swift:344`.

## 3.10 Shutdown — every path releases keys first

`performShutdown(reason:)` at `EngineMain.swift:2379-2394`:
```
if let st = EngineGlobals.state:
    st.stopDriving()          // includes controlEngine.releaseAll()      :2383
    st.recordEngine.flushSync()                                          :2386
else:
    ControlEngine().releaseAll()      // fallback, state not built yet     :2389
EngineGlobals.socket?.stop()                                             :2391
exit(0)                                                                  :2393
```
Why `flushSync()` is mandatory (`:2384-2385`): `stop()`'s `meta.json` is written via
`writeQueue.async`, and an immediate `exit(0)` would kill the process before the metadata lands,
leaving the recording session without `meta.json`. The wait drains the queue.

Callers of `performShutdown`: signal handler (`:1181`), tick-observed flag (`:1309-1310`), idle-exit
countdown (`:2347`). The invariant "SIGTERM before exit → `releaseAll`" is stated in the file header as
component 7 (`EngineMain.swift:20`) with the explicit purpose of preventing a **stuck key inside the
game**.

## 3.11 Shared memory — `/aurora_frame_v1`

Declared at `EngineMain.swift:184`; `shm_open`/`shm_unlink` are bridged because Swift cannot import the
C variadic `shm_open` (fixed 3-arg version at `:43-49`, `@_silgen_name`).

Header layout is documented byte-by-byte at `EngineMain.swift:112-166`. Fields that later sections
depend on: `magic 0x41555246` ("AURF", `:113`), `version = 1` (struct version, distinct from the socket
`protocolVersion = 3`), `headerSize 4096` (`:115`), `detOffset 4096` / `detCapacity 256` / `detStride 64`
(`:116-118`), `frameWidth/Height` (`:119-120`), `generation` bumped on resolution change (`:121`),
`activePage` 0/1 double buffer ("翻转即新帧就绪", `:122`), `frameSeq` (`:123`), `timestampNs` (`:124`),
`detectionCount` (`:125`), `flags` bit0 isDriving / bit1 isStreaming (`:126`), `fpsMilli` (`:127`),
`enginePid` (`:128`), `pageSize` (`:129`), then the mask block `maskSeq/maskW/maskH/laneW/laneH/
maskFlags/maskRatio/maskPadX/maskPadY/maskSrcW/maskSrcH/maskNewW/maskNewH` (`:130-142`).

Three layered facts that are not obvious from the file header:

**(a) `maskNewW/maskNewH` were added as a bug fix, not a feature** (`:144-162`). `MaskOverlay`'s draw
guard read `metrics.newW > 0` but the protocol never transmitted `newW/newH`, so `EngineClient`
rebuilt `LetterboxMetrics` with `newW: 0` → the guard was permanently false → **in engine mode not a
single mask cell was drawn**, user symptom "只能看到检测框，看不到可行驶区域和车道线". Local mode was
fine because it reads `yolopxEngine.metrics` where `newW` is real, which is why local selftests could
never catch it. Two fixes were applied, both deliberate: ① actually transmit the values; ② remove the
draw path's dependence on `newW`, because the drawing math never used it (only
`ratio/padX/padY/srcW/srcH`). ② was necessary because ① alone would still block old clients.
Backward compatibility: the fields sit in otherwise-free header space (header is 4096 bytes, only 125
were used), so no existing field moved and old clients simply ignore them (`:161-162`).

**(b) Mask area placement forced a layout bump** (`:191-198`). Old `pixelsOffset` was exactly `20480`
(end of detection area) with no room for masks; adding them pushed the pixel area back and bumped the
socket protocol to 2 (later 3). `maskOffset = detEnd = 4096 + 256*64 = 20480` (`:198-199`),
`maskGridMax = 160` (`:199`).

**(c) Masks are bit-packed and versioned** (`:168-181`). Motivation quoted as a user requirement that
the engine must return masks and the UI draw them directly. Plain `UInt8` would be 160×160 = 25,600
bytes per mask, 50 KB for two, i.e. **1.5 MB/s of pointless copying at 30 Hz**; bit-packing gives 3,200
bytes each, 6.4 KB total — negligible. Generation-number approach (`maskSeq`): masks only change on
frames where YOLOPX produced output, and YOLOPX runs slower than tick; unconditional resend would spend
half the frames retransmitting identical data, so `maskSeq` changes trigger a resend and the UI only
parses on a new seq (`:179-181`). `EngineGlobals.maskSeq` and `lastMaskFingerprint` hold this state
(`:648-652`).

## 3.12 Engine-mode blind spots (state that exists only in the UI process)

Facts recorded in-source that constrain future work:
1. **YOLOPX does not run in engine mode** (`EngineMain.swift:22-34`). Evidence chain given:
   `DriveState.tick()` early-returns via `tickEngineMode()` when `EngineClient.shared.isActive`
   (near `AuroraDriveApp.swift:3172`), and `yolopxEngine.infer(image:)` has exactly **one** call site
   repo-wide, located **after** that return in the local-inference branch (same file `:3260`) → engine
   mode can never reach it. Consequence: mask overlay reads empty masks and `yolopxEngine.isDegraded`
   stays at its initial `true`, so `LaneFallback` does not engage. Declared "既定设计", not a defect —
   but if masks are ever wanted in engine mode, the 160×160 grid (~50 KB) must be added to the shm
   protocol and back-filled in `tickEngineMode`; **not done** (`:33-34`).
2. `DriveState.perceptionMode` is a **UI-process** property (`UNVERIFIED:` exact definition line;
   cited as `AuroraDriveApp.swift:5414` in `EngineMain.swift:890`). Nothing writes it on the engine side
   — `selectPerceptionMode` only pushes config — so the engine's `st.perceptionMode` stays at its
   initial `.ayolom` and any engine-side gate reading it is permanently A-model (`EngineMain.swift:889-895`).
   Because of that, the engine keeps its own mode value; default `"ayolom"` is justified at `:897-901`
   (the engine has no yolo26s load path at boot: `yoloEngine.loadIfNeeded()` has **zero** occurrences in
   EngineMain — this is a quoted grep result, `:898-899`).
3. Recorded keys in engine mode must come from the UI-forwarded `remoteKeyMask` because the engine has
   no `NSEvent` source (`EngineMain.swift:1235-1237`, §3.6 step 9).

## 3.13 Logging sinks (relevant to any IPC debugging)

| sink | path | cap | rotation |
|---|---|---|---|
| engine | `~/Library/Logs/AuroraEngine.log` | 8 MB (`EngineMain.swift:59`) | single backup `.1`, checked every 64 writes (`:61`, `:65-75`, `:86-89`) |
| UI client | `~/Library/Logs/AuroraEngineClient.log` | 2 MB (`EngineClient.swift:48`) | single backup `.old`, checked every 64 writes (`:50`, `:55-65`, `:78-81`) |

Both rotate **before** writing the current line so there is no window where an over-limit file keeps
receiving writes (`EngineMain.swift:84-85`, `EngineClient.swift:76-77`). The engine log previously had
no cap at all — measured 6.16 MB in a 5.71 h session (951 KB/h, ⇒ ~22 MB/24 h, never cleaned), of which
**70% was a "once every 5 s" statistics line**, whose send frequency was reduced together with the cap
(`EngineMain.swift:55-58`). The client log is deliberately smaller because it is the reconnect /
protocol-mismatch triage entry point: it cannot be deleted, so it is capped instead; peak disk is
2 MB current + 2 MB backup = 4 MB (`EngineClient.swift:39-47`).

Corollary for anyone debugging IPC: engine-side `print` output only becomes visible after the
line-buffering fix, and both sinks write to `stdout` **and** a file, because a GUI process's stdout is
usually buffered and would otherwise be lost on exit (`EngineClient.swift:67-68`).
