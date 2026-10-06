# 代码-21 RuleController 规则控制器

> 覆盖源文件：`Sources/AuroraDrive/Agent/RuleController.swift`（**200 行，2026-10-06 `wc -l` 复测**）。基于当前仓库逐单元编写。**2026-09-25 深度复核**：9-24 性能优化改动 8 给 `struct Detection` 加了 `Equatable` 协议（源码 :29）+ 6 处「先比后写」消费点；**2026-10-06 复核**：源文件又增 13 行（187→200），核心是 `decide()` 内 **2026-10-02 取消规则侧自动刹车**（:141-152 注释，详见二节），行号以 200 行版为准（已逐条回读核实）。

## 〇、★ 在驾驶全链路中的位置（2026-10-06 补，行号已核实）

RuleController 是降级三档梯子里**最低档（.rule）的决策者**：`DriveState.tick()`（`App/AuroraDriveApp.swift:6384`）→ 降级状态机选档（:6686-6694，`Agent/DegradeStateMachine.swift:74-139`）→ `.rule` 档时 `ruleController.decide(detections:)`（AuroraDriveApp.swift:6879）产出 `ControlCommand` → `applyCommand`（:7321-7350）映射为按键。`.yolo` 档（`decide`）与 `.rule` 态（`fuse`）的语义见下文；⚠️ 融合入口 `fuse` 的档位语义随 laneKeepTiers（`AURORA_LANEKEEP_TIERS`，默认 `rule,yolo`，AuroraDriveApp.swift:5426-5428）放开而扩展——车道保持/分段覆盖叠加在 `.rule`、`.yolo` 两档的输出之上（:6917-6967）。

## 一、Detection 类型：危险区与紧迫度（第 1–70 行）

**定位（5-18 行头注释）**：YOLO 检测 → 控制量 规则控制器——把感知模型（game_assist_yolo）的障碍物检测结果，用规则转换为 steer/throttle/brake 控制量。

**用途（两个态）**：

- `.yolo` 态（YOLO_RULE）：**纯规则**——YOLO 检测 → 规则控制
- `.rule` 态（E2E_ASSISTED）：**E2E 输出 + 规则修正**（避障覆盖）

**四个设计要点（源注释原文，:14-18）**：① 检测框用归一化坐标 [0,1]，与图像分辨率解耦；② 只关心"正前方危险区"的障碍：水平中心带 + 垂直下方（近距）；③ 危险等级分三档：避让（转向绕开）/ 减速 / 急刹（⚠️ 2026-10-02 起"急刹档"也不再刹车，见二节）；④ .rule 态下与 E2E 输出融合：危险时规则覆盖，安全时信 E2E。

**`Detection`（struct: Equatable，第 29–70 行）**——单个障碍物检测结果（YOLO 输出解析后的统一格式），**所有坐标归一化到 [0,1]，原点左上角，与图像分辨率解耦**（Equatable 用途见 :27-28 注释：供 DriveState 先比后写，值不变时跳过 @Observable 写入；所有字段自动合成比较）：

| 字段 | 说明 |
|---|---|
| `x / y` | 边界框**中心** x/y [0,1]（**中心点 + 宽高格式**，与 YoloEngine.parse 的输出契约一致） |
| `width / height` | 宽/高 [0,1] |
| `label: Label` | 障碍物类别——enum：`car`（车辆）/ `pedestrian`（行人）/ `sign`（交通牌）/ `obstacle`（通用障碍） |
| `confidence` | 置信度 [0,1] |
| `rawName`（默认 "OBJ"） | **原始检测类名（COCO 类名，如 "CAR"/"PERSON"/"TRAFFIC LIGHT"）——仅用于 UI 画框时显示；规则决策只看 label**。有默认值 → 不影响既有的 Detection(x:y:width:height:label:confidence:) 调用 |

**`isInDangerZone(dangerHalfWidth: Double = 0.18, dangerYMin: Double = 0.45) -> Bool`（第 58–61 行）**——是否在"正前方危险区"：

```swift
abs(x - 0.5) < dangerHalfWidth && y > dangerYMin
```

危险区定义：**水平中心带（\|x-0.5\|<dangerHalfWidth）+ 垂直下方（y>dangerYMin，近距）**——y 大 = 画面下方 = 离车近（透视投影）。

**`urgency: Double`（计算属性，第 65–69 行）**——估算的"碰撞紧迫度" [0,1]：

```swift
let sizeScore = width * height                    // 框面积
let centerScore = 1.0 - abs(x - 0.5) * 2.0        // 居中度（中心=1，边缘=0）
return max(0, min(1, sizeScore * 8.0 * centerScore))
```

**框越大（越近）+ 越居中 → 紧迫度越高**；`× 8.0` 放大面积贡献（面积通常 0.0x~0.1 量级，×8 后进 0.2~0.8 可判档）；max/min 夹到 [0,1]。

## 二、decide() 三档决策与 fuse() 融合（第 72–200 行）

**类声明（第 78–79 行）**：`@Observable final class RuleController`——UI 可观察危险等级与最近障碍；**纯函数式：decide(detections, e2e?) → ControlCommand；无内部状态，线程安全**。

**五个可调阈值（第 83–96 行）：**

| 参数 | 默认值（行号） | 说明 |
|---|---|---|
| `dangerHalfWidth` | 0.18（:84） | 危险区水平半宽（中心带宽度 = 2 × 此值 = 0.36） |
| `dangerYMin` | 0.45（:87） | 危险区垂直下限（y 大于此值视为近距） |
| `hardBrakeUrgency` | 0.55（:90） | **急刹阈值**：紧迫度超过此值进入最高档避让（⚠️ 2026-10-02 起不再刹车，见下） |
| `brakeUrgency` | 0.25（:93） | **减速阈值**：紧迫度超过此值减速 |
| `steerStrength` | 1.0（:96） | 避让转向强度系数 |

**状态输出（第 100–109 行）**：`dangerLevel: DangerLevel`（enum :101-106：`.safe = "安全" / .caution = "注意" / .danger = "危险" / .critical = "急刹"`——rawValue 中文 UI 直接展示，默认 .safe）+ `nearestDetection: Detection?`（当前最紧迫障碍）。

**`decide(detections: [Detection]) -> ControlCommand`（第 116–175 行）**——纯规则决策（.yolo 态用）：

1. **找最紧迫障碍（118–121 行）**：`dangers = detections.filter { isInDangerZone }` → `nearest = dangers.max(by: urgency)` → `nearestDetection = nearest`
2. **无障碍（123–129 行）**：直行加速——`ControlCommand(steer: 0, throttle: 0.8, brake: 0, confidence: 0.8)`——源注释：**confidence 固定 0.8：直行是规则确定行为、无检测框可依，语义为"高但非满"的规则确定度（不再用危险等级反推置信度）**
3. **有障碍（131–174 行）**：置信度 = `obs.confidence`（**YOLO 检测置信度，反映"这个检测框可不可信"，与危险等级解耦**——危险等级仍由 urgency 独立分档，只决定 steer/throttle/brake，confidence 不再用危险等级分档给固定魔法值（原 0.4/0.5/0.6），注释 :134-137）；`offset = obs.x - 0.5`（负=左，正=右）

**★ 危险等级分档（2026-10-02 修改后现行行为，:141-174）：**

| urgency | 等级 | steer | throttle | brake |
|---|---|---|---|---|
| > 0.55 | `.critical` 急刹档 | `offset > 0 ? -1.0 : 1.0`（**向障碍反方向打满**，:156） | 0 | **0（恒 0）** |
| > 0.25 | `.danger` 危险 | `(offset > 0 ? -1.0 : 1.0) × steerStrength`（:163） | 0.2 | **0（恒 0）** |
| 其余 | `.caution` 注意 | `(offset > 0 ? -0.5 : 0.5) × steerStrength`（:170） | 0.6 | **0（恒 0）** |

**⚠️ 2026-10-02 重大行为变更（:141-152 注释，用户明确要求）：取消规则侧的一切自动刹车。**

- 原因（注释原文要义）：本游戏里 `brake` 唯一的物理含义是**按 S 键，而 S 键兼作倒车**——"自动刹车"实际等于"自动倒车"。用户实测：托管中车辆不停自动倒车、与用户抢控制权；用户想自主倒车脱困时被反复打断（倒车速度永远达不到托管标准）。叠加第三视角下自车被模型当成障碍框，误触发极其频繁。
- 现行策略：**只转向、只压油门，绝不自动刹车**——危险时靠"压低油门 + 转向避让"让车自然减速/绕开；真要停车/倒车由**用户自己踩**。throttle 仍保留分级（危险时不给油），这不是刹车，只是不加速。
- 文档勘误记录：本文件早前版本的分档表（brake = 1.0 / 0.6 / 0.1）对应的是 2026-10-02 **之前**的旧行为，现已过时；现行源码三档 `brake` **恒为 0**（:159/:165/:172）。

**`fuse(detections: [Detection], e2e: ControlCommand) -> ControlCommand`（第 182–199 行）**——E2E + 规则融合决策（.rule 态用）：

```swift
let ruleCmd = decide(detections: detections)
switch dangerLevel {
case .safe:      return e2e                       // 安全：完全信 E2E
case .caution:   return ControlCommand(steer: e2e.steer * 0.5 + ruleCmd.steer * 0.5,
                                       throttle: e2e.throttle, brake: e2e.brake,
                                       confidence: e2e.confidence * 0.9)
case .danger, .critical: return ruleCmd             // 危险/急刹：规则覆盖
}
```

- **安全时信 E2E、注意时转向对半融合（E2E 为主，规则只修正转向，油门刹车用 E2E 的）、危险/急刹时规则完全覆盖**
- **危险时 confidence 也用规则侧的 obs.confidence**（ruleCmd 自带）——此时降级状态机看到的是 YOLO 检测置信度
- ⚠️ 与上面 2026-10-02 变更联动：`.danger/.critical` 时 fuse 返回的 ruleCmd 现在 **brake 恒 0**——规则覆盖也不会按 S 倒车。

**调用链（2026-10-06 核实）**：`DriveState.tick()`（AuroraDriveApp.swift:6384）→ 降级状态机 `degradeStm.update()`（:6686-6694）选定档位 → `.rule` 档时 `ruleController.decide(detections:)`（:6879，`detections` 来自 `yoloEngine.detections` :6631）；车道保持/分段覆盖可再叠加在 rule/yolo 档输出上（:6917-6967）→ `applyCommand`（:7034→:7321-7350）→ ControlEngine 按键映射。

**RuleController 文档至此完整**（200 行全覆盖：Detection 类型 → decide/fuse 决策）。