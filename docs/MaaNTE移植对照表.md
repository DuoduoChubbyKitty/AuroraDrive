# MaaNTE 移植对照表（25 项全量）

> 生成时间：2026-09-14（v3.2）
> 项目路径：`/Users/dupi/Desktop/自动驾驶系统`
> 参考源：`MaaNTE/`（Windows 专用，禁止照抄 Win32 API）

## 状态图例
- ✅ 已移植（macOS 实现可用）
- ⚠️ 待移植（面板有按钮，功能未实现）
- ❌ 缺失（面板无按钮）

## 对照表

| # | MaaNTE 任务 | 面板 ID | 分类 | 状态 | 实现位置 / 缺什么 |
|---|---|---|---|---|---|
| 1 | ClaimRewards | `rewards` | — | ✅ | `AIAgentPanel.swift` performUIClickLoop（OCR 点击循环） |
| 2 | Furniture | `furniture` | — | ✅ | 同上（共用 performUIClickLoop） |
| 3 | WithdrawMoney | `withdraw_money` | A | ❌ 缺失 | 需 OCR 定位金额选项，SpeedOCRReader 可复用但需写新 case |
| 4 | Fish | `fishing` | — | ✅ | `AIAgentPanel.swift` performFishingLoop（F 抛竿/收杆循环） |
| 5 | BidKing | `bid_king` | C | ❌ 缺失 | 需识别拍卖 UI 价格数字+倒计时；SpeedOCRReader 可读数字，缺决策逻辑 |
| 6 | PinkPawHeist | `pinkpaw` | C | ⚠️ 待移植 | 多阶段 UI（入口/选择/结算）；需 VisualLocator+OCR，缺阶段状态机 |
| 7 | MakeCoffee | `coffee` | A | ⚠️ 待移植 | 需 OCR 识别"开始营业"按钮+菜单导航；SpeedOCRReader 可用，缺完整流程 |
| 8 | MakeCoffeeLite | `coffee_lite` | A | ❌ 缺失 | 同 coffee 简化版；缺 OCR 定位+点击序列 |
| 9 | MakeTomatoJuice | `tomato_juice` | A | ❌ 缺失 | 同 coffee 模式；需 OCR 定位+键序循环 |
| 10 | Rhythm | `rhythm` | C | ⚠️ 待移植 | 音游音符识别；YoloEngine 可检测但 60fps 下性能未验证 |
| 11 | Tetris | `tetris` | C | ❌ 缺失 | 棋盘格识别；需 YoloEngine 检测方块+切分网格，缺专用训练数据 |
| 12 | Volleyball | `volleyball` | — | ✅ | `AIAgentPanel.swift` startVolleyballLoop（K 键 0.6s 循环） |
| 13 | BagelSpam | `bagel_spam` | A | ❌ 缺失 | 文本输入刷屏；ControlEngine 无 typeText 方法，需先加文本输入支持 |
| 14 | RealTime | `realtime` | C | ❌ 缺失 | 实时战斗辅助；需 YoloEngine 识别+快速反应，缺专用模型 |
| 15 | OnlineMapNavigation | `online_nav` | C | ❌ 缺失 | 地图定位+路线；NetworkLocator 已有地图能力，缺路线生成+自动走 |
| 16 | SoundDodge | `dodge` | — | ✅ | `AIAgentPanel.swift` performDodgeLoop（Space+Shift 闪避循环） |
| 17 | AutoFScroll | `auto_scroll` | — | ✅ | `AIAgentPanel.swift` performAutoScroll（F 连点+滚轮） |
| 18 | FountainCheckin | `fountain` | A | ❌ 缺失 | 需路线导航+OCR 识别喷泉名；复杂多阶段流程，缺导航+识别 |
| 19 | AutoPiano | `piano` | A | ✅ 已移植 | 3首内置曲目（小星星/欢乐颂/生日快乐），0.4s节拍循环 |
| 20 | WitchDivination | `witch` | A | ❌ 缺失 | 固定点击序列+OCR；需先完成 fountain 级别的 OCR 定位 |
| 21 | AutonomousDrivingDataset | `drive_dataset` | B | ✅ | `AIAgentPanel.swift` startDriveDatasetLoop（2Hz WASD 采样+RecordEngine） |
| 22 | SyncCharacterAbilityCityAbility | `sync_ability` | C | ❌ 缺失 | 多步 UI 操作（角色能力面板）；步骤可固定但需 OCR 定位每个按钮 |
| 23 | Touch | `touch` | A | ✅ | `AIAgentPanel.swift` startTouchLoop（F→点击→ESC ×10） |
| 24 | preset/AFK | `preset_afk` | D | ✅ | `AIAgentPanel.swift` startPresetAFK（rewards→furniture→fishing） |
| 25 | preset/RealtimeAssistance | `preset_realtime` | D | ❌ 缺失 | 依赖 C 类 realtime 未实现；dodge 可用，realtime 部分待移植 |

## 统计
- ✅ 已实现：**9 项**（#1, #2, #4, #12, #16, #17, #21, #23, #24）
- ⚠️ 待移植：**4 项**（#6, #7, #10, #19）
- ❌ 缺失：**12 项**（#3, #5, #8, #9, #11, #13, #14, #15, #18, #20, #22, #25）

## 按优先级排序的下一步

### P0（可快速完成）
1. `bagel_spam`：先给 ControlEngine 加 `typeText(_ text: String)` 方法 → 再实现刷屏循环
2. `piano`：内置 1-2 首简单曲目（G/H/I 音键序列），不需要 MIDI 解析

### P1（中等复杂度）
3. `coffee`/`coffee_lite`/`tomato_juice`：OCR 定位"开始营业"按钮 → 固定点击序列
4. `withdraw_money`：OCR 定位金额选项 → 点击
5. `fountain`/`witch`：多步点击序列（需先有导航到目标位置的能力）

### P2（需 CV 能力）
6. `bid_king`：价格数字 OCR + 加价决策
7. `pinkpaw`：三阶段 UI 状态机
8. `rhythm`/`tetris`：需要 YoloEngine 模型训练
9. `online_nav`：复用 NetworkLocator + 路线生成
10. `realtime`/`preset_realtime`：战斗状态识别

## macOS 平台映射表（通用）
| Windows API | macOS 等价 | 备注 |
|---|---|---|
| GetAsyncKeyState | CGEventSource.keyState | drive_dataset 已用 |
| PrintWindow | SCStream（CaptureEngine） | 已有 |
| PostMessage/KeyBD | CGEvent（ControlEngine） | 已有 |
| 模板匹配 | VisualLocator | 已有 |
| YOLO 推理 | YoloEngine | 已有 |
| OCR | SpeedOCRReader | 已有 |
