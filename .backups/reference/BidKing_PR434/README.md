# BidKing（自动竞价）PR #434 代码提取

> 来源：[1bananachicken/MaaNTE PR #434](https://github.com/1bananachicken/MaaNTE/pull/434)
> 作者：Dawnprincess（fork 分支 `feat/BidKing`，commit `3cdbca9`）
> 状态：**Open，尚未合并到 dev**（截至 2026-09-19）
> 本文件夹只是把 PR 里 BidKing 相关的文件单独抽出来看，**没有合并进 MaaNTE dev 工作区**。

---

## 文件清单

```
BidKing_PR434/
├── README.md                ← 本文档
├── pipeline/                ← Pipeline 流程定义（MaaFramework V2 格式）
│   ├── BidKing.json         ← 主流程：入口→轮次循环→开始→出价轮询→退出
│   └── BidKingStatus.json   ← 轮询候选状态节点（二次确认弹窗/面板残留自愈；跳过与出价节点在主流程里）
└── agent/                   ← Python 自定义动作（MaNTE agent 侧）
    ├── place_bid.py         ← 出价入口动作（策略调度 + 公共输入层）
    ├── layout.py            ← 固定屏幕布局常量（1280×720）
    ├── utils.py             ← OCR 读取 + 价格解析工具
    └── strategies/          ← 出价策略（注册表模式）
        ├── __init__.py      ← 策略注册表（@register 装饰器）
        ├── fixed_price.py   ← 固定价格策略（默认每轮出 1）
        └── valuation.py     ← 保底出价策略（OCR 读系统最低估价）
```

> PR 里还有 5 个 locale 翎翻译文件和 `interface.json`/`tasks/BidKing.json` 注册，
> 属于"接进去才能跑"的配套，没抽（本地 dev 已有 tasks/BidKing.json 的早期版本）。

---

## 竞价流程（Pipeline 主线）

```
BidKingEntrance（进拍卖界面）
  → BidKingRound（最多 20 轮）
    → BidKingStart（点开始）
      → BidKingConfirm（确认开始）
        → BidKingBalance（等余额标识出现）
          → BidKingWaitBidOrSkip（核心轮询）
             ├─ 高价二次确认弹窗 BidKingPopupConfirm → 点确认 → 回轮询
             ├─ 跳过 BidKingSkip → 点跳过 → BidKingExit（本轮结束）
             ├─ 面板残留 BidKingClosePanel → 点 X → 回轮询（自愈）
             └─ 出价 BidKingBid → 点出价 → BidKingSelectOne
                  → place_bid（Python：策略算金额→清空→逐位输入→回读校验）
                  → BidKingConfirmBid（点确认出价）→ 回轮询
```

出价输入/确认两步（`BidKingSelectOne`/`BidKingConfirmBid`）配了 `on_error` 回 `BidKingWaitBidOrSkip` 自愈；一轮完整结束后点退出（`BidKingExit`）进入下一轮，`max_hit` 20 轮用尽则由 `BidKingTaskExit` 结束任务。

---

## 核心设计（值得抄的地方）

### 1. 策略注册表模式（strategies/__init__.py）

```python
STRATEGIES: dict[str, Strategy] = {}      # 策略名 → decide 函数
DEFAULT_STRATEGY = "fixed"                 # 未知策略回落

@register("fixed")                         # 导入即注册
def decide(context, controller, params, ui) -> Optional[int]: ...

def get_strategy(name) -> tuple[Strategy, bool]: ...   # (策略实现, 是否回落)；未知名字回落默认策略
```

新增策略两步：新建模块 + `@register("名字")`，末尾 import 一次。
策略**只算数不点击**：点击顺序/确认提交全在 place_bid 公共层，职责干净。

### 2. 公共输入层（place_bid.py）

- `clear_and_type`：清空输入框 → 把目标金额转成数字序列 → 逐位点屏幕数字键盘
- `verify_readback`：OCR 回读输入框校验；不一致**只重输一次**，再不一致就交给
  Pipeline（防死循环）。完全读不到不重输（大概率是 OCR 的问题不是点错）

### 3. 价格解析防误读（utils.py `extract_price`）

- 全角转半角（OCR 常返回全角数字）
- **整串匹配**两种写法：千位分隔 `1,222,418`（分隔符 `,` 或 `.` 都接受，OCR 常把逗号读成小数点）/ 纯数字 `839`
- 不匹配直接返回 None —— `可输入范围0~2,524,741`、`1.23M` 这类文本**必须失败**，
  避免把提示文字读成余额

### 4. 等画面稳定（valuation.py `wait_until_stable`）

- 每轮新情报先展示 → 更新包裹 → 更新顶栏估价；只有情报卡片区域静止了，
  顶栏才是新估价
- 判定：连续 0.8s 像素变化占比 ≤ 0.001（容忍鼠标指针），上限 12s
- 稳定后**再等 5s**（估价更新本身看不见，只能等）
- 稳定区域只框情报卡片列，**不包含包裹区** —— 包裹物品品质光效会让画面
  永远"不稳定"（作者实测撞 12s 超时的坑）

### 5. 三级兜底（valuation.py）

```
估价读不到 → 点"上轮出价"沿用 → 仍空/0 → 出 1
估价为 0   → 短重试 1.5s → 仍为 0 → 出 1
```

### 6. 固定布局坐标（layout.py，全部 1280×720）

| 区域 | 坐标 (x, y, w, h) |
|---|---|
| 顶栏系统估价 PRICE_ROI | (1077, 100, 161, 23) |
| 出价输入框 INPUT_ROI | (759, 505, 244, 30) |
| 上轮出价按钮 | (603, 532, 102, 52) |
| 清空按钮 CLEAR_BTN | (608, 615, 88, 60) |
| 数字键盘 0-9 | 3×4 网格，x∈{263,379,494}，y∈{360,445,530,615}，各 88×60 |
| 稳定判定区 SETTLE_ROI | (412, 163, 421, 431) |

坐标不走 custom_action_param 传入（防止前端覆盖丢失），固定写死在 layout。

---

## 已知问题（Sourcery 评审指出）

**place_bid.py 138 行附近**：策略返回 `None`/非正数表示放弃本轮时，
`PlaceBid.run` 仍返回 `success=True`，Pipeline 会顺着 `BidKingSelectOne`
的正常 next 边走到 `BidKingConfirmBid`（空金额点确认），而不是走
关闭面板的自愈路径。作者还没修 —— 如果要接入，注意这个边。

---

## 与 AuroraDrive 的关系

这是 MaaNTE（Windows/MaaFramework）的实现。macOS 侧移植时对应关系：

| MaaNTE 概念 | AuroraDrive 对应 |
|---|---|
| `controller.cached_image`（BGR numpy） | `CaptureEngine.currentFrame`（BGRA NSImage） |
| `JOCR` 区域识别 | `LoginAssistant.locateButton`（Vision OCR） |
| `click_rect(controller, roi)` | `MouseController.click(at:)` + `screenPoint(fromPixel:scale:)` |
| `post_key_down/up` | `ControlEngine.pressGameKey` |
| layout.py 固定 ROI | 同样可以按 1280×720 等比缩放映射 |
| 等画面稳定（numpy diff） | 截图帧对比（可复用同一阈值 0.8s / 0.001） |

竞价主循环（轮询状态机）可以用 AuroraDrive 的 OCR 点击全家桶
（`performUIClickLoop` 模式）+ 这个状态机结构直接移植。
