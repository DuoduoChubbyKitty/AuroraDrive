# AuroraDrive 进度追踪（AI Agent 执行日志）

> 本文件由 AI Agent 维护，记录每轮工作的进度。
> 用户要求：不要简化，全部完整实现。

## 当前进度（2026-09-14）

### 已完成
- [x] 4 个稳定性缺陷修复
- [x] 弱模型防线 1+3
- [x] LLM 动态 tools 过滤
- [x] 移植 touch / drive_dataset / preset_afk / piano
- [x] MaaNTE 移植对照表文档
- [x] LLM CLI 测试（env var，不走 Keychain）
- [x] 编译 0 error 验证通过
- [x] LLM 实测通过（1+1=2 + tool_calls）

### 进行中
- [ ] 阶段 3 电脑操作验收（SwiftUI 窗口 accessibility 受限）
- [ ] C 类评估文档（coffee/fountain/bagel 确认需 OCR）
- [ ] 最终报告

### 待做
- [ ] 部署 run.sh（双目标同步）
- [ ] 部署后验证 md5 一致
- [ ] 完整 13 条验收

### 关键约束
- 不走 Keychain（用 AURORA_API_KEY 环境变量）
- 编译用 scratch path
- 不删 .build/scratch（上次误删导致全量重建）

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

### 环境性阻塞（本轮确证）
- TCC 辅助功能授权丢失：AuroraTCCSelfTest.log 历史 ax=true→false（redeploy 重签后 CDHash 变化）
- 因果链：TCC ax=false → 引擎 fail-fast → UI 本地模式 → 主窗口创建被权限门控（AuroraDriveApp.swift:312 注释）→ --agent-selftest（触发点在 ContentView.body :2258）永不启动
- GUI 自测（验收#2）与窗口级 computer-use 走查（验收#6）需用户在正常桌面 session + TCC 恢复后手动完成
