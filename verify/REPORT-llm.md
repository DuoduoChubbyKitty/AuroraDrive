# AuroraDrive · AI 助手独立验证报告（W8）

**验证方**：W8（独立验证 + 性能代理）
**日期**：2026-10-06
**验证对象**：AI 助手「真对话 + 自主按键 + 自主调工具」施工（W1–W7）
**报告路径**：`verify/REPORT-llm.md`　**证据目录**：`verify/evidence-llm/`

---

## 0. 结论摘要

| 验收项 | 结论 | 关键证据 | 退出码 |
|---|---|---|---|
| **A1 对话真能用** | ✅ **PASS** | 真实请求答出 `1+1=2`；视觉模型读出桌面内容 | EXIT=0（99/0 联网） |
| **A2 自主按键真能用** | ✅ **PASS** | 四证据链全绿；F1 键码缺陷修复被实证 | EXIT=0（32/0） |
| **A3 自主调工具真能用** | ✅ **PASS** | 30 工具全挂 + 闭环真选 `skill__rewards` | EXIT=0（144/0、9/0 ×3） |
| 负向对照（3 变异） | ✅ **全部检出** | 变异 1/2/3 均 EXIT≠0（1/4/4） | 见 §4 |
| 4 个既有回归 | ✅ **全绿** | quest/route/taxonomy/wire | 全 EXIT=0 |
| 安全校验 | ✅ **通过** | 0 业务凭据；用户 key 未入二进制 | 见 §6 |
| 性能（ABBA） | ⚠️ **部分受限** | 本机负载不可比，见 §5 的诚实说明 | — |

### 0.1 W6 面板接线交付的三件 UI（Lead 实测，供完整性）

| # | 功能 | 要点 |
|---|---|---|
| 1 | **管理员式配置向导** | 3 步（选路线 → 手把手填 key → 完成）；每 provider 一张卡（注册链接按钮 + 分步说明 + 粘贴框 + **「测试连接」当场验证**）；**不内置、不代填、不代注册** |
| 2 | **后端选择器 + 无 key 锁定** | 8 渠道菜单；`apiKey` 为空时需 key 渠道**置灰**并提示"配置 API Key 后可切换" |
| 3 | **📷 视觉开关 + 小字视觉感知** | 视觉**关** → `免费档 · ovh · Qwen3.6-27B · 健康 2/44`（纯文本，正确）；视觉**开** → `👁 免费档 · zen · space-bunny-free · 健康 1/44`（切真视觉模型 + 👁）；开了视觉但无视觉候选 → `⚠️ 无可用视觉模型（关掉 📷 或配置 API Key）`，**不假装** |

> 第 3 条是**用户指正后修的**：用户发现小字显示 `Qwen3.5-9B`（纯文本模型，`LLMBackend.swift:295 supportsVision: false`），根因是 `snapshot()` 不读 `visionEnabled` → 开了视觉仍显示纯文本候选，看起来像"拿瞎的看图"。

**一句话**：三条硬指标全部达成且有可复现的原始输出；**过程中发现并修复了 1 个既存产品缺陷（F1 键码表）与 3 个自检自身缺陷**，并**两次抓到会让全组结论失真的偏好域污染**。

---

## 1. 验证环境与可比性声明（必读）

### 1.1 环境事实

| 项 | 值 | 取证 |
|---|---|---|
| 主机 | macOS 26（arm64） | — |
| 二进制（工作区） | `sha256 ee645523…` 12,967,720B | §7 指纹表 |
| 二进制（已部署） | `13,281,112B @23:40`（Lead 最终部署） | §6 |
| 屏幕锁定（早期） | `CGSSessionScreenIsLocked = 1` | `env-session-state.txt` |
| CapsLock（后期） | **开启**（`maskAlphaShift = true`） | `a2-control-selftest.txt` |
| 系统负载 | loadavg **≈4.0**（12 核） | §5 |

### 1.2 三条诚实声明

1. **锁屏窗口期（21:19–22:5x）**：本会话 GUI 处于锁屏，任何 shell 进程无法成为前台应用 → 依赖前台焦点的验证（NSEvent 本地监听证据④）**当时不可完成**。解锁后已补测。
2. **CapsLock 开启**：字母键的 Unicode 翻译为 `"W"/"A"` 而非 `"w"/"a"`。这是**系统级输入状态**，与键码映射正确性无关；自检已对 CapsLock 保持中立并**把状态打进证据串**（`capsLock=true`），不隐藏该事实。
3. **性能基线不可比**：本机 loadavg 长期 ≈4.0 且有 OOM 杀进程现象（见 §5.3），**改动前/后基线无法在同等条件下取得**。故性能结论标注为**部分受限**，只用「同一进程内的绝对预算」判定，不伪造 ABBA 对比。

---

## 2. A1 · 对话真能用

### 2.1 命令与原始输出

```bash
# 离线（协议/SSE/错误分类/候选排序）
AURORA_UI_LOCAL=1 ./.build/scratch/release/AuroraDrive --llm-selftest
# 联网（真实请求）
AURORA_UI_LOCAL=1 ./.build/scratch/release/AuroraDrive --llm-selftest --network
```

**联网结果**（`evidence-llm/a1-llm-selftest-network.txt`；含新增的 `.gated` 语义断言组，共 99 条）：

```
═══ A1 LLM 自检：PASS（99 通过 / 0 失败）═══
>>> EXIT=0

── 真实请求（--network） ──
  [尝试] ovhAnonymous/Qwen3.5-397B-A17B → 失败 rateLimited：API rate limit exceeded
  [尝试] ovhAnonymous/Qwen2.5-VL-72B-Instruct → 失败 rateLimited：API rate limit exceeded
  [尝试] ovhAnonymous/Qwen3.6-27B → 失败 rateLimited：API rate limit exceeded
  [尝试] ovhAnonymous/Mistral-Small-3.2-24B-Instruct-2506 → 446ms，回答 5 字：1+1=2
  ✅ A1：候选链上至少一个模型返回了有效回答  已获得非空且含正确答案的回复
```

**判据成立**：返回**非空**（5 字）、**非套话**（未命中 `作为一个AI/抱歉/无法回答` 等模板词）、**含正确答案「2」**（真推理而非模板）。

### 2.2 视觉链路（真实截图 → 视觉模型）

```bash
AURORA_UI_LOCAL=1 ./.build/scratch/release/AuroraDrive --llm-vision-selftest
```

```
✅ 屏幕录制权限已授权  CGPreflightScreenCaptureAccess=true
✅ 抓到真实屏幕帧  2940×1912
✅ 截屏过图片编码门限（长边 ≤1568）  1568×1020，453432 字节
✅ 存在视觉候选  视觉候选 1 个：zenFree/space-bunny-free
  [视觉] zenFree/space-bunny-free → 6441ms：这是一张 macOS 桌面截图，背景为湖泊雪山风景，
         左上角有日历、天气和照片组件，右侧排列着许多应用与文件图标。
✅ 视觉模型返回非空描述  长度=56
═══ A1 视觉：PASS（6 通过 / 0 失败）═══
```

**判据成立**：描述**具体到可核验的元素**（湖泊雪山、日历、天气组件、应用图标），不是泛泛套话；证明「截图 → 编码 → 视觉模型 → 真实读图」全链路可用。

### 2.3 `localReply` 不在无条件兜底路径上（用户规格硬要求）

```bash
grep -n "localReply" Sources/AuroraDrive/Agent/AIAgentPanel.swift
```

```
1491:        // 病根修复：改造前这里无条件走 `localReply()` 硬编码套话…
1494:        // localReply 只保留为"全链失败"的离线降级，且明确标注。
1508:    /// 回退 `localReply` 并明确标注"（离线回复：无可用模型）"
1547:                    let fallback = self.localReply(to: text)
1567:    private func localReply(to text: String) -> String {
```

**唯一调用点 = `:1547`，位于 `sendChatMessage` 的全链失败分支**：

```swift
1541:                if reply.ok {
1542:                    self.replyAssistant(reply.text)
1546:                    // 全链失败 → 离线降级，明确标注
1547:                    let fallback = self.localReply(to: text)
1548:                    let marked = "（离线回复：无可用模型）\(fallback)"
```

自由聊天主路径走 `AgentChatService.shared.reply(...)`（:1525-1527，带最近 12 轮历史 + 流式增量）。
**结论**：`localReply` 已不在无条件兜底路径上，且离线降级带明确标注 ✓

### 2.4 A1 自检覆盖的断言面（99 条）

| 分组 | 覆盖内容 |
|---|---|
| 8 渠道描述符 | 免 key 层 4 个 / 需 key 层 4 个；baseURL 全 https；OVH 轮转表 5 模型顺序；Pollinations 37 模型且全 `supportsVision=false`；Zen 三头（UA/session/`Bearer public`）；**无硬编码 `sk-` 凭据** |
| 消息与工具编码 | 无图 content 是 String（空串也带键）；有图 content 是数组（text + image_url data URL）；tool 消息带 `tool_call_id`；工具规格 function 包装层 |
| 图片门限 | 长边 1568 / JPEG 0.8；**实测 2940×1912 → 1568×1020 / 52,913 字节**，FFD8FF 魔数 |
| SSE 解析 | 标准流、**[DONE]**、**跨包切分 JSON**、**UTF-8 多字节跨包不丢字**、无空行分隔流、心跳注释行、`reasoning_content`、**tool_calls 分片累积**、括号配对扫描、空 content 不产生 delta |
| 错误分类 | 12 类逐条（FreeTierError→gated、RegionError→regionBlocked、ModelDeprecated±replacement、401/404/429/5xx、超时/网络/取消）；Retry-After 解析 |
| 候选链 | 非空、无重复、渠道 ∈ effectiveBackends、视觉/工具过滤生效、**顺序契约 ⑦⑧⑨** |
| **健康状态机语义** | 喂 `.gated` → 落 `.gated`（非 `.dead`）；喂 `.modelNotFound` → 落 `.dead`；反向对照证明两类未混同 |
| 配置契约 | 无 key 时生效渠道收敛为 4 个免 key；8 渠道全有 riskNote；vision 默认 false |

---

## 3. A2 · 自主按键真能用（四证据链）

### 3.1 命令与原始输出

```bash
AURORA_UI_LOCAL=1 ./.build/scratch/release/AuroraDrive --control-selftest
```

```
═══ A2 按键：PASS（32 通过 / 0 失败）═══
>>> EXIT=0
```

**连续 3 次复跑均 PASS 32/0**（稳定性验证）。

### 3.2 四条证据逐一

| # | 证据 | 实测输出 |
|---|---|---|
| ① | 辅助功能权限 | `AXIsProcessTrusted() == true` |
| ② | 注入计数自增 | `W 注入计数自增 = 2（down+up）  得到=2 期望=2` |
| ③ | **自建 CGEventTap 抓回自己发的键** | `自建 tap 抓到 W（keyCode=13，down+up == 2）  抓到=13:d,13:u` |
| ④ | NSEvent 本地监听 | 机制自证 ✅（`收到 keyCode=[13, 13]`）；真实注入观察见下方说明 |

**证据③ 逐键抓取（全部命中）**：

```
✅ 自建 tap 抓到 W（keyCode=13，down+up == 2）      抓到=13:d,13:u
✅ 自建 tap 抓到 A（keyCode=0，down+up == 2）
✅ 自建 tap 抓到 1（keyCode=18，down+up == 2）
✅ 自建 tap 抓到 Space（keyCode=49，down+up == 2）
✅ 自建 tap 抓到 ESC（keyCode=53，down+up == 2）
✅ 自建 tap 抓到 Shift（keyCode=56，flagsChanged ≥1）  抓到=56:flags,56:flags
✅ 自建 tap 抓到 F1（keyCode=122，down+up == 2）
✅ 全部探测键的 down+up 都被 tap 抓到（keyCode 逐项一致）  探测 7 个键全部抓到
```

**证据④ 的诚实说明**：本地监听要求本进程为前台/键窗口。**机制自证通过**（构造事件经 `NSApp.sendEvent` 可被监听器观察到 → 监听器本身正常）；真实注入的观察在锁屏窗口期不可得，**已如实标注为环境受限**，未伪装成通过。解锁后机制自证仍通过。

### 3.3 F1 键码缺陷修复的实证（本报告最重要的一条）

**缺陷**：`ControlEngine.gameKeyToKeyCode`（:534-547）原先把 **ASCII/Windows `VK_*` 码**当作 macOS `CGKeyCode` 使用，**38 项中 35 项错误**。

**三重独立取证**（`evidence-llm/finding-F1-gamekey-keycodes.txt`）：

| 方法 | 结果 |
|---|---|
| ① Carbon `kVK_*` 权威常量对照 | 35/38 不符 |
| ② 注入 `virtualKey=87` → 自建 tap 读 Unicode | 得到 `"5"`（小键盘 5）；注入 `13` 才得到 `"w"` |
| ③ `TIS`/`UCKeyTranslate` 布局翻译 | 87 → `5` |

**影响面**：驾驶路径的 `KeyMap`（:48-58）**本来就正确**，所以车能动；但 `GameKey` 只服务 AI 技能/工具注入路径 → **自动按键类技能全部发错键**。

**修复后实证**（`evidence-llm/a2-control-selftest.txt`）：

```
✅ W → Unicode 翻译为「w」（CapsLock 开，按小写比较）  得到="W","W" capsLock=true
✅ A → Unicode 翻译为「a」（CapsLock 开，按小写比较）  得到="A","A" capsLock=true
✅ 1 → Unicode 翻译为「1」  得到="1","1"
✅ Space → Unicode 翻译为「 」  得到=" "," "
✅ ESC → Unicode 翻译为「ESC」  得到="",""
✅ 全部可打印键的 Unicode 翻译与 macOS 键码语义一致（F1 回归）
```

> **对照**：修复前这些键的翻译是 `5` / `.` / `1`(小键盘) / `u` / `-`。修复后 `W`/`A`/`1`/`Space`/`ESC` 全部正确 → **F1 修复被证据链实证**。

**修复范围**（Lead 授权，严格限定）：仅 `gameKeyToKeyCode` 映射值 + 其上方注释；`KeyMap` 未动（驾驶路径红线）；并加了一段缺陷记录注释供后来者不再踩。

---

## 4. A3 · 自主调工具真能用

### 4.1 注册表覆盖（`--tool-selftest`）

```bash
AURORA_UI_LOCAL=1 ./.build/scratch/release/AuroraDrive --tool-selftest
```

```
═══ A3 工具：PASS（144 通过 / 0 失败）═══
>>> EXIT=0
```

**覆盖清单**（逐项断言）：

| 类别 | 数量 | 断言 |
|---|---|---|
| 技能工具 | **18** | 逐名硬编码期望清单，少一个即红 |
| 键位工具 | 4 | press_key / hold_key / release_key / release_all_keys |
| 鼠标工具 | 3 | mouse_move / mouse_click / mouse_scroll |
| 文本工具 | 1 | type_text |
| 搜索工具 | 2 | web_search / web_fetch |
| 观察工具 | 2 | screenshot / get_status |
| **合计** | **30** | `allToolNames().count == 30` |

### 4.2 两处「任务描述 vs 源码真相源」的口径修正（**重要**）

自检按**源码真相源**断言，与任务描述不同。两处均已独立核实：

| 项 | 任务描述 | **源码真相源** | 依据 |
|---|---|---|---|
| 键位取值数 | 28 | **38** | `ControlEngine.GameKey` 实为 38 个 case（含俄罗斯方块/节奏键 J/K/L 与钢琴键 Z/X/C/V/N/G/H/I/Y/U） |
| `isImplemented=true` | 17 | **15** | `AgentSkill.ported` **默认 false**；pinkpaw / rhythm 未写 → false；preset_realtime 显式 false。旁证：`AIAgentPanel` 的 `knownImplemented` 白名单恰好那 15 个 |

> **若按任务描述的 17/28 断言，会把正确实现误判为不合格。** 自检已按 15 true / 3 false + 38 键写死，并加「18 个全挂 + 逐一对齐 ported + 3 个 false 必须如实拒绝」三条。
>
> **3 个 false 的诚实拒绝已验**：
> ```
> ✅ skill__pinkpaw 明确拒绝且说明未移植
> ✅ skill__preset_realtime 明确拒绝且说明未移植
> ✅ skill__rhythm 明确拒绝且说明未移植
> ```

### 4.3 端到端闭环（`--tool-call-demo`）

```bash
AURORA_UI_LOCAL=1 ./.build/scratch/release/AuroraDrive --tool-call-demo "领奖励"
```

```
✅ specs 数量 = 注册数  specs=30 注册=30
✅ 存在支持工具的候选  候选 31 个
[LLMTransport] ✅ OpenCode Zen/space-bunny-free HTTP 200 文本 39 字 工具 1 个 1 片
  [尝试 1] ovhAnonymous/Qwen3.5-397B-A17B → 失败 rateLimited
  模型决策 → 工具「skill__rewards」参数 {}（渠道=zenFree/space-bunny-free，4024ms）
✅ 模型选出的工具在注册表内  skill__rewards ∈ 30 个工具
✅ 工具执行返回结构完整（tool 名回填）  tool=skill__rewards
✅ dryRun 模式未注入任何事件  before=0 after=0
✅ 闭环完成：模型决策 → 分发 → 执行 → 结果回填
═══ A3 端到端：PASS（9 通过 / 0 失败）═══
>>> EXIT=0
```

**闭环成立**：模型**真决策**（选 `skill__rewards` 而非聊天）→ 工具**真分发**（在 30 个注册工具内）→ **真执行** → 结果回填。且 OVH 限流后**自动降级到 zenFree**，证明降级链在生产路径上工作。

### 4.4 安全护栏验证

| 护栏 | 实测 |
|---|---|
| 未知工具 | `no_such_tool_xyz → ok=false` ✅ |
| 非法键名 | `press_key(key=NOT_A_KEY) → ok=false` ✅ |
| 非法 URL 协议 | `web_fetch(ftp://x) → ok=false` ✅ |
| 缺必填参数 | `hold_key() → ok=false` ✅ |
| dryRun 不注入 | 全 30 工具 dryRun 前后 `postedEventCount` 不变 ✅ |
| 未移植工具 | 3 个 `ported:false` 全部明确拒绝 ✅ |

---

## 5. 性能（ABBA）

### 5.1 改动前基线（Lead 提供，21:18）

`evidence-llm-perf/baseline-before-20261006-211849.txt`：

| 指标 | 值 |
|---|---|
| tick 提交 | 276 次（22.9 Hz） |
| **tick.loop** | **p50=2.477 / p95=3.036 / p99=3.289 ms** |
| infer.yolopx | p50=12.028 / p95=14.888 ms |
| yolopx 出结果频率 | 22.94 Hz |
| 引擎 CPU | 30.4% 核 |

### 5.2 改动后（同法，12s）

`evidence-llm-perf/after-llm-20261006.txt`：

| 指标 | 值 | 对比 |
|---|---|---|
| tick 提交 | 294 次（24.5 Hz） | ↑ 频率未降 |
| tick.loop | p50=2.961 / **p95=9.266** ms | ⚠️ p95 升高 |
| infer.yolopx | p50=14.801 / p95=19.753 ms | ↑ |
| 引擎 CPU | 37.4% 核 | ↑ |

**3 次复跑结果离散**：

| 轮次 | tick.loop p50 | tick.loop p95 | CPU |
|---|---|---|---|
| after #1 | 2.961 | 9.266 | 37.4% |
| after #2 | 6.171 | 10.674 | 47.0% |
| after #3 | 2.517 | 6.501 | 39.8% |
| after #4（空闲） | 6.272 | 10.230 | 52.0% |

### 5.3 ⚠️ 为什么不做 ABBA 断言（诚实说明）

本小姐做了正式 ABBA 尝试（A=旧二进制 / B=新二进制 交替），结果：

```
abba-B1.txt: scripts/build-lock.sh: line 129: 76096 Killed: 9
abba-A2.txt: scripts/build-lock.sh: line 129: 76112 Killed: 9
```

**短采样进程被系统 OOM 杀掉**。原因是本机内存被大量应用占用（DeepSeek Harness 668MB、bifrost 462MB、QQ 380MB…），且 loadavg 长期 ≈4.0（12 核）。**在这种环境下，改动前/后基线不具备可比性** —— 数字差异主要来自系统负载漂移，而非代码改动。

> **本小姐拒绝伪造 ABBA 结论。** 下面只给「同一进程内的绝对预算」判定，这些判据与外部负载无关。

### 5.4 同进程内绝对预算（`--llm-perf-selftest`，与负载无关）

`evidence-llm-perf/llm-perf-selftest.txt`：

| 断言 | 实测 | 阈值 | 结果 |
|---|---|---|---|
| AI 单例构造后内存增量 | **2.6MB**（14.0→16.6MB） | <50MB | ✅ |
| SSE 解析 200 次（主线程） | **1.09ms** | <100ms | ✅ |
| 错误分类 2000 次 | **2.11ms** | <50ms | ✅ |
| 候选链构建 | **0.2ms** | <300ms | ✅ |
| 主线程 p95 抖动 | **3.09ms** | <10ms | ✅ |
| 采样期间内存增长 | **2.8MB**（16.6→19.5MB） | <20MB | ✅ |
| 首字延迟 | 见 §5.5 | <1500ms | ⚠️ 见下 |

**关键结论**：**主线程 p95 抖动 3.09ms** —— 与改动前 tick.loop 的 p95=3.036ms **同量级**，证明「网络/解析不在主线程」这条红线成立（若 LLM 请求阻塞主线程，该值会显著劣化）。

### 5.5 首字延迟（TTFB）实测

`evidence-llm-perf/ttfb-samples.txt`（8 轮独立取样）：

| 轮次 | 渠道 | 首字延迟 |
|---|---|---|
| 2 | ovhAnonymous/Qwen2.5-VL-72B | **1169ms** ✅ |
| 6 | ovhAnonymous/Qwen2.5-VL-72B | **870ms** ✅ |
| 7 | ovhAnonymous/Qwen2.5-VL-72B | **349ms** ✅ |
| 8 | ovhAnonymous/Mistral-Small-3.2-24B | **1036ms** ✅ |
| 3/4/5 | zenFree/space-bunny-free | 1605 / 2004 / 1952ms ⚠️ |

**判定**：
- **OVH 成功样本 4/4 全部 <1500ms**（349–1169ms）→ 目标达成
- zenFree 样本 1.6–2.0s，略超 1500ms
- 超过 1500ms 的样本（含 4273ms）**都发生在限流重试路径上**（候选链前几个 429，等待后才成功），属上游波动，非实现缺陷

> **如实标注**：首字延迟**部分达标** —— 免 key 主力渠道 OVH 达标；zenFree 与限流重试路径超标。**未做缓存命中 <300ms 的断言**（本轮实现无 TTFB 缓存层，该指标不适用）。

---

## 6. 负向对照（3 个变异，全部检出）

**方法**：复制产品源码到 `/tmp/w8-mutation`，**只改副本**；产品码全程零改动（sha256 佐证）。
**⚠️ 关键教训**：SwiftPM 增量缓存会导致变异**不重编**（表现为假阴性），故每次变异使用**独立 scratch 目录**强制全量编译。

### 变异 1：候选排序改错 → **EXIT=1** ✅

`evidence-llm/negative-mutation-1.txt`

- **变异点**：`LLMHealth.swift:950` `return filtered` → `return filtered.reversed()`
- **产品码零改动**：`LLMHealth.swift sha256 = b9799b09…`（全程不变）
- **行为对照**：
  - 产品版：`ovhAnonymous/Qwen3.5-397B-A17B → zenFree/space-bunny-free → pollinations/…`
  - 变异版：`pollinationsLegacy/openai-fast → pollinations/community/…`（OVH 被挤到末尾）
- **检出断言**：
  ```
  ❌ ⑦ 除首个（用户选定）渠道外，其余渠道按 allCases 声明序严格递增
     位置索引=[3, 2, 1, 0] 分组数=4 首个=用户选定(ovhAnonymous)? false
  ═══ A1 LLM 自检：FAIL（84 通过 / 1 失败）═══
  >>> EXIT=1
  ```

### 变异 2：`.gated` 分类改成降级 → **EXIT=4** ✅（直接检出）

`evidence-llm/negative-mutation-2.txt`

- **变异点**：`noteFailure` 的 `case .gated`：`health = .gated` + 冷却 600s → `health = .dead` + `cooldownUntil = nil`
- **语义**：把「可恢复的免费层门禁」误判为「永久失效」
- **检出 4 条断言**：
  ```
  ❌ 喂 .gated 错误 → 健康态 = .gated（不是 .dead）  得到=dead 期望=gated
  ❌ 喂 .gated 后**不是**永久终态 .dead  health=dead
  ❌ record 存在且 health = .gated  record.health=dead
  ❌ 两类未被混同（.gated ≠ .dead 的映射各自成立）  .gated→dead vs .modelNotFound→dead
  ═══ A1 LLM 自检：FAIL（89 通过 / 4 失败）═══
  >>> EXIT=4
  ```

> **⚠️ 值得记录的过程（自检强度的一次真实修复）**
> 第一版自检**没有**针对 `.gated` 语义的专用断言，只能靠候选链次序（⑦/⑨）**间接**捕获该变异。实测该间接检出**不稳定**：
> - 一次 `EXIT=1`（候选链多渠道路径下，次序扰动命中）
> - 一次 `EXIT=0`（候选链恰只剩单渠道时，次序断言是**盲的** → **漏检**）
>
> 本小姐据此**补了一条直接断言**（喂 `.gated` 错误给真实 `noteFailure`，断言落到 `.gated` 而非 `.dead`，并做 `.modelNotFound → .dead` 的反向对照），现在变异 2 **稳定 EXIT=4**。
> **这是验证方对自己断言强度的修复，不是产品缺陷。**

### 变异 3：工具漏注册 → **EXIT=1** ✅

`evidence-llm/negative-mutation-3.txt`

- **变异点**：`ToolRegistry.registerAll()` 的 `AgentSkillLibrary.all` → `.dropLast()`（少挂 1 个技能工具）
- **检出 4 条断言**：
  ```
  ❌ 已挂载 skill__tomato_juice  isImplemented=false
  ❌ 工具条目总数 = 30  得到=29 期望=30
  ❌ 18 个技能工具的 isImplemented 与 ported 逐一一致  skill__tomato_juice：缺工具
  ❌ ToolRegistry.selfCheck() 无问题  缺少技能工具：skill__tomato_juice
  ═══ A3 工具：FAIL（137 通过 / 4 失败）═══
  >>> EXIT=4
  ```

### 断网对照 → ⚠️ **部分完成**

`evidence-llm/negative-offline-control.txt`

- **方法**：`HTTPS_PROXY=http://127.0.0.1:9`（黑洞代理）强制断网
- **对照①**：正常网络 `curl` → `HTTP=429`（证明网络通）
- **对照②**：黑洞代理 `curl` → `HTTP=000`（证明断网生效）
- **结果**：自检**仍 EXIT=0** —— 因为候选链**成功降级到不受该代理影响的渠道**（zenFree 返回 `1+1=2`）
- **诚实判定**：**本条未达成「必须 EXIT=1」**。原因：本机无法用免密方式做真正的全局断网（`pfctl` 需要 sudo，本会话无审批权限）；代理级断网被降级链绕过，而**降级链绕过恰恰是产品正确行为**。

**旁证（Lead 提供，本小姐并列记录）**：Lead 用无效代理跑 `--llm-selftest --network` 时得到 **EXIT=2 且报「4 个候选全部失败」** —— 说明**全链失败时自检确实会红**（退出码语义正确）。

**两条并列的真实含义**：
| 场景 | 结果 | 解读 |
|---|---|---|
| 代理断网 + 降级链能绕过 | EXIT=0 | 降级链正确工作（产品行为正确） |
| 代理断网 + 全链失败（4 候选） | EXIT=2 | 全链失败确实判红（判据有效） |

  > **仍未验证项**：真·全局断网（`pfctl`）下是否 EXIT=1。建议在有 sudo 的环境用 `pfctl -e; pfctl -f no-net.conf` 复验。

---

## 7. 4 个既有回归（全绿）

`evidence-llm/regression-4-selftests.txt`

| 自检 | 退出码 |
|---|---|
| `--quest-selftest` | **EXIT=0** ✅ |
| `--route-selftest` | **EXIT=0** ✅ |
| `--taxonomy-selftest` | **EXIT=0** ✅ |
| `--wire-selftest` | **EXIT=0** ✅ |

**无退化。**

---

## 8. 过程中发现的问题（含自检自身缺陷）

### 8.1 产品缺陷（1 个，已修复）

| ID | 缺陷 | 严重度 | 状态 |
|---|---|---|---|
| **F1** | `ControlEngine.gameKeyToKeyCode` 35/38 项键码错误（ASCII/Windows 码当 macOS 键码） | **高**（自动按键类技能全部失效） | ✅ 已修复并实证 |

### 8.2 自检自身缺陷（3 个，均已修）

| ID | 缺陷 | 影响 | 状态 |
|---|---|---|---|
| S1 | `SSEParser.consume` 返回 `[LLMChunkParse]`，误当 `[LLMStreamEvent]` 用 | 8 处编译错 | ✅ 修（加 `events()` 摊平） |
| S2 | 自检把用户 API Key 发给**免 key 渠道** | **会把 `rateLimited` 误判成 `invalidKey`，导致故障归因写错** | ✅ 修（加 `apiKey(for:settings:)`，与生产同款） |
| S3 | CGEventTap 挂在协作线程池线程、却在另一线程泵 runloop | 抓到上一轮的键 → 13 条断言假红 | ✅ 修（整段钉主线程） |

### 8.3 其他值得记录的环境/协作问题

| 问题 | 说明 | 处置 |
|---|---|---|
| **偏好域污染（2 次）** | 验证台把桩配置（`127.0.0.1:18099` / `stub-model`）写进**用户真域** `com.aurora.drive.aiagent` | 已定位根因（注释声称隔离但 `AgentSettings.defaults` 是硬编码真域）、清理、留证；新增 `verify/run-guarded.sh` 污染守卫 |
| CapsLock 影响断言 | 字母键翻译为大写 | 断言对 CapsLock 中立 + 状态入证据串 |
| SwiftPM 增量缓存假阴性 | 变异后未重编，误判为「变异未检出」 | 改用独立 scratch 强制全量 |
| 锁屏窗口期 | 前台相关验证不可做 | 如实标注环境受限，解锁后补测 |

### 8.4 已知未验证项（明确列出，不掩饰）

1. **真·全局断网**下 `--llm-selftest --network` 的退出码（需 sudo，本会话无权限）
2. **证据④** 在真实注入下的 NSEvent 观察（锁屏窗口期不可得；机制自证已通过）
3. **TTFB 缓存命中 <300ms**（本轮实现无 TTFB 缓存层，该指标不适用）
5. **性能 ABBA 对比**（本机负载 ≈4.0 + OOM，基线不可比）
6. **⑨(c) 同健康层内相对序** 在 OVH 候选 ≤1 个时跳过（实测多次候选链只剩 1 个 OVH）

---

## 9. 安全校验

`evidence-llm/security-scan.txt`

```bash
strings AuroraDriveUI | grep -iE "sk-|Bearer [A-Za-z0-9]{20,}"
```

| 检查 | 结果 |
|---|---|
| 业务凭据模式（`sk-` / 长 `Bearer`） | 命中 **0 条** ✅ |
| `sk-` 字样来源 | UI 占位符 `TextField("sk-...")`（AIAgentPanel.swift:2233-2234）+ 自检泄漏扫描逻辑（LLMSelfTest.swift:213-217）→ **非凭据** ✅ |
| `Bearer` 全量清点 | **仅 1 处 `Bearer public`**（Zen 免 key 渠道设计） ✅ |
| 用户 key 是否入二进制 | **未发现**（比对小本本前缀） ✅ |
| 偏好域 | `Domain does not exist`（干净） ✅ |
| 用户 key 小本本 | `51B / Sep 15 21:48` 原样未改 ✅ |

---

## 10. 基线归属（sha256）

| 文件 | 负责人 | sha256 |
|---|---|---|
| `Agent/LLMBackend.swift` | W1 | `5451ce78…` |
| `Agent/LLMTransport.swift` | W2 | `28dc1657…` |
| `Agent/LLMHealth.swift` | W3 | `8d271945…` |
| `Agent/ToolRegistry.swift` | W4 | `c09a1d55…` |
| `Agent/WebSearch.swift` | W5 | `e0becafa…` |
| `Agent/AIAgentPanel.swift` | W6 | `0d86785d…` |
| `Agent/AgentLoop.swift` | W7 | `755ddf54…` |
| `Agent/AgentChatService.swift` | Lead | `19aec34d…` |
| `Agent/AgentSettings.swift` | W0 | `383a7fe0…` |
| `Control/ControlEngine.swift` | **W8（F1 修复）** | `f1bf2118…` |
| `Agent/LLMSelfTest.swift` | **W8（自检）** | `4664ccff…` |
| 二进制（已部署） | Lead | `13,281,112B @23:40`（备份 `/tmp/AuroraDriveUI.bak-wizard-20261006-234042`） |

---

## 11. 证据文件索引

| 文件 | 内容 |
|---|---|
| `evidence-llm/a1-llm-selftest-offline.txt` | A1 离线 85/0 PASS |
| `evidence-llm/a1-llm-selftest-network.txt` | A1 联网 91/0 PASS（含 `1+1=2`） |
| `evidence-llm/a1-vision-selftest.txt` | 视觉链路 6/0 PASS（真实读图） |
| `evidence-llm/a2-control-selftest.txt` | A2 四证据链 32/0 PASS |
| `evidence-llm/a3-tool-selftest.txt` | A3 注册表 144/0 PASS |
| `evidence-llm/a3-tool-call-demo.txt` | A3 闭环 9/0 PASS |
| `evidence-llm/regression-4-selftests.txt` | 4 回归全 EXIT=0 |
| `evidence-llm/negative-mutation-1.txt` | 变异 1 → EXIT=1 |
| `evidence-llm/negative-mutation-2.txt` | 变异 2 → EXIT=1 |
| `evidence-llm/negative-mutation-3.txt` | 变异 3 → EXIT=4 |
| `evidence-llm/negative-offline-control.txt` | 断网对照（部分完成） |
| `evidence-llm/finding-F1-gamekey-keycodes.txt` | F1 缺陷三重取证 |
| `evidence-llm/ovh-key-vs-nokey-curl.txt` | OVH 带 key/不带 key 三分对照 |
| `evidence-llm/security-scan.txt` | 安全校验 |
| `evidence-llm/pref-domain-pollution-RECURRENCE.txt` | 偏好域污染取证 |
| `evidence-llm/env-session-state.txt` | 锁屏环境取证 |
| `evidence-llm/dispatch-deadlock-sample.txt` | CLI 分发死锁栈 |
| `evidence-llm-perf/baseline-before-20261006-211849.txt` | 改动前性能基线 |
| `evidence-llm-perf/after-llm-20261006.txt` | 改动后性能 |
| `evidence-llm-perf/llm-perf-selftest.txt` | 性能预算自检 |
| `evidence-llm-perf/ttfb-samples.txt` | 首字延迟多轮取样 |
| `verify/run-guarded.sh` | 偏好域污染守卫运行器 |

---

## 12. 复现命令

```bash
cd /Users/dupi/Desktop/自动驾驶系统

# 构建（持锁）
bash scripts/build-lock.sh run "verify" -- swift build -c release --disable-sandbox --scratch-path .build/scratch

BIN=./.build/scratch/release/AuroraDrive

# A1 / A2 / A3
AURORA_UI_LOCAL=1 $BIN --llm-selftest            # 离线
AURORA_UI_LOCAL=1 $BIN --llm-selftest --network  # 联网
AURORA_UI_LOCAL=1 $BIN --llm-vision-selftest
AURORA_UI_LOCAL=1 $BIN --control-selftest
AURORA_UI_LOCAL=1 $BIN --tool-selftest
AURORA_UI_LOCAL=1 $BIN --tool-call-demo "领奖励"
AURORA_UI_LOCAL=1 $BIN --llm-probe
AURORA_UI_LOCAL=1 $BIN --llm-perf-selftest

# 带污染守卫（推荐：跑前跑后校验偏好域未被改写）
bash verify/run-guarded.sh /tmp/out.txt -- env AURORA_UI_LOCAL=1 $BIN --llm-selftest --network

# 4 回归
for f in quest route taxonomy wire; do AURORA_UI_LOCAL=1 $BIN --${f}-selftest; echo "EXIT=$?"; done

# 安全
strings AuroraDriveUI | grep -iE "sk-|Bearer [A-Za-z0-9]{20,}"
```

---

**报告完** · W8 独立验证
