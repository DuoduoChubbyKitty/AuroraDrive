# Internals · Pitfalls

> Real crashes and silent failures that happened during development and were fixed. Format: symptom → root cause → fix. Only pitfalls that map to **current code** are listed.
> Up: [Developer Guide](DEVELOPER_GUIDE.en.md) ｜ 中文: [踩坑实录](../自动驾驶与功能/pitfalls.md)

> ## ⚠️ Out of sync (noted 2026-09-29) — the Chinese version has **27** entries, this file has **10**
>
> The Chinese `pitfalls.md` has grown to **27 sections** (up from 10), i.e. **17 entries are missing here**.
> The most important omissions for anyone touching the current code:
>
> | § | Chinese title | Why it matters |
> |---|---|---|
> | 11–13 | OpenCV static-link / SPM `-L` / no Foundation in manifest | **Build-breaking**; all three were hit on 2026-09-27 |
> | 14 | Pooled `CVPixelBuffer` held across steps → use-after-recycle | Frame corruption / crash risk |
> | 15–16 | Optical-flow latency vs QoS; OpenCV thread count | The `setNumThreads(2)` value is a **production setting — do not change** |
> | 17 | **Fake diagnostics are worse than none** | A self-test printed an unassigned field; wasted a whole debugging cycle |
> | 18 | One flag driving two things | Root cause of "can't see lane lines *and* drivable area" |
> | 19–20 | Division in the inner loop; a verification script that lies | Perf + methodology |
> | 21 | **`drawingGroup()` on an animated subtree = offscreen texture rebuilt every frame** | Caused a "卡到逆天" (unusably laggy) regression; **must** be validated with `sample <pid> 3` |
> | 22 | "Background thread" ≠ "idle thread" | Moving work to the ScreenCaptureKit queue made things worse |
> | 23 | `pkill -f` substring mismatch fails silently | Ops |
> | **24** | **A guard used a field the protocol never sent → masks never drawn** | The user-visible bug: "only detection boxes, no drivable area / lane lines" |
> | 25–26 | `LaneFallback` has the same guard shape; `/tmp/aurora_pcap.log` has no rotation | Open **to-dos** |
>
> **Recommendation**: read the Chinese [pitfalls.md](../自动驾驶与功能/pitfalls.md) as the source of truth.
> This English file is a **2026-09-19 historical snapshot** and has not been extended since.

> **Archive note (verified 2026-09-19, baseline 7b7d2db)**: all 10 items were re-checked against the current code and still hold — `pcap_next_ex` blocking loop (captureLoop), `Int64(bitPattern: v &- modulus)`, `guard searchEnd > 190` + the full `bits()` guarding, `pcap_findalldevs` enumeration, the CIImage `y = sh - yMax` mirrored crop, the `com.aurora.bpf-setup` LaunchDaemon, `pcapLog` writing `/tmp/aurora_pcap.log` (FileHandle seekToEnd), `MLModel.compileModel`, the fixed signing order in `run.sh`, and the Chinese-path external-disk Xcode (historical environment). This is a pure historical record; the body is unchanged.
>
> ⚠️ **One claim in the note above is now stale**: it says `pcapLog` citing the FileHandle `seekToEnd` behaviour "still holds" — it does, but note that this is exactly the **unbounded-growth** issue now tracked as §26 in the Chinese file.

## 1. pcap_loop callback SIGBUS on Apple Silicon (PAC crash)

- **Symptom**: instant SIGBUS on launch, stack inside libpcap, intermittent
- **Root cause**: the `pcap_loop` C function-pointer callback is invoked from another stack. Apple Silicon's PAC (Pointer Authentication Codes) validates function-pointer signatures; a Swift closure coerced via `@convention(c)` fails signature validation across the PAC boundary → SIGBUS
- **Fix**: drop the `pcap_loop` callback; pull packets with a blocking `pcap_next_ex` loop (`captureLoop`)
- **Lesson**: think twice before passing function-pointer callbacks into C libraries on Apple Silicon; polling-style APIs are usually safer

## 2. Unsigned underflow SIGTRAP

- **Symptom**: random SIGTRAP crashes while pcap runs fine
- **Root cause**: in signed vector decoding, `v -= modulus` underflows UInt64 when garbage bits yield `v < modulus` — Swift traps on unsigned underflow by default
- **Fix**: `v = v &- modulus` (wrapping subtraction, semantically equal to two's-complement subtraction)
- **Lesson**: a bitstream scanner runs over garbage; every arithmetic op must assume "input can be any bit pattern"

## 3. findCandidates Range trap

- **Symptom**: crash when real game traffic arrives (simulated traffic never crashed)
- **Root cause**: the scan window `for offset in 190..<searchEnd` — with short packets `payload.count*8-60 < 190`, and Swift Ranges require lowerBound ≤ upperBound → runtime trap
- **Fix**: `guard searchEnd > 190` + full guarding in `bits()` (count>63 against `1<<count` overflow, array bounds, `data.count > 14` precheck)
- **Lesson**: real traffic length distributions differ from assumptions; Range literals are Swift's most common hidden trap

## 4. pcap_lookupdev picks the wrong NIC

- **Symptom**: capture starts fine, loop runs, but zero packets forever
- **Root cause**: `pcap_lookupdev` on macOS returns only the default-route NIC (en0/Wi-Fi); game traffic may flow on en8 (wired/USB)
- **Fix**: `pcap_findalldevs` enumerates all NICs, skipping lo0/pdp_ip/utun/awdl/xhc20 virtual prefixes; open+compile+setfilter each until one succeeds
- **Lesson**: "the API returned success" ≠ "you captured the traffic you wanted"; NIC selection must be explicit

## 5. CIImage crop Y-flip

- **Symptom**: systematic offset of speedometer digit slot crops
- **Root cause**: ScreenCaptureKit/CVImageBuffer row order is flipped relative to the CGImage coordinate system; cropping by normalized coordinates yields a mirrored region
- **Fix**: crop via the CIImage path with an explicit mirror `ciRect.y = sh - yMax`
- **Lesson**: for cross-framework (ScreenCaptureKit↔CoreImage) vision pipelines, coordinate semantics must be itemized and compared

## 6. BPF permissions lost on reboot

- **Symptom**: `sudo chmod 666 /dev/bpf*` works, but after a reboot pcap gets Permission denied again
- **Root cause**: macOS rebuilds `/dev/bpf*` device nodes at every boot with root-only permissions
- **Fix**: in-app password sheet → osascript installs the `com.aurora.bpf-setup` LaunchDaemon (RunAtLoad auto-chmods 666 at every boot) — enter once, effective forever
- **Lesson**: device-node permissions are volatile; any scheme depending on /dev permissions must handle reboots

## 7. SwiftUI app's print() never reaches the terminal

- **Symptom**: debug prints vanish; neither the terminal nor `log show` shows them
- **Root cause**: a bare SwiftUI executable's stdout is not wired to the terminal; concurrent high-frequency prints also race
- **Fix**: `pcapLog` appends to `/tmp/aurora_pcap.log` (FileHandle seekToEnd; the earlier "read-all + append + write-all" pattern exploded IO at 10Hz and dropped lines through overwrite races)
- **Lesson**: file logging from day one for SwiftUI apps

## 8. CoreML loading .mlpackage throws "Compile the model"

- **Symptom**: `MLModel(contentsOf:)` on a `.mlpackage` throws *"Unable to load model … Compile the model with Xcode or MLModel.compileModel(at:)"*
- **Root cause**: newer macOS no longer implicitly compiles `.mlpackage`; explicit compilation is required
- **Fix**: `let compiled = try MLModel.compileModel(at: url)` first, then `MLModel(contentsOf: compiled)`
- **Lesson**: prefer shipping pre-compiled `.mlmodelc`; if you ship `.mlpackage`, always go through compileModel

## 9. Binary signing and xattr

- **Symptom**: app SIGKILL "Code Signature Invalid"
- **Root cause**: `xattr -cr` deletes the code signature itself; or signing the artifact inside `.build` and then cp-ing it (cp breaks the signature)
- **Fix**: fixed order `swift build → cp to target → codesign the target → xattr -d com.apple.quarantine` (remove only the quarantine attribute; never `-cr`). Baked into `run.sh`
- **Lesson**: signing targets and order are hard constraints

## 10. Macro plugin malformed on Chinese-path Xcode

- **Symptom**: `swift build` reports *"external macro implementation type 'ObservationMacros.ObservableMacro' could not be found … swift-plugin-server produced malformed response"*
- **Root cause**: `xcode-select` points to a Chinese-path external-disk Xcode (`/Volumes/项目依赖/Xcode.app`) whose `swift-plugin-server` (implementing `@Observable`) misbehaves in restricted environments
- **Mitigation**: build with full permissions (the plugin needs to write temp caches); the real fix is installing Xcode under a non-Chinese local path
- **Lesson**: toolchain paths with non-ASCII characters on external disks bite you at the deepest layer — compiler plugins
