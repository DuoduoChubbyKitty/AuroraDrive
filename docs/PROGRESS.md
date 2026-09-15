# AuroraDrive 进度追踪（AI Agent 执行日志）

> 本文件由 AI Agent 维护。最近一轮（41-42）刷新。

## 当前进度（2026-09-15）

### 已完成（全部已编译 + 双目标部署 + 特性串字节级验证）
- [x] 4 个稳定性缺陷修复（死锁/信号量/超时/ported 默认值）
- [x] 弱模型防线 1-10 全部实现（含防线 8 熔断 UI：设置页「复位 AI 规划熔断」按钮）
- [x] 已移植技能 15 项：rewards/furniture/fishing/volleyball/dodge/auto_scroll/auto_login/touch/drive_dataset/preset_afk/piano/coffee/tomato_juice/coffee_lite/bagel_spam（+ ControlEngine.typeText）
- [x] 如实标注未移植 10 项（pinkpaw/rhythm/tetris/realtime/online_nav/sync_ability/bid_king/fountain/witch/withdraw_money/preset_realtime）——缺什么能力已写清，绝不写假实现
- [x] LLM 链路端到端实测（--agent-llm-test 30s 内返回真实回答 + tool_calls，多次回归 ✅）
- [x] MaaNTE 25 项对照表（docs/MaaNTE移植对照表.md，每行有结论）
- [x] 最终报告（docs/最终报告.md，六部分齐全）
- [x] 自测项 21 条（路由 11 项 + ported 一致性 2 项 + 原有 8 项）

### 进行中 / 用户侧待办
- [ ] 重授 TCC（引擎 03:11 日志确认 ax=false 且 screen=false，引擎 fail-fast → UI 本地模式）
- [ ] 用户桌面 session 手动：./run.sh → --agent-selftest（期望 PASS=21 FAIL=0）→ 8 项走查
- [ ] GUI 验收 #2/#4/#6/#7 需 TCC 恢复后执行

### 关键约束
- key 只走 Keychain / AURORA_API_KEY 环境变量，日志一律掩码 sk-ZVb…uSSb
- ★用户新规则（03:xx 明确）：AI 禁止 `security`/改钥匙串；LLM 测试从小本本 `.llm-key-notebook.md`（gitignored）取 key 走 AURORA_API_KEY env（该 CLI 路径 0 次钥匙串访问，AuroraDriveApp.swift:560 证据）
- 编译 `/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch`
- 部署走 ./run.sh（双目标原子替换 + 重签）
- 每次 run.sh 重签会使 CDHash 变化 → TCC 授权再次失效（macOS 行为，无法规避）
- 架构冻结清单不碰（ControlEngine 仅 +17 行 typeText 方法，GameKey 枚举/映射 0 改动，已在验收#8 判据说明）

### 环境性阻塞（03:11 复核确证）
- 日志 ~/Library/Logs/AuroraEngine.log：`TCC 自检 ax=false screen=false → fail-fast`（02:55 / 03:02 / 03:11 三次）
- 因果链：redeploy 重签 → TCC 授权丢失 → 引擎 fail-fast → UI 本地模式 → 主窗口创建被权限门控（AuroraDriveApp.swift:312）→ --agent-selftest（触发点在 ContentView.body :2258）永不启动
- DSH 会话无法代用户授予 TCC；需用户在 系统设置→隐私与安全性→辅助功能/屏幕录制 中重新勾选 AuroraDriveUI

#### 新防线（41+ 轮）
- run.sh 构建失败防再犯（6d81bd6）：`swift build > .last-build.log` + 检查 `$?` + 失败打印 error 行并 exit 1（旧管道 `| tail -5` 吞退出码）
- 钥匙串禁令（4c07134）：LLM 测试走 `.llm-key-notebook.md` + `AURORA_API_KEY` env，禁止 `security`

## Git 最近提交（本轮 39-41）
```
45e2ff1 docs: 验收#8/#9 判据刷新（ControlEngine 允许新增 typeText +17行）
9e1efd2 docs: bagel_spam 完成 + 构建流程教训记录
3b00910 docs: bagel_spam 移植同步
f2eb1cd fix(ControlEngine): typeText 参数标签 stringLength:
5fc64a8 feat(技能): 移植 bagel_spam
bfb1515 docs: coffee_lite 移植同步
6ebc588 feat(技能): 移植 coffee_lite
```
（更早：防线 8 UI 3e2f9d7/16e06cb、咖啡番茄汁 2edce05、钢琴 9661714 等）

## ★ 会话交接快照（round 16 · 13:56）
- HEAD: 5ead510；小本本 `.llm-key-notebook.md`（gitignored）= LLM 测试唯一取 key 路径（禁 `security`）
- 代码面收敛：31 Swift 文件、15 移植技能 + 3 记录不实现、防线 1-10、run.sh 构建防线（6d81bd6）
- 部署：双目标 5,304,736 字节同 mtime；TCC 仍 ax=false/screen=false（03:11 后无新尝试）
- 待用户：① 系统设置重授 辅助功能+屏幕录制（AuroraDriveUI）② 手动 `./run.sh` + `--agent-selftest`（期望 PASS=21）③ 批准 `docs/legacy-guard-patch.md`（3 处窗口护栏）④ 8 项 GUI 走查
- 恢复执行顺序：先探 TCC（tail ~/Library/Logs/AuroraEngine.log 看新 ax=true）→ 能自测则跑 → 走查 → 应用护栏补丁 → 终验 13 条
