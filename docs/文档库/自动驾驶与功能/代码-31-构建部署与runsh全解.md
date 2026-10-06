# 代码-31 构建部署与 run.sh 全解

> ### ⚠️ 2026-10-07 复核块（**持锁构建 → mtime 防静默 → 原子双写部署 → 自检矩阵**，逐条实测）
>
> 本次把「日常迭代怎么构建、怎么验证构建真的生效、怎么部署、部署后跑什么」固化成可复制流程。
> 实测快照：`AuroraDriveUI` **13,347,768 B**（2026-10-07 02:29:11）、
> `.build/scratch/release/AuroraDrive` 同尺寸（02:27:48）、
> `.app/Contents/MacOS/AuroraDriveUI` 同尺寸（02:29:11）——两者都是**原子替换**的产物。
>
> **三处 sha256 实测完全一致**（「双写一致性」最硬的证据，本次已跑）：
>
> ```
> cb36c690a9fb672b8b1418c8bdedf3f39224c1e391f43ba6a0dbbc6f0c27470e  .build/scratch/release/AuroraDrive
> cb36c690a9fb672b8b1418c8bdedf3f39224c1e391f43ba6a0dbbc6f0c27470e  ./AuroraDriveUI
> cb36c690a9fb672b8b1418c8bdedf3f39224c1e391f43ba6a0dbbc6f0c27470e  AuroraDriveUI.app/Contents/MacOS/AuroraDriveUI
> ```
>
> 另：构建锁当前空闲（`bash scripts/build-lock.sh status` → `🔓 无锁（空闲）`）。
>
> ---
>
> ## ★ 一、标准构建命令（持锁，唯一推荐写法）
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> bash scripts/build-lock.sh run "<原因>" -- \
>   swift build -c release --disable-sandbox --scratch-path .build/scratch
> ```
>
> 逐项理由（全部有源码/实测依据）：
>
> | 片段 | 为什么必须有 |
> |---|---|
> | `bash scripts/build-lock.sh run "<原因>" --` | **多人/多 agent 并发时 SwiftPM 是整模块编译**，会互相打断（`error: input file '...' was modified during the build`，`build-lock.sh:7-11`）；且一人写坏全组都验不了。`run` 自动加锁/解锁（`:129-138`），拿不到锁退出码 **3**（`:95`） |
> | `-c release` | 发布构建；自检/基准都在 release 产物上跑 |
> | `--disable-sandbox` | DSH workspace 沙盒下 SwiftPM 自身 sandbox_apply 会 `Operation not permitted` → manifest 编译失败（run.sh:69-73 的 9-24 修复记录） |
> | `--scratch-path .build/scratch` | 统一 scratch 目录，与增量缓存共用；`scripts/perf-snapshot.sh:128`、`scripts/regression-gate.sh:66`、`run.sh:85` 三处同一写法 |
>
> **产物路径**：`.build/scratch/release/AuroraDrive`（**不是** `.build/release/`，别找错文件）。
>
> 不需要锁的场合（单人、空仓、只读检查）可以直接 `swift build -c release --disable-sandbox --scratch-path .build/scratch`，
> 但只要有人在同时构建/跑基准，走锁是硬要求。
>
> ---
>
> ## ★ 二、构建后必做：**校验二进制 mtime ≥ 源码 mtime**（防静默不重编译）
>
> **为什么必须查**：SwiftPM 增量构建在若干情况下会「看起来成功、实际没重编」——
> 产物 mtime 比源码还旧，而你**照样 cp 上去了**，于是「改了代码但行为没变」，
> 排查方向全错（会怀疑自己改错地方、怀疑自检不会红）。
> **这是构建环节最隐蔽的假绿，与自检层的 oneShotFlags 假绿同级。**
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> BIN=.build/scratch/release/AuroraDrive
>
> # ① 产物必须存在且比「最新的一个源文件」新
> newest_src=$(find Sources -name '*.swift' -exec stat -f '%m %N' {} \; | sort -rn | head -1)
> echo "最新源文件: $newest_src"
> stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' "$BIN"
>
> # ② 一行判定（列出所有比产物新的源文件；输出为空 = 通过）
> find Sources -name '*.swift' -newer "$BIN" -print
> #    ✅ 空输出 → 产物是最新的
> #    ❌ 有输出 → **静默未重编译**，删缓存重来（见下）
>
> # ③ 更硬的证据：源码里新加的东西必须能在二进制里被 strings 找到
> strings "$BIN" | grep -c -- '--websearch-selftest'      # 期望 ≥ 1
> ```
>
> **本次实测**：`find Sources -name '*.swift' -newer AuroraDriveUI` → **0 个文件**；
> 最新源文件 `Sources/AuroraDrive/Agent/AIAgentPanel.swift`（02:26:30）早于二进制（02:29:11）→ **通过**。
>
> **不通过时的标准处理**（顺序照做）：
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> # 只删 scratched 产物，再重建（保守做法；彻底做法是 rm -rf .build，但代价是全量重编）
> rm -rf .build/scratch/release/AuroraDrive
> bash scripts/build-lock.sh run "强制重编" -- \
>   swift build -c release --disable-sandbox --scratch-path .build/scratch
> find Sources -name '*.swift' -newer .build/scratch/release/AuroraDrive -print   # 必须为空
> ```
>
> ⚠️ **`run.sh` 的老做法是每次 `rm -rf .build` 全量重编**（`run.sh:80`）——
> 那是「宁可慢也别静默」的取舍，日常迭代**不建议**（代价高），但**上线前**可以用它兜底一次。
>
> ---
>
> ## ★ 三、标准部署流程：备份 /tmp → `cp` + `mv` **原子双写**
>
> **两个目标必须同时更新**（`AuroraDriveUI` 裸可执行 + `.app/Contents/MacOS/AuroraDriveUI`）：
> 只更新一个 → 用户从不同入口启动到**两个不同版本**，症状荒诞且极难排查
> （历史教训：把备份二进制放进 `.app/Contents/MacOS/` 里，见 `AuroraDrive-交接文案.md:114`）。
>
> **本流程与 `run.sh:102-113` 的实际做法逐句对齐**（同一套动作，这里补了备份与校验）：
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> SRC=.build/scratch/release/AuroraDrive
> TS=$(date +%Y%m%d-%H%M%S)
> APP=AuroraDriveUI.app/Contents/MacOS/AuroraDriveUI
>
> # ① 备份当前线上二进制到 /tmp（可回滚点）
> cp -p ./AuroraDriveUI "/tmp/AuroraDriveUI.bak-deploy-$TS"
>
> # ② 原子替换：先 cp 到临时名（同目录，保证同一文件系统），再 mv 换 inode
> #    —— 与 run.sh:105 / run.sh:112 同款写法（.tmp.$$）
> cp "$SRC" "./AuroraDriveUI.tmp.$$" && mv -f "./AuroraDriveUI.tmp.$$" ./AuroraDriveUI
> cp "$SRC" "$APP.tmp.$$"            && mv -f "$APP.tmp.$$" "$APP"
>
> # ③ ad-hoc 签名 + 去隔离标记（顺序照抄 run.sh:104-107：
> #    签 BIN_SRC → cp+mv → xattr -d；两边都要去隔离）
> /usr/bin/codesign --force --deep --sign - "$SRC" 2>/dev/null || true
> /usr/bin/xattr -d com.apple.quarantine ./AuroraDriveUI 2>/dev/null || true
> /usr/bin/xattr -d com.apple.quarantine "$APP" 2>/dev/null || true
>
> # ④ 双写一致性自证（三处 sha256 必须完全相同）
> shasum -a 256 "$SRC" ./AuroraDriveUI "$APP"
> ```
>
> **部署前清旧进程**（`run.sh` 的 `pkill -f "AuroraDriveUI" || true`）——
> 防新旧两个 UI 抢引擎 socket（0.5s 断开重连死循环）。
>
> **为什么要 `cp` 到临时名再 `mv`（原子替换）而不是直接 `cp` 覆盖**：
> 直接 `cp` 是**原地覆盖同一 inode**；正在运行的实例按需分页，会陆续从磁盘读到
> **新旧混合的页** → CDHash 校验失败 → 内核直接杀（Taskgated Invalid Signature）。
> `mv` 换 inode 后，运行中实例继续引用旧 inode（unlink 后 vnode 存活），新实例用新文件，互不影响。
> 该修复与完整背景见本文 §一「SIGKILL 根因」与 `run.sh:94-101` 注释。
>
> **部署后必须再跑自检**（否则等于「部署了个没验证过的文件」）：
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> # 用**已部署的那个文件**跑，不是 .build 产物
> AURORA_UI_LOCAL=1 ./AuroraDriveUI --tool-selftest | tail -2
> AURORA_UI_LOCAL=1 ./AuroraDriveUI --wire-selftest | tail -2
> # 完整矩阵见 代码-33 §5
> ```
>
> ⚠️ **TCC 条目提醒（仍然成立，见本文 §一）**：权限只挂在**裸可执行文件**上，
> 不能拿 `.app` bundle 启动去跑需要 AX/录屏权限的自检（会 `ax=false screen=false`）。
>
> ---
>
> ## ★ 四、部署场景下的 8 个 AI 自检（及为什么它们改变交付流程）
>
> 本次新增的 8 个 AI flag 让「部署后验证」从「跑通不崩」升级为**可断言的交付门禁**
> （逐个 flag、依赖、实测项数详见 代码-33 §2 与 §5）。对**构建部署**流程的直接影响有三条：
>
> 1. **`--tool-selftest` / `--websearch-selftest` / `--llm-selftest`（离线）不需要网络也不需要游戏**，
>    可以放进任何一次部署后的冒烟检查，成本只有几秒。
> 2. **`--control-selftest` / `--llm-vision-selftest` 需要 TCC 权限**，
>    必须用**裸可执行文件**跑（`.app` 无授权），且 `--control-selftest` 依赖辅助功能权限。
> 3. **`--llm-probe` / `--llm-selftest --network` / `--tool-call-demo` 需要网络**，
>    属于「联网可用性」验收，不放进无网冒烟。
>
> 一条可复制的部署后冒烟（离线部分，约十几秒）：
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> bash scripts/build-lock.sh run "部署后冒烟" -- bash -c '
> BIN=./AuroraDriveUI
> for f in --quest-selftest --route-selftest --taxonomy-selftest --wire-selftest \
>          --llm-selftest --control-selftest --tool-selftest; do
>   AURORA_UI_LOCAL=1 $BIN $f > /tmp/smoke$(echo $f | tr -d --).log 2>&1
>   echo "$f -> EXIT=$?"
> done
> AURORA_UI_LOCAL=1 $BIN --websearch-selftest "swift actor" >/tmp/smoke-websearch.log 2>&1
> echo "--websearch-selftest -> EXIT=$?"
> '
> ```
>
> ---

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

> **⚠️ 2026-10-07 补**：本节就是顶部「标准构建命令」的依据——`scripts/build-lock.sh` 的
> 取用方式见 3.2；`mkdir` 原子锁、残留锁只提示不自动删、`release` 校验 pid（3.3）三条设计约束
> 本次逐行复核仍然成立（**脚本 146 行**，`wc -l` 实测）。

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

**构建部署文档至此完整**（run.sh 四步全解 → 工具链遗留说明 → 训练包/脚本群 → 模型文件 → 备份 → **构建锁** → **2026-10-07 复核对：持锁构建 / mtime 防静默 / 原子双写部署 / 部署后自检矩阵**）。

> **配套阅读**：
> - CLI flag 全集、8 个 AI 自检的**逐 flag 说明 + 两个陷阱 + 完整自检矩阵** → 代码-33 进程模式与CLI参数全解 §1/§2/§5
> - AI 助手链路设计 → 代码-23 / AI_AGENT_DESIGN.md；踩坑总表 → pitfalls.md