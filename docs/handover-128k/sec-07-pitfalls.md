# SEC-07 — PITFALLS / INCIDENT HISTORY / HARD CONSTRAINTS

This section is a distilled index of failure modes that are **documented in the source itself**, each
with `path:line`. It is organised by invariant, not chronologically. Every entry was read this session
unless marked otherwise. Density measurement used to locate the hot files:
`grep -rc '事故\|踩坑\|实测\|假绿' Sources/ --include='*.swift'` → `AuroraDriveApp.swift` 151,
`MissionConsole.swift` 82, `YolopxEngine.swift` 54, `LLMBackend.swift` 54, `CoordinateCapture.swift` 47,
`WebSearch.swift` 45, `InferenceEngineV2.swift` 42, `LLMHealth.swift` 36.
Dated-comment density: `2026-09-30` ×141, `2026-10-04` ×101, `2026-10-06` ×81, `2026-10-02` ×53,
`2026-10-08` ×46, `2026-10-22` ×28, `2026-11-03` ×19.

## 7.1 Verification integrity — the "false green" class (highest-value pitfall)

**Invariant**: a test that reports success must actually have executed.

The `oneShotFlags` registry is a **hand-maintained array** (`AuroraDriveApp.swift:952-1018`). A
self-check flag missing from it is blocked by the UI single-instance lock and the process **exits 0**,
which reads as success. The source records this recurring **four times**:
- `:982-983` — "漏登记时进程会被 UI 单实例锁挡掉却仍 exit 0 —— **假绿**。登记与分发必须同时存在。"
- `:999-1002` — two self-checks had dispatch code for a long time but were never registered;
  "同款陷阱第 3 次出现".
- `:1015-1016` — "本项目第 4 次踩同款假绿陷阱".
- `:986-990` — the **mirror image**: registering without dispatching falls through to the normal UI
  start and also exits 0 → false green.
- `:216`, `:992-998` — same warning restated for `--lean-annotate`.

Related false-green sources recorded elsewhere in the UI file:
- `:1652` — "避免「自检用的解析逻辑和生产不一样」的假绿" (self-check parsing must not diverge from
  production parsing).
- `:1796` — proving only "load succeeded" is a false green; a closed-loop probe must use instrumentation
  counts.
- `:1991`, `:1996` — a pre-condition assertion prevents "the value is 0 because it hasn't loaded yet"
  being mistaken for a real zero.
- `:3603` — a specific item's first version was a **weak assertion (false green)** and is recorded as
  such.
- `:3856` — "硬凑一个恒真断言只会制造假绿" (padding with a tautological assertion only manufactures
  false greens); the signature constraint is actually enforced by `tools/check-c7-gate.sh` A2.

Operational consequence for anyone verifying this project: confirm **both** registration and dispatch
before believing a self-check result, and confirm no UI instance was holding `ui.lock` (SEC-06 §6.7.1).

## 7.2 Concurrency / architecture constraints

### 7.2.1 Never do heavy work on the SCStream callback queue
`CaptureEngine.swift:1170-1172` — the record-copy is synchronous on captureQueue (≈4 MB memcpy,
sub-millisecond) but "JPEG 编码与写盘由录制器丢到自己的后台队列 —— **绝不可在 captureQueue 上编码**",
with the incident cited: synchronous heavy work on that queue pushed `capGap` from **11 ms to 2081 ms**.
Restated independently in `LeanRecordEngine.swift:44-47` and again at `:589-592` (why the cadence monitor
hops to main before calling `stop()`). Three separate files state the same rule.

### 7.2.2 `stop()` must not be called from the capture queue
`LeanRecordEngine.swift:589-593` — `stop()` internally does `writeQueue.sync {}`, which would block the
capture queue on disk I/O; therefore `DispatchQueue.main.async` is used, mirroring the auto-segment path.

### 7.2.3 Socket fd must not be closed via the shared variable
`EngineMain.swift:562-566` — on new connection the old one is cancelled (`old.cancel()`), never closed by
reading `clientFD`, because cancel is asynchronous and closing the shared variable would **close the new
connection** ("绝不在这里按 clientFD 关…会误关新连接").

### 7.2.4 UI read-source must be cancelled synchronously on EOF
`EngineClient.swift:439-451` — measured: one engine kill produced **12+ "连接断开"** lines because
`read()` returning 0 left `readSource` alive and the same EOF was re-delivered every event-loop turn;
the earlier fix that cancelled inside an async block was also too late. Correct order: cancel on the
read queue, then hop to main only for state cleanup.

### 7.2.5 Handover ordering (flock makes it unforgiving)
`EngineClient.swift:1076-1080` and `:336-343` — after SIGTERM the engine still needs
`releaseAll → stopDriving → flushSync → exit(0)` (hundreds of ms); during that window the socket exists
and the flock is still held, so spawning a new engine immediately makes it `exit(0)` for want of the
singleton lock, presenting as "the engine never comes back". Two independent sites record the same trap.

### 7.2.6 Pid reuse — never re-kill a remembered pid
`EngineClient.swift:1020-1025` — `enginePID` is already zero in the idempotent path, so only
`suspendedPID` is available, and that process is long dead; **the pid may have been reused**, so a second
kill would kill an unrelated process. Return true instead.

### 7.2.7 `@Observable` storage is not thread-safe
`LeanRecordEngine.swift:473-478` — `frameCount` may only be written on the main thread via
`DispatchQueue.main.async`; the authoritative count is `framesWrittenLocked` under `stateLock`, because
at `stop()`-drain time the main-thread value may not have updated yet (`:694-696`).

## 7.3 Data-integrity constraints (training data)

### 7.3.1 CSV row index ⇄ `frames/NNNNNN.jpg` is a hard pairing
`LeanRecordEngine.swift:34-40`. Upstream cause: `dataset_v3._build_index` uses `n_frames = len(rows)` and
resolves `frames/{j:06d}.jpg` by **row order**. Violation is **silent** — labels shift and nothing errors.
Five defence mechanisms are enumerated in SEC-05 §5.4. The specific historical bug: `appendCSVRow`
returned nothing while `writeFrame` still advanced the index → whole segment unloadable
(`:481-486`).

### 7.3.2 Never write `speed_kmh = 0`
`LeanRecordEngine.swift:489-491` — empty string ⇒ `speed_valid=false`; `0` would be read as "true speed is
zero", i.e. a **wrong supervision signal**. Real speed is filled by offline OCR.

### 7.3.3 Frame-rate tolerance is enforced by the training loader, not the recorder
`LeanRecordEngine.swift:311-327` — `dataset_v3` computes `actual_fps = 1/median(dts)` and raises
`ValueError` outside **12.75–17.25** (15 ± 15 %). The recorder's own gate only enforces "not too fast";
the "too slow" case cannot be fixed by rejecting frames and is handled by monitoring and **stopping with
an explicit reason** (`:325-327`).

### 7.3.4 Never accept a session-directory name collision
`LeanRecordEngine.swift:612-624` — timestamp precision is one second and auto-segment is `stop()`
immediately followed by `start()`, so collision is guaranteed; `createDirectory` does not error on an
existing directory and `createFile` would **truncate** the previous `controls.csv`, silently losing a
whole segment.

### 7.3.5 Do not record the app's own windows
`CaptureEngine.swift:17-19` — original filter used `excludingWindows: []` (nothing excluded), so the
desktop and AuroraDrive's own UI entered the training data. The invariant assertion is now
"exclusion list must be non-empty when own windows are on screen" (`:1063-1069`), and the pixel-based
heuristic was **deleted** on the principle "宁可漏报也不能误报" (`:1060-1061`).

### 7.3.6 Never silently fall back on a missing capture window
`CaptureEngine.swift:549-556` — falling back to full screen would violate the user's explicit choice, so
it reports an error and marks the selector red instead.

### 7.3.7 Alt-tab / focus loss must not lose held keys
`YolopxEngine.swift:58` and `:63` state the fail-open red line: a fail-hard path would drop the
already-pressed keys; the design instead gives "the most conservative answer" when data is untrustworthy
rather than letting the car die. `LaneBridge.swift:175` restates the fail-open red line for mask
geometry: `isUsable` must reject short `cells` before `LaneFallback` would `SIGTRAP`.

## 7.4 Input-injection constraints (measured against the actual game)

### 7.4.1 Only `.hidSystemState` + `.cghidEventTap` works
`ControlEngine.swift:183-198` — measured: the target game's input layer reads only the HID system state
layer. `.combinedSessionState` (previously used) is ignored by the game even though system UI reacts
(keyboard visualiser lights up, system beep sounds) — symptom "UI 显示已输出 W，但游戏纹丝不动".
`.privateState` is "禁止使用". `.hidSystemState` with `.cghidEventTap` is the verified combination that
gets through.

### 7.4.2 Modifier keys only emit `flagsChanged`
`KeyboardMonitor.swift:106-118` — measured: synthesising Shift produces event type **12 = flagsChanged**
for both phases, no keyDown/keyUp. Shift is the handbrake and the precondition for super brake
(Shift+Space) and ultimate brake (Shift+Space+S) (`:111-112`). Without a `.flagsChanged` monitor,
`heldKeys` never contains 56, so `shift` is 0 for the whole recording and the three safety heads get zero
positive samples — the trained model would never pull the handbrake (`:113-115`).

### 7.4.3 Auto-repeat is ignored by this game
`ControlEngine.swift:504-507` — the game's input layer only accepts "new key down" and ignores
auto-repeat, so `autorepeat` must stay `false` for the target game.

### 7.4.4 Never inject keys in observe-only mode
`ToolRegistry.swift:405` — with `AURORA_OBSERVE_ONLY=1` input injection is refused with an explicit
message that nothing was sent. Cross-referenced by the engine's narrowed TCC predicate
(`EngineMain.swift:1132-1138`, SEC-03 §3.6).

### 7.4.5 Permission query must not pop a dialog on the hot path
`ControlEngine.swift:210-232` — two distinct bugs recorded:
- P0 (2026-09-07): the string literal `"kAXTrustedCheckOptionPrompt"` is not a valid CFString constant,
  making the options dictionary invalid, `AXIsProcessTrustedWithOptions` receiving a nil-equivalent and
  **crashing with EXC_BAD_ACCESS at 0x8**.
- 2026-09-30 correction: the earlier comment claiming "first call auto-prompts" was **wrong** — passing
  `nil` only queries and **never** prompts, which is why the app never appeared in the Accessibility list
  (no request was ever issued). Therefore two methods exist: `checkPermission()` stays pure-query
  (because the high-frequency `press`/`hold` retry path must never prompt, "否则每帧弹一次"), and
  `requestAccessibilityPermission()` prompts once at start.

### 7.4.6 Six key-ups per frame was 71 % of the frame
`ControlEngine.swift:456-485` — measured `tick.inject` p50 = **0.15 ms** of `tick.total` 0.21 ms = **71 %**,
the single largest main-thread cost, because the `expertMode || controlDisabled` branch called
`releaseAll()` every frame (6 keys × `CGEvent.post`, `ev=` counter rising ~2000 per 30 s). Fix:
`releaseAllIfNeeded()` throttles to at most once per second when `heldKeys` is empty, while `releaseAll()`
itself is unchanged ("一字未改") because it still carries the safety duty of clearing system-level stuck
keys left by a previous crashed process. Safety argument enumerated at `:473-481`; equivalence to be shown
by ABBA comparison (0.15 ms → ~0.01 ms) at `:483-485`.

## 7.5 Platform / OS constraints

### 7.5.1 Deploying a binary over its own inode kills the running process
`run.sh:96-101` — running processes page text on demand; an in-place `cp` over the same inode makes the
kernel read mixed old/new pages, CDHash verification fails, and the kernel kills the process
(Taskgated Invalid Signature). Fix: copy to a temp name and `mv` (new inode), so the old instance keeps
the old vnode.

### 7.5.2 Metal precompile needs a writable module cache
`run.sh:118-120` — metal's clang ModuleCache defaults to `/var/folders/`, which a restricted environment
rejects with `Operation not permitted`, silently failing the precompile; redirected via
`-fmodules-cache-path="$ROOT/.build/metal-cache"`.

### 7.5.3 `libpcap` presence cannot be detected by file existence
`run.sh:26-39` — system libraries moved into the dyld shared cache since macOS 11, so
`ls /usr/lib/libpcap*` is always false; `brew list libpcap` is always false because libpcap ships with
macOS. Detection now uses `dyld_info -linked_dylibs` on a build product, then
`dyld_info -exports /usr/lib/libpcap.A.dylib`.

### 7.5.4 Build exit code lost through a pipe
`run.sh:78-80` — `swift build | tail -5` swallowed the exit status so `set -e` never fired and a **failed
build was deployed and launched**; the named incident is a 2026-09-15 `bagel_spam` compile failure that
was mis-deployed. Now the full log is captured and the rc checked.

### 7.5.5 Only `"1"` means on
`AuroraFlags.swift:94-102` — the project convention is `== "1"`; accepting `"true"`/`"yes"` would create a
silent behaviour change. `boolNotZero` is the inverse for default-on switches (`:104-109`).

### 7.5.6 `static let` never re-reads the environment
`AuroraFlags.swift:40-45` — `static let` evaluates at first access, so `setenv` later has no effect. One
documented exception exists: `AURORA_EGO_CHECK` is deliberately a per-call `static var` because
`AuroraDriveApp.swift:3232` does `setenv("AURORA_EGO_CHECK", "off", 1)` and a selftest depends on it
taking effect immediately (`:238-243`).

### 7.5.7 View-state restoration hangs the process
`AuroraDriveApp.swift:1368-1372` — symptom with `open AuroraDriveUI.app` (LaunchServices / double-click):
the process spins forever — 4 threads, 0.0 % CPU, 70 MB RSS, CPU time flat for 30 s, no log, no window —
while running the same binary from a shell is fine. Fix recorded as "禁用窗口状态恢复" (2026-09-30).

### 7.5.8 stdio block buffering hides all engine logs
`EngineMain.swift:1078-1085` — redirected stdout/file output block-buffers at 4 KB, so every
`print("[cap-deep] ...")` stayed in memory and the log was empty; during diagnosis this was misread as
"the code never ran". Both stdout and stderr are set to `_IOLBF`; the UI path already did this at
`AuroraDriveApp.swift:751`, the engine path had missed it. `AuroraDriveApp.swift:782-784` states the same
rationale for the UI process.

### 7.5.9 First-frame timing probes produce astronomical values
`CaptureEngine.swift:1139-1144` — with `lastFrameTime == .distantPast`, `timeIntervalSince` yields
~5e11 ms; the first frame logs 0 instead.

### 7.5.10 Screenshot rendering must happen before the run loop
`AuroraDriveApp.swift:787-790` — headless capture must run synchronously there: it is pure offscreen
`ImageRenderer` work, and if placed in `ContentView.onAppear` there is no window, the view never lays out,
`onAppear` never fires, and the process hangs after engine init — measured **240 s without producing an
image**.

## 7.6 Performance-measurement constraints

### 7.6.1 Absolute timings are not comparable across sessions
`PerfSelfTest.swift:868-874` (read verbatim in the `runTickBench` banner, 2026-10-05 measured lesson):
same binary, same machine, measured **2–2.5× difference** around a few hours of heavy load
(opticalflow p50 2.53 ms → 6.4 ms; `infer.yolopx` 16.4 ms → 22.6 ms), unrelated to code — it is thermal /
contention state. Therefore the fixture is **only** for same-session A/B attribution (same process,
back-to-back, single variable = perception tier), and cross-binary comparison must use
`scripts/paired-ab.sh --metric tick` (alternating paired rounds).

### 7.6.2 Concurrent benchmarking invalidates all timing numbers
`scripts/build-lock.sh:14-17` — measured: 3 agents running `--mc-map-bench --iters 200` at ~85 % CPU each
drove loadavg to 5.15 on 8 cores, at which point any timing figure is incomparable. Hence long tasks
(selftests / benches / gate collection) must hold the build lock, not only `swift build`.

### 7.6.3 Re-reading the environment on a hot path costs 17–32 µs
`AuroraFlags.swift:21-25` — `ProcessInfo.environment[key]` measured at **17.213 µs/call** and
**0.032 ms/call**; `AURORA_OCR_DEBUG` was read three times inside every OCR inference and
`AURORA_DISABLE_OPTICAL_FLOW` every frame.

### 7.6.4 The 45 Hz plan was wrong and must not be retried
`EngineMain.swift:727-733` — user once asked for "720P + 45fps" and tick was raised to 45, which was
**wrong**: 45 Hz budget is 22.2 ms while measured per-frame work is yolopx letterbox 10.5 + ayolom model
10.4 + V2 8.5 + world_model 3 + flow/control/recording 2 ≈ **36.9 ms**, so yolopx alone would consume 94 %
of the budget and the game dropped to **1–2 fps** (user-measured).

### 7.6.5 Changing tick frequency with `.now()` fires an extra tick
`EngineMain.swift:814-830` — measured on a running `DispatchSourceTimer`:
`schedule(deadline: .now(), repeating:)` produced a **0 ms** interval at the switch
(`GAPS: 204,200,197,204,[0],54,50,50,...`). Even with `hold()/release()` idempotence guards and
`appendFrame` back-pressure, the extra tick still posts an async inference `Task` with no idempotence
guard and an extra `refreshHeldKeys()` keyDown round. Chosen fix: always schedule `now + 1/clamped`, i.e.
wait one full period so the switch is a clean "old period → new period" with zero extra ticks; accepted
cost is one period of delay on the first new-cycle tick (`:828-830`).

### 7.6.6 Do not trust "updateConfiguration did not throw"
`CaptureEngine.swift:686-700` — the header states nothing about which fields are live-updatable; frame
rate is a capture throttle that may be frozen at stream creation, so success is an **optimistic
assumption** with a written measurement plan. `UNVERIFIED:` plan not executed in this session.

### 7.6.7 Native Retina capture was 675 MB/s of waste
`CaptureEngine.swift:509-535` — original capture was native 2940×1912 @30fps = **675 MB/s** through the
WindowServer compositor, competing with the game for GPU bandwidth; on a fanless Air M3 this throttled the
machine and the game fell to 1–2 fps, while training stored only 640×360 JPEG and the model consumed
180×320 (24× wasted). Down to 1280-wide @20fps = 85 MB/s; overall **7.9×** reduction.

## 7.7 "Don't overstate / don't fabricate" — documentation discipline encoded in source

### 7.7.1 Comments that overstate behaviour get explicitly corrected in place
`ControlEngine.swift:220-226` — a prior comment's claim ("first call auto-prompts") is marked
"**错的**" and replaced with the measured truth. This project's convention is to keep the wrong statement
visible with a correction date rather than silently rewriting it.

### 7.7.2 Hardcoded developer paths must not exist in product code
`AuroraPaths.swift:69-89` — P-1 (2026-10-04): the source contained
`URL(fileURLWithPath: "/Users/dupi/Desktop/自动驾驶系统")`, i.e. one developer's desktop baked into the
product. Consequences recorded: it fails on any other machine **silently** (it is a fallback candidate,
so failure is invisible), and it is both a privacy problem and a "this only runs on my machine" smell.
Also records a **first failed fix**: replacing it with `homeDirectoryForCurrentUser` was rejected because
that directory contains neither `Package.swift` nor `models/`, i.e. it would be a candidate that can never
match — "兜底候选的价值在于'真的可能命中'，不是'看起来更通用'". Final approach: walk up to 6 levels from the
executable's directory, with the level count justified (`release/ → macosx/ → scratch/ → .build/ → root`
= 4, plus 2 spare).

### 7.7.3 Secrets must never be printed or persisted
`AuroraFlags.swift:146-151` — `AURORA_API_KEY` is annotated "绝不打印、绝不落盘". `PrivilegePill.swift:17-19`
— passwords are entered in-app, never hardcoded (the old implementation hardcoded `"123456"`, which
"发布版必然失效且是安全隐患"), live only in memory, cleared after use, never written to disk or logs, and the
privilege escalation is strictly limited to installing one LaunchDaemon script (`:22-26`).

### 7.7.4 No native authorisation dialogs
`PrivilegePill.swift:9-13` — user requirement (2026-09-23): never use
`do shell script ... with administrator privileges`; repeated system authorisation prompts get the app
flagged by macOS as suspicious behaviour, which is harmful to an open-source project's reputation. Both
legacy entry points are now `@available(*, deprecated)` and immediately return failure:
`BPFSetup.swift:96-99`, `PrioritySetup.swift:53-58`.

### 7.7.5 Web search must fail honestly and must not evade anti-bot measures
`WebSearch.swift:31-36` — compliance red line: no proxy pools (the proxy mentioned is the machine's own
system proxy, verified with `scutil --proxy`, not an evasion tool); read-only public pages; no CAPTCHA
bypass, no simulated login, no forged Referer, no proxy rotation. **Honesty red line**: any failure throws
`WebSearchError` and never returns a placeholder or fabricated result; not-found = `.emptyResults`,
blocked = `.blocked`, timeout = `.timeout`, and the three must be distinguishable in the UI (`:36-37`).
Error taxonomy at `:84` — "每一类都对应一次真实的实测观察，绝不合并成一句'失败了'".
`WebSearch.swift:218-221` — an independent ephemeral `URLSession` is a **performance red line**: it must not
be shared with `captureQueue` or `aurora.quest.ocr`.

### 7.7.6 Self-checks must not fabricate omissions or environment limits
`LLMSelfTest.swift:30` — unverified items are explicitly marked "未验证" and counted as failures or
flagged environment-limited, "绝不编造". `:1288` — print the actual session state and mark environment
limits instead of disguising them as a pass. `:211` — repository red line: source must not hardcode API
keys; the check scans all descriptor headers and baseURLs. `LLMBackend.swift:27` — the only literal that
looks like a key, `"public"`, is the OpenCode Zen catalog term.

### 7.7.7 Brand vs upstream attribution
`ControlEngine.swift:4-16` (2026-10-04) — the game key table (`GameKey`, near `:408`) comes from the
upstream open-source project **MaaNTE**'s actually-used key set. The upstream name is deliberately kept in
**source comments** so any key's presence can be re-verified, but the upstream name must never appear in
brand-visible strings/identifiers; the product brand is `AuroraDrive` (`App/AuroraBrand.swift`).

## 7.8 Mask/display-path pitfalls (engine vs local asymmetry)

### 7.8.1 The mask draw guard depended on a field the protocol never sent
`EngineMain.swift:144-162` — `MaskOverlay` guarded on `metrics.newW > 0`, but the protocol never carried
`newW/newH`, so `EngineClient` rebuilt `LetterboxMetrics` with `newW: 0` → guard permanently false → in
engine mode **no mask cell was drawn**; user symptom "只能看到检测框，看不到可行驶区域和车道线". Local mode
was unaffected because it reads `yolopxEngine.metrics`, which is why **local selftests could never catch
it**. Both fixes were applied (transmit the values; remove the guard's dependence on them).

### 7.8.2 Layout changes require a protocol version bump
`EngineClient.swift:108-115` — v3 added the mask area and moved `pixelsOffset 20480 → 28672`; an old UI
would read mask bytes as pixels (garbled screen). The bump exists so the version guard forces an engine
restart.

### 7.8.3 Staleness must key on "saw a heartbeat", not on "protocol != 0"
`EngineClient.swift:324-332` — an old engine never sends `proto`, so `engineProtocol` stays 0; treating 0
as "unknown, not a mismatch" would miss the exact "new UI × old engine" case the guard exists for
(measured 2026-09-12).

### 7.8.4 YOLOPX does not run in engine mode (by design, with side effects)
`EngineMain.swift:22-34` — `tickEngineMode()` early-returns, and `yolopxEngine.infer(image:)` has exactly
one call site located after that return, so engine mode can never reach it. Consequences: no `da`/`ll`
masks are produced in that process (masks arrive via shm instead), `MaskOverlay` otherwise reads empty
masks, and `yolopxEngine.isDegraded` stays at its initial `true` so `LaneFallback` does not engage.

## 7.9 Logging / resource pitfalls

### 7.9.1 Unbounded logs become a disk problem
`EngineMain.swift:55-58` — the engine log had **no cap**; measured 6.16 MB in a 5.71 h session
(951 KB/h ⇒ ~22 MB/24 h, never cleaned), of which **70 %** was a once-per-5-s statistics line.
`EngineClient.swift:39-47` — the client log mattered for reconnect triage so it cannot be deleted; capped
at 2 MB with a `.old` backup ⇒ peak 4 MB, predictable.
`EngineMain.swift:564` also demonstrates the same discipline for the socket: never close the shared fd.

### 7.9.2 Stuck keys survive a crash unless a real process does `releaseAll`
`EngineMain.swift:20`, `:2360-2375`, `:2377-2394` — every exit path releases keys first; SIGKILL is
explicitly a last resort because it loses the "keys released" guarantee
(`EngineClient.swift:1058-1062`). `pauseDriving` additionally stops recording to avoid polluting the
training set with "car stopped, labels still the last AI decision" frames (`:2367-2369`).

## 7.10 Open / unverified items (must be carried forward, not silently dropped)

Each is a concrete gap, not a suggestion:
1. `CaptureEngine.setCaptureHz` hot-update effectiveness — measurement plan written, `UNVERIFIED:` never
   executed (`CaptureEngine.swift:686-700`).
2. `SCDisplay.width` pixels-vs-points — needs measurement, glyph templates depend on it
   (`CaptureEngine.swift:505-507`).
3. Real-gameplay validation of the recorder: `recordings/` is 0 B; `data/raw_clips` and `clips` were
   empty at last check. Speed-OCR accuracy on a real speedometer and true 10-minute segment timing are
   unmeasured.
4. Crash window between JPEG write and CSV append — no recovery on next start
   (`LeanRecordEngine.swift:447-460` covers graceful failure only).
5. `AuroraFlags` migration incomplete: 16 variables still read outside the table (SEC-06 §6.3), with
   `migrationStatus` (`AuroraFlags.swift:556-563`) naming 9 pending files.
6. Case-sensitivity: this volume is case-insensitive (APFS default; `ls -d vendor` succeeds although the
   directory is `Vendor`), so path-casing bugs are invisible locally.
7. Stale in-source numbers catalogued in SEC-06 §6.10 (72 vs 92/76; section counts 64 vs 76; the
   `--lean-selftest` "19 列" comment; README's 20 Hz claim vs live 15 Hz).
