# YOLOPX · W3 接线最终化与根因修复报告（任务 t28）

> 契约（队长 2026-09-26 修订版）：修复 `loadIfNeeded` 单发加载导致的**引擎永久未加载**根因；
> `pal8_detfp` 置候选首位；残缺候选可跳过；`.mlpackage` 假回退处理；注释更正；
> 用 **App 同一入口** 实测证明加载成功（Python 口径不算证据）；fail-open 语义不变；编译 EXIT=0。
> 执行：swift-fixer。**时间：2026-09-26 23:06–23:25（GMT+8）。**

---

## 0. 一句话结论

**根因已修：YOLOPX 从「从未加载成功」变为「稳定加载精度冠军 `pal8_detfp`」。**
`swift build -c release` EXIT=**0**；用 App 同款 API 实测 **PASS**；
且**改前/改后对照已实测**（见 §3）。fail-open 语义**未改变**。

---

## 1. 根因（为什么改候选顺序本身修不好）

```swift
// 修改前 —— YolopxEngine.swift
private var modelURL: URL {
    for name in Self.modelCandidates {
        let u = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }   // ← 只看「存在」
    }
    ...
}

func loadIfNeeded() {
    do {
        let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        isLoaded = true
    } catch {
        errorMessage = "..."      // ← 失败即终止，**不试下一个候选**
        isLoaded = false
    }
}
```

**两个缺陷叠加成致命 bug**：

1. `modelURL` 用 `fileExists` 选文件 —— **存在 ≠ 可加载**。
   磁盘上 `yolopx3_w8a16.mlmodelc` **目录存在**，但只有 `weights/weight.bin`，
   缺 `model.mil` / `metadata.json` / `coremldata.bin` → `MLModel(contentsOf:)` 直接抛错。
2. `loadIfNeeded()` 是**单发 try/catch** —— 挑中坏文件就 `isLoaded = false`，
   **永不尝试其余候选**（`loadRetryCooldown` 只是稍后重试同一个坏 URL）。

→ 后果：**YOLOPX 三头感知在运行时从未上线**。
`isLoaded=false` → det 回落 yolo26s；`laneMask`/`drivableMask` 恒为 `.empty` → MaskOverlay 不绘；
`isDegraded` 初值即 `true`（`:207`）→ LaneFallback 全程不介入。

**因此：只把 `pal8_detfp` 挪到候选首位是无效修复**——它只会让 `modelURL` 选中另一个文件，
若那个文件也坏了，结果一样是永久失败。**必须让"加载失败"能继续换候选。**

---

## 2. 修改内容（文件:行 + 修法）

仅改一个文件：`Sources/AuroraDrive/Inference/YolopxEngine.swift`

### 2.1 新增状态字段（`:196-201`）

```swift
/// **实际加载成功**的模型文件名（未加载时为 nil）。必须区别于「候选表里哪个文件存在」。
private(set) var loadedModelName: String?

/// 候选逐个尝试的记录（`候选名: 存在性/编译/加载 结果`），失败时也能看清卡在哪。
private(set) var loadAttemptLog: [String] = []
```

`loadedModelName` 让"到底加载到哪一个"可被诊断与告警读取，而不是靠文件名**猜测**。

### 2.2 候选表重排（`:301-315`）—— `pal8_detfp` 置首位

> **⚠️ 本节在正式提交轮做过一次修正**：初版表里含两个**磁盘上并不存在**的文件名
> （`yolopx3_int8.mlmodelc`、`yolopx3_fp16.mlmodelc`），违反契约「不许写磁盘上不存在的模型文件名」。
> 已用 `ls` 逐条核对后**移除**，最终 6 条**全部真实存在**（见 §2.2.1）。

| 顺序 | 候选 | 磁盘 | 依据 |
|---|---|---|---|
| 1 | **`yolopx3_pal8_detfp.mlmodelc`** | ✅ | **精度冠军**：det 100% / da IoU 0.9930 / ll P99.28·R98.15；结构完整、免编译 |
| 2 | `yolopx3_pal8_detfp.mlpackage` | ✅ | 同上，包形态（需编译） |
| 3 | `yolopx3_w8a16.mlmodelc` | ✅ | 8 位次选，**det 仅 85%**；**当前结构残缺，会被跳过**（留档待 C1 修复） |
| 4 | `yolopx3_w8a16.mlpackage` | ✅ | det 85% |
| 5 | `yolopx3_int8.mlpackage` | ✅ | **ll recall 仅 3.98%（架构性失败）**，靠后 |
| 6 | `yolopx3_fp16.mlpackage` | ✅ | 兜底，违反「只用 8 位」，会告警 |

**已移除（磁盘不存在）**：`yolopx3_int8.mlmodelc`、`yolopx3_fp16.mlmodelc`。
**磁盘存在但刻意未纳入**：`yolopx3_w8a16_detfp.mlpackage`（w8a16 权重 + det 头 fp16）
—— **精度未记录，不凭推测接入生产回退链**，仅留档待实测数据。

#### 2.2.1 候选表磁盘存在性核验（契约硬约束）

```
候选数: 6
  ✅ yolopx3_pal8_detfp.mlmodelc
  ✅ yolopx3_pal8_detfp.mlpackage
  ✅ yolopx3_w8a16.mlmodelc
  ✅ yolopx3_w8a16.mlpackage
  ✅ yolopx3_int8.mlpackage
  ✅ yolopx3_fp16.mlpackage
不存在的条目数: 0
```

### 2.3 核心修复：逐候选实测加载（`:329-377`）

```swift
private func loadFirstUsableModel() -> (model: MLModel, name: String)? {
    for url in candidateURLs {
        guard FileManager.default.fileExists(atPath: url.path) else { log.append("✗ 不存在"); continue }
        var loadURL = url
        if name.hasSuffix(".mlpackage") {
            do { loadURL = try MLModel.compileModel(at: url) }   // ← .mlpackage 假回退修复
            catch { log.append("✗ 编译失败"); continue }
        }
        do { return (try MLModel(contentsOf: loadURL, configuration: config), name) }
        catch { log.append("✗ 加载失败: \(error.localizedDescription)"); continue }  // ← 继续下一候选
    }
    return nil
}
```

修复三点：① 每次尝试都是**真实加载**（不只是 `fileExists`）；② 失败**继续**而非终止；
③ 每步原因记入 `loadAttemptLog`。

### 2.4 `.mlpackage` 假回退修复（`:356`）

补 `MLModel.compileModel(at:)`（与 `SpeedOCRReader.swift:282/301` 同法）。
**修复前**：候选表里 3 个 `.mlpackage` 即使被选中也必然失败——`MLModel(contentsOf:)` 不能直接吃 `.mlpackage`，而本引擎从不调 `compileModel`（全仓库仅 SpeedOCRReader 调）。**现在是真回退。**

### 2.5 follow-on 修补（因删除 `modelURL` 而必须同步）

- `isUsingFp16Fallback`（`:323`）：改读 **`loadedModelName`**（实际命中）而非 `modelURL`（候选表选中）。
- `reloadModel()`（`:349-358`）：新增清空 `loadedModelName` / `loadAttemptLog`，避免热替换后残留旧状态。
- `diagnosticSummary()`（`:790+`）：`模型:` 行改报实际加载名（未加载时明示「（未加载成功）」，不再显示误导性的候选名），并新增「候选遍历」段输出 `loadAttemptLog`。
- **文件头** `:9-12`：模型说明从 `yolopx3_{fp16,w8a16}.mlmodelc` 更正为 `yolopx3_pal8_detfp.mlmodelc`。

### 2.6 误导性注释更正（`:276-300`，队长指定的第 3 点）

原注释写「① **只允许 8 位量化**，fp16 排除 → int8 / w8a16 优先 …③ w8a16 稳定性优于全 int8，故 int8 排最前」——
**与精度实测结论矛盾**（int8 的 ll recall 只有 3.98%，w8a16 的 det 只有 85%，两者都不达标；真正达标的是 pal8_detfp）。
已整体重写为「**精度优先**」排序依据，并写明每条降级的确切实测数字与原因，附
**「本表是『尝试顺序』，不是『命中顺序』」**的显式警告（防止后人再按旧前提改）。

---

## 2.7 接线点核对（任务第 ③ 项）

任务给定的 7 个接线点**逐个核对，全部在场且门控正确，未发现断链**：

| # | 接线点 | 位置 | 核对结果 |
|---|---|---|---|
| ① | `DriveState` 的引擎字段 | `AuroraDriveApp.swift:2550` `yolopxEngine` / `:2554` `laneFallback` | ✅ 实例已建 |
| ② | 启动加载 | `AuroraDriveApp.swift:2743` `yolopxEngine.loadIfNeeded()` | ✅ 在 `startDriving` 内 |
| ③ | 每帧推理触发 | `AuroraDriveApp.swift:3182` `yolopxEngine.infer(image: cg)` | ✅ 与 yoloEngine 并行、独立 letterbox；内部由 `enabled` + `isLoaded` 门控 |
| ④ | 兜底决策段 | `AuroraDriveApp.swift:3401` `laneFallback.evaluate(...)` | ✅ 门控 `decided == .rule \|\| .recover`，第三优先级 |
| ⑤ | 建议叠加全局函数 | `AuroraDriveApp.swift:3829` `func applyLaneAdvice(...)` | ✅ 文件级全局函数，调用点无 `Self.` 前缀 |
| ⑥ | 掩码叠加视图 | `AuroraDriveApp.swift:3898` `struct MaskOverlay` | ✅ 已定义 |
| ⑦ | 视图调用点 | `MissionConsole.swift:589` `MaskOverlay(active:...)` | ✅ `active: isDriving && showYolopxMasks` |

### 2.7.1 ⚠️ 修复带来的**下游激活**效应（本次核对接线时的关键发现）

三个下游消费者都要求 `yolopxEngine.isLoaded == true`，而**修复前它恒为 `false`**——
所以这不仅是"换了个模型"，而是**同时点亮了三条一直是死的链路**：

| 消费者 | 位置 | 门控 | 修复前 | 修复后 |
|---|---|---|---|---|
| `effectiveDetections` 走 YOLOPX 框 | `:1881-1887` | `preferYolopxDetections && isLoaded && !detections.isEmpty` | 恒取 yolo26s 的框 | 取 YOLOPX det |
| `MaskOverlay` 掩码绘制 | `MissionConsole.swift:589` | `active`（`showYolopxMasks`）+ 掩码非空 | 掩码恒 `.empty`，**什么都不画** | 画 da/ll 掩码 |
| `LaneFallback` 车道兜底 | `:3401` | `isDegraded`（初值 `true`） | **全程不介入** | 首帧推理后按 `laneRatio` 计算 |

三个开关默认值均为开启：`preferYolopxDetections = true`（`:2430`）、
`showYolopxMasks = true`（`:2433`）、`yolopxEngine.enabled = true`（`YolopxEngine.swift:186`）。
**即：修复后这三条链路会立即进入实际生效状态**——这是本修复的真实影响面，
也是**必须交给 t30/t31/t32 安全审查重点复核**的地方（不是"接线没动"，而是"接线从死变活"）。

两段输出均由 `/tmp/t28-prep/before_after.swift` 实测产生，使用 **App 同一入口** `MLModel(contentsOf:configuration:)`。

### 修改前

```
【修改前】modelURL 选中: yolopx3_w8a16.mlmodelc          ← fileExists 挑中的第一个
         加载: ❌ 失败 → isLoaded=false，**不尝试下一候选**，引擎永久未加载
         报错: Unable to load model: ... Compile the model with Xcode or `MLModel.compileModel(at:)`.
```

### 修改后

```
【修改后】逐个实测加载:
         ✓ yolopx3_pal8_detfp.mlmodelc — 加载成功
         最终命中: yolopx3_pal8_detfp.mlmodelc
```

**效果**：引擎由「永久未加载（感知链死）」变为「加载 det 100% 的精度冠军」。

### 3.1 候选遍历日志（契约 7 要求）

**真实 `models/` 环境下**（首位即命中，遍历只走一步）——`loadAttemptLog` 的实际内容：
```
  ✓ yolopx3_pal8_detfp.mlmodelc — 加载成功
```
运行时 `loadIfNeeded()` 会打印：
```
[yolopx] 模型加载: yolopx3_pal8_detfp.mlmodelc
[yolopx]   ✓ yolopx3_pal8_detfp.mlmodelc — 加载成功
```

**降级路径下**（用符号链接模拟"全部 8 位不可用"，见 §4.3 与 §7 局限 2）遍历会完整走完并逐条留痕：
```
  ✗ yolopx3_pal8_detfp.mlmodelc — 不存在
  ✗ yolopx3_pal8_detfp.mlpackage — 不存在
  ✗ yolopx3_w8a16.mlmodelc — 加载失败: Unable to load model: ... Compile the model with Xcode ...
  ✓ yolopx3_w8a16.mlpackage — 加载成功
```
三种失败归因齐全：**不存在 / 编译失败 / 加载失败**，全部带候选名，便于运维定位卡在哪一步。
全部失败时该日志会整体拼进 `errorMessage`，不会"静默死亡"。

---

## 4. 契约验收证据（逐条）

验收程序 `/tmp/t28-prep/verify_t28.swift`，用 App 同款 API，输出：

### 4.1 契约 1：实测加载成功（Python 口径不算）

```
  实际加载: yolopx3_pal8_detfp.mlmodelc
  输入: ["image"]
  输出: ["da", "det", "ll"]
    ll: [1, 2, 640, 640]
    det: [1, 8400, 6]
    da: [1, 2, 640, 640]
  ✅ 命中精度冠军 yolopx3_pal8_detfp.mlmodelc
  ✅ IO 契约匹配（in=[image] out=[da,det,ll]）
```

**IOS 属规格与作战手册 §7 完全一致**（`det [1,8400,6]` / `da`/`ll [1,2,640,640]`）。

### 4.2 契约 2：遍历候选、逐条记录、失败不再永久

见 §2.3 代码 + §4.1 输出中 `loadAttemptLog` 的产生路径；每条记录含 `候选名 + 失败原因`
（不存在 / 编译失败 / 加载失败三种归因）。

### 4.3 契约 3：残缺候选可跳过（★已独立实测）

**这一条最初我只写了"逻辑分支存在"，自查发现不达标——于是补做了非侵入性实测。**

**⚠️ 第一次测试是无效的（如实记录）**：把"首位缺失 + 残缺候选"放一起测时，
遍历在**第 2 位**就成功返回，**根本没走到残缺候选**——那一跑没验证到跳过逻辑：
```
  ✗ yolopx3_pal8_detfp.mlmodelc — 不存在 → continue
  ✓ yolopx3_pal8_detfp.mlpackage — 加载成功      ← 提前返回，残缺候选未被触及
```

**第二次测试（把残缺候选放到必经之路）才真正验证**：让 `pal8_*` 两项全缺，
使**残缺的 `w8a16.mlmodelc` 落在必经之路上**：
```
  ✗ yolopx3_pal8_detfp.mlmodelc — 不存在 → continue
  ✗ yolopx3_pal8_detfp.mlpackage — 不存在 → continue
  ✗ yolopx3_w8a16.mlmodelc — 加载失败 → **continue 到下一候选**   ← 关键：跳过残缺候选
  ✓ yolopx3_w8a16.mlpackage — 加载成功
最终命中: yolopx3_w8a16.mlpackage
✅ 通过：越过 2 项缺失 + 【残缺候选加载失败并 continue】，成功回退到其后的可用候选
✅ 附加：.mlpackage 走 compileModel 成功 → 契约「假回退修复」同时成立
```

**这一跑同时证明了两件事**：① 残缺候选（旧实现会在此**永久终止**）现在能被跳过并继续；
② `.mlpackage` 候选经 `compileModel` 后**真的能加载**（不再是假回退）。

**实现方式（不违反红线）**：在 `/tmp/t28-skip2/models/yolopx/` 下用**符号链接**搭场景，
`models/` 本体**一个文件都没动**（其 `w8a16.mlmodelc` mtime 仍为 `21:40:51`，已复核）。

### 4.4 契约 5：全部候选失败时 fail-open 不变

```
  ✅ 无任何候选可加载 → isLoaded 将保持 false（fail-open，LaneFallback 门控拒绝采信）
```

`loadIfNeeded()` 在 `guard let hit = ... else` 分支里**只设 `isLoaded=false` + `errorMessage`**，
`isDegraded` 仍为初值 `true` → `LaneFallback.evaluate` 门①（`LaneFallback.swift:116-119`）仍返回 `nil`。
**未引入误转向风险**，与队长采纳的安全结论一致。

### 4.5 契约 6：编译

```
Build complete! (104.04s)     EXIT=0
swift build -c release 2>&1 | grep -E "\berror: " | grep -v warning | wc -l   → 0
```

---

## 5. ⚠️ F1 交付后需二次更新候选首项

**当前首位是"已知最优"`yolopx3_pal8_detfp`，不是 F1 生产产物**——E3→F1 链路尚未产出。
待 F1 交付且精度验收（t24）通过后，**应把 F1 产物提到候选首位**，`pal8_detfp` 退为次选。
此事项已写入 `YolopxEngine.swift:294-299` 的注释（「⚠️ **F1 交付后需二次更新候选首项**」），
供后续接手者直接看到。**本任务未等 F1，也未假设 F1 已存在。**

---

## 6. 红线遵守

| 红线 | 状态 |
|---|---|
| 禁改 `models/` 产物 | ✅ 未写任何 `models/` 文件。变更前后文件数均为 **139**（与 t29 核验一致） |
| 禁改 vendored 仓库 | ✅ 未触碰 `tools/yolopx/`（实测程序全部写在 `/tmp/t28-prep/`） |
| 禁删功能/注释代码 | ✅ 仅重排候选、新增遍历逻辑，无功能删除 |
| 不改用户文件 | ✅ 唯一源码改动 = `YolopxEngine.swift` |

**关于 `w8a16.mlmodelc` 破损**：按队长指示**保持原样未修**，已同步给产物编译环节（C1）。
（其 mtime `21:40:51` 早于我接触，非我造成。）

**上游并发现象（知情记录）**：核验期间观察到 `models/yolopx/yolopx3_*.mlpackage/Manifest.json`
的 mtime 为 **23:00–23:0x**、`yolo26s_int8.mlpackage/Manifest.json` 同理——
artifact-builder 正在写入 `models/`。**我未参与**，仅记录以免后人误判为我的改动。

---

## 7. 局限与未验证（诚实清单）

1. **未做真机端到端验证。** 证据是**用 App 同款 API 的独立程序**（`MLModel(contentsOf:)`）
   实测，非实际启动 AuroraDrive 观察日志。因此"引擎在真实 App 生命周期中加载成功"
   属**强推断**而非直接观测。建议后续用 `--yolopx-selftest` 或启动日志确认。
2. **「跳过残缺候选」已用符号链接场景实测通过**（§4.3），但**不是在真实 `models/` 目录下**验证的
   —— 因为那需要移动 `models/` 文件（违反红线）。符号链接场景与真实场景的差异：
   真实目录里 `pal8_detfp` 在场，遍历会在第 1 位就返回，**永远走不到残缺的 `w8a16`**；
   故本条在真实环境下**不会被触发**，属于"逻辑正确但当前路径不经过"的安全冗余。
3. **`loadAttemptLog` 的运行时输出未在真机观察。** 只验证了逻辑与静态输出格式。
4. **未验证 `pal8_detfp` 的推理数值正确性。** 本任务只证明**能加载 + IO 契约匹配**；
   精度（da IoU / ll 偏差 / det 匹配率）属 t24 验收范围，**本报告不作精度声明**。
5. **未评估 `.mlpackage` 编译耗时对启动的影响。** `compileModel` 有编译开销；
   当前首位是 `.mlmodelc`（免编译），但若落到第 2 位会引入一次性编译延迟，**未测量**。
6. **未确认 `loadedModelName` 的所有消费方。** 新增字段目前仅供诊断/告警；
   若后续 UI 需要展示，需另行接线（不在本任务范围）。

---

## 8. 复现命令

```bash
cd /Users/dupi/Desktop/自动驾驶系统

# ① 契约 6：编译
swift build -c release 2>&1 | grep -E "\berror: " | grep -v warning | wc -l   # 期望 0

# ② 契约 1/3/5：用 App 同款 API 实测（证据留 /tmp）
cd /tmp/t28-prep
swiftc -O verify_t28.swift -o verify_t28 && ./verify_t28        # 期望 RESULT: PASS
swiftc -O before_after.swift -o before_after && ./before_after  # 修改前/后对照

# ③ 候选表与状态字段
grep -n "yolopx3_" Sources/AuroraDrive/Inference/YolopxEngine.swift | grep -E ':\s+"'
grep -n "loadedModelName\|loadAttemptLog" Sources/AuroraDrive/Inference/YolopxEngine.swift
```

---

## 9. 本轮实测记录

| 项 | 值 |
|---|---|
| 编译 | `Build complete! (104.04s)`，EXIT=**0**，error=**0** |
| 验收程序 | `RESULT: PASS`（PROBE_EXIT=0） |
| 实际加载 | `yolopx3_pal8_detfp.mlmodelc`（in=[image] out=[da,det,ll]） |
| 修改前实际加载 | ❌ 失败（选中残缺 `w8a16.mlmodelc`，不换候选） |
| 源码改动 | 仅 `Sources/AuroraDrive/Inference/YolopxEngine.swift` |
| `models/` 文件数 | 139 → 139（未变） |
| vendored 改动 | 0 |
