# road_corners*.json 五份打点集说明（2026-11-25 登记）

本目录下同一族「弯道/路口打点集」共五份，按演进顺序：

| 文件 | 大小 | 生成脚本（`models/tools/`，均在 git 内，可复现） | 说明 |
|---|---|---|---|
| `road_corners.json` | 56KB | **确切产出脚本版本已不可考**（与 t70 同一提交 600874b 进仓，但该提交里 `make_road_corners.py` 的输出名已是 t70） | v1 射线峰值法的早期产物 |
| `road_corners_t70.json` | 72KB | `make_road_corners.py`（输入 `road_prior_2048_t70.png`） | v1 + t70 阈值干净先验 |
| `road_corners_v2.json` | 1.1MB | `make_road_corners_v2.py` | v2：密集 · 双向 · 覆盖整个弯道 |
| `road_corners_v3.json` | 1.8MB | `make_road_corners_v3.py` | v3：补支路长度/宽度 |
| `road_corners_v3b.json` | 1.6MB | `make_road_corners_v3b.py` | **v3b：现役**。修 v3 的三个问题（reach 44% 饱和 156m 等，见脚本头） |

## 现役判定依据

`Sources/AuroraDrive/Inference/RoadCornerGuide.swift` 的 `locateResource()` 里
`let name = "road_corners_v3b"` 是唯一加载点——**现役是 `road_corners_v3b.json`**。
其余四份只是演进留痕，运行时不加载。

## 注意事项

1. **不要随手覆盖任何一份**：每份都是对应算法版本的一次性产物，覆盖即丢演进历史。
   要出新版请新起文件名（v4…）并同步改 `locateResource()` 的 `name`。
2. 生成脚本在 `models/tools/make_road_corners*.py`（此前有「生成过程已丢失」的
   误判——grep 只扫了 `src/` 与 `tools/`，漏了 `models/tools/`，2026-11-25 更正）。
3. Swift 侧个别注释仍写「数据源 road_corners_v2.json」（如
   `AuroraDriveApp.swift` 的 7426 附近），是 v2 时代的遗留表述，以
   `locateResource()` 的 `name` 为准。
