# 代码-31 构建部署与 run.sh 全解

> 覆盖源文件：`run.sh`（**182 行**，2026-09-29 `wc -l` 实测；本文写 170 行）+ `scripts/setup_toolchain.sh`（77 行）+ Package.swift 构建面 + 部署产物实况。基于当前仓库逐单元编写。
>
> ### 📌 2026-09-29 复核追加：模型检查补了 YOLOPX（+12 行）
>
> **改动**：`run.sh` 的 `[2/4] 模型检查` 段原先只查三个模型
> （`m9_mono` / `game_assist_control` / `yolo26s`），**漏了项目当前的核心感知资产 `yolopx`**。
> 现补上优先候选检查 + 回退候选列出：
>
> ```sh
> # YOLOPX 三合一：候选表首位优先，逐个回退（与 YolopxEngine.modelCandidates 对应）
> if [ -d "models/yolopx/yolopx3_pal8_detfp.mlmodelc" ]; then
>     echo "  yolopx3_pal8_detfp.mlmodelc: ✓ (★核心资产)"
> elif [ -d "models/yolopx" ] && [ -n "$(ls -A models/yolopx 2>/dev/null)" ]; then
>     echo "  yolopx3_pal8_detfp.mlmodelc: ⚠ 非首选，回退候选:"
>     ls -1 models/yolopx 2>/dev/null | sed 's/^/      /'
> else
>     echo "  yolopx: ✗ 缺失! (可行驶区/车道线/检测三合一头，★核心资产)"
> fi
> ```
>
> **为什么要补**：`yolopx` 是「**一个字节都不能换**」的红线模型（甲方围绕它投资）。
> 它缺失时程序**会静默降级**（`isDegraded` 初始为 true），
> 而原检查表**不会报任何异常**——用户只会看到"没有车道线和可行驶区"，
> 却查不到根因。**这类"漏检"比误报更危险。**
>
> **同时修正一处失效引用**：原 libpcap 缺失提示写「`NetworkPacketCapture.swift` 需要」，
> 但该文件**已废弃**（现仅存在于 `legacy/NetworkPacketCapture.swift`），
> 现役抓包实现在 `CoordinateCapture.swift`。已改。
>
> **实测验证**（`sh run.sh --status`）：
> ```
> [2/4] 模型检查
>   m9_mono.mlmodelc: ✓
>   game_assist_control.mlmodelc: ✓
>   yolo26s.mlmodelc: ✓
>   yolopx3_pal8_detfp.mlmodelc: ✓ (★核心资产)
> ```
> 另经 `sh -n run.sh` 语法检查通过。
>
> **本文其余内容（构建面修复史 / 签名顺序 / metallib 预编译等）仍然准确**，无需改动。

> **2026-09-25 深度复核记录**（133→170 行，+37 行全是 9-24 构建面修复）：
> ① **libpcap 检查重写（26–31 行）**：旧判据自 macOS 11 起恒为假必然误报（`ls /usr/lib/libpcap*`——系统库已全部移入 dyld 共享缓存磁盘上不存在实体文件；`brew list libpcap`——libpcap 是 macOS 自带库从不经 brew 装）→ 改用 **dyld 实际解析结果**判断（产物存在用 ①，编译前用 ② 兜底）；
> ② **构建输出不再被管道吞（64–68 行）**：旧写法 `swift build | tail -5` 管道吞掉退出码（set -e 失效）→ 构建失败仍部署/启动（2026-09-15 bagel_spam 编译失败曾误部署）→ 现完整记录 .last-build.log 并检查 exit code；
> ③ **`--disable-sandbox`（69–73 行）**：DSH workspace-write 沙盒下 SwiftPM 自身 sandbox_apply 会 Operation not permitted → manifest 编译失败；统一 scratch 到 `.build/scratch` 与增量构建共用缓存；
> ④ **metallib 预编译（9-24 改动 12）**：`xcrun metal -c Shaders.metal -fmodules-cache-path=.build/metal-cache` → metallib 双路径部署（bundle Contents/Resources + 项目根）——省启动 100ms-1s 运行时编译；**编译失败不阻塞部署**（运行时编译兜底，功能零损失）；-fmodules-cache-path 指 workspace 内防 /var/folders 被沙盒拒写静默失败；
> ⑤ **原子替换部署保留**（9-12 修复）：cp 到临时名 + mv 换 inode——防运行中实例按需分页读到新旧混合页 → CDHash 校验失败 → SIGKILL；
> ⑥ --auto-login 参数化：默认不自动登录（用户手动控制），传参才开 8s 检测登录守护。

## 一、run.sh 一键编译+签名+启动（全文 **182 行**；本文正文按 133 行编写，见文首复核块）

> ⚠️ **行号基准提示**：本节以下正文的行号引用（如「116–133 行」「123–133 行」）
> 基于 **133 行版本**。此后经历了 133→170（9-24 构建面修复）→ **182**（9-29 补 YOLOPX 检查）
> 两轮增长，**文末段落的实际行号已后移约 49 行**。
> 阅读时请以「段落标题」定位，不要直接按行号跳转。

**用法（2–5 行）**：`./run.sh` → 编译+签名+启动 GUI；`./run.sh --status` → **只检查环境，不启动**；`./run.sh --yolo-selftest <图片>` → YOLO 自检。`set -e`（出错即停）。

**部署产物实况（本机验证）**：`AuroraDriveUI`（5.4MB，2026-09-16 裸可执行）+ `AuroraDriveUI.app/Contents/`（bundle）+ 12 个历史备份可执行（位于 `docs/git/`，`AuroraDriveUI.bak-2026MMDD-*`）。

**`[1/4] 环境检查（18–32 行）**：

- `swift --version`（首行）+ `sw_vers -productVersion`——打印工具链与系统版本
- **libpcap 检查（27–32 行）**：`ls /usr/lib/libpcap*` 或 `brew list libpcap`——✓ 已安装 / ✗ 未安装（"NetworkPacketCapture.swift 需要"——**注意：NetworkPacketCapture 已移除不编译，现 NetworkLocator 用系统 libpcap；此提示文案滞后**）+ 安装命令 `brew install libpcap`

**`[2/4] 模型检查（34–45 行）**：`for m in m9_mono game_assist_control yolo26s`——三个模型逐个检查：

- `models/${m}.mlmodelc` 存在 → ✓（**编译版，首选**）
- `models/${m}.mlpackage` 存在 → ✓ (未编译,回退加载)
- 都无 → ✗ 缺失!

**`--status` 模式（47–52 行）**：打印"[完成] 仅检查模式,不启动。" + exit 0。

**`[3/4] 编译（54–70 行）——release 构建（必须先清缓存）**：

```sh
# 必须先清缓存! SwiftPM 缓存会导致代码改动不生效
rm -rf .build
# 修复：旧写法 `swift build | tail -5` 管道吞掉构建退出码（set -e 失效）
# → 构建失败时仍继续部署/启动。现在完整记录构建输出并检查 exit code，
#   失败时打印错误行并中止（防再犯：2026-09-15 bagel_spam 编译失败曾误部署）
swift build -c release > .last-build.log 2>&1
BUILD_RC=$?
tail -5 .last-build.log
if [ "$BUILD_RC" -ne 0 ] || [ ! -f "$BIN_SRC" ]; then
    echo "  编译失败! (exit $BUILD_RC) 错误摘录："
    grep -m 8 "error:" .last-build.log || tail -10 .last-build.log
    exit 1
fi
```

- **`rm -rf .build`（58 行）**：**每次全量重编译（SwiftPM 缓存会导致代码改动不生效）**
- **管道退出码修复（59–62 行）**：**旧写法 `swift build | tail -5` 的退出码是 tail 的（构建失败仍继续）——现在重定向到 `.last-build.log` + `BUILD_RC=$?` 显式检查**；防再犯标注："2026-09-15 bagel_spam 编译失败曾误部署"
- **双条件失败判定（65–69 行）**：`BUILD_RC != 0 || !-f BIN_SRC`——**退出码与产物存在性双查**；错误摘录 `grep -m 8 "error:"`（最多 8 行）或 tail -10

**`[4/4] 签名 + 部署（72–106 行）——ad-hoc 签名 + 原子替换：**

- **SIGKILL 根因（73–78 行注释，2026-09-12 修复）**："Code Signature Invalid——**进程按需分页——运行中实例会陆续从磁盘读未调入的页。旧的 `cp` 原地覆盖同一 inode 后，内核读到新旧混合的页，CDHash 校验失败 → 内核直接杀（Taskgated Invalid Signature，见 9/10 DiagnosticReports）。原子替换（cp 到临时名 + mv 换 inode）：运行中实例继续引用旧 inode（unlink 后 vnode 存活），新实例用新文件，谁都不受影响**"
- `codesign --force --deep --sign - "$BIN_SRC"`（**ad-hoc 签名**，失败容错 || true）
- **原子替换（82 行）**：`cp "$BIN_SRC" "$BIN_DST.tmp.$$" && mv -f "$BIN_DST.tmp.$$" "$BIN_DST"`——**换 inode 部署**
- `xattr -d com.apple.quarantine "$BIN_DST"`——**去隔离标记（Gatekeeper 不拦）**

**.app bundle 构建（85–103 行）——从子进程启动时需要（避免 SIGKILL）**：

- `AuroraDriveUI.app/Contents/MacOS/` 目录 + **原子替换复制**（同 inode 防护）
- **Info.plist（89–101 行）**：CFBundleExecutable=AuroraDriveUI / NSPrincipalClass=NSApplication / **CFBundleIdentifier=com.aurora.driveui** / CFBundleName=AuroraDrive / APPL / 1.0 / **LSMinimumSystemVersion=14.0**
- `codesign --force --deep --sign -`（bundle 整体签名）+ xattr 去隔离

**清理旧进程（106 行）**：`pkill -f "AuroraDriveUI"`——**部署前杀旧实例（防新旧两个 UI 抢引擎 socket）**——容错 || true。

**部署完成输出（108–114 行）**：裸可执行路径 + .app bundle 路径。

**启动（116–133 行）**：

> **⚠️ TCC 条目实测（2026-09-25，用户指出）**：本脚本默认 `open "$BUNDLE_DIR"`（启动 `.app` bundle），但**用户从未给 `.app` 授权**——TCC 权限一直只挂在**裸可执行文件** `/Users/dupi/Desktop/自动驾驶系统/AuroraDriveUI` 这个条目上。二者是**两个独立的 TCC 条目**，bundle 启动 → `ax=false screen=false` → 引擎 fail-fast 退出（`~/Library/Logs/AuroraEngine.log` 可见）。**正确启动方式是直接跑裸可执行**：
> ```bash
> nohup ./AuroraDriveUI > /tmp/aurora_ui_stdout.log 2>&1 &
> ```
> 实测此方式引擎继承 `ax=true screen=true` ✓。用户明确 2026-09-25："没必要"改 run.sh（不改脚本默认行为），但**必须知道 `./run.sh` 启动后 App 拿不到权限**——部署完请手动跑裸文件，或额外给 `.app` 单独授权。

- `--yolo-selftest <图片>` / `--yolo-bench <图片>`：**直接跑裸可执行**（`./$BIN_DST --yolo-selftest "$2"`）
- **GUI 启动（123–133 行）**：**优先用 .app bundle（LaunchServices 干净父进程）**——`open "$BUNDLE_DIR" --args --auto-login`；**--auto-login：启动即自动进入登录守护（每 8s 检测登录界面并点击，直到进游戏或 80s 超时）。游戏已登录/未开时守护安静退出，无副作用**
- 排障提示（129–133 行）："如果没出现窗口，检查：1. 屏幕录制权限（系统设置 → 隐私 → 屏幕录制）；2. 辅助功能权限（系统设置 → 隐私 → 辅助功能）；3. 手动跑裸文件: ./$BIN_DST"

## 二、工具链与部署产物（setup_toolchain.sh + 模型文件实况）

**`setup_toolchain.sh`（scripts/，77 行）——一键安装 AuroraDrive 原生 App 构建工具链（⚠️ Tauri 旧方案遗留）**：

- **安装内容（4–8 行）**：Rust + Cargo（rustup）/ Tauri CLI v2 / CMake / LibTorch（可选）——**这是曾经的 Tauri 前端架构（Rust shell + C++ sidecar + pnpm 前端）的工具链脚本，与当前 SwiftUI 纯原生架构（零外部依赖）无关——历史遗留**
- 四步：cargo 检查（rustup 安装 + source env）→ `cargo install tauri-cli --version "^2.0" --locked` → brew install cmake → **构建 C++ sidecar：`mkdir -p cpp/build && cmake .. && cmake --build .`**
- **⚠️ cpp/frontend 目录已不存在（本机验证）**——此脚本现在跑会在第 4 步失败（cmake 找不到 ../CMakeLists.txt）；**"下一步"提示（74–77 行）里的 `cargo tauri dev/build`、`pnpm run build` 均为旧方案命令**——保留仅为历史对照，不再使用

**Python 训练包（src/，本机验证存在）**：`src/train_game_assist.py`（**DriveState.startTraining 调用的训练脚本**，代码-25 单元六）/ train_mono.py / model.py / ml/ / assist/ / autonomy/ / config.py / mono_dataset.py——**DAgger 增量训练的 Python 侧**；`/usr/local/bin/python3.11` 存在（startTraining 的解释器）。

**tools/ 目录（80+ 文件，本机验证）——训练/诊断/转换/抓包脚本群**：

| 类别 | 代表文件 | 说明 |
|---|---|---|
| 训练 | train_recording.py / train_speed_ocr.py / train_speed_cnn_v5.py / ppocrv6_finetune/ | OCR/CNN 微调训练 |
| 转换 | convert_e2e_to_coreml.py / convert_e2e_v2.py / convert_e2e_v3.py / convert_yolo_to_coreml.py / export_game_assist_coreml.py / export_yolo26s_coreml.py | PyTorch → CoreML 导出（deployTrainedModel 的上游） |
| 数据构建 | build_final_map_db.py / build_hdf5.py / build_labeled_glyphs.py / build_speed_glyphs.py / build_speed_templates.py / crop_speed_roi.py / dagr_to_h5.py / label_strong_brake.py | 地图数据库/HDF5/字模构建 |
| 诊断 | diag_grad.py / diag_clusters.py / measure_glyph_slots.py / verify_*.py（10 个）/ roi_ab_test.py / full_audit.py / audit2.py | 簇分析/槽位测量/验证脚本 |
| 抓包 | aurora_capture.c / cgrab.py / mac_screen_record.py / record_video.py / hid_key.c / hid_look.c | C 抓包器/HID 探针 |
| 辅助 | game_focus.sh / menu_click.sh / save_shot.sh / stitch_map.py / fetch_complete_map.py | 游戏聚焦/截图/地图拼接 |

**模型文件实况（models/，本机验证）**：

| 模型 | 文件 | 说明 |
|---|---|---|
| M9 端到端 | `m9_mono.mlmodelc`（编译版） | InferenceEngine 默认（deployTrainedModel 的替换目标） |
| 第二司机 | `game_assist_control.mlmodelc` + `.mlpackage` + `_int8.mlpackage` | YOLO 接管档（训练产出 → 热部署） |
| YOLO 检测 | `yolo26s.mlmodelc` | YoloEngine（640×640 e2e） |
| OCR 双模型 | `ppocrv6_tiny_ft_int8.mlpackage` + `speed_digit_cnn.mlmodelc`（+v4/v4_int8） | SpeedOCRReader 主/备用 |
| 底图 | `bigworldmap-13056.jpg`（7.4MB）/ `bigworldmapSecond.png` / `yihuan_map_z4.png` | 小地图三候选 + 大地图主底图 |
| 地图数据 | `FINAL_complete_map_database.json`（7.2MB，5677 标记） | GameMapView |
| 训练权重 | `yolo26s.pt`（根层，exclude）/ `data/lane_batches.json` | PyTorch 源权重（2026-09-20 整理后批次清单迁入 `data/`） |

**历史备份（`docs/git/` 下 12 个 AuroraDriveUI.bak-*，本机验证）**：2026-08-07 至 2026-09-13 的部署快照（2.5MB→5.4MB）——**回滚点**（SIGKILL/误部署时可退回上一个可用版本）。

## 三、scripts/build-lock.sh 原子构建锁（2026-10-06 追加，全部行号本次逐行核实）

> **scripts/ 是 git 未跟踪的新目录**（2026-10-06 `git status` 实测：目录下 7 个文件中仅
> `setup_toolchain.sh` 已跟踪，其余 6 个——`build-lock.sh` / `check-package-sources.sh` /
> `paired-ab.sh` / `perf-snapshot.sh` / `regression-gate.sh` / `README.md`——均为 `??` 未跟踪状态）。

### 3.1 为什么需要构建锁（`scripts/build-lock.sh:6-17` 文件头注释，本次核实）

1. **SwiftPM 是全模块编译**：多人并发改文件 + 并发 `swift build` 会互相打断，典型报错
   `error: input file '.../AuroraTheme.swift' was modified during the build`（`:7-11`）；
   且一人写坏，全组的 `swift build` 一起失败。
2. **更隐蔽的危害是并发基准测量**：实测 3 个 agent 同时跑 `--mc-map-bench --iters 200`
   各占 ~85% CPU，loadavg 冲到 5.15/8 核——此时**任何耗时类数字都不可比**（`:14-17`）。
   所以「长任务」（自检/基准/门禁采集）也必须持锁，不只是 `swift build`。

### 3.2 用法（`:19-27`，本次逐行核实）

```sh
bash scripts/build-lock.sh acquire "阶段A验收"   # 拿不到 → 退出码 3（:95）
bash scripts/build-lock.sh release
bash scripts/build-lock.sh status
bash scripts/build-lock.sh run "原因" -- <命令...>   # 自动加锁/解锁（:129-138）

# 脚本内推荐写法（:25-27）：
bash scripts/build-lock.sh acquire "regression-gate" || exit 3
trap 'bash scripts/build-lock.sh release' EXIT
```

### 3.3 设计约束（本次核实）

- **`mkdir` 做原子锁**——bash 3.2 没有 `flock` 命令，但 `mkdir` 是原子的（`:30`）。
  锁路径 `${AURORA_BUILD_LOCK:-${TMPDIR:-/tmp}/aurora-build.lock}`（`:37`）。
- 锁目录里写 `owner` 文件（pid/时间/主机/用户/原因/cwd，`:64-71`），便于判断谁持有。
- **残留锁超过 `AURORA_BUILD_LOCK_STALE_MIN`（默认 15 分钟，`:38`）→ 只提示，不自动删**
  （`:91-94`，"万一真的还在跑"）；持锁进程已死也只提示可安全清理（`:87-90`）——保守策略。
- `release` 校验持有者 pid 与调用方一致才删（`:102-107`），防误删别人的锁。

**构建部署文档至此完整**（run.sh 四步全解 → 工具链遗留说明 → 训练包/脚本群 → 模型文件 → 备份 → **构建锁**）。