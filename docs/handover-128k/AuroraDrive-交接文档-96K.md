# AuroraDrive — 交接文档（压缩版 96K 目标）

Machine-oriented handover document for `/Users/dupi/Desktop/自动驾驶系统`.
Compressed from `AuroraDrive-交接文档-全量版.md` (251,052 chars / 3,798 lines).
Every claim keeps its `path:line`; `UNVERIFIED:` marks anything not read in the generating session.

- HEAD at generation: `4947ec6` (lean recorder drops pose columns, CSV 19 → 11)
- Scale: 77 Swift files / 71,552 lines under `Sources/`; 22 Python files / 17,706 lines under `src/`
- Sections: 12, order preserved

---

# SEC-01 — IDENTITY / SCALE / TREE / FILE INVENTORY

`UNVERIFIED:` marks what was not read.

## 1.1 Identity

`Package.swift:50` product `AuroraDrive`; cwd `/Users/dupi/Desktop/自动驾驶系统`; HEAD `4947ec6` "精简录制器：去掉定位列，只存画面 + 按键（CSV 19 列 → 11 列）" (`git log --oneline -1`); 393 commits; branch `main`; dirty `default.metallib` (M, rewritten by `run.sh`); GPL-3.0-or-later (`NOTICE:1-14`, `README.md:171-179`); copyright `2026 DuoduoChubbyKitty <19859116705@163.com>` (`NOTICE:2`); SPDX `SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty` + `SPDX-License-Identifier: GPL-3.0-or-later` (`NOTICE:50-52`); remote `github.com/DuoDuoChubbyKitty/AuroraDrive.git` (`README.md:71`; `UNVERIFIED:` not re-read via `git remote -v`); last 8 `4947ec6` `5c178e0` `297f1f2` `066e1df` `1dc6327` `849da70` `8aa68e8` `fb5c4ad`.

Purpose (`README.md:5`): macOS third-party viewpoint-autodrive for 《异环》(NTE): capture → CoreML → key injection + libpcap locating + speed OCR (PP-OCRv6 finetuned int8) + MetalFX. `README.md:10-11`: research/personal-study only; ToS / ban risk.

## 1.2 Toolchain (measured)

```
swift-driver 1.148.6  Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx28.0
ProductName: macOS  ProductVersion: 27.0.1  BuildVersion: 26A434   uname -m = arm64
```
`// swift-tools-version:6.2` (`Package.swift:1`); `platforms: [.macOS(.v26)]` (`Package.swift:51`) — floor is a minimum, host newer; `README.md:68` "macOS 26+ · Apple Silicon".

## 1.3 Targets (4, zero external deps)

`Package.swift:49-210`; `dependencies: []` at `Package.swift:52` — no remote packages.

| target | kind | path | deps | evidence |
|---|---|---|---|---|
| `AuroraDriveShared` | `.target` | `Sources/AuroraDriveShared` | none | `Package.swift:54-57` |
| `OpenCVFlow` | `.target` C++ | `Vendor/OpenCVFlow` | none | `Package.swift:59-71` |
| `AuroraDriveUserAgent` | `.executableTarget` | `Sources/AuroraDriveUserAgent` | Shared | `Package.swift:72-76` |
| `AuroraDrive` | `.executableTarget` | `.` root | Shared, OpenCVFlow | `Package.swift:77-209` |

`path: "."` plus inside-tree deps are made viable by whitelist + `exclude`, not layout (`Package.swift:93-192`). `sources: ["Sources/AuroraDrive", "Vendor/MetalGoose/Engine"]` (`Package.swift:189-192`); new `.swift` there needs no manifest edit (`:188`). `exclude` (`Package.swift:93-187`), body `94-186` = **89 quoted entries + 4 comment lines** (`sed -n '94,186p' Package.swift | grep -c '^ *"'` → 89; `grep -c '^ *//'` → 4). Purpose (`:88-92`): stops `path: "."` walking `.build/` ("59 万个条目") as unhandled input. Kept-but-excluded (`:85-87`): `Shaders.metal` (loaded by path at `Vendor/MetalGoose/Engine/GooseEngine.swift:456`), `Sources/AuroraDrive/Capture/CaptureEngine.swift.bak-20260930`. Drift check `bash scripts/check-package-sources.sh` (`Package.swift:92`). `docs` twice (`Package.swift:144`, `:186`), tolerated.

**Language mode — hard constraint, do not delete**: `swiftSettings: [.swiftLanguageMode(.v5)]` (`Package.swift:201-203`). `Package.swift:193-200`: without it, tools-version 6.2 defaults to Swift 6 strict concurrency → `static let shared` across "56 个文件" emits `#MutableGlobalVariable` / "main actor-isolated default value", "500+ error" once; a scripted `sources:` edit once swallowed the block via regex.

**OpenCV static link** (`Package.swift:4-9`): C wrapper over `cv::DISOpticalFlow`. Measured 640×640 (`Package.swift:11-14`): VTOpticalFlow 10.28 ms, Vision 27.43 ms, OpenCV DIS 1.91 ms → "光流 ≤5ms" red line. `openCVFlowRoot` from `packageRoot` (`Package.swift:29`), root from `#filePath`, stdlib-only (manifest sandbox has no Foundation, `Package.swift:20-28`). Linker (`Package.swift:16-18`): `-L` **must be absolute** (relative → "library not found"); static libs real files, not nested symlinks. 11 libs (`Package.swift:35-47`): `opencv_core` 5.02 MB, `opencv_imgproc` 8.05 MB, `opencv_geometry` 2.65 MB, `opencv_flann` 0.79 MB, `opencv_video` 0.67 MB (holds DIS), `tegra_hal`, `kleidicv_hal`, `kleidicv`, `kleidicv_thread`, `ittnotify`, `zlib`. 3 groups or undefined symbols (`Package.swift:31-34`): HAL → `carotene_o4t::*`; `Accelerate` → `_cblas_sgemm$NEWLAPACK$ILP64`; libc++. App links `NetworkExtension`, `Network`, `pcap` (`Package.swift:204-208`).

## 1.4 Scale (measured)

Swift `Sources/`: **77 files / 71,552 lines**; MetalGoose engine **5 / 2,780**; `Vendor` **14 `.swift`** (`Package.swift:163-178`). Sums reconcile: 17+17+15+11+6+4+3+2+1+1 = 77.

`App` 17/25,764 · `Agent` 17/15,383 · `Inference` 15/14,706 · `Core` 11/6,150 · `Capture` 6/6,485 · `Control` 4/1,212 · `Perception` 3/620 · `Locate` 2/1,159 · `AuroraDriveShared` 1/21 · `AuroraDriveUserAgent` 1/52.

Python: `src/` **22 / 17,706** (no `__pycache__`), `tools/` **219 / 53,298** ⇒ ≥ 71,004. `src/` largest: `train_v2.py` 2,317, `model_v2.py` 1,930, `risk_head.py` 1,822, `model_v3.py` 1,648, `dataset_v2.py` 1,417, `model_v3_experiments.py` 1,045, `dataset_v3.py` 913, `verify_heads.py` 699, `heading_head.py` 644, `verify_lane_usage.py` 613.

Top Swift: `AuroraDriveApp.swift` 10,008 · `MissionConsole.swift` 8,003 · `InferenceEngineV2.swift` 3,820 · `AIAgentPanel.swift` 3,273 · `EngineMain.swift` 2,395 · `LLMSelfTest.swift` 2,183 · `SpeedOCRReader.swift` 1,924 · `YolopxEngine.swift` 1,814 · `CoordinateCapture.swift` 1,811 · `LLMHealth.swift` 1,791 · `CaptureEngine.swift` 1,739 · `LLMTransport.swift` 1,580 · `WebSearch.swift` 1,463 · `QuestPanelReader.swift` 1,160 · `EngineClient.swift` 1,121 · `ToolRegistry.swift` 1,065 · `PointerHeadingReader.swift` 1,027 · `PerfSelfTest.swift` 992 · `MapSelfTest.swift` 985 · `YoloEngine.swift` 918. 4 largest = 25,104 = 35.1%; top 5 = 27,499 = 38.4%.

## 1.5 Repo root

Dirs `AuroraDriveUI.app` `MaaNTE` `Resources` `Sources` `Vendor` `checkpoints` `data` `docs` `legacy` `models` `print` `recordings` `scripts` `src` `tools` `verify` `website`; files `Package.swift` `README.md` `README.en.md` `NOTICE` `run.sh` `default.metallib` `AuroraDriveUI`. `ls -d vendor` **succeeds** though dir is `Vendor` — APFS case-insensitive; casing bugs invisible here, break on case-sensitive checkouts (`UNVERIFIED:` untested).

`du -sh`: `3.9G models 1.3G MaaNTE 933M tools 522M docs 520M checkpoints 134M website 84M data 24M Vendor 23M print 5.7M verify 3.9M Sources 2.4M src 104K scripts 104K legacy 0B recordings`. `recordings` **0B** (clips to temp/selftest; `UNVERIFIED:` production dir).

## 1.6 Model assets

`models/` **193 top-level entries**: **52** `*.mlmodelc`, **105** `*.mlpackage`, rest json/png/backups. README assertions, each with its line in `README.md:44-57` (re-derive before asserting): `models/ppocrv6_tiny_ft_int8.mlpackage` speed OCR (`README.md:33`); `models/ayolom/ayolom_n_int8.mlmodelc` YOLOPX three-head; `models/quest_index.json` (`README.md:36`); `models/route_graph.json` **664 nodes / 932 edges** (`README.md:38`, `README.md:55`); `models/FINAL_complete_map_database.json` (`NOTICE:38-41`); `models/bigworldmapSecond.png` 13056×13056, publisher-copyrighted, **not** redistributed, do not commit (`NOTICE:30-35`); `models/pointer_model.onnx` third-party (`NOTICE:33-35`); `models/NOTICE.md` exists (`UNVERIFIED:` contents).

## 1.7 Existing docs surface

`docs/` 522 MB: 40-article `代码-00`~`代码-39` (`README.md:161-170`) + `docs/文档库/自动驾驶与功能/` (`README.md:8`, `:155-170`). Subdirs `class-diagram.mermaid` `deep-audit-cpu` `git` `handover-128k` `perf-audit-20261024` `perf-audit-gpu` `roadnet` `sequence-diagram.mermaid` `v3-design` `指针朝向-交接笔记.md` `整合文档` `文档库` `老旧文档`. `handover-128k/` is new; the older series drifted from code (`README.md:63-64`, `README.md:139-144`).

Stale markers: `README.md:46` "三档" (`.recover` deleted 2026-09-30); `README.md:61-64` "自愈式定位" removed with `76e9027`, `VisualLocator` never instantiated, "8 种诊断 + 自动修复" unimplemented; `README.md:95-98` claims 20 Hz / `EngineMain.engineTickHz = 20.0` (history 45→30→20, live 15.0); `README.md:103-117` diagram is single-process, missing four pillars (dual process + shm v3, YOLOPX, optical flow + motion predict, mask visualization).

## 1.8 Entry points

`AuroraDrive` → `Sources/AuroraDrive/App/AuroraDriveApp.swift` (10,008, UI); `AuroraDriveUserAgent` → `Sources/AuroraDriveUserAgent/main.swift` (52); `AuroraDriveShared` → `Sources/AuroraDriveShared/AuroraDriveShared.swift` (21); `OpenCVFlow` → `Vendor/OpenCVFlow`. Declared `Package.swift:72-76`, `:77-209`. `UNVERIFIED:` exact `@main` line and `main.swift` content (pinned in SEC-02/03). Deployed `AuroraDriveUI` (`.app/Contents/MacOS/AuroraDriveUI`), renamed in `run.sh`.

## 1.9 Scripts / tools

`scripts/` (104 KB, 8): `README.md` `build-lock.sh` `check-package-sources.sh` `gpu-attrib.sh` `paired-ab.sh` `perf-snapshot.sh` `regression-gate.sh` `setup_toolchain.sh`. Wired: `check-package-sources.sh` (`Package.swift:92`); `paired-ab.sh --metric tick` (via `Sources/AuroraDrive/App/PerfSelfTest.swift:870`; `UNVERIFIED:` line not re-read).

`tools/` 933 MB / 219 `.py`, scratch dump: `aurora_recorder` + 6 `.bak-*`, `aurora_capture.c`, `aurora_recorder.c`, `candidate_8_frames.png`, `diag_clusters.png`, `convert_e2e_v3.py`, `convert_yolo_to_coreml.py`, `build_hdf5.py`, `build_final_map_db.py`, `fetch_complete_map.py`, `auto_label.py`. Append-only archaeology; filenames carry dates (`bak-20260809_121949`, `bak-fps-133005`).

---

# SEC-02 — BUILD / SIGN / DEPLOY / BUILD-LOCK

Read: `run.sh` (182 lines, all), `Package.swift` (211), `scripts/build-lock.sh` (146), `scripts/check-package-sources.sh` (229, first 80).

## 2.1 `run.sh` — only supported build+deploy entry

Modes (`run.sh:2-5`): no arg = build+sign+launch; `--status`; `--yolo-selftest <image>`; plus `--yolo-bench`, `--auto-login` (`run.sh:159-178`). `set -e` (`run.sh:6`).

```
ROOT    = dirname($0) absolute               run.sh:8
BIN_SRC = .build/scratch/release/AuroraDrive  run.sh:11
BIN_DST = AuroraDriveUI                       run.sh:12
BUNDLE  = $ROOT/AuroraDriveUI.app             run.sh:109
```
Product is `AuroraDrive`; **deployed** name `AuroraDriveUI` — a `cp` rename, unknown to `Package.swift`.

**Step 1/4 libpcap (`run.sh:26-39`) — documented past bug.** Both former predicates are **always-false since macOS 11**: `ls /usr/lib/libpcap*` (libs live in the dyld shared cache; `/usr/lib` has "仅剩 32 个条目") and `brew list libpcap` (ships with macOS). Now a 3-way `||` (`run.sh:32-39`): `[ -f "$BIN_SRC" ] && dyld_info -linked_dylibs "$BIN_SRC" | grep -q libpcap`; `dyld_info -exports /usr/lib/libpcap.A.dylib`; `ls /usr/lib/libpcap*`. The `-f` guard exists because ① needs a build product absent on a clean tree, so ② is the fallback (`run.sh:31`). Failure text names consumer `CoordinateCapture.swift` and dead `legacy/NetworkPacketCapture.swift` (`run.sh:37`).

**Step 2/4 models (`run.sh:41-64`).** Trio `m9_mono`, `game_assist_control`, `yolo26s` (`run.sh:47`): ✓ `.mlmodelc` / ✓ `.mlpackage` ("未编译,回退加载") / ✗ (`run.sh:48-54`). `yolopx` special (`run.sh:56-64`): preferred `models/yolopx/yolopx3_pal8_detfp.mlmodelc`; dir present without it → "⚠ 非首选，回退候选:" + dir listing; else ✗, noting the driveable-area/lane/detection three-in-one head is a "★核心资产". `run.sh:42-44`: the original check **missed yolopx** — the core asset and a "一个字节都不能换" red-line model. `--status` exits here (`run.sh:67-71`).

**Step 3/4 build (`run.sh:73-93`).** ① `rm -rf .build` (`run.sh:77`) — "必须先清缓存! SwiftPM 缓存会导致代码改动不生效"; every run is from scratch. ② `swift build -c release --disable-sandbox --scratch-path .build/scratch > .last-build.log 2>&1` (`run.sh:85`). Three documented fixes: `run.sh:78-80` — old `swift build | tail -5` swallowed the exit code so `set -e` never fired and a **failed build still deployed and launched** (2026-09-15 `bagel_spam` mis-deploy); now full log, `BUILD_RC=$?` (`run.sh:86`), last 5 lines printed, and on `BUILD_RC -ne 0 || [ ! -f "$BIN_SRC" ]` greps `-m 8 "error:"` and `exit 1` (`run.sh:88-92`). `run.sh:81-83` — in sandboxes ("DSH workspace-write") SwiftPM's `sandbox_apply` fails `Operation not permitted` and manifest compilation dies → `--disable-sandbox`, harmless outside. `--scratch-path` unifies scratch with dev builds (`run.sh:83-84`). Note the guard is rc≠0 **OR** binary missing.

**Step 4/4 sign+deploy — the SIGKILL incident (`run.sh:95-106`).** `run.sh:96-101`: macOS pages text **on demand**, so a running instance keeps reading from disk; the old deploy `cp`'d **in place over the same inode**, the kernel read mixed old/new pages, CDHash verification failed and it killed the process (Taskgated Invalid Signature, 9/10 DiagnosticReports). Now:
```
codesign --force --deep --sign - "$BIN_SRC"               run.sh:104   (ad-hoc)
cp "$BIN_SRC" "$BIN_DST.tmp.$$" && mv -f ... "$BIN_DST"   run.sh:105   (new inode)
xattr -d com.apple.quarantine "$BIN_DST"                  run.sh:106
```
`mv` gives the new instance a fresh inode while the old keeps the old vnode (post-unlink survival, `run.sh:100-101`). `codesign` and `xattr` are `|| true` (`run.sh:104`, `:106`).

**Bundle (`run.sh:108-145`).** `mkdir -p Contents/MacOS` (`:110`); binary via temp+mv (`:111`); Metal precompile (`:112-130`): `xcrun -sdk macosx metal -c Vendor/MetalGoose/Engine/Shaders.metal -fmodules-cache-path="$ROOT/.build/metal-cache" -o /tmp/Shaders.air` → `metallib` → `Contents/Resources/default.metallib`, also copied to `$ROOT/default.metallib`; two locations required because a bare-executable launch has a meaningless `Bundle.main` (`:112-116`); failure non-blocking, prints "✗ 预编译失败 (回退运行时编译)" (`:127-130`). `-fmodules-cache-path` (`:118-120`) because metal's clang ModuleCache defaults to `/var/folders/`, rejected `Operation not permitted` in restricted envs. **This is why `default.metallib` shows `M` in `git status`: every `run.sh` rewrites the tracked file.** `Info.plist` heredoc (`:131-143`): `CFBundleExecutable=AuroraDriveUI`, `NSPrincipalClass=NSApplication`, `CFBundleIdentifier=com.aurora.driveui`, `CFBundleName=AuroraDrive`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=1.0`, `CFBundleVersion=1`, `LSMinimumSystemVersion=14.0` — the last contradicts `Package.swift:51` `.macOS(.v26)`, and the plist is regenerated every run (not a versioning source of truth). Re-sign (`:144`), de-quarantine (`:145`), `pkill -f "AuroraDriveUI"` (`:148`) — kills by **command-line substring**, also matching the bare binary.

**Launch (`run.sh:158-182`).** Bundle preferred: LaunchServices gives a clean parent (`:167`). `--auto-login` → `open "$BUNDLE_DIR" --args --auto-login` (`:172`): login watchdog, checks every 8 s and clicks until success or 80 s; exits quietly if already logged in or game absent (`:168-170`). Default plain `open "$BUNDLE_DIR"` (`:175`), auto-login off (`:176`). Triage (`:179-181`): Screen Recording, Accessibility, or run `./AuroraDriveUI` bare. `--yolo-selftest`/`--yolo-bench` exec `./$BIN_DST <flag> <arg>` (`:159-164`); a missing second arg makes the `&& [ -n "$2" ]` guard fail and falls to the `else` at `:165` — so `./run.sh --yolo-selftest` **builds, deploys and launches the GUI** instead of erroring.

## 2.2 Manual build

```sh
swift build -c release --disable-sandbox --scratch-path .build/scratch
swift build 2>&1 | tail -30          # incremental check
./AuroraDriveUI --lean-selftest      # after deploy
```
`--disable-sandbox` only needed in sandboxed harnesses (`run.sh:81-83`); `rm -rf .build` only for "cache made my change invisible" (`run.sh:76`).

## 2.3 `scripts/build-lock.sh`

Why (`build-lock.sh:6-17`): SwiftPM is whole-module, so concurrent edits + builds give `error: input file '.../AuroraTheme.swift' was modified during the build`, and one broken file blocks **everyone** — an "infrastructure defect". Second reason: 3 agents running `--mc-map-bench --iters 200` at ~85 % CPU each drove loadavg to 5.15 on 8 cores, making timing incomparable; therefore **long tasks (selftests / benches / gate collection) must also hold the lock**.

```
bash scripts/build-lock.sh acquire "阶段A验收"   # exit 3 if not acquired
bash scripts/build-lock.sh release | status
bash scripts/build-lock.sh run "原因" -- <cmd...>
```
`build-lock.sh:19-23`, dispatch `:140-146`. Env: `AURORA_BUILD_LOCK` (default `${TMPDIR:-/tmp}/aurora-build.lock`, `:37`), `AURORA_BUILD_LOCK_STALE_MIN` (15, `:38`), `AURORA_LOCK_OWNER_PID` (`:65`, `:102`).

`mkdir` is the atomic primitive because macOS `bash` 3.2 has **no `flock` command** (`:30`); the lock dir carries `owner` (`pid`, `time`, `host`, `user`, `reason`, `cwd`; `:64-71`, read `:48-51`); stale locks are **reported, never auto-deleted** — age ≥ STALE_MIN prints "但**不自动删**（万一真的还在跑）" (`:91-94`), and a dead pid prints `rm -rf` instructions (`:87-90`); `release` refuses another pid's lock (`:102-106`); `run` acquires/executes/releases (`:129-138`) by plain sequential calls **not a `trap`**, so a `set -e` abort inside the wrapped command skips the release — recommended pattern `trap 'bash scripts/build-lock.sh release' EXIT` (`:26-27`). `UNVERIFIED:` whether a wrapped crash leaves stale locks. Caveat: `age` uses the dir birth time via `stat -f %B` (`:57`), which does not survive copying, so a restored lock can read as fresh (`UNVERIFIED:` not tested).

## 2.4 `scripts/check-package-sources.sh`

229 lines; Python body in a heredoc (`check-package-sources.sh:29`) because `/bin/bash` 3.2 has **no associative arrays** (`:27`). Guards (`:6-19`): orphan `.swift` in no target; non-`.swift` inside `Sources/AuroraDrive/` (warnings); new top-level dir/file missing from `exclude` (warning **and** a full repo-root walk every build). History: `sources:` was a per-file whitelist until 2026-10-04 (P5-A7), causing `cannot find 'Xxx' in scope` on add/remove; now directory-level. Usage (`:21-23`): exit 0 / 1 divergent; `--gen-exclude`. Mechanics to `:80`: `set -uo pipefail` (`:24`, no `-e`), `ROOT` from `$0` (`:25-26`), `match_bracket(...)` (`:39-51`), `re.finditer(r'\.(?:executable)?[Tt]arget\(', src)` (`:56`), paren-depth block extraction (`:58-67`), fields `name`/`path`/`sources`/`exclude` (`:68-79`). `UNVERIFIED:` checks after line 80.

## 2.5 Other scripts

8 entries, 1,602 shell lines: `build-lock.sh` 146, `check-package-sources.sh` 229, `gpu-attrib.sh` 133, `paired-ab.sh` 413, `perf-snapshot.sh` 334, `regression-gate.sh` 270, `setup_toolchain.sh` 77, `README.md` 263 (`UNVERIFIED:` not read). Only `check-package-sources.sh` (`Package.swift:92`) and `build-lock.sh` are wired into artifacts read here.

## 2.6 Build-failure triage

| symptom | cause | source |
|---|---|---|
| `cannot find 'X' in scope` after adding a file | `sources:` per-file before 2026-10-04 | `Package.swift:81-88`, `check-package-sources.sh:11-13` |
| `found N file(s) which are unhandled` | top-level dir/file missing from `exclude` | `Package.swift:88-92`, `check-package-sources.sh:17-19` |
| 500+ `static let shared` / "main actor-isolated default value" | `.swiftLanguageMode(.v5)` lost | `Package.swift:193-203` |
| `Operation not permitted` in manifest | SwiftPM `sandbox_apply` | `run.sh:81-83` |
| `library not found` | relative `-L` | `Package.swift:16-17` |
| undefined `carotene_o4t::*` | HAL libs unlinked | `Package.swift:31-33`, `:41-46` |
| undefined `_cblas_sgemm$NEWLAPACK$ILP64` | `Accelerate` unlinked | `Package.swift:32`, `:70` |
| `input file '...' was modified during the build` | concurrent builds, no lock | `build-lock.sh:7-11` |
| build "succeeded", change invisible | SwiftPM cache | `run.sh:76-77` |
| old behaviour after `run.sh` | deployed binary is `AuroraDriveUI`; `pkill -f AuroraDriveUI` then `open` | `run.sh:11-12`, `:105`, `:148`, `:175` |
| GUI won't open | Screen Recording / Accessibility | `run.sh:179-181` |
| `Taskgated Invalid Signature` / SIGKILL at deploy | in-place `cp` over a running inode | `run.sh:96-101` |

---

# SEC-03 — DUAL PROCESS / IPC / SINGLETON LOCK / ENGINE HANDOVER

From `Sources/AuroraDrive/Core/EngineMain.swift` (2395 lines) and `Sources/AuroraDrive/Core/EngineClient.swift` (1121 lines).

## 3.1 Two processes, one binary

`AuroraDrive` is one executableTarget (`Package.swift:77-79`); the mode is chosen by argv.

| aspect | detail | evidence |
|---|---|---|
| UI process | SwiftUI app, `@main AuroraDriveLauncher` | `EngineMain.swift:7` |
| engine process | same binary with `--engine` | `EngineMain.swift:5`, `EngineClient.swift:404` |
| dispatch | splits at the very front, **before** SwiftUI | `EngineMain.swift:7-9` |
| engine never touches | SwiftUI, windows, `NSApp.run()` | `EngineMain.swift:7-8` |
| TCC | inherited through the process chain (parent authorised → no prompt) | `EngineMain.swift:9` |
| engine entry | `static func run() -> Never` | `EngineMain.swift:1077` |

The engine contains the whole SwiftUI/AppKit code and its own `DriveState()` (`EngineMain.swift:1234`), built from the same class code ("照搬主程序组装（同一份类代码）", `EngineMain.swift:19`), but never enters the UI run loop. State living only in a SwiftUI `@State` is therefore **absent** engine-side — root cause of several "works locally, broken in engine mode" bugs (§3.12).

## 3.2 Startup ladder — `EngineClient.startup()` (`EngineClient.swift:231-270`)

```
if AuroraFlags.uiLocal: wantsEngineMode=false; return   :232-237  (AURORA_UI_LOCAL=1)
wantsEngineMode = true                                  :238
if tryConnect(): activate(); return                     :240-243  (engine already there)
if !spawnEngine(): log "引擎 spawn 失败 → 回退本地模式"; return :245-248
poll tryConnect every 0.3s, ≤20 attempts (6 s)          :250-269
attempt 20 fail: log "等待引擎超时 → 回退本地模式"        :261-263
```
**Connect before spawn**: a healthy engine already listening is attached to, never duplicated (`EngineClient.swift:8-9`). Every failure degrades to local mode with `isActive == false` (`EngineClient.swift:14`). `activate()` (`:272-280`) sets `isActive/isConnected`, stamps `lastHeartbeat`, `attachShm()`, then `onActivated?()` to push display/upscale state. `tryConnect()` (`:286-322`): `sockaddr_un`, guard `pathBytes.count <= sun_path` (`:294-296`), connect, `DispatchSource.makeReadSource` (`:313-318`), send `status` (`:320`).

## 3.3 Spawn (`EngineClient.swift:394-418`)

```
exeURL = CommandLine.arguments[0] standardized + resolvingSymlinksInPath()  :396-397
guard isExecutableFile(atPath:) else log + return false                     :398-401
process.arguments = ["--engine"]                                            :404
stdout & stderr appended to engineLogPath via one FileHandle                :405-409
try process.run(); log "spawn 引擎 pid=..."                                  :410-413
catch: log "spawn 失败: \(error)"; return false                             :414-417
```
- Launched from `argv[0]` **resolved through symlinks**, not `Bundle.main` — bare and bundle launches both spawn the right binary. `UNVERIFIED:` bundle-relative restart after the binary is replaced on disk mid-session.
- Child stdout/stderr go to the **engine** log; that is why engine `print` was invisible until `EngineMain.swift:1078-1085`.
- The UI never sets `environment`, so both processes share env vars (`AURORA_FORCE_YOLO26S` is the example) (`EngineMain.swift:906-907`).

## 3.4 Socket, protocol version, staleness

- `~/Library/Application Support/AuroraDrive/engine.sock` (`EngineMain.swift:17`, built `:1189-1191`); parent made at `:1089-1090`.
- `protocolVersion = 3` (`EngineClient.swift:115`). History (`:108-114`): 1 = `start/stop/bye/status/upscale/ping`; 2 = `record/reloadmodel/config` + heartbeat `recording/frames/proto`; 3 = shm gained the **mask area**, `pixelsOffset` `20480 → 28672` — old UI on new engine would read mask bytes as pixels.
- `isEngineStale = sawHeartbeat && engineProtocol != protocolVersion` (`EngineClient.swift:330-332`). It **must** key on `sawHeartbeat`, not `engineProtocol != 0`: an old engine never sends `proto`, so 0 means "absent", and treating 0 as unknown would exactly miss "new UI × old engine" (2026-09-12, measured) (`:324-329`).

**Three traps in `relaunchStaleEngine()` (`:336-343`)** — ① `bye` does not stop the engine (it only `pauseDriving()`s then waits 30 s idle), so a real `kill` is mandatory; ② must wait for the old process to die before `startup()`, else `tryConnect()` reattaches (connect → stale → restart → stale) and the flock makes the *new* engine `exit(0)` at once; ③ must reset `sawHeartbeat`, else staleness is re-declared immediately. Sequence (`:351-380+`): cancel read source, close fd, `detachShm()`, cancel timer (`:352-357`); clear `isActive/isConnected/engineProtocol/sawHeartbeat/lastHeartbeat/enginePID` (`:358-364`); `kill(pid, SIGTERM)` (`:366-368`); poll 0.4 s ≤8 s, escalate `SIGKILL` once `waited >= 1.2` while alive (`:369-380`); `startup()` only after death. Refused while **driving** (`:344`).

## 3.5 Engine singleton — flock (`EngineMain.swift:1092-1105`)

```
lockPath = AppSupport/engine.lock                                :1093
lockFD = open(lockPath, O_CREAT|O_RDWR, 0o600); if <0 → exit(3)  :1094-1098
flock(lockFD, LOCK_EX|LOCK_NB) != 0 → log "已有引擎实例在运行（flock 失败），本进程退出"; exit(0)  :1099-1102
ftruncate(lockFD, 0); write pid + "\n"                           :1103-1105
```
Released by the **kernel on exit**, so no stale-lock cleanup exists or is needed (`:1092`). A second engine exits **code 0** — "someone else is doing the job" is a non-failure, which is why reclaim (§3.9) must wait for the old process; otherwise the new engine `exit(0)`s and the UI waits forever. The pid is post-mortem only; authority is the flock. Unrelated to `scripts/build-lock.sh` (SEC-02 §2.3).

## 3.6 Engine startup order (`EngineMain.swift:1077-1256+`)

0. `setvbuf(stdout/_IOLBF)` + stderr (`:1084-1085`): stdout is redirected to a file and stdio block-buffers 4 KB, so `print("[cap-deep] ...")` stayed in memory and the log was empty — misread as "the code never ran" (`:1078-1083`). The UI path already did this at `AuroraDriveApp.swift:751`.
1. Create `~/Library/Application Support/AuroraDrive` (`:1088-1090`). 2. flock (§3.5).
3. **TCC fail-fast** (`:1107-1155`): `axOK = AXisProcessTrusted()`, `screenOK = CGPreflightScreenCaptureAccess()`; default `axOK && screenOK`; failure → `exit(2)` "权限须由父进程链继承". Bypass `AURORA_ENGINE_DIAG_SKIP_TCC=1` warns, "仅供无 TCC 环境验证非权限逻辑，正常路径禁用" (`:14-15`, `:1142-1143`). **Observe-only relaxation** (`:1114-1155`): under `AURORA_OBSERVE_ONLY=1` the predicate narrows to `screenOK`, since that mode forces `controlDisabled = true` and injects zero keys. Not "skipping checks": the non-observe predicate is unchanged and `ControlEngine.hold()`'s `guard hasAccessibilityPermission` returns early (`:1132-1138`).
4. `GameModeDefender.shared.start()` (`:1157-1159`).
5. **Anti-freeze**: `beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])` with the token **retained** (else released immediately) (`:1161-1165`), then `setpriority(PRIO_PROCESS, 0, -20)` (`:1166-1168`).
6. **Signals** (`:1170-1187`): `SIG_IGN` for SIGTERM/SIGINT first, then one `DispatchSource.makeSignalSource` per signal; handler sets `EngineGlobals.shutdownRequested = true` and hops to main for `performShutdown(reason: "signal \(sig)")`. Two-stage so the tick loop sees the flag (`:1309-1310`) while `releaseAll()` still runs on the main actor.
7. **Socket server** (`:1189-1224`): `EngineSocketServer(path:)` + `onLine → handleCommand`, `onClientDisconnected`, `onClientConnected`; `start()` failure → `exit(4)`.
8. **Shared memory** (`:1226-1230`): `EngineFrameShm()`; failure → `exit(5)`.
9. `DriveState` under `MainActor.assumeIsolated` (`:1232-1250+`): `EngineGlobals.state = DriveState()`, `isEngineHost = true` — no run loop (`dispatchMain`), no `NSEvent`, so keys come from `remoteKeyMask` (`:1235-1237`); upscale wiring overridden (`:1240-1250`) — no window/MTKView, so the engine forwards full frames through a lock-protected slot; `isUpscaleWanted`/`isYoloWanted` gates avoid mode-disabled work (`:1248-1254`).

Exit codes: `2` TCC, `3` lock file, `4` socket, `5` shm, `0` another engine running.

## 3.7 Command channel (`EngineMain.swift:1862+`)

One JSON object per line (`:1862-1870`); unparseable lines log "无法解析命令" and drop. An optional `id` is echoed; absent → **no ack** (`:1872-1874`).

| command | line | behaviour | | command | line | behaviour |
|---|---|---|---|---|---|---|
| `start` | `:1874` | `startDriving()`, clears `clientSaidBye` | | `reloadmodel` | `:2026` | model reload |
| `stop` | `:1887` | stop driving | | `config` | `:2060` | config push, main-async |
| `bye` | `:1899` | `pauseDriving`, engine keeps running | | `set_capture_mode`/`capture` | `:2196` | capture mode / hz |
| `status` | `:1910` | reply with state | | `state` | `:2257` | state query |
| `upscale` | `:1921` | `wantFullFrame` toggle | | `ping` | `:2271` | liveness |
| `record` | `:1934` | recording control | | | | |

Heartbeat (engine → UI) built at `:2307`: `type/proto/ts/fps/detections/isDriving/isStreaming/mode/modeRaw/speed/speedKmh/confidence/recording/frames/pid/takeover/userHolding/reason`. `recording` is `st.recordEngine.frameCount` and `frames` is the **same** value — the heartbeat's `frames` is the recording count, not capture.

## 3.8 Connection loss, reconnect, idle exit

UI: `readSocket()` (`EngineClient.swift:422-453`) buffers and splits on `0x0A` (`:428-436`); on EOF/error it **cancels the read source synchronously on the read queue** before hopping (`:447-451`). `:439-446` records the measured bug: one engine kill gave **12+ consecutive "连接断开"** lines because `read()` returning 0 left `readSource` alive, re-delivering the EOF every event-loop turn; cancelling inside an async block was too late. `handleConnectionLoss` `:628`; `tryReconnectSoon()` (`:455-474`) polls every 0.5 s only while `isActive` (`:456`).

Engine: `onClientDisconnected` (`EngineMain.swift:1195-1210`) — `clientSaidBye` → "UI 主动关闭（bye），引擎继续运行等待重连", no window; else "UI 连接异常断开，进入 3 秒重连窗口"; **both** start the idle countdown (`:1205-1207`). `onClientConnected` (`:1211-1220`) cancels both, clears `clientSaidBye`, sends an immediate heartbeat `reason: "client-connected"`.

`startIdleExitCountdown()` (`:2336-2352`): 30 s `asyncAfter`; re-checks `socket?.hasClient == true` and returns (`:2345`), else "30 秒无人使用，自动退出（先释放全部按键）" → `performShutdown(reason: "idle-exit")`. Cancel (`:2354-2358`).

`pauseDriving(_:)` (`:2360-2375`): `isDriving=false`, `controlEngine.releaseAll()`, **and stops recording** (`:2370-2373`) — otherwise 30 s of "car stopped, labels still the previous AI decision" poisons the imitation dataset (`:2367-2369`). Capture and inference keep running.

## 3.9 Handover: yield and reclaim

**Yield — `suspendForLeanRecording() -> Bool`** (`EngineClient.swift`, `:1011-1068`):
1. Cancel any pending reclaim poll **before** the guard (`:1012-1018`): while the engine leaves, `isActive`/`enginePID` are already empty, so a guard first would return false, skip the cancel, and the pending poll would `startup()` the engine again, contending for the same screen stream (`:1013-1015`).
2. Idempotent: if `suspendedByLeanRecording`, return true without re-signalling (`:1020-1025`) — only `suspendedPID` remains, long dead, and **pids get reused**, so a second kill could hit an innocent process.
3. `hadPendingResume` also counts as yielded (`:1027-1029`), else reclaim is never recorded.
4. `wantsEngineMode = false`, cancel `connectTimer` (`:1031-1034`).
5. `sendByeSync()` before killing (`:1035-1036`) so the engine skips its 3 s abnormal-loss window.
6. Store `pid = enginePID > 0 ? enginePID : suspendedPID` into `suspendedPID` before zeroing `enginePID` (`:1037-1042`) — reclaim must poll "is the old engine dead"; without it, the flock `exit(0)` hits.
7. Tear down: cancel read source, close fd, `detachShm()`, clear state (`:1043-1053`); shm must be unmapped or the new engine points at old memory.
8. `kill(pid, SIGTERM)`; **15 s** backstop to `SIGKILL` (`:1054-1063`) — SIGKILL loses the "keys released" guarantee.
9. No pid → log that only the connection was dropped (`:1064-1066`).

**Reclaim — `resumeAfterLeanRecording() -> Bool` (`:1084-1120`)**: clear the flag, `wantsEngineMode = true` (`:1085-1087`); read then zero `suspendedPID` (`:1090-1092`); no pid → `startup()` (`:1096-1099`); else poll 0.3 s ≤8 s for `kill(pid, 0) != 0` then `startup()` (`:1100-1119`); still alive → "⚠️ 旧引擎 pid=… 8 秒未退出，仍尝试拉起" and start anyway. `startup()` is re-run because SIGTERM made the engine **exit the process** (`:1072-1074`). Waiting matters (`:1076-1080`): after SIGTERM it still runs `releaseAll → stopDriving → flushSync → exit(0)` (hundreds of ms) with the socket present and the flock held — spawning then yields `exit(0)`, presenting as "the engine never comes back".

**Invariants**: only `SIGTERM` stops the engine, so a yield is `wantsEngineMode=false` **plus** a real SIGTERM and reclaim must not assume the pid is gone; shm unmapped before a new engine maps `/aurora_frame_v1`; order is strict (cancel reclaim → disable reconnect → bye → remember pid → drop connection → SIGTERM → wait death → startup). Refused while driving — `UNVERIFIED:` exact guard line; `EngineClient.swift:344` carries the same restriction.

## 3.10 Shutdown (`EngineMain.swift:2379-2394`)

```
if let st = EngineGlobals.state:
    st.stopDriving()          // includes controlEngine.releaseAll()   :2383
    st.recordEngine.flushSync()                                        :2386
else: ControlEngine().releaseAll()      // state not built yet         :2389
EngineGlobals.socket?.stop()                                           :2391
exit(0)                                                                :2393
```
`flushSync()` is mandatory (`:2384-2385`): `meta.json` is written via `writeQueue.async`, so an immediate `exit(0)` loses it. Callers: signal handler (`:1181`), tick-observed flag (`:1309-1310`), idle countdown (`:2347`). "SIGTERM before exit → `releaseAll`" is header component 7 (`EngineMain.swift:20`), to prevent a **stuck key inside the game**.

## 3.11 Shared memory — `/aurora_frame_v1`

Declared `EngineMain.swift:184`; `shm_open`/`shm_unlink` bridged via `@_silgen_name` (Swift cannot import the C variadic form; fixed 3-arg version `:43-49`). Layout byte-by-byte at `EngineMain.swift:112-166`: `magic 0x41555246` ("AURF", `:113`), `version = 1` (struct, distinct from socket `protocolVersion = 3`), `headerSize 4096` (`:115`), `detOffset 4096` / `detCapacity 256` / `detStride 64` (`:116-118`), `frameWidth/Height` (`:119-120`), `generation` bumped on resolution change (`:121`), `activePage` 0/1 double buffer ("翻转即新帧就绪", `:122`), `frameSeq` (`:123`), `timestampNs` (`:124`), `detectionCount` (`:125`), `flags` bit0 isDriving / bit1 isStreaming (`:126`), `fpsMilli` (`:127`), `enginePid` (`:128`), `pageSize` (`:129`), mask block `maskSeq/maskW/maskH/laneW/laneH/maskFlags/maskRatio/maskPadX/maskPadY/maskSrcW/maskSrcH/maskNewW/maskNewH` (`:130-142`).

**(a) `maskNewW/maskNewH` were a bug fix** (`:144-162`): `MaskOverlay`'s guard read `metrics.newW > 0` but the protocol never sent `newW/newH`, so `EngineClient` rebuilt `LetterboxMetrics` with `newW: 0` → guard always false → **in engine mode not one mask cell was drawn** ("只能看到检测框，看不到可行驶区域和车道线"). Local mode was fine (real `newW` from `yolopxEngine.metrics`), so local selftests could never catch it. Both applied: ① transmit the values; ② drop the draw path's dependence on `newW` (the math only used `ratio/padX/padY/srcW/srcH`) — ② was required because ① alone still blocks old clients. Compatible: fields sit in free header space (4096 bytes, only 125 used), nothing moved (`:161-162`).

**(b) Mask placement forced a layout bump** (`:191-198`): old `pixelsOffset` was exactly `20480` with no room for masks; `maskOffset = detEnd = 4096 + 256*64 = 20480` (`:198-199`), `maskGridMax = 160` (`:199`).

**(c) Masks are bit-packed and versioned** (`:168-181`): plain `UInt8` = 160×160 = 25,600 bytes per mask, 50 KB for two = **1.5 MB/s of pointless copying at 30 Hz**; bit-packed = 3,200 each, 6.4 KB total. Masks change only when YOLOPX produced output, and YOLOPX runs slower than tick, so unconditional resend would retransmit identical data half the frames; `maskSeq` changes trigger resend and the UI parses only on a new seq (`:179-181`). State in `EngineGlobals.maskSeq` / `lastMaskFingerprint` (`:648-652`).

## 3.12 Engine-mode blind spots

1. **YOLOPX never runs in engine mode** (`EngineMain.swift:22-34`): `tick()` early-returns via `tickEngineMode()` when `EngineClient.shared.isActive` (near `AuroraDriveApp.swift:3172`), and `yolopxEngine.infer(image:)` has exactly **one** call site repo-wide, after that return (same file `:3260`). So mask overlay reads empty masks and `yolopxEngine.isDegraded` stays at its initial `true`, so `LaneFallback` does not engage. Declared "既定设计"; masks in engine mode would need the 160×160 grid (~50 KB) in the shm protocol back-filled in `tickEngineMode` — **not done** (`:33-34`).
2. `DriveState.perceptionMode` is a **UI-process** property (`UNVERIFIED:` definition line; cited as `AuroraDriveApp.swift:5414` in `EngineMain.swift:890`). Nothing writes it engine-side, so `st.perceptionMode` stays initial `.ayolom` and engine-side gates are permanently A-model (`EngineMain.swift:889-895`); default `"ayolom"` justified at `:897-901` (`yoloEngine.loadIfNeeded()` has **zero** occurrences in EngineMain — quoted grep, `:898-899`).
3. Recorded keys come from `remoteKeyMask` (no `NSEvent`; `EngineMain.swift:1235-1237`).

## 3.13 Logging sinks

| sink | path | cap | rotation |
|---|---|---|---|
| engine | `~/Library/Logs/AuroraEngine.log` | 8 MB (`EngineMain.swift:59`) | backup `.1`, every 64 writes (`:61`, `:65-75`, `:86-89`) |
| UI client | `~/Library/Logs/AuroraEngineClient.log` | 2 MB (`EngineClient.swift:48`) | backup `.old`, every 64 writes (`:50`, `:55-65`, `:78-81`) |

Both rotate **before** writing (`EngineMain.swift:84-85`, `EngineClient.swift:76-77`). The engine log had no cap — 6.16 MB in a 5.71 h session (951 KB/h ⇒ ~22 MB/24 h, never cleaned), **70%** of it one "once every 5 s" statistics line, whose frequency was cut with the cap (`EngineMain.swift:55-58`). The client log is capped, not deleted, because it is the reconnect/protocol triage entry point; peak 2 MB + 2 MB = 4 MB (`EngineClient.swift:39-47`). Both write to `stdout` **and** a file because a GUI process's stdout is buffered and lost on exit (`EngineClient.swift:67-68`).

---

# SEC-04 — CAPTURE: CaptureEngine / SCStream / FRAME FORMAT / ROI / CAPTURE HZ

`Sources/AuroraDrive/Capture/CaptureEngine.swift` (1739 lines). Read: 1-100, `start()` 438-501, `startStream()` 504-567+, config/hot-hz 625-744, exclusion audit 1060-1113, callback 1116-1179.

Layer (`CaptureEngine.swift:98`): `final class CaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable` — one long-lived SCStream; the system pushes frames on change, memory flat, one stream feeds display + inference + recorder (`:92-97`, `:4-8`). The "30fps" class comment is historical.

## 4.2 Two capture modes (2026-10-08 rework, `CaptureEngine.swift:10-27`)

Header records the requirement **and the bug fixed**: original filter was `SCContentFilter(display:excludingWindows: [])` — exclude array **empty**, so the whole display (desktop + own UI) was captured, contaminating training data (`:17-19`). `.fullScreen` excludes all own windows (`:22`); `.window(id)` uses `SCContentFilter(desktopIndependentWindow:)`, inherently containing neither own UI nor desktop (`:23-24`); switching uses `SCStream.updateContentFilter(_:)` (macOS 12.3+) — no restart, no dropped frames (`:26-27`).

`enum CaptureMode` (`:45-63`): `.fullScreen` (`excludedWindowCount` diagnostics only, `:46-47`), `.window(id: CGWindowID)` = `SCWindow.windowID` (`:48-49`), `isWindowMode` (`:51-54`), `label` (`:57-62`). Enum not Bool (`:42-44`): it removes the illegal `isWindowMode=true, windowID=nil` state. `CapturableWindow` (`:70-90`) is a flat snapshot (`id`, `applicationName`, `bundleIdentifier`, `title`, `width`, `height`, `isGame`, `isOwn`, `displayLabel`, `sizeLabel`; `:72-81`, `:84-87`, `:89`) because `SCWindow` dies with its window (`:66-69`); re-resolved by `id` via `resolveWindow(id:)`.

## 4.3 Stream configuration

`makeStreamConfiguration(configHz:display:)` (`:632-661`) is a **static pure function shared** by `start()` and the hot path, because `updateConfiguration` needs the full config, not a delta (`:625-627`, `:526-529`).

| field | value | line |
|---|---|---|
| `width` | `targetW = 1280` | `:634`, `:646` |
| `height` | `(1280 * aspect).rounded()` | `:647` |
| `aspect` | `NSScreen` of `displayID` h/w; else `display.height/width`; else `9/16` | `:635-645` |
| `scalesToFit` / `queueDepth` / `showsCursor` | `false` / `3` / `true` | `:648`, `:654`, `:655` |
| `minimumFrameInterval` | `CMTime(value:1, timescale: tscale)`, `tscale = max(1, Int(safeHz.rounded()))`, `safeHz = max(1, min(120, finite ? configHz : 20))` | `:650-652` |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` | `:653` |

Aspect is critical (`:517-524`): defaults `preservesAspectRatio = true`, `scalesToFit = false` (shrink-only). Forcing a 3:2 screen (1470×956 pt) into 16:9 1280×720 letterboxes and **shifts every normalised coordinate** (`speedROINorm`, boxes, lane masks), so height derives from the screen's aspect.

Performance (`:509-537`): old native Retina **2940×1912 @30fps = 675 MB/s** via the WindowServer compositor competed for GPU; on a fanless Air M3 the game fell to 1-2 fps while training stored 640×360 JPEG and the model ate 180×320 (24× waste). Now 1280×832 @20fps = **85 MB/s**; at 45 fps it was 192 MB/s with one frame consumed per tick. Overall **7.9×** (`:535`). The block's own baseline is historical (`:536-537`: "两档基准都 20fps，应急冲刺提到 45fps") while the live authority is 15 fps both tiers, 20 Hz sprint (`EngineMain.swift:709-711`, `:868-885`) — **comment numbers drift; read `EngineMain.engineTickHz`.** Each build logs `WxH @fps`, aspect, MB/s (`:656-659`).

## 4.4 Hot frame-rate update and its unverified assumption

`setCaptureHz(_ hz: Double) async` (`:710-746`): clamp to `1...120`, non-finite → 20 (`:711`); store `targetCaptureHz` for a later `start()` (`:713`); not capturing → "未在捕获 → 只记 targetCaptureHz，下次 start() 生效" (`:715-718`); unchanged → skip (`:719-722`); primary = fresh full config + `try await stream.updateConfiguration`, then `activeCaptureHz = newHz` (`:724-730`); on throw await `pendingStopTask` then `stop()` + `start()` (`:731-742`).

**Documented as unverified** (`:686-700`): `SCStream.h:500` is quoted (`:668-679`) showing `updateConfiguration` has no availability beyond 12.3, usable at `.macOS(.v26)` (`:680-684`), but the header never says which fields are live-updatable and frame rate may be frozen at creation. So **"did not throw" ≠ "the rate changed"**, and setting `activeCaptureHz` on success is an **optimistic assumption** (`:689-690`). Measurement plan (`:692-699`): watch `[cap-deep] 📥 帧到达 #N` (every 60 frames ≈ 3.0 s at 20 fps) after `setCaptureHz(45)` (interval → ~1.33 s), or count a fixed 5 s window (20 fps → ~100, 45 fps → ~225); if ineffective the fallback becomes primary. `UNVERIFIED:` whether executed — the block still says "待批准编译后执行".

`activeCaptureHz` is deliberately **not** set on the fallback path (`:743-744`); it means "actually in effect" and only `startStream` sets it after `startCapture` succeeds (`:530`). Wiring (`:707-709`): as of 2026-10-12 it **is** called from `EngineMain.applyPerceptionMode` (mode switch, re-switch after recording) and `tickOnce`'s sprint linkage; those EngineMain line numbers are `UNVERIFIED:`.

## 4.5 `start()` (`:438-501`)

Probe log (`:439`); `guard !isCapturing` (`:440-443`); body in a `Task` (`:446`); **await `pendingStopTask` before building a new stream** (`:449-466`) — `stop()` sets `stream=nil`/`isCapturing=false` **synchronously** so the guard passes while the old `stopCapture()` still runs; starting then interleaves old-stop with new-start, symptom "停止后再选就没反应". Must be `await`, not a semaphore: `start()` runs on the **main thread** and a sync wait could deadlock (`:458-460`). Then `SCShareableContent.current` (`:473-482`), on failure emitting both `.error("获取屏幕内容失败（可能未授权）: ...")` and `.permissionDenied` (`:479-480`). Display prefers `CGMainDisplayID()` over `content.displays.first` (`:484-496`) to avoid an arbitrary-order display (`:484`). Then `await startStream(display:content:)` (`:499`).

## 4.6 `startStream()` (`:504-...`)

Logs `display.frame.size`/`width`/`height` to settle whether `SCDisplay.width` is pixels or points — Apple documents pixels but glyph templates need native resolution (`:505-507`); `UNVERIFIED:` the measured conclusion is not stated there. Config from `targetCaptureHz` (`:530`). Filter by mode (`:545-567`): `.window(id)` via `Self.findWindow(id:in:)`; a missing window **refuses to silently fall back to full screen**, sets `lastModeError`, reports `.error(reason)` **and** `onOwnUIWarning?(reason)` (selector turns red), then returns (`:549-557`). `.fullScreen` = `SCContentFilter(display:display, excludingWindows: own)` with `excludedOwnWindowCount = own.count` (`:563-567`).

## 4.7 Own-UI exclusion audit (`:1076-1093`)

The pixel-based "is our UI in there" check was **deleted**; principle "宁可漏报也不能误报" (`:1058-1072`, `:1060-1061`). The single root cause of "we recorded ourselves" is `excludingWindows: []`, so the audit asserts the invariant: in full-screen mode, if own windows exist on screen the exclusion list **must be non-empty** and the excluded count must be ≥ overlapping own windows (`:1063-1067`) — necessary and sufficient, cannot false-positive, blocks "someone reverted the filter to an empty array". Cost: once per `start()`/`applyMode()`, reusing `SCShareableContent`, zero extra syscalls (`:1071-1072`). Implementation filters `ownWindows(in: content)` by `isOnScreen && frame.intersects(display.frame)` (`:1079-1082`), with distinct messages for empty (`:1083-1087`) and `excludedCount < overlapping.count` (`:1088-1091`), else nil. `ownUIWarningFired` = once per session (`:1095-1096`), skipped in window mode (`:1100`), re-armed by `resetOwnUIWarning()` (`:1110-1113`).

## 4.8 Per-frame callback (`:1118-...`)

1. Only `.screen`; audio ignored (`:1120`). 2. `_deepFrameCounter` published as `capturedFrameCount` (`:1123-1125`) — the "is capture alive" signal **independent of recording** (`:1124`); probes print the first 3 frames then every 60th (`:1126-1128`). 3. **Whole body in `autoreleasepool`** (`:1130-1133`): the delegate callback gets no automatic pool, so at 30 fps `NSImage`/`CGImage`/`CGDataProvider`/`vImage` temporaries would accumulate. 4. Timing probes: `lastFrameGapMs` = 0 for frame 1 because `lastFrameTime` starts `.distantPast` (~5e11 ms fake gap) (`:1137-1144`); `defer` records `lastFrameWorkMs` so **failed frames still get diagnostics** (`:1146`); `updateFPS()` (`:1147`).

5. Four optional consumers, each gated **before** its copy:
- `onNativeFrame` — `copyNativeFrame(from:)` from a private `CVPixelBufferPool`, row order from `src.bytesPerRow`, no orientation reinterpretation. Reason (`:1149-1154`): SCStream's buffer may be recycled if the main thread is slow → use-after-release (garbage crop or crash).
- `onUpscaleFrame` — gated by `isUpscaleWanted()`; the copy must land in a private buffer **with an IOSurface** or downstream `CGImage` creation crashes (`MG-ENG-001`) (`:1159-1166`). Gate-before-copy skips even the full-res copy when upscaling is off (`:1161-1162`).
- `onRecordFrame` — gated by `isRecordFrameWanted()`; **copy synchronous on captureQueue (≈4 MB memcpy, sub-ms), JPEG encode and disk I/O on the recorder's background queue** (`:1168-1176`). Incident: synchronous heavy work here pushed `capGap` from **11 ms to 2081 ms** (`:1172`).
- `onYoloFrame` — CPU `vImage` downscale to `YoloEngine.inputSize` (640) at the source, avoiding `大图 → NSImage → CGImage → 再缩放` (`:1178-1179+`); gated by `isYoloWanted()`.

6. `isUpscaleWanted`/`isRecordFrameWanted`/`isYoloWanted` are `() -> Bool` closures per frame, "完全同款模式" (`:136-138`, `:159`, `:163`, `:179`); the engine installs them so mode-gated work is never done (`EngineMain.swift:1248-1254`).

| closure | resolution | gate | consumer |
|---|---|---|---|
| `onNativeFrame` | native copy, row order preserved | always (if set) | display path |
| `onUpscaleFrame` | true full resolution | `isUpscaleWanted()` | MetalGoose interpolation |
| `onRecordFrame` | full resolution | `isRecordFrameWanted()` | lean recorder |
| `onYoloFrame` | 640×640 CPU-scaled | `isYoloWanted()` | yolo26s / optical flow |

## 4.9 Invariants

One instance serves recording **and** autodrive (`:514-515`). Never encode/OCR/infer/block on the SCStream callback queue (`:1170-1172`). `start()` after `stop()` must await `pendingStopTask` (`:452-456`). The operating rate is dispatched at runtime; `CMTime(value:1, timescale:45)` in older code is an upper bound (`EngineMain.swift:724-725`). Window mode never falls back to full screen (`:549-556`). Own-window exclusion is necessary and sufficient (`:1063-1069`); breaking it silently contaminates training data (`:17-19`).

---

# SEC-05 — RECORDING: LeanRecordEngine / CSV CONTRACT / LeanAnnotator / LEGACY RecordEngine

Read: `Sources/AuroraDrive/Capture/LeanRecordEngine.swift` (852 lines; header 1-130, `start/stop` 234-295, `appendFrame` 302-343+, `writeFrame`/`appendCSVRow` 400-529, `noteCadenceForContract` 555-598, `makeSessionDir`/`openSession`/`closeSessionLocked` 602-723), `Capture/CaptureEngine.swift:1168-1176`. `RecordEngine.swift` (771) and `LeanAnnotator.swift` (597) are pinned by symbol/size only; anything not read is `UNVERIFIED:`.

## 5.1 Why a second recorder

Header `LeanRecordEngine.swift:4-49`. The existing `RecordEngine` "expert mode" was too heavy in the UI process: per frame it read the keyboard, generated continuous-value labels, scaled to 640×360 and competed with OCR/glyph/interpolation for the main thread — in practice it slowed capture. The user's 2026-11-03 decision (`:9-10`): a **very thin** recorder running **no models at all** during recording, pushing heavy work to offline annotation.

## 5.2 What it does — exactly two things (`:12-14`)

1. Encode the **full-resolution** frame from the capture layer into JPEG and write it to disk. 2. Record a timestamp and a **key snapshot** at 15 Hz — the keys *are* the V3 training labels.

## 5.3 What it deliberately does not record (`:16-26`)

It initially also parsed position/heading/acceleration from libpcap and wrote **19 columns**; the user rejected it. Three accepted reasons (`:19-25`): V3 learns **screen → keys**, so position is neither input nor supervision — `dataset_v3`'s `REQUIRED_COLUMNS` needs only `t_sec/frame` + 8 keys and reads **not one** of `x/y/z/pitch/heading/accel`; position is human map information, a **display-layer** concern; capture required locking a NIC and asking permissions, and on failure the columns were left blank. ⟹ whole column set deleted, CSV **19 → 11 columns**, `poseProvider` wiring removed.

Also not recorded, because all of it is offline (`:28-32`): speed OCR (the full frame already contains the speedometer, so `speedROINorm` is cropped offline — a separate "speedometer strip" was explicitly rejected), supersampling to 384×224 (offline, so the input size can be changed and retrained), coordinate tables / world model / any perception model.

## 5.4 The one hard data invariant: CSV row index ⇄ frame filename

`LeanRecordEngine.swift:34-40` states it and the upstream reading that forces it: `dataset_v3._build_index` computes `n_frames = len(rows)` and resolves each image as `frames/{j:06d}.jpg` where `j` is the CSV **row order**. Therefore **CSV row j must correspond to `frames/0000jj.jpg`**. Failure mode (`:38-40`): if frame numbers were pre-assigned on the main thread and one JPEG encode failed and was dropped, every later number shifts by one — the whole batch's labels no longer match its images **and nothing reports an error**. Hence numbers advance only after a successful write; a failed write retries/drops the frame and writes **no CSV row** (`:40`).

Five defence mechanisms:

1. **Number allocated in the write queue, not the main thread** (`:42-48`: `start()`/`stop()` on main, `appendFrame` on captureQueue, JPEG + disk + CSV on the serial `writeQueue`).
2. **Generation check before taking `framesDir`/`nextFrameIndex`** (`writeFrame` `:406-424`): a frame captured in an old session, if the session rotated (auto-segment = stop→start) meanwhile, would land in the new segment at index 0 (`:408-411`).
3. **Image first, CSV row second** (`:447-460`): "图片已落盘，才写 CSV 行". If the row fails, the **image is deleted** (`:450-455`), because a leftover image with no row shifts every later filename. The number does not advance, so the next frame reuses the index (`.atomic` overwrite) — even a failed delete leaves no permanent hole.
4. **No "file exists → next index" retry branch** (`:435-441`): `.atomic` overwrites anyway (dead code), and if it ran, `idx += 1` would leave a hole in `frames/` while the row still says `idx`.
5. **`appendCSVRow` returns Bool** (`:481-529`): the earlier bug incremented a counter and returned while `writeFrame` still advanced `nextFrameIndex` → image present, row missing, later indices advancing → the training side's index→filename map is off-by-N and `dataset_v3`'s `frame == i` check raises `ValueError`, making the **entire segment unloadable**.

Two API traps inside `appendCSVRow`: `try handle.write(contentsOf:)` rather than `write(_:)` (`:508-511`) because `FileHandle.write(_:)` is non-throwing and **raises an ObjC exception** on disk-full/IO error, which `do/catch` cannot catch → it crashes the app, and a mid-recording crash leaves an unflushed CSV. And the handle is force-unwrapped via `guard let handle = csvHandle` (`:513-523`) because `try csvHandle?.write(...)` returns `true` on `nil`, letting the caller believe the row was written and advance the number; both fields are assigned/cleared under one lock (`openSession:558-559` / `closeSessionLocked`), so the state is currently unreachable — kept as a zero-cost defence.

## 5.5 CSV format — 11 columns, header once per session

Header verbatim (`LeanRecordEngine.swift:649-650`):
```
t_sec,frame,speed_kmh,w,a,s,d,shift,space,super_brake,ultimate_brake
```
Rows (`:497-502`) built by **string concatenation**, not `String(format:"%@…")` (`:493-496`): `%@` relies on String→NSString `CVarArg` bridging with unpredictable output for empty/non-ASCII values, while concatenation is deterministic and the column count is visible.

Fields: `t_sec` = `String(format: "%.5f", tSec)`, `tSec = date.timeIntervalSince(sessionStart)` (`:448`, `:497`); `frame` = integer `idx` (`:497`); `speed_kmh` — **always empty, never `0`** (`:489-491`, `:498`), because `dataset_v3` treats empty as `speed_valid=0` while `0` means "the true speed is zero", a wrong supervision signal; real speed is filled by offline OCR. `w,a,s,d,shift,space,super_brake,ultimate_brake` = the 8 V3 native key labels from `RawKeySample` (`:499-502`).

Key codes (project-wide authority): A=0, D=2, W=13, S=1, Space=49, LeftShift=56. `UNVERIFIED:` not re-derived from source this session; pinned in SEC-12 §12.6.

Session files from `openSession` (`:634-685`): `view.txt` = `viewLabel`, default `"TPV"` (`:119-121`, `:640-643`), written only if absent — `dataset_v3` reads it only when `view_filter` is passed and `train_v3.py:263` passes none, so a missing file does not drop the segment, but keeping the file set identical avoids a future silent skip (which **does not error**, it just yields fewer samples). `controls.csv` created with the header (`:651`) then reopened and seeked to end (`:654-655`). `frames/` via `makeSessionDir` (`:626-627`). `meta.json` at close (§5.6).

State reset in `openSession` (`:657-683`): `sessionDir`, `lastClipDir`, `framesDir`, `csvHandle`, `sessionStart` (`:658-662`); `sessionGeneration &+= 1` so in-flight old frames are discarded (`:663-664`); `frameCount = 0`, `writeFailureCount = 0`, `nextFrameIndex = 0` (`:665-667`); `framesWrittenLocked = 0` — the **authoritative** counter, else segment 2 inherits segment 1's count (`:668-669`); `lastFrameWidth/Height = 0` (`:670-671`); `restartedPending = false` (`:672`); `lastAcceptedFrameTime = nil` — else the 10-minute auto-segment drops one frame at every segment start (`:673-675`); `cadenceIntervals.removeAll` + `contractBreachStreak = 0` — else the new segment inherits old interval samples and could be stopped for jitter belonging to the old one; the contract is evaluated **per clip** (`:676-681`); `lastError = nil` (`:682`).

Naming (`makeSessionDir`, `:602-632`): `clip_<yyyyMMdd_HHmmss>` under `clipsRoot`, matching the repo convention (training scans only the `clip_` prefix; cleanup relies on lexicographic ≈ chronological, `:609-611`). **Name collisions are never accepted** (`:612-624`): second-precision timestamps and auto-segment `stop()`→`start()` necessarily land in the same second; `createDirectory(withIntermediateDirectories:)` does **not** error on an existing dir, and `createFile` would **truncate** the previous `controls.csv` while frames restart at `000000` — the whole segment silently lost. A numeric suffix `_2 … _999` is appended; beyond 999 returns nil (`:622`).

## 5.6 `meta.json`

`struct LeanRecordMeta` (`:61-88`): `fps/width/height/frames/framesFailed/durationSeconds/segmentIndex/note` (`:62-69`). `jsonObject(createdAt:)` emits `mode:"lean"`, `created_at`, `fps`, `width`, `height`, `total_frames`, `frame_write_failures`, `frames_complete` (`framesFailed == 0`), `duration_seconds`, `segment_index`, `speed_source:"offline_ocr"`, `needs_annotation:true`, `note` (`:71-87`). Note at close (`:714`): "只录画面与按键；speed_kmh 列为空，需跑离线标注回填。"

Why meta exists (`:58-60`): recording-time **silent failures cannot be reconstructed from the data** — e.g. frame rate drifted out of tolerance so the training side rejects the segment, yet the files look normal.

`closeSessionLocked()` (`:687-723`), only from `writeQueue.sync`: `csvHandle?.synchronizeFile()` then `closeFile()`, `csvHandle = nil` (`:690-692`); counters read **under the lock** (`:697-704`) and must read `framesWrittenLocked`, not the `@Observable frameCount` (updated via `DispatchQueue.main.async`, may not have run → under-report) (`:694-696`); `meta.json` written `.atomic` (`:722`), non-optional because a partial JSON from a crash/power loss fails to parse and by then the segment was already handed to the annotator via `onSegmentClosed`, losing the only self-description of usability (`:719-721`); width/height from the **actual pixel buffer** per frame (`:464-467`), else meta permanently says 0×0 (`:465`).

## 5.7 `start()` / `stop()`

`start() -> Bool` (`:234-263`): `guard !isRecording` (`:235`); disk check **on the volume actually written to** (`:237-245`) — `Self.freeDiskBytes(at: clipsRoot)` vs `minFreeDiskBytes` (default 2 GiB, `:117`), because `projectRoot` may be a different volume (switch disk / external / selftest `clipsRootOverride`), so authorising writes to disk B with disk A's free space and running truly full invalidates the segment (`:238-239`); failure names free space and floor, returns false, does **not** delete user data (`:116`, `:241-243`); `makeSessionDir()` (`:247-251`); `openSession()` (`:252-256`); `isRecording = true` under lock, log `▶ 开始精简录制 → <dir>（15.0 fps，段 N）` (`:258-262`).

`stop()` (`:266-295`): `guard isRecording` (`:267`); `isRecording = false` **first** (`:269-271`); `writeQueue.sync { closeSessionLocked() }` (`:273-277`) — serial queue so it is ordered after every enqueued frame; `stop()` drain happens after the last write, else tail rows are lost (`:273-274`); log totals from `framesWrittenLocked`/`writeFailureCount` (`:279-287`), stating skipped CSV rows kept numbering paired (`:285-287`); `onSegmentClosed?(closedPath)` **last** (`:288-294`) — it must **not** annotate here, because auto-segment immediately `start()`s and annotating would compete for CPU (`:290-291`).

## 5.8 Per-frame admission — the one-way 15 fps gate

`appendFrame(pixelBuffer:)` (`:298-343+`) runs on **captureQueue** and only takes timestamp + key snapshot + enqueue (`:299`). The buffer is already a private copy from `CaptureEngine.copyRecordFrame`, so holding it until write completes is safe (`:300-301`).

Rate limiting (`:305-330`), **before** taking the timestamp (`:305`): this is **not** compressing 20 fps to 15. The UI capture baseline is 15 fps and the UI only calls `start()`, never `setCaptureHz` (20/45 are **engine-process** values, unrelated). The gate defends against **extra SCStream pushes**: a violently changing picture gets more frames, accepting them all compresses `t_sec`, while `dataset_v3` validates `actual_fps = 1/median(dts)` against 15 ± 15 % (**12.75–17.25**) and raises `ValueError` — the entire dataset becomes unloadable.

Threshold `minGap = period * 0.9` (`:329-330`), not a strict `1/15`: a real 15 fps source jitters around 66.7 ms, so pinning to 66.7 ms would reject normal frames, lowering the effective rate below the tolerance floor (`:314-316`).

**Documented blind spot of a one-way gate** (`:318-327`): it never enforces "not too slow". If SCStream stalls to ~10 Hz, ~100 ms intervals pass every time, `median(dts)` leaves 12.75–17.25 and `dataset_v3` raises on the whole segment. Rejecting slow frames cannot fix it — the next frame compares against the last *accepted* time, so intervals only grow until everything is rejected, and rejecting cannot turn 10 Hz into 15 Hz. The chosen response is to **monitor actual rate with `dataset_v3`'s own criterion and stop with an explicit reason** rather than silently producing ten minutes of unloadable data.

Lock discipline (`:331-341`): the `isRecording` check and the generation read happen in **one** lock acquisition. Split, a rotation between them would carry an old segment's frame into the new one at `nextFrameIndex=0`, overwriting `000000.jpg` — old segment loses a frame, new one gains an old picture, numbering stays contiguous ⇒ `dataset_v3` reports nothing. Rate-limited frames are excluded from cadence statistics (`:342-343`).

## 5.9 Cadence monitor — the training contract enforced at record time

`noteCadenceForContract()` (`:555-598`), called per frame from `appendFrame` (`:363`). Fields: `cadenceIntervals`, `cadenceWindow = 120`, `contractBreachStreak`, `contractBreachLimit = 45`, `contractMinSamples = 30`, `contractFpsTolerance = 0.15` (`:196-205`); `contractBreachLimit`/`contractMinSamples` are `var` so a selftest can shorten them to trigger deterministically — same convention as `maxSegmentSeconds` (`:199`, `:114`).

Algorithm (`:556-598`): lock → require `isRecording` and `cadenceIntervals.count >= contractMinSamples` → **median** of intervals (even/odd aware, `:561-565`) → `actualFps = 1/medianDt` (`:570`) → `deviation = |actualFps - fps| / fps` (`:571`) → `breached = deviation > contractFpsTolerance` (`:572`) → streak increments/resets (`:573-577`) → unlock → require `breached && streak >= contractBreachLimit` (`:581`) → **report only at the exact crossing** `streak == contractBreachLimit` (`:582-583`), since this runs every frame.

Message (`:585-587`): `实测 X.XXfps 已持续偏离 YHz 超过 ±Z%（dataset_v3 会拒载整段），已停止录制`.

Stop must be hopped to main (`:589-597`): calling `stop()` on the capture queue would run its `writeQueue.sync {}` and block on disk I/O — the recorded capGap 11 ms → 2081 ms incident. `DispatchQueue.main.async`, and the closure re-checks `isRecordingSnapshot` before stopping and setting `lastError`.

## 5.10 Threading model

| context | work | rule |
|---|---|---|
| main | `start()`/`stop()`, segment rotation | `stop()` drains via `writeQueue.sync`; never call from captureQueue |
| captureQueue (SCStream) | `appendFrame`: timestamp, key snapshot, rate gate, enqueue | **no JPEG, no disk I/O, no `stop()`** (`:44-47`) |
| writeQueue (serial) | JPEG encode, file write, CSV append, meta, close | owns `nextFrameIndex` ordering; `stop()` drains it |
| main (async hop) | `frameCount` publish (`@Observable` storage is not thread-safe) | authoritative count is `framesWrittenLocked` under `stateLock` (`:473-478`) |

## 5.11 Capture-side contract

`CaptureEngine.swift:1168-1176`: `onRecordFrame` gated by `isRecordFrameWanted()` **before** the copy; the copy is synchronous on captureQueue (≈4 MB memcpy, sub-ms) while JPEG and disk I/O are the recorder's job. The same comment carries the standing prohibition (never encode on capture queue, 11 ms → 2081 ms). **Two files state the same rule independently** — treat it as cross-cutting, not local advice.

## 5.12 Legacy `RecordEngine`

`Sources/AuroraDrive/Capture/RecordEngine.swift` is 771 lines and still compiles (`Package.swift:189-192` includes the whole directory). Its weight is why the lean recorder exists (§5.1). Output isolation (`LeanRecordEngine.swift:94-95`): lean clips go to `data/lean_clips/clip_<yyyyMMdd_HHmmss>/`, deliberately **separated** from the training scan path `data/raw_clips` so unannotated data cannot be picked up. `UNVERIFIED:` `RecordEngine.swift` internals (19-column layout, continuous-value labels, 640×360 scaling) were **not** read line-by-line; the 19-column claim appears only as history in `LeanRecordEngine.swift:17` and in commit `4947ec6` ("CSV 19 列 → 11 列") — verify before stating it as current fact.

## 5.13 Offline annotator

`Sources/AuroraDrive/Capture/LeanAnnotator.swift` (597) consumes `onSegmentClosed` and, per design, fills `speed_kmh` by running OCR on `speedROINorm` offline (`LeanRecordEngine.swift:29-30`, `:83`, `:491`). `UNVERIFIED:` its internals (staging, % reporting, in-place rewrite of `controls.csv`, whether it validates `frame == i`) were **not** read. Cross-references to check: `speed_source:"offline_ocr"` (`:83`) and `needs_annotation:true` (`:84`) imply the annotator is the only path that makes a segment training-ready.

## 5.14 Selftest

`Sources/AuroraDrive/Capture/LeanRecordSelfTest.swift` (715) runs as `./AuroraDriveUI --lean-selftest`. Pattern (per assertions described in earlier verification work; `UNVERIFIED:` line numbers not re-pinned): `clipsRootOverride` (`:123-125`) writes into a temp dir so `data/lean_clips` is untouched, `maxSegmentSeconds` shortened to force rotation (`:114`, `:199`), plus header/column-count assertions and reverse assertions that removed columns are gone.

## 5.15 Known-open items

- `LeanRecordEngine.swift:96-100` — the **directory-layout comment still says "controls.csv 19 列"** and mentions position/acceleration; stale against the 11-column header at `:649-650`. Trusting it mis-sizes the schema.
- Crash window between a successful JPEG write and the CSV append: `frames/N.jpg` exists with no row. `.atomic` protects the file, not the pairing. Uncovered; pairing is only guaranteed for graceful failures.
- Auto-segment first-frame `t_sec` skew: `t_sec` is relative to `sessionStart`, set inside `openSession`, so cross-segment time monotonicity is not preserved (`:662`).
- `FileHandle.close()` (`:691`) is not wrapped in do/catch — a failure would be invisible; the counter read afterwards still reflects `framesWrittenLocked`.
- Speed-OCR accuracy on a real speedometer and true 10-minute segmentation timing remain unmeasured on real data (`recordings/` is 0 B; `data/raw_clips` not exercised).

---

# SEC-06 — ALL ENVIRONMENT VARIABLES + ALL CLI FLAGS

Counted by `grep`, not recalled; commands are quoted so every count can be re-derived.

## 6.1 Counting method — the counting itself was once a bug

`AuroraFlags.swift:8-15` records the trap: pre-refactor ("perf-core" full scan) = **72** `AURORA_*` variables across **13 files / 70+ call sites**. The statistic **must** scan `"AURORA_*"` **string literals**, not `environment["X"]` subscripts — subscript-only scanning misses ① `let env = ProcessInfo.processInfo.environment` then `env["X"]` (25 vars) and ② constants holding the key name, e.g. `EgoBoxFilter.envKey = "AURORA_EGO_AREA"` (3 vars). The author's subscript-only attempt got **41** ("错得很远, 记此存照").

```sh
grep -rhoE '"AURORA_[A-Z0-9_]+"' Sources/ | tr -d '"' | sort -u | wc -l
```

## 6.2 The counts — do not conflate

| measurement | value | command |
|---|---|---|
| distinct `"AURORA_*"` literals in `Sources/` | **92** | the grep above |
| literals **declared** in `AuroraFlags.swift` | **76** | same grep, that file |
| `static let`/`static var` lines there | **78** | `grep -cE '^ *static (let\|var) '` |
| variables **not** centralised | **16** | `comm -23` of the two sets |
| all `AURORA_*` tokens incl. non-literal | **127** | `grep -rhoE 'AURORA_[A-Z0-9_]+'` |
| distinct `"--flag"` literals in `Sources/` | **73** | `grep -rhoE '"--[a-z0-9-]+"' Sources/ \| tr -d '"' \| sort -u \| wc -l` |
| flags registered in `oneShotFlags` | **53** | `sed -n '952,1018p' AuroraDriveApp.swift` |

92 ≠ 127 because 127 includes concatenation/prefix fragments in comments and strings (`AURORA_CORNER_`, `AURORA_SEG_`, `AURORA_JUNC_`, `AURORA_EGO_` in interpolation) plus `scripts/`, `tools/`, `run.sh`. Authoritative for Swift runtime behaviour = the **92 literals** (76 centralised, 16 not). 78 ≠ 76 because two `static` declarations are not environment switches (`AuroraFlagSpec`/`all`/`helpText`/`migrationStatus` machinery): **76 is the per-variable truth, 78 is a line count** — do not cite 78 as "number of switches".

## 6.3 The 16 outside the central table

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
Two are **deliberate** and must not be "fixed": `AURORA_FORCE_YOLO26S` is read independently in both processes and the UI deliberately does not set the child's environment, so both agree by construction (`EngineMain.swift:903-907`). `AURORA_EGO_CHECK` is the documented **only** exception to `static let` (`AuroraFlags.swift:40-45`): `AuroraDriveApp.swift:3232` calls `setenv("AURORA_EGO_CHECK", "off", 1)` at runtime and the selftest needs it immediately, so `egoCheck` stays a per-call read (`:238-243`); it is **not** in the 16 because it is declared as a `static var`.

`migrationStatus` (`AuroraFlags.swift:556-563`) is the living list: converged `Core/AuroraCache.swift`, `Core/AuroraFlags.swift`; pending `App/AuroraDriveApp.swift`, `App/MissionConsole.swift`, `App/PerfSelfTest.swift`, `App/MarkerCluster.swift`, `App/MarkerTaxonomy.swift`, `App/RouteGraph.swift`, `App/AuroraTheme.swift`, `Capture/CoordinateCapture.swift`, `Inference/YolopxEngine.swift`.

## 6.4 Why the central table exists

`AuroraFlags.swift:4-54`: before it there was **no aggregation** — defaults lived inside each `??`, so "what happens if I don't set this" meant reading 13 files (`:19-20`). **Hot-path re-reads were measured**: `ProcessInfo.environment[key]` costs **17.213 µs/call** (cited `AuroraDriveApp.swift:5171`) and **0.032 ms/call** (cited `MarkerCluster.swift:75`); `AURORA_OCR_DEBUG` was read **3 times inside every OCR inference**, `AURORA_DISABLE_OPTICAL_FLOW` every frame (`:21-25`). At 30 Hz, 17 µs × 30 = 0.5 ms/s wasted (`:37-38`); `static let` is `swift_once`-guarded → evaluated once, then a memory read (`:33-38`). Three goals: centralise; self-describe (`defaultValue` / summary / `isDiagnostic` / `readBy`); discoverable via `--flags-help` (`:27-30`).

**Boolean parsing is a compatibility contract** (`AuroraFlags.swift:94-114`): `bool(_:default:)` — **only the literal `"1"` means on**; `"true"`/`"yes"` are rejected, because the historical convention is `== "1"` (`AuroraDriveApp.swift:138/5334`) and keeping it byte-identical avoids "this used to work and now doesn't" (`:96-98`). `boolNotZero(_:default:)` is the inverse — only `"0"` means off — used for default-on switches (`AURORA_CACHE`, `AURORA_MAP_FILTER_BAR`) (`:104-109`). `str` treats empty as absent (`:111-114`); `dbl`/`int` fall back on parse failure; `dblOpt`/`intOpt` return nil. `raw(_:)` (`:89-92`) is the **only** `environment[...]` in the file, deliberately, so `grep -rn 'environment\[' Sources/` measures migration progress (`:82-83`); `UNVERIFIED:` that it now returns exactly the 16 above.

## 6.5 Switch table, by section

| section | MARK | header says | static decls in range |
|---|---|---|---|
| A 运行模式/进程 | `:133` | 5 | 5 |
| B 引擎/IPC/网络 | `:155` | 4 | 4 |
| C 推理/感知 | `:171` | 6 | 8 |
| D 光流/自车运动 | `:212` | 6 | 9 |
| E 驾驶/控制 | `:284` | 9 | 11 |
| F 路网/弯道引导 | `:324` | 13 | 13 |
| G 地图 UI | `:355` | 16 | 19 |
| H 性能/日志 | `:414` | 5 | 7 |

Header counts sum to **64**, measured `static` decls sum to **76** — the MARK numbers are historical labels, not counts; C/D/E/G/H grew after their headers were written.

Named switches (key, default, line): `uiLocal` `AURORA_UI_LOCAL` false `:138`; `daemonMode` `AURORA_DAEMON_MODE` false `:141`; `observeOnly` `AURORA_OBSERVE_ONLY` false `:145`; `tccTest` `AURORA_TCC_TEST` `:148`; `apiKey` `AURORA_API_KEY` `:152`; `engineDiagSkipTCC` `AURORA_ENGINE_DIAG_SKIP_TCC` false `:159`; `engineDiagCaptureOnly` `AURORA_ENGINE_DIAG_CAPTURE_ONLY` false `:162`; `legacyProto` `AURORA_LEGACY_PROTO` false `:165`; `nicTestTarget` `AURORA_NIC_TEST_TARGET` `"49.232.46.87"` `:168`; `ayolom` `AURORA_AYOLOM` `:175`; `inferQoS` `AURORA_INFER_QOS` `:178`; `yolopxIntervalMs` `AURORA_YOLOPX_INTERVAL_MS` 0 `:181`; `yolopxLetterboxMain` `AURORA_YOLOPX_LETTERBOX_MAIN` false `:184`; `skipModelLoad` `AURORA_SKIP_MODEL_LOAD` false `:187`; `ocrDebug` `AURORA_OCR_DEBUG` false `:190`; `ocrWorkers` `AURORA_OCR_WORKERS` 0 `:198`; `questOCR` `AURORA_QUEST_OCR` **true** `:209`; `disableOpticalFlow` `AURORA_DISABLE_OPTICAL_FLOW` false `:219`; `egoArea` `AURORA_EGO_AREA` computed `:227`; `egoCheck` `AURORA_EGO_CHECK` per-call `static var` `:243`; `egoMaxFwd` 0.5 `:246`; `egoMaxFlowPx` 80.0 `:248`; `egoResidualRatio` 0.6 `:250`; `egoMinConf` 0.35 `:252`; `egoDiag` false `:266`; `keyRefreshHz` computed `:278`; `laneKeepTiers` `:288`; `releaseAllEveryTick` false `:291`; `assistKeepalive` `AURORA_ASSIST_KEEPALIVE` true via `boolNotZero` `:302`; `stuckSeconds` 30 `:305`; `enableBgDrift` false `:308`; `segStraightenDeg` 15.0 `:311`; `segStraightenDoneDeg` 8.0 `:313`; `segHandoverM` 15.0 `:315`; `segHandoverFrames` 10 `:317`; `segCorridorM` 8.0 `:319`; `segMapTimeoutS` 20.0 `:321`; `cornerLookaheadM` 40.0 `:328`; `cornerHeadingTolDeg` 60.0 `:330`; `cornerDeadbandDeg` 8.0 `:332`; `cornerSatDeg` 35.0 `:334`; `cornerPassedM` 15.0 `:336`; `cornerConeDeg` 75.0 `:338`; `cornerTightRM` 80.0 `:340`; `cornerTightSpeed` 40.0 `:342`; `juncLookaheadM` 45.0 `:344`; `juncApproachM` 25.0 `:346`; `juncExcludeDeg` 35.0 `:348`; `juncForkTolDeg` 25.0 `:350`; `juncReachRatio` 1.2 `:352`; `mapWindow` `AURORA_MAP_WINDOW` false `:359`. `UNVERIFIED:` sections G (`:355-413`) and H (`:414-443`) counted but not transcribed; `--flags-help` enumerates them at runtime.

## 6.6 `--flags-help` self-description contract

`AuroraFlags.swift:536-552`: `helpText()` emits a title line with `all.count`, one line per switch, then a statistics line — one switch per line, and `wc -l` must equal `all.count + 2`, so `--flags-help | wc -l` is a usable assertion (`:538-540`). Per-line format (`:545`): `  [诊断|功能] KEY=defaultValue  — summary   ← readBy`. `AuroraFlagSpec` (`:61-72`) requires `key`, `defaultValue`, `summary`, `isDiagnostic`, `readBy`; `defaultValue` **must** match the real code default — "不一致就是文档撒谎" (`:64-65`). The table is authoritative: "漏加等于这个开关'不存在'" (`:444`).

## 6.7 CLI flags — 73 distinct, two hard registration rules

73 distinct flag literals (command in §6.2); parsing is `CommandLine.arguments` string search, `grep -rn 'CommandLine.arguments' Sources/` → **27** sites.

**Rule 1 — a one-shot flag must be in `oneShotFlags` or it is silently blocked.** `AuroraDriveApp.swift:950-952` declares `let oneShotFlags = [...]` (array `:952-1018`, **53** entries): short-lived self-check and daemon modes must not participate in the UI lock, else they mutually exclude the resident UI and either the selftest fails or the user cannot start the GUI (`:950-951`).

The lock (`AuroraDriveApp.swift:763-779`): `flock(LOCK_EX|LOCK_NB)` on `~/Library/Application Support/AuroraDrive/ui.lock`; if the file cannot be created it **allows** startup (`:769`); on success stores the fd and writes the pid (`:770-775`); on failure `close` + false (`:777-778`). Enforcement (`:1358-1366`):
```swift
let isOneShot = args.contains { oneShotFlags.contains($0) }
if !isOneShot, !acquireUISingleInstanceLock() {
    print("[App] 已有 AuroraDrive 实例在运行 —— 本次启动退出")
    print("      原因：两个 UI 会互抢引擎 socket（0.5s 断开重连死循环）")
    exit(0)
}
```
Reason (`:760-762`): measured 2026-09-12 — two UI instances fight over one engine socket, the engine serves one client, both get kicked into a "disconnect → reconnect 0.5 s" loop. The engine side already had `engine.lock`; the UI side lacked it.

**The documented failure mode is a false green**, recorded **four times**: `:982-983` "漏登记时进程会被 UI 单实例锁挡掉却仍 exit 0 —— **假绿**。登记与分发必须同时存在。"; `:999-1002` two self-checks had dispatch code but were never registered — "同款陷阱第 3 次出现"; `:1015-1016` "⚠️ 登记与分发必须同时存在（本项目第 4 次踩同款假绿陷阱）。"; `:986-990` the mirror image — registering without dispatching falls through to the normal UI start and also exits 0; `:216` and `:992-998` repeat it for `--lean-annotate`. Consequence: a selftest that "passed" while another UI held the lock, with the flag unregistered, **proved nothing**.

**Rule 2 — dispatch must precede the lock, or the flag must be registered.** Lock acquired at `:1359`. First-dispatch lines for flags **not** in `oneShotFlags`: `--engine` `:855`; `--auto-login` `:528`; `--agent-llm-test` `:879`; `--set-llm-config` `:861`; `--network` `:1112`; `--live` `:1149`; `--map-window-test` `:1354` (only 5 lines before the lock — the most fragile); `--auto-drive` `MissionConsole.swift:6494`; `--agent-ui-shot` `MissionConsole.swift:6537`; `--agent-layout-shot` `MissionConsole.swift:6541`; `--locate-live` `Locate/VisualLocator.swift:118`; the rest (`--dir --image --frames --iters --roi --seconds --stride --auto-seconds --agent-command`) are **argument payloads**, not modes. Known-benign false positive: `"--live"` at `:1149` is a real standalone literal, so a substring search for `--live` over-matches `--locate-live`; only quoted-literal matching is sound.

**The 53 registered one-shot modes** (`AuroraDriveApp.swift:952-1018`): self-checks `--speed-selftest --tcc-selftest --test-xpc --yolo-selftest --upscale-selftest --fit-selftest --limit-selftest --proto-selftest --yolopx-selftest --opticalflow-selftest --motion-selftest --corner-selftest --realshot-selftest --egobox-selftest --ayolom-selftest --lanekeep-selftest --perception-selftest --wire-selftest --route-selftest --taxonomy-selftest --flags-help --cache-selftest --quest-selftest --llm-selftest --llm-vision-selftest --control-selftest --tool-selftest --tool-call-demo --llm-perf-selftest --websearch-selftest --v2-selftest --agent-selftest --map-selftest --lane-extrapolator-selftest --capture-selftest --pointer-selftest --lean-selftest`; benchmarks `--yolo-bench --perf-selftest --tick-profile --tick-bench --mc-map-bench --lanekeep-reality`; headless render `--mc-shot --mc-map --mc-map-offline --mc-route --mc-route-loading --mc-quest`; resident `--daemon --nic-autotest --llm-probe`; offline annotation subprocess `--lean-annotate` (`:992-998`). `--lean-annotate` spawns `--lean-annotate <clip>` as a **separate process** after recording stops, explicitly to avoid a synchronous `@MainActor` OCR freezing the UI (`:992-994`).

## 6.8 Full flag inventory (73)

```
--agent-command --agent-layout-shot --agent-llm-test --agent-selftest --agent-ui-shot
--auto-drive --auto-login --auto-seconds --ayolom-selftest --cache-selftest
--capture-selftest --control-selftest --corner-selftest --daemon --dir
--egobox-selftest --engine --fit-selftest --flags-help --frames
--image --iters --lane-extrapolator-selftest --lanekeep-reality --lanekeep-selftest
--lean-annotate --lean-selftest --limit-selftest --live --llm-perf-selftest
--llm-probe --llm-selftest --llm-vision-selftest --locate-live --map-selftest
--map-window-test --mc-map --mc-map-bench --mc-map-offline --mc-quest
--mc-route --mc-route-loading --mc-shot --motion-selftest --network
--nic-autotest --opticalflow-selftest --perception-selftest --perf-selftest --pointer-selftest
--proto-selftest --quest-selftest --realshot-selftest --roi --route-selftest
--seconds --set-llm-config --speed-selftest --stride --taxonomy-selftest
--tcc-selftest --test-xpc --tick-bench --tick-profile --tool-call-demo
--tool-selftest --upscale-selftest --v2-selftest --websearch-selftest --wire-selftest
--yolo-bench --yolo-selftest --yolopx-selftest
```
Verified both directions: `awk '/^## 6\.8/,/^## 6\.9/' sec-06-flags-cli.md | grep -oE '\-\-[a-z0-9-]+' | sort -u > doc.txt` then `comm -13` (code-only) and `comm -23` (doc-only) are both **empty**. Flags taking an argument: `--yolo-selftest <image>` (`run.sh:159-161`), `--yolo-bench <image>` (`run.sh:162-164`), `--dir <path>` (`:520`), `--image`, `--frames`, `--iters`, `--roi`, `--seconds`, `--stride`, `--auto-seconds`, `--network`, `--tool-call-demo <task>`, `--websearch-selftest <q>`, `--set-llm-config` (4 positional, `AuroraDriveApp.swift:861`).

## 6.9 `--engine` mode selection

Dispatches at `AuroraDriveApp.swift:855`, **before** the UI lock and any SwiftUI setup, consistent with `EngineMain.swift:7-8` ("进程最前端分流，不触碰 SwiftUI"). Not in `oneShotFlags` and does not need to be: the engine exits on its own flock singleton (`EngineMain.swift:1092-1102`), a different lock file (`engine.lock` vs `ui.lock`) — two locks, two holders, no interaction.

## 6.10 Documented stale numbers found while writing this section

1. `AuroraFlags.swift:8-15` — "**72 个** variables" is the pre-refactor count; current literal count is **92**, centralised **76**. Do not cite 72 as current.
2. `AuroraFlags.swift:133-414` — per-section MARK counts sum **64** vs actual **76** `static` declarations.
3. `AuroraDriveApp.swift:1016` — the `--lean-selftest` comment still says the test asserts "表头 19 列" and "缺失定位写空串"; both are **gone** (11 columns; the empty-string invariant was removed with the pose columns, commit `4947ec6`).
4. `README.md:95-98` — claims tick and capture both 20 Hz citing `EngineMain.engineTickHz = 20.0`; live value is **15.0** (`EngineMain.swift:771`, both tiers return 15.0 at `:868-885`, sprint 20). The paragraph dates from the 2026-10-12 tier and was superseded 2026-10-22.

---

# SEC-07 — PITFALLS / INCIDENT HISTORY / HARD CONSTRAINTS

Distilled index of failure modes **documented in the source itself**, organised by invariant, not chronology. Hot-file density: `grep -rc '事故\|踩坑\|实测\|假绿' Sources/ --include='*.swift'` → `AuroraDriveApp.swift` 151, `MissionConsole.swift` 82, `YolopxEngine.swift` 54, `LLMBackend.swift` 54, `CoordinateCapture.swift` 47, `WebSearch.swift` 45, `InferenceEngineV2.swift` 42, `LLMHealth.swift` 36. Dated-comment density: `2026-09-30` ×141, `2026-10-04` ×101, `2026-10-06` ×81, `2026-10-02` ×53, `2026-10-08` ×46, `2026-10-22` ×28, `2026-11-03` ×19.

## 7.1 False green (highest-value pitfall)

**Invariant: a test that reports success must actually have executed.** `oneShotFlags` is a **hand-maintained array** (`AuroraDriveApp.swift:952-1018`); a self-check missing from it is blocked by the UI single-instance lock and the process **exits 0**, reading as success. Recorded **four times**: `:982-983` "漏登记时进程会被 UI 单实例锁挡掉却仍 exit 0 —— **假绿**。登记与分发必须同时存在。"; `:999-1002` "同款陷阱第 3 次出现"; `:1015-1016` "本项目第 4 次踩同款假绿陷阱"; `:986-990` the mirror image (registering without dispatch → falls through to normal UI start, also exit 0); `:216`, `:992-998` for `--lean-annotate`.

Other false-green sources: `:1652` "避免「自检用的解析逻辑和生产不一样」的假绿"; `:1796` proving only "load succeeded" is false green — use instrumentation counts; `:1991`, `:1996` a pre-condition assertion stops "0 because not loaded yet" being read as a real zero; `:3603` a first version was a **weak assertion (false green)**; `:3856` "硬凑一个恒真断言只会制造假绿" (the signature constraint is enforced by `tools/check-c7-gate.sh` A2).

**Operational rule**: confirm **both** registration and dispatch before believing a self-check, and confirm no UI instance held `ui.lock` (SEC-06 §6.7.1).

## 7.2 Concurrency / architecture

- **Never heavy work on the SCStream callback queue** — `CaptureEngine.swift:1170-1172`: the record copy is synchronous on captureQueue (≈4 MB memcpy, sub-ms) but "JPEG 编码与写盘由录制器丢到自己的后台队列 —— **绝不可在 captureQueue 上编码**"; incident `capGap` **11 ms → 2081 ms**. Restated in `LeanRecordEngine.swift:44-47` and `:589-592`.
- **`stop()` must not run on the capture queue** — `LeanRecordEngine.swift:589-593`: it does `writeQueue.sync {}` and would block on disk I/O; use `DispatchQueue.main.async`.
- **Socket fd must not be closed via the shared variable** — `EngineMain.swift:562-566`: on a new connection the old one is `old.cancel()`, never closed by reading `clientFD`, because cancel is async and closing the shared var would **close the new connection** ("绝不在这里按 clientFD 关…会误关新连接").
- **UI read source must be cancelled synchronously on EOF** — `EngineClient.swift:439-451`: one engine kill gave **12+ "连接断开"** lines; `read()` returning 0 left `readSource` alive, re-delivering the EOF each turn; cancelling inside an async block was too late. Cancel on the read queue, then hop to main for state.
- **Handover ordering is unforgiving** — `EngineClient.swift:1076-1080`, `:336-343`: after SIGTERM the engine still runs `releaseAll → stopDriving → flushSync → exit(0)` (hundreds of ms) with the socket present and flock held, so spawning immediately yields `exit(0)` and presents as "the engine never comes back".
- **Pid reuse — never re-kill a remembered pid** — `EngineClient.swift:1020-1025`: in the idempotent path only `suspendedPID` exists and that process is long dead; the pid may have been **reused**, so a second kill would hit an unrelated process.
- **`@Observable` storage is not thread-safe** — `LeanRecordEngine.swift:473-478`: `frameCount` only on main via `DispatchQueue.main.async`; the authoritative count is `framesWrittenLocked` under `stateLock`, because at `stop()`-drain time main may not have updated (`:694-696`).

## 7.3 Data integrity (training data)

- **CSV row index ⇄ `frames/NNNNNN.jpg` is a hard pairing** — `LeanRecordEngine.swift:34-40`: `dataset_v3._build_index` uses `n_frames = len(rows)` and resolves `frames/{j:06d}.jpg` by **row order**; violation is **silent**. Five defences in SEC-05 §5.4; the historical bug was `appendCSVRow` returning nothing while `writeFrame` still advanced the index → whole segment unloadable (`:481-486`).
- **Never write `speed_kmh = 0`** — `LeanRecordEngine.swift:489-491`: empty ⇒ `speed_valid=false`; `0` reads as "true speed is zero", a **wrong supervision signal**; offline OCR fills it.
- **Frame-rate tolerance is enforced by the loader, not the recorder** — `LeanRecordEngine.swift:311-327`: `actual_fps = 1/median(dts)` must stay in **12.75–17.25** (15 ± 15 %) or `ValueError`; the recorder gate only enforces "not too fast" and the "too slow" case is handled by monitoring and **stopping with an explicit reason** (`:325-327`).
- **Never accept a session-directory name collision** — `LeanRecordEngine.swift:612-624`: timestamps are second-precision and auto-segment is `stop()`→`start()`, so collision is guaranteed; `createDirectory` does not error and `createFile` would **truncate** the previous `controls.csv`, silently losing a segment.
- **Do not record the app's own windows** — `CaptureEngine.swift:17-19`: `excludingWindows: []` let the desktop and own UI into training data; the invariant is now "exclusion list non-empty when own windows are on screen" (`:1063-1069`) and the pixel heuristic was **deleted** on "宁可漏报也不能误报" (`:1060-1061`).
- **Never silently fall back on a missing capture window** — `CaptureEngine.swift:549-556`: that would violate the user's explicit choice; report an error and mark the selector red.
- **Alt-tab / focus loss must not lose held keys** — `YolopxEngine.swift:58`, `:63` state the fail-open red line: a fail-hard path would drop already-pressed keys; return "the most conservative answer" instead. `LaneBridge.swift:175` restates it for mask geometry: `isUsable` must reject short `cells` before `LaneFallback` would `SIGTRAP`.

## 7.4 Input injection (measured against the game)

- **Only `.hidSystemState` + `.cghidEventTap` works** — `ControlEngine.swift:183-198`: the game's input layer reads only the HID system state layer; `.combinedSessionState` is ignored even though system UI reacts (keyboard visualiser lights, system beep) — symptom "UI 显示已输出 W，但游戏纹丝不动"; `.privateState` is "禁止使用".
- **Modifier keys only emit `flagsChanged`** — `KeyboardMonitor.swift:106-118`: synthesising Shift produces event type **12 = flagsChanged** for both phases, no keyDown/keyUp; Shift is the handbrake and the precondition for super brake (Shift+Space) and ultimate brake (Shift+Space+S) (`:111-112`). Without a `.flagsChanged` monitor `heldKeys` never holds 56, so `shift` is 0 for the whole recording and the three safety heads get zero positives (`:113-115`).
- **Auto-repeat is ignored by this game** — `ControlEngine.swift:504-507`: only "new key down" is accepted, so `autorepeat` must stay `false`.
- **Never inject in observe-only mode** — `ToolRegistry.swift:405`: with `AURORA_OBSERVE_ONLY=1` injection is refused with an explicit message; cross-referenced by the engine's narrowed TCC predicate (`EngineMain.swift:1132-1138`).
- **Permission query must not pop a dialog on the hot path** — `ControlEngine.swift:210-232`: P0 (2026-09-07) the string literal `"kAXTrustedCheckOptionPrompt"` is not a valid CFString constant → invalid options dict → `AXIsProcessTrustedWithOptions` with a nil-equivalent → **EXC_BAD_ACCESS at 0x8**. 2026-09-30 correction: "first call auto-prompts" was **wrong** — passing `nil` only queries and **never** prompts, which is why the app never appeared in the Accessibility list. Hence `checkPermission()` stays pure-query (the high-frequency `press`/`hold` retry path must never prompt, "否则每帧弹一次") and `requestAccessibilityPermission()` prompts once at start.
- **Six key-ups per frame was 71 % of the frame** — `ControlEngine.swift:456-485`: `tick.inject` p50 **0.15 ms** of `tick.total` 0.21 ms = **71 %**, the largest main-thread cost, because `expertMode || controlDisabled` called `releaseAll()` every frame (6 keys × `CGEvent.post`, `ev=` rising ~2000 per 30 s). Fix: `releaseAllIfNeeded()` throttles to ≤1/s when `heldKeys` is empty, while `releaseAll()` is "一字未改" because it still carries the duty of clearing **system-level stuck keys left by a previously crashed process** (`:473-481`); equivalence to be shown by ABBA (0.15 ms → ~0.01 ms) at `:483-485`.

## 7.5 Platform / OS

- **Deploying a binary over its own inode kills the process** — `run.sh:96-101`: text is paged on demand, an in-place `cp` makes the kernel read mixed old/new pages, CDHash fails, Taskgated Invalid Signature. Fix: temp name + `mv` (new inode).
- **Metal precompile needs a writable module cache** — `run.sh:118-120`: clang ModuleCache defaults to `/var/folders/`, rejected `Operation not permitted`, silently failing the precompile; redirected with `-fmodules-cache-path="$ROOT/.build/metal-cache"`.
- **`libpcap` cannot be detected by file existence** — `run.sh:26-39`: system libs live in the dyld shared cache since macOS 11, and libpcap ships with macOS; use `dyld_info -linked_dylibs` on a build product, then `dyld_info -exports /usr/lib/libpcap.A.dylib`.
- **Build exit code lost through a pipe** — `run.sh:78-80`: `swift build | tail -5` swallowed the status, `set -e` never fired and a **failed build was deployed and launched** (2026-09-15 `bagel_spam`).
- **Only `"1"` means on** — `AuroraFlags.swift:94-102`: accepting `"true"`/`"yes"` would be a silent behaviour change; `boolNotZero` is the inverse for default-on switches (`:104-109`).
- **`static let` never re-reads the environment** — `AuroraFlags.swift:40-45`: evaluated at first access, so later `setenv` has no effect. One documented exception: `AURORA_EGO_CHECK` is a per-call `static var` because `AuroraDriveApp.swift:3232` does `setenv("AURORA_EGO_CHECK", "off", 1)` and a selftest depends on it (`:238-243`).
- **View-state restoration hangs the process** — `AuroraDriveApp.swift:1368-1372`: `open AuroraDriveUI.app` spins forever (4 threads, 0.0 % CPU, 70 MB RSS, flat CPU time 30 s, no log, no window) while the same binary from a shell is fine; fix "禁用窗口状态恢复" (2026-09-30).
- **stdio block buffering hides all engine logs** — `EngineMain.swift:1078-1085`: redirected stdout block-buffers at 4 KB, so `print("[cap-deep] ...")` stayed in memory and the log was empty, misread as "the code never ran"; both streams set to `_IOLBF`. The UI path already did it at `AuroraDriveApp.swift:751`, and `AuroraDriveApp.swift:782-784` states the same rationale.
- **First-frame timing probes produce astronomical values** — `CaptureEngine.swift:1139-1144`: with `lastFrameTime == .distantPast`, `timeIntervalSince` yields ~5e11 ms; the first frame logs 0.
- **Screenshot rendering must happen before the run loop** — `AuroraDriveApp.swift:787-790`: headless `ImageRenderer` work in `ContentView.onAppear` never fires (no window, no layout) and the process hangs after engine init — measured **240 s without producing an image**.

## 7.6 Performance measurement

- **Absolute timings are not comparable across sessions** — `PerfSelfTest.swift:868-874`: same binary/machine differed **2–2.5×** around a few hours of heavy load (opticalflow p50 2.53 ms → 6.4 ms; `infer.yolopx` 16.4 ms → 22.6 ms), unrelated to code. The fixture is **only** for same-session A/B (same process, back-to-back, single variable); cross-binary needs `scripts/paired-ab.sh --metric tick`.
- **Concurrent benchmarking invalidates all numbers** — `scripts/build-lock.sh:14-17`: 3 agents at ~85 % CPU each drove loadavg 5.15 on 8 cores; long tasks must hold the build lock, not just `swift build`.
- **Re-reading the environment costs 17–32 µs** — `AuroraFlags.swift:21-25`: **17.213 µs/call** and **0.032 ms/call**; `AURORA_OCR_DEBUG` was read 3× per OCR inference, `AURORA_DISABLE_OPTICAL_FLOW` every frame.
- **The 45 Hz plan was wrong — do not retry** — `EngineMain.swift:727-733`: 45 Hz budget is 22.2 ms while measured per-frame work is yolopx letterbox 10.5 + ayolom 10.4 + V2 8.5 + world_model 3 + flow/control/recording 2 ≈ **36.9 ms**, so yolopx alone would take 94 %; the game dropped to **1–2 fps** (user-measured).
- **Changing tick Hz with `.now()` fires an extra tick** — `EngineMain.swift:814-830`: `schedule(deadline: .now(), repeating:)` produced a **0 ms** interval (`GAPS: 204,200,197,204,[0],54,50,50,...`) and an extra async inference `Task` plus an extra `refreshHeldKeys()` keyDown round. Fix: always `now + 1/clamped`; accepted cost one period of delay (`:828-830`).
- **Do not trust "updateConfiguration did not throw"** — `CaptureEngine.swift:686-700`: nothing says which fields are live-updatable and frame rate may be frozen at creation; success is an **optimistic assumption** with a written plan; `UNVERIFIED:` plan not executed.
- **Native Retina capture was 675 MB/s of waste** — `CaptureEngine.swift:509-535`: 2940×1912 @30fps competed with the game; on a fanless Air M3 the game fell to 1–2 fps while training stored 640×360 JPEG and the model consumed 180×320 (24× waste). Now 1280-wide @20fps = 85 MB/s, **7.9×** less.

## 7.7 Documentation discipline encoded in source

- **Overstated comments are corrected in place** — `ControlEngine.swift:220-226`: the prior claim ("first call auto-prompts") is marked "**错的**" and replaced; the convention is to keep the wrong statement visible with a correction date.
- **Hardcoded developer paths must not exist** — `AuroraPaths.swift:69-89`: P-1 (2026-10-04) the source contained `URL(fileURLWithPath: "/Users/dupi/Desktop/自动驾驶系统")`; it fails on any other machine **silently** (it is a fallback candidate). A first fix (`homeDirectoryForCurrentUser`) was rejected: that dir has neither `Package.swift` nor `models/`, so it can never match — "兜底候选的价值在于'真的可能命中'". Final: walk up to 6 levels from the executable's dir (`release/ → macosx/ → scratch/ → .build/ → root` = 4, plus 2 spare).
- **Secrets never printed or persisted** — `AuroraFlags.swift:146-151`: `AURORA_API_KEY` is "绝不打印、绝不落盘". `PrivilegePill.swift:17-19`: passwords entered in-app, never hardcoded (old `"123456"` "发布版必然失效且是安全隐患"), memory-only, cleared after use; escalation limited to installing one LaunchDaemon script (`:22-26`).
- **No native authorisation dialogs** — `PrivilegePill.swift:9-13`: user requirement 2026-09-23 — never `do shell script ... with administrator privileges`; repeated prompts get the app flagged as suspicious. Both legacy entry points are `@available(*, deprecated)` and return failure: `BPFSetup.swift:96-99`, `PrioritySetup.swift:53-58`.
- **Web search must fail honestly** — `WebSearch.swift:31-36`: no proxy pools (the proxy mentioned is the machine's own system proxy, verified with `scutil --proxy`), read-only public pages, no CAPTCHA bypass, no simulated login, no forged Referer, no rotation. Any failure throws `WebSearchError`, never a placeholder: not-found `.emptyResults`, blocked `.blocked`, timeout `.timeout`, distinguishable in the UI (`:36-37`); taxonomy at `:84` — "每一类都对应一次真实的实测观察，绝不合并成一句'失败了'". `WebSearch.swift:218-221`: an independent ephemeral `URLSession` is a **performance red line** — never shared with `captureQueue` or `aurora.quest.ocr`.
- **Self-checks must not fabricate** — `LLMSelfTest.swift:30`: unverified items marked "未验证" and counted as failures or flagged environment-limited, "绝不编造"; `:1288` print actual session state; `:211` scan all descriptor headers/baseURLs for hardcoded keys. `LLMBackend.swift:27`: the only key-like literal, `"public"`, is the OpenCode Zen catalog term.
- **Brand vs upstream** — `ControlEngine.swift:4-16` (2026-10-04): the `GameKey` table (near `:408`) comes from upstream **MaaNTE**'s actually-used key set; the upstream name stays in **source comments** for re-verification but must never appear in brand-visible strings/identifiers; brand is `AuroraDrive` (`App/AuroraBrand.swift`).

## 7.8 Mask / display path (engine vs local asymmetry)

- **The mask draw guard depended on a field the protocol never sent** — `EngineMain.swift:144-162`: `MaskOverlay` guarded on `metrics.newW > 0` but the protocol never carried `newW/newH`, so `EngineClient` rebuilt `LetterboxMetrics` with `newW: 0` → guard always false → in engine mode **no mask cell drawn** ("只能看到检测框，看不到可行驶区域和车道线"); local mode was unaffected, so **local selftests could never catch it**. Both fixes applied.
- **Layout changes require a protocol bump** — `EngineClient.swift:108-115`: v3 added the mask area and moved `pixelsOffset 20480 → 28672`; an old UI would read mask bytes as pixels.
- **Staleness must key on "saw a heartbeat"** — `EngineClient.swift:324-332`: an old engine never sends `proto`, so `engineProtocol` stays 0; treating 0 as "unknown" would miss exactly the "new UI × old engine" case (measured 2026-09-12).
- **YOLOPX does not run in engine mode** — `EngineMain.swift:22-34`: `tickEngineMode()` early-returns and `yolopxEngine.infer(image:)` has one call site after that return, so engine mode never reaches it: no `da`/`ll` masks there (masks arrive via shm), `MaskOverlay` otherwise reads empty masks, and `yolopxEngine.isDegraded` stays `true` so `LaneFallback` does not engage.

## 7.9 Logging / resources

- **Unbounded logs become a disk problem** — `EngineMain.swift:55-58`: no cap; measured 6.16 MB in a 5.71 h session (951 KB/h ⇒ ~22 MB/24 h, never cleaned), **70 %** of it a once-per-5-s statistics line. `EngineClient.swift:39-47`: the client log matters for reconnect triage so it cannot be deleted — capped at 2 MB with a `.old` backup ⇒ peak 4 MB. `EngineMain.swift:564` shows the same discipline for the socket (never close the shared fd).
- **Stuck keys survive a crash unless a real process calls `releaseAll`** — `EngineMain.swift:20`, `:2360-2375`, `:2377-2394`: every exit path releases keys first; SIGKILL is a last resort because it loses that guarantee (`EngineClient.swift:1058-1062`). `pauseDriving` also stops recording to avoid "car stopped, labels still the last AI decision" frames (`:2367-2369`).

## 7.10 Open items — carry forward, do not drop

1. `CaptureEngine.setCaptureHz` hot-update effectiveness — plan written, `UNVERIFIED:` never executed (`CaptureEngine.swift:686-700`).
2. `SCDisplay.width` pixels-vs-points — needs measurement; glyph templates depend on it (`CaptureEngine.swift:505-507`).
3. Real-gameplay validation of the recorder: `recordings/` 0 B; `data/raw_clips` and `clips` empty at last check; speed-OCR accuracy and true 10-minute segmentation unmeasured.
4. Crash window between JPEG write and CSV append — no recovery on next start (`LeanRecordEngine.swift:447-460` covers graceful failure only).
5. `AuroraFlags` migration incomplete: 16 variables outside the table (SEC-06 §6.3), `migrationStatus` (`AuroraFlags.swift:556-563`) naming 9 pending files.
6. Case-sensitivity: volume is APFS case-insensitive (`ls -d vendor` succeeds), so path-casing bugs are invisible locally.
7. Stale in-source numbers (SEC-06 §6.10): 72 vs 92/76; 64 vs 76; `--lean-selftest` "19 列"; README 20 Hz vs live 15 Hz.

---

# SEC-08 — AGENT / LLM SUBSYSTEM

`Sources/AuroraDrive/Agent` — **17 files / 15,383 lines**. Largest: `AIAgentPanel.swift` 3273, `LLMSelfTest.swift` 2183, `LLMHealth.swift` 1791, `LLMTransport.swift` 1580, `WebSearch.swift` 1463, `ToolRegistry.swift` 1065, `LLMBackend.swift` 884, `AgentLoop.swift` 657, `AgentChatService.swift` 618, `DriveSegmentController.swift` 430, `FallbackGuard.swift` 280, `AgentSettings.swift` 262, `EmergencyTakeover.swift` 239, `RuleController.swift` 209, `LoginAssistant.swift` 166, `DegradeStateMachine.swift` 165, `EgoBoxFilter.swift` 118.

## 8.1 Layer map

`LLMBackend.swift:8-21` states the boundary: ① `LLMBackendDescriptor` — which channels exist; ② `makeRequest` — how to build a legal request per channel; ③ `models`/`staticModels` — models per channel and capabilities. It does **not** send requests (`LLMTransport`), **not** monitor health or order the fallback chain (`LLMHealth`), **not** touch UI (`AIAgentPanel`) (`:14-17`).

| file | responsibility |
|---|---|
| `LLMBackend.swift` | descriptors: channels, request construction, model tables (`:8-12`) |
| `LLMTransport.swift` | OpenAI-compatible sending + SSE parsing + 12 error classes (`:8-18`) |
| `LLMHealth.swift` | health monitoring, degradation ordering, candidate chain (`:9-11`) |
| `ToolRegistry.swift` | single tool list + single execution entry + evidence chain (`:11-15`) |
| `AIAgentPanel.swift` | UI, streaming display, session history (`:15-18`) |
| `AgentChatService.swift` | chat glue: candidate chain × transport × health, in an actor (`:4-27`) |
| `AgentLoop.swift` | native tool-calling loop, zero framework (`:4-25`) |
| `AgentSettings.swift` | config struct, no API keys (`:4-18`) |

`LLMMessage`/`LLMToolSpec`/`LLMImage`/`LLMRole` are defined in `LLMTransport.swift` and only **referenced** by `LLMBackend.swift`, because redefining symbols would break the module (`LLMBackend.swift:19-20`).

## 8.2 Channels — measured 2026-10-06 21:18–21:35 Asia/Shanghai

`LLMBackend.swift:36-56` carries a probe log (raw outputs at `/tmp/w1_*.json`) for **7 channels**:

| channel | `GET models` | `POST chat/completions` |
|---|---|---|
| OVH | 200, 24 entries, **no Authorization header needed** | 200 for Qwen3.6-27B; 429 "API rate limit exceeded" on the other 4 buckets |
| Zen | 200, 86 entries (200 even with any of three headers missing) | 200 with **tool_calls working**; paid models (claude-sonnet-5/gpt-5.5) → 401 |
| Gen | 200, 298 entries | **401 requires key** (9 on-machine probes) |
| Legacy | `/models` 200, single `openai-fast` | `/openai/chat/completions` 200 — **base URL is already the chat endpoint** |
| OpenRouter | `/api/v1/models` 200, 464 entries (public) | — |
| Groq | `/openai/v1/models` 403 (needs key) | — |
| 智谱 | `/api/paas/v4/models` 401 code 1001 (needs key) | — |

**The pollinations conflict is deliberately unresolved** (`:57-66`): 9 on-machine probes (varying UA/Referer, `?referrer=`, `?token=anonymous`, `Authorization: Bearer anonymous`, stream:true) all returned **401** `{"success":false,"error":{"message":"A valid API key is required..."}}` with **no 429 at any point**, while at the same moment Legacy returned 200 and gen's `GET /models` returned 200; the Lead's 4 re-probes all **succeeded**. Conclusion: **time-of-day gateway flapping**, neither a permanent gate nor rate limiting. Therefore `requiresKey=false` is kept (frozen contract not unilaterally changed), `riskNote` says only "flaps, trust the probe", explicitly **not** "needs key" or "rate limited", and availability is decided by `LLMHealthMonitor` probing real requests.

Red line: **no hardcoded API key**; the only look-alike literal, `"public"`, is OpenCode Zen's public-tier sentinel, provenance `/tmp/zen-proxy.mjs:495 return "Bearer public"` (`LLMBackend.swift:27-29`). Restated in `AgentSettings.swift:14-17`: the user's key lives in a local mode-0600 notebook; key-free channels use `public`/empty Authorization.

## 8.3 Transport — what makes it offline-testable

`LLMTransport.swift:8-30`: `POST {base}/chat/completions`, non-streaming and SSE; SSE parsing of `data:`, `[DONE]`, `delta.content`, `delta.reasoning_content`, `delta.tool_calls` fragment accumulation; image parts as data URLs with **long side 1568 px, JPEG 0.8 hard limits**; 12 error classes each matching a real observed body; `Task.cancel` → `.cancelled`, no dangling connection.

**All parsing is pure functions** (`:19-23`): `SSEParser`, `LLMError.classify`, `LLMImageEncoder` are stateless (no `URLSession`, no globals) so `--llm-selftest` reproduces every criterion **without network**.

Performance red lines (`:26-30`): network and parsing run entirely in async context; **no `DispatchQueue.main` and no `@MainActor` anywhere in the file**; `LLMSessionPool` is independent of `captureQueue` and the panel's `llmSession` (listed as an ABBA item); reads use `URLSession.bytes(for:)` byte-by-byte with **per-line flush** for minimum first-token latency rather than buffering the whole body.

Error taxonomy, one case per observed body (`:32-44`): `FreeTierError` → `.gated`; `RegionError` → `.regionBlocked`; `ModelDeprecated` + `metadata.replacement` → `.modelDeprecated`; `ModelDeprecated` without replacement (placeholder `no-replacement-available`) → `.modelNotFound`; `server_error`/5xx → `.upstream`; 429 (with `Retry-After`) → `.rateLimited`; 401 → `.invalidKey`; `URLError.timedOut` → `.timeout`; DNS/network → `.network`; 200 with empty content (seen on `space-bunny-free`) → `.badResponse`; `Task.cancel` → `.cancelled`. Rule: "逐条照抄、不自行增删分类". `toolCall` id semantics (`:420`): in SSE fragments the `id` and `function.name` appear **only in the first** fragment. `timeout` (`:491-493`) is an **idle** timeout (`timeoutIntervalForRequest` = max gap between packets), so long streams are not cut. SSE compat (`:539`): some key-free endpoints return plain JSON even with `stream=true`.

## 8.4 `AgentChatService`

Header `AgentChatService.swift:4-27`: the panel needs "user says something → show incrementally → final text" over a distributed candidate-chain × transport × health state; extracting it into an actor keeps the panel ignorant of candidates/degradation/error classes, makes the CLI selftest reuse the same path as the panel, and keeps network/parsing off the **main thread**.

**The bug this file fixed** (`:13-16`): `sendUserMessage`'s free-text branch went through `localReply()` canned text while the real model Q&A function `plainAnswer` existed but **was never called by any production path**. This file *is* that missing path.

| constant | value | reason |
|---|---|---|
| `maxHistoryTurns` | **12** | prevent token explosion; overflow dropped (`:107-109`) |
| `maxCandidatesPerRequest` | **4** | "4 是权衡值" — free tiers rate-limit so several escape routes are needed, but a dozen round trips is unacceptable and triggers more limiting (`:111-115`) |
| `deltaThrottleInterval` | **1/15 s** (≈66 ms) | some channels push one chunk per token; a SwiftUI write per chunk saturates main (`:117-124`) |
| `requestTimeout` | **30 s** | idle semantics, does not truncate streaming (`:126-128`) |

Degradation (`:19-23`): at most **4** candidates from `LLMHealthMonitor.candidates`; full-chain failure **does not throw to the UI** — empty text plus an error string, and the panel falls back to `localReply` marked 「离线回复」 so the user can tell model from fallback. Measured basis (`:25-27`): Vision OCR p50 **33.6 ms** ≈ one entire 30 Hz frame budget, hence the project is main-thread sensitive; `onDelta` is throttled to ≤15 Hz here.

## 8.5 Health / candidate ordering

`LLMHealth.swift` (1791), entry `func candidates(preferred:...)` at `:840`. Ordering (`:1058`, `:1074`) uses **explicit partitioning + stable enumeration sort**; the comment rejects `sorted { ... return false }` because a comparator that always returns false is not a valid ordering. Consumed call sites pinned in `LLMBackend.swift:22-26`: `LLMBackendRegistry.shared.descriptor(for:)` nullable; `provider(for:apiKey:)` nullable; `try? await provider.models(apiKey:)` throwing; `AgentLoop.swift:510` descriptor, `:520` `descriptor?.extraHeaders` (Zen's three headers); W3/W7 use only `baseURL`, `extraHeaders`, `staticModels` (+`kind`), so keeping extra fields is harmless (`LLMBackend.swift:28-29`). `UNVERIFIED:` health scoring / probe scheduling internals beyond these symbols.

## 8.6 Tools — exactly 30 mounted, four guards

`ToolRegistry.swift:16-23` enumerates the mounted list and the count is verifiable: **13** `insert(AgentTool(` call sites, one inside `for skill in AgentSkillLibrary.all` (`:155-161`), and `AgentSkillLibrary.all` (`AIAgentPanel.swift:91`) holds **18** skills (`auto_login, volleyball, fishing, coffee, coffee_lite, bagel_spam, pinkpaw, furniture, rewards, piano, rhythm, dodge, auto_scroll, touch, drive_dataset, preset_afk, preset_realtime, tomato_juice`). 18 + 12 = **30**.

| group | count | names | backed by |
|---|---|---|---|
| skills | 18 | `skill__*` | `AgentSkillCenter.runSkill(id:source:.ai)` |
| keys | 4 | `press_key`/`hold_key`/`release_key`/`release_all` | `ControlEngine(GameKey)` |
| text | 1 | `type_text` | `ControlEngine.typeText` |
| mouse | 3 | `mouse_move`/`mouse_click`/`mouse_scroll` | `MouseController` |
| observe | 2 | `screenshot`/`get_status` | — |
| search | 2 | `web_search`/`web_fetch` | `WebSearch` (`ToolRegistry.swift:22-23`: this file implements no fetching) |

**Mounted ≠ usable** (`:156-158`): `isImplemented: skill.ported`, so only `ported: true` skills work; `preset_realtime` is `ported=false` → `ok=false`. Measured `grep -c 'ported: true'` in `AIAgentPanel.swift` = **15**, i.e. **3 of 18 not implemented** (`pinkpaw`, `rhythm`, `preset_realtime`), so the honest usable count is 27 (15 + 12) — with the caveat that grep also matched other `ported` mentions (33 occurrences of the token), so re-derive from the skill table before treating it as final. `UNVERIFIED:` per-skill flags not printed individually.

Four guards, all "explicit error, never silent" (`:24-34`): ① `AuroraFlags.observeOnly` → refuse every injection tool; ② `GameWindowDetector.isGameVisible()` → refuse when the game is not visible (prevents injecting into another window); ③ `AXIsProcessTrusted()` → refuse without Accessibility, because the system **silently discards** such events, "绝不假装成功"; ④ `dryRun` → inject nothing but return a **structurally complete** `ToolResult`. `dryRun` is deliberately **not** blocked by ② ③ (`:36-43`), else a selftest with no game window could never obtain `ok=true` and would be nothing but refusal text; ① does not block `dryRun` either but real calls stay refused — violating this destroys the "side-effect-free selftest" capability. `postedEvents` (`:45-53`) = the CGEvent delta before `invoke` returns = `(ControlEngine.postedEventCount delta) + (MouseController.postedEventCount delta)`; for injection tools it is **exactly** the count injected (0 = nothing went out); for skills it is a lower bound (async workQueue).

## 8.7 `AgentLoop`

`AgentLoop.swift:4-25`: user sentence → LLM decomposes into `tool_use` calls → dispatch via `ToolRegistry` → results fed back → plan until done. The W7 rework made planning share **one chain** with chat (`:11-17`): model calls → `LLMTransport`; models → `LLMHealthMonitor` candidate chain, ≤4 rotating; tool list → `ToolRegistry.shared.specs()`; execution → `ToolRegistry.shared.invoke(name:args:dryRun:)`. The old `AgentSkillCenter.callLLM` path is no longer used here. `MockLLM` (`:21-23`) self-tests "instruction → plan → execute → return → complete" with no available candidate.

## 8.8 Degradation ladder — three tiers

`DegradeStateMachine.swift:5-9`: E2E main drive → YOLO takeover → pure-rule fallback. **The `.recover` escape tier was deleted 2026-09-30 at the user's request**: it reduced speed and could not exit, so autodrive lasted only ≈**12 seconds** before the escape loop interrupted it (`:6-7`). Inputs: M9 alive / control model alive / tier health / boost / warm-up; output `DriveMode` + reason (`:8-9`). Principles (`:10-14`): monotone degradation with hysteresis recovery; boost overrides everything (speed first, obstacle avoidance off, forced E2E); stuck detection independent of the model; thresholds externally adjustable. Main thread only, called synchronously from `DriveState.tick` (`:24`); `update(inputs)` is pure (`:22-23`).

`RuleController.swift:8-18`: `.rule` is the **only** call point of the rule controller (`AuroraDriveApp`'s `switch decided`); `.e2e`/`.yolo` do not go through it. It also corrects an older comment: `.yolo`-tier-pure-rules / `.rule`-tier-E2E-fusion is **not** what the code does, and `fuse()` has **no call site** repo-wide (`:18-21`). Frame source depends on tier: A-model → A-YOLOM(n) int8 three-in-one `det`; legacy → `yolo26s` or YOLOPX `det` (`:8-11`); `game_assist_yolo.onnx` is long abandoned (`:11-13`). `RuleController.swift:157`, `:164`: **steer only, throttle only, never brake automatically**; emergency avoidance = no throttle + full opposite steer, `b` always 0, never reverses on its own.

## 8.9 Emergency takeover — 2026-10-22 retune

`EmergencyTakeover.swift:4-30`: on dropped ticks (`tickGap > 80 ms` ×3, later 100 ms) or model degradation, raise the tick to sprint rate and show "please take over"; a controlled key press yields to 5 Hz; release returns to cruise.

**The header diagram is stale** (`:9-10`, `:15`, `:19`, `:22` still say `[巡航] hz=20 ... [冲刺] hz=45 ... [让位] hz=5`). Live constants:
```
EmergencyTakeover.swift:55   static let normalHz: Double = 15.0   // ⚠️ 2026-10-22: 20→15
EmergencyTakeover.swift:58   static let sprintHz: Double = 20.0   // ⚠️ 2026-10-22: 45→20
EmergencyTakeover.swift:60   static let yieldHz:  Double = 5.0
EmergencyTakeover.swift:62   static let sprintMaxSeconds: Double = 35.0
```
Reasons: `:54` user measured 20 Hz pushed the game to 8–14 Hz; `:58` old 45 Hz cannot complete at all when throttled, so it was *worse*. Tick-gap threshold 80 → **100 ms** (`:68-70`): at 15 Hz a normal period is 66.7 ms, leaving only 13 ms margin at 80 ms. Sustained trigger 10 frames = 667 ms at 15 Hz (`:75`). `effectiveTickHz` is read by `EngineMain` to set `engineTickHz` (`:34`, `:87`). Fourth instance of the comment-vs-code drift class (SEC-06 §6.10).

## 8.10 Geometric fallbacks — explicitly not the main driver

`FallbackGuard.swift:6-30`, two user criteria: **A — ego position**: take the largest detection box at image centre as ego, so "is anything directly ahead" is answerable with perception down; **B — box-overlap collision**: centre box overlapping another vehicle is necessarily an avoidance case, a pure-geometric criterion needing no confidence. Discipline inherited from `LaneFallback`'s four rules (`:26-31`): ① fail-open — untrustworthy input returns nil and the caller keeps its decision; ② bounded output — steering/brake hard-limited, never full throttle; ③ multi-frame confirmation; ④ discard sudden changes.

`EgoBoxFilter.swift:8-30` solves the mirror-image problem (in third person the model always boxes **the player's own car**). Historical incident: ego box + front car's box judged "overlap = collision" → `brake 0.8` → and in this game `brake` **is the S key, which is also reverse** → the takeover state kept braking *and* reversing (`:12-17`). The rule is decided by **area**, not position, because the camera wanders ("官方为了帅车可能会到处跑……甚至可以到最远端"), settled by a 10,000-real-frame measurement (`:20-28`):

| rule | own-car masking | false-hit on real cars / frame |
|---|---|---|
| area > 2 % | **98.0 %** | 0.08 |
| area > 3 % | 97.8 % | 0.05 |
| position only (centre band + lower area) | 93.2 % | 0.06 |
| area > 3 % AND position | 93.0 % | 0.03 |

Shipped rule = the area > 2 % row (`:24`): highest success rate accepted with its slightly higher false-hit rate.

## 8.11 Segment handover — four AND conditions

`DriveSegmentController.swift:8-30`, user flow 2026-09-30: ① approach a map waypoint (corner) → enter **map segment** and steer through; ② after the turn the heading is skewed → **must straighten** using map road direction; ③ then hand over to **model/vision** for lane keeping; ④ the handover must be **confirmed**, all four conditions satisfied, else stay conservative. Verbatim (`:14-17`): "判断成功标准是在那条道路里…而且已经向前行驶一段距离…而且都能拟合在道路里…并且模型已经能正常识别到车道线，才能算准确性". Conditions (`:18-22`): ① position inside the target road corridor (`RoadMapPrior.isOnRoad`); ② actually travelled some distance (network-locate integration); ③ fitting stays inside the road for several consecutive frames; ④ vision recognises lane lines (laneMask valid). Why not hand over immediately after the turn (`:24-26`): heading still skewed and lane lines possibly unrecognised → swerve. Safety boundary (`:28-30`): it only decides **which control source**, performs **no limiting**.

## 8.12 Login assistant — perceived closed loop

`LoginAssistant.swift:6-17`: NTE stops at the login screen every launch. Loop: ① take the current frame from `CaptureEngine` (engine stream already running); ② Vision `VNRecognizeTextRequest` OCR zh/en; ③ match by priority (`点击进入` > `进入游戏` > `登录` > `开始游戏` …); ④ hit → normalised bbox → screenshot pixel → screen point → click; ⑤ re-screenshot after 2 s: text gone = success, still present = next keyword (bounded to 3 rounds, not an unbounded loop). Coordinate chain, "全部已验证" (`:14-17`): Vision bbox (normalised, bottom-left) → pixels (top-left) (`px = midX·W`, `py = (1 - midY)·H`) → screen points (`point = pixel / backingScaleFactor`). `AIAgentPanel.swift:703`: "绝不点击任何「登录」按钮（否则会误点浏览器/QQ 等窗口的登录按钮）"; `AIAgentPanel.swift:305` bans F1–F12 because macOS consumes them before the game.

## 8.13 Search tools

`WebSearch.swift` supplies `web_search`/`web_fetch`; `ToolRegistry.swift:22-23` states the registry implements no fetching. Honesty/compliance constraints are in SEC-07 §7.7.5; the performance item here: `WebSearch.swift:218-221` uses an **independent ephemeral `URLSession`** never shared with `captureQueue` or `aurora.quest.ocr`, so search latency cannot affect capture or quest OCR.

## 8.14 Self-test surface

`LLMSelfTest.swift` (2183) backs `--llm-selftest`, `--llm-vision-selftest`, `--llm-probe`, `--llm-perf-selftest`, `--websearch-selftest`, `--tool-selftest`, `--tool-call-demo` (all registered, SEC-06 §6.7.3). Discipline (`:30`, `:1288`): unverified items marked 「未验证」 and counted as failures or flagged environment-limited — "绝不编造"; print actual session state; `:211-213` scans all descriptor headers and baseURLs for hardcoded keys. `UNVERIFIED:` the assertion inventory was not enumerated.

## 8.15 Pitfalls specific to this subsystem

1. **`plainAnswer` existed but was never wired** — a real QA function with no production caller while the UI answered with canned text (`AgentChatService.swift:13-16`); no unit test catches it because the component itself passes.
2. **Mounted tools are not implemented tools** — `isImplemented: skill.ported` (`ToolRegistry.swift:158`), 3 of 18 false.
3. **`sorted { ... return false }` is not an ordering** (`LLMHealth.swift:1058`) — explicit partitioning instead.
4. **Client-side 429 must be distinguished from upstream errors** — 12-way taxonomy classified per real observation, not collapsed into "failed" (`LLMTransport.swift:32-44`, `WebSearch.swift:84`).
5. **Third-party gateway flapping** — recorded with both sides' evidence; the decision is to **not** encode a guess into the contract (`LLMBackend.swift:57-66`).
6. **Stale header diagrams** — `EmergencyTakeover.swift:9-10`, `:15`, `:19`, `:22` say 20/45/5 while constants are 15/20/5 (`:55`, `:58`, `:60`).
7. **Self-test parsing must equal production parsing** (`AuroraDriveApp.swift:1652`); weak/tautological assertions only manufacture false greens.

---

# SEC-09 — INFERENCE / PERCEPTION

`Sources/AuroraDrive/Inference` — **15 files / 14,706 lines**; `Sources/AuroraDrive/Perception` — **3 files / 620 lines**. All 18 headers read plus key contracts.

`InferenceEngineV2.swift` 3820 (M9-V2 multi-input) · `SpeedOCRReader.swift` 1924 (speedometer OCR) · `YolopxEngine.swift` 1814 (three-in-one) · `QuestPanelReader.swift` 1160 · `PointerHeadingReader.swift` 1027 · `YoloEngine.swift` 918 · `RoadCornerGuide.swift` 757 · `MotionPredictor.swift` 575 (α-β 15→30 Hz) · `InferenceEngine.swift` 522 (legacy m9_mono) · `LaneFallback.swift` 461 · `EgoMotionModel.swift` 399 · `OpticalFlowBridge.swift` 384 · `RoadMapPrior.swift` 360 (2048² prior) · `ConfidenceEstimator.swift` 357 · `LaneKeepRealityTest.swift` 228 · `Perception/LaneExtrapolator.swift` 348 · `LaneBridge.swift` 178 · `LaneExtrapolatorSelfTest.swift` 94.

## 9.1 YOLOPX — core perception asset (`YolopxEngine.swift:5-31`)

`models/yolopx/yolopx3_pal8_detfp.mlmodelc` (first candidate, 8-bit palette, det precision 100 %); `modelCandidates` probe-loads each and falls through on failure (`:8-10`). Exported by `tools/yolopx/export_yolopx_coreml.py`, parity-verified by `tools/yolopx/verify_yolopx_coreml.py` (`:10-11`).

```
det  [1, 8400, 6]      cx, cy, w, h, obj_conf, cls_conf   (640-input pixels, NOT NMS'd)
da   [1, 2, 640, 640]  drivable-area binary logits
ll   [1, 2, 640, 640]  lane-line binary logits
```
(`:13-16`)

**Three differences from `YoloEngine`(yolo26s) where a mistake fails silently** (`:18-27`): ① input is **letterbox** (aspect-preserving scale + 114 grey padding), **not** whole-frame stretch — trained on BDD100K with letterbox, so stretching distorts **both** boxes and masks; ② the `det` head is YOLOX anchor-free and **output is not NMS'd**, coordinates `(cx,cy,w,h)`, whereas yolo26s is NMS-free and emits `(x1,y1,x2,y2)`, so this engine does its own transform + NMS + grey-padding box rejection; ③ `nc = 1` — only the "car" class, mapped to `Detection.Label.car`.

Coexistence (`:29-31`): independent buffers, does not touch the incumbent detection chain, disable-able with zero impact. Mask downsampling (`:38+`): raw `da`/`ll` is 640×640×2 fp16 = 1.6 MB/frame, wasteful, so it is downsampled by `gridStride` to a **160×160** grid — the same dimension as the shm mask area (SEC-03 §3.11). Frequency by tier (`README.md:111`): `ayolom` tier every tick, `legacy` tier every even frame; `UNVERIFIED:` the exact gating line was not re-read (tier maps pinned at `EngineMain.swift:868-885`).

## 9.2 yolo26s — a different contract (`YoloEngine.swift:5-25`)

`models/yolo26s.mlmodelc` (YOLOv26s, **NMS-free end-to-end**), Ultralytics export with automatic `colorSpace=RGB`. Input `image` 640×640 `CVPixelBuffer` RGB — the app feeds 32BGRA and CoreML extracts R/G/B in order, no manual swap (`:12-14`). Output `[1, maxDet, 6]` Float32, rows `[x1,y1,x2,y2,conf,class_id]` in 640-pixels; `parse()` divides by 640 (`:15-17`). No anchors, so dedup is inside the model; Swift only confidence-filters, sorts, truncates, maps classes (`:19-21`). **Preprocessing is whole-frame non-proportional stretch to 640×640 (no letterbox)**, matching training, so pixel/640 *is* whole-frame normalised (`:23-25`). Swapping preprocessors between §9.1 and §9.2 yields plausible-looking but wrong boxes and masks.

## 9.3 M9-V2 — multi-input end-to-end (`InferenceEngineV2.swift:4-42`)

Why a new file: the original runs `m9_mono` (2 inputs: image + `vehicle_state[6]`) and is the chain **currently driving**; the new model has 5 inputs and 8-dim state, a structural change — editing in place would turn "roll back to the old model" into a large refactor (`:6-11`). Authoritative contract (`:13-17`): `src/model_v2.py` and `tools/export_m9_v2_coreml.py` (**the script that actually produces the CoreML**, with 8 measured pitfalls); **when the two disagree, the export script wins** (`:17`).

```
image         [1,3,180,320]  f32  third-person screenshot CHW in [0,1]
lane          [1,1,160,160]  f32  lane mask binary 0/1
dets          [1,20,12]      f32  boxes in fixed slots, empty slots zero-padded
det_mask      [1,20]         f32  1=valid box, 0=empty slot
vehicle_state [1,8]          f32  vehicle state
steer [1,1] tanh ∈[-1,1] ;  throttle [1,1] sigmoid ∈[0,1] ;  brake [1,1] sigmoid ∈[0,1]
```
(`:19-30`)

**Two naming traps**: ① the input name is **`lane`, NOT `lane_mask`** (`:32-39`) — `src/model_v2.py`'s forward *parameter* is `lane_mask` but the exported CoreML *feature* is `lane`; the verbatim runtime error is `KeyError: Provided key "state" ... does not match any of the model input name(s), which are: {'dets','det_mask','lane','state_workaround','image'}`. The file drives everything from one `V2InputContract.featureName` table to make this class of mismatch impossible. ② **An input must never be named `state`** (`:41-42`): coremltools 8.3 **silently renames** it `state_workaround` because `state` collides with a MIL reserved word, and the failure surfaces at inference time, not conversion time.

## 9.4 Speed OCR — dual model, three layers (`SpeedOCRReader.swift:4-30`)

Primary: PP-OCRv6 full-line — ROI slice → grey → bilinear 48×136 → replicate 3 channels → CTC decode → last 3 digits → confidence threshold (`:6-8`). Fallback: per-digit CNN `speed_digit_cnn_v4` — `cropSlots` cuts 3 slots → 90×50 each → softmax per digit (`:9-10`). **Switching rule** (`:11-14`): only a system-level runtime fault (inference throw / missing output) degrades to CNN **within the same frame** and writes `engineNotice` (orange UI banner + orange engine label beside the speed); "can't read" business diagnostics (low foreground / low confidence / short digit string) are **not** faults and do not switch. Both models failing to load writes `errorMessage`/`engineNotice` at `init` — never silent. History (`:15-17`): glyph-template matching (`speed_glyphs.json` + 0–300 residual) was replaced and deleted; `cropSlots` constants still used by the CNN path.

Why a finetuned PP-OCRv6 (`:19-25`): generic Vision OCR misreads the HUD's hollow digits (`"000"` → `"NTO0U"`); a self-trained per-digit CNN at 99.98 % is an **in-distribution** result that may collapse when resolution/game/UI change; the finetuned model = general pretraining + scene alignment, frozen test set (5077 images from unseen clips) **99.9803 %**, strongest generalisation (`PPOCRV6_FINETUNE_REPORT.md`).

Threading (`:27-30`): `infer()` on main → background `ocrQueue` → `Task @MainActor` applies `applyEngineUse()` and `finish()` writes the latest snapshot; a `generation` counter stops in-flight results landing after `reset()`. Invalid-frame pre-check (`:32-35`): frames without a speedometer are marked invalid by an Otsu-foreground ratio below threshold and never enter inference; PP-OCR adds a confidence threshold and digit-length rule. Three-layer validation cited at `README.md:49` as `SpeedOCRReader.swift:638-653` (range / jump / multi-frame); `UNVERIFIED:` those lines were not re-read.

## 9.5 Minimap arrow — body heading (`PointerHeadingReader.swift:4-30`)

Why (`:5-10`): network locate (`CoordinateCapture` / MaaNTE `nte_coordinate_api`) yields UE5 **ControlRotation** = camera/view heading; in third person the camera rotates independently, so **view heading ≠ body heading**. This reads the minimap arrow, which is **body heading** (cross-validated against in-game world-coordinate trajectories).

```
models/tiny_arrow_v2.mlmodelc
  self-trained; data = arrow sprites cut from real frames, rotated 0–360° and composited
  onto real minimap backgrounds, 20000 synthetic images at /tmp (label accuracy 0°)
  size 44 KB / 11962 params / input 64×64
  image [1,3,64,64] Float32 (RGB, [-1,1]) → heading_sincos [1,2] Float32 = (sinθ, cosθ)
  measured: val angle error p50 0.56° / p95 1.81°; 180° flip rate 0.0%;
            CPU_ONLY single-frame p50 0.087 ms; CoreML vs PyTorch max diff 0.272°
```
(`:12-18`)

**θ₀ = 332.0°** (`:20-26`): the model learns rotation relative to the sprite's native orientation, so `true compass = model output + θ₀`. θ₀ was calibrated **objectively** from in-game world-coordinate trajectories (the video's top-left permanently displays XYZ readouts readable frame by frame). Compass angle = `atan2(ΔX, −ΔY)` (+X east, +Y south, UE5-compatible). Four independent measurements were used (`:26`, list continues past the read window).

Wiring: 5 Hz dedicated lightweight `pointer` channel (`EngineMain.swift:712` — "地图指针读数 5Hz = 15Hz ÷ 3"), so it cannot run at tick rate.

## 9.6 Optical flow — OpenCV DIS, chosen by measurement (`OpticalFlowBridge.swift:4-30`)

YOLOPX single inference ≈60 ms (148 GFLOPs against measured ANE peak 9.26 TFLOPS ⇒ 16 ms floor, ≈26 % efficiency), so it cannot reach loop rate and intermediate frames must not be blind. Same-batch ABBA at 640×640, driven by the 「光流 ≤5ms」 red line (`:13-19`):

```
Apple VTOpticalFlow (VideoToolbox hardware)   10.28 ms   ✗
Vision VNGenerateOpticalFlow                   27.43 ms   ✗
OpenCV DISOpticalFlow ULTRAFAST                 1.91 ms   ✓
same, restricted to 1 core (extreme case)       3.78 ms   ✓
```
Official hardware paths are **5–14× slower**. DIS is the CVPR 2016 algorithm in OpenCV's `video` module, not custom code (`:19-21`). Accuracy (`:23`): displacement error **0.07 px** (measured `dx = 1.930` vs ground truth 2.000). Threading (`:25-30`): `ad_dis_compute` is **not** thread-safe (same ctx must not be called concurrently), so the class serialises behind a private lock and accepts calls from any thread. Build wiring `Package.swift:59-71`; static-link pitfalls SEC-01 §1.3.3.

## 9.7 Motion prediction — α-β instead of Kalman (`MotionPredictor.swift:1-30`)

Stale-box problem (`:5-11`): between inferences boxes are **completely static** while targets move. Solution (user's proposal, `:13-18`): YOLOPX low-rate ground truth (~15 Hz) + optical-flow inter-frame motion vectors (measured p95 **3.7 ms**) + an α-β filter keeping per-target position/velocity + extrapolation with correction on new observations. **Why α-β** (`:20-27`): α-β is Kalman's closed-form solution under constant-velocity + steady-state gain; covariance matrices are unnecessary here because the motion model is simple, observation noise is stable, and it must run every frame at 30 Hz where α-β costs two multiply-adds versus matrix ops. Discipline (`:29-33`): ① fail-open — if flow is unavailable, ground truth stale, or a target lost past timeout, **do not extrapolate**; return the un-predicted original detection, "绝不编造运动"; ② predicted results are marked `isPredicted = true` so the decision layer can down-weight.

## 9.8 Ego motion — the missing consumer found by static audit (`EgoMotionModel.swift:4-30`)

`OpticalFlowBridge` had long computed `dx/dy/divergence` with **zero readers repo-wide** (2026-09-30 audit), and its stated purpose "cross-check global motion direction" had **never been implemented** (`:7-12`). This file is that consumer: it turns flow-estimated **ego motion** into a criterion for validating `MotionPredictor` velocities (`:10-12`).

Why **radial**, not translational (`:14-28`): α-β velocities come from box differences, which misread "the ego is moving" as "the target is moving" when a target is static. Subtracting the global median `dx/dy` is **wrong**: ego **lateral** movement pans the image so `dx` describes it ✓, but ego **forward** movement makes content expand **radially toward the vanishing point** ✗. When moving forward, centre targets barely move while edge targets fly outward — exactly what `divergence` measures. Geometry (`:24-30`): vanishing point at image centre; for `r = (px − cx, py − cy)`, `u_ego = forwardRate · r_x`, `v_ego = forwardRate · r_y`.

## 9.9 Road prior — bitmap prior, heading only (`RoadMapPrior.swift:4-30`)

Purpose: when lane lines are entirely lost (junction / U-turn / occlusion / stutter), supply "which way does the road turn" (`:5-8`). **Hard boundary** (`:10-12`): **heading only, never lateral offset** — lateral must come from real-time vision, because the map is player-annotated with metre-level deviation and using it for lateral would directly mis-steer. Source (`:14-16`): `models/road_prior_2048_t70_fixed.png`, generated offline from `models/bigworldmap-13056.jpg` by `models/tools/make_road_prior_t70.py` and `make_road_corners_v2.py`, reproducible.

**Three corrections (2026-09-30), all previously wrong and pointed out by the user** (`:18-30`; a 2026-10-18 note fixes a "two vs three" typo):
1. **Threshold**: 45 captured **16.1 % extra contour noise** (measured 677,265 pixels), causing 83 % of corner waypoints to land on buildings/contours. Full-image grey histogram: 0–8 pure black 47.6 % / 16–24 dark ground 45.0 % / 24–56 buildings+contours 4.8 % / **80–88 real road 1.95 % (the only one)**. Threshold 70 gives 98.6 % connectivity; threshold 80 collapses to **37 %**.
2. **Scaling**: old `H//2048 = 6` (integer truncation) made each cell 6 px instead of 6.375 px, and `2048*6 = 12288` **discarded the last 768 px (468 m)** → systematic offset, 66.6 % of waypoints >24 m from real road. BOX-scaling to exactly 6.375 px/cell over the full extent gave median deviation **0.0 m**, 94.3 % within 1.8 m, 100 % within 9.8 m.
3. (Third correction continues past the read window; `UNVERIFIED:` its exact content.)

## 9.10 Corner waypoints — v1's three mistakes (`RoadCornerGuide.swift:4-30`)

Waypoints rather than pure vision (`:6-10`): lane vision often fails at corners/junctions, while the map is a **fixed** prior. **v2's three properties, all wrong in v1** (`:12-22`): ① **dense** — one point every ~23 m (**952 positions**), not one per corner, else entering from another position/lane misses it; ② **bidirectional** — each position yields two records (opposite `turnSign`) because a bend can be driven both ways; matching must select the record agreeing with ego heading, else the wheel turns the wrong way; ③ junction data retained (`branchCount ≥ 3` with branch directions) but **turning decisions do not yet cover junctions** — logging/future only.

Division of labour (`:24-29`): `RoadMapPrior` = bitmap (2048²) → `isOnRoad` / `roadHeadingCandidates`; `RoadCornerGuide` = waypoint set → `cornerAhead` / `steerForCorner`.

## 9.11 Quest panel OCR (`QuestPanelReader.swift:4-30`)

The left quest panel says e.g. "与路边着急的研究员对话" — the player understands, the car does not. Python tooling compiled 39 quest tables (`tools/nte_datatables`) into `models/quest_index.json` — **1372 exact texts → 2938 located objectives** (`:6-11`).

```
CaptureEngine frame (tick 主线程取 currentFrameCG)
  → crop questROI (normalised, top-left origin)
  → Vision VNRecognizeTextRequest (zh-Hans)
  → filter hint lines → join lines into query text
  → voting buffer (3 consecutive identical results required)
  → 4-way match: exact → substr → core → fuzzy (+ byname fallback)
  → verdict (ok / ambiguous / low / miss) → ambiguous: NextQuests chain
  → state.setLocatorTarget(x:y:) + state.questName
```
(`:13-25`) **Red line 1: coordinate system — not a single conversion is performed** (`:27-28`); `UNVERIFIED:` the remaining red lines were not read. Cadence: `minInterval = 0.7` s (`README.md:54` cites `:414-431`; `UNVERIFIED:` not re-read), default-on via `AuroraFlags.questOCR = true` (`AuroraFlags.swift:209`).

## 9.12 Confidence estimator — the dead-model equilibrium bug (`ConfidenceEstimator.swift:4-30`)

E2E outputs no confidence, so this estimates it from output history + current image; the [0,1] score feeds the degradation state machine (`:5-6`). Gate + three fused signals (`:8-22`): ⓪ **link-liveness gate** — not loaded / no result / stale ⇒ confidence 0; the old formula gave **0.70** for a dead E2E emitting `idle`, above the 0.65 degradation threshold, so a **dead model stayed in the E2E tier forever** (`:9-11`). ① output consistency — lower steer jitter over N frames is more trustworthy. ② steer extremeness — `|steer| > 0.95` pinned for long is degeneration; throttle/brake at the edge is normal and no longer penalised, fixing "healthy cruise sat at exactly 0.70, could never reach the 0.75 recovery threshold, and stayed stuck in the rule tier" (`:14-17`); stable output is **not** judged frozen, since on a straight road the model is *supposed* to be stable (`:17-18`). ③ frame validity — all-black/all-white ⇒ low confidence. Design (`:24-28`): sliding window with O(1) update, weights adjustable, main-thread only.

## 9.13 Lane fallback — four disciplines (`LaneFallback.swift:4-24`)

**Fallback, not main driver**; every principle serves "the fallback must never become the accident source" (`:8-9`): ① **fail-open** — untrustworthy input (degraded / empty mask / size mismatch) returns nil and the caller keeps its decision, never "guess a direction" (`:10-11`); ② **bounded output** — steer clamped to ±`maxSteer`, throttle may only decrease, never full throttle (`:12-14`); ③ **multi-frame confirmation** — same deviation N consecutive frames (`:15-16`); ④ **discard sudden changes** — jumps beyond threshold treated as anomalous, previous value retained (`:17-18`). Pure functional, only internal state a caller-fed stability counter (`:20-22`).

`Perception/LaneBridge.swift:168-176` supplies the same red line for mask geometry: `isUsable` only checks "dimensions positive + cells long enough", deliberately **not** a strict `== 160` gate (that is `LaneFallback`'s guard ②); if `cells` is shorter than `width*height`, `LaneFallback` would later `SIGTRAP`, so it must be intercepted early. `Perception/LaneExtrapolator.swift:57`: on a malformed mask return `.empty` and **never fabricate lane lines**; its guard shares origin with `MaskGrid.at`.

## 9.14 Engine-vs-local asymmetry

`EngineMain.swift:22-34`: YOLOPX **never runs in engine mode** — `tick()` early-returns via `tickEngineMode()` and the single `yolopxEngine.infer(image:)` call site is after that return. Test implication stated in-source: **local selftests cannot catch engine-mode perception bugs**. Consequence chain: `MaskOverlay` reads locally-valid data, `yolopxEngine.isDegraded` stays `true`, `LaneFallback` does not engage. Root cause of the bug in SEC-07 §7.8.1, invisible to every local selftest.

## 9.15 Testing surface

Perception one-shot modes (SEC-06 §6.7.3): `--yolopx-selftest --yolo-selftest --yolo-bench --speed-selftest --pointer-selftest --opticalflow-selftest --motion-selftest --corner-selftest --route-selftest --taxonomy-selftest --perception-selftest --ayolom-selftest --v2-selftest --lanekeep-selftest --lanekeep-reality --lane-extrapolator-selftest --capture-selftest --quest-selftest --egobox-selftest --fit-selftest --realshot-selftest`. Two semantics: `--lanekeep-reality` exists because existing self-checks only validated contracts and **never measured real behaviour** (`AuroraDriveApp.swift:1022-1026`); absolute timings are not comparable across sessions — 2–2.5× drift on the same binary (`PerfSelfTest.swift:868-874`, SEC-07 §7.6.1), so use same-session A/B or `scripts/paired-ab.sh --metric tick`.

## 9.16 Pitfalls

1. **YOLOPX letterbox ≠ yolo26s stretch** — wrong preprocessor silently distorts boxes and masks (`YolopxEngine.swift:18-22`).
2. **YOLOPX `det` is not NMS'd and is `(cx,cy,w,h)`** (`:23-25`).
3. **Feature name `lane`, not `lane_mask`**; never name an input `state` (`InferenceEngineV2.swift:32-42`).
4. **`dx/dy/divergence` had zero readers** until `EgoMotionModel` — a dead-data class found by static audit (`EgoMotionModel.swift:7-12`).
5. **Ego motion must be radial** (`EgoMotionModel.swift:18-28`).
6. **Road prior is heading only** — using it for lateral mis-steers by metres (`RoadMapPrior.swift:10-12`).
7. **Corner matching must respect ego heading** (`RoadCornerGuide.swift:16-19`).
8. **A dead E2E scored 0.70** — above the 0.65 threshold, never degraded (`ConfidenceEstimator.swift:9-11`).
9. **A healthy cruise scored exactly 0.70** — never reached 0.75 recovery, stuck in the rule tier (`ConfidenceEstimator.swift:14-17`).
10. **Dual-model switching only on system faults, not "can't read"** (`SpeedOCRReader.swift:11-14`).
11. **θ₀ = 332.0° is calibrated, not a guess** — omitting it rotates every heading by a fixed amount (`PointerHeadingReader.swift:20-26`).
12. **Engine-mode blindness**: local selftests validate a different perception path (`EngineMain.swift:22-34`).

---

# SEC-10 — UI / DriveState / TICK ORDER / PANELS / MAP WIRING

`Sources/AuroraDrive/App` — **17 files / 25,764 lines**. `AuroraDriveApp.swift` 10,008 · `MissionConsole.swift` 8,003 · `PerfSelfTest.swift` 992 · `MapSelfTest.swift` 985 · `CategoryPanel.swift` 875 · `AuroraTheme.swift` 773 · `MapLayers.swift` 669 · `MapWindow.swift` 648 · `MapWiring.swift` 613 · `RouteGraph.swift` 554 · `ControlWiring.swift` 542 · `RealShotSelfTest.swift` 257 · `AuroraBrand.swift` 246 · `MarkerCluster.swift` 240 · `MarkerTaxonomy.swift` 201 · `GameHUDWindow.swift` 123 · `LocateRuntime.swift` 35.

## 10.1 The tick is the single production loop

`DriveState.tick()` at `AuroraDriveApp.swift:7568`. Both processes run **the same** `tick()` (`:7578`); the process is chosen by one early return:

```swift
// AuroraDriveApp.swift:7682-7689
if EngineClient.shared.isActive {
    tickEngineMode()
    PerfBus.mark("tick.engineMode", from: perfT)
    return
}
```
`tickEngineMode()` is at `:7203`. Everything below the return is the **local** path (capture, inference, control, recording); everything above runs in **both** processes.

**Line-number drift warning**: the comment at `:7576-7577` cites the early return as `:6886`, and `:7744`/`:7750` repeat it. The real line is **`:7683`**; reading `:6886` lands in an unrelated observe-only block (`AuroraFlags.observeOnly` / `controlDisabled`). Any edit trusting the comment edits the wrong place.

## 10.2 Tick order (`:7568-7692`)

1. **`tickGapMs` first** (`:7570-7572`): `tickNow - lastTickTime` ms, used with `capGap`/`capWork` for latency attribution; `>33 ms` means the main thread dropped a beat or blocked (`:7569`).
2. **Emergency-takeover feed, gated to non-engine mode** (`:7574-7605`): it **must** precede the engine-mode early return (`:7576-7581`), but in engine mode the UI must **not** compute state locally (`:7600-7605`). Reason (`:7588-7596`): the UI unconditionally calls `yolopxEngine.loadIfNeeded()`, so in `ayolom` tier `isDegraded` is permanently true (da=0 cells, ll=0 cells; engine log 121/121) → the UI would `enterSprint()` → `takeoverActive=true` while the engine heartbeat reports the real state and `syncFromEngine` writes false back → **the banner flickers**. Fix: in engine mode the UI is a **display mirror driven by heartbeat only**; only UI-local mode feeds locally. `tickGap` is gated with it (`:7598-7599`). `isDegraded` is fed only when `isLoaded` (`:7602-7604`): before load it defaults true ("no model = degraded"), which must not trigger takeover.
3. **Perf instrumentation** (`:7607-7614`): `var perfT = PerfBus.stamp()`; `tick.total` settled with `defer { PerfBus.mark("tick.total", from: perfStart) }` **so every return path** is counted; with `AURORA_PERF` unset `stamp()` returns 0 and every `lap` short-circuits (`:7608-7609`).
4. **Even/odd frame phase split** (`:7616-7637`), "at the very front of tick" so `inferFast` and the slow driving path share one phase counter (`:7617-7618`): `detectGateA` = yolopx three-in-one (`det/da/ll`) on even frames; `detectGateB` = yolo26s on odd. Rationale (`:7620-7622`): both stopping on the same frame creates "vacuum frames". **2026-10-07 user decision: the `ayolom` family is not decimated** (`:7624-7629`) — the E4 original gated `yolopxEngine.infer` unconditionally, halving the default ayolom model to 15 Hz, but ayolom is measured p50 **10.4 ms** on ANE (95.9 Hz; only 31 % of a 30 Hz budget), so `detectGateA` is **always true for ayolom** (`:7637`: `decimateFallback || isAyolom || parityEven`); the offset applies only to legacy-tier yolopx + yolo26s. Rollback: `AURORA_DETECT_DECIMATE=1` makes both gates always true (`:7631`, `:7634`).
5. **yolo26s tier gate** (`:7639-7642+`): before 2026-10-19 yolo26s had **no** tier gate and inferred every other frame even in A-model tier.

Consequence: tick frequency is not "the model rate" — the tick rate is `EngineMain.engineTickHz` (15 Hz), and within a tick the nets are further gated by tier and frame parity. Any timing measurement assuming "one inference per tick" is wrong in legacy tier and wrong for yolo26s.

## 10.3 Observe-only is enforced in the UI too

`AuroraDriveApp.swift:6886-6896`: `let observeOnly = AuroraFlags.observeOnly`; if set, `controlDisabled = true` and an `[OBSERVE]` log says "推理/定位/渲染照跑，按键注入全路径关闭". Three independent enforcement points for one flag — engine TCC narrowing (SEC-03 §3.6), UI `controlDisabled`, and `ToolRegistry` guard ① (SEC-08 §8.6): deliberate defence in depth.

## 10.4 `DriveState` — the one shared state object

`@MainActor final class DriveState` at `AuroraDriveApp.swift:4235-4236`, instantiated **once per process**: the UI for real, the engine its own copy (`EngineMain.swift:1234`) from the same class code — which is why a `@MainActor`-only class can live in a process with no run loop: the engine drives it via `MainActor.assumeIsolated` inside `dispatchMain()`.

Marker sections (real lines): recording viewpoint fixed to third person `:4712`; stuck→manual intervention `:5892`; anti-freeze heartbeat **disabled** `:7055`; one-click training `:7070`. `UNVERIFIED:` the full field inventory was not enumerated.

Fields other sections depend on: `perceptionMode` — a UI-process property, nothing writes it engine-side (SEC-03 §3.12); `locatorFound`, `locatorX/locatorY` — drive the map (§10.7); `isDriving`, `isStreaming`, `isRecording`, `mode`, `speedKmh`, `confidence` — echoed in the heartbeat (SEC-03 §3.7); `speedKmh` is **switched by process role**: `:5592` `var speedKmh: Double { EngineClient.shared.isActive ? remoteSpeedKmh : speedOCR.speedKmh }`; same pattern for detections at `:4304`; `captureEngine.isEngineHost`, `remoteKeyMask` — the engine has no `NSEvent`, so recorded keys come from the UI (`EngineMain.swift:1235-1237`).

## 10.5 UI composition tree

`MissionConsole.swift` (8,003) holds the whole console as small `View` structs:
```
ConsoleCard :29    CardHead :69     TopBar :95       BrandMark :182   TBStat :202
PillStat :236      PermissionPill :271  RCChip :320  RCBar :366       KeyBar :445
MainGrid :541      LeftColumn :566  ViewportPanel :584  WindowPickerRail :838
TagChip :1139      QuestCard :1220  RCWarn :1421     StuckWarn :1463  TakeoverWarn :1524
GearRing :1567     AutoSpeedPill :1635  DualGauge :1709  GaugeDial :1740  MidColumn :1801
MiniMapCard :1823  MiniMapCanvas :1959  MapTileStore :2270  MapTileCache :2367
MapBaseImageProvider :2812  MapTileImage :2862  BaseMapGrade :2910  MapPin :3069
MapCorner :3091    NavLine :3106    NavGuidance :3171  HardwareBank :3268
BankSwitch :3334   LeanRecordBar :3402  PerceptionPickerCard :3551  RunLogCard :3664
```
Live path for the lean-recorder button: `ContentView → MainGrid → MidColumn → HardwareBank → LeanRecordBar`, with `LeanRecordBar(state: state)` instantiated at **`MissionConsole.swift:3326`**; no conditional wrapper, no `ScrollView`, no fixed-height clipping. Why it matters: a previously shipped build had the button compiled in but unreachable, and the only valid proof of presence is `nm <binary> | grep -c LeanRecordBar` (the string table cannot see Chinese literals; `UNVERIFIED:` those results were produced in an earlier session).

**`ControlWiring.swift:1-15` — "no dead buttons"**: 界面上的每一个可点元素，背后都必须有一条真的执行路径。没有执行路径的，宁可不画。Wiring (`:8-15`): ① road-condition 4-state → `DriveState.roadCondition` (+ auto-speed `speedLimit` linkage); ② auto-speed switch → `speedLimit` via engine `config`; ③ four-tier degradation chain → `forceRuleMode`/`degradeThreshold` over `config`; ④ speed slider → `speedLimit` (20…unlimited); ⑤ 18 skills → `AgentSkillCenter.toggleSkill(id:source:.human)`; ⑥ engine's 9 commands → `EngineClient.sendCommand`. Documented mismatch: ③ says 「四挡降级链」 while three ship (SEC-08 §8.8, `.recover` deleted 2026-09-30) — the list was not updated.

## 10.6 Map wiring — coordinate transform and the invisible-matrix trap

`MapWiring.swift:1-13`: `CoordinateCapture` → world coords (UE5 cm) → `worldToMapPixel()` → map pixels (**13056×13056**) → viewport-normalised → minimap/bigmap. All **derived on the fly, never cached** ("定位一变地图立刻跟着动", `:11`). Unlocked locator → `mapPixelX/Y` return the map centre (`:39-46`), caller decides on `locatorFound` (`:12`). Pure math is `nonisolated` (`:24-27`, `:29`, `:34`).

**Documented near-miss** (`MapWiring.swift:52-78`): the inverse must **not** reuse `CoordinateTransform.invert` (`NetworkLocator.swift:55`) because they are **not the same matrix**: `MapWiring.worldToMapPixelX`: `mapX = A·wx + B·wy + TX`; `CoordinateTransform.apply`: `x' = a·x − b·y + tx`. The **B term has opposite sign**. Numerically `B = 5.69e-08`, so at coordinates ~1e5 it differs by only ~**0.006 px** — invisible, constant, never crashes ("看不见的错": 量小、恒定、永远不崩). The inverse is therefore solved from MapWiring's own equations with a round-trip selftest (`--route-selftest` asserts deviation < 0.5 px):
```
mapX = A·wx + B·wy + TX ;  mapY = A·wy − B·wx + TY
dx = mapX − TX ; dy = mapY − TY
[dx]   [ A   B ] [wx]
[dy] = [−B   A ] [wy]      det = A² + B²  (A≠0 always invertible)
wx = (A·dx − B·dy) / det ;  wy = (B·dx + A·dy) / det
```
(`:70-78`)

## 10.7 Map UI layer inventory

`MapWiring.swift` 613 (transforms, viewport normalisation) · `MapWindow.swift` 648 (separate big-map window) · `MapLayers.swift` 669 (layer toggles: teleport / material / chest / oracle stone, `README.md:37`) · `MarkerCluster.swift` 240 · `MarkerTaxonomy.swift` 201 · `MapSelfTest.swift` 985 (`--map-selftest`) · `RouteGraph.swift` 554 (664 nodes / 932 edges) · `CategoryPanel.swift` 875 · `LocateRuntime.swift` 35.

`README.md:38` asserts `models/route_graph.json` with **664 nodes / 932 edges** and dead-end rate 19.3 % → 5.4 %, pinning evidence to `AuroraDriveApp.swift:2135` plus selftest assertions at `:2139-2140`; `UNVERIFIED:` those two lines were not re-read — the numbers are README claims to be re-derived from `models/route_graph.json`.

`LocateRuntime.swift:30-31` holds a `VisualLocator` that is never assigned; `grep -rn "VisualLocator(" Sources/` has zero hits. `README.md:62` records that `NetworkHealer` was retired with commit `76e9027` and "8 种诊断 + 自动修复" has no implementation. Shipped behaviour: network locate plus freshness tiers (live ≤18 s / recent ≤40 s / stale ≤90 s / lost >90 s; `recent` and older do not participate in decisions), cited at `README.md:56` as `AuroraDriveApp.swift:4620-4626` (`UNVERIFIED:` not re-read).

## 10.8 Display path — MetalFX is display-only

Red line stated in three places: `README.md:100-101` ("插帧/超分只作用于显示叠加层，绝不进入决策链路"), `CaptureEngine.swift:128-130` (MetalGoose needs full frames for temporal interpolation / spatial upscaling, on a separate callback), `AuroraDriveApp.swift:6037-6040` ("插帧/超分直通：全分辨率帧 → MetalGoose 引擎（仅显示路径）"). Enforced mechanically by frame fan-out: `onUpscaleFrame` is a separate closure gated by `isUpscaleWanted()` (SEC-04 §4.8), and the engine installs a gate returning false unless the UI requested full frames (`EngineMain.swift:1248-1250`). Vendored engine `Vendor/MetalGoose` = 5 Swift files / 2,780 lines under `Vendor/MetalGoose/Engine`, listed in `Package.swift:163-178` as excluded except the `Engine` subtree (`Package.swift:189-192`); `NOTICE:16-27` records it as GPL-3.0, vendored unmodified, separate target, **display path only**.

## 10.9 Frame delivery — latest-frame overwrite

`AuroraDriveApp.swift:6018-6027`: `nonisolated(unsafe) var frameDeliveryLagMs`, `private nonisolated(unsafe) var pendingFrame: NSImage?`, `pendingFrameCG: CGImage?`. The callback publishes the newest frame and the tick consumes the newest each cycle, so backlog is impossible — old frames are overwritten; when the main thread cannot keep up, intermediate frames are dropped rather than queued (`:7690-7692`). `frameDeliveryLagMs` makes that visible. Same pattern as the engine's full-frame slot (`EngineMain.swift:1243-1247`, lock-protected single slot) — one pattern, two processes.

## 10.10 Panels

`ViewportPanel` `:584` preview frame; `WindowPickerRail` `:838` pull-out window list driving capture mode (`CaptureEngine.CapturableWindow`, SEC-04 §4.2), user quote in `CaptureEngine.swift:10-15`. `HardwareBank` `:3268` holds `BankSwitch` `:3334` and `LeanRecordBar` `:3402` (the lean recorder's long flat button). `KeyBar` `:445` renders live key state from `KeyboardMonitor`/`ControlEngine.heldKeys`; `GearRing` `:1567`, `DualGauge` `:1709`, `GaugeDial` `:1740`, `AutoSpeedPill` `:1635` are instrumentation. Warnings are their own views: `RCWarn` `:1421`, `StuckWarn` `:1463`, `TakeoverWarn` `:1524`, matched to `EmergencyTakeover` / `DegradeStateMachine` stuck detection. `RunLogCard` `:3664` is the log surface; logs also mirrored to files with caps (SEC-03 §3.13).

## 10.11 Theme / brand

`AuroraTheme.swift` (773) and `AuroraBrand.swift` (246). Brand rule crossing files: upstream `MaaNTE` may appear in **source comments** as provenance but never in user-visible strings or identifiers (`ControlEngine.swift:4-16`, SEC-07 §7.7.7). `PrivilegePill` (`Core/PrivilegePill.swift`, 472) is the in-app password + `sudo -S` escalation UI replacing native dialogs (SEC-07 §7.7.4).

## 10.12 Selftests covering this layer

`--map-selftest` (`MapSelfTest.swift` 985), `--route-selftest` (inverse round-trip < 0.5 px, §10.6), `--mc-map`/`--mc-shot`/`--mc-route`/`--mc-quest`/`--mc-map-bench` (headless `ImageRenderer`; must run **before** the run loop or they hang — SEC-07 §7.5.10), `--agent-ui-shot`/`--agent-layout-shot`, `--tick-profile`/`--tick-bench`, `--perf-selftest`, `--realshot-selftest`, `--wire-selftest`, `--flags-help`. `--mc-shot`/`--mc-map` dispatch at `AuroraDriveApp.swift:787-795` synchronously; `--mc-map` renders via `MissionControlShot.renderMapNow()` with `exit(ok ? 0 : 1)`.

## 10.13 UI-layer pitfalls

1. **Engine-mode early return sits above all local work** (`:7682-7689`) — anything needed in engine mode must be **above** it; two comments exist purely to record bugs from getting this wrong (`:7576-7581`, `:7744-7750`).
2. **Comments cite stale line numbers** (`:7576` says `:6886`, real `:7683`) — re-grep before editing.
3. **Feeding takeover state locally in engine mode caused banner flicker** (`:7588-7596`).
4. **`isDegraded` defaults true before load** (`:7584-7586`) — feeding it ungated triggers takeover on a fresh process.
5. **A default small model was being decimated for no reason** (`:7624-7629`) — ayolom 10.4 ms p50 against a 66.7 ms budget.
6. **The inverse transform is not the inverse of the other class's transform** (`MapWiring.swift:52-78`) — 0.006 px sign error, invisible, never crashes.
7. **Wiring list says four degradation tiers while three ship** (`ControlWiring.swift:8-15` vs `DegradeStateMachine.swift:5-9`).
8. **A button can be compiled in and still unreachable** — the only valid proof is symbol presence (`nm | grep -c`), not string search, because Chinese literals do not land in the string table.
9. **Headless render must precede the run loop** (`:787-790`, measured 240 s hang).

---

# SEC-11 — ML TRAINING PIPELINE (`src/*`, dataset_v3, model_v3, train_v3, export)

`src/` — **22 Python files / 17,706 lines** (no `__pycache__`). Largest: `train_v2.py` 2317, `model_v2.py` 1930, `risk_head.py` 1822, `model_v3.py` 1648, `dataset_v2.py` 1417, `model_v3_experiments.py` 1045, `dataset_v3.py` 913, `verify_heads.py` 699, `heading_head.py` 644, `verify_lane_usage.py` 613, `model.py` 596, `train_mono.py` 558, `temporal.py` 519, `train_game_assist.py` 498, `world_model.py` 485, `train_v3.py` 449, `mono_dataset.py` 375, `lane_geometry.py` 330, `config.py` 283. `tools/` — **219 `.py` / 53,298 lines**, append-only archaeology (SEC-01 §1.9).

## 11.1 `dataset_v3` — the contract the recorder must satisfy

`src/dataset_v3.py:257` `class V3KeyDataset(Dataset)` — the name is `V3KeyDataset(clips_dir=...)`, **not** `V3ClipDataset`.

Required columns, order-independent:
```
src/dataset_v3.py:65-69
REQUIRED_COLUMNS = ["t_sec","frame","w","a","s","d","shift","space","super_brake","ultimate_brake"]
src/dataset_v3.py:72
ATOMIC_KEYS = ["w","a","s","d","shift","space"]
```
The comment at `:65` dates the format: "录制器 2026-11-03 起的必需列（顺序无关）". **Absent**: `speed_kmh` is not required (read opportunistically, may be empty) and there are **no** position / heading / acceleration columns — the upstream reason the recorder dropped them (SEC-05 §5.3). Header validation (`:456-464`): missing columns raise `ValueError` naming the missing set, printing the actual header and stating V3 needs the post-2026-11-03 pure-key format; old format must be rebuilt via `keylog.csv` or re-recorded.

**Frame-rate contract — a raise, not a warning:**
```
src/dataset_v3.py:86   EXPECTED_FPS = 15
src/dataset_v3.py:89   FPS_TOLERANCE = 0.15
```
Reasoning (`:80-85`): deployment tick is 15 Hz (citing `EngineMain.swift:709`), and V3's 24-frame window is designed at 15 Hz = 1.6 s (`model_v3.py:274`); recording at another rate desynchronises "how long 24 frames cover" from deployment — at 10 fps, 24 frames span 2.4 s and the motion looks slower. Validation (`:427-450`): skip if `expected_fps is None` or <2 rows; parse `t_sec` (non-numeric raises with the clip name); positive deltas only, take the **median**, `actual_fps = 1.0/median_dt`; if `abs(actual_fps - expected)/expected > FPS_TOLERANCE` → `ValueError` quoting measured fps, assumed fps, tolerance, rationale and remedy (`--fps 15` re-record, or pass `expected_fps=None`). Accepted band **12.75–17.25 fps**.

Sample shape (`src/dataset_v3.py:258-278` docstring):
```
image_hi      [3, 224, 384]        current frame (high-res)
image_lo      [21, 3, 112, 192]    previous 21 frames (low-res), padded with earliest
lane          [1, 160, 160]        lane mask   → currently a ZERO image
dets          [20, 12]             detection boxes → currently ZERO
det_mask      [20]                 valid mask → all zero
vehicle_state [8]                  + 8 targets
```
**Explicitly recorded gap** (`:275-277`): `lane` and `dets` are zero-padded because the recordings contain neither; V3 inherits V2's contract and accepts them, but **training with zeros means those two branches learn nothing** — a recorded open item requiring the recorder to persist lane masks and detection boxes.

Constants (`:74-78`): `NUM_HI_FRAMES = 3`, `NUM_TOTAL_FRAMES = 24` (must agree with `model_v3.V3Config.num_hi_frames`, default 3) — 3 high-res (`t, t−1, t−2`) + 21 low-res (`t−3 … t−23`) = 24 frames @15 Hz = 1.6 s. Constructor (`:279-307`): `V3KeyDataset(clips_dir, image_size=(224,384), lowres_size=(112,192), history=21, augment=False, view_filter=None, skip_all_zero=True, seed=42, expected_fps=EXPECTED_FPS)`; raises `RuntimeError("需要 Pillow：pip install pillow")` if PIL is missing; caches `index: List[(Path,int)]`, `_rows_cache`, `_cm_cache` (per-clip `[N,6]` atomic-key matrix). `skip_all_zero=True` drops frames whose 8 keys are all zero (`:386`), erroring `"所有 clip 均无有效样本"` if everything drops (`:400`); the docstring at `:321` states skipping does **not** shift later frame numbers because the index keeps CSV row order.

## 11.2 The 8 output heads and derived labels

Names (`src/dataset_v3.py:15-18`):
```
handbrake    [B,1] 0/1   (= shift)
brake        [B,1] 0/1   (= space)
super_brake  [B,1] 0/1   (= shift ∧ space)
ultimate     [B,1] 0/1   (= shift ∧ space ∧ s)
```
**Combination consistency is validated, not assumed** (`:183-195`): `super_brake != (shift and space)` raises naming the row and all three values; likewise `ultimate != (shift and space and s)`. That redundancy is the point — disagreement proves corruption.

Key semantics (user-authoritative; cross-referenced from `KeyboardMonitor.swift:111-112` and the CSV): Shift = handbrake; Space = normal brake; Shift+Space short = super brake; long press = ultimate brake; S alone = reverse; S during ultimate braking = anti-rollover. `dataset_v3` encodes `handbrake=shift`, `brake=space`, `super_brake=shift∧space`, `ultimate=shift∧space∧s` — **the safety heads are Boolean functions of three atomic keys**, which is why recording raw keys is sufficient.

`intent_from_keys(w,a,s,d,shift,space)` at `:160-171` gives the intent head. `risk` labels (`:231-233`): `ultimate_brake` (Shift+Space+S) → **1.0** (highest risk, actively limit-braking); `super_brake` (Shift+Space) → **0.8**; `space` or `s` → **0.5**.

## 11.3 `model_v3` — structure and provenance

`src/model_v3.py:1-2` marks the file `[TRAINING-ONLY]`: offline training/export only, CoreML/C++ executes at runtime. Header (`:3-8`) declares it the integrated implementation of the three `docs/v3-design/` documents (`01-backbone.md`, `02-temporal.md`, `03-output-head.md`).

**Paper-derived mechanisms to preserve verbatim** (`:11-30`), from `docs/v3-design/papers/state_aware.txt` (arXiv:2310.20650), *Addressing Limitations of State-Aware Imitation Learning for Autonomous Driving*: ① **State Token Propagation** (§IV.A, `:173-207`) — the ego state (`t−1` steer/throttle/brake/speed) becomes a special Transformer token, role-equivalent to ViT's CLS token (paper `:193`), but its content is **measured**, not learned; between stages **only this token propagates** (paper `:179-181`), so each stage can "look at the image again with a new question". ② **Pixel-State Attention** (§IV.B, `:208-245`) — the conv feature map is flattened into N visual tokens, the state token prepended, all doing self-attention, so every pixel attends to other pixels **and** to vehicle state (paper `:236-237`) — both the multi-stage path and the source of interpretability. ③ Coarse-to-fine multi-stage (§III/§IV.D, continues past the read window).

`V3Config` at `:329-330`; `num_hi_frames: int = NUM_HI_FRAMES` (`:342`); total-frame property `num_hi_frames + num_lo_frames` (`:384`); validation `num_hi_frames ≥ 1`, `num_lo_frames ≥ 0` (`:438-439`). Reparameterization `def reparameterize()` (`:506`, `:1103`) folds training-time branches into the deployment form (`:1114` "折叠 → 部署态"); `export_coreml()` omits training-only parameters (`:209`, `:1124`).

## 11.4 `train_v3` — supervision is raw keys, selection is macro recall

`src/train_v3.py:4-9` states the premise (「模型直接输出标签，不要油门」): the supervision target **is the raw keys** (`w/a/s/d/shift/space`) expanded into 8 heads; flow is `controls.csv(pure keys) → dataset_v3 → 8 head targets → V3Loss`. **No continuous (steer/throttle/brake)-to-key conversion exists anywhere in this file.**

v2 relationship (`:11-19`): reuses `build_adamw_optimizer` (no weight decay on BN/bias) and `CosineWithWarmup` from `train_v2.py`, but **not** the v2 data pipeline, because v2 reads continuous values and v3 reads pure keys.

**CCM is explicitly disabled during training** (`:21-29`): `V3Model.forward` returns `['brake','confidence','handbrake','horizontal','intent','risk','super_brake','ultimate','vertical']` — **no `ccm`** — and `V3Loss` computes the CCM term only when both `ccm_pred` and `ccm_target` are passed, otherwise it **silently skips**. So training passes `enable_ccm=False` explicitly, making "CCM not enabled" a **stated decision**; enabling requires wiring a ccm output into forward first.

**Model selection must not use overall accuracy** (`:30-35`): a trivial "always output W" already scores **80.8 %** while never predicting S. The script selects by **macro recall** (mean of per-class recall) and logs per-class recall plus the confusion-matrix diagonal.

Usage (`:37-44`): inspect distribution first (`python3 src/dataset_v3.py --stats data/raw_clips`) to set class weights; then `python3 src/train_v3.py --clips data/raw_clips --epochs 30 --batch-size 8`; smoke run = 2 epochs, small batch.

## 11.5 Export chain

Exporters in `tools/`: `convert_e2e_to_coreml.py`, `convert_e2e_v2.py`, `convert_e2e_v3.py`, `convert_yolo_to_coreml.py`, `tools/yolopx/export_yolopx_coreml.py` (+ `verify_yolopx_coreml.py`), `tools/export_m9_v2_coreml.py` — the last is the **authoritative** contract source per `InferenceEngineV2.swift:14-17` ("含 8 个实测坑") and explicitly wins over `src/model_v2.py` when they disagree, because it decides what lands on disk.

Cross-layer constraints: Swift drives CoreML feature names from one constant table because exported names diverged from Python parameter names — `lane` vs `lane_mask`, and an input named `state` gets **silently renamed** `state_workaround` by coremltools 8.3 (`InferenceEngineV2.swift:32-42`, SEC-09 §9.3). Model assets live under `models/` (**193 top-level entries: 52 `*.mlmodelc`, 105 `*.mlpackage`**, 3.9 GB) and are not git-friendly (SEC-01 §1.5). `NOTICE:30-41` constrains two third-party assets: `bigworldmapSecond.png` (publisher-copyrighted, supply locally, do not commit) and `pointer_model.onnx` + the nteguide marker DB (not redistributed).

## 11.6 Verification scripts

`src/verify_heads.py` (699) and `src/verify_lane_usage.py` (613) exist to verify head behaviour and lane-mask usage instead of trusting training logs; `tools/v3_contract_test.py` is the contract-level test for the 11-column format. `UNVERIFIED:` internals and current pass counts were **not** executed or read this session — named as the verification surface, not asserted as passing.

## 11.7 `config.py` is training-sim, not vehicle runtime

`src/config.py` (283) is a **traffic/world simulation** config, easily mistaken for vehicle parameters. Read: `ROOT_DIR` from `__file__` (`:12`), `DATA_DIR`/`MODELS_DIR`/`SRC_DIR`/`CONFIGS_DIR` (`:15-18`), `AURORA_MAP_DIR` override (`:25`), `MAP_FILE = fujian_map.bin` with `MAP_MAX_SIZE = 700 MB` (`:35-36`), `ROAD_TYPES` (`:39`), `WORLD_LOAD_RADIUS = 500.0 m` / `WORLD_UNLOAD_RADIUS = 800.0 m` (`:49-50`), `EGO_VEHICLE` (`:54`), `VEHICLE_TYPES` (`:66`), `TRAFFIC_MAX_VEHICLES = 150` (`:110`), `TRAFFIC_UPDATE_HZ = 10` (`:111`), spawn/despawn `200–300 m` / `200 m` (`:112-114`), `TRAFFIC_DENSITY` (`:117`), `IDM_PARAMS` (`:124`), `MOBIL_PARAMS` (`:134`), `SCENARIO_PROBS` (`:141`), `INTERSECTION_RULES` (`:152`), `CAMERA_COUNT = 10` (`:172`). `UNVERIFIED:` whether it participates in V3 training or only the simulation track — import graph not traced.

## 11.8 Pitfalls

1. **Wrong class name**: `V3KeyDataset`, not `V3ClipDataset` (`dataset_v3.py:257`) — fails at import.
2. **Wrong FPS is fatal**: `expected_fps` mismatch raises and rejects the whole clip (`:442-448`); the recorder's 15 Hz gate exists for this (SEC-05 §5.8).
3. **Empty `speed_kmh` is meaningful**: empty ⇒ `speed_valid=0`; `0` would be a true zero speed (`LeanRecordEngine.swift:489-491`).
4. **`skip_all_zero` can empty the dataset** and raises rather than returning zero samples (`:400`).
5. **Derived brake heads are validated against atomic keys** — corruption surfaces as `ValueError` with all three values (`:183-195`).
6. **CCM silently does nothing unless enabled** (`train_v3.py:21-29`).
7. **Overall accuracy is a trap**: constant-W scores 80.8 % (`train_v3.py:30-33`) — select on macro recall.
8. **`lane`/`dets` are zero-filled** so those branches cannot learn from current recordings (`dataset_v3.py:275-277`) — a stated open item.
9. **CoreML feature names ≠ Python parameter names**, and `state` is renamed (`InferenceEngineV2.swift:32-42`).
10. **Export script wins over model source** for the on-disk contract (`InferenceEngineV2.swift:14-17`).
11. **`config.py` is simulation config** — do not quote its numbers as deployed behaviour.

---

# SEC-12 — LOCATE / MAP / CONTROL INJECTION / KEY SEMANTICS / SAFETY

Sources: `Capture/CoordinateCapture.swift` (1811), `Locate/NetworkLocator.swift` (668), `Locate/VisualLocator.swift` (491), `Control/ControlEngine.swift` (718), `Control/KeyboardMonitor.swift` (231), `Control/MouseController.swift` (219), `Control/EscapeController.swift` (44), `Core/GameModeDefender.swift` (217), `Core/BPFSetup.swift` (134), `Core/PrioritySetup.swift` (74), `Core/PrivilegePill.swift` (472), `Perception/*` (620).

## 12.1 Network locate — ported code with a licence obligation

`CoordinateCapture.swift:4-18` is a provenance block that must not be removed: the file is **ported wholesale from upstream MaaNTE's `nte_coordinate_api.py` (AGPL-3.0)**. Both reasons are hard: **AGPL-3.0's attribution obligation** — removing the provenance is a licence violation (`:11-13`); and the port-30031 filter plus the `kCalibA/B/TX/TY` constants are "upstream-measured + our re-measurement" conclusions that cannot be re-verified once the provenance is gone (`:13-16`). Same brand rule as elsewhere: provenance in comments; upstream name never in brand-visible strings (SEC-07 §7.7.7).

Mechanism: libpcap capture → UE5 movement-packet parse → world coordinate + heading (`CoordinateCapture.swift:19-20`). C bindings are `@_silgen_name`: `pcap_open_live` (`:37-38`), `pcap_compile` (`:40-41`), `pcap_setfilter`; `libpcap` linked via `Package.swift:207` (`.linkedLibrary("pcap")`), with the dyld-cache detection caveat (SEC-02 §2.1.2).

Filter `tcp port 30031 or udp` (`:12`). `README.md:47` pins the call to `CoordinateCapture.swift:1052` and the filter to `:1100`; **`UNVERIFIED:`** those two lines were not re-read — port/filter text and the `pcap_open_live` symbol are confirmed, the line numbers are README claims.

Calibration constants (`:112-115`) — the transform between UE5 world centimetres and map pixels:
```
kCalibA  = 0.016394586684750773
kCalibB  = 5.693519256055879e-08
kCalibTX = 6526.474380746091
kCalibTY  = 5210.664390686138
```
Base map: `map-2026-08`, MaaNTE-Map **13056×13056** expanded edition, upgraded 2026-09-13 (`:106`). `MapWiring.swift:8-12` consumes exactly this chain and notes the inverse is a **different matrix** with opposite B sign (`MapWiring.swift:52-78`, SEC-10 §10.6).

## 12.2 A refuted hypothesis still worth reading

`CoordinateCapture.swift:301` records that on **2026-09-25** the project concluded the 30031 S2C 76-byte packet was protobuf; that conclusion is now marked **被推翻**. The replacement explanation sits around `:301-320`, which also notes a `port 30031` filter had been keeping UDP 30212 entirely outside the capture window (`:315`). Why it matters: narrowing to the wrong predicate silently discards the packets that carry position, and the symptom is "locating works sometimes".

## 12.3 Traffic is bursty — probing takes many rounds

`CoordinateCapture.swift:704` — measured with `tcpdump` over a 30 s sample while the game ran: port 30031 traffic is **bursty**, not steady. `lsof` shows `30031 ESTABLISHED` and `tcpdump -i en8 port 30031` captures, yet a 3-second window can find nothing (`:718-722`). The project measured **23 consecutive probe rounds at 14:15–14:16 all reporting "均无 30031 流量"** (`:753`), so a short probe cannot distinguish "wrong NIC" from "quiet moment". Consequence: a failed capture path leaves the whole column blank — why the recorder dropped position columns (SEC-05 §5.3) and why BPF permissions are installed up-front (`Core/BPFSetup.swift`, `:90-99` documents the retired native-auth path).

## 12.4 Locate freshness — four tiers, and why 18 s

`CoordinateCapture.swift:1738` defines `enum PoseTier` (cases `:1739-1742`):
```
case live      // ≤ liveWindow (default 18s)  : full function
case recent    // ≤ recentWindow (default 40s ≈ 2–3 periods) : UI normal, decision down-weighted
case stale     // ≤ staleWindow (default 90s) : UI marks "stale", decisions do not trust it
case lost      // > staleWindow : UI marks "no locate"
```
Thresholds: `poseFreshWindow = 18.0` (`:848`), `poseRecentWindow = 40.0` (`:1747`, ≈2.6 × 15 s periods), `poseStaleWindow = 90.0` (≈6 periods). `.live` is **exactly** the pre-existing `poseFreshWindow`, so old behaviour is preserved verbatim while two wider tiers are added (`:1747-1748`).

Why 18 s and not 12 s (`:818`, `:842-846`): the game's **real coordinate period is 15 s** (2026-09-30 final measurement), so a 12 s window expired every cycle and produced **location flicker**; 18 s = 15 s + 3 s margin, negligible perception impact. The tier system removed the flicker without "ghost positions": `stale`/`lost` are down-weighted, `lost` is labelled "no locate", and the `hasRecentTraffic` pre-gate remains (`:1735-1738`).

API: `readWithTier(live:recent:stale:) -> (tier, pose?, ageSeconds?)` (`:1753`), lock-protected, returning `.lost` with nil pose only when no sample has ever existed.

## 12.5 Two dead classes — verified zero instantiation

```
grep -rn "NetworkLocator(" Sources/ | grep -v 'class |//'   → 0 hits
grep -rn "VisualLocator("  Sources/ | grep -v 'class |//'   → 0 hits
```
`Locate/NetworkLocator.swift` (668) and `Locate/VisualLocator.swift` (491) **compile but are never instantiated**; `LocateRuntime.swift:30-31` holds fields never assigned. `README.md:62`: the self-healing engine `NetworkHealer` was retired with commit `76e9027`, and "8 kinds of diagnostics + auto-repair" has **no implementation** in source, so the README deleted the line rather than keep an unverifiable claim. Shipped behaviour = network locate + the four-tier model (`README.md:64`). Operational consequence: do not "wire up" `NetworkLocator` thinking it is missing — it was deliberately superseded, and `VisualLocator`'s `CoordinateTransform.invert` is **not** interchangeable with the map inverse (SEC-10 §10.6).

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
`Action` enum (`:34-40`): `throttle`, `brake`, `steerLeft`, `steerRight`, `handbrake` (+ boost mapping). Semantics (user-confirmed, recorded at `KeyboardMonitor.swift:111-112`, encoded in `dataset_v3`):

| gesture | meaning |
|---|---|
| Shift | **handbrake** |
| Space | normal brake |
| Shift+Space (short press) | super brake |
| Shift+Space (long press) | ultimate brake |
| S alone | reverse |
| S during ultimate braking | anti-rollover |

This is why training targets are Boolean functions of atomic keys (`dataset_v3.py:15-18`, SEC-11 §11.2): `handbrake=shift`, `brake=space`, `super_brake=shift∧space`, `ultimate=shift∧space∧s`. **The dangerous overlap**: in this game `brake` **is the S key, which is also reverse** — the cause of a real incident where the ego-box fallback output `brake 0.8` and the car kept braking *and* reversing (SEC-08 §8.10, `EgoBoxFilter.swift:12-17`).

## 12.7 Injection layer — three independent constraints

`ControlEngine.swift:183-198`: source must be `.hidSystemState`, tap `.cghidEventTap`; the game reads only the HID system state layer, `.combinedSessionState` is ignored even though system UI reacts, `.privateState` is banned. `ControlEngine.swift:504-507`: `autorepeat` must stay `false`. `MouseController.swift:10-19`: same strategy (`CGEventSource(stateID: .hidSystemState)` + `.cghidEventTap`), with a coordinate warning from a near-miss — CGEvent mouse coordinates are **global display points**, origin at the **main display's top-left**, y downward, same orientation as screenshot pixels, differing only by `backingScaleFactor` (2× on Retina); `NSScreen.frame` uses **bottom-left AppKit coordinates** and the two must not be mixed; conversion `CGEvent point = screenshot pixel / backingScaleFactor` (main display case).

Bookkeeping (`:361-390`): `press` posts down then up; `hold` is idempotent via `guard !heldKeys.contains(keyCode)`; `release` posts up only if present; every entry point guards `hasAccessibilityPermission` (`:357`, `:371`). `releaseAll()` (`:436-443`) unconditionally posts key-up for **all six mapped keys** and clears the set — deliberately not conditional, because it also clears **system-level stuck keys left by a previously crashed process** (`:468-471`). `releaseAllIfNeeded()` (`:486-496`) skips redundant sweeps when nothing is held and a sweep ran within the last second, without changing `releaseAll` semantics (SEC-07 §7.4.6).

## 12.8 Control output type — the only survivor of the escape tier

`EscapeController.swift:8-14`: the file now holds **only** the public `ControlCommand` type — `steer[-1,1] + throttle[0,1] + brake[0,1] + confidence[0,1]` — the unified output of the two remaining decision sources (`E2E`/`Rule`), which `DriveState` maps to `ControlEngine` injection (`:9-10`). `EscapeController` itself was deleted 2026-09-30 at the user's request: the escape tier compressed speed and could not exit, so autodrive survived only ≈**12 s** before the escape loop interrupted it (`:11-13`); its timeout protection went with it. `RuleController.swift:157` and `:164`: **steer only, throttle only, never brake automatically**; emergency avoidance = no throttle + full opposite steer, `b` always 0, never reverses on its own.

## 12.9 Game Mode suppression — measured, countered twice

`GameModeDefender.swift:4-18`: measured 2026-09-13 — after the game enters full-screen Game Mode, AuroraDrive's auxiliary frame rate holds ~30 fps for about **40 s**, then `gamepolicyd` suppresses it to single digits; a one-off setup at launch (nice value, activity assertion) is **not enough**. Two measures: ① **silent audio (the `audible` dimension)** (`:8-15`) — App Nap treats "isn't audible" as a criterion and audio playback is an independent exemption; the CoreAudio thread runs at **realtime priority without root**, bypassing the "realtime threads need root" blocker; implemented as an `AudioQueue` loop emitting zero samples, needing no `NSApplication`, so the **engine process can use it too**. ② **persistent re-assertion** (`:16-18`) — re-claim every 3 s, not once. Engagement `GameModeDefender.shared.start()` at `EngineMain.swift:1157-1159` (the engine does detection, so it needs both most). Related: `beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])` + `setpriority(PRIO_PROCESS, 0, -20)` (`EngineMain.swift:1161-1168`, SEC-03 §3.6).

## 12.10 Privilege escalation — in-app only, one action only

`PrivilegePill.swift:1-28`: never macOS native authorisation dialogs (`do shell script ... with administrator privileges`) — repeated prompts get the app flagged as suspicious, harming an open-source project (`:9-13`); instead an in-app glass dialog takes the password and escalates via `sudo -S`, password on **stdin** because argv is visible to `ps` (the old implementation put it in an AppleScript string = plaintext in process arguments, `:20-23`). Never hardcoded (the old `"123456"` "发布版必然失效且是安全隐患", `:18-19`), memory-only, cleared after use, never on disk or logs, escalation strictly limited to installing one LaunchDaemon script (`:24-28`). Both legacy native-auth entry points are `@available(*, deprecated)` and **return failure immediately**: `BPFSetup.swift:96-99`, `PrioritySetup.swift:53-58`. `AuroraFlags.swift:146-151`: the LLM API key is likewise "绝不打印、绝不落盘"; the GUI stores user keys in a local mode-0600 notebook (`AgentSettings.swift:14-17`).

## 12.11 Safety invariants — consolidated

1. **Every exit path releases all keys before exiting**; SIGKILL is a last resort precisely because it loses that guarantee. `EngineMain.swift:20`, `:2377-2394`; `EngineClient.swift:1058-1062`.
2. **Observe-only (`AURORA_OBSERVE_ONLY=1`) refuses all injection** at three independent layers: engine TCC predicate narrowed to screen-only (`EngineMain.swift:1132-1138`), UI `controlDisabled=true` (`AuroraDriveApp.swift:6886-6896`), `ToolRegistry` guard ① (`ToolRegistry.swift:26-27`, `:405`). Even if injection were attempted, `ControlEngine.hold()`'s permission guard returns early (`EngineMain.swift:1136-1138`).
3. **No injection without Accessibility permission**, and the permission query must never prompt on the hot path (`ControlEngine.swift:210-232`, SEC-07 §7.4.5).
4. **Handover / engine restart is refused while driving** — losing the engine mid-drive is more dangerous than a protocol mismatch (`EngineClient.swift:344`; SEC-03 §3.9).
5. **Recorded keys must be released, not inferred**: the engine has no `NSEvent`, so it uses the UI-forwarded `remoteKeyMask` (`EngineMain.swift:1235-1237`).
6. **Stuck detection is independent of the model** — not moving triggers intervention even if the model is confident (`DegradeStateMachine.swift:12-13`).
7. **Fallbacks are fail-open and bounded**: never guess a direction, never full throttle, require N-frame confirmation, discard sudden jumps (`LaneFallback.swift:10-18`; `FallbackGuard.swift:26-31`; `MotionPredictor.swift:29-33`; `LaneBridge.swift:168-176`).
8. **Rule tier never brakes automatically and never reverses on its own** (`RuleController.swift:157`, `:164`).
9. **Recording must never be corrupted silently**: CSV row ⇄ image pairing, no `speed_kmh=0`, no name-collision reuse, stop with an explicit reason on frame-rate breach (SEC-05 §5.4, §5.8–5.9).
10. **Permissions are inherited through the process chain**, and the TCC self-check fails fast at startup (`EngineMain.swift:107-1155`, exit code 2).
11. **Never click anything labelled login globally** (`AIAgentPanel.swift:703`); never press F1–F12 because the game cannot receive macOS system function keys (`AIAgentPanel.swift:305`).
12. **No synthetic network traffic, no proxy pools, no CAPTCHA evasion**; search tools fail honestly (`WebSearch.swift:31-36`, SEC-07 §7.7.5).

## 12.12 Cross-process role switching

Two values change meaning by process, both verified: `speedKmh` — `AuroraDriveApp.swift:5592` `EngineClient.shared.isActive ? remoteSpeedKmh : speedOCR.speedKmh`; `detections` — `:4304` `EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections`. So a UI-side reading reflects the **engine's** answer whenever an engine is attached. Any report of "the UI shows a different speed than the log" must first establish which process produced each number.

## 12.13 Open items

1. Real-gameplay validation of locating + control end to end was never exercised; `recordings/` is 0 B and `data/raw_clips` and `clips` were empty at last check.
2. NIC auto-selection under bursty 30031 traffic needs many rounds; a fast probe is insufficient (`CoordinateCapture.swift:704-753`).
3. `NetworkLocator` / `VisualLocator` remain compiled dead code with zero instantiation — deliberate, but any re-enable must first reconcile `CoordinateTransform` with the map inverse.
4. The 30031 packet-format conclusion was refuted once (`:301`); treat the current explanation as measured but re-checkable.
5. `brake` == `S` == reverse remains an inherent hazard of this key layout; any component emitting `brake` must be reviewed for whether it wants to reverse (the ego-box incident is the precedent).

---
