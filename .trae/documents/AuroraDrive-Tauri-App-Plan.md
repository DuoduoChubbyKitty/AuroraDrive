# AuroraDrive 原生 App 实施计划（Tauri v2 + Python Sidecar）

> ⚠️ 本文档为阶段7原始计划（Python Sidecar 路线），已被 Route B 纯 C++ 迁移取代。实际架构见 REFACTOR_CHANGELOG.md 阶段7 Route B 说明。

> 本计划基于 Phase 1 探索（亲自读取 run_web.py / App.tsx / useSimStore.ts / cpp_bridge.py / inference.py / vite.config.ts / package.json / CMakeLists.txt / config.py）与 Plan agent 架构设计综合而成。所有文件路径均来自真实代码核对，已剔除前序 Explore agent 的幻觉信息。

---

## 一、Context（背景与目标）

### 1.1 用户诉求
将 AuroraDrive（极光智行）从"浏览器 + 沙箱后端"形态升级为 **macOS 原生 App**：

1. **原生窗口行为**：放入 Dock + Applications 文件夹，支持三指拖拽、缩放、与其他 App 共存，行为与原生 App 一致，不依赖浏览器。
2. **独立运行时**：打包独立 Python 运行时（PyInstaller），使用系统原生 Python 或自带 Python，不依赖 agent 沙箱环境。C++ 模块一并打包。
3. **双模式**：
   - **模式 A（仿真驾驶）**：App 内 3D SR 仿真自动驾驶（现有 CockpitPage）
   - **模式 B（联动辅助）**：捕捉其他 App（如游戏《异环》、赛车游戏）画面，视觉分析 + HUD 辅助引导线，可选自动控制注入
4. **模式互斥 + 2D 降级**：联动模式时 3D 仿真降级为 2D 极低精度扁平小窗（AssistMiniMap），释放 WebGL 上下文与 GPU。
5. **硬性能预算**：CPU ≤ 30%、GPU ≤ 50%、显存 ≤ 2GB。界面简洁、bug 少。
6. **联动配置**：
   - 默认 HUD 辅助线，自动控制需手动开启 + 选定目标窗口 + 紧急停止
   - 视觉算法默认 OpenCV 30fps（流畅），可切 ONNX
   - 通用方案（任意 App/游戏）
   - 两者都要（HUD + 自动控制）

### 1.2 当前状态（已验证）
- **后端**：`run_web.py` 用 `_ROOT = Path(__file__).resolve().parent`（相对路径，打包友好），FastAPI/uvicorn 监听 8000，WebSocket 10Hz 推送。已有 `--static` 参数支持生产模式托管前端。
- **前端**：React 18 + Vite 6 + TS + Tailwind + R3F（fiber 8 / drei 9 / postprocessing）+ three 0.180 + zustand 5 + react-router-dom 7。3 个页面：CockpitPage（3D SR）/ NavigatorPage（2D）/ DebugPage。`App.tsx` 用 `BrowserRouter`，`useSimStore.ts` 硬编码 `ws://${window.location.hostname}:8000/api/ws`。
- **C++**：`cpp/` 下 `autodrive_core`（pybind11），提供 bike_step / TrafficManager / GridIndex / render_cameras。`src/cpp_bridge.py` 有 `CPP_AVAILABLE` 回退逻辑。已构建产物 `autodrive_core.cpython-311-darwin.so`（arm64）。
- **推理**：`src/inference.py` 用 torch（M9Model），App **不打包 torch**，联动模式视觉走全新 OpenCV/ONNX 路径。
- **地图**：`data/fujian_map.bin` ~1.3GB，需 zstd 压缩外置，首启解压到 `~/Library/Application Support/AuroraDrive/`。
- **系统环境**：macOS 26.5.1 / arm64，Swift CLT 可用（无完整 Xcode），opencv-python 4.13 已装，未装 pyinstaller/pyobjc/onnxruntime/torch/Rust/Tauri，brew 可用。
- **Task #34 已完成**：FSD 改名扫尾，全仓零 FSD 命中，pygame 可视化器已删。

---

## 二、技术选型（已与用户确认）

| 维度 | 选型 | 理由 |
|---|---|---|
| App 壳 | **Tauri v2** | Rust 主进程 + WKWebView，原生窗口行为，体积小（~10MB vs Electron 100MB+） |
| Python 运行时 | **PyInstaller --onedir** | 打包独立运行时，不依赖系统 Python；含 C++ .so + 前端 dist |
| 训练功能 | **不打包** | 只放运行时（推理+仿真+UI），训练留在源码 |
| 屏幕捕捉 | **ScreenCaptureKit**（macOS 12.3+） | 原生 API，按窗口过滤，硬编 JPEG，CPU 极低 |
| 视觉算法 | **OpenCV 30fps 默认**（可切 ONNX） | Canny + HoughLinesP + IPM，cv2.setNumThreads(2) 限 CPU |
| 输入注入 | **CGEvent**（PyObjC Quartz） | steer→A/D、throttle→W、brake→S，需"辅助功能"权限 |
| 3D 降级 | **unmount SRScene + Canvas 2D** | 联动模式释放 WebGL 上下文，换 AssistMiniMap |
| 地图外置 | **zstd 压缩 + 首启解压** | 1.3GB → ~600MB 进 bundle，解压到 App Support |
| 模式切换 | **状态机互斥** | mode: "sim" \| "assist"，切换时清理资源 |

### 性能预算（目标达标）
| 模式 | CPU | GPU | 显存 | 备注 |
|---|---|---|---|---|
| A 仿真 | ~19% | ~40% | ~550MB | 3D SR + 仿真 + WS |
| B 联动 | ~27% | ~16% | ~235MB | 截屏 + OpenCV + overlay |

---

## 三、Proposed Changes（分阶段实施）

### 阶段 1：构建工具链与依赖声明

**目标**：安装 Rust/Tauri 工具链，建立 Python 打包 venv，声明 App 依赖。

**新建文件**：
- `requirements-app.txt` — App 运行时依赖清单（不含 torch/numba）
  ```
  fastapi
  uvicorn[standard]
  pydantic
  numpy
  scipy
  networkx
  pyproj
  Pillow
  opencv-python==4.13.*
  pyobjc-core
  pyobjc-framework-Quartz
  pyobjc-framework-ScreenCaptureKit
  pyobjc-framework-AVFoundation
  pyobjc-framework-Cocoa
  onnxruntime  # 可选，联动模式 ONNX 档
  zstandard
  pyinstaller
  pybind11[global]
  ```
- `packaging/build_cpp.sh` — C++ 构建脚本（cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j && pip install build/）
- `scripts/setup_toolchain.sh` — 一键安装 Rust + Tauri CLI + 创建 venv
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source "$HOME/.cargo/env"
  cargo install tauri-cli --version "^2.0"
  /usr/local/bin/python3.11 -m venv .venv-app
  source .venv-app/bin/activate
  pip install -r requirements-app.txt
  ```

**验证**：`cargo tauri --version`、`rustc --version`、`.venv-app/bin/python -c "import cv2; print(cv2.__version__)"`

---

### 阶段 2：PyInstaller sidecar 打包

**目标**：把 Python 运行时 + 依赖 + C++ .so + 前端 dist 打包成 `aurora-sidecar` 可执行。

**新建文件**：
- `packaging/aurora_sidecar.spec` — PyInstaller spec
  - 入口：`run_web.py`（改造后，见下）
  - datas：`frontend/dist` → `frontend/dist`、`data/fujian_map.bin.zst` → `data/`
  - hiddenimports：`src.web_simulator`、`src.web_server`、`autodrive_core`、`src.assist.*`
  - binaries：`cpp/build/autodrive_core.cpython-311-darwin.so`
  - `--onedir`（启动快，崩溃可定位）
- `packaging/build_sidecar.sh` — 调用 PyInstaller 生成 sidecar

**修改文件**：
- `run_web.py` — 增加环境覆盖与 sidecar 探活协议
  - 从环境变量读 `AURORA_PORT`（默认 0 = 系统分配）、`AURORA_MAP_DIR`（默认 App Support）
  - 启动后打印 `READY:AURORA_PORT=<port>` 到 stdout（行协议，供 Tauri 探活）
  - 静态资源改为 `_MEIPASS / "frontend" / "dist"`（PyInstaller 解包目录）
- `src/config.py` — 地图路径支持环境覆盖
  - `MAP_FILE = Path(os.environ.get("AURORA_MAP_DIR", ROOT_DIR / "data")) / "fujian_map.bin"`
  - 首启检测：若 .bin 不存在但 .bin.zst 存在，解压

**验证**：`cd packaging && ./build_sidecar.sh`，运行 `dist/aurora-sidecar/aurora-sidecar`，观察 stdout `READY:AURORA_PORT=xxxx`，curl localhost:port/health 返回 ok。

---

### 阶段 3：Tauri 骨架 + sidecar 生命周期

**目标**：建立 Tauri 项目，主进程 spawn sidecar，前端走 sidecar 端口。

**新建文件**：
- `src-tauri/Cargo.toml` — Tauri v2 依赖（tauri 2、serde、tokio）
- `src-tauri/tauri.conf.json` — App 配置
  - `productName`: "AuroraDrive"
  - `identifier`: "com.auroradrive.app"
  - `app.window.title`: "AuroraDrive · 极光智行"
  - `app.window.width/height`: 1440/900
  - `app.window.minWidth/minHeight`: 1024/680
  - `bundle.macOS.minimumSystemVersion`: "12.3"
  - `bundle.targets`: ["app", "dmg"]
  - `bundle.icon`: ["icons/aurora.icns"]
  - `build.frontendDist`: "../frontend/dist"
  - `build.beforeBuildCommand`: "npm run build"
  - `app.security.csp`: 允许 ws://localhost:* 和 img-src data: blob:
- `src-tauri/src/main.rs` — 入口，注册 commands，启动 sidecar
- `src-tauri/src/sidecar.rs` — sidecar 进程管理
  - `spawn_sidecar()`：启动打包后的 `aurora-sidecar`，读 stdout 行，解析 `READY:AURORA_PORT=<p>`
  - 崩溃监控：监听子进程 exit，重启 ≤ 3 次，超过则弹原生对话框
  - `stop_sidecar()`：退出时优雅 kill
- `src-tauri/src/port.rs` — 端口分配（绑定 0 端口，取系统分配的空闲端口传给 sidecar）
- `src-tauri/src/commands.rs` — Tauri commands
  - `get_sidecar_port()` → 返回 sidecar 端口给前端
  - `get_sidecar_status()` → running / starting / crashed

**修改文件**：
- `frontend/src/App.tsx` — `BrowserRouter` → `MemoryRouter`（Tauri 无真实 URL）
- `frontend/src/store/useSimStore.ts` — WS URL 改为从 Tauri command 动态获取
  ```ts
  const WS_URL = import.meta.env.VITE_WS_URL
    ?? (window.__AURORA_SIDECAR_PORT__
        ? `ws://localhost:${window.__AURORA_SIDECAR_PORT__}/api/ws`
        : `ws://${window.location.hostname}:8000/api/ws`);
  ```
  - App.tsx 启动时先调 `invoke('get_sidecar_port')` 拿端口，设到 `window.__AURORA_SIDECAR_PORT__`，再 connect()
- `frontend/vite.config.ts` — 加 Tauri 适配
  - `envPrefix: ['VITE_', 'TAURI_']`
  - `server.strictPort: true`
  - `build.target: 'es2021'`
- `frontend/index.html` — 移除 Google Fonts CDN（CSP 问题），改本地字体或系统字体栈

**验证**：`cargo tauri dev` 启动，原生窗口出现，3D SR 场景渲染正常，WS 连接成功，ego 数据流动。

---

### 阶段 4：前端模式切换 + 2D 降级视图

**目标**：在 App 内增加"仿真 / 联动"模式切换，联动时降级 3D。

**新建文件**：
- `frontend/src/pages/AssistPage.tsx` — 联动模式主页
  - 左侧：CaptureCanvas（截屏画面 + 车道线 overlay）
  - 右下：AssistMiniMap（2D 扁平小窗，复用 NavigatorPage 绘图，scale=0.3）
  - 顶部：WindowPicker（选择目标窗口）+ EmergencyStop 按钮
- `frontend/src/components/assist/AssistMiniMap.tsx` — 2D 降级视图
  - Canvas 2D 绘制，复用 NavigatorPage 的道路/ego 绘图逻辑
  - 联动模式 unmount SRScene 释放 WebGL 上下文
- `frontend/src/components/assist/WindowPicker.tsx` — 窗口选择器
  - 调 `invoke('list_windows')` 获取可捕捉窗口列表
  - 选中后调 `invoke('start_capture', { windowId })`
- `frontend/src/components/assist/EmergencyStop.tsx` — 紧急停止按钮
  - 大红色按钮，点击调 `invoke('emergency_stop')`
  - 全局热键 ⌘. 也触发
- `frontend/src/lib/tauriBridge.ts` — Tauri invoke 封装
  - `getSidecarPort()` / `listWindows()` / `startCapture()` / `stopCapture()` / `emergencyStop()`
  - 浏览器环境降级为 no-op（保留 dev 兼容）

**修改文件**：
- `frontend/src/store/useSimStore.ts` — 增加 `appMode: "sim" | "assist"` 状态
- `frontend/src/App.tsx` — 根据 appMode 渲染 CockpitPage 或 AssistPage
- `frontend/src/components/NavRail.tsx` — 增加模式切换入口（仿真 / 联动）

**验证**：切换到联动模式，SRScene unmount，AssistMiniMap 显示 2D 扁平视图；切回仿真，3D 恢复。

---

### 阶段 5：Swift ScreenCaptureKit 插件 + 窗口选择

**目标**：原生捕捉目标 App 窗口画面，30fps JPEG 推给 Python sidecar。

**新建文件**：
- `src-tauri/plugins/screencapture/Cargo.toml` — swift-rs 依赖
- `src-tauri/plugins/screencapture/src/lib.rs` — Swift 桥接
- `src-tauri/plugins/screencapture/swift/capture.swift` — ScreenCaptureKit 实现
  - `list_windows()` → 返回 `[(id, title, owner)]`
  - `start_capture(window_id, socket_path)` → 创建 SCContentFilter + SCStream 30fps
    - 每帧 CVPixelBuffer → VideoToolbox 硬编 JPEG → 写入 Unix domain socket
  - `stop_capture()` → 停止 SCStream
- `src/assist/capture_bridge.py` — Python 端 socket 接收
  - 监听 Unix socket，收 JPEG 字节，放入帧队列
  - `get_frame()` → 返回最新 JPEG（丢弃旧帧保证低延迟）

**Tauri commands**（src-tauri/src/commands.rs 扩展）：
- `list_windows()` → 调 Swift 插件
- `start_capture(window_id)` → 调 Swift 插件，返回 socket 路径
- `stop_capture()`

**权限**：首次调用触发系统"屏幕录制"权限弹窗，需用户授权。

**验证**：选择某个窗口，CaptureCanvas 显示实时画面 30fps，CPU 增量 < 5%。

---

### 阶段 6：OpenCV 车道线检测 + HUD overlay

**目标**：对捕捉画面做车道线检测，渲染 HUD 辅助线。

**新建文件**：
- `src/assist/__init__.py`
- `src/assist/lane_detector.py` — OpenCV 车道线检测
  - `detect(jpeg_bytes) → LaneResult`
  - 流程：解码 → 灰度 → Canny(50,150) → ROI 梯形掩码 → HoughLinesP → 透视变换 IPM 鸟瞰 → 二次曲线拟合
  - `cv2.setNumThreads(2)` 限 CPU
  - 返回：左/右车道线点列 + 曲率 + 偏移 + 推荐转向
- `src/assist/overlay_protocol.py` — overlay 数据协议
  - `{type: "lane", left: [[x,y]...], right: [[x,y]...], center: [...], curvature, offset, steer_hint}`

**修改文件**：
- `src/web_server.py` — 增加 `/api/assist/lane` WebSocket，推送 lane 检测结果到前端
- `frontend/src/components/assist/CaptureCanvas.tsx`（新建）— Canvas 2D 绘制
  - 绘制 JPEG 画面 + overlay 车道线（青绿色）+ 推荐路径（粉色）+ 偏移指示

**验证**：捕捉赛车游戏画面，HUD 车道线叠加正确，转向提示随弯道变化，CPU 增量 < 8%。

---

### 阶段 7：自动控制注入 + 紧急停止

**目标**：可选的自动控制注入（默认关闭），紧急停止机制。

**新建文件**：
- `src/assist/control_injector.py` — CGEvent 输入注入
  - `inject(steer, throttle, brake)` → PyObjC Quartz CGEventCreateKeyboardEvent + CGEventPostToPid
  - steer→A/D、throttle→W、brake→S
  - 需"辅助功能"权限
- `src/assist/assist_runner.py` — 联动模式主循环
  - 30fps：get_frame → lane_detector.detect → overlay 推送
  - 自动控制开启时：根据 lane_result 计算 steer/throttle/brake → control_injector.inject
  - 安全阀：检测到画面静止 > 2s / 车道线丢失 > 0.5s → 自动暂停注入

**修改文件**：
- `frontend/src/components/assist/AssistPage.tsx` — 增加"自动控制"开关（默认关）
  - 开启前强制弹出确认对话框 + 选定窗口
  - 显示倒计时 3s 后开始注入
- `frontend/src/components/assist/EmergencyStop.tsx` — 紧急停止
  - 调 `invoke('emergency_stop')` → Rust 调 `stop_capture()` + Python `control_injector.stop()`
  - 全局热键 ⌘.（Tauri globalShortcut 注册）

**权限引导**：
- 首次开启自动控制 → 弹原生对话框引导到"系统设置 > 隐私与安全 > 辅助功能"
- `src-tauri/entitlements.plist` 声明权限用途

**验证**：开启自动控制，车辆按车道线行驶；按 ⌘. 或点 EmergencyStop，注入立即停止。

---

### 阶段 8：地图外置 + 权限引导 + 打包发布

**目标**：地图压缩外置，权限引导，生成 .app + .dmg。

**新建文件**：
- `packaging/compress_map.sh` — zstd 压缩地图
  ```bash
  zstd -19 data/fujian_map.bin -o data/fujian_map.bin.zst
  ```
- `src-tauri/entitlements.plist` — 权限声明
  - `com.apple.security.screen-recording` = true
  - `com.apple.security.automation.apple-events` = true（CGEvent）
- `src-tauri/Info.plist.template` — 权限用途描述
  - `NSScreenCaptureUsageDescription`: "AuroraDrive 需要捕捉其他应用画面以提供驾驶辅助"
  - `NSAppleEventsUsageDescription`: "AuroraDrive 需要模拟键盘以实现自动控制"
- `frontend/src/components/Onboarding.tsx` — 首启权限引导
  - 检测权限状态，引导到系统设置对应面板
- `README_APP.md` — App 使用说明

**修改文件**：
- `src-tauri/tauri.conf.json` — `bundle.resources` 加入 `data/fujian_map.bin.zst`
- `src/config.py` — 首启解压逻辑（若 .bin 不存在但 .zst 存在，解压到 App Support）

**打包命令**：
```bash
# 1. 构建 C++
cd cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j && pip install build/ && cd ..
# 2. 压缩地图
./packaging/compress_map.sh
# 3. 构建前端
cd frontend && npm run build && cd ..
# 4. 打包 sidecar
cd packaging && ./build_sidecar.sh && cd ..
# 5. 打包 App
cargo tauri build
```

**产物**：`src-tauri/target/release/bundle/{dmg,AuroraDrive.app}`

**安装**：
- 拖入 `/Applications/`
- Dock 添加

**验证**：
- 双击 .app 启动，原生窗口出现
- 三指拖拽、缩放正常
- 与其他 App 共存正常
- 不依赖浏览器、不依赖沙箱
- CPU/GPU/显存符合预算

---

## 四、Assumptions & Decisions（假设与决策）

### 假设
1. macOS 26.5.1 支持 ScreenCaptureKit（12.3+ 引入，确认满足）
2. Swift CLT 足以编译 swift-rs 插件（无需完整 Xcode，Plan agent 已验证）
3. arm64 架构，C++ .so 已为 arm64
4. 用户有 brew 可用，可安装 Rust 工具链
5. 地图文件 `data/fujian_map.bin` 存在（~1.3GB）

### 决策
1. **Tauri v2 而非 Electron**：体积小 10x，原生窗口行为，Rust 主进程性能好
2. **PyInstaller --onedir 而非 --onefile**：启动快（~1s vs 5s+），崩溃可定位单文件，体积稍大可接受
3. **不打包 torch**：torch ~2GB，App 仅需运行时（推理用 OpenCV/ONNX），训练留源码
4. **模式互斥 + 2D 降级**：联动时释放 WebGL 上下文，GPU 预算给视觉算法
5. **OpenCV 默认而非 ONNX**：30fps 流畅，无模型依赖，通用方案
6. **CGEvent 而非 AppleScript**：直接内核级注入，延迟 < 5ms
7. **Unix domain socket 传帧**：避免 TCP 开销，零拷贝倾向
8. **stdout 行协议探活**：简单可靠，跨平台
9. **地图 zstd 外置**：-19 压缩比 ~2x，首启解压一次

### 待执行中需关注的点
- Google Fonts CDN 必须移除（Tauri CSP 限制）
- BrowserRouter → MemoryRouter（Tauri 无 URL 历史）
- WS URL 必须动态获取 sidecar 端口
- `-march=native` 自用同机 OK，分发需改 `-march=armv8.5-a` 之类通用架构
- numba 缺失：Lidar 回退纯 Python（已有逻辑），App 不打包 numba
- 端口冲突：sidecar 绑 0 端口，系统分配

---

## 五、Verification（验证步骤）

### 阶段性验证（每阶段结束）
| 阶段 | 验证方式 | 通过标准 |
|---|---|---|
| 1 | `cargo tauri --version` + venv import cv2 | 工具链可用 |
| 2 | 运行 sidecar，curl health | stdout READY + HTTP 200 |
| 3 | `cargo tauri dev` | 原生窗口 + 3D 渲染 + WS 连通 |
| 4 | 模式切换 | 3D unmount + 2D 显示 + 切回正常 |
| 5 | 选窗口捕捉 | 30fps 画面 + CPU < 5% |
| 6 | 车道线检测 | HUD 叠加 + CPU < 8% |
| 7 | 自动控制 + 紧急停止 | 注入工作 + ⌘. 停止 |
| 8 | `cargo tauri build` + 安装 | .app 启动 + 原生行为 + 性能预算 |

### 最终验收（用户核心诉求逐条核对）
- [ ] 放入 Dock + Applications 文件夹
- [ ] 三指拖拽、缩放、与其他 App 共存
- [ ] 不依赖浏览器，独立运行
- [ ] Python 运行时独立打包，不依赖沙箱
- [ ] C++ 模块打包
- [ ] 双模式：仿真 3D + 联动 2D 降级
- [ ] 联动：HUD 默认 + 自动控制手动开 + 选窗口 + 紧急停止
- [ ] OpenCV 30fps 默认
- [ ] 通用方案（任意 App/游戏）
- [ ] CPU ≤ 30%、GPU ≤ 50%、显存 ≤ 2GB
- [ ] 界面简洁、bug 少

---

## 六、风险与缓解

| 风险 | 缓解 |
|---|---|
| 地图 1.3GB 太大 | zstd -19 压缩 ~600MB，首启解压到 App Support |
| C++ .so 绑定 Python 版本 | PyInstaller 打包对应 Python 3.11 + .so |
| 屏幕录制权限被拒 | Onboarding 引导 + 降级提示 |
| 辅助功能权限被拒 | 自动控制默认关，仅 HUD 仍可用 |
| numba 缺失 | Lidar 回退纯 Python（已有逻辑） |
| Tauri + Python 复杂度 | stdout 协议解耦，崩溃重启 ≤ 3 次 |
| CGEvent 兼容性 | 安全阀：画面静止/车道丢失自动暂停 |
| Swift 编译 | CLT 足够，无需完整 Xcode |
| Google Fonts CSP | 移除 CDN，用系统字体栈 |
| 端口冲突 | sidecar 绑 0 端口，系统分配 |
| macOS 26.5 API 变化 | ScreenCaptureKit 12.3+ 稳定，26.5 兼容 |

---

## 七、实施顺序与 Task 规划

建议按 8 阶段顺序实施，每阶段完成后验证再进入下一阶段。预计工作量：
- 阶段 1-3（骨架）：~40% 工作量，建立可运行的原生 App
- 阶段 4（模式切换）：~10%
- 阶段 5-7（联动功能）：~40% 工作量，核心新功能
- 阶段 8（打包发布）：~10%

**MVP 里程碑**：完成阶段 1-3 即可交付"原生 App 跑仿真驾驶"，满足用户最核心诉求（不依赖浏览器、原生窗口、独立运行时）。阶段 4-8 为增量增强。
