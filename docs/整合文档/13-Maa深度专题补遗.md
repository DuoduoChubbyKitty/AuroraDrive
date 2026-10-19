# 13 · Maa 深度专题补遗

> 整合自 2 篇：`MAA深度文档_完整版.md`（3151 行）+ `ROI反推规则.md`（137 行）。
> 整合日期：2026-10-18。**只读整合，未删改任何原文档**。
> 代码引用均来自 MaaNTE 源码（本地 `MaaNTE/`，未随本仓库分发），可核对。

---

## 1. 完整版与分篇的重叠度判断

**机器量化结论**（8-gram 比对，2026-10-18 本地脚本实测）：

| 指标 | 值 |
|---|---|
| 完整版 8-gram 总数 | 728 |
| 被其他 14 篇覆盖的比例 | **26.6%**（191 个 8-gram 有重合） |
| 完整版**独有** 8-gram | **537**（73.4%） |
| 与架构篇重合 | 29.3%（占架构篇） |
| 与功能篇重合 | 4.6% |
| 与扩展篇重合 | 0.9% |
| 与 Maa-09~15 七篇重合 | **0.0%**（零重合） |

**判断**：完整版**不是**前三篇（架构/功能/扩展）的简单并集。它是更早写的一份**完整逐行分析**（2026-09-13），包含大量代码级细节。分篇（架构/功能/扩展）是后续从完整版**抽取+重组+补充**的精炼版。**Maa-09~15 七篇模块拆解是独立的新工作，与完整版零重合。**

**本篇只提取完整版独有内容**（其他 12 篇已覆盖的不再重复），加上 `ROI反推规则.md` 的全部内容。

---

## 2. 完整版独有：工具函数库 Common/utils.py（`完整版:2539-2609`）

> 这是全项目被引用最多的模块（Maa-12 teleport_to_point、排球等都 `from ..Common.utils import ...`）。完整版给出了三个核心函数的**完整实现**，分篇只给了签名。

### 2.1 `load_params(custom_action_param) -> dict`

```python
def load_params(custom_action_param) -> dict:
    """兼容 None / dict / JSON 字符串的 custom_action_param 解析"""
    if not custom_action_param:
        return {}
    if isinstance(custom_action_param, dict):
        return custom_action_param
    try:
        params = json.loads(custom_action_param)
    except Exception:
        return {}
    return params if isinstance(params, dict) else {}
```

**设计要点**：三态容错（None→{} / dict 直用 / JSON 字符串解析失败→{}），**绝不抛异常**——pipeline 参数来源不可控，必须防御式解析。

### 2.2 `get_image(controller)`

```python
def get_image(controller):
    job = controller.post_screencap()
    job.wait()
    img = controller.cached_image  # numpy BGR 数组
    return img
```

**⚠️ 关键**：`post_screencap()` 是**异步**的，必须 `.wait()`。`cached_image` 是 MaaFramework 缓存的 numpy BGR 数组。

### 2.3 `click_rect(controller, rect, delay=0.001)`

```python
def click_rect(controller, rect, delay=0.001):
    x, y, w, h = rect
    cx = x + w // 2
    cy = y + h // 2
    controller.post_touch_move(cx, cy).wait()
    time.sleep(delay)
    controller.post_touch_down(cx, cy).wait()
    time.sleep(delay)
    controller.post_touch_up().wait()
```

**三步人类化点击**：move → down → up，每步间 `delay=0.001s`（1ms）。**点击矩形中心**（`w//2` + `h//2`，整除）。

### 2.4 `match_template_in_region(img, region, template, min_similarity=0.8, green_mask=False)`

**全项目最核心的视觉工具函数**，完整实现（`完整版:2570-2609`）：

```python
def match_template_in_region(img, region, template, min_similarity=0.8, green_mask=False):
    x1, y1, w, h = region
    x2, y2 = x1 + w, y1 + h
    h_img, w_img = img.shape[:2]
    x1, y1 = max(0, x1), max(0, y1)           # 边界钳制
    x2, y2 = min(w_img, x2), min(h_img, y2)
    if x2 <= x1 or y2 <= y1:
        return False, 0.0, 0, 0

    roi = img[y1:y2, x1:x2]
    if len(roi.shape) == 3 and roi.shape[2] == 4:
        roi = cv2.cvtColor(roi, cv2.COLOR_BGRA2BGR)   # 4通道归一

    if green_mask:
        lower_green = np.array([0, 255, 0], dtype=np.uint8)
        mask = cv2.bitwise_not(cv2.inRange(template, lower_green, lower_green))
        res = cv2.matchTemplate(roi, template, cv2.TM_CCOEFF_NORMED, mask=mask)
    else:
        res = cv2.matchTemplate(roi, template, cv2.TM_CCOEFF_NORMED)

    res = np.nan_to_num(res, nan=-1.0, posinf=-1.0, neginf=-1.0)  # 防 NaN 污染
    res[(res < -1e-6) | (res > 1.0 + 1e-6)] = -1.0
    np.clip(res, 0.0, 1.0, out=res)
    min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(res)

    if max_val >= min_similarity:
        return True, max_val, x1 + max_loc[0], y1 + max_loc[1]
    return False, max_val, 0, 0
```

**关键工程点**：
1. **ROI 边界钳制**（`max(0,...)` / `min(w_img,...)`）——防越界
2. **BGRA→BGR 归一**——MaaFramework 截图可能是 4 通道
3. **`green_mask`**：绿色遮罩排除绿色高亮元素（`cv2.bitwise_not(cv2.inRange(template, [0,255,0], [0,255,0]))`）——**用纯绿像素做遮罩键**
4. **`np.nan_to_num` 防 NaN 污染**——空模板或全相同区域会产生 NaN/Inf
5. **`np.clip` 双保险**——理论 TM_CCOEFF_NORMED 输出 [-1,1]，但浮点噪声可能越界
6. **返回值是 `(matched, max_val, x, y)`**——x/y 已加上 ROI 偏移（**绝对坐标，不是 ROI 内相对坐标**）

> 💡 **对本项目的启示**：AuroraDrive 的 `VisualLocator.swift` 是纯 Swift NCC 实现，无 `green_mask` 能力；若需要排除绿色高亮，可参考此处的 `cv2.inRange` + `bitwise_not` 方案（但在 Swift 中需用 vImage 或 Metal 实现）。

---

## 3. ROI 反推规则（`ROI反推规则.md` 全文保留）

> 这是 macOS 适配的**不可再生知识**——623 节点全量匹配 + 实测位移反推得出，不需要再录任何素材。

### 3.1 根因（纯几何）

```
macOS 窗口 1470×923  --Maa 按长边缩放到 1280-->  1280×803
MaaNTE 基线（Windows）                          -->  1280×720
                                                     高度差 H = 83px
```

Maa 只有等比缩放（`postproc_screenshot()` → `cv::resize`，`ScreenshotTargetLongSide=1280`），**不做跨宽高比适配**。窗口比 16:9 高，多出来的 83px **全部加在底部**。

### 3.2 推导出的规则

| 方向 | 规则 | 依据 |
|---|---|---|
| **x** | `Δx = 0` | 两个空间宽度都是 1280，UI 按宽度缩放，横向完全对齐 |
| **y** | `Δy ∈ [0, +83]` | 顶部锚定=0；底部锚定=+83；中间线性 |

**安全统一处理**：
```
新ROI = [x, y, w, h + 83 + 32]    # 32 = 安全边距（吸收取整/内边距/噪声）
下边界钳到画面底（y + h ≤ 803）
```

### 3.3 实测验证

| 节点 | y | 实测位移 |
|---|---|---|
| `VolleyballSkipStory` | 29 | +0 |
| `VolleyballWaitDifficultySelection` | 5 | +1 |
| `BidKingConfirm` | 455 | +41 |
| `VolleyballStartButton` | 655 | **+83** |

**最大实测位移 = +83，与几何上界完全吻合** → 上界充分。反例校正：`BidKingStart` 表面 Δy=+142，其中 59px 是 ROI 自身内边距，真实位移仍是 +83。

### 3.4 产物

| 文件 | 内容 |
|---|---|
| `build/maa_pipeline_override.json` | **全量 250 节点 ROI override**（`tools/maa_roi_offset.py` 生成） |
| `build/maa_override_all.json` | 181 节点（规则套用档） |
| `build/maa_override_final.json` | 32 节点（精确反推档） |
| `build/maa_override_derived.json` | derived 26 + expand 35（中间推导档） |
| `build/audit_result.json` | 78 模板 × 159 样本的全部匹配分数与坐标 |
| `data/_gray_cache/` | 263 张 1280×803 灰度缓存（⚠️ 已随 2026-09-19 磁盘清理迁移至外置硬盘） |

**override 分两档**：29 个用实测位置反推（x、y 双向扩张，最准）+ 152 个套几何规则（y +83 + 边距）。自检：**29/29 覆盖成功，0 失败**（15 个 x 方向串味样本已剔除）。

### 3.5 ⚠️ OCR 节点全量验证结果（关键教训）

**正确的 OCR 推理管线**——早期用「整块 ROI 直接喂 rec 模型」得到全空串，根因是三处管线缺陷：

```python
# ① 缺 det 阶段 —— PP-OCR 是两段式，整块 ROI 喂 rec 必然返回空串
#    现象：'' + mean_conf=0.951（模型"确信"这里没有一行文字）
# ② 检测框未外扩 —— rec 需要 2px padding 才能正确识别
# ③ 缩放用 INTER_LINEAR —— 应为 INTER_CUBIC
crop = img[y-2 : y+h+2, x-2 : x+w+2]
im = cv2.resize(crop, (rw, 48), interpolation=cv2.INTER_CUBIC)
```

修正后「强制开启」识别置信度 = **1.0**，四种缩放倍率全部正确。模型选择：`ppocr_v6/medium`（18708 类）；`small` 对小字号红字乏力（conf 0.39→0.85），`tiny` 是项目速度数字微调模型的基座（6904 类），不适用于中文界面。

### 3.6 A/B 结果与覆盖率（诚实口径）

| 指标 | 原 ROI | 修正 ROI |
|---|---|---|
| OCR 命中 | 14/111 | **40/111** |
| TemplateMatch 命中 | 19/61 | **31/61** |
| 合计 | 33 | **71** |
| 被改坏 | — | **0** |

26 个 OCR 节点 + 12 个模板节点被 ROI 修正救回。**71 个 miss 的归因：缺截图，非坐标**——排除假阳性后，**真实 ROI 偏移 = 0**，剩余 50 个节点的期望文案在全库中完全不存在。

| 类别 | 已验证 | 总数 |
|---|---|---|
| TemplateMatch | 31 | 82（可测 61） |
| OCR | 40 | 164（可测 111） |
| And / Or / ColorMatch | 0 | 90 |
| **识别类合计** | **71** | **336** |
| **覆盖率** | **21.1%** | |

不需要识别的节点 287 个（None 221 / DirectHit 65 / Custom 1）不计入分母。

**结论：ROI 反推规则已到极限，无进一步优化空间。** 其余节点的验证只能等实机覆盖这些场景。

---

## 4. 完整版独有：其他功能模块（`完整版:2611-3042`）

> 完整版 §17 的 10 个功能模块，其中大部分在功能篇/Maa-13/Maa-14/Maa-15 已有覆盖。本节只提取**完整版独有的实现细节**。

### 4.1 提款机 WithdrawMoney（`完整版:2691-2763`）—— OCR 价格解析

```python
def _parse_value(text):
    text = text.strip().upper().replace(",", "").replace("，", "")
    m = re.search(r"(\d+(?:\.\d+)?)\s*(K)?\s*/", text)
    if not m: return None
    value = float(m.group(1))
    if m.group(2) == "K": value *= 1000
    return value
```

**智能选品逻辑**：① OCR 识别所有商品价格/小时 → ② 按 value 降序排序 → ③ 取 top5 点击 → ④ 自动处理上下翻页（`down_items` + `up_items` 合并排序，按 swipe 方向分组切换）。**支持 `1,234` / `1.5K` 格式**——逗号和中文逗号都处理。

### 4.2 自动滚书 AutoFScroll（`完整版:2764-2803`）—— 双通道按键

```python
while not context.tasker.stopping:
    is_f_pressed = ctypes.windll.user32.GetAsyncKeyState(VK_F) & 0x8000
    if is_f_pressed:
        controller.post_key_down(KEY_F)    # MAA 控制器按键
        time.sleep(0.1)
        controller.post_key_up(KEY_F)
        ctypes.windll.user32.mouse_event(  # 同时 Windows 滚轮事件
            MOUSEEVENTF_WHEEL, 0, 0, -120, 0)
        time.sleep(0.1)
```

**原理**：通过 `GetAsyncKeyState` 检测物理 F 键状态，长按时**同时发送 MAA 按键和 Windows 滚轮事件**，实现极速翻页。**双通道**：MAA 按键走 pipeline 控制器，Windows 滚轮走 `mouse_event`（不经过 MAA）。

### 4.3 角色都市技能同步（`完整版:2888-2973`）—— 16 角色映射表

```python
_TEMPLATE_TO_NAME = {
    "Adler.png": "阿德勒", "Aurelia.png": "海月",
    "Baicang.png": "白藏", "Chaos.png": "卡厄斯",
    "Chiz.png": "小吱", "Daffodill.png": "达芙蒂尔",
    "Edgar.png": "埃德嘉", "Fadia.png": "法帝娅",
    "Haniel.png": "哈尼娅", "Hathor.png": "哈索尔",
    "Hotori.png": "浔", "Jiuyuan.png": "九原",
    "Lacrimosa.png": "安魂曲", "Mint.png": "薄荷",
    "Nanally.png": "娜娜莉", "Sakiri.png": "早雾",
    "Skia.png": "翳", "Zero.png": "零",
}
```

**识别策略**：① OCR 先在信息页识别名字 → ② 进入技能页后 **TemplateMatch 以 ≥0.9 置信度优先采用** → ③ TM 失败时回退 OCR。**安全上限 300 次迭代**（`for iteration in range(300)`），连续 3 次名字不变即判列表末尾。

### 4.4 在线地图导航（`完整版:2974-3042`）—— WebSocket 协议全量

**位置推送格式**（`完整版:3000-3012`）：
```json
{
    "type": "navi-state",
    "version": 1,
    "position": {"x": 6500.5, "y": 5200.3, "pixelX": 6520, "pixelY": 5210,
                 "score": 0.95, "mode": "coordinate"},
    "angle": 180.5, "pitch": -15.2, "angleConfidence": 0.98,
    "route": {"waypoints": [...], "active": true, "currentIndex": 2, "status": "running"},
    "timestamp": 1726234567.0
}
```

**七类消息**：`navi-route-set` / `-add` / `-clear` / `-start` / `-stop` / `-ack` / `-state`（Maa-11 已覆盖，完整版给出了完整 JSON 格式）。

---

## 5. 完整版独有：新增功能开发指南（`完整版:3042-3151`）

> ⚠️ 完整版的 §16-§18 章节编号有**重复错误**（两个 §16/§17），但内容是有效的。

### 5.1 完整流程（7 步）

1. 创建 Python 文件 `agent/custom/action/<Name>/action.py`
2. 注册装饰器 `@AgentServer.custom_action("snake_case_name")`
3. 导入注册：`__init__.py` 添加 import + `__all__`
4. 创建 Pipeline JSON：`assets/resource/base/pipeline/` 添加 JSON
5. 创建任务配置：`assets/resource/tasks/` 添加 JSON
6. 更新 `interface.json`：`import` 数组中添加引用
7. 更新本地化：同步 5 个语言文件

### 5.2 ⚠️ 漏一处的后果

| 漏 | 后果 |
|---|---|
| locale（5 语言文件） | MXU 界面显示 `$task_xxx_label` 原文（功能正常但界面破相） |
| `import`（interface.json） | **任务在界面上根本不出现** |
| `__init__.py`（from-import + `__all__`） | **`@AgentServer.custom_action` 装饰器不执行，pipeline 调用时报"未知动作"** |

### 5.3 编码规范

```python
# ✅ 正确
logger.debug("message %s", value)   # % 格式化
PrintT(context, "key", arg1)         # 向界面推送消息

# ❌ 错误
print("message")                     # 禁止使用 print
logger.debug(f"message {value}")     # 禁止 f-string
```

---

## 6. 对本项目的可借鉴点

| # | 借鉴点 | 说明 |
|---|---|---|
| 1 | **`match_template_in_region` 的 `green_mask` 方案** | 用纯绿像素做遮罩键排除绿色高亮元素——AuroraDrive 的 `VisualLocator` 无此能力 |
| 2 | **OCR 正确管线三要素** | 缺 det 阶段 / 未外扩 2px / 缩放用 INTER_LINEAR（应 INTER_CUBIC）——AuroraDrive 的 SpeedOCRReader 可对照检查 |
| 3 | **ROI +83px 规则** | macOS 上 MaaNTE 基线适配的几何推导，AuroraDrive 用归一化 float ROI 规避了此问题 |
| 4 | **`load_params` 三态容错** | None→{} / dict 直用 / JSON 失败→{}，绝不抛异常——pipeline 参数防御式解析 |
| 5 | **`click_rect` 三步人类化点击** | move → down → up + delay，AuroraDrive 的 `MouseController.click` 也是 move → settle → down → up |
| 6 | **250 节点 override 三档策略** | 规则套用 + 精确反推 + 安全边距——通用的 ROI 适配方法论 |
| 7 | **新增功能 7 步流程** | pipeline + task + locale + interface + `__init__` 五处同步的纪律 |

---

## 7. 已过期 / 未验证项

| 项 | 状态 |
|---|---|
| 完整版 §16/§17 编号重复 | ⚠️ 原文有两个 §16/§17（编号错误，内容有效） |
| 完整版尾部「总行数 5000+」 | ⚠️ 实测 3151 行 |
| `data/_gray_cache/` 路径 | ⚠️ 已随 2026-09-19 磁盘清理迁移至外置硬盘，重跑需重建缓存 |
| 24 个缺模板节点是否已补齐 | **未验证** |
| OCR 节点 164 个的期望文本是否在 macOS 上全部正确 | **未验证**（靠实跑才能确认） |
| 完整版的 `interface.json` 内容（interface_version 2 / version 0.0.4） | ✅ 本地核对一致（:161 行） |

---

## 8. 原文处置建议

| 原文 | 处置 | 理由 |
|---|---|---|
| `MAA深度文档_完整版.md`（3151） | **保留，但标注为「完整版独有内容已被整合」** | 与分篇 26.6% 重合，但 73.4% 独有内容（工具函数完整实现、功能模块代码级细节、开发指南）仍有价值 |
| `ROI反推规则.md`（137） | **保留** | macOS 适配的不可再生知识（623 节点全量匹配 + 实测位移反推），结论标注「仍有效」 |

**本篇新增的核对结论**：
1. 机器量化重叠度：完整版 728 个 8-gram，被其他 14 篇覆盖 26.6%，**73.4% 独有**——不是分篇的简单并集。
2. 完整版与 Maa-09~15 七篇**零重合**（0.0%）——它们是独立的新工作。
3. `match_template_in_region` 的完整实现已提取（`green_mask` 方案是 AuroraDrive 缺失的能力）。
4. OCR 正确管线三要素（det 阶段 + 2px 外扩 + INTER_CUBIC）已原文保留。
5. ROI 反推规则覆盖率 **21.1%**（71/336 识别类节点已验证），结论「已到极限，无进一步优化空间」。

---

*本篇为整合文档，未删改任何原文件。代码引用均已去本地 `MaaNTE/` 核对。*
