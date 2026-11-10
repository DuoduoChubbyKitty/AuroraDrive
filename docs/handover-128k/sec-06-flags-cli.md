# SEC-06 — ALL ENVIRONMENT VARIABLES + ALL CLI FLAGS

Measured this session by `grep`, not recalled. Commands are quoted so every count can be re-derived.

## 6.1 Counting method (the counting itself was a bug once)

`AuroraFlags.swift:8-15` records the methodological trap, quoted as project history:
- Measured pre-refactor state ("perf-core" full scan): **72** `AURORA_*` variables across **13 files /
  70+ call sites**.
- The statistic **must** scan `"AURORA_*"` **string literals**, not just `environment["X"]` subscripts.
  Subscript-only scanning misses two classes: ① `let env = ProcessInfo.processInfo.environment` then
  `env["X"]` (25 such vars); ② constants holding the key name, e.g.
  `EgoBoxFilter.envKey = "AURORA_EGO_AREA"` (3 such vars).
- The author's first attempt scanned only subscripts and got **41** — recorded as "错得很远, 记此存照".

So this document uses literal scanning. Reproduce with:
```sh
grep -rhoE '"AURORA_[A-Z0-9_]+"' Sources/ | tr -d '"' | sort -u | wc -l
```

## 6.2 The three different counts (do not conflate them)

| measurement | value | command |
|---|---|---|
| distinct `"AURORA_*"` literals in `Sources/` | **92** | `grep -rhoE '"AURORA_[A-Z0-9_]+"' Sources/ \| tr -d '"' \| sort -u \| wc -l` |
| distinct `"AURORA_*"` literals **declared** in `AuroraFlags.swift` | **76** | same grep restricted to that file |
| `static let`/`static var` lines in `AuroraFlags.swift` | **78** | `grep -cE '^ *static (let\|var) '` |
| variables **not** centralised (read elsewhere) | **16** | `comm -23` of the two sets |
| all `AURORA_*` tokens including non-literal occurrences | **127** | `grep -rhoE 'AURORA_[A-Z0-9_]+'` (no quotes) |
| distinct `"--flag"` literals in `Sources/` | **73** | `grep -rhoE '"--[a-z0-9-]+"' Sources/ \| tr -d '"' \| sort -u \| wc -l` |
| flags registered in `oneShotFlags` | **53** | `sed -n '952,1018p' AuroraDriveApp.swift` |

Why 92 ≠ 127: the 127 includes partial tokens created by concatenation and by prefix fragments in
comments/strings (`AURORA_CORNER_`, `AURORA_SEG_`, `AURORA_JUNC_`, `AURORA_EGO_` appear as literal
prefixes in string interpolation), plus occurrences in `scripts/`, `tools/`, `run.sh`. The authoritative
set for Swift runtime behaviour is the **92 literals**, of which **76** are centralised and **16** are
not.

Why 78 ≠ 76: two `static` declarations in `AuroraFlags.swift` are not environment switches
(`AuroraFlagSpec`-related/`all`/`helpText`/`migrationStatus` machinery occupy static slots) while some
variables are referenced via helpers rather than a dedicated `static let`. The **per-variable** truth is
the 76 count; the 78 is a line count. Do not cite 78 as "number of switches".

## 6.3 The 16 variables still read outside the central table

Exact list (`comm -23` output), with the reason each is unreachable by the `static let` pattern:

```
AURORA_CONF_CI              AURORA_PTR_DUMP
AURORA_DETECT_DECIMATE      AURORA_PYTHON
AURORA_DIGEST               AURORA_WEBSEARCH_COOLDOWN
AURORA_FORCE_YOLO26S        AURORA_WORLD_MODEL
AURORA_LLM_HEALTH_CACHE     AURORA_YOLO_FASTCOPY
AURORA_LLM_PROBE_INTERVAL   AURORA_MAX_CLIPS
AURORA_MAP_GRAPH_W          AURORA_PRIVILEGE_INSTALLED
AURORA_MAP_ROAD_W           AURORA_OCR_CI
```

Two of these are known **deliberate** and must not be "fixed":
- `AURORA_FORCE_YOLO26S` is read in both processes independently; the UI deliberately does not set the
  child's environment, so both read the same value (`EngineMain.swift:903-907`). Centralising it in one
  process's `static let` would break the "engine and UI agree by construction" property.
- `AURORA_EGO_CHECK` is the documented **only** exception to `static let` (`AuroraFlags.swift:40-45`):
  `AuroraDriveApp.swift:3232` calls `setenv("AURORA_EGO_CHECK", "off", 1)` at runtime and the selftest
  depends on the change taking effect immediately; `static let` reads once at first access, so
  `egoCheck` is deliberately left as a per-call read (`:238-243`). It is **not** in the 16 above because
  it *is* declared in the file — as a `static var` computed per access.

`migrationStatus` (`AuroraFlags.swift:556-563`) is the in-code living list of what remains: it names
converged files (`Core/AuroraCache.swift`, `Core/AuroraFlags.swift`) and the pending ones
(`App/AuroraDriveApp.swift`, `App/MissionConsole.swift`, `App/PerfSelfTest.swift`,
`App/MarkerCluster.swift`, `App/MarkerTaxonomy.swift`, `App/RouteGraph.swift`, `App/AuroraTheme.swift`,
`Capture/CoordinateCapture.swift`, `Inference/YolopxEngine.swift`).

## 6.4 Why the central table exists (with the measured cost it removes)

`AuroraFlags.swift:4-54`:
- Pre-refactor there was **no aggregation**: default values existed only inside each `??` expression, so
  answering "what happens if I don't set this" required reading 13 files (`:19-20`).
- **Hot-path re-reads were real and measured**: `ProcessInfo.environment[key]` costs **17.213 µs/call**
  (measured, cited `AuroraDriveApp.swift:5171`) and **0.032 ms/call** (cited `MarkerCluster.swift:75`).
  `AURORA_OCR_DEBUG` was read **3 times inside every OCR inference**; `AURORA_DISABLE_OPTICAL_FLOW` was
  read every frame (latter since fixed) — called a "typical symmetric omission" (`:21-25`).
- At 30 Hz, 17 µs × 30 = 0.5 ms/s burned for nothing (`:37-38`). `static let` is `swift_once`-guarded →
  thread-safe, evaluated once, thereafter a memory read (`:33-38`).
- Three goals: ① centralise; ② self-describe (`defaultValue` / one-line summary / `isDiagnostic` /
  `readBy`); ③ discoverable via `--flags-help` (`:27-30`).

### 6.4.1 Boolean parsing conventions — a compatibility contract

`AuroraFlags.swift:94-114`:
- `bool(_:default:)` — **only the literal `"1"` means on**; `"true"`/`"yes"` are **not** accepted.
  Reason (`:96-98`): the project's historical convention is `== "1"`
  (`AuroraDriveApp.swift:138/5334` cited); keeping it byte-identical avoids a silent behaviour change of
  the form "this used to work and now doesn't".
- `boolNotZero(_:default:)` — inverse: only `"0"` means off; unset or anything else means on. Used for
  default-on switches (`AURORA_CACHE`, `AURORA_MAP_FILTER_BAR`) (`:104-109`).
- `str` treats empty string as absent (`:111-114`); `dbl`/`int` fall back to the default on parse
  failure; `dblOpt`/`intOpt` return nil.
- Single subscript site: `raw(_:)` at `:89-92` is the **only** `environment[...]` inside the file, and
  the comment states this deliberately so that `grep -rn 'environment\[' Sources/` is a direct measure of
  how much has not been migrated (`:82-83`). `UNVERIFIED:` that grep now returns exactly the residual
  sites listed in 6.3 — not re-run as an exhaustive assertion this session.

## 6.5 The switch table, section by section

Sections declared in `AuroraFlags.swift` with their own counts in the MARK headers, plus the `static`
declaration count actually present in each line range (measured):

| section | MARK | declared in header | static decls in range |
|---|---|---|---|
| A. 运行模式 / 进程 | `:133` | 5 | 5 |
| B. 引擎 / IPC / 网络 | `:155` | 4 | 4 |
| C. 推理 / 感知 | `:171` | 6 | 8 |
| D. 光流 / 自车运动 | `:212` | 6 | 9 |
| E. 驾驶 / 控制 | `:284` | 9 | 11 |
| F. 路网 / 弯道引导 | `:324` | 13 | 13 |
| G. 地图 UI | `:355` | 16 | 19 |
| H. 性能 / 日志 | `:414` | 5 | 7 |

The header counts (5+4+6+6+9+13+16+5 = **64**) are **stale relative to the code**; the measured
`static` declarations in those ranges sum to **76**. Sections C/D/E/G/H each grew after the header
number was written. Treat the MARK numbers as historical labels, not counts.

Named switches read in this session (key + default + line):
`uiLocal` `AURORA_UI_LOCAL` false `:138`; `daemonMode` `AURORA_DAEMON_MODE` false `:141`;
`observeOnly` `AURORA_OBSERVE_ONLY` false `:145`; `tccTest` `AURORA_TCC_TEST` `:148`;
`apiKey` `AURORA_API_KEY` `:152`; `engineDiagSkipTCC` `AURORA_ENGINE_DIAG_SKIP_TCC` false `:159`;
`engineDiagCaptureOnly` `AURORA_ENGINE_DIAG_CAPTURE_ONLY` false `:162`;
`legacyProto` `AURORA_LEGACY_PROTO` false `:165`; `nicTestTarget` `AURORA_NIC_TEST_TARGET` default
`"49.232.46.87"` `:168`; `ayolom` `AURORA_AYOLOM` `:175`; `inferQoS` `AURORA_INFER_QOS` `:178`;
`yolopxIntervalMs` `AURORA_YOLOPX_INTERVAL_MS` 0 `:181`; `yolopxLetterboxMain`
`AURORA_YOLOPX_LETTERBOX_MAIN` false `:184`; `skipModelLoad` `AURORA_SKIP_MODEL_LOAD` false `:187`;
`ocrDebug` `AURORA_OCR_DEBUG` false `:190`; `ocrWorkers` `AURORA_OCR_WORKERS` 0 `:198`;
`questOCR` `AURORA_QUEST_OCR` **true** `:209`; `disableOpticalFlow` `AURORA_DISABLE_OPTICAL_FLOW`
false `:219`; `egoArea` `AURORA_EGO_AREA` computed `:227`; `egoCheck` `AURORA_EGO_CHECK` (per-call
`static var`) `:243`; `egoMaxFwd` 0.5 `:246`; `egoMaxFlowPx` 80.0 `:248`;
`egoResidualRatio` 0.6 `:250`; `egoMinConf` 0.35 `:252`; `egoDiag` false `:266`;
`keyRefreshHz` computed `:278`; `laneKeepTiers` `:288`; `releaseAllEveryTick` false `:291`;
`assistKeepalive` `AURORA_ASSIST_KEEPALIVE` true via `boolNotZero` `:302`; `stuckSeconds` 30 `:305`;
`enableBgDrift` false `:308`; `segStraightenDeg` 15.0 `:311`; `segStraightenDoneDeg` 8.0 `:313`;
`segHandoverM` 15.0 `:315`; `segHandoverFrames` 10 `:317`; `segCorridorM` 8.0 `:319`;
`segMapTimeoutS` 20.0 `:321`; `cornerLookaheadM` 40.0 `:328`; `cornerHeadingTolDeg` 60.0 `:330`;
`cornerDeadbandDeg` 8.0 `:332`; `cornerSatDeg` 35.0 `:334`; `cornerPassedM` 15.0 `:336`;
`cornerConeDeg` 75.0 `:338`; `cornerTightRM` 80.0 `:340`; `cornerTightSpeed` 40.0 `:342`;
`juncLookaheadM` 45.0 `:344`; `juncApproachM` 25.0 `:346`; `juncExcludeDeg` 35.0 `:348`;
`juncForkTolDeg` 25.0 `:350`; `juncReachRatio` 1.2 `:352`; `mapWindow` `AURORA_MAP_WINDOW` false
`:359`.
`UNVERIFIED:` sections G (`:355-413`) and H (`:414-443`) were counted but their individual keys were not
all transcribed in this session; they are enumerated by `--flags-help` at runtime.

## 6.6 Self-description contract — `--flags-help`

`AuroraFlags.swift:536-552`. `helpText()` emits, in order: a title line containing `all.count`, then one
line per switch, then one trailing statistics line. Format is **one switch per line**, and the comment
makes the assertion explicit (`:538-540`): `wc -l` must equal `all.count + 2`, so
`--flags-help | wc -l` is usable as a test assertion.

Per-line format (`:545`): `  [诊断|功能] KEY=defaultValue  — summary   ← readBy`.

`AuroraFlagSpec` (`:61-72`) requires `key`, `defaultValue`, `summary`, `isDiagnostic`, `readBy`; the
`defaultValue` doc comment states it **must** match the real code default — "不一致就是文档撒谎"
(`:64-65`). The table itself is authoritative: `:444` states "漏加等于这个开关'不存在'", i.e. a switch
missing from `all` is invisible to `--flags-help` and to the selftest.

## 6.7 CLI flags — 73 distinct, two hard registration rules

Distinct flag literals: **73** (command in 6.2). Parsing is by `CommandLine.arguments` string search;
`grep -rn 'CommandLine.arguments' Sources/` returns **27** sites.

### 6.7.1 Rule 1 — a one-shot flag must be registered in `oneShotFlags` or it is silently blocked

`AuroraDriveApp.swift:950-952` declares `let oneShotFlags = [...]` (array spans `:952-1018`, **53**
distinct entries) with the stated purpose: short-lived self-check and daemon modes must not participate
in the UI lock, otherwise they mutually exclude the resident UI and either the selftest fails or the user
cannot start the GUI (`:950-951`).

The lock itself (`AuroraDriveApp.swift:763-779`): `flock(LOCK_EX|LOCK_NB)` on
`~/Library/Application Support/AuroraDrive/ui.lock`; if the file cannot be created it **allows**
startup (`:769`) rather than blocking normal use; on success it stores the fd and writes the pid
(`:770-775`); on failure `close` + false (`:777-778`).
Enforcement (`:1358-1366`):
```swift
let isOneShot = args.contains { oneShotFlags.contains($0) }
if !isOneShot, !acquireUISingleInstanceLock() {
    print("[App] 已有 AuroraDrive 实例在运行 —— 本次启动退出")
    print("      原因：两个 UI 会互抢引擎 socket（0.5s 断开重连死循环）")
    exit(0)
}
```
The reason for the lock (`:760-762`): measured 2026-09-12 — two UI instances fight over the same engine
socket, the engine serves one client, both get kicked and each enters a "disconnect → reconnect 0.5 s"
loop flooding the log. The engine side already had `engine.lock`; the UI side lacked it.

**The documented failure mode is a false green**, and the source records it recurring **four times**:
- `:982-983` — "W5 实测警告：漏登记时进程会被 UI 单实例锁挡掉却仍 exit 0 —— **假绿**。登记与分发必须同时存在。"
- `:999-1002` — "这两个自检早就有分发代码，但从未登记进本数组 —— 一旦 UI 进程在跑（持 ui.lock），
  它们会被单实例锁挡掉却仍 exit 0（**假绿**）。同款陷阱第 3 次出现。"
- `:1015-1016` — "⚠️ 登记与分发必须同时存在（本项目第 4 次踩同款假绿陷阱）。"
- `:986-990` — the mirror-image error: registering without dispatching falls through to the normal UI
  start and also exits 0 → false green.
- `:216` and `:992-998` add the same warning for `--lean-annotate`.

Consequence for verification work: a selftest that "passed" while another UI instance was running, and
whose flag was not registered, **proved nothing**. Both registration and dispatch must be verified.

### 6.7.2 Rule 2 — dispatch must happen before the lock, or the flag must be registered

Measured ordering: lock acquired at `:1359`. Flags dispatched earlier in `main()` are unaffected by
registration. Verified first-dispatch lines for the flags **not** in `oneShotFlags`:

| flag | first dispatch line | before lock (`:1359`)? |
|---|---|---|
| `--engine` | `:855` | yes |
| `--auto-login` | `:528` | yes |
| `--agent-llm-test` | `:879` | yes |
| `--set-llm-config` | `:861` | yes |
| `--network` | `:1112` | yes |
| `--live` | `:1149` | yes |
| `--map-window-test` | `:1354` | yes (5 lines before the lock) |
| `--auto-drive` | `MissionConsole.swift:6494` | separate entry path |
| `--agent-ui-shot` | `MissionConsole.swift:6537` | separate entry path |
| `--agent-layout-shot` | `MissionConsole.swift:6541` | separate entry path |
| `--locate-live` | `Locate/VisualLocator.swift:118` | consumed elsewhere, not an entry mode |
| remaining (`--dir --image --frames --iters --roi --seconds --stride --auto-seconds --agent-command`) | n/a | **argument payloads**, not modes |

So the 20 unregistered flags split into: entry modes that dispatch **before** the lock (safe by
ordering), MissionConsole-side entry paths, and pure argument payloads. `--map-window-test` at `:1354`
is the tightest margin — five lines before the lock — and is therefore the most fragile of the group:
anyone inserting work between `:1354` and `:1359` could change its behaviour.

**Known-benign false-positive in naive greps**: `"--live"` at `:1149` is a real standalone literal, so
`--live` is not merely a substring of `--locate-live` (`grep -rnoE '"--live"'` finds the quoted form). A
substring search for `--live` therefore over-matches `--locate-live`; only quoted-literal matching is
sound.

### 6.7.3 The 53 registered one-shot modes

Registered in `AuroraDriveApp.swift:952-1018`, grouped as the source groups them:
- self-checks: `--speed-selftest --tcc-selftest --test-xpc --yolo-selftest --upscale-selftest
  --fit-selftest --limit-selftest --proto-selftest --yolopx-selftest --opticalflow-selftest
  --motion-selftest --corner-selftest --realshot-selftest --egobox-selftest --ayolom-selftest
  --lanekeep-selftest --perception-selftest --wire-selftest --route-selftest --taxonomy-selftest
  --flags-help --cache-selftest --quest-selftest --llm-selftest --llm-vision-selftest
  --control-selftest --tool-selftest --tool-call-demo --llm-perf-selftest --websearch-selftest
  --v2-selftest --agent-selftest --map-selftest --lane-extrapolator-selftest --capture-selftest
  --pointer-selftest --lean-selftest`
- benchmarks / profiling: `--yolo-bench --perf-selftest --tick-profile --tick-bench --mc-map-bench
  --lanekeep-reality`
- headless render / capture: `--mc-shot --mc-map --mc-map-offline --mc-route --mc-route-loading --mc-quest`
- resident/helper: `--daemon --nic-autotest --llm-probe`
- offline annotation subprocess: `--lean-annotate` (`:992-998`)

`--lean-annotate` has an architectural role: after the UI stops recording it spawns
`--lean-annotate <clip>` as a **separate process** to run the speed-OCR backfill, explicitly to avoid a
synchronous `@MainActor` OCR freezing the interface (`:992-994`).

## 6.8 Full flag inventory (73, alphabetical)

```
--agent-command        --agent-layout-shot   --agent-llm-test      --agent-selftest
--agent-ui-shot        --auto-drive           --auto-login         --auto-seconds
--ayolom-selftest      --cache-selftest       --capture-selftest   --control-selftest
--corner-selftest      --daemon               --dir                --egobox-selftest
--engine               --fit-selftest         --flags-help         --frames
--image                --iters                --lane-extrapolator-selftest
--lanekeep-reality     --lanekeep-selftest    --lean-annotate      --lean-selftest
--limit-selftest       --live                 --llm-perf-selftest  --llm-probe
--llm-selftest         --llm-vision-selftest  --locate-live        --map-selftest
--map-window-test      --mc-map               --mc-map-bench       --mc-map-offline
--mc-quest             --mc-route             --mc-route-loading   --mc-shot
--motion-selftest      --network              --nic-autotest       --opticalflow-selftest
--perception-selftest  --perf-selftest        --pointer-selftest   --proto-selftest
--quest-selftest       --realshot-selftest    --roi                --route-selftest
--seconds              --set-llm-config       --speed-selftest     --stride
--taxonomy-selftest    --tcc-selftest         --test-xpc           --tick-bench
--tick-profile         --tool-call-demo       --tool-selftest      --upscale-selftest
--v2-selftest          --websearch-selftest   --wire-selftest      --yolo-bench
--yolo-selftest        --yolopx-selftest
```
Count verified by diff, both directions:
```sh
awk '/^## 6\.8/,/^## 6\.9/' sec-06-flags-cli.md | grep -oE '\-\-[a-z0-9-]+' | sort -u > doc.txt
comm -13 doc.txt cli_norm.txt   # flags present in code but missing here → empty
comm -23 doc.txt cli_norm.txt   # flags here but absent from code    → empty
```
Both `comm` outputs are **empty**, so the 73 blocks above are exactly the 73 distinct quoted flag
literals in `Sources/`. No flag is invented and none is omitted.

Flags that take a following argument (observed at their dispatch sites): `--yolo-selftest <image>`
(`run.sh:159-161`), `--yolo-bench <image>` (`run.sh:162-164`), `--dir <path>` (`:520`), `--image`,
`--frames`, `--iters`, `--roi`, `--seconds`, `--stride`, `--auto-seconds`, `--network`,
`--tool-call-demo <task>`, `--websearch-selftest <q>`, `--set-llm-config` (4 positional args,
`AuroraDriveApp.swift:861`).

## 6.9 `--engine` mode selection (cross-reference)

`--engine` dispatches at `AuroraDriveApp.swift:855`, i.e. **before** the UI lock and before any SwiftUI
setup, consistent with `EngineMain.swift:7-8` ("进程最前端分流，不触碰 SwiftUI"). It is not in
`oneShotFlags` and does not need to be: the engine exits on its own flock singleton
(`EngineMain.swift:1092-1102`, SEC-03 §3.5), a different lock file (`engine.lock` vs `ui.lock`).
Two distinct singleton locks, two distinct holders, no interaction.

## 6.10 Documented stale numbers found while writing this section

Recorded because they are exactly the kind of drift this handover exists to prevent:
1. `AuroraFlags.swift:8-15` — "**72 个** variables" is the pre-refactor count; the current literal count
   is **92** and the centralised count is **76**. The 72 must not be cited as current.
2. `AuroraFlags.swift:133-414` — the per-section MARK counts (sum 64) undercount the actual `static`
   declarations (sum 76). Sections grew, headers did not.
3. `AuroraDriveApp.swift:1016` — the `--lean-selftest` comment still says the test asserts "表头 19 列" and
   "缺失定位写空串". Both are **gone**: the header is 11 columns and the "missing position writes empty
   string" invariant was removed with the pose columns (commit `4947ec6`). The comment describes a
   previous generation of the test.
4. `README.md:95-98` — claims tick and capture are both 20 Hz citing `EngineMain.engineTickHz = 20.0`.
   The live value is **15.0** (`EngineMain.swift:771`, both tiers return 15.0 at `:868-885`, sprint 20).
   The README paragraph dates from the 2026-10-12 tier and was superseded on 2026-10-22.
