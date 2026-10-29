# 8 · GPU 占用归因方法（把 36.4% 设备级活跃拆到进程）

- 探测时间：2026-10-24 22:33–22:47
- 探测机器：M3 MacBook Air / 16GB / macOS 27.0.1（Build 26A434）
- 探测性质：**纯只读探测**。未改业务代码、未 build、**未启动 AuroraDrive**（探测期间曾观察到 Aurora 进程在跑，那是既有实例，非本次启动）。
- 纪律：每条命令都真跑过；超过几秒或需 root 的方向不强行执行，一律标注「未验证」。

---

## 1. 一句话结论

**`ioreg` 的 `AGXDeviceUserClient` 节点里藏着 per-client 的 `accumulatedGPUTime`（纳秒），按 `IOUserClientCreator` 的 pid 聚合求差，就能得到「每个进程占多少 GPU」——这条路已在本机跑通并做了正对照验证；`powermetrics`、`ps`/`top`、`task_gpu_utilisation`、`sample`/`spindump` 五条路已验证不可用。**

可直接用的命令（本次已落库为 `scripts/gpu-attrib.sh`）：

```bash
bash scripts/gpu-attrib.sh 3 3
```

同窗口取设备级对照：

```bash
ioreg -r -c IOAccelerator -w 0 | grep -o '"Device Utilization %"=[0-9]*'
```

真实输出（本机实跑，3 秒窗口）：

```
===== 窗口 3.0s #1  设备 Device Util: 17% → 33% =====
     pid 进程名                         ΔGPUTime(ns)   GPU ms/s    客户端
     669 WindowServer                   593242291      197.7      2
   39600 DeepSeek Harness Helper        334291958      111.4      1
   53133 QQ Helper                        9864208        3.3      1
   39892 ego Helper                       7238959        2.4      1
   36810 com.apple.WebKit.GPU             2392000        0.8      1
-- 全部 GPU 客户端合计: 315.7 ms/s (双向累加折合 31.6%)
```

> 关键：探测窗口内曾抓到 Aurora 自己的两行（`AuroraDriveUI` 分别 8.9 与 0.1 ms/s），说明**这个数据源直接就能回答"YOLOPX 那个引擎进程占多少"**。

---

## 2. 判定速查表

| # | 方向 | 判定 | 一句话理由 |
|---|---|---|---|
| 1a | Activity Monitor 的 per-process GPU%（**查它的数据源**） | **已在本机验证可定位** | 二进制里直接含 `accumulatedGPUTime` 字样，与 ioreg 字段同名同源 |
| 1b | Activity Monitor **本身**能否脚本化 | **验证不可用** | 无 CLI；`defaults` 里只有列宽缓存，没有开关 |
| 1c | `ps` 取 GPU 列 | **验证不可用** | `ps: gpu: keyword not found` |
| 1d | `top` 取 GPU 列 | **验证不可用** | `top -o gpu` / `-stats gpu` 均报 invalid |
| 2 | xctrace `Metal System Trace` 录制与导出 | **已在本机验证可用** | 2s/43MB 与 3s 系统级录制均成功，TOC 含 WindowServer |
| 2b | xctrace **按进程导出 GPU 时间数值** | **未验证** | 只验证到"能录能导出、有按 pid 的表"，没跑到具体数值 |
| 3 | **ioreg `AGXDeviceUserClient` per-client 归因** | **已在本机验证可用** ✅ | 有 pid + 纳秒计数，正对照与 CoreImage 对照均通过 |
| 3b | ioreg **设备级** `Device Utilization %` | **已在本机验证可用** | 但与窗口均值不可比（瞬时值，会从 0% 跳到 21%） |
| 4 | `sample` 采 WindowServer | **验证不可用** | 权限拒绝；同一工具采自己进程是成功的 |
| 5a | `powermetrics --show-process-gpu`（非 root） | **验证不可用** | `powermetrics must be invoked as the superuser` |
| 5b | `powermetrics` root 下 GPU ms/s 恒 0.00 | **未验证**（采信用户既有实测） | 本会话 sudo 需密码，无法复现 |
| 5c | `spindump` | **验证不可用** | `spindump must be run as root when sampling the live system` |
| 5d | `sysdiagnose` | **未验证** | 会生成大归档且耗时数分钟，违反"几秒内返回"，未执行 |
| 5e | 私有 `task_power_info_v2.task_gpu_utilisation` | **验证不可用** | 自建 Metal 压力进程实测仍恒 0 |
| 5f | `proc_pid_rusage` / `rusage_info_v6` | **验证不可用** | SDK 头文件里根本没有 GPU 时间字段 |
| 5g | MetricKit `MXGPUMetric.cumulativeGPUTime` | **未验证** | 仅用于 App 自身上报、按日聚合，不能实时拆进程，未跑 |

---

## 3. 逐方向实测记录

### 3.1 Activity Monitor：数据源找到了，但它自己没法脚本化

**执行（全部真跑）**

```bash
ps -Ao pid,%cpu,comm | head -12
ps -Ao pid,gpu | head -3
top -l 1 -o gpu -n 8
top -l 1 -stats pid,cpu,gpu -n 5
defaults read com.apple.ActivityMonitor
```

**真实输出（关键行）**

```text
$ ps -Ao pid,gpu
ps: gpu: keyword not found
  PID

$ top -l 1 -o gpu -n 8
invalid argument -o: gpu
	[-o <key>] [-O <secondaryKey>]
		keys: pid (default), command, cpu, cpu_me, cpu_others, csw,
			time, threads, ports, mregion, mem, rprvt, purg, vsize, vprvt,
			kprvt, kshrd, pgrp, ppid, state, uid, wq, faults, cow, user,
			msgsent, msgrecv, sysbsd, sysmach, pageins, boosts, instrs, cycles

$ top -l 1 -stats pid,cpu,gpu -n 5
invalid stat: gpu
invalid argument for -stats: pid,cpu,gpu
```

`ps` 与 `top` 的关键字清单里**没有任何 GPU 键**，所以「用 ps/top 脚本化取 per-process GPU%」这条直接死掉。

`defaults read com.apple.ActivityMonitor` 确实有 GPU 相关的键，但它们是**列宽缓存**，不是数据开关：

```text
"Column Width" =     {
        CPU =         {
            ...
            GPUTime = 75;
            GPUUsage = 75;
            ...
```

**决定性证据：Activity Monitor 从哪取数**

```bash
BIN="/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor"
otool -L "$BIN" | grep -iE "iokit|metal|ioreport|systemstats"
strings -a "$BIN" | grep -iE "IOAccelerator|AGXDeviceUserClient|AppUsage|accumulatedGPUTime|Device Utilization"
```

真实输出：

```text
/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit (compatibility version 1.0.0, ...)
/System/Library/Frameworks/Metal.framework/Versions/A/Metal (compatibility version 1.0.0, ...)
/usr/lib/libIOReport.dylib (compatibility version 1.0.0, ...)
/usr/lib/libsystemstats.dylib (compatibility version 1.0.0, ...)

accumulatedGPUTime          ← 二进制里直接存在这个字符串
```

同时 `strings` 还能看到 `SMGPUMonitor`、`SMGPUController`、`GPUTime`、`GPUUsage`。

**判定**

- **1a 数据源：已在本机验证可定位。** Activity Monitor 的 per-process GPU 与 §3.3 我们读的 ioreg 字段**同名（`accumulatedGPUTime`）**，且它链接了 IOKit。这是"字符串同源"级别的证据，不是反编译结论——严格说我只证明了两者使用同一个字段名、同一个框架家族，没有证明它逐字节就是读那个 ioreg 节点。**要完全坐实需反汇编或 DTrace，本次未做。**
- **1b 脚本化 Activity Monitor 本身：验证不可用**——它没有命令行接口，`defaults` 里也没有可切换的数据开关。
- **1c/1d `ps`/`top`：验证不可用**（见上，参数直接被拒）。

> **这一条的意义**：既然 Activity Monitor 用的就是 `accumulatedGPUTime`，而我们能直接读同一个数据源，那就**不需要**再去驱动 GUI 或截屏 OCR 界面数字——脚本化读 ioreg 是等价且更精确的路径。§3.3 已实测跑通。

---

### 3.2 xctrace：能录、能导出、有按进程的表；但没跑到具体数值

**执行**

```bash
xcrun xctrace list templates
xcrun xctrace list instruments | grep -iE "metal|gpu"
xcrun xctrace help record
```

**真实输出（关键行）**

```text
== Standard Templates ==
Activity Monitor
...
CPU Counters
Core ML
...
Game Performance
Game Performance Overview
...
Metal System Trace          ← 有
...
System Trace
Tailspin
Time Profiler
```

模板清单里**确实有 `Metal System Trace`**，另有 `Core ML`、`Game Performance`、`Animation Hitches`；**没有叫 `GPU Driver` 的模板**，但有同名的 instrument：

```text
== Standard Instruments ==
Advanced Graphics Statistics
Core Animation Activity
Core Animation Commits
Core Animation FPS
Core Animation Server
Core ML
Display
GPU
Metal Application
Metal GPU Counters
Metal Performance Overview
Metal Resource Events
Neural Engine
SceneKit Application
```

`record` 支持限时与系统级采集：

```text
--time-limit <time[ms|s|m|h]>          Limit recording time to the specified value
--attach <pid|name>                    Attach and record process with the given name or pid
--all-processes                        Record all processes
```

**实测录制（遵守 ≤10s，两次都很短）**

```bash
# ① 2 秒，只挂自己的 sleep
sleep 20 & SP=$!
xcrun xctrace record --template 'Metal System Trace' --attach $SP --time-limit 2s \
        --output /tmp/xct_test.trace --no-prompt

# ② 3 秒，系统级全进程
xcrun xctrace record --template 'Metal System Trace' --all-processes --time-limit 3s \
        --output /tmp/xct_all.trace --no-prompt
```

真实输出：

```text
Starting recording with the Metal System Trace template. Attaching to: sleep (74657). Time limit: 2.0 s
Reached specified time limit, ending recording...
Recording completed. Saving output file...
Output file saved as: xct_test.trace
→ 43M	/tmp/xct_test.trace        ← 2 秒就 43MB，长录会爆盘

Starting recording with the Metal System Trace template. Targeting All Processes. Time limit: 3.0 s
Recording completed. Saving output file...
Output file saved as: xct_all.trace
```

系统级录制覆盖到了 WindowServer：

```bash
xcrun xctrace export --input /tmp/xct_all.trace --toc | grep -oE 'process name="[^"]+" pid="[0-9]+"' | grep -iE "windowserver|aurora"
```

```text
process name="WindowServer" pid="669"
（进程总数 = 223）
```

TOC 里存在**按 pid 归属**的表，这是"能否按进程统计 GPU 提交"的关键：

```text
<template-name>Metal System Trace</template-name>
<instrument name="Metal Application">
<table schema="metal-shader-profiler-intervals" target-pid="SINGLE" documentation="Denotes Shader Timeline intervals"/>
<table schema="ca-client-present-request" documentation="Denotes client requests to present a CAMetalDrawable."/>
<table schema="displayed-surfaces-interval" target-pid="SINGLE" documentation="Shows when a surface is being displayed."/>
<table schema="display-compositor-events-interval" documentation="Shows generic compositor events"/>
<table schema="metal-residency-set-usage-event" documentation="Denotes a MTLResidencySet usage"/>
```

**判定**

- **"xctrace 能录、能导出、覆盖 WindowServer、含按 pid 的 Metal/合成事件表"：已在本机验证可用。**
- **"xctrace 能按进程输出 GPU 时间毫秒数"：未验证。** 我只验证到表结构存在（`target-pid="SINGLE"`、`ca-client-present-request`），**没有实际导出一张按进程的 GPU 时间汇总表并读出数字**。要把这条升级成"可用"，还需一步：`xctrace export --xpath` 导出 `metal-shader-profiler-intervals` / `ca-client-present-request` 并核对是否有可加总的时长字段。
- 已知约束：**2 秒 43MB**，所以只适合短窗口；且需要 GUI 会话权限（本次在非 root 下录制成功，说明这部分不需要 root）。

---

### 3.3 ioreg per-client：✅ 唯一验证可用且能给出进程级数字的路

**第一步：确认 `-c IOAccelerator` 本身没有 per-client 数据**

```bash
ioreg -r -c IOAccelerator -w 0 | head -40
```

真实输出（节选）：

```text
+-o AGXAcceleratorG15G  <class AGXAcceleratorG15G, id 0x1000004be, registered, matched, active, busy 0 (6192 ms), retain 75>
  | {
  |   "AGCInfo" = {"fLastSubmissionPID"=60089,"fSubmissionsSinceLastCheck"=0,"fBusyCount"=0}
  |   "PerformanceStatistics" = {"Tiler Utilization %"=61,"recoveryCount"=0,
        "Renderer Utilization %"=60,"Device Utilization %"=62,"SplitSceneCount"=0,...}
```

→ 设备级节点只有 `Device Utilization % / Renderer / Tiler` 三个百分比，**没有 per-client、也没有 accumulatedGPUTime**。`AGCInfo` 里那个 `fLastSubmissionPID` 只是"最后提交者"，不是时间累计，不能用来归因。

**第二步：按用户给的 grep 找可用键，意外命中真正的数据源**

```bash
ioreg -l | grep -i "gpu.*time\|GPUTime\|Device Utilization" | head -20
```

命中 32 行，关键三行（去掉噪音后）：

```text
+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x10000103a, !registered, !matched, active, busy 0, retain 5>
  |     "AppUsage" = ({"API"="Metal","lastSubmittedTime"=696880082362208,"accumulatedGPUTime"=91625126731791},{"API"="Metal","lastSubmittedTime"=696029727123416,"accumulatedGPUTime"=150242375},{"API"="Metal","lastSubmittedTime"=0,"accumulatedGPUTime"=0},{"API"="Metal","lastSubmittedTime"=0,"accumulatedGPUTime"=0})
  |     "IOUserClientCreator" = "pid 669, WindowServer"
  |     "CommandQueueCount" = 4
```

**这就是答案**：`AGXDeviceUserClient` 节点 = 一个 GPU 客户端；`IOUserClientCreator` 给出 **pid + 进程名**；`AppUsage[].accumulatedGPUTime` 给出**累积 GPU 执行时间（纳秒）**。

**第三步：确认节点规模与可脚本化（XML 化）**

```bash
ioreg -r -c AGXDeviceUserClient -w 0 | grep -c "AGXDeviceUserClient  <class"
ioreg -a -r -c AGXDeviceUserClient | head -30
ioreg -a -r -c AGXDeviceUserClient | wc -c
```

真实输出：

```text
67                      ← 67 个 GPU 客户端节点

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<array>
	<dict>
		<key>AppUsage</key>
		<array/>
		<key>IOObjectClass</key>
		<string>AGXDeviceUserClient</string>
		...
		<key>IOUserClientCreator</key>
		<string>pid 669, WindowServer</string>
	</dict>

47907                   ← 约 47KB，python plistlib 可直接解析
```

顺带统计了节点构成：68 个节点里 **24 个带非空 `AppUsage`**，且 `API` 字段取值**只有 `Metal` 一种**：

```text
{'Metal': 31}
节点总数: 68
带非空 AppUsage 的节点数: 24
```

**第四步：确认计数真在增长（不是静态值）**

```bash
ioreg -r -c AGXDeviceUserClient -w 0 | grep -A3 "AGXDeviceUserClient  <class" \
  | grep -B2 "pid 669, WindowServer" | grep "AppUsage"
sleep 3
# 再跑一次
```

真实输出：

```text
# 第一次
"AppUsage" = ({"API"="Metal","lastSubmittedTime"=696895867050708,"accumulatedGPUTime"=91628806701125}, ...)
# 3 秒后
"AppUsage" = ({"API"="Metal","lastSubmittedTime"=696898907909416,"accumulatedGPUTime"=91630075944583}, ...)
```

两个增量互相印证单位是纳秒：

- `lastSubmittedTime` 增 **3,040,858,708**，除以 1e9 ≈ **3.04 s** —— 与真实 sleep 3s 吻合，证明这些字段是纳秒。
- `accumulatedGPUTime` 增 **1,269,243,458** ns ≈ **1.269 s**，占 3.04s 的 **41.7%**。

**第五步：交叉校验设备级口径**

```bash
# 同一时间窗口：设备级 Device Utilization % vs 全部客户端 Δ 合计
```

真实输出：

```text
设备级 Device Utilization %: 54 → 65
全部客户端 ΔGPUTime = 1672903791 ns / 3s = 557.6 ms/s → 折合 50.0 %
```

客户端合计折算 50.0%，设备级窗口两端 54% / 65% —— **同一量级，可作为相对份额使用**。

**第六步：正对照（证明不是噪声）**

参照项目已有的 GPU 烧机工具 `tools/exp_exec_gpu_burn.swift`（同一思路：Metal compute 持续提交），自建一个确知在用 GPU 的进程，看它是否以自己的 pid 出现在表里：

```bash
/tmp/metal_stress 7 &        # 自建：持续提交 Metal compute，7 秒
sleep 1.5
python3 /tmp/gpu_attr.py 2 1
```

真实输出：

```text
metal_stress pid=68624 开始，持续 7.0s
===== 采样窗口 2.0s #1 =====
     pid 进程名                      ΔGPUTime(ns)   GPU ms/s      客户端
   68624 metal_stress               1557423250      778.7        1     ← 榜首，正是它
     669 WindowServer                190467500       95.2        2
   36810 com.apple.WebKit             25319375       12.7        1
-- 本机全部 GPU 客户端合计: 892.2 ms/s (≈设备活跃 89.2%)
metal_stress 结束，提交 5922 个 command buffer
```

**第七步：CoreImage 专项对照（直接回答"CoreImage 占多少"）**

这一步最初出现过假阴性，值得记录（见 §5 陷阱 3）。修正后的正确做法与结果：

```bash
# ci_stress3：显式 CIContext(mtlDevice:)，把真实 pid 写文件后按 pid 查
/tmp/ci_stress3 12 &
REAL=$(cat /tmp/ci_real.pid)
ioreg -r -c AGXDeviceUserClient -w 0 | grep -B4 -A4 "pid $REAL,"
```

真实输出：

```text
+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100114234, ...>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=697379739464958,"accumulatedGPUTime"=675915166})
      "IOUserClientCreator" = "pid 78414, ci_stress3"
      "CommandQueueCount" = 1
    }
```

三窗口读者：

```text
  AppUsage条目=1 合计=689792416 ns
  AppUsage条目=1 合计=1117012875 ns      ← 1.5s 后
  AppUsage条目=1 合计=1438504291 ns      ← 再 1.5s 后
```

**结论：CoreImage 的 GPU 工作会被计入调用进程的 pid**（1.5 秒涨约 320 ms）。所以「CoreImage 占多少」在该数据源下**能回答**，前提是 CoreImage 跑在你的进程里（Aurora 的 UI 进程），而不是被 WindowServer 代劳。

**判定**

- **方法整体：已在本机验证可用。** 判据三条全过：① 计数随时间线性增长且单位可证（纳秒）② 合计与设备级同量级 ③ 自建 Metal/CoreImage 负载都以自己的 pid 精确出现在榜首。
- **已落库脚本：`scripts/gpu-attrib.sh`（`bash -n` 通过，实跑通过）。**

---

### 3.4 `sample` 采 WindowServer：权限被拒，但工具本身是好的

**执行**

```bash
sample 669 2 1 -file /tmp/ws_sample.txt
# 对照：采自己的进程
sleep 6 & SP=$!
sample $SP 2 1 -file /tmp/self_sample.txt
```

真实输出：

```text
$ sample 669 2 1 -file /tmp/ws_sample.txt
sample[66084]: sample cannot examine process 669 (WindowServer) because you do not have appropriate privileges to examine it; try running with `sudo`.
→ /tmp/ws_sample.txt 未生成

$ sample <sleep pid> 2 1 -file /tmp/self_sample.txt
Sampling process 74216 for 2 seconds with 1 millisecond of run time between samples
Sampling completed, processing symbols...
Sample analysis of process 74216 written to file /tmp/self_sample.txt
→ -rw-r--r--  13173  /tmp/self_sample.txt   ← 成功产出 13KB 报告
```

**判定**

- **采 WindowServer：验证不可用**（非 root 下权限拒绝，与工具能力无关）。
- **采自己进程：已在本机验证可用**（同一工具，同一会话）。
- 对你的问题（"能否看出合成路径"）的可行性判断：即使拿到 root 采到 WindowServer 栈，`sample` 给的是**CPU 调用栈采样**，只能看出它此刻在执行哪段合成代码（如 SkyLight / CA 的 `compositor` 相关帧），**给不出 GPU 毫秒数**。要定量仍须走 §3.3 或 §3.2。**这一判断本身未验证**（因为没能采到 WindowServer）。

---

### 3.5 其它方向

#### 3.5.1 `powermetrics --show-process-gpu`

**执行**

```bash
powermetrics -n 1 -i 2000 --show-process-gpu
powermetrics --help | grep -iE "gpu|process"
```

真实输出：

```text
$ powermetrics -n 1 -i 2000 --show-process-gpu
powermetrics must be invoked as the superuser

$ powermetrics --help | grep -iE "gpu|process"
    -r | --order <method>        order process list using specified method [default: composite]
    --show-process-coalition     group processes by coalitions and show per coalition information
    --show-process-gpu           show per-process gpu time
    --show-process-energy        show per-process energy impact number
    ...
    gpu_power         gpu power and frequency info
```

**判定**

- **非 root 运行：验证不可用**（明确要求 superuser；本会话 `sudo -n true` 报 `sudo: a password is required`，无法提权）。
- **root 下 per-process GPU ms/s 恒 0.00：未验证**——这是你已有的实测结论，本次无法复现，本报告只转述不背书。
- **`--show-process-coalition` 是唯一未被你排除过的相邻开关**，它按 coalition 分组而非按 pid。对 Aurora 这种「同二进制 spawn 子进程」的结构，coalition 会把 UI + 引擎归到一组，**反而更难拆分**，因此不推荐作为主路；**未验证**其在本机的输出。

#### 3.5.2 `spindump`

```bash
spindump 669 2 1 -o /tmp/spindump_test.txt
```

```text
spindump must be run as root when sampling the live system
```

**判定：验证不可用。**

#### 3.5.3 `sysdiagnose`

```bash
sysdiagnose -h | head -25
```

```text
sysdiagnose version 3.0
USAGE: sysdiagnose [args] [process_name | pid]
          -f results_directory    Specify the directory where results will be stored.
          ...
```

**判定：未验证。** 它有 `[process_name | pid]` 参数，理论上能定向采集；但一次运行会产出大归档、耗时数分钟，违反「几秒内返回」的探测纪律，**本次未执行**。且它本质是"打包现场日志"，不是低开销实时计量器，不适合做 ABBA 归因。

#### 3.5.4 私有 API `task_gpu_utilisation`：字段存在但恒 0

在 `mach/task_info.h` 里发现 `TASK_POWER_INFO_V2`(26) 的 `gpu_energy_data` 含 `task_gpu_utilisation`。写 Swift 实测：

```swift
// 自建 Metal 压力进程，1.5 秒提交 1621 个 command buffer 后读自己
task_info(task, 26, ...)   // TASK_POWER_INFO_V2
```

真实输出：

```text
Metal 设备: Apple M3
提交 1621 个 command buffer / 1.5s
task_gpu_utilisation: 0 -> 0  Δ=0
task_energy         : 35198737 -> 189957082  Δ=154758345     ← 能量在涨，GPU 字段不动
task_ptime          : 318527 -> 1910402
```

而 `task_for_pid(WindowServer)` 直接失败：

```text
pid=   669 WindowServer       task_for_pid= 5(0=OK) | gpu_util=0 Δ=0 ...
pid= 61760 Finder             task_for_pid= 5(0=OK) | gpu_util=0 Δ=0 ...
```

（`5` = `KERN_FAILURE`，无权限；只有对自己 pid 返回 0。）

**判定：验证不可用。** 该字段在本机内核下**恒填充 0**——用"确知在用 GPU"的进程自测仍为 0，这是干净的否证，不是"进程没用 GPU"。

#### 3.5.5 `proc_pid_rusage` / `rusage_info_v6`

```bash
grep -in "gpu" "$SDK/usr/include/sys/resource.h"
grep -n "rusage" "$SDK/usr/include/libproc.h"
```

```text
124: * the GPU. (deprecated)          ← 只是 PRIO_DARWIN_NONUI 的注释，不是时间字段
（rusage_info_v6 全结构里无任何 gpu 字段；libproc.h 只有 int proc_pid_rusage(...) 声明）
```

`rusage_info_v6` 的字段到 `ri_neural_footprint / ri_reserved[9]` 为止，**没有 GPU 时间**。

**判定：验证不可用（结构体根本没有这个维度）。**

#### 3.5.6 MetricKit `MXGPUMetric.cumulativeGPUTime`

```bash
grep -n "cumulativeGPUTime" "$SDK/System/Library/Frameworks/MetricKit.framework/.../MXGPUMetric.h"
```

```text
 @property (readonly, strong, nonnull) NSMeasurement<NSUnitDuration *> *cumulativeGPUTime;
 @discussion The data here represents the total GPU time an application consumed over the date range of the containing payload.
```

**判定：未验证。** 语义上它只覆盖"本 App 自己"、按上报周期聚合（date range），既拆不到同 App 内模块、也拿不到实时值，**结构上不适合本任务**。

---

## 4. 推荐方案

### 主线（立刻可用）：ioreg `AGXDeviceUserClient` per-pid 归因

```bash
# 一次采集，2 秒窗口 × 3 次取稳健值
bash scripts/gpu-attrib.sh 2 3

# 想看实时设备级对照（另开一个终端同窗口跑）
ioreg -r -c IOAccelerator -w 0 | grep -o '"Device Utilization %"=[0-9]*'
```

**为什么选它**

1. **唯一被三条独立判据同时验证通过的路**（计数真增长 / 与设备级同量级 / 正对照精确命中）。
2. **零权限、零插桩、零副作用**：普通用户即可读，不需要 root、不需要改代码、不需要重启 App。
3. **粒度正好对上你的问题**：Aurora 是「UI 进程 + `--engine` 引擎子进程」（`EngineClient.swift:354` spawn 同二进制），而 YOLOPX 在引擎侧跑（`EngineClient.swift:77`："引擎模式下 UI 不跑 YOLOPX"）。**两个进程 = 两个 pid = 两行归因**，天然把「YOLOPX vs 窗口合成」分开。
4. CoreImage 已验证会计入**调用进程**的 pid（§3.3 第七步），所以 UI 进程的 CoreImage 开销不会丢。

**怎么用它回答 36.4%**

```text
36.4%（设备级活跃驻留）
  ├─ WindowServer 的 ms/s   → 窗口合成（含你 app 的图层被它合成的那部分）
  ├─ AuroraDriveUI(A) 的 ms/s → UI 进程（CoreImage / SwiftUI 渲染）
  ├─ AuroraDriveUI(B) 的 ms/s → 引擎进程（YOLOPX 推理，若走 GPU）
  └─ 其余进程                 → 其它 App
```

注意：设备级百分比是**瞬时值**，脚本里的 `GPU ms/s` 是**窗口均值**，两者只比量级与占比，不要逐点对齐（见 §5 陷阱 1）。

### 副线一（要"进程内模块级"拆分时才需要）：Metal 命令缓冲区时间戳

若最终要在一个进程内区分「YOLOPX 的推理提交」和「CoreImage 的滤镜提交」，公开 API 就有：

```text
MTLCommandBuffer.GPUStartTime / GPUEndTime
  @abstract The host time in seconds that GPU starts executing this command buffer.
  API_AVAILABLE(macos(10.15), ...)
```

（已在 SDK 头文件 `MTLCommandBuffer.h:289,294` 核实存在。）

做法是在你的提交点用 completion handler 累计 `GPUEndTime - GPUStartTime`，按来源（推理 / 滤镜 / 绘制）打标签。**判定：未验证**——需要在项目里插桩，本次按纪律未改代码。

### 副线二（需要合成器视角时）：xctrace `Metal System Trace`

```bash
xcrun xctrace record --template 'Metal System Trace' --all-processes \
        --time-limit 5s --output /tmp/metal.trace --no-prompt
xcrun xctrace export --input /tmp/metal.trace --toc
```

**只在该用的时候用**：它能给到 `ca-client-present-request`（谁提交了 present）、`display-compositor-events-interval`（合成器事件），适合回答"WindowServer 那 197 ms/s 里有多少是在替我的窗口干活"。代价是 **2 秒 43MB**，且导出解析成本高。**"按进程 GPU 毫秒数"这一具体产出仍未验证。**

---

## 5. 口径与坑（都是本次踩到的）

| # | 坑 | 现象 | 应对 |
|---|---|---|---|
| 1 | **设备级 `Device Utilization %` 是瞬时值** | 同一 2 秒窗口内读到 `0% → 21%`、`54% → 65%`、`17% → 33%`，跳变极大 | 只拿来对量级/占比，**不要**和窗口均值逐点比较；要严格对比就取多次采样中位数 |
| 2 | **累计口径 ≠ powermetrics 的"活跃驻留"** | 脚本合计折算可达 89.2%，超过 powermetrics 报的 36.4% | 多个客户端可在 GPU 不同单元并发，**合计理论上可超 100%**。只用来看**相对份额**，绝对值不可直接互换 |
| 3 | **`IOUserClientCreator` 的进程名被内核截断到 16 字符** | 出现 `NotificationCent`、`PhotosReliveWidg`、`DeepSeek Harness`（len=16） | 必须**按 pid 回连 `ps -p <pid> -o comm=`** 取全名（`scripts/gpu-attrib.sh` 已内置） |
| 4 | **客户端节点随进程退出而消失** | 长窗口采样会漏掉中途退出的进程 | 观察 Aurora 时窗口取 2–3 秒；若进程刚退出，其数据会整段消失而非归零 |
| 5 | **同名进程有多个 pid**（Aurora UI + 引擎是同二进制） | 归因表出现两行 `AuroraDriveUI`（实测 8.9 与 0.1 ms/s） | 先 `ps -Ao pid,comm,args \| grep -i aurora` 区分 `--engine`，再对应到表里的 pid |
| 6 | **假阴性：查错了 pid** | 用 shell `$!` 拿到包装进程 pid，查询结果为空，一度误判"CoreImage 不计入" | 让被测程序**自己把 `getpid()` 写文件**，按真实 pid 查（§3.3 第七步就是这么修正的） |
| 7 | **`API` 字段当前只有 `Metal`** | `{'Metal': 31}` | 走 Metal 的（含 Metal 承载的 CoreImage/CoreML-GPU/SceneKit）会计入；走 ANE 或 CPU 的**不会出现**。所以"某模型 0 GPU"要结合 `MLComputePlan` 判断，不能只看这张表 |
| 8 | **`ioreg -l` 输出极大** | 单次可上千行，混入大量无关 `*time*` 键 | 用 `-a` 拿 XML + `plistlib` 精确解析，别用 grep 硬啃文本 |

---

## 6. 明确未验证清单（不要当成结论引用）

| 项 | 为什么没验证 | 若要验证，怎么做 |
|---|---|---|
| `powermetrics` root 下 per-process GPU ms/s 是否仍恒 0 | 本会话 `sudo` 需密码，无法提权 | 有 sudo 权限时：`sudo powermetrics -n 1 -i 2000 --show-process-gpu --show-process-energy` |
| `powermetrics --show-process-coalition` 的输出形态 | 同上（需 root） | 同上换开关；观察 coalition 是否会合并 UI+引擎 |
| xctrace 能否导出**按进程的 GPU 毫秒数** | 只验证到录制成功 + TOC 有 `target-pid` 表，未解析出数值 | `xcrun xctrace export --input X.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-shader-profiler-intervals"]'` 后核对字段 |
| Activity Monitor 是否**逐字节**读同一 ioreg 节点 | 只有符号/字符串同源证据，未反汇编 | `sudo dtrace -n 'fbt::IOServiceOpen:entry { ... }'` 或反汇编 `SMGPUMonitor` |
| `MTLCommandBuffer.GPUStartTime/GPUEndTime` 在本项目的实际可用性 | 需插桩，未改代码 | 在 `YolopxEngine` / `CIContext` 提交点包一层 completion handler 累加 |
| `sample` 采 WindowServer 能否看出合成路径 | 非 root 被拒，未采到 | `sudo sample 669 3 1 -file ws.txt` |
| `sysdiagnose <pid>` 的定向采集内容 | 耗时长且产生大归档，违反本次探测纪律 | 单独立项跑一次，事后删归档 |
| MetricKit `cumulativeGPUTime` 在本机的实际粒度 | 结构性不适合，未跑 | 不推荐投入 |

---

## 7. 交付物

- 本文件：`docs/perf-audit-gpu/8-gpu-attribution.md`
- 脚本：`scripts/gpu-attrib.sh`（新增，`bash -n` 与实跑均通过）
  - 只读、无需 root、默认 2s×3 窗口
  - 已处理：名字截断（ps 回连）、XML 精确解析、进度与合计输出
  - 口径限制已写在脚本头部注释里，避免后人误用
- 探测用临时程序（均在 `/tmp`，非项目文件）：`gpu_probe2.swift`（否证 `task_gpu_utilisation`）、`metal_stress.swift`（正对照）、`ci_stress3.swift`（CoreImage 对照）
