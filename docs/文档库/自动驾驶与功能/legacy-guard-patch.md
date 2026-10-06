# Legacy 技能窗口护栏补丁（✅ 已应用 · commit adb63ad，2026-09-16）

> **档案标注（2026-09-20 核）**：本补丁 2026-09-16 已应用并双目标部署（见下方状态更新），正文保留作过程档案；文中"未应用原因""应用后的验收"等段落为应用前的预备记录，**不是待办事项**。

> **状态更新（Round 1，adb63ad）**：原 3 处（volleyball/fishing/dodge）已应用，且审计全部
> pressGameKey/scrollWheel 注入点后**发现 patch doc 漏了 auto_scroll**——实际 **4 个**纯按键循环无护栏。
> 已按"稳定性优先"直接落地（用户 Round 1 目标"掉所有问题"授权放宽架构冻结）：
> 每个循环加「启动前 + 每轮/每 tick」双层 `GameWindowDetector.isGameVisible()` guard，
> 游戏中途消失也自动停。41 行纯新增、0 改老逻辑；build 0 error；selftest PASS=21。已双目标部署。


> 背景：剩余风险 #9（`docs/文档库/探索文档/最终报告.md` §五）——5 个 legacy 技能缺 `GameWindowDetector.isGameVisible()`
> 游戏窗口护栏。架构冻结清单规定"技能实现只加不改老方法"，故补丁**预备在此、不动代码**，
> 用户批准后一次应用：编译 → 自测（PASS 只增不减）→ `./run.sh` → 提交。
>
> 审计结论（2026-09-15 全量扫描）：`performAutoScroll` / `performAutoLogin` / `performUIClickLoop`
> 已有窗口/帧检查（无需改）；需补的只有 **3 处**（纯按键注入型）：

## 补丁 1/3：startVolleyballLoop（`AIAgentPanel.swift:729` 后插入）

```swift
        guard let control else {
            appendSystem("❌ 按键引擎未注入")
            runningSkills.remove(skill.id)
            return
        }
        // ↓ 新增（1 条，照抄 :760 touch 的护栏模式）
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，排球已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }
```

## 补丁 2/3：performFishingLoop（`AIAgentPanel.swift:1187` dryRun guard 之后插入）

```swift
        guard !dryRun else {
            appendSystem("✅ 自测：钓鱼循环（F 抛竿/收杆）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        // ↓ 新增
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，钓鱼已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }
```

## 补丁 3/3：performDodgeLoop（`AIAgentPanel.swift:1221` dryRun guard 之后插入）

```swift
        // ↓ 新增
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，闪避已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }
```

## 应用后的验收

1. `swift build -c release --disable-sandbox --scratch-path .build/scratch` → 0 error
2. `./AuroraDriveUI --agent-selftest` → PASS ≥ 21 且 FAIL=0（干跑路径不变，护栏在 dryRun 之后）
3. `./run.sh` 部署
4. 无游戏窗口时依次点 volleyball/fishing/dodge → 日志出现「未检测到游戏窗口…已取消」
5. 单独 1 个 commit

## 未应用原因

架构冻结清单（用户 2026-09-14 明示"不接受任何改变整体架构的方式"）：老技能实现方法不在
"允许改动"绿名单。是否放宽由用户决定；批准前**不得**应用。
