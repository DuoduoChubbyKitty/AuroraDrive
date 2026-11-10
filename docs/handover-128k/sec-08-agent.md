# SEC-08 — AGENT / LLM SUBSYSTEM

Source dir: `Sources/AuroraDrive/Agent` — **17 files / 15,383 lines** (`wc -l`). Largest:
`AIAgentPanel.swift` 3273, `LLMSelfTest.swift` 2183, `LLMHealth.swift` 1791, `LLMTransport.swift` 1580,
`WebSearch.swift` 1463, `ToolRegistry.swift` 1065, `LLMBackend.swift` 884, `AgentLoop.swift` 657,
`AgentChatService.swift` 618, `DriveSegmentController.swift` 430, `FallbackGuard.swift` 280,
`AgentSettings.swift` 262, `EmergencyTakeover.swift` 239, `RuleController.swift` 209,
`LoginAssistant.swift` 166, `DegradeStateMachine.swift` 165, `EgoBoxFilter.swift` 118.

## 8.1 Layer map — five files, five single responsibilities

`LLMBackend.swift:8-21` states the boundary explicitly and is the most complete architectural statement in
this subsystem:
1. `LLMBackendDescriptor` — which channels exist;
2. `makeRequest` — how to build a legal request per channel;
3. `models` / `staticModels` — which models each channel has and their capabilities.
It **does not** send requests (`LLMTransport`), **does not** monitor health or order the fallback chain
(`LLMHealth`), **does not** touch UI (`AIAgentPanel`) (`:14-17`).

| file | responsibility | stated by source |
|---|---|---|
| `LLMBackend.swift` | descriptors: channels, request construction, model tables | `:8-12` |
| `LLMTransport.swift` | OpenAI-compatible request sending + SSE parsing + 12 error classes | `:8-18` |
| `LLMHealth.swift` | health monitoring, degradation ordering, candidate chain | `:9-11` of LLMBackend ref |
| `ToolRegistry.swift` | the single tool list + single execution entry + evidence chain | `:11-15` |
| `AIAgentPanel.swift` | UI, streaming display, session history window | `:15-18` ref |
| `AgentChatService.swift` | chat glue: candidate chain × transport × health orchestration, in an actor | `:4-27` |
| `AgentLoop.swift` | native tool-calling task loop (zero framework) | `:4-25` |
| `AgentSettings.swift` | config struct, extracted from the panel; no API keys | `:4-18` |

Dependency direction is asserted, not implied: `LLMMessage`/`LLMToolSpec`/`LLMImage`/`LLMRole` are
defined in `LLMTransport.swift` and only **referenced** by `LLMBackend.swift`, because redefining symbols
would break the whole module (`LLMBackend.swift:19-20`).

## 8.2 Channels and their measured reality

`LLMBackend.swift:36-56` carries a probe log with timestamp, method and raw result for **7 channels**,
measured 2026-10-06 21:18–21:35 Asia/Shanghai against live endpoints (raw outputs archived to
`/tmp/w1_*.json`):

| channel | `GET models` | `POST chat/completions` |
|---|---|---|
| OVH | 200, 24 entries, **no Authorization header needed** | 200 for Qwen3.6-27B; 429 "API rate limit exceeded" on the other 4 buckets |
| Zen | 200, 86 entries (200 even when any of three headers is missing) | 200 with **tool_calls working**; paid models (claude-sonnet-5/gpt-5.5) → 401 |
| Gen | 200, 298 entries | **401 requires key** (9 on-machine probes) |
| Legacy | `/models` 200, single `openai-fast` | `/openai/chat/completions` 200 — **note the base URL is already the chat endpoint** |
| OpenRouter | `/api/v1/models` 200, 464 entries (publicly readable) | — |
| Groq | `/openai/v1/models` 403 (needs key) | — |
| 智谱 | `/api/paas/v4/models` 401 code 1001 (needs key) | — |

**The pollinations conflict is recorded as deliberately unresolved** (`:57-66`): on-machine 9 probes
(varying UA/Referer, `?referrer=`, `?token=anonymous`, `Authorization: Bearer anonymous`, stream:true)
all returned **401** `{"success":false,"error":{"message":"A valid API key is required..."}}` with **no
429 at any point**, while at the same moment Legacy returned 200 and gen's `GET /models` returned 200;
the Lead's own 4 re-probes all **succeeded**. Conclusion stated in-source: this is **time-of-day gateway
flapping**, neither a permanent gate nor rate limiting. Therefore: `requiresKey=false` is kept (frozen
contract not unilaterally changed), `riskNote` states only "flaps, trust the probe", explicitly
**not** writing either "needs key" or "rate limited", and real availability is decided by
`LLMHealthMonitor` probing actual requests.

Red line: **no hardcoded API key**; the only literal resembling one, `"public"`, is OpenCode Zen's public
tier sentinel, with provenance recorded (`/tmp/zen-proxy.mjs:495 return "Bearer public"`,
`LLMBackend.swift:27-29`). Same rule restated in `AgentSettings.swift:14-17`: no embedded key; the user's
key lives in a local mode-0600 notebook; key-free channels use `public`/empty Authorization.

## 8.3 Transport layer — what makes it offline-testable

`LLMTransport.swift:8-30`:
- Sends `POST {base}/chat/completions`, non-streaming and SSE streaming;
- SSE line parsing: `data:`, `[DONE]`, `delta.content`, `delta.reasoning_content`,
  `delta.tool_calls` fragment accumulation;
- Image part encoding as data URL, with **long side 1568 px, JPEG 0.8 hard limits**;
- 12 error classes, each corresponding to a real observed upstream body;
- `Task.cancel` → `.cancelled`, leaving no dangling connection.

**All parsing is pure functions** (`:19-23`): `SSEParser`, `LLMError.classify`, `LLMImageEncoder` are
stateless (no `URLSession`, no global state) specifically so `--llm-selftest` can reproduce every
criterion **without network access**.

Performance red lines (`:26-30`): network and parsing run entirely in async context (URLSession's own
delegate queue); **no `DispatchQueue.main` and no `@MainActor` anywhere in the file**; URLSession uses an
independent configuration (`LLMSessionPool`) fully separated from `captureQueue` and the panel's
`llmSession`, so capture frame rate is unaffected by LLM requests (listed as an ABBA comparison item);
reads use `URLSession.bytes(for:)` consumed byte-by-byte with **per-line flush** (minimum
first-token latency) rather than buffering the whole SSE body and splitting it.

Error taxonomy is copied from real responses, one case per observed body (`:32-44`):
`{"type":"error","error":{"type":"FreeTierError"}}` → `.gated`;
`RegionError` → `.regionBlocked`; `ModelDeprecated` + `metadata.replacement` → `.modelDeprecated`;
`ModelDeprecated` without replacement (placeholder `no-replacement-available`) → `.modelNotFound`;
`server_error`/HTTP 5xx → `.upstream`; HTTP 429 (with `Retry-After` header) → `.rateLimited`;
HTTP 401 → `.invalidKey`; `URLError.timedOut` → `.timeout`; DNS/network unreachable → `.network`;
HTTP 200 with empty content (observed on `space-bunny-free`) → `.badResponse`; `Task.cancel` → `.cancelled`.
The comment's framing rule: "逐条照抄、不自行增删分类".

`toolCall` id semantics (`:420`): in SSE fragments the `id` and `function.name` appear **only in the
first** fragment.
`timeout` semantics (`:491-493`): it is an **idle** timeout (`URLSession.timeoutIntervalForRequest` =
maximum gap between two packets), so long streaming answers are not cut mid-stream.
SSE compat mode (`:539`): some key-free endpoints return plain JSON even when `stream=true`.

## 8.4 Chat orchestration — `AgentChatService`

Header (`AgentChatService.swift:4-27`). Why the actor exists: the panel needs "user says something → show
incrementally → get final text", while underneath there is a distributed state of candidate chain ×
transport × health monitoring. Extracting the orchestration into an actor gives three benefits:
the panel need not know candidate/degradation/error-class details (UI cares only about text and a status
string); the orchestration is directly reusable by the CLI selftest (`--llm-selftest` uses the same path
as the panel); network and parsing stay inside the actor so the **main thread is never touched**.

**The bug this file fixed** (`:13-16`): before the rework, `sendUserMessage`'s free-text branch went
through `localReply()` hardcoded canned text, while the real model Q&A function `plainAnswer` existed but
**was never called by any production path**. This file *is* that missing production path.

Constants (`:100-126`):
| constant | value | reason (source) |
|---|---|---|
| `maxHistoryTurns` | **12** | prevent token explosion; overflow turns are dropped (`:107-109`) |
| `maxCandidatesPerRequest` | **4** | "4 是权衡值" — free tiers rate-limit so several escape routes are needed, but dragging one conversation into a dozen round trips is unacceptable and triggers more rate limiting (`:111-115`) |
| `deltaThrottleInterval` | **1/15 s** (≈66 ms) | some channels push one SSE chunk per token, hundreds per answer; a SwiftUI state write per chunk saturates the main thread (`:117-124`) |
| `requestTimeout` | **30 s** | idle-timeout semantics, does not truncate streaming (`:126-128`) |

Degradation semantics (`:19-23`): the candidate chain comes from `LLMHealthMonitor.candidates` and tries
**at most 4**. Full-chain failure **does not throw to the UI**: it returns empty text plus an error
string, and the panel decides to fall back to `localReply` marked 「离线回复」, so the user can tell
"model answered" from "local fallback".

Performance justification is measured and repeated across files (`:25-27`): Vision OCR p50 **33.6 ms** ≈
one entire 30 Hz frame budget, hence the project is extremely main-thread sensitive; therefore network,
SSE parsing and history trimming all run in the actor, and the `onDelta` callback is throttled to ≤15 Hz
by this layer.

## 8.5 Health / candidate ordering

`LLMHealth.swift` (1791 lines). Entry point `func candidates(preferred:...)` at `:840`.
Ordering design (`:1058`, `:1074`): it uses **explicit partitioning + stable enumeration sort**, with the
comment rejecting `sorted { ... return false }` because a comparator that always returns false is not a
valid ordering. Exact call sites consumed by other modules are pinned in `LLMBackend.swift:22-26`:
`LLMBackendRegistry.shared.descriptor(for:)` → nullable; `provider(for:apiKey:)` → nullable;
`try? await provider.models(apiKey:)` → throwing; `AgentLoop.swift:510` descriptor,
`:520` `descriptor?.extraHeaders` (Zen's three headers come from here); W3/W7 access only four descriptor
members: `baseURL`, `extraHeaders`, `staticModels` (+`kind`). The backend file therefore keeps fields
beyond the minimum contract, which is harmless for existing call sites (`LLMBackend.swift:28-29`).
`UNVERIFIED:` the internals of the health scoring / probe scheduling in `LLMHealth.swift` were not read
line-by-line this session beyond the symbols above; anything finer must be re-read before asserting.

## 8.6 Tools — exactly 30, with four guards

`ToolRegistry.swift:16-23` enumerates the mounted list, and the count is verifiable in code: there are
**13** `insert(AgentTool(` call sites, one of which sits inside `for skill in AgentSkillLibrary.all`
`(:155-161)`, and `AgentSkillLibrary.all` (`AIAgentPanel.swift:91`) contains **18** skills
(`auto_login, volleyball, fishing, coffee, coffee_lite, bagel_spam, pinkpaw, furniture, rewards, piano,
rhythm, dodge, auto_scroll, touch, drive_dataset, preset_afk, preset_realtime, tomato_juice`).
18 + 12 = **30**.

| group | count | prefix / names | backed by |
|---|---|---|---|
| skills | 18 | `skill__*` | `AgentSkillCenter.runSkill(id:source:.ai)` |
| keys | 4 | `press_key` / `hold_key` / `release_key` / `release_all` | `ControlEngine(GameKey)` |
| text | 1 | `type_text` | `ControlEngine.typeText` |
| mouse | 3 | `mouse_move` / `mouse_click` / `mouse_scroll` | `MouseController` |
| observe | 2 | `screenshot` / `get_status` | — |
| search | 2 | `web_search` / `web_fetch` | `WebSearch` (this file implements no fetching) |

**Mounted ≠ usable** (`:156-158`): `isImplemented: skill.ported`, so among the 18 skills only those with
`ported: true` truly work; `preset_realtime` is documented as `ported=false` → calling it returns
`ok=false`. Measured `grep -c 'ported: true'` in `AIAgentPanel.swift` = **15**, i.e. **3 of 18 skills are
not implemented** (`pinkpaw`, `rhythm`, `preset_realtime`). So "30 tools" is a mount count, and the
honest usable count is 27 (15 skills + 12 non-skill tools) — with the caveat that `grep` also matched
other `ported` mentions (33 occurrences of the token), so this number should be re-derived from the
skill table itself before being treated as final. `UNVERIFIED:` the per-skill `ported` flags were not
printed individually this session.

Four guards, all "explicit error, never silent" (`:24-34`):
1. `AuroraFlags.observeOnly` (`AURORA_OBSERVE_ONLY=1`) → refuse every injection tool (`ok=false`);
2. `GameWindowDetector.isGameVisible()` → refuse when the game is not visible (prevents injecting keys
   and mouse into some other window);
3. `AXIsProcessTrusted()` → refuse without Accessibility permission, because the system **silently
   discards** such events — "绝不假装成功";
4. `dryRun` → inject nothing, but return a **structurally complete** `ToolResult` for the selftest.

The `dryRun` vs guard relationship is an explicit design decision (`:36-43`): `dryRun` injects nothing,
so guards ② ③ do **not** block `dryRun` — otherwise a selftest environment with no game window could
never obtain an `ok=true` structured result and the selftest would be nothing but refusal text. Guard ①
does not block `dryRun` either, but real calls are still refused; this is deliberate, and violating it
destroys the "side-effect-free selftest" capability. The `dryRun` return text states truthfully that it
did nothing.

`postedEvents` semantics (`:45-53`): = the CGEvent delta observed before `invoke` returns =
`(ControlEngine.postedEventCount delta) + (MouseController.postedEventCount delta)`. For injection tools
it is **exactly** the number injected this call (0 = not a single event went out); for skill tools the
skill runs asynchronously on `AgentSkillCenter`'s workQueue, so this number is a lower bound.

## 8.7 Native tool-calling loop — `AgentLoop`

Header (`AgentLoop.swift:4-25`): architecture named by the user as 「零框架·原生 Tool-Calling」 —
one user sentence → the LLM decomposes the task into a series of tool calls (`tool_use`) → AgentLoop
dispatches through `ToolRegistry` → results are fed back → the LLM keeps planning until done.

The W7 rework made planning and execution share **one chain** with the chat path (`:11-17`):
model calls → `LLMTransport` (W2) (no more self-written HTTP or hand-assembled tools); available models →
`LLMHealthMonitor` (W3) candidate chain with live accounting, rotating at most 4; tool list →
`ToolRegistry.shared.specs()` (W4); tool execution → `ToolRegistry.shared.invoke(name:args:dryRun:)` (W4).
The old `AgentSkillCenter.callLLM` path is no longer used by this file for planning.
`MockLLM` (`:21-23`) lets the whole "instruction → plan → execute → return → complete" chain be
self-tested end-to-end with no available candidate.

## 8.8 Degradation ladder — three tiers, and why the fourth was deleted

`DegradeStateMachine.swift:5-9`: ladder = end-to-end main drive (E2E) → YOLO takeover (a second neural
net) → pure-rule fallback.
**The escape tier `.recover` was deleted wholesale on 2026-09-30 at the user's request**, with the
measured reason recorded: the escape strategy reduced speed and could not exit, so autodrive lasted only
≈**12 seconds** before being interrupted by the escape loop (`:6-7`).
Inputs: M9 alive / control model alive / current-tier health / boost switch / warm-up flag. Output:
current `DriveMode` + transition reason (`:8-9`).
Design principles (`:10-14`): ① monotone degradation with hysteresis recovery, preventing oscillation
around a threshold; ② boost mode overrides everything (speed first, obstacle avoidance off, forced E2E);
③ stuck detection is independent of the model — even a very confident model gets escaped when the car
does not move; ④ thresholds externally adjustable (UI slider, live).
Threading: main thread only, called synchronously from `DriveState.tick` (`:24`); transitions are pure
(`update(inputs)` computes the next state, no side effects, `:22-23`).

Rule tier is the only caller of the rule controller: `RuleController.swift:8-18` states that `.rule` is
the **only** call point (`AuroraDriveApp`'s `switch decided`) while `.e2e`/`.yolo` do **not** go through
it. It also corrects an older comment: `.yolo`-tier-pure-rules / `.rule`-tier-E2E-fusion is **not** what
the code does, and `fuse()` (E2E + rule fusion) currently has **no call site** repo-wide — a reserved
path (`:18-21`). The frame source depends on the perception tier: A-model tier → A-YOLOM(n) int8
three-in-one `det` head; legacy tier → `yolo26s` or YOLOPX's `det` (`:8-11`). The old hardcoded
`game_assist_yolo.onnx` name is a long-abandoned detector (`:11-13`).
`RuleController.swift:157` and `:164` define the output discipline: **steer only, throttle only, never
brake automatically**; emergency avoidance = no throttle + full opposite steer, `b` always 0, never
reverses on its own.

## 8.9 Emergency takeover — state machine with 2026-10-22 retune

`EmergencyTakeover.swift:4-30`. Responsive behaviour: when the system drops ticks (`tickGap > 80 ms`
for 3 consecutive frames, later 100 ms) or the model degrades, raise the inference tick to sprint rate
and show a "please take over" banner; when the user presses a controlled key, yield to 5 Hz (user driving);
on release return to cruise.

**The header diagram is stale.** Lines `:9-10` and `:15`/`:19`/`:22` still read
`[巡航] hz=20 ... [冲刺] hz=45 ... [让位] hz=5`. The live constants are:
```
EmergencyTakeover.swift:55   static let normalHz: Double = 15.0   // ⚠️ 2026-10-22: 20→15
EmergencyTakeover.swift:58   static let sprintHz: Double = 20.0   // ⚠️ 2026-10-22: 45→20
EmergencyTakeover.swift:60   static let yieldHz:  Double = 5.0
EmergencyTakeover.swift:62   static let sprintMaxSeconds: Double = 35.0
```
Reasons recorded at `:54` (user measured 20 Hz pushed the game to 8–14 Hz; performance insufficient) and
`:58` (old 45 Hz cannot complete at all when the system is throttled, so it was *worse*); the
tick-gap threshold went 80 → **100 ms** (`:68-70`) because at 15 Hz a normal period is 66.7 ms, leaving
only 13 ms of margin at 80 ms — the new threshold keeps roughly the same ratio (20 Hz/50 ms → 80 ms ≈
1.6×). Sustained-trigger requirement is 10 frames = 667 ms at 15 Hz, so only persistent throttling fires
and occasional jitter does not (`:75`).
`effectiveTickHz` is read by `EngineMain` to dynamically set `engineTickHz` (`:34`, `:87`).
This is the same 15 Hz authority as SEC-03/06; the stale diagram is a fourth instance of the
comment-vs-code drift class catalogued in SEC-06 §6.10.

## 8.10 Geometric fallbacks — explicitly *not* the main driver

`FallbackGuard.swift:6-30`. Two criteria provided by the user:
- Structure A — ego position: "take the largest detection box at the image centre as the ego position",
  so "is there anything directly ahead" can be answered even with the perception chain down;
- Structure B — box-overlap collision: if the centre box overlaps another vehicle's box, that is
  necessarily an avoidance/collision case, so overlap can drive emergency avoidance as a pure-geometric
  criterion with no model confidence at all.
Positioning discipline is inherited from `LaneFallback`'s four rules (`:26-31`): ① fail-open — if input is
untrustworthy (too few boxes / abnormal size) return nil and the caller keeps its original decision;
② bounded output — steering and brake are hard-limited, never full throttle; ③ multi-frame confirmation —
the same verdict must hold N consecutive frames; ④ discard sudden changes — a single anomalous frame does
not change the conclusion.

`EgoBoxFilter.swift:8-30` solves the mirror-image problem: in third person the model always boxes **the
player's own car**. Its historical incident is severe and worth quoting: ego box + the front car's box
were judged by the geometric fallback as "box overlap = collision" → output `brake 0.8` → and in this game
`brake` **is the S key, which is also reverse** → so the takeover state kept giving the user braking and
reversing (`:12-17`). The decision was made by **area**, not position, because the user stated the camera
wanders ("官方为了帅车可能会到处跑……甚至可以到最远端"), and a 10,000-real-frame measurement settled it
(`:20-28`):

| rule | own-car masking success | false-hit on real cars / frame |
|---|---|---|
| area > 2 % | **98.0 %** | 0.08 |
| area > 3 % | 97.8 % | 0.05 |
| position only (centre band + lower area) | 93.2 % | 0.06 |
| area > 3 % AND position | 93.0 % | 0.03 |

The shipped rule is the area > 2 % row (`:24`), i.e. the highest success rate was accepted together with
its slightly higher false-hit rate.

## 8.11 Segment handover — four AND conditions

`DriveSegmentController.swift:8-30` records the user's 2026-09-30 required flow: ① car approaches a map
waypoint (corner) → enter **map segment**, use map guidance to steer through; ② after the turn the
heading is skewed → **must straighten** using the map road direction; ③ after straightening, hand over to
**model/vision** for lane keeping; ④ the handover must be **confirmed to really succeed**, all four
conditions satisfied, otherwise stay in place and drive conservatively.

Verbatim requirement (`:14-17`): "判断成功标准是在那条道路里…而且已经向前行驶一段距离…而且都能拟合在道路里…
并且模型已经能正常识别到车道线，才能算准确性". The four AND conditions (`:18-22`):
1. position falls inside the target road corridor (`RoadMapPrior.isOnRoad`);
2. has actually travelled some distance (network-locate coordinate integration);
3. fitting stays inside the road for several consecutive frames (vision confidence + no jump);
4. vision can actually recognise lane lines (laneMask valid).
Why not hand over immediately after the turn (`:24-26`): at that instant the heading is still skewed and
lane lines may not be recognised yet; handing over then most likely yields no trustworthy direction and
the car swerves. Safety boundary (`:28-30`): this controller only decides **which control source** to use
and performs **no limiting**.

## 8.12 Login assistant — perceived closed loop, no blind clicks

`LoginAssistant.swift:6-17`. Problem: NTE stops at the login screen every launch, previously requiring a
manual click. Working principle (fully perceived, no blind clicking):
1. take the current screen frame from `CaptureEngine` (full-screen shot; the engine stream is already
   running);
2. Vision `VNRecognizeTextRequest` OCR in Chinese and English to get all text blocks;
3. match login-button keywords by priority (`点击进入` > `进入游戏` > `登录` > `开始游戏` …);
4. on hit → normalised bbox → screenshot pixel → screen point → mouse click;
5. re-screenshot 2 s later to verify: button text gone = success; still present = try the next keyword
   (bounded to 3 rounds, rotating keywords, not an unbounded loop).
Coordinate chain (three segments, "全部已验证", `:14-17`):
Vision bbox (normalised, bottom-left origin) → screenshot pixels (top-left origin)
(`px = midX·W`, `py = (1 - midY)·H`) → screen points (CGEvent top-left)
(`point = pixel / backingScaleFactor`).
Additional constraint from `AIAgentPanel.swift:703`: "绝不点击任何「登录」按钮（否则会误点浏览器/QQ 等窗口的登录按钮）"
— a global ban on clicking anything labelled login, precisely to avoid hitting another app's login button.
`AIAgentPanel.swift:305` similarly bans F1–F12 because those are macOS system function keys the game never
receives.

## 8.13 Search tools — honesty and performance constraints

`WebSearch.swift` supplies `web_search` / `web_fetch` but `ToolRegistry.swift:22-23` states that the
registry itself implements no fetching. Full honesty/compliance constraints are catalogued in
SEC-07 §7.7.5; the performance item that belongs here: `WebSearch.swift:218-221` uses an **independent
ephemeral `URLSession`** that must not be shared with `captureQueue` or `aurora.quest.ocr` — a stated
performance red line, so search latency cannot influence capture frame rate or quest OCR.

## 8.14 Self-test surface

`LLMSelfTest.swift` (2183 lines) backs `--llm-selftest`, `--llm-vision-selftest`, `--llm-probe`,
`--llm-perf-selftest`, `--websearch-selftest`, `--tool-selftest`, `--tool-call-demo`
(all registered in `oneShotFlags`, SEC-06 §6.7.3). Its discipline rules (`:30`, `:1288`): unverified items
are marked 「未验证」 and counted as failures or flagged environment-limited — "绝不编造"; it must print the
actual session state and mark environment limits rather than disguising them as a pass. `:211-213`
enforces the repo red line that source must not hardcode API keys by scanning all descriptor headers and
baseURLs. `UNVERIFIED:` the individual assertion inventory of this file was not enumerated this session.

## 8.15 Pitfalls specific to this subsystem

1. **`plainAnswer` existed but was never wired** — a real model QA function with no production caller
   while the UI answered with canned text (`AgentChatService.swift:13-16`). The class of bug: a correct
   component that nothing calls, which no unit test catches because the component itself passes.
2. **Mounted tools are not implemented tools** — `isImplemented: skill.ported`
   (`ToolRegistry.swift:158`), 3 of 18 skills false.
3. **`sorted { ... return false }` is not an ordering** (`LLMHealth.swift:1058`) — explicit partitioning
   used instead.
4. **Client-side `Retry-After` / 429 must be distinguished from upstream errors** — 12-way taxonomy, and
   the comment requires classification per real observation rather than collapsing into "failed"
   (`LLMTransport.swift:32-44`, `WebSearch.swift:84`).
5. **Third-party gateway state flaps** — recorded as unresolved with both sides' evidence, and the
   explicit decision is to **not** encode a guess into the contract, leaving availability to live probing
   (`LLMBackend.swift:57-66`).
6. **Stale header diagrams**: `EmergencyTakeover.swift:9-10/:15/:19/:22` still say 20/45/5 Hz while the
   constants are 15/20/5 (`:55/:58/:60`). Fourth instance of the drift class in SEC-06 §6.10.
7. **Self-test parsing must equal production parsing** (`AuroraDriveApp.swift:1652`) and weak/tautological
   assertions only manufacture false greens (`:3603`, `:3856`).
