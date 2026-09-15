# AuroraDrive 进度追踪（AI Agent 执行日志）

> 本文件由 AI Agent 维护。最近一轮（2026-09-15 晚 23:3x）刷新。

## 当前进度（2026-09-15 晚）

### 已完成（全部已编译 + 双目标部署 + 特性串字节级验证）
- [x] 4 个稳定性缺陷修复（死锁/信号量/超时/ported 默认值）
- [x] 弱模型防线 1-10 全部实现（含防线 8 熔断 UI：设置页「复位 AI 规划熔断」按钮）
- [x] 已移植技能 15 项（rewards/furniture/fishing/volleyball/dodge/auto_scroll/auto_login/touch/drive_dataset/preset_afk/piano/coffee/tomato_juice/coffee_lite/bagel_spam，+ ControlEngine.typeText）
- [x] 未移植 3 项如实标注（pinkpaw/rhythm/preset_realtime，面板默认隐藏 + 「显示待移植技能(3)」开关）
- [x] 自测 21 条，**2026-09-15 晚真实 GUI 会话跑通 PASS=21 FAIL=0**（d8cf729 修 1 条自测指令 bug：「刷个屏」→「贝果刷屏」）
- [x] LLM 链路端到端实测（env 小本本路径 0 钥匙串 + tool_calls volleyball + 错 key 401 快速失败降级）
- [x] **钥匙串整体移除（1b06802，用户指令"每次启动访问密码库，起不来"）**：API key 存储 钥匙串→本地小本本文件 `~/Library/Application Support/AuroraDrive/llm-key-notebook.txt`（0600），源码 `SecItem*` 残留 0；app 启动路径 0 钥匙串接触
- [x] **用户 3 项 UI 修复**：① 模型菜单改 API /models 真实清单，假模型（Claude 3.5/GPT-4o/Gemini 2.0/DeepSeek-V3）移除，选中直写 aiSettings.model（d43b253）② 「⚡ 一键自动化挂机」按钮（preset_afk：领奖励→收家具→钓鱼，可整体停止）+ 待移植默认隐藏（039daba）③ 快速填充不再清空 API Key（保存禁用根因）+ 新增 Agnes 示例（1980bc9）
- [x] 电脑走查 #1-#7 computer-use 实测通过（23:2x-23:3x：启动/面板外扩/设置页小本本回显/钓鱼 12 轮自动结束+teardown/复合指令真实 LLM 3s 规划 3 技能/「停止」/权限缺失 0 乱点）；#8 UI 稳定 20min+，引擎连接半项待屏幕录制重授
- [x] MaaNTE 25 项对照表 + 最终报告六部分（§二/§三 已更新至晚 23:3x 证据）

### 进行中 / 用户侧待办
- [ ] **重授 TCC 屏幕录制**（当前引擎自检 ax=true / screen=false → fail-fast，UI 本地模式）：系统设置 → 隐私与安全性 → 屏幕录制，AuroraDriveUI 开关一次
- [ ] **批准 legacy 护栏补丁**（docs/legacy-guard-patch.md，3 处 1 行 guard，锚点复核生效）——★23:24 走查实锤：游戏未开时 legacy 钓鱼在桌面真实按 F 键（§五#9 已升级紧急）；用户回"批"后 1 轮内应用
- [ ] #8 引擎连接稳定性半项：屏幕录制重授后补验

### 关键约束
- key 只走 **本地小本本**（app 运行时存储）/ `.llm-key-notebook.md`（gitignored 测试源）+ AURORA_API_KEY 环境变量；**app 与 AI 均 0 钥匙串访问**（1b06802 起），日志一律掩码 sk-ZVb…uSSb
- 编译 `/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch`
- 部署走 ./run.sh（双目标原子替换 + 重签；重签会使 TCC 再失效，须重授）
- 架构冻结清单不碰（ControlEngine 仅 +17 行 typeText；老技能方法只加不改 → legacy 护栏走用户批准的补丁）
- 本地 git 只加不 push；每 15 工具调用做一次全项目分析

### 当前 HEAD 与部署
- HEAD `a987ccc`；本段 commit 链：d8cf729→1b06802→d43b253→039daba→f53f378→1980bc9→d9d86b9→a987ccc
- 部署目标：run.sh 双目标（23:12 最后一次重签部署）；app pid 47184 运行中（本地模式，引擎 fail-fast）

### 环境性阻塞（晚 23:3x 复核）
- 引擎自检 ax=true（辅助功能已恢复）/ screen=false（屏幕录制未重授）→ 引擎 fail-fast → UI 本地模式；本地模式下走查 #4-7 仍可完成（已完成）
- DSH 会话无法代用户授予 TCC；需用户在 系统设置→隐私与安全性→屏幕录制 中重新勾选 AuroraDriveUI

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
