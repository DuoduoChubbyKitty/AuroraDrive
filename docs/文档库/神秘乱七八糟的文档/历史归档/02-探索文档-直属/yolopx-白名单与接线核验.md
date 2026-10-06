# YOLOPX · W4 白名单与接线完整性核验报告（任务 t29）

> 契约：核验 `Package.swift` 显式白名单是否覆盖全部参与编译的源文件、找出漏编译高危文件、
> 核对 `models/` 产物完整性。
> 核验时间：2026-09-26 23:30–23:50（GMT+8）。执行：swift-fixer（attempt 1）。
> **本任务为只读核验：未改白名单、未删任何文件。**

---

## 0. 结论摘要

| 核验项 | 结论 |
|---|---|
| ① 白名单覆盖完整性 | ✅ **完整**。磁盘与白名单**双向零差异** |
| ② 接入链 6 文件 | ✅ **6/6 全部在 `sources:` 中**，且均**不在** `exclude:` 中 |
| ③ `models/` 产物完整性 | ✅ **无文件被误删**（139 个文件、2.0G 全在） |
| ④ 漏编译风险 | ✅ **无**。零个「在磁盘却未参与编译」的源文件 |
| ⑤ **独立发现（非本任务契约项）** | 🔴 **运行时加载的 YOLOPX 模型是 det 仅 85% 的 w8a16，而精度 100% 的 pal8_detfp 根本不在候选列表里** |

**核验方法升级（关键）**：没有只用 `grep` 手抠 `Package.swift` 文本，而是用
**SwiftPM 自己的权威视图** `swift package describe --type json` 取真实编译清单，
再与磁盘树做集合差。文本解析与 SwiftPM 结果**逐字节一致（41=41，双向差集为空）**，
两条独立路径互证。

---

## 1. 白名单完整对照

### 1.1 sources: 全清单（41 项，`AuroraDrive` target，path=`.`）

| # | 文件 | # | 文件 |
|---|---|---|---|
| 1 | `Sources/AuroraDrive/Agent/AIAgentPanel.swift` | 22 | `Sources/AuroraDrive/Core/EngineClient.swift` |
| 2 | `Sources/AuroraDrive/Agent/AgentLoop.swift` | 23 | `Sources/AuroraDrive/Core/EngineMain.swift` |
| 3 | `Sources/AuroraDrive/Agent/DegradeStateMachine.swift` | 24 | `Sources/AuroraDrive/Core/GameModeDefender.swift` |
| 4 | `Sources/AuroraDrive/Agent/LoginAssistant.swift` | 25 | `Sources/AuroraDrive/Core/PrioritySetup.swift` |
| 5 | `Sources/AuroraDrive/Agent/RuleController.swift` | 26 | `Sources/AuroraDrive/Core/PrivilegePill.swift` |
| 6 | `Sources/AuroraDrive/App/AuroraDriveApp.swift` | 27 | `Sources/AuroraDrive/Control/ControlEngine.swift` |
| 7 | `Sources/AuroraDrive/App/AuroraTheme.swift` | 28 | `Sources/AuroraDrive/Control/EscapeController.swift` |
| 8 | `Sources/AuroraDrive/App/ControlWiring.swift` | 29 | `Sources/AuroraDrive/Control/KeyboardMonitor.swift` |
| 9 | `Sources/AuroraDrive/App/GameHUDWindow.swift` | 30 | `Sources/AuroraDrive/Control/MouseController.swift` |
| 10 | `Sources/AuroraDrive/App/LocateRuntime.swift` | 31 | `Sources/AuroraDrive/Inference/ConfidenceEstimator.swift` |
| 11 | `Sources/AuroraDrive/App/MapWiring.swift` | 32 | `Sources/AuroraDrive/Inference/InferenceEngine.swift` |
| 12 | `Sources/AuroraDrive/App/MissionConsole.swift` | 33 | **`Sources/AuroraDrive/Inference/LaneFallback.swift`** ★ |
| 13 | `Sources/AuroraDrive/Capture/CaptureEngine.swift` | 34 | `Sources/AuroraDrive/Inference/SpeedOCRReader.swift` |
| 14 | `Sources/AuroraDrive/Capture/CoordinateCapture.swift` | 35 | `Sources/AuroraDrive/Inference/YoloEngine.swift` |
| 15 | `Sources/AuroraDrive/Capture/RecordEngine.swift` | 36 | **`Sources/AuroraDrive/Inference/YolopxEngine.swift`** ★ |
| 16 | `Sources/AuroraDrive/Core/AuroraPaths.swift` | 37 | `Sources/AuroraDrive/Locate/MinimapTileCache.swift` |
| 17 | `Sources/AuroraDrive/Core/BPFSetup.swift` | 38 | `Sources/AuroraDrive/Locate/NetworkLocator.swift` |
| 18 | `Sources/AuroraDrive/Core/DaemonSetup.swift` | 39 | `Vendor/MetalGoose/Engine/CaptureSettings.swift` |
| 19 | `Sources/AuroraDrive/Core/EngineClient.swift` | 40 | `Vendor/MetalGoose/Engine/GooseEngine.swift` |
| 20 | `Sources/AuroraDrive/Core/EngineMain.swift` | 41 | `Vendor/MetalGoose/Engine/GooseUpscaler.swift` |
| 21 | `Vendor/MetalGoose/Engine/Stubs.swift` | | `Vendor/MetalGoose/Engine/WindowCaptureManager.swift` |

★ = 本批 YOLOPX 接入新增、已正确登记的两个文件。

### 1.2 exclude: 全清单（60 项）

**目录级（36 项）**：`.build`、`build`、`MaaNTE`、`scripts`、`docs`、`tools`、`checkpoints`、
`data`、`diag_area`、`diag_steps`、`graphflow-out`、`models`、`recordings`、`BidKing_PR434`、
`AuroraDriveUI`、`AuroraDriveUI.app`、`.workbuddy`、`.venv-yolo26`、`.trae`、`.vscode`、
`.agent-teams`、`.dsh-computer-use`、`.dsh-vision-router`、`Plugins`、`src`、`legacy`、
`Sources/AuroraDriveShared`、`Sources/AuroraDriveUserAgent`、`__pycache__` 等。

**文件级 — 非 .swift（15 项）**：`yolo26s.pt`、`train.log`、`photorec.log`、`photorec.ses`、
`run.sh`、`test-minimal-plugin.js`、`README.md`、`README.en.md`、`NOTICE`、
`.dsh-edit-review.json`、`.dsh-edit-review-archive.json`、`.last-build.log`、`.run-deploy.log`、
`.ui-shot.log`、`.llm-key-notebook.md`、`Vendor/MetalGoose/{LICENSE, Localizable.xcstrings,
MetalGoose.entitlements, NOTICE.md, README.md, Shaders.metal}`、`Vendor/MetalGoose/Engine/Shaders.metal`。

**文件级 — .swift（9 项，全部是 Vendor/MetalGoose 根层，有意排除）**：

```
Vendor/MetalGoose/AutoUpdater.swift          Vendor/MetalGoose/MGHUD.swift
Vendor/MetalGoose/CaptureSettings.swift      Vendor/MetalGoose/MetalGooseApp.swift
Vendor/MetalGoose/ContentView.swift          Vendor/MetalGoose/OverlayWindowManager.swift
Vendor/MetalGoose/GlobalHotkeyManager.swift  Vendor/MetalGoose/WindowCaptureManager.swift
Vendor/MetalGoose/GooseEngine.swift
```

### 1.3 `sources ∩ exclude` 冲突检查

**空集 —— 零冲突。** 没有任何文件同时出现在两个数组里。
（该结论用**严格区块解析**得到：先按 `name: [` 做括号配对取出区块、剥掉 `//` 注释再取字符串字面量。
⚠️ 一种朴素 grep 写法会得到假的「41 个冲突」，因为它对整份 `Package.swift` 匹配，
`exclude` 的关键词会命中 `sources` 那一行 —— 本核验据此改用区块解析，见 §5 方法学。）

---

## 2. 漏编译风险清单

### 2.1 磁盘 vs 白名单 双向差集

| 方向 | 结果 |
|---|---|
| 磁盘有、`sources` 无（**漏编译高危**） | **0 个** |
| `sources` 有、磁盘无（悬空条目） | **0 个** |
| 文本解析 `sources` 数 vs SwiftPM 权威数 | **41 vs 41，双向差集为空** |

### 2.2 全部「在磁盘却不在白名单」的 .swift —— 逐个定性（无一是漏编译）

| 文件 | 为何不编译 | 定性 |
|---|---|---|
| `Package.swift` | 清单自身 | ✅ 正常 |
| `Sources/AuroraDriveShared/AuroraDriveShared.swift` | 属 **AuroraDriveShared** target | ✅ 正常 |
| `Sources/AuroraDriveUserAgent/main.swift` | 属 **AuroraDriveUserAgent** target | ✅ 正常 |
| `Vendor/MetalGoose/` 根层 9 个 .swift | 显式列在 `exclude:`（见 §1.2） | ✅ 有意排除，注释已说明「刻意不编译」 |
| `legacy/NetworkPacketCapture.swift` | `exclude: legacy` | ✅ 有意排除（历史文件保留） |
| `Plugins/PostBuildSign/...` 2 个 | `exclude: Plugins` | ✅ 独立子包，不参与主 target |
| `tools/`、`src/`、`MaaNTE/`、`BidKing_PR434/` 下 | 均已 exclude | ✅ 已核验：这些目录下 **0 个 .swift** |

**「66 个假错误」风险的现行状态：已消除。** 本次双向比对未发现任何漏登记文件。

### 2.3 需要留意的 `Vendor/MetalGoose` 双份同名文件（**非漏编译，但值得知情**）

```
Vendor/MetalGoose/GooseEngine.swift        (84597 B, Aug 19)  ← exclude
Vendor/MetalGoose/Engine/GooseEngine.swift (93975 B, Sep 24)  ← 进白名单，实际编译
Vendor/MetalGoose/WindowCaptureManager.swift      (16098 B)   ← exclude
Vendor/MetalGoose/Engine/WindowCaptureManager.swift (16098 B) ← 进白名单
Vendor/MetalGoose/CaptureSettings.swift      (9185 B)         ← exclude
Vendor/MetalGoose/Engine/CaptureSettings.swift (9185 B)       ← 进白名单
```

`Engine/` 是**真实目录，不是符号链接**（`ls -ld` + `readlink` 确认）。
两份同名文件**内容不同**（`Engine/GooseEngine.swift` 更大且更新，是真正的运行时版本）。
这是**刻意的「只用 Engine/ 下 5 文件」设计**，`Package.swift` 注释已写明。
**风险提示**：将来若有人改了根层那份以为生效，实际改的是死文件 —— 建议后续任务（非本任务）考虑加注说明。
另注：`Vendor/MetalGoose/Engine/Shaders.metal` **只 exclude 不进白名单**，但运行时由
`GooseEngine.swift:456` 按路径加载，文件本体必须留在原地（`Package.swift` 注释已警示，本次核验确认文件在）。

---

## 3. models/ 产物完整性核对

### 3.1 总览

| 项 | 值 |
|---|---|
| `models/` 总大小 | **2.0 GB** |
| 文件总数（递归） | **139** |
| 顶层条目 | 53 |
| `.mlpackage`（顶层） | 8 |
| `.mlmodelc`（顶层） | 4 |
| 空目录 | **0** |
| 0 字节文件 | 3（见 §3.3，已辨明真伪） |

### 3.2 代码引用的模型逐个存在性核验

| 代码引用的模型 | 存在 | 说明 |
|---|---|---|
| `models/yolo26s.mlmodelc` / `.mlpackage` | ✅ | YoloEngine 现役 |
| `models/m9_mono.mlmodelc` | ✅ | InferenceEngine |
| `models/game_assist_control.mlmodelc` / `.mlpackage` | ✅ | 第二司机 |
| `models/speed_digit_cnn.mlmodelc` | ✅ | OCR 字模 |
| `models/speed_digit_cnn_v4.mlpackage` | ✅ | OCR |
| `models/ppocrv6_tiny_ft_int8.mlpackage` + `_keys.txt` | ✅ | OCR |
| `models/yolo26s_int8.mlpackage` | ✅ | 备选 |
| `models/game_assist_control_fpv.mlmodelc` | ❌ 缺 | **非缺陷**：`AuroraDriveApp.swift:2900-2901` 是 4 项候选回退列表，会回落到 `game_assist_control.mlmodelc`（已存在）。该项缺失属于「尝试失败则回退」，不影响加载 |
| `models/yolopx/yolopx3_int8.mlmodelc` | ❌ 缺 | **非缺陷**：候选回退，跳过 |
| `models/yolopx/yolopx3_fp16.mlmodelc` | ❌ 缺 | **非缺陷**：候选回退，跳过 |

**结论：无任何被代码引用且无回退路径的模型缺失。无文件被误删。**

### 3.3 三个 0 字节文件的真伪辨明

```
models/pak_paths_pakchunk0-Mac.txt
models/pak_paths_pakchunk1-Mac.txt
models/pak_paths_pakchunk2-Mac.txt
```

- 逐个检查：**没有任何 Swift 代码引用**（`grep -rn "pak_paths" Sources/` 空）；
  **也没有任何 .py/.sh 脚本引用**。
- 定性：**空占位文件**，非「被删空」的正常产物。它们本来就没有内容
  （文件名暗示是 pak 路径清单的预留槽位）。
- **我未删除它们**（本任务禁止删文件）。仅记录事实 + 判定为非缺陷。

### 3.4 作战手册 §7 五产物在场性（逐个签名）

| 产物（手册 §7 清单） | 体积 | 在场 |
|---|---|---|
| `yolopx3_fp16.mlpackage` | 63M | ✅ |
| `yolopx3_w8a16.mlpackage` | 32M | ✅ |
| `yolopx3_int8.mlpackage` | 32M | ✅ |
| `yolopx3_w8a16_detfp.mlpackage` | 32M | ✅ |
| `yolopx3_pal8_detfp.mlpackage` | 32M | ✅ |

**手册清单 5/5 全在。** 另磁盘上还有手册未列的
`yolopx3_pal8_detfp.mlmodelc`、`yolopx3_w8a16.mlmodelc`（已编译产物）与
`yolopx.onnx`、`yolopx.onnx.data`、`yolopx_epoch195.pth`、`yolopx_{fp16,int8,w8a16}.mlpackage`（旧版）——
均为**额外存在**，无缺失。

---

## 4. 🔴 独立发现：运行时加载的 YOLOPX 模型与「精度不降」目标冲突

> **这一项不在 t29 契约内，但是核验过程中发现的高危事实，必须报告。不改代码，只报事实。**

`YolopxEngine.swift:274-281` 的候选列表（按顺序回退，取第一个存在的）：

```
1. yolopx3_int8.mlmodelc       → ❌ 磁盘无
2. yolopx3_w8a16.mlmodelc      → ✅ 存在  ← 实际命中这里
3. yolopx3_int8.mlpackage      → （不会走到）
4. yolopx3_w8a16.mlpackage     → （不会走到）
5. yolopx3_fp16.mlmodelc       → ❌ 磁盘无（兜底）
6. yolopx3_fp16.mlpackage      → （不会走到）
```

**逐项模拟结果：运行时实际加载 `yolopx3_w8a16.mlmodelc`。**

对照作战手册 §3.1 已测事实：

| 产物 | 手册记载精度 | 在候选列表中 | 磁盘 |
|---|---|---|---|
| `yolopx3_w8a16` | **det 85%**（框数膨胀 7→12、15→29） | ✅ **第 2 位，实际命中** | ✅ |
| `yolopx3_int8` | ll recall **3.98%**（架构性失败） | ✅ 第 1 位 | ❌ .mlmodelc 缺 |
| `yolopx3_fp16` | det 100% / da 0.9924（但违反「只用 8 位」） | ✅ 兜底 | ❌ .mlmodelc 缺 |
| **`yolopx3_pal8_detfp`** | **det 100% / da 0.9930 / ll P99.28·R98.15 ← 精度最佳** | ❌ **完全不在候选列表** | ✅ `.mlmodelc` + `.mlpackage` **都在** |

**问题**：团队目标写明「精度不降（det>99% / da IoU>0.99 / ll 偏差<0.006）」，
而唯一同时满足 det 100% 与 da 0.9930 的产物 `yolopx3_pal8_detfp` **已经编译成 `.mlmodelc` 躺在磁盘上，
却没有任何代码引用它**。当前生效路径会加载 det 仅 85% 的 w8a16。

**注意**：`AuroraDriveApp.swift:2546` 的注释写的是 `models/yolopx/yolopx3_*.mlmodelc`（通配），
不构成对具体产物的引用 —— 即**全仓库对 `pal8_detfp` 的 Swift 引用数为 0**（已 grep 确认）。

**我没有改候选列表**（契约明确「不改白名单，本任务只核验，发现缺失报告给队长」，
且候选列表属 t28「接线最终化」范围，见下）。**此发现需队长决定归属。**
它与 `t28`（「modelCandidates 指向 F1 实际交付的生产产物，精度达标者优先」）
高度相关 —— t28 很可能正是为此而设，若如此，本项即 t28 的输入。

---

## 5. 方法学与本次踩过的坑（供复算者避雷）

1. **用 SwiftPM 权威清单而非手抠文本**：`swift package describe --type json` 给出真实
   `targets[].sources`，与磁盘做集合差。两条独立路径（文本解析 / SwiftPM）互证一致。
2. **⚠️ 朴素 grep 会造出假冲突**：一度用「对整份 `Package.swift` 做 `grep -c "$f"` 再和
   `sources` 字符串比对」的写法，得到 **41 个「同时出现在 sources 和 exclude」的假警报**——
   因为它对全文匹配，未区分区块。**改为区块解析后冲突为空。**
   教训与作战手册 §6「66 个假错误」同源：**这个项目的检测脚本本身极易产生系统性假信号**。
3. **⚠️ `find` 默认不跟随符号链接**：一度只扫 `Sources/` 就断言 Vendor 5 条目是「幽灵条目」，
   实为我 `find` 范围过窄。补扫全包树后确认 `Engine/` 是真实目录。
   **未核验范围就下结论 = 假发现。**
4. **区分「候选回退缺失」与「真缺失」**：YOLOPX/第二司机均为多候选回退语义，
   缺一个候选**不等于**故障；必须模拟「按顺序取第一个存在者」才能判断真实命中。
5. **0 字节文件必须查引用**才能定性，不能凭大小判「被删空」。

---

## 6. 验证命令（可复现）

```bash
cd /Users/dupi/Desktop/自动驾驶系统

# ① SwiftPM 权威编译清单
swift package describe --type json | python3 -c "
import json,sys; d=json.load(sys.stdin)
for t in d['targets']:
    if t['name']=='AuroraDrive':
        print(len(t['sources']),'个 source'); [print(' ',s) for s in sorted(t['sources'])]"

# ② 双向差集（漏编译 / 悬空条目）
find Sources/AuroraDrive -name '*.swift' | sort > /tmp/disk.txt
#   （与 ① 输出对比；本报告用的是覆盖全包树的版本）

# ③ 接入链 6 文件在场
for f in Inference/YolopxEngine Inference/LaneFallback App/AuroraDriveApp \
         App/MissionConsole App/ControlWiring Inference/YoloEngine; do
  grep -q "\"Sources/AuroraDrive/$f.swift\"" Package.swift && echo "✅ $f" || echo "❌ $f"
done

# ④ 候选回退模拟（真实命中哪个 YOLOPX 模型）
for n in yolopx3_int8.mlmodelc yolopx3_w8a16.mlmodelc yolopx3_int8.mlpackage \
         yolopx3_w8a16.mlpackage yolopx3_fp16.mlmodelc yolopx3_fp16.mlpackage; do
  [ -e "models/yolopx/$n" ] && { echo "实际命中: $n"; break; } || echo "跳过: $n"
done

# ⑤ models/ 完整性
du -sh models/; find models/ -type f | wc -l
find models/ -type f -size 0        # 0 字节文件需查引用再定性

# ⑥ 干净构建（确认白名单真的全都能编过）+ SwiftPM 自己的 unhandled 报告
swift build -c release --scratch-path /tmp/yolopx-t29-scratch
```

**本轮实测结果**：干净构建 `Build complete! (172.31s)`、**EXIT=0**、error 计数 **0**；
SwiftPM 仅报 2 个 **非 Swift** 的 unhandled 文件（`YOLO家族三合一模型清单_2026-09-26.html`、
`default.metallib`）—— 不影响源码编译，但可考虑列入 exclude（**本任务未改**）。

---

## 7. 验收对照

| 验收项 | 结果 | 证据 |
|---|---|---|
| 白名单是否覆盖全部参与编译的源文件 | ✅ 完整 | 磁盘 ↔ 白名单双向差集为空；41=41 双路径互证（§2.1） |
| 接入链每个文件在 `sources:` 且不在 `exclude:` | ✅ 6/6 | §1.3 冲突检查为空集；§2.2 接入链核验全 ✅ |
| `models/` 产物是否都在（不许误删） | ✅ 无缺失 | 139 文件 / 2.0G / 0 空目录；手册 §7 五产物 5/5；代码引用逐个核验（§3） |
| 列出「磁盘存在但未参与编译」的源文件 | ✅ 已列并逐个定性 | §2.2 —— **无一是漏编译** |
| 明确结论 | ✅ 见 §0 | 白名单完整、无漏编译风险 |

**红线遵守**：未改 `Package.swift`（`git diff -- Package.swift` 无本任务新增行）；
未删任何文件；未改 `models/` 与 vendored 仓库。
· 唯一写入：本报告。

---

## 8. 局限与未验证

1. **未做运行时验证**。§4 的「实际命中 w8a16」是从候选列表与磁盘存在性**静态推导**的，
   未实际启动程序观察加载日志。真机确认需运行 `--yolopx-selftest` 或看启动日志。
2. **未核验 `Engine/` 与根层同名文件的内容等价性**（§2.3）——只比了体积与时间戳，未 diff。
3. **未评价候选列表顺序是否合理**（如 int8 排第一但 ll recall 仅 3.98%）。
   这是设计问题，留给 t28/终审。
4. **未核验非 `.swift` 资源**（如 `.metal`、`.xcstrings`）是否被正确加载，除
   `Engine/Shaders.metal` 外未逐个查。
5. **`models/` 的 139 个文件中，只对「代码引用的」与「手册列出的」做了在场核验**，
   其余文件仅做总数与体积统计，未逐个断言其必要性。
6. **未与其他成员交叉核对** `pal8_detfp` 是否正被 t28 处理中；§4 的建议归属基于任务标题推测。
