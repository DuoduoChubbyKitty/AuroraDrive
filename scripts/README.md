# scripts/ —— 工程化门禁与协作纪律

本目录是**基础设施**，不是业务代码。用户明确要求「不能牺牲工程化程度」「除掉所有补丁」——
多人并发改同一个 SwiftPM 模块产生的竞态，是**基础设施缺陷**，用锁解决是标准做法。

---

## 📜 构建纪律（多人协作必读）

```
· 改完立刻构建并回报绿色，然后才轮到下一个人验收
· 跑长任务（--map-selftest / --mc-map-bench / 门禁采集）前先取构建锁
· SwiftPM 是全模块编译 —— 一个人写坏，全组都验不了
```

**为什么**：SwiftPM 把整个 target 当一个编译单元。4 个人并发改文件 + 并发 `swift build` 会：

1. 互相打断：`error: input file '.../AuroraTheme.swift' was modified during the build`
2. **一个人写坏，全组都验不了** —— 任何一处 error 都让所有人的 `swift build` 失败
3. 更隐蔽的：并发跑基准会让 `loadavg` 冲高。实测 3 个 agent 同时
   `--mc-map-bench --iters 200`，各占 ~85% CPU，`loadavg` 冲到 **5.15 / 8 核** ——
   此时**任何耗时类数字都不可比**，「优化前后」的对比全部作废。

---

## 🔧 脚本清单

| 脚本 | 作用 | 退出码 |
|---|---|---|
| `build-lock.sh` | 原子构建/验收锁（`mkdir` 实现，bash 3.2 无 `flock`） | 3 = 拿不到锁 |
| `perf-snapshot.sh` | 七维度性能/质量快照采集 → JSON | 0 正常 |
| `regression-gate.sh` | 七维度「零劣化」门禁，任何劣化非零退出 | 0 通过 / 1 劣化 / 3 锁冲突 |
| `check-package-sources.sh` | 校验 `Package.swift` 与磁盘一致（防漏登记 / 孤儿文件 / unhandled） | 0 一致 / 1 有差异 |

### `build-lock.sh`

```bash
bash scripts/build-lock.sh acquire "阶段A验收"   # 拿不到 → 退出码 3
bash scripts/build-lock.sh release
bash scripts/build-lock.sh status
bash scripts/build-lock.sh run "原因" -- <命令...>   # 自动加锁/解锁
```

在脚本里：
```bash
bash scripts/build-lock.sh acquire "regression-gate" || exit 3
trap 'bash scripts/build-lock.sh release' EXIT
```

**设计**：
- `mkdir` 是原子的 —— bash 3.2 没有 `flock` 命令
- 锁目录里写 `owner`（pid / 时间 / 主机 / 用户 / 原因 / cwd），便于判断谁持有
- 残留锁超过 **15 分钟** → **只提示，不自动删**（万一真的还在跑）
- 持锁进程已死 → 提示可安全清理，仍不自动删（保守）
- 锁路径：`${TMPDIR:-/tmp}/aurora-build.lock`（可用 `AURORA_BUILD_LOCK` 覆盖）

### `perf-snapshot.sh`

```bash
bash scripts/perf-snapshot.sh <二进制> <输出.json> [标签]
```

采集七个维度的指标并落成 JSON，原始日志存到 `<输出目录>/raw/<标签>/`：

| 维度 | 来源 | 指标 |
|---|---|---|
| 1 帧率/频率 | `--mc-map-bench` | 各视野档 ①/②/③ 的 avg/p50/p95/max/冷启 |
| 2 输出频率 | `--perf-selftest` | tick 提交 Hz、各模型出结果 Hz + 推理计数 |
| 2b 推理成本 | `--perf-selftest` | `infer.*` 的 p50/p95/p99/max/mean |
| 3 画质 | `--mc-map` | PNG md5 + 64×64 像素指纹 + 颜色数 |
| 4 模型质量 | `--perf-selftest` + 各 `*-selftest` | R2 检测框数、R3 掩码精度、各自检失败标记 |
| 5 线程数 | `ps -M` 采样 | 峰值线程数 |
| 6 内存 | `--map-selftest` T4/T5 | 首帧加载/渲染/缓存命中、RSS 增长、底图取图耗时 |
| 7 工程化 | `swift build` + `check-package-sources.sh` | unhandled、警告数、error 数 |

**纪律**：耗时类数字**必须带负载一起看**。快照里记录了 `load.load1 / ncpu / oversub`，
`oversub > 1.5` 时打 `timing_unreliable: true`。

### `regression-gate.sh`

```bash
bash scripts/regression-gate.sh --freeze      # 冻结当前状态为参考基线
bash scripts/regression-gate.sh               # 每次优化落地后跑
bash scripts/regression-gate.sh --baseline A.json --current B.json   # 只比快照
bash scripts/regression-gate.sh --allow-image-change                 # 画质项降级为 WARN
```

判据（全部为「不得劣化」）：

| 维度 | 判据 |
|---|---|
| 1 帧率 | p50 ≤ 基线 ×1.10，p95 ≤ 基线 ×1.15 |
| 2 输出频率 | Hz 与推理计数 ≥ 基线 ×0.95 |
| 2b 推理成本 | `infer.*` p50 ≤ ×1.10，p95 ≤ ×1.15 |
| 3 画质 | 64×64 像素指纹与 md5 **完全相等**（除非 `--allow-image-change`） |
| 4 模型质量 | R2/R3 不得下降；自检不得新增失败标记 |
| 5 线程数 | 峰值 ≤ 基线 ×1.10 且 ≤ +2 |
| 6 内存 | RSS 增长 ≤ ×1.5 且 < 50MB；底图取图 ≤ ×1.20 |
| 7 工程化 | unhandled = 0、error = 0、警告数不增、`check-package-sources.sh` 通过 |

**注意**：任一侧 `timing_unreliable` 时，耗时类 FAIL 可能是**假红灯**（机器忙），
门禁会打印警告但仍给出结论 —— 请空载重跑确认。

### `check-package-sources.sh`

```bash
bash scripts/check-package-sources.sh                 # 校验，0=一致 1=有差异
bash scripts/check-package-sources.sh --gen-exclude   # 重新生成 exclude 块
```

六项检查：sources 路径存在 / `Sources/AuroraDrive/**/*.swift` 全被编译 /
`Sources/` 无孤儿 / 声明的 sources 都在磁盘 / 非源码文件在 exclude /
顶层条目在 exclude。

---

## 🧭 负载归一化（A14）

`MapSelfTest.swift:109-141` 已实现：`系数 = clamp(loadavg(1min) / 活跃核数, 1, 8)`。
空载时系数 = 1（阈值原样，真退化照样抓得住）；高负载时阈值按系数放宽，
避免「机器忙」被误判成「代码退化」。

**尚未覆盖的时间门禁**（待推广）：
- `PerfSelfTest.swift` —— 0 处负载归一化
- `RealShotSelfTest.swift` —— 0 处

`regression-gate.sh` 自身是**负载感知**的：把两侧 `load.oversub` 打进报告，
并在 `>1.5` 时标注 `timing_unreliable`。

---

## ⚖️ 量具可比性闸（2026-10-05）

`scripts/paired-ab.sh` 在**任何测量之前**校验两端二进制的**夹具指纹**。
不一致 → 退出码 **4**，拒绝给数字。

**为什么必须有**：实测事故 —— `HEAD(preA) vs 当前` 的配对 A/B 报
「①仅底图 **+60.0%**」「③Canvas+聚类 **+170.6%**」，判「❌ 显著劣化」。
真相**不是变慢，是换了把尺子**：

| | 夹具 | 测的路径 | 同二进制实测 |
|---|---|---|---|
| preA（旧） | `.offset(0.5px)` | 击不穿 4px 量化 → **缓存命中**后光栅化 | ~8.5 ms |
| 当前（新） | `AURORA_BENCH_DRAG_PX=8` | **真冷路径**平移 | ~14.6 ms |

同二进制内尺子差异：`drag=0 → 10.0ms`，`drag=8 → 14.6ms`（单调，距离越远越慢）。
所以那份 +60% 主要是**夹具语义变更**，属于不可比。

**探针**：`AURORA_BENCH_DRAG_PX`（新夹具的编译期指纹，用 `strings` 探测）。

> ⚠️ **改夹具语义时必须同时更新这个探针**，否则闸门失效。
> 这一条是**结构性**的：闸门靠一个常量指纹工作，没有它就只能靠人记得。

**实现坑（勿重犯）**：第一版用 `strings X | grep -q PAT && probe=1`，
在 `set -o pipefail` 下**静默失效** —— `grep -q` 命中即退出，
`strings` 收到 SIGPIPE（141），pipefail 取到非零，`&&` 右侧永不执行。
于是闸门明明没生效，还打印「✅ 两端夹具指纹一致」。**又一处假绿。**
改用 `$(... | grep -c PAT || true)` + 数值比较。

## 📉 实际意义阈值（2026-10-05，防假红灯）

符号检验只看**方向一致性**，不看幅度。零假设对照（同一个二进制 A vs A，
6 线程负载）实测：`+0.060ms / +0.5%` 被旧逻辑判「❌ 显著劣化」——
**0.5% 的抖动只要方向稳定就会稳定飘红**。
一个总喊「狼来了」的门禁没人会看，真劣化（+56%）反而失去信号价值。

**修法**：显著劣化需**同时**满足方向一致 **且** 幅度过
`max(相对 3%, 绝对 0.05ms)`。取 `max` 是刻意保守 ——
宁漏判小幅劣化（由 `regression-gate.sh` 的高负载绝对值栏兜住），
绝不制造假红灯。

自测（`--selftest`）用两条**互相牵制**的用例把这个阈值钉死：
- 噪声级 `0.5%` → **必须**退出 0（否则又开始喊狼来了）
- 真劣化 `+4%` → **必须**退出 1（否则阈值成了新的掩盖手段）

## 🛡️ C7 路况观测门守卫（2026-10-05，安全缺陷）

`tools/check-c7-gate.sh` —— 源码级守卫，含 3 条负向对照。

**守的缺陷**：`§4.4` 自动速度的路况判定门原本写成
`if autoSpeedEnabled, isDriving, !unlimitedLockedByUser`，
把**整块路况判定**包住 → 用户把限速滑块拉到底（不限速）后
`roadCondition` 永不再更新 → `needsTakeover` 恒 false →
**接管告警横幅永不显示**。而「我刚决定不限速」恰恰最该提醒用户。

**为什么必须源码级**：这条缺陷**测不出来** —— `--limit-selftest` 已覆盖
`autoSpeedTarget` 全部优先级分支且全绿，但门一旦被放回调用方，
**每一个断言都仍然通过**（那叫「恰好通过」）。纯函数级自测
**结构上**看不见调用点的条件。

**修法**：门**下沉**而非删除 —— `ControlWiring.applyRoadCondition` 里
`guard !unlimitedLockedByUser`，位置在 `roadCondition = rc` **之后**，
所以路况状态与告警照常更新，只有限速下发被挡。

**A1 的教训（旁证也会被写坏）**：第一版 A1 是「全文件 grep 该纯函数 ≥1 处」。
随后为验证 C7 在 `--limit-selftest` 里加了 3 条自测断言 —— 它们也调用该函数。
于是负向对照①（退回内联写法）**不再被抓住**：计数从 1 变 3，照样通过。
现在 A1 严格限定在 `§4.4` 段内查，不查全文件。

**自测的教训（注入静默失配 = 假绿）**：负向对照第一版用 `str.replace()`
且不校验返回值，找不到目标就什么都不做还退出 0 → 「坏样本」其实是好样本，
对照永远通过。现在注入用正则 + `re.subn` 并**硬断言 n==1**，失配直接报错。

---

## 🎯 生产主循环整圈基准（`--tick-bench`，2026-10-05）

**补的盲区**：`tick.total` 探针早就在 `tick()` 里（`defer` 结算，覆盖所有 return
路径），但**没有任何离屏夹具能驱动真实 `tick()`**：

| | 为什么不产出 `tick.total` 样本 |
|---|---|
| `--perf-selftest` | 自建引擎和自己的循环，**根本不调用 `tick()`**；它的 `tick.loop` 是自检夹具口径 |
| `--tick-profile` | 只读**本进程** `PerfBus`，而生产 tick 由 SwiftUI Timer 驱动 → 另起进程读不到 |

结果：有一堆分段（`tick.consumeFrame` / `tick.opticalflow` / …），
却**没有一个可信的主线程整圈数**。`--tick-bench` 主动驱动真实 `tick()` 补上它。

```
AURORA_UI_LOCAL=1 .build/scratch/release/AuroraDrive --tick-bench --seconds 6
bash scripts/paired-ab.sh <A> <B> 6 --load 6 --metric tick   # 跨二进制配对
```

**同进程 A/B**：跑两档（`.ayolom` 生产默认 / `.legacy` 优化前行为），
唯一变量是感知档位 → 直接量出 A2 的主线程收益。

### ⚠️ 安全：两条注入路径都必须堵死

`tick()` 里有**两条**按键注入路径，只堵一条不够：

1. `applyCommand`（真按键）—— 由 `mayInjectKeys = isDriving && !expertMode && !controlDisabled` 把守
2. `releaseAllIfNeeded()`（松键）—— **`controlDisabled` 分支里仍会发 keyUp**，
   且进程刚起时 `lastFullReleaseAt == 0` → **首帧必走 `releaseAll()`**，真发 6 个 CGEvent

所以夹具强制 `controlDisabled = true` **且** `benchSuppressAllInjection = true`
（后者是"连松键也不发"的硬开关），并**断言两条同时成立**才继续，
否则直接退出、不做任何测量。夹具可能在用户正开着游戏时运行，不允许有任何注入。

### ⚠️ 读数红线：绝对数不可跨时段比

实测：**同一份二进制、同一台机器**，在数小时重负载前后相差 **2~2.5 倍**：

| 指标 | 重负载前 | 重负载后 |
|---|---|---|
| `opticalflow` p50 | 2.53 ms | 6.4 ms |
| `infer.yolopx` p50 | 16.4 ms | 22.6 ms |

与代码无关，是热/争用状态。所以：

- **本夹具只用于同一会话内的 A/B 归因**（同进程、背靠背、唯一变量）
- **跨二进制对比必须走 `paired-ab.sh --metric tick`**（逐轮交替配对，抵消漂移）
- 任何"优化了 X%"的说法，只有在**同一会话的配对**里才成立

### 量具闸（`--metric tick`）

`paired-ab.sh` 会先探两端是否认识 `--tick-bench`，不一致直接**退出 4**。
没有这道闸的后果实测过：拿不认识该 flag 的老二进制跑配对，
它会以 **GUI 模式挂死**（跑了 10 分钟没退）。

**闸门自身踩过两个坑，都已写进自测**：
- `grep -q` + `pipefail` → SIGPIPE(141) → `&& probe=1` 永不执行（静默失效还打印 ✅）
- `grep -c '--tick-bench'` → 被当成 grep 长选项 → 报错被 `|| true` 吞掉 → 两端都算 0
  → 判定"一致"放行。**修法：模式一律用 `-e` 传，且探针算不出来时硬失败。**
