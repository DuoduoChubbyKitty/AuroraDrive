# SEC-02 — BUILD / SIGN / DEPLOY / BUILD-LOCK

Read from `run.sh` (182 lines, all lines), `Package.swift` (211 lines), `scripts/build-lock.sh`
(146 lines), `scripts/check-package-sources.sh` (229 lines, first 80). Every line number is real.

## 2.1 `run.sh` — the only supported build+deploy entry

Header advertises three modes (`run.sh:2-5`): no arg = build+sign+launch GUI; `--status` = check only;
`--yolo-selftest <image>`. Actual dispatch has one more: `--yolo-bench`, and `--auto-login`
(`run.sh:159-178`). `set -e` at `run.sh:6`.

### 2.1.1 Path constants

```
ROOT     = dirname($0) resolved absolute          run.sh:8
BIN_SRC  = .build/scratch/release/AuroraDrive     run.sh:11
BIN_DST  = AuroraDriveUI                          run.sh:12
BUNDLE   = $ROOT/AuroraDriveUI.app                run.sh:109
```
Target product is `AuroraDrive`; the **deployed** name is `AuroraDriveUI`. The rename is a `cp` to a
different filename, nothing in `Package.swift` knows about `AuroraDriveUI`.

### 2.1.2 Step [1/4] environment check — libpcap detection (a documented past bug)

`run.sh:26-39`. Two former predicates are recorded as **always-false since macOS 11**, so they were
necessarily false-negatives:
1. `ls /usr/lib/libpcap*` — all system libraries moved into the dyld shared cache, no on-disk files
   remain; the comment states this machine's `/usr/lib` has "仅剩 32 个条目".
2. `brew list libpcap` — libpcap ships with macOS and is never installed via brew.

Current predicate (`run.sh:32-39`) is a 3-way `||`:
- `[ -f "$BIN_SRC" ] && dyld_info -linked_dylibs "$BIN_SRC" | grep -q libpcap` — only possible after a
  prior build produced a binary;
- `dyld_info -exports /usr/lib/libpcap.A.dylib` — succeeds via dyld shared cache even without a file;
- `ls /usr/lib/libpcap*` — last-resort fallback.
The `[ -f "$BIN_SRC" ] &&` guard is explicitly there because predicate ① needs a build product that
does not exist on a clean tree, so ② is the fallback (`run.sh:31`).
Failure text names the consumer and a dead implementation: `CoordinateCapture.swift` needs it;
`legacy/NetworkPacketCapture.swift` is the deprecated one (`run.sh:37`).

### 2.1.3 Step [2/4] model presence check

`run.sh:41-64`. Two groups:
- Legacy trio `m9_mono`, `game_assist_control`, `yolo26s` (`run.sh:47`), each accepting either
  `models/<m>.mlmodelc` (✓) or `models/<m>.mlpackage` (✓ "未编译,回退加载") or ✗ missing
  (`run.sh:48-54`).
- `yolopx` special-cased (`run.sh:56-64`): preferred artifact is
  `models/yolopx/yolopx3_pal8_detfp.mlmodelc`; if the dir exists but the preferred name does not, the
  script prints "⚠ 非首选，回退候选:" and lists the whole dir; else ✗ with the note that it is the
  driveable-area / lane / detection three-in-one head and a "★核心资产".
  Comment at `run.sh:42-44` says the original check covered only the trio and **missed yolopx**, which
  is the current core perception asset and a "一个字节都不能换" red-line model.
- `--status` exits here (`run.sh:67-71`) so environment check never triggers a build.

### 2.1.4 Step [3/4] build

`run.sh:73-93`.
1. `rm -rf .build` at `run.sh:77`, with comment "必须先清缓存! SwiftPM 缓存会导致代码改动不生效."
   This makes every `run.sh` a from-scratch build (no incremental reuse of the normal `.build`).
2. `swift build -c release --disable-sandbox --scratch-path .build/scratch > .last-build.log 2>&1`
   (`run.sh:85`).

Three documented fixes are attached to this one line:
- `run.sh:78-80`: old form was `swift build | tail -5`; the pipeline swallowed the exit code, so
  `set -e` never fired and a **failed build still deployed and launched**. Incident named:
  2026-09-15 `bagel_spam` compile failure was mis-deployed. Now the full log goes to
  `.last-build.log`, `BUILD_RC=$?` is captured (`run.sh:86`), last 5 lines printed, and on
  `BUILD_RC -ne 0 || [ ! -f "$BIN_SRC" ]` it greps `-m 8 "error:"` and `exit 1` (`run.sh:88-92`).
- `run.sh:81-83`: under a sandboxed environment (named "DSH workspace-write"), SwiftPM's own
  `sandbox_apply` fails with `Operation not permitted` and manifest compilation dies; hence
  `--disable-sandbox`. Behaviour outside sandboxes is unchanged.
- `--scratch-path .build/scratch` unifies the scratch dir with incremental dev builds
  (`run.sh:83-84`), which is why `BIN_SRC` is `.build/scratch/release/AuroraDrive` rather than
  `.build/release/AuroraDrive`.

Note the guard is `BUILD_RC -ne 0 || binary-missing`, i.e. a zero exit code with a missing product
also aborts — that is the belt-and-braces half of the 2026-09-15 fix.

### 2.1.5 Step [4/4] sign + deploy — the SIGKILL / Code-Signature-Invalid incident

`run.sh:95-106`. Comment at `run.sh:96-101` documents the root cause chain:
macOS pages process text **on demand**, so a running instance keeps reading pages from disk. The old
deploy did `cp` **in place over the same inode**; the kernel then read a mix of old and new pages,
CDHash verification failed, and the kernel killed the process (reported as Taskgated Invalid
Signature, seen in 9/10 DiagnosticReports).

Current sequence:
```
codesign --force --deep --sign - "$BIN_SRC"                     run.sh:104   (ad-hoc "-")
cp "$BIN_SRC" "$BIN_DST.tmp.$$" && mv -f ... "$BIN_DST"         run.sh:105   (temp name + mv = new inode)
xattr -d com.apple.quarantine "$BIN_DST"                        run.sh:106
```
`mv` over the path gives the new instance a fresh inode while the old instance keeps the old one alive
(post-unlink vnode survival) — both sides unaffected (`run.sh:100-101`).
Both `codesign` and `xattr` are `|| true` (`run.sh:104`, `:106`), i.e. ad-hoc signing failure does
**not** abort the deploy.

`.app` bundle build (`run.sh:108-145`):
- `mkdir -p "$BUNDLE_DIR/Contents/MacOS"` (`:110`).
- Binary copied with the same temp+mv trick to `Contents/MacOS/AuroraDriveUI` (`:111`).
- Metal shader precompile (`:112-130`): `xcrun -sdk macosx metal -c Vendor/MetalGoose/Engine/Shaders.metal
  -fmodules-cache-path="$ROOT/.build/metal-cache" -o /tmp/Shaders.air` then `metallib` →
  `Contents/Resources/default.metallib`, then copied to `$ROOT/default.metallib`.
  Rationale (`:112-116`): `setupPipelines` prefers the precompiled library (bundle Resources → next to
  the bare executable → source-compile fallback); placing it in **two** locations is required because a
  bare-executable launch has a meaningless `Bundle.main`. Failure is non-blocking — it removes
  `/tmp/Shaders.air` and the partial metallib and prints "✗ 预编译失败 (回退运行时编译)" (`:127-130`).
  The `-fmodules-cache-path` redirect (`:118-120`) exists because metal's clang ModuleCache defaults to
  `/var/folders/` which a restricted env rejects with `Operation not permitted`, silently killing the
  precompile. **This also explains why `default.metallib` shows as `M` (modified) in `git status`:
  every `run.sh` rewrites the tracked file.**
- `Info.plist` written from a printf heredoc (`:131-143`): `CFBundleExecutable=AuroraDriveUI`,
  `NSPrincipalClass=NSApplication`, `CFBundleIdentifier=com.aurora.driveui`,
  `CFBundleName=AuroraDrive`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=1.0`,
  `CFBundleVersion=1`, `LSMinimumSystemVersion=14.0`.
  Two inconsistencies (recorded as facts, no judgement added): `LSMinimumSystemVersion` is
  `14.0` while `Package.swift:51` declares `.macOS(.v26)`; and the plist is regenerated on every run,
  so it is not a source of truth for versioning.
- Re-sign the whole bundle ad-hoc (`:144`), de-quarantine (`:145`).
- `pkill -f "AuroraDriveUI"` (`:148`) — kills by **command-line substring**, which also matches the
  bare binary and any path containing that string. `|| true` so a no-op kill is fine.

### 2.1.6 Launch

`run.sh:158-182`. Non-selftest path prefers the bundle because LaunchServices gives a clean parent
process (`:167`):
- `--auto-login` → `open "$BUNDLE_DIR" --args --auto-login` (`:172`). Documented behaviour: enters the
  login watchdog immediately, checks every 8 s and clicks until login succeeds or 80 s elapses; exits
  quietly if the game is already logged in or not running (`:168-170`).
- default → plain `open "$BUNDLE_DIR"` (`:175`), auto-login **not** enabled (`:176`).
- Failure triage printed to the user (`:179-181`): Screen Recording permission, Accessibility
  permission, or run the bare binary `./AuroraDriveUI` directly.

`--yolo-selftest` / `--yolo-bench` bypass the GUI launch and exec `./$BIN_DST --yolo-selftest <arg>` /
`--yolo-bench <arg>` (`:159-164`). Both require a second positional arg; a missing arg silently falls
through to the normal launch branch (the `&& [ -n "$2" ]` guard fails, so the `else` at `:165` runs).
That is a real behavioural edge: `./run.sh --yolo-selftest` with no path **builds, deploys, and
launches the GUI** instead of erroring.

## 2.2 Manual build commands (used in this project's workflow)

Equivalent to what `run.sh` does, minus deploy:
```sh
swift build -c release --disable-sandbox --scratch-path .build/scratch
swift build 2>&1 | tail -30          # incremental debug-style check
./AuroraDriveUI --lean-selftest      # after deploy
```
The `--disable-sandbox` flag is needed only in sandboxed harnesses; it is harmless outside
(`run.sh:81-83`). `rm -rf .build` is **not** required for a correctness build, only for the
"cache made my change invisible" class of failure (`run.sh:76`).

## 2.3 Build serialization — `scripts/build-lock.sh`

Reason it exists (`build-lock.sh:6-17`): SwiftPM is whole-module; concurrent edits + concurrent
`swift build` produce `error: input file '.../AuroraTheme.swift' was modified during the build`, and
one broken file blocks **everyone** because compilation is per-module. Called an "infrastructure
defect", not an individual mistake. Second, less obvious reason: concurrent benchmarking. Measured
claim at `:15-17` — 3 agents running `--mc-map-bench --iters 200` simultaneously at ~85% CPU each
drove loadavg to 5.15 on 8 cores, at which point any timing number is incomparable; therefore
**long tasks (selftests / benches / gate collection) must also hold the lock**, not just builds.

Interface (`build-lock.sh:19-23`, dispatch at `:140-146`):
```
bash scripts/build-lock.sh acquire "阶段A验收"   # exit 3 if not acquired
bash scripts/build-lock.sh release
bash scripts/build-lock.sh status
bash scripts/build-lock.sh run "原因" -- <cmd...>
```
Env knobs: `AURORA_BUILD_LOCK` (default `${TMPDIR:-/tmp}/aurora-build.lock`, `:37`),
`AURORA_BUILD_LOCK_STALE_MIN` (default 15, `:38`), `AURORA_LOCK_OWNER_PID` (owner pid override,
`:65`, `:102`).

Design decisions with their stated reasons (`:29-33`):
- `mkdir` is the atomic primitive because macOS `bash` 3.2 has **no `flock` command** (`:30`).
- Lock dir carries an `owner` file with `pid`, `time`, `host`, `user`, `reason`, `cwd`
  (written `:64-71`; fields read by `_owner_field` at `:48-51`).
- Stale locks are **reported, never auto-deleted**, twice: age ≥ STALE_MIN prints a staleness verdict
  but says "但**不自动删**（万一真的还在跑）" (`:91-94`); and if the recorded pid is gone it prints
  `rm -rf` instructions rather than executing them (`:87-90`).
- `release` refuses to remove a lock owned by a different pid (`:102-106`, returns 1).
- `run` acquires, executes `"$@"`, releases, returns the command's rc (`:129-138`) — note it releases
  via plain sequential call, not a `trap`, so a `set -e` abort inside the wrapped command would skip
  the release. The recommended in-script pattern uses `trap 'bash scripts/build-lock.sh release' EXIT`
  (`:26-27`). `UNVERIFIED:` whether a wrapped-command crash in practice leaves stale locks — not
  reproduced this session.

Lock usability caveat: because `age` is computed from the lock dir's birth time via
`stat -f %B` (`:57`), and `mkdir` timestamps are not preserved across copies, a copied/restored lock
dir could read as fresh. `UNVERIFIED:` not tested.

## 2.4 Manifest/disk consistency gate — `scripts/check-package-sources.sh`

229 lines; the Python body is embedded in a bash heredoc (`check-package-sources.sh:29`), and the
reason is explicit at `:27`: this machine's `/bin/bash` is 3.2, which has **no associative arrays**
(`declare -A`), so the logic is written in `python3` instead.

Documented failure classes it guards (`:6-19`):
- orphan `.swift` under `Sources/` belonging to no target;
- non-`.swift` files inside `Sources/AuroraDrive/` (become unhandled warnings);
- new top-level dir/file not added to `exclude` (becomes an unhandled warning **and** makes SwiftPM
  walk the whole repo root on every build, slowing each build).
History stated: `sources:` was a per-file manual whitelist until 2026-10-04 (P5-A7), which caused
`cannot find 'Xxx' in scope` at compile time whenever a file was added or removed without updating the
list. Now directory-level, so the remaining risks are the three above.

Usage (`:21-23`): `bash scripts/check-package-sources.sh` → exit 0 consistent / 1 divergent;
`--gen-exclude` prints a regenerated `exclude` block.

Mechanics (read to `:80`): `set -uo pipefail` (`:24`, note: no `-e`), `ROOT` resolved from `$0`
(`:25-26`), then per-target parsing of `Package.swift` — a `match_bracket(...)` helper walks brackets
to find the closing token (`:39-51`), `.target(`/`.executableTarget(` declarations are iterated with
`re.finditer(r'\.(?:executable)?[Tt]arget\(', src)` (`:56`), and each target block is extracted by
paren-depth matching (`:58-67`); `name`, `path`, `sources`, `exclude` are then pulled out
(`:68-79`). `UNVERIFIED:` the checks after line 80 were not read this session; the exit-code semantics
above come from the file's own usage comment.

## 2.5 Other scripts (inventory for later sections)

`scripts/` holds 8 entries, 1,602 total lines of shell:
`build-lock.sh` 146, `check-package-sources.sh` 229, `gpu-attrib.sh` 133, `paired-ab.sh` 413,
`perf-snapshot.sh` 334, `regression-gate.sh` 270, `setup_toolchain.sh` 77, `README.md` 263.

`README.md` (263 lines) is the scripts index; `UNVERIFIED:` its content was not read this session.
Only two of these are wired into other artifacts read so far: `check-package-sources.sh`
(`Package.swift:92`) and `build-lock.sh`. `paired-ab.sh`, `perf-snapshot.sh`, `regression-gate.sh`
belong to the performance/verification workflow and are pinned in the perf section.

## 2.6 Build-failure triage table (all causes are documented in-source)

| symptom | real cause | source |
|---|---|---|
| `cannot find 'X' in scope` after adding a file | `sources:` was per-file whitelist (pre-2026-10-04); now directory-level, so re-check you added the file under a whitelisted dir | `Package.swift:81-88`, `check-package-sources.sh:11-13` |
| `found N file(s) which are unhandled` | new top-level dir/file missing from `exclude` | `Package.swift:88-92`, `check-package-sources.sh:17-19` |
| 500+ errors, all `static let shared` / "main actor-isolated default value" | `.swiftLanguageMode(.v5)` block was lost (Swift 6 strict concurrency became the default) | `Package.swift:193-203` |
| manifest fails to compile, `Operation not permitted` | SwiftPM's own `sandbox_apply` in a restricted env | `run.sh:81-83` |
| `library not found` at link | relative `-L` path for OpenCV | `Package.swift:16-17` |
| undefined `carotene_o4t::*` | `tegra_hal`/`kleidicv*`/`ittnotify`/`zlib` not linked | `Package.swift:31-33`, `:41-46` |
| undefined `_cblas_sgemm$NEWLAPACK$ILP64` | `Accelerate` framework not linked | `Package.swift:32`, `:70` |
| `input file '...' was modified during the build` | concurrent edits/builds, no build lock | `build-lock.sh:7-11` |
| build "succeeded" but code change invisible | SwiftPM cache; `run.sh` deletes `.build` first | `run.sh:76-77` |
| old behaviour still runs after `run.sh` | deployed binary is `AuroraDriveUI`, not `.build/.../AuroraDrive`; `pkill -f AuroraDriveUI` then `open` bundle | `run.sh:11-12`, `:105`, `:148`, `:175` |
| GUI won't open | Screen Recording / Accessibility permission | `run.sh:179-181` |
| `Taskgated Invalid Signature` / process SIGKILLed at deploy | in-place `cp` over the inode of a running binary | `run.sh:96-101` |
