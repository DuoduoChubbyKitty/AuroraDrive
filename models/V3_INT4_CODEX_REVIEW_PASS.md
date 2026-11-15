# V3 INT4 部署复审通过记录

日期：2026-11-16
Codex 最终结论（第 7 轮 / HEAD 90a49c5）：**可以合入生产部署**，剩余阻断：无。

模型：models/v3_int4.mlmodelc（protect_backbone，9.66MiB，内容指纹 8431c781…）
自检 71/71；contract 31/31；审计 PASSED（rc0）；三档计算单元均通过。
已签字接受的残余风险：handbrake/super_brake 各 1 处 false→true 翻转（clip_20261104_211247_p00000#2006），见 V3_RESIDUAL_RISK_ACCEPT.md。

复审迭代：共 7 轮（R1~R6 整改），每轮均提交并经本机 clash 代理 push origin/main。
