# MaaNTE 移植对照表（25 项全量）

> 生成时间：2026-09-14（v3.2）
> 项目路径：`/Users/dupi/Desktop/自动驾驶系统`
> 参考源：`MaaNTE/`（Windows 专用，禁止照抄 Win32 API）
>
> 【2026-09-19 现状标注】本表为 09-14 快照，表体后续有更新但"统计"与"下一步"两节未同步（本 09-19 修订已按表体重写统计、标注已完成的下一步）。项目定位已收敛为：**Maa 只做工具（ROI/模板/任务定义参考），不整体接管**，主力执行通道仍是 Swift `AgentSkillCenter.runSkill`（见 `docs/AI-Agent最终实施方案.md` 09-19 定位澄清）。MaaNTE 侧截至 2026-09-19：250 节点 ROI override 已生成（`build/maa_pipeline_override.json`），剩 24 个缺模板节点待实机采集（见 `docs/界面采集作业指令.md`）；BidKing（拍卖王）PR#434 代码已提取至独立文件夹 `BidKing_PR434/`（git 7b7d2db，未合并主线），#5 的决策逻辑参考该文件夹。

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
| 5 | BidKing | `bid_king` | C | ❌ 缺失 | 需识别拍卖 UI 价格数字+倒计时；SpeedOCRReader 可读数字，缺决策逻辑。2026-09-19：上游 PR#434 代码已提取至 `BidKing_PR434/`（git 7b7d2db，未合并主线），可作移植参考 |
| 6 | PinkPawHeist | `pinkpaw` | C | ⚠️ 待移植 | 多阶段 UI（入口/选择/结算）；需 VisualLocator+OCR，缺阶段状态机 |
| 7 | MakeCoffee | `coffee` | A | ✅ 已移植 | F键交互×20轮（MaaNTE源=press_key_f循环）；commit 7a7e1e6 |
| 8 | MakeCoffeeLite | `coffee_lite` | A | ✅ 已移植 | 轻量 10 轮 × 1s F 交互（对应 MaaNTE make_count=10；macOS 用 F 键位等价，无 OCR 依赖） |
| 9 | MakeTomatoJuice | `tomato_juice` | A | ✅ 已移植 | F键×20轮（MaaNTE AutoMakeTomatoJuice 简化版，倒计时/双份服务未实现）；commit 2edce05 |
| 10 | Rhythm | `rhythm` | C | ⚠️ 待移植 | 音游音符识别；YoloEngine 可检测但 60fps 下性能未验证 |
| 11 | Tetris | `tetris` | C | ❌ 缺失 | 棋盘格识别；需 YoloEngine 检测方块+切分网格，缺专用训练数据 |
| 12 | Volleyball | `volleyball` | — | ✅ | `AIAgentPanel.swift` startVolleyballLoop（K 键 0.6s 循环） |
| 13 | BagelSpam | `bagel_spam` | A | ✅ 已移植 | 内置中性文案 6 轮 × 2s 刷屏（ControlEngine.typeText Unicode 注入 f2eb1cd；需先开聊天框聚焦；MaaNTE 原版 LLM 文案未做） |
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
> 2026-09-19 修订：旧统计（9/4/12）与表体脱节（#7/#8/#9/#13/#19 在表体已标 ✅ 但仍列在待移植/缺失），以下为按当前表体重算的结果。
- ✅ 已移植：**14 项**（#1, #2, #4, #7, #8, #9, #12, #13, #16, #17, #19, #21, #23, #24）
- ⚠️ 待移植：**2 项**（#6, #10）
- ❌ 缺失：**9 项**（#3, #5, #11, #14, #15, #18, #20, #22, #25）

## 按优先级排序的下一步

### P0（可快速完成）
1. ~~`bagel_spam`：先给 ControlEngine 加 `typeText(_ text: String)` 方法 → 再实现刷屏循环~~ —— 已完成（#13，ControlEngine.typeText Unicode 注入 f2eb1cd）
2. ~~`piano`：内置 1-2 首简单曲目（G/H/I 音键序列），不需要 MIDI 解析~~ —— 已完成（#19，3 首内置曲目）

### P1（中等复杂度）
3. ~~`coffee`/`coffee_lite`/`tomato_juice`~~：☕/🥛/🍅 已移植为键序循环（F 交互，无 OCR 依赖）
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
