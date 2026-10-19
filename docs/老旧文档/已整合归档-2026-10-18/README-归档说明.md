# 已整合归档 · 2026-10-18

> **本目录存放的是「已被 `docs/整合文档/` 吸收」的原始文档。**
> 归档原因：内容已提炼进对应整合稿，原文数字大量过期，留着会被继续引用。
> **未删除**——本目录就是安全网，任何时候都能 `mv` 回去。

---

## 归档口径

| 归档组 | 篇数 | 被谁整合 | 归档理由 |
|---|---:|---|---|
| 性能类 `性能-*` / `优化-*` / `性能优化总结` 等 | 22 | `05-性能与优化全史.md` | 频率 45/30→20 全变；实测数据基线已过期 |
| 复杂版 `复杂版-W1~W8` | 7 | `05` | 同上；机制设计有价值但数值以源码为准 |
| 录制类 `录制前检查-*` / `录制验证-*` | 18 | `07-录制链路与数据契约.md` | CSV 5→9 列、视角恒 TPV、`maxClipsPerKind` 10→200 等全部变更 |
| 模型类 `主驾驶模型换代-*` / `双模型*` / `ANE*` 等 | 29 | `06-模型与训练实验.md` | `camera_heading` 无输入、`enableMultiSplit` 生产不可达、训练数据增长 100 倍 |
| 应急接管/AI 类 | 6 | `08-应急接管与智能体设计.md` | 「3 帧」实为 10 帧、「Key 存 Keychain」实为文件、端点拼装缺陷 |
| 车道线/朝向/其他单篇 | 10 | `06` / `07` | 零散结论已归入主题整合稿 |
| 早期设计（`trae/` 子目录） | 3 | `03-早期设计与实测报告归档.md` | Tauri 路线废弃、Web/Python/C++ 栈 100% 已死 |
| 工具链 | 3 | `01-工具链与训练手册.md` | `STAGE01_REPORT` 的 venv 已不存在、`PATCH_multi_split_chunk` 的 Bug 已修 |
| **合计** | **99 + 3(trae)** | | |

---

## 明确**没有**归档的（仍在使用）

| 对象 | 位置 | 理由 |
|---|---|---|
| 37 篇代码系列 | `docs/文档库/自动驾驶与功能/代码-*.md` | 已全部复核修订（260+ 条修正） |
| `00-文档索引.md` / `DEVELOPER_GUIDE.md` / `pitfalls.md` / `bpf-daemon.md` / `legacy-guard-patch.md` | 同上 | 索引与开发者文档，仍在用 |
| `docs/文档库/Maa深度/` 16 篇 | 原位 | 整合进 `10~13` 但**原件保留**（未复制到本归档） |
| `verify/REPORT-llm.md` / `REPORT-llm-perf.md` / `REPORT-task-3.md` | `verify/` | **可复现实测证据**，过期的只是数字不是方法论 |
| `verify/evidence-llm/`（22 txt）+ `evidence-llm-perf/`（16 txt）+ `evidence/` | `verify/` | 报告里每个数字的原始输出，最值钱的部分 |
| `.dsh-workspace-notes/` 10 篇笔记 | 原位 | 勘察原始记录（`04` 已整合但保留原件备查） |
| `README.md` / `README.en.md` / `NOTICE` | 根目录 | 项目门面 |
| `.workbuddy/memory/MEMORY.md` | 原位 | 项目铁律与踩坑全集 |
| `tools/yolopx/README.md` | 原位 | ⚠️ **待你决定**：它是上游仓库克隆，见下 |

---

## 一个需要你确认的残留

**`tools/yolopx/README.md`（260 行）** —— 实测是上游 `github.com/jiaoZ7688/YOLOPX` 的 README 原样克隆（`.git` origin 证实），里面全是论文在 N 卡上的指标（32.9M 参数 / 47fps / BDD100K 93.7%），与本机 CoreML/ANE 表现无关。

**我建议**：改名为 `UPSTREAM-README.md` 并在开头加一行说明，而不是删——因为 `tools/yolopx/.git` 还指向上游，将来可能还要 `git pull`。

**没动它，等你一句话。**

---

## 恢复方式

```bash
# 恢复某一篇
mv "docs/老旧文档/已整合归档-2026-10-18/<文件名>" "docs/文档库/自动驾驶与功能/"

# 全部恢复
mv docs/老旧文档/已整合归档-2026-10-18/*.md docs/文档库/自动驾驶与功能/
mv docs/老旧文档/已整合归档-2026-10-18/trae/* .trae/documents/ 2>/dev/null
```

---

## 同批处理的其他文件

| 对象 | 处置 | 位置 |
|---|---|---|
| `models/split/`（32M，全仓无引用） | 移入备份 | `.backups/deleted-20261018/models_split-32M-无引用/` |
| `量化ctl.py`（指向外部目录） | 移入备份 | `.backups/deleted-20261018/量化ctl.py` |
| `orldToMapPixelXp` / `orldToMapPixelp`（0 字节垃圾，队友误建） | 删除 | — |
| `Package.swift` 的 `exclude` | 补 `.agents` / `.backups` / `docs` 三项 | `check-package-sources.sh` 现已全绿 |

---

*生成时间：2026-10-18*
