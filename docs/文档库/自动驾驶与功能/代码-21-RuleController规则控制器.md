# 代码-21 RuleController 规则控制器

> 覆盖源文件：`Sources/AuroraDrive/Agent/RuleController.swift`（**187 行**）。基于当前仓库逐单元编写。**2026-09-25 深度复核**：9-24 性能优化改动 8 给 `struct Detection` 加了 `Equatable` 协议（源码 :29）+ 6 处「先比后写」消费点（DriveState tick 等处以 `detections != oldDetections` 判断避免无变化重绘），185→187 行即此；决策逻辑（危险区/urgency 三档/fuse）零变化。

## 一、Detection 类型：危险区与紧迫度（第 1–68 行）

**定位（4–19 行头注释）**：YOLO 检测 → 控制量 规则控制器——把感知模型（game_assist_yolo）的障碍物检测结果，用规则转换为 steer/throttle/brake 控制量。

**用途（两个态）**：

- `.yolo` 态（YOLO_RULE）：**纯规则**——YOLO 检测 → 规则控制
- `.rule` 态（E2E_ASSISTED）：**E2E 输出 + 规则修正**（避障覆盖）

**四个设计要点（源注释原文）**：① 检测框用归一化坐标 [0,1]，与图像分辨率解耦；② 只关心"正前方危险区"的障碍：水平中心带 + 垂直下方（近距）；③ 危险等级分三档：避让（转向绕开）/ 减速 / 急刹；④ .rule 态下与 E2E 输出融合：危险时规则覆盖，安全时信 E2E。

**`Detection`（struct，第 27–68 行）**——单个障碍物检测结果（YOLO 输出解析后的统一格式），**所有坐标归一化到 [0,1]，原点左上角，与图像分辨率解耦**：

| 字段 | 说明 |
|---|---|
| `x / y` | 边界框**中心** x/y [0,1]（**中心点 + 宽高格式**，与 YoloEngine.parse 的输出契约一致） |
| `width / height` | 宽/高 [0,1] |
| `label: Label` | 障碍物类别——enum：`car`（车辆）/ `pedestrian`（行人）/ `sign`（交通牌）/ `obstacle`（通用障碍） |
| `confidence` | 置信度 [0,1] |
| `rawName`（默认 "OBJ"） | **原始检测类名（COCO 类名，如 "CAR"/"PERSON"/"TRAFFIC LIGHT"）——仅用于 UI 画框时显示；规则决策只看 label**。有默认值 → 不影响既有的 Detection(x:y:width:height:label:confidence:) 调用 |

**`isInDangerZone(dangerHalfWidth: Double = 0.18, dangerYMin: Double = 0.45) -> Bool`（第 56–59 行）**——是否在"正前方危险区"：

```swift
abs(x - 0.5) < dangerHalfWidth && y > dangerYMin
```

危险区定义：**水平中心带（\|x-0.5\|<dangerHalfWidth）+ 垂直下方（y>dangerYMin，近距）**——y 大 = 画面下方 = 离车近（透视投影）。

**`urgency: Double`（计算属性，第 63–67 行）**——估算的"碰撞紧迫度" [0,1]：

```swift
let sizeScore = width * height                    // 框面积
let centerScore = 1.0 - abs(x - 0.5) * 2.0        // 居中度（中心=1，边缘=0）
return max(0, min(1, sizeScore * 8.0 * centerScore))
```

**框越大（越近）+ 越居中 → 紧迫度越高**；`× 8.0` 放大面积贡献（面积通常 0.0x~0.1 量级，×8 后进 0.2~0.8 可判档）；max/min 夹到 [0,1]。

## 二、decide() 三档决策与 fuse() 融合（第 70–187 行）

**类声明（第 76–77 行）**：`@Observable final class RuleController`——UI 可观察危险等级与最近障碍；**纯函数式：decide(detections, e2e?) → ControlCommand；无内部状态，线程安全**。

**五个可调阈值（第 79–94 行）：**

| 参数 | 默认值 | 说明 |
|---|---|---|
| `dangerHalfWidth` | 0.18 | 危险区水平半宽（中心带宽度 = 2 × 此值 = 0.36） |
| `dangerYMin` | 0.45 | 危险区垂直下限（y 大于此值视为近距） |
| `hardBrakeUrgency` | 0.55 | **急刹阈值**：紧迫度超过此值直接急刹 |
| `brakeUrgency` | 0.25 | **减速阈值**：紧迫度超过此值减速 |
| `steerStrength` | 1.0 | 避让转向强度系数 |

**状态输出（第 96–107 行）**：`dangerLevel: DangerLevel`（enum：`.safe = "安全" / .caution = "注意" / .danger = "危险" / .critical = "急刹"`——rawValue 中文 UI 直接展示，默认 .safe）+ `nearestDetection: Detection?`（当前最紧迫障碍）。

**`decide(detections: [Detection]) -> ControlCommand`（第 114–160 行）**——纯规则决策（.yolo 态用）：

1. **找最紧迫障碍（116–119 行）**：`dangers = detections.filter { isInDangerZone }` → `nearest = dangers.max(by: urgency)` → `nearestDetection = nearest`
2. **无障碍（121–127 行）**：直行加速——`ControlCommand(steer: 0, throttle: 0.8, brake: 0, confidence: 0.8)`——源注释：**confidence 固定 0.8：直行是规则确定行为、无检测框可依，语义为"高但非满"的规则确定度（不再用危险等级反推置信度）**
3. **有障碍（129–159 行）**：置信度 = `obs.confidence`（**YOLO 检测置信度，反映"这个检测框可不可信"，与危险等级解耦**——危险等级仍由 urgency 独立分档，只决定 steer/throttle/brake，confidence 不再用危险等级分档给固定魔法值（原 0.4/0.5/0.6））；`offset = obs.x - 0.5`（负=左，正=右）

**危险等级分档（138–159 行）：**

| urgency | 等级 | steer | throttle | brake |
|---|---|---|---|---|
| > 0.55 | `.critical` 急刹 | `offset > 0 ? -1.0 : 1.0`（**向障碍反方向打满**） | 0 | **1.0** |
| > 0.25 | `.danger` 危险 | `(offset > 0 ? -1.0 : 1.0) × steerStrength`（半转） | 0.2 | 0.6 |
| 其余 | `.caution` 注意 | `(offset > 0 ? -0.5 : 0.5) × steerStrength`（轻转） | 0.6 | 0.1 |

**`fuse(detections: [Detection], e2e: ControlCommand) -> ControlCommand`（第 167–184 行）**——E2E + 规则融合决策（.rule 态用）：

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

**调用链**：DriveState 每 tick → YoloEngine.detections → `decide`（.yolo 态）或 `fuse(detections, e2eCommand)`（.rule 态）→ ControlCommand → ControlEngine 按键映射。

**RuleController 文档至此完整**（187 行全覆盖：Detection 类型 → decide/fuse 决策）。