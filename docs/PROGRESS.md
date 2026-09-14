# AuroraDrive 进度追踪（AI Agent 执行日志）

> 本文件由 AI Agent 维护，记录每轮工作的进度。
> 用户要求：不要简化，全部完整实现。

## 当前进度（2026-09-14）

### 已完成
- [x] 4 个稳定性缺陷修复（commit 4186aa8）
  - ① --agent-llm-test 死锁 → 纯同步 HTTP + 30s 超时
  - ② sendUserMessage 信号量 → Task 后台 + MainActor
  - ③ URLSession 无超时 → 专用 llmSession (30s/45s)
  - ④ ported 默认值 true → false
- [x] 弱模型防线 1（提示词与 tool calling 一致）+ 防线 3（三重校验）
- [x] LLM 动态 tools 过滤（只给 ported:true 的技能）
- [x] 移植 touch 技能（commit f67b9f2）
- [x] 移植 drive_dataset 技能（commit bbf461c）
- [x] 移植 preset_afk 技能（commit 62b8851）
- [x] MaaNTE 移植对照表文档（commit 6c9de25）
- [x] LLM CLI 测试修复（AURORA_API_KEY env var，不走 Keychain）

### 进行中
- [ ] 移植 piano 技能（3首内置曲目，完整节拍）
- [ ] 编译验证（上次被打断）

### 待做
- [ ] 移植 coffee / coffee_lite / tomato_juice（A类）
- [ ] 移植 fountain / witch（A类，需点击序列）
- [ ] 移植 bagel_spam（需 ControlEngine.typeText）
- [ ] C类评估 + 待移植标注
- [ ] 阶段 3 电脑操作验收（computer-use）
- [ ] 最终报告

### 关键约束
- 不走 Keychain（用 AURORA_API_KEY 环境变量）
- 编译用 scratch path
- 部署必须 codesign
- 架构冻结清单不碰

### Git 历史（本轮）
```
819411b chore: preset_realtime 占位
6c9de25 docs: MaaNTE 移植对照表
62b8851 feat: preset_afk
9df38ac feat: callLLM 动态过滤
ffa9285 chore: 清理 debug
897a236 fix: LLM CLI Keychain 阻塞
bbf461c feat: drive_dataset
f67b9f2 feat: touch
4186aa8 fix: 4个稳定性缺陷
```
