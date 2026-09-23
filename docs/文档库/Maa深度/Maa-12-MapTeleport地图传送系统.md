# Maa-12 MapTeleport 地图传送系统

> 覆盖源文件：`MaaNTE/agent/custom/action/MapTeleport/`（teleport_to_point.py 968 行 + check_teleport_required.py 425 行 + __init__.py 12 行）+ `assets/resource/base/map_teleport/`（teleport_points.json 10 点 + check_points.json 1 锚点）。基于当前仓库逐单元编写。

## 一、模块职责与两个注册动作

| 动作名（pipeline 调用） | 类 | 文件 |
|---|---|---|
| **`check_teleport_required`** | CheckTeleportRequiredAction | check_teleport_required.py 343–425 行 |
| **`map_teleport_to_point`** | MapTeleportToPointAction | teleport_to_point.py 924–968 行 |

**协作关系（源码链接链）**：`check_teleport_required` 判定"离目标太远" → **直接 `from .teleport_to_point import run_map_teleport_flow`（414 行）** 走完整传送流程；两个动作共享 `check_teleport_required` 的四件套工具（`find_named_record` / `load_json_resource` / `point_xy` / `resource_base_path`，teleport_to_point.py 28–34 行导入）。

**双入口的设计意图**：pipeline 侧可以**只用判定**（自己决定后续走本地导航还是传送），也可以**直接调传送**（跳过距离判定）。

## 二、check_teleport_required.py（425 行）——距离判定与后端降级

**参数默认值（26–32 行）**：

| 常量 | 值 | 语义 |
|---|---|---|
| `DEFAULT_NEAR_DISTANCE` | 200.0 | **近距阈值（世界单位）** |
| `DEFAULT_POSITION_BACKEND` | `"auto"` | 默认自动（先抓包后视觉） |
| `DEFAULT_COORDINATE_TYPE` | `"world"` | 默认用世界坐标比距离 |
| `DEFAULT_COORDINATE_TIMEOUT` | 1.5 | 抓包等待上限（秒） |
| `DEFAULT_COORDINATE_INTERVAL` | 0.1 | 轮询间隔 |
| `NEAR_MESSAGE` / `FAR_MESSAGE` | **"距离过近，直接使用自动导航。" / "距离较远，使用地图传送"** | 用户可见文案 |

**⚠️ 导入兜底（16–23 行）**——**本文件最关键的工程点**：

```python
try:
    from maa.agent.agent_server import AgentServer
    from maa.context import Context
    from maa.custom_action import CustomAction
except ImportError:
    AgentServer = None
    Context = Any
    CustomAction = None
```

**maa 包缺失时不崩，只在文件尾 `if AgentServer is not None and CustomAction is not None:`（343 行）包住注册块**——**整个模块的核心算法（判定/解析/定位）可脱离 MaaFramework 单测/复用**（与 `local_route_navigation_unit_test` 同一设计哲学）。

**两个冻结 dataclass**：

- **`TargetPoint`（35–40 行）**：id / name / point / **threshold（该点自己的阈值）**
- **`TeleportDecision`（43–54 行）**：current / target / distance / need_teleport / mode / coordinate_type + **`message` 属性（52–54 行：`FAR_MESSAGE if need_teleport else NEAR_MESSAGE`——文案与决策绑定，调用方不再拼串）**

**`resource_base_path()`（57–67 行）——向上遍历找资源根**：

```python
for parent in Path(__file__).resolve().parents:
    if (parent/"assets"/"resource"/"base").exists(): return ...   # 生产布局
    if (parent/"resource"/"base").exists(): return ...            # dev 布局
raise FileNotFoundError("Unable to locate resource/base directory")
```

**包导入双模式（70–121 行）——本文件最复杂的一段**：

- **`load_map_locator_class()` / `load_coordinate_position_provider_class()`**
- **正常模式（有 `__package__`）**：`importlib.import_module("..Navi.map_locator", __package__)`——**相对导入**
- **降级模式（无包上下文 / 被 exec 或直接当脚本跑）**：
  1. **把 `agent/` 目录插进 sys.path**
  2. **`root_name = "_map_teleport_check_action"` 动态造 3 个 ModuleType（根 + `.Navi` + `.Common`），手工设 `__path__` / `__package__`，`sys.modules.setdefault` 注册**
  3. 再 `importlib.import_module(f"{root_name}.Navi.map_locator")`
- **⚠️ 意义：不依赖任何 `__init__.py` 就能把 Navi 子模块当包内模块导入**——**单文件可测性的极致实现**（`setdefault` 保证重复调用不冲突）

**参数解析四件套**：

| 函数 | 语义 |
|---|---|
| `parse_params`（123–128 行） | None/空 → `{}`；dict 直用；**字符串则 json.loads** |
| `point_xy`（137–149 行） | **五级键优先：`worldX/worldY` → `rawX/rawY` → `pixelX/pixelY` → `x/y` → 嵌套 `coordinate.{x,y}`**；全不中抛 ValueError |
| `find_named_record`（152–167 行） | 按容器名取 list（**dict 则直接取该键，list 则当整体**）→ **按 `id` 或 `name` 匹配（空白容忍）** → 找不到抛带 id 的 ValueError |
| `load_target_point`（170–186 行） | 有 `point_id` → 读表（**默认 `map_teleport/check_points.json`，可用 `points_file` 覆盖**）→ 取 `threshold`（**缺失回退 200**）→ 组 TargetPoint |

**`parse_target_point`（189–199 行）——表优先 + 三形态兜底**：**先试表查询 → `target`/`target_point` 列表（≥2 元素）→ `{x,y}` dict → `target_x`/`target_y` 必须存在**。

**定位两函数**：

- **`visual_locate`（215–237 行）**：无 frame 则 `get_frame()` 取；**`MapLocator(debug) + CoordinatePositionProvider("map", debug)` → `provider.locate(locator, frame)`**；**`finally` 里 provider.close() 内嵌 locator.close()（双资源必释放）**；**228 行把 MapLocator 模块的 logger 压到 WARNING（视觉匹配刷屏抑制）**
- **`locate_current_position`（240–272 行）——后端编排**：

```
backend 归一化 → CoordinatePositionProvider(backend)
├─ uses_visual_positioning()（无抓包器）→ 直接 visual_locate
└─ 有抓包：deadline = now + timeout
      while: provider.locate(None, None) → found 即返回
             超时 break
      超时且 backend=="auto" → visual_locate 兜底
      超时且 backend=="coordinate" → None
finally: provider.close()
```

**⚠️ 注意 `time.sleep(max(interval, 0.05))`（266 行）——间隔下限 50ms 强制**。

**`check_teleport_required`（275–318 行）——主判定**：

- **参数顺序魔法（287–291 行）**：`target=None` 时把第一参数当 target；否则第一参数当 frame——**同一函数支持 `(target)` 与 `(frame, target)` 两种调用**
- 定位失败/未找到/point 为 None → **返回 None（三态：None 未知 / True 传送 / False 不传送）**
- `current = location_point(result, coordinate_type)` → None 则 None
- **`distance = math.hypot(dx, dy)`（310 行）→ `need_teleport = distance >= threshold`（315 行，闭区间）**

**坐标系归一（321–340 行）**：

| 函数 | 语义 |
|---|---|
| `normalize_coordinate_type`（321–327 行） | `world`/`raw`/`coordinate` → **"world"**；`map`/`pixel`/`image` → **"map"**；其他抛 ValueError |
| `location_point`（330–340 行） | **map 模式用 `result.point`；world 模式用 `result.raw_coordinate`（抓包原始坐标，视觉路径由 coordinate_position 反算填充）** |

**`CheckTeleportRequiredAction.run`（347–425 行）——完整流程**：

1. **参数解析（350–378 行）**：11 个参数（target/threshold/position_backend/coordinate_type/coordinate_timeout/coordinate_interval/teleport_point_id/teleport_points_file/debug）——**解析失败 print + `RunResult(success=False)`**
2. **`get_frame` 闭包（380–381 行）**：`context.tasker.controller.post_screencap().wait().get()`——**惰性取帧（需要视觉时才截屏）**
3. **判定（383–396 行）**：异常 → print + success=False
4. **`decision is None` → print("not_found") + success=False（398–400 行）**
5. **消息上报（402–407 行）**：`from utils.maafocus import Print` → `Print(context, decision.message)`；**import 失败则退化为 print（双通道）**
6. **分支（409–425 行）**：
   - 需传送但**缺 teleport_point_id → print 错误 + success=False**（**明确要求调用方给点 id**）
   - 需传送 → **`run_map_teleport_flow(context, id, points_file=...)` → 以其返回值作为 success**
   - 不需传送 → **`RunResult(success=True)`（近距即成功，交给后续自动导航）**

## 三、teleport_to_point.py（968 行）——传送流程全解

### 3.1 常量与模板（38–67 行）

**4 个模板图（基于 `resource/base/` 相对路径）**：

| 常量 | 路径 | 用途 |
|---|---|---|
| `MAP_INDEX_ICON_TEMPLATE` | `image/map_teleport/map_index_icon.png` | 地图索引按钮 |
| `AREA_NEXT_BTN_TEMPLATE` | `image/map_teleport/area_next_btn.png` | 地区切换（下一地区） |
| `SUB_SELECTION_BTN_TEMPLATE` | `image/map_teleport/sub_seletion_btn.png` | **子选项按钮（源文件名拼写为 seletion，沿用上游）** |
| `ZOOM_CONTROL_BTN_TEMPLATE` | `image/map_teleport/Zoom_control_button.png` | 缩放滑杆 |

**9 个 ROI + 1 个确认点（44–53 行）——注释明示"所有 ROI 都基于 1280x720"**：

| 常量 | 坐标 | 语义 |
|---|---|---|
| `MAP_INDEX_ICON_ROI` | [1069, 626, 89, 74] | 右下方索引图标 |
| `MAP_INDEX_TITLE_ROI` | [907, 66, 121, 36] | "地图索引"标题（OCR 验证） |
| `AREA_NAME_ROI` | [958, 127, 235, 40] | 地区名（OCR 匹配） |
| `AREA_NEXT_BTN_ROI` | [1203, 126, 44, 42] | 右上角切换按钮 |
| `MAIN_SELECTION_ROI` | [901, 176, 358, 460] | 主选项列表 |
| `SUB_SELECTION_ROI` | [1190, 180, 55, 461] | **子选项列表（窄长条，55px 宽）** |
| `TELEPORT_CONFIRM_POINT` | **[639, 361]** | **屏幕中心附近（1280/2≈640, 720/2=360）——打开确认框的点击点** |
| `TELEPORT_BUTTON_ROI` | [933, 620, 332, 45] | 底部传送按钮 |
| `ZOOM_CONTROL_BTN_ROI` | [47, 258, 34, 242] | **左侧竖向缩放滑杆** |

**按键与阈值**：`KEY_ESC = 27` / **`KEY_M = 77`（打开地图）**；模板阈值 0.8 / **OCR 阈值 0.5**（**比 AGENTS.md 建议的 0.3 严格**）/ 最大地区切换 15 次 / 动作间隔 0.5s / 开图等待 1.0s / 最终确认等待 1.0s。

**静止检测默认值（64–67 行）**：max_wait 8.0 / interval 0.25 / **consecutive 2（连续 2 帧稳定即判定静止）** / **diff_threshold 1.5（灰度均值差）**。

**`TeleportPoint` dataclass（70–80 行）**：id / name / point / coordinate_type / **area_name** / **icon_index** / **selection_name** / **icon_path** / description——**9 字段完整描述一次传送所需的全部 UI 线索**。

### 3.2 工具层（83–330 行）

| 函数 | 关键实现 |
|---|---|
| `load_teleport_point`（91–108 行） | 读表 → `find_named_record(data, "teleport_points", id)` → **`areaName` / `iconIndex` 为必填（直接下标，缺失抛 KeyError）**；其余可缺省 |
| **`_notify`（111–121 行）** | context 为 None → print；否则 `Print(context, msg)`；**Print 失败退 logger.info——三级消息通道** |
| **`_is_stopping`（124–128 行）** | `getattr(getattr(context,"tasker",None),"stopping",False)`——**双层 getattr 防属性缺失** |
| `_template_path` / `_load_template`（131–139 行） | `cv2.imread(..., IMREAD_COLOR)`；**None → FileNotFoundError 带相对路径** |
| **`_normalize_frame`（142–145 行）** | **4 通道（BGRA）→ `cv2.COLOR_BGRA2BGR`**——**MaaFramework 截图可能是 4 通道，必须先归一（否则模板匹配报错）** |
| `_screencap`（148–151 行） | `post_screencap().wait()` → `cached_image` → **归一化** |
| **`_click_point`（154–158 行）** | **move → down → sleep(0.05) → up（四步人类化点击）** |
| `_press_key_action`（166–191 行） | **⚠️ 源注释（167 行）："通过 Pipeline 的 ClickKey 发键，避免 CustomAction 内直接调用 controller 按键时的原生层异常。"** → 临时节点 `__MapTeleportPressKey` + override（**action.type=ClickKey + key 数组 + pre/post_delay=0 + rate_limit=0**） |
| `_click_rect_action`（194–217 行） | 同样走 Pipeline Click（**注释："关键确认点击同样交给 Pipeline Click，兼容 SeizeInput 等不同控制器实现"**）——**节点名 `__MapTeleportClick`** |
| **`_swipe_up_in_roi`（220–237 行）** | **从 ROI 底部中央 → 顶部中央滑动（duration 可调）——列表上滑** |
| `_box_to_rect` / `_detail_box`（240–272 行） | **识别结果对象 → [x,y,w,h] 的五级兼容取框**：`detail.box` → `best_result.box` → `filtered_results[*].box` → `all_results[*].box` |

**`_wait_screen_still`（275–319 行）——动效期间的稳定性守卫**：

1. `deadline = now + max(max_wait, interval)`
2. 初帧 `previous`
3. 循环：**`_is_stopping` 立即返回 None** → sleep → 取新帧
4. **降采样到 160×90（INTER_AREA）→ 灰度 → `cv2.absdiff` → `np.mean` = diff**
5. **`diff <= 1.5` 连续 2 次 → 返回当前帧**；否则计数清零
6. 超时返回 `last_frame`（**最后一帧兜底，不返回 None**——除非首帧取不到或中途停止）

**⚠️ 注释（288 行）**："连续多帧变化很小时认为画面已稳定，**避免动画期间误识别或误点**。"

**`_find_template_matches`（331–379 行）——多目标模板匹配（传送图标列表的核心）**：

- ROI 边界**先与帧尺寸求交（clamp）**，退化区域返回 []
- 区域小于模板 → []
- **`cv2.matchTemplate(..., TM_CCOEFF_NORMED)` + `np.nan_to_num(nan/posinf/neginf → -1.0)`（防 NaN 污染）**
- **循环取 `minMaxLoc` 最高分 → 记录 → 把该点周围 `template_w × template_h` 区域置 -1.0（非极大值抑制）** → 直到 `max_results=20` 或低于阈值
- **最后按 `(y, x)` 排序（从上到下、从左到右）**——注释（359 行）："传送点图标会有多个，逐个取最高分并抑制同一图标周围的重复响应"

**`_ocr_match`（382–402 行）**：**`context.run_recognition_direct(JRecognitionType.OCR, JOCR(expected=[text], roi=tuple(roi), threshold=...), frame)`**——**直接用 MaaFramework 的 JOCR 对象（不写 pipeline 节点）**；`detail.hit` 为真才返回。

**`_ensure_in_world`（405–411 行）**：`context.run_task("SceneAnyEnterWorld")` → `_wait_screen_still(max_wait=5.0)` → **`context.run_recognition("InWorld", frame)` 判 `result.hit`**——**先回大世界再操作地图（前置条件守卫）**。

**`_click_map_index`（414–430 行）**：静止 → 在 MAP_INDEX_ICON_ROI 匹配 → 命中则**用匹配框（x, y, 模板宽, 模板高）点击**。

**`_wait_ocr_text`（433–450 行）**：deadline 内循环——**先静止（max_wait=2.0）再 OCR，未中 sleep(0.2)**——**双等待嵌套（等静止 + 等文字出现）**。

**`_switch_to_area`（453–494 行）——地区翻页**：循环 `max_switches`（15）次——**先 OCR 验地区名（命中即 True）→ 否则匹配"下一地区"按钮 → 未命中就 False（按钮都没了还找不到，说明异常）** → 点击 + `time.sleep(action_delay)`；**注释（467 行）："地区名没命中时点击右上角切换按钮，最多翻 15 次避免卡死"**。

### 3.3 图标定位与点击（497–785 行）

**`_get_cursor_pos`（497–504 行）——本文件唯一的 Win32 直接调用**：

```python
pt = ctypes.wintypes.POINT()
ctypes.windll.user32.GetCursorPos(byref(pt))          # 屏幕坐标
hwnd = ctypes.windll.user32.WindowFromPoint(pt)       # 光标下窗口
if hwnd: ctypes.windll.user32.ScreenToClient(hwnd, byref(pt))   # → 客户区坐标
return (pt.x, pt.y)
```

**`_identify_new_list_nodes`（507–533 行）——"鼠标分界线以下的新选项"**：

- **docstring**："识别推荐地点列表中鼠标分界线以下第一个新出现的选项。通过系统 API 获取鼠标 Y 坐标，在子选项列表中匹配目标图标模板，**取 Y 严格大于鼠标 Y 的第一个匹配点**。"
- **设计意图：鼠标当前位置就是"已看过的分界"，往下第一个匹配即未浏览的新传送点（避免重复点同一个）**

**其余函数职责**（签名实测）：

| 函数 | 职责 |
|---|---|
| `_find_closest_icon_center`（534 行） | 找离参考点最近的图标中心 |
| `_drag_list_upward`（559 行） | **向上拖动列表**（配合 `_swipe_up_in_roi` 的语义封装） |
| `_check_closest_icon`（586 行） | 校验最近图标是否为目标 |
| **`_drag_zoom_control`（610–644 行）** | 拖动左侧竖向缩放滑杆（ZOOM_CONTROL_BTN_ROI） |
| `_click_main_selection`（645–670 行） | **OCR 定位主选项（MAIN_SELECTION_ROI）并点击** |
| **`_click_teleport_icon`（671–735 行）** | **在子选项列表找第 icon_index 个目标图标并点击（三参数：模板 / icon_path / icon_index）** |
| `_click_teleport_button`（736–785 行) | 底部传送按钮定位点击 |
| `_wait_teleport_loading`（786–792 行） | **`context.run_task("SceneLoadingType1")` 等加载节点跑完** |

### 3.4 主流程 `run_map_teleport_flow`（795–921 行）——十一步

| 步 | 动作 | 失败文案（`_notify`） |
|---|---|---|
| 0 | `load_teleport_point` + **info 日志（id/name/area/icon_index/point 五项）** + 通知"准备使用地图传送：X（地区，第 N 个）" | — |
| — | **`context is None` → log error 直接 False**（824–826 行） | — |
| 1 | 预载 3 个模板（map_index / area_next / sub_selection） | — |
| 2 | **`_ensure_in_world`** | "当前未确认处于大世界界面" |
| 3 | **`_press_key_action(context, KEY_M)` + sleep(1.0)** | "打开地图按键失败" |
| 4 | **`_drag_zoom_control`** | "缩放调节失败" |
| 5 | **`_click_map_index`** | "未找到地图索引按钮" |
| 6 | **`_wait_ocr_text("地图索引", MAP_INDEX_TITLE_ROI)`** | "未进入地图索引" |
| 7 | **`_switch_to_area(area_name, ...)`** | "未找到地区 %s" |
| 8 | **`_click_main_selection(selection_name)` + sleep(action_delay)** | "未找到主选项" |
| 9 | **`_click_teleport_icon(sub_selection, icon_path, icon_index)`** | "未找到第 %s 个传送图标" |
| 10 | **静止(5s) → `_press_key_action(KEY_ESC)` → sleep(1.0) → `_click_rect_action(中心点 2×2 矩形)`** | "退出地图按键失败" / "确认传送点击失败" |
| 11 | **`_click_teleport_button` → sleep → `_wait_teleport_loading`** | "未找到传送按钮" / "等待传送加载结束失败" |

**成功** → `_notify(context, "地图传送流程已完成：%s" % name)` + **return True**。

**⚠️ 关键工程点（897 行注释逐字）**："选中传送点后先退出地图指引，再点屏幕中央附近打开最终传送确认框。"——**ESC 退出指引 → 点中心（TELEPORT_CONFIRM_POINT ±1px 的 2×2 矩形）→ 底部传送按钮**——**三步顺序不可换**。

**⚠️ `_click_rect_action` 用 2×2 矩形而非 `_click_point`（903–906 行）**：**走 Pipeline Click 兼容 SeizeInput 控制器**（前台控制器会独占输入，只有走 Pipeline 才生效）。

### 3.5 数据资产（本机实测）

**`teleport_points.json`（10 条，字段 10 个）**：

```json
{
  "id": "fountain", "name": "喷泉传送点", "coordinateType": "world",
  "worldX": -152904.578, "worldY": 129793.907,
  "areaName": "绘空", "iconIndex": 2, "selectionName": "推荐地点",
  "iconPath": "image/map_teleport/teleport_icon/phone_booth.png",
  "description": "地图索引中使用的传送点"
}
```

**`check_points.json`（1 条锚点）**：

```json
{
  "id": "fountain", "name": "喷泉", "coordinateType": "world",
  "worldX": -151702, "worldY": 151178, "threshold": 7000,
  "description": "用于判断当前位置距离喷泉目标点是否过远；threshold 为小于该距离时直接使用本地路线。"
}
```

**⚠️ 三点重要事实**：

1. **两表同为 "fountain" 但坐标不同**（`-152904.578/129793.907` vs `-151702/151178`）——**传送点表是"传送落点"，检查点表是"导航目标"（喷泉本体），两者本就不同点**
2. **检查点 threshold = 7000（不是默认 200）**——**说明"近距离"阈值按点配置，7000 世界单位 ≈ 114 像素（7000×0.0164）**
3. **传送点表 version 字段 + teleport_points 数组**；检查点表 points 数组——**统一走 `find_named_record` 的容器名参数**

## 四、上下游衔接

| 方向 | 接口 |
|---|---|
| **上游** | pipeline 节点 `custom_action: "check_teleport_required"` / `"map_teleport_to_point"`，`custom_action_param` 传 JSON |
| **上游依赖** | **Navi 包（map_locator / coordinate_position）**——通过 70–121 行的双模式动态导入；**不发 __init__ 依赖** |
| **下游** | **本地导航（LocalRouteNavigation）**——`check_teleport_required` 返回 success=True 且不传送时由 pipeline 接续；**`_wait_teleport_loading` 走通用加载节点 `SceneLoadingType1`** |
| **横切** | `SceneAnyEnterWorld`（回大世界）/ `InWorld`（识别大世界）/ `__MapTeleportPressKey` 与 `__MapTeleportClick`（**运行时临时节点，`__` 前缀符合私有节点约定**） |

**⚠️ 与 AGENTS.md 的约定对照**：本模块**大面积使用 `time.sleep` 硬延迟**（action_delay 0.5 / 开图 1.0 / 确认 1.0 / 静止 0.25）——**与 AGENTS.md "避免硬延迟，优先中间识别节点" 的通用约定不同**：原因在于地图 UI 是**强动画、无稳定识别锚点**的场景，静止检测（`_wait_screen_still`）+ 固定延迟是这里唯一可靠的手段——**这是有意识的例外，不是遗漏**。

---

**Maa-12 文档至此完整**（MapTeleport 两文件 1393 行 + 10 传送点 + 1 锚点数据全解；含包双模式导入、_wait_screen_still 静止守待、非极大值抑制多目标匹配、Pipeline 代发键鼠三大关键工程点）
