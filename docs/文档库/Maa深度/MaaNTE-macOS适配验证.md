# MaaNTE macOS 适配验证记录

> 【2026-09-19 档案标注】本文为纯验证记录，正文保留，结论仍有效。文中引用路径（`data/mac_shots/`、`MaaNTE/assets/...`、`tools/maa_roi_offset.py`、`build/maa_pipeline_override.json`）均在本地保留，未受 2026-09-19 磁盘清理影响；同期已迁移外置硬盘（`/Volumes/代码项目/删除_20260919/自动驾驶系统清理/`）的素材为 `data/web_frames`、`build/vid_*.mp4` 等批量视频/网络素材，本文正文未直接引用。
>
> 验证对象：`MaaNTE/assets/resource/base/pipeline/`
> 环境：macOS，游戏窗口 1470×923（逻辑），retina 2x
> 缩放：`ScreenshotTargetLongSide = 1280` → 截图 1280×803

## 结论速览

| 项目 | 结果 |
|---|---|
| 场景检测模板（`Common/Scene/*`） | ✅ 零修改可用 |
| `PinkPawHeist_CheckGateOnce`（OCR） | ✅ 零修改可用（实测） |
| 底部锚定 UI 模板 | ⚠️ 需 Δy ≈ +83px ROI 偏移 |
| 顶部锚定 UI 模板 | ✅ 无需偏移 |

---

## 1. 坐标系约定

游戏内容区在窗口内 1:1 映射，因此：

```
屏幕坐标 = 截图坐标 + (0, 33)        # 33 = 窗口 frame 的 y
```

1280 空间（MaaNTE 原始坐标）到 1470 空间：

```
x_1470 = x_1280 × 1.1484
y_1470 = y_1280 × 1.1484
```

---

## 2. `PinkPawHeist_CheckGateOnce` 实测

**节点定义**（`PinkPawHeist/tools.json`）：

```json
{
  "desc": "单次检测铁门",
  "recognition": {
    "type": "OCR",
    "param": {
      "expected": ["强制开启", "強制開啟", "(?i)Force\\s*Open", "強制解錠", "강제 오픈"],
      "roi": [770, 337, 210, 116]
    }
  },
  "action": { "type": "DoNothing" },
  "timeout": 1500,
  "max_hit": 1
}
```

**验证方法**：

1. 取实拍截图（2940×1912 物理）
2. 裁出游戏内容区 2940×1846
3. 按 Maa 的缩放规则缩到 1280×803
4. 用**原始** ROI `[770, 337, 210, 116]` 裁片
5. 送 OCR

**结果**：`强制开启` — 完全匹配 `expected` 第一项。

**对位细节**（1470 空间换算后）：

| | x 范围 | y 范围 |
|---|---|---|
| MaaNTE ROI | 884 – 1125 | 387 – 520 |
| 实测文字 | 927 – 1055 | 474 – 507 |
| 余量 | 左 43 / 右 70 | 上 87 / 下 13 |

文字完整落在 ROI 内，中心偏移 (-14, +36)。**下沿余量仅 13px**，若日后出现识别不稳定，用 `expand` 模式把 ROI 高度 +40 即可。

---

## 3. ROI 偏移规则

### 3.1 现象

macOS 上游戏窗口为 1470×923（比例 1.593:1），MaaNTE 设计基线为 1280×720（1.778:1）。Maa 只有等比缩放，没有跨宽高比适配，导致：

- **顶部锚定**的 UI：Δy ≈ 0–1px（无需处理）
- **底部锚定**的 UI：Δy = **+83px**（需要处理）

### 3.2 独立样本（≥10 个）

| 模板 | Δy |
|---|---|
| `VolleyballStartButton` | +83 |
| `BagelSpamOpenBagel` | +94 |
| `BagelSpamOpenCamera` | +77 |
| `BagelSpamTakeShot` | +61 |
| `BagelSpamClickRelease` | +85 |
| `FishChooseGeneralBait` | +84 |
| `BagelSpamSaveShot` | +99 |
| `BidKingExit` | +107 |

### 3.3 处理方式

用 `pipeline_override` 走 `expand` 模式：ROI 高度 +83，覆盖上下两种锚定情形，无需逐个分类。

```python
# tools/maa_roi_offset.py
build_override(mode='expand')   # -> build/maa_pipeline_override.json
```

已生成 250 条 override，其中 177 条不受影响、73 条需要 +83。

**已被两个反例验证安全性**：`SelectDifficulty` / `ChooseTeammate`（顶部锚定）与 `StartButton`（底部锚定）在同一套 expand 规则下都正常工作。

---

## 4. 场景检测模板

`Common/Scene/*` 在 macOS 上**完全无需修改**，实测匹配分：

| 模板 | 分数 |
|---|---|
| `SceneScarboroughFair` | 0.977 |
| `SceneBattlePass` | 0.973 |
| `SceneCityTycoon` | 0.972 |

全部在 ROI 原点 (20,20) 的 `[0,0,80,80]` 区域内命中。

---

## 5. 粉爪大劫案实采流程

从实机采集（`data/mac_shots/`）还原的流程：

```
小吱（大堂经理）对话
  └─ 选「我要参加」
       └─ 粉爪大劫案入口面板（挑战时间 12 分）
            └─ 点「进入」
                 ├─ 加载页（"拉冬"设定 + KEEP OUT 胶带）
                 ├─ 剧情过场（电视雪花 + 旁白）  ← SkipStory 目标
                 └─ G-接待大厅（倒计时 11:35 起）
                      ├─ 走廊铁栅门 → 「强制开启」(F)
                      ├─ 保险箱房间（终端 / 蓝白保险柜）
                      ├─ 金库大厅（金色雕像 + 敌人）
                      ├─ 战斗（火球 / 紫色特效）
                      └─ 剧情立绘（粉发角色 + 猫头鹰）
```

**关键交互**：铁栅门用 **F** 键（「强制开启」红标签）。

对应模板文件：`PinkPawHeist/PinkPawHeist_SkipStory.png`、`heist_interac_lock_pick.png`、`heist_lock_pick.png`、`interactable.png`

---

## 6. 采集工具

| 工具 | 用途 |
|---|---|
| `tools/cgrab.py` | ctypes CoreGraphics 截屏（无 pyobjc 依赖） |
| `tools/watch_collect.py` | 循环采集 + 帧差去重，只在游戏前台时存盘 |
| `tools/hid_key.c` → `hid_key` | HID 层按键注入（唯一能驱动本游戏的方式） |
| `tools/hid_look.c` → `hid_look` | 右键拖拽转视角 |

**输入注入契约**（必须保持）：

```
CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
CGEventPost(kCGHIDEventTap, ...)
kCGKeyboardEventAutorepeat = 0        // 必须每次都是新按下
按住键需以 ~30Hz 重复发送 keyDown
```

`.combinedSessionState` / `.privateState` 无效；`cliclick` / `osascript key down` 无法移动角色。
