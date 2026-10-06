# ROI 反推规则（macOS 适配）

> 结论来源：623 节点全量匹配 + 实测位移反推。**不需要再录任何素材。**
>
> 【2026-09-19 现状标注】"不需要再录素材"指 ROI 反推规则本身无需新素材；截至 2026-09-19，全量 250 节点 override 已合入 `build/maa_pipeline_override.json`，但仍有 **24 个缺模板节点需实机采集**（清单见 `docs/文档库/探索文档/界面采集作业指令.md`：胜负加载屏、商店页、光标；SceneLoadingType2 的 '%' 与 Sync×6 疑似占位坏定义，可不采）。

## 一、根因（纯几何）

```
macOS 窗口 1470×923  --Maa 按长边缩放到 1280-->  1280×803
MaaNTE 基线（Windows）                      -->  1280×720
                                                  ↑ 高度差 H = 83px
```

Maa 只有等比缩放（`postproc_screenshot()` → `cv::resize`，`ScreenshotTargetLongSide=1280`），
**不做跨宽高比适配**。窗口比 16:9 高，多出来的 83px 全部加在底部。

## 二、推导出的规则

在 1280 宽的 Maa 坐标空间里：

| 方向 | 规则 | 依据 |
|---|---|---|
| **x** | `Δx = 0` | 两个空间宽度都是 1280，UI 按宽度缩放，横向完全对齐 |
| **y** | `Δy ∈ [0, +83]` | 顶部锚定=0；底部锚定=+83；中间线性。图只变高，元素不可能下移超过 83 |

**安全统一处理**：

```
新ROI = [x, y, w, h + 83 + 32]
                          └─ 安全边距：吸收取整、内边距差异、测量噪声
下边界钳到画面底（y + h ≤ 803）
```

## 三、实测验证

用「ROI 尺寸 == 模板尺寸」的干净样本读出真实位移（排除了 ROI 内边距干扰）：

| 节点 | y | 实测位移 |
|---|---|---|
| `VolleyballSkipStory` | 29 | +0 |
| `VolleyballWaitDifficultySelection` | 5 | +1 |
| `BidKingConfirm` | 455 | +41 |
| `VolleyballStartButton` | 655 | **+83** |
| `VolleyballStartButtonAfterTeammates` | 655 | **+83** |

**最大实测位移 = +83，与几何上界完全吻合** → 上界充分。

反例校正：`BidKingStart` 表面 Δy=+142，其中 59px 是 ROI 自身内边距，
真实位移仍是 +83（`758 − 83 = 675`，正是 Windows 原位置）。

## 四、产物

| 文件 | 内容 |
|---|---|
| `build/maa_pipeline_override.json` | **全量 250 个节点的 ROI override**（最终交付，`tools/maa_roi_offset.py` 生成），可直接喂 Maa 的 `pipeline_override` |
| `build/maa_override_all.json` | 181 个节点的 ROI override（规则套用档） |
| `build/maa_override_final.json` | 32 个节点的精确反推 override（实测位置档） |
| `build/maa_override_derived.json` | derived 26 + expand 35 的中间推导档 |
| `build/audit_result.json` | 原始数据：78 模板 × 159 样本的全部匹配分数与坐标 |
| `data/_gray_cache/` | 263 张 1280×803 灰度缓存。**2026-09-19 已随磁盘清理移到 `/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/（⚠️ 2026-09-29 路径订正：实际在「自动驾驶项目半成品版本1.0到10.0」目录内，原文少两级）`**；重跑审计需先重建缓存（原"有缓存 4 分钟"结论仍有效） |
| `tools/audit2.py` | 审计脚本 |
| `tools/full_audit.py` | 早期版本（含 fork 死锁，勿用） |
| `tools/maa_roi_offset.py` | 生成 `build/maa_pipeline_override.json` 的脚本 |

**override 分两档**（相对 181 节点档 `maa_override_all.json`）：
- 29 个：用实测位置反推（x、y 双向扩张，最准）
- 152 个：套几何规则（y 方向 +83 + 边距）

自检：**29/29 覆盖成功，0 失败**（15 个 x 方向串味样本已剔除）。

> 250 全量口径 = 上述各档的并集（`maa_override_all` 181 + `maa_override_final` 32 + `maa_override_derived` derived 26 / expand 35，有重叠），落地文件以 `build/maa_pipeline_override.json` 为准。

## 五、已知边界

1. **442 个节点无 ROI**（纯流程节点），不需要处理。
2. **164 个 OCR 节点**的 ROI 已按同一规则处理，但**期望文本本身还没验证过** —— OCR 靠的不是模板匹配，要在 macOS 上实跑才能确认。
3. **15 个串味样本**：模板是通用小图标（白按钮/关闭按钮），全图搜会匹配到别处的相似控件。这些节点的真实 ROI 仍未确定。
4. 规则基于「窗口长边缩放」这一前提。**若改了窗口尺寸或 Maa 的 ScreenshotTargetLongSide，全部失效。**

---

## 五、OCR 节点全量验证结果（补充）

### 5.1 正确的 OCR 推理管线（关键教训）

早期用「整块 ROI 直接喂 rec 模型」得到全空串，根因是三处管线缺陷：

```python
# ① 缺 det 阶段 —— PP-OCR 是两段式，整块 ROI 喂 rec 必然返回空串
#    现象：'' + mean_conf=0.951（模型"确信"这里没有一行文字）
# ② 检测框未外扩 —— rec 需要 2px padding 才能正确识别
# ③ 缩放用 INTER_LINEAR —— 应为 INTER_CUBIC
crop = img[y-2 : y+h+2, x-2 : x+w+2]
im = cv2.resize(crop, (rw, 48), interpolation=cv2.INTER_CUBIC)
```

修正后「强制开启」识别置信度 = **1.0**，四种缩放倍率全部正确。

模型选择：`ppocr_v6/medium`（18708 类）。`small` 档对小字号红字乏力（conf 0.39→0.85），
`tiny` 档是项目速度数字微调模型的基座（6904 类），不适用于中文界面。

### 5.2 A/B 结果

| 指标 | 原 ROI | 修正 ROI |
|---|---|---|
| OCR 命中 | 14/111 | **40/111** |
| TemplateMatch 命中 | 19/61 | **31/61** |
| 合计 | 33 | **71** |
| 被改坏 | — | **0** |

26 个 OCR 节点 + 12 个模板节点被 ROI 修正救回。

### 5.3 71 个 miss 的归因（结论：缺截图，非坐标）

对 71 个 miss 做全库文本搜索，发现 21 个"疑似 ROI 偏移"，逐一查证后**全部为假阳性**：

- 通用短词（`确认`/`购买`/`更换`/`新品`）在任何界面都能匹配 → 搜索条件无特异性
- 宽正则会大量误命中：`\d+\s*:\s*\d+` 命中 **160 处**
- 散文文本误命中：`魔女之家`、`店长特供` 出现在任务描述的长句里，不是 UI 按钮

排除假阳性后，**真实 ROI 偏移 = 0**。剩余 50 个节点的期望文案在全库中完全不存在
（喷泉许愿池、抚摸、面包圈、通行证领取、实时传送/剧情跳过、粉爪撤离、俄罗斯方块等场景）。

**结论：ROI 反推规则已到极限，无进一步优化空间。** 其余节点的验证只能等实机覆盖这些场景。

### 5.4 覆盖率实况（诚实口径）

| 类别 | 已验证 | 总数 |
|---|---|---|
| TemplateMatch | 31 | 82（可测 61） |
| OCR | 40 | 164（可测 111） |
| And / Or / ColorMatch | 0 | 90 |
| **识别类合计** | **71** | **336** |
| **覆盖率** | **21.1%** | |

不需要识别的节点 287 个（None 221 / DirectHit 65 / Custom 1）不计入分母。
