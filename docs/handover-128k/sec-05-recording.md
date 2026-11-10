# SEC-05 — RECORDING: LeanRecordEngine / CSV CONTRACT / LeanAnnotator / LEGACY RecordEngine

Primary sources read in this session: `Sources/AuroraDrive/Capture/LeanRecordEngine.swift`
(852 lines; header 1-130, `start/stop` 234-295, `appendFrame` 302-343+, `writeFrame`/
`appendCSVRow` 400-529, `noteCadenceForContract` 555-598, `makeSessionDir`/`openSession`/
`closeSessionLocked` 602-723), `Capture/CaptureEngine.swift:1168-1176`.
`RecordEngine.swift` (771 lines) and `LeanAnnotator.swift` (597) are pinned by symbol/size only where
stated; anything not read is marked `UNVERIFIED:`.

## 5.1 Why a second recorder exists

Header `LeanRecordEngine.swift:4-49`. The existing `RecordEngine` "expert mode" was too heavy in the UI
process: per frame it read the keyboard, generated continuous-value labels, scaled to 640×360, and
competed with OCR / glyph / interpolation work for the main thread — in practice it slowed capture.
The user's 2026-11-03 decision (verbatim at `:9-10`) was to build a **very thin** recorder that runs
**no models at all** during recording and pushes all heavy work to offline annotation after the clip
ends.

## 5.2 What the lean recorder does — exactly two things

`:12-14`:
1. Encode the **full-resolution** frame handed over by the capture layer into JPEG and write it to disk.
2. Record a timestamp and a **key snapshot** at 15 Hz — the keys *are* the V3 training labels.

## 5.3 What it deliberately does NOT record — and why (position was removed)

`:16-26` records the reversal in the author's own words. Initially this recorder also parsed
position/heading/acceleration out of libpcap and wrote **19 columns**. The user rejected it outright
(quoted verbatim in-source, colloquial). The three reasons that were accepted as valid (`:19-25`):
- V3 learns **screen → keys**. Position is neither a model input nor a supervision signal;
  `dataset_v3`'s `REQUIRED_COLUMNS` requires only `t_sec/frame` plus 8 keys and reads **not one** of
  `x/y/z/pitch/heading/accel`.
- Position is map information for humans — a **display-layer** concern, unrelated to training data.
- Capture required locking a NIC and asking for permissions, and when it failed the columns were simply
  left blank; introducing a failure-prone, warning-emitting, maintenance-carrying external dependency
  for a column the training side never reads is a net burden.
⟹ whole column set deleted; CSV went **19 → 11 columns**; the `poseProvider` wiring was removed with it.

Also explicitly **not** recorded, because all of it is offline work (`:28-32`):
- Speed OCR — the full-screen original frame already contains the speedometer, so the `speedROINorm`
  region is cropped offline and recognised there. Therefore no separate "speedometer strip" is stored
  (the user explicitly rejected that design).
- Supersampling to 384×224 — done offline; recording keeps the original image so the input size can be
  changed and retrained.
- Coordinate tables / world model / any perception model.

## 5.4 The one hard data invariant: CSV row index ⇄ frame filename

`LeanRecordEngine.swift:34-40` states the invariant and the exact upstream reading that forces it:
`dataset_v3._build_index` computes `n_frames = len(rows)` and resolves each image as
`frames/{j:06d}.jpg` where `j` is the CSV **row order**. Therefore **CSV row j must correspond to
`frames/0000jj.jpg`**.

Failure mode if violated (`:38-40`): if frame numbers were pre-assigned on the main thread and one JPEG
encode failed and was dropped, every subsequent frame number shifts by one — the entire batch's labels
no longer match its images, **and nothing reports an error**.

Therefore: frame numbers advance only after a successful disk write; a failed write retries/drops the
frame and writes **no CSV row** (`:40`).

This invariant is defended by five separate mechanisms (all read):

1. **Number allocated in the write queue, not on the main thread** (thread model at `:42-48`:
   `start()`/`stop()` on main; `appendFrame` on captureQueue; JPEG encode + disk write + CSV append on
   the serial `writeQueue`).
2. **Generation check before taking `framesDir`/`nextFrameIndex`** (`writeFrame` at `:406-424`). A frame
   captured in an old session, if the session rotated (auto-segment = stop→start) in between, would
   otherwise be written into the new segment's directory at index 0 — a silent mismatch (`:408-411`).
3. **Image first, CSV row second** (`:447-460`): "图片已落盘，才写 CSV 行". If the CSV row fails, the
   **image is deleted** (`:450-455`) because a leftover image with no row shifts every later filename.
   Frame number does not advance, so the next frame reuses the same index (`.atomic` overwrite), meaning
   even a failed delete leaves no permanent hole.
4. **No "file exists → next index" retry branch** (`:435-441`). Two reasons: `Data.write(to:options:
   .atomic)` overwrites anyway so the branch would be dead code; and if it did run, `idx += 1` would
   leave a hole in `frames/` while the CSV row still says `idx`, breaking the hard constraint silently.
5. **`appendCSVRow` returns Bool** (`:481-529`). The comment records the earlier bug: on failure it only
   incremented a counter and returned, while `writeFrame` still advanced `nextFrameIndex` → image present,
   row missing, later indices keep advancing → the training side's "index → filename" mapping is
   off-by-N and `dataset_v3`'s `frame == i` check raises `ValueError`, making the **entire segment
   unloadable**.

Two API-level traps documented inside `appendCSVRow`:
- Uses `try handle.write(contentsOf:)` rather than `write(_:)` (`:508-511`) because
  `FileHandle.write(_:)` is non-throwing and **raises an ObjC exception** on disk-full/IO error, which
  Swift `do/catch` cannot catch → it crashes the whole app, and a mid-recording crash leaves an
  unflushed CSV, which is far worse than losing one frame.
- The handle must be force-unwrapped via `guard let handle = csvHandle` (`:513-523`), not
  `try csvHandle?.write(...)`, because optional chaining returns `true` on `nil`, letting the caller
  believe the row was written and advance the frame number while the CSV has no such line. The two
  fields are always assigned/cleared under the same lock
  (`openSession:558-559` / `closeSessionLocked`), so the state is currently unreachable — kept as a
  zero-cost defence that does not depend on that implicit invariant.

## 5.5 CSV format — 11 columns, header written once per session

Header, verbatim (`LeanRecordEngine.swift:649-650`):
```
t_sec,frame,speed_kmh,w,a,s,d,shift,space,super_brake,ultimate_brake
```
Row construction (`:497-502`), in the same column order, built by **string concatenation** rather than
`String(format:"%@…")` — stated reason (`:493-496`): `%@` relies on String→NSString `CVarArg`
bridging which can produce unpredictable output for empty or non-ASCII values, while concatenation is
deterministic and the column count is visible at a glance.

Field semantics:
- `t_sec` — `String(format: "%.5f", tSec)` where `tSec = date.timeIntervalSince(sessionStart)`
  (`:448`, `:497`).
- `frame` — the integer `idx` (`:497`).
- `speed_kmh` — **always an empty string, never `0`** (`:489-491`, `:498`). Reason: `dataset_v3` treats
  an empty string as `speed_valid=0`; writing `0` would be interpreted as "the true speed is zero",
  i.e. a wrong supervision signal. Real speed is filled in by offline OCR.
- `w,a,s,d,shift,space,super_brake,ultimate_brake` — the 8 V3 native key labels from `RawKeySample`
  (`:499-502`).

Key codes (project-wide authority, cross-referenced by other sections): A=0, D=2, W=13, S=1, Space=49,
LeftShift=56. `UNVERIFIED:` those integers were not re-derived from source in this session; they must be
pinned in the control section before being asserted.

Session file set, written by `openSession` (`:634-685`):
- `view.txt` — content = `viewLabel`, default `"TPV"` (`:119-121`, `:640-643`). Written only if absent.
  Rationale (`:636-639`): `dataset_v3` reads it only when `view_filter` is passed explicitly and
  `train_v3.py:263` currently does not pass one, so a missing file does not silently drop the segment —
  but keeping the file set identical avoids a future silent skip (which **does not error**, it just
  yields fewer samples).
- `controls.csv` — created with the header via `FileManager.createFile` (`:651`), then reopened for
  writing and seeked to end (`:654-655`).
- `frames/` — created by `makeSessionDir` (`:626-627`).
- `meta.json` — written at close (5.6).

Session state reset inside `openSession` (`:657-683`), each with its reason:
`sessionDir`, `lastClipDir`, `framesDir`, `csvHandle`, `sessionStart` (`:658-662`);
`sessionGeneration &+= 1` so in-flight old frames are discarded by the generation check (`:663-664`);
`frameCount = 0`, `writeFailureCount = 0`, `nextFrameIndex = 0` (`:665-667`);
`framesWrittenLocked = 0` — explicitly noted as the **authoritative** counter, and omitting the reset
would make segment 2's log/meta inherit segment 1's frame count (`:668-669`);
`lastFrameWidth/Height = 0` (`:670-671`); `restartedPending = false` (`:672`);
`lastAcceptedFrameTime = nil` — else the 10-minute auto-segment would drop exactly one frame at the start
of every segment because the stale timestamp blocks the first frame (`:673-675`);
`cadenceIntervals.removeAll` + `contractBreachStreak = 0` — else the new segment inherits the previous
segment's interval samples and could be stopped immediately for jitter that belonged to the old segment;
the contract is evaluated **per clip**, so the monitor must also work per segment (`:676-681`);
`lastError = nil` (`:682`).

Directory naming (`makeSessionDir`, `:602-632`): `clip_<yyyyMMdd_HHmmss>` under `clipsRoot`, matching the
repo convention — the training side scans only the `clip_` prefix and cleanup relies on lexicographic ≈
chronological order (`:609-611`). **Name collisions are never accepted** (`:612-624`): the timestamp is
second-precision and auto-segment is `stop()` immediately followed by `start()`, which necessarily lands
in the same second; `createDirectory(withIntermediateDirectories:)` does **not** error on an existing
directory, and `createFile` in `openSession` would then **truncate** the previous segment's
`controls.csv` while frames restart at `000000` — the whole segment is silently lost with no error. A
numeric suffix `_2 … _999` is appended instead; exceeding 999 returns nil (`:622`).

## 5.6 Session metadata — `meta.json`

`struct LeanRecordMeta` (`:61-88`) with fields `fps/width/height/frames/framesFailed/durationSeconds/
segmentIndex/note` (`:62-69`). `jsonObject(createdAt:)` emits exactly these keys (`:71-87`):
`mode:"lean"`, `created_at`, `fps`, `width`, `height`, `total_frames`, `frame_write_failures`,
`frames_complete` (= `framesFailed == 0`), `duration_seconds`, `segment_index`,
`speed_source:"offline_ocr"`, `needs_annotation:true`, `note`.
Note text at close (`:714`): "只录画面与按键；speed_kmh 列为空，需跑离线标注回填。"

Why meta exists at all (`:58-60`): recording-time **silent failures cannot be reconstructed from the
data itself** — e.g. frame rate drifted out of tolerance so the training side rejects the whole segment,
yet the files look perfectly normal.

`closeSessionLocked()` (`:687-723`), only ever called from `writeQueue.sync`:
- `csvHandle?.synchronizeFile()` then `closeFile()`, then `csvHandle = nil` (`:690-692`).
- Counters are read **under the lock** (`:697-704`) because they are written by writeQueue and read by
  main; and it must read `framesWrittenLocked` (authoritative), not the `@Observable frameCount`, which
  is updated via `DispatchQueue.main.async` and may not have run yet — using it would under-report
  (`:694-696`).
- `meta.json` is written with `.atomic` (`:722`), commented as non-optional because a partial JSON from a
  crash/power loss fails to parse, and by then the segment has already been handed to the annotator via
  `onSegmentClosed` — losing the only self-description of "is this data usable" (`:719-721`).
- Width/height come from the **actual pixel buffer** per frame (`:464-467`), because otherwise meta would
  permanently say 0×0 — which is an **incorrect statement** that later analysis would misread (`:465`).

## 5.7 `start()` / `stop()`

`start() -> Bool` (`:234-263`), order matters:
1. `guard !isRecording else { return true }` (`:235`).
2. Disk check **on the volume actually written to** (`:237-245`): `Self.freeDiskBytes(at: clipsRoot)`
   compared against `minFreeDiskBytes` (default 2 GiB, `:117`). Explicit reason: it must not query
   `projectRoot`, because the two may be different volumes (switch recording disk / external disk /
   selftest `clipsRootOverride`); querying the wrong volume means authorising writes to disk B using
   disk A's free space, and running truly full invalidates the whole segment (`:238-239`).
   Failure message includes both the free space and the floor and states recording was refused
   (`:241-243`), returns false — it does **not** delete user data (`:116`).
3. `makeSessionDir()` else error (`:247-251`).
4. `openSession()` else error (`:252-256`).
5. Set `isRecording = true` under lock, log `▶ 开始精简录制 → <dir>（15.0 fps，段 N）` (`:258-262`).

`stop()` (`:266-295`):
1. `guard isRecording` (`:267`).
2. Set `isRecording = false` **first** (`:269-271`).
3. `writeQueue.sync { closeSessionLocked() }` (`:273-277`). Because writeQueue is serial, `sync` is
   ordered after every enqueued frame, guaranteeing the CSV handle closes **after** the last frame is
   written — otherwise tail rows are lost (`:273-274`).
4. Read `framesWrittenLocked`/`writeFailureCount` under lock and log totals (`:279-287`); if failures > 0
   it says the corresponding CSV rows were skipped to keep frame numbers paired (`:285-287`).
5. `onSegmentClosed?(closedPath)` **last** (`:288-294`), only registers the path — it must **not**
   annotate here, because auto-segment calls `stop()` then immediately `start()`, and annotating now
   would compete with the new segment's capture for CPU (`:290-291`).

## 5.8 Per-frame admission — the one-way 15 fps gate

`appendFrame(pixelBuffer:)` (`:298-343+`), called on **captureQueue**, does only "take timestamp + key
snapshot + enqueue" (`:299`). The pixel buffer is already a private copy made by
`CaptureEngine.copyRecordFrame`, so holding it until the write completes is safe — no
use-after-release (`:300-301`).

Rate limiting (`:305-330`):
- Runs **before** taking the timestamp (`:305`).
- Purpose stated precisely (`:306-312`): this is **not** compressing 20 fps down to 15. The UI process's
  capture baseline is 15 fps and the UI only calls `start()`, never `setCaptureHz` (20/45 fps are values
  the **engine process** dispatches by mode and are unrelated to this recorder's process). The gate is a
  defence against **extra pushes from SCStream**: when the picture changes violently the system pushes
  more frames, and accepting them all compresses `t_sec`, while `dataset_v3` validates
  `actual_fps = 1/median(dts)` against 15 ± 15 % (**12.75–17.25**) and raises `ValueError` — making the
  entire dataset unloadable.
- Threshold is `minGap = period * 0.9` (`:329-330`) rather than a strict `1/15`. Reason (`:314-316`):
  the true interval of a 15 fps source jitters around 66.7 ms, and pinning to exactly 66.7 ms would also
  reject normal frames, lowering the effective rate and falling below the tolerance floor.
- **Documented blind spot of a one-way gate** (`:318-327`): it only enforces "not too fast", never "too
  slow". If SCStream stalls or the system throttles and delivery drops to ~10 Hz, intervals ~100 ms pass
  the lower bound every time, `median(dts)` leaves 12.75–17.25 and `dataset_v3` raises on the whole
  segment. Rejecting slow frames cannot fix it — the next frame's reference is the last *accepted* time,
  so intervals only grow, leading to rejecting everything; and rejecting cannot turn a 10 Hz source into
  15 Hz. The correct response, and the chosen one, is to **monitor actual rate with `dataset_v3`'s own
  criterion and stop recording with an explicit reason** rather than silently producing ten minutes of
  data that cannot be loaded.
- Lock discipline (`:331-341`): the `isRecording` check and the generation read happen in **one** lock
  acquisition. If they were taken separately and a segment rotation landed between them, an old
  segment's in-flight frame would be carried into the new segment, then written to the new segment's
  `framesDir` at `nextFrameIndex=0`, overwriting `000000.jpg` — old segment loses a frame, new segment
  gains an old picture, and frame numbers remain contiguous ⇒ `dataset_v3` reports nothing. A silent
  mismatch.
- Rate-limited frames are excluded from cadence statistics because they are not representative of
  capture cadence (`:342-343`).

## 5.9 Cadence monitor — enforcing the training-side contract at record time

`noteCadenceForContract()` (`:555-598`), called per frame from `appendFrame` (`:363`).
Fields: `cadenceIntervals`, `cadenceWindow = 120`, `contractBreachStreak`, `contractBreachLimit = 45`,
`contractMinSamples = 30`, `contractFpsTolerance = 0.15` (`:196-205`). `contractBreachLimit` and
`contractMinSamples` are `var`, deliberately, so a selftest can shorten them to trigger the stop
deterministically — the same convention as `maxSegmentSeconds` (`:199`, `:114`).

Algorithm (`:556-598`): lock → require `isRecording` and `cadenceIntervals.count >= contractMinSamples`
→ compute the **median** of the intervals (even/odd aware, `:561-565`) → `actualFps = 1/medianDt`
(`:570`) → `deviation = |actualFps - fps| / fps` (`:571`) → `breached = deviation >
contractFpsTolerance` (`:572`) → streak increments on breach, resets otherwise (`:573-577`) →
unlock → require `breached && streak >= contractBreachLimit` (`:581`) → **report only at the exact
crossing moment** `streak == contractBreachLimit` (`:582-583`) since this runs every frame.

Message (`:585-587`): `实测 X.XXfps 已持续偏离 YHz 超过 ±Z%（dataset_v3 会拒载整段），已停止录制`.

Stop must be hopped to main (`:589-597`): the comment forbids calling `stop()` on the capture queue
because `stop()` contains `writeQueue.sync {}` and would block the capture queue on disk I/O — the same
incident on record (capGap 11 ms → 2081 ms). `DispatchQueue.main.async` is used, and the closure
re-checks `isRecordingSnapshot` before stopping and setting `lastError`.

## 5.10 Threading model (authoritative summary)

| context | what happens | rule |
|---|---|---|
| main thread | `start()` / `stop()`, segment rotation | `stop()` does `writeQueue.sync` drain; never call it from captureQueue |
| captureQueue (SCStream callback) | `appendFrame`: timestamp, key snapshot, rate gate, enqueue | **no JPEG encode, no disk I/O, no `stop()`** (`:44-47`) |
| writeQueue (serial) | JPEG encode, file write, CSV append, meta write, close | owns `nextFrameIndex` ordering; `stop()` drains it synchronously |
| main thread (async hop) | `frameCount` publish (because `@Observable` storage is not thread-safe) | authoritative count is `framesWrittenLocked` under `stateLock` (`:473-478`) |

## 5.11 Where the frames come from (capture-side contract)

`CaptureEngine.swift:1168-1176`: `onRecordFrame` is gated by `isRecordFrameWanted()` **before** the copy;
the copy itself is synchronous on captureQueue (≈4 MB memcpy, sub-millisecond) while JPEG encoding and
disk I/O are the recorder's job. The same comment carries the standing prohibition: never encode on the
capture queue, citing the 11 ms → 2081 ms regression. Two separate files therefore state the same rule
independently — treating it as a cross-cutting invariant, not local advice.

## 5.12 Legacy `RecordEngine` (expert mode) — status

`Sources/AuroraDrive/Capture/RecordEngine.swift` is 771 lines and still compiles as part of the target
(`Package.swift:189-192` includes the whole directory). Its own existence is the reason the lean
recorder was written (5.1). Output-directory isolation is documented at `LeanRecordEngine.swift:94-95`:
lean clips go to `data/lean_clips/clip_<yyyyMMdd_HHmmss>/` — deliberately **separated** from the
training scan path `data/raw_clips` so that unannotated data cannot be picked up by training.

`UNVERIFIED:` the internals of `RecordEngine.swift` (19-column layout, continuous-value label
generation, 640×360 scaling) were **not** read line-by-line in this session. The 19-column claim appears
only as historical description in `LeanRecordEngine.swift:17` and as the subject of commit `4947ec6`
("CSV 19 列 → 11 列"). It must be verified before being stated as a fact about the current file.

## 5.13 Offline annotator — contract surface

`Sources/AuroraDrive/Capture/LeanAnnotator.swift` (597 lines) consumes what `stop()` reports via
`onSegmentClosed`, and per the design it is responsible for filling `speed_kmh` by running OCR on the
`speedROINorm` region offline (`LeanRecordEngine.swift:29-30`, `:83`, `:491`).

`UNVERIFIED:` `LeanAnnotator`'s internals (progress staging, % reporting, whether it rewrites
`controls.csv` in place, whether it validates `frame == i` before writing) were **not** read this
session. Cross-references that must be checked when writing that part: `speed_source:"offline_ocr"`
in meta (`:83`) and `needs_annotation:true` (`:84`) imply the annotator is the only path that makes a
segment training-ready.

## 5.14 Selftest surface

`Sources/AuroraDrive/Capture/LeanRecordSelfTest.swift` (715 lines) is the executable proof for this
section and is run as `./AuroraDriveUI --lean-selftest`. Its pattern (per the assertions described in
this session's earlier verification work, `UNVERIFIED:` line numbers not re-pinned here): it uses
`clipsRootOverride` (`:123-125`) to write into a temp dir so `data/lean_clips` is untouched, shortens
`maxSegmentSeconds` to a tiny value to force rotation (`:114`, `:199`), and asserts header/column counts
plus reverse assertions that removed columns are really gone.

## 5.15 Known-open items in this layer

Carried as facts about the current state, each traceable to source or to a prior recorded review:
- `LeanRecordEngine.swift:96-100` — the **directory-layout doc comment still says "controls.csv 19 列"**
  and mentions position/acceleration. Stale comment vs the actual 11-column header at `:649-650`.
  Anyone trusting the comment will mis-size the schema.
- Crash window between a successful JPEG write and the CSV row append: if the process dies between them,
  `frames/N.jpg` exists with no row. `.atomic` write protects the file's integrity, not the pairing.
  Uncovered code path; the pairing invariant is only guaranteed for graceful failures.
- Auto-segment's first frame `t_sec` skew: `t_sec` is relative to `sessionStart`, which is set inside
  `openSession`, so the first frame of a new segment is relative to the new session — cross-segment
  time monotonicity is not preserved (a design consequence of per-segment CSVs, `:662`).
- `FileHandle.close()` (`:691`) is not wrapped in do/catch — it is non-throwing Swift API here, but a
  failure would be invisible; the counter read afterwards still reflects `framesWrittenLocked`.
- Speed-OCR accuracy on a real speedometer and true 10-minute segmentation timing remain unmeasured on
  real gameplay data (`recordings/` is 0 B, `data/raw_clips` not exercised this session).
