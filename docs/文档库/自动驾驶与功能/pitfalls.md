# 四级 · 踩坑实录

> 开发过程中真实发生过、并已修复的崩溃与隐性故障。每条：现象 → 根因 → 修复。只记录**能对应当前代码**的坑。
> 上级：[开发者文档](DEVELOPER_GUIDE.md) ｜ English: [Pitfalls](../神秘乱七八糟的文档/历史归档/03-英文版/pitfalls.en.md)

> **档案标注（2026-09-19 核对，基线 7b7d2db）**：以下 10 条逐条对过现码仍成立——`pcap_next_ex` 阻塞循环（captureLoop）、`Int64(bitPattern: v &- modulus)`、`guard searchEnd > 190` + `bits()` 全套防护、`pcap_findalldevs` 枚举、CIImage `y = sh - yMax` 镜像裁剪、`com.aurora.bpf-setup` LaunchDaemon、`pcapLog` 写 `/tmp/aurora_pcap.log`（FileHandle seekToEnd）、`MLModel.compileModel`、`run.sh` 固定签名顺序、Xcode 中文路径外置盘（历史环境）。本文件为纯历史记录，正文未改动。

## 1. pcap_loop 回调在 Apple Silicon上 SIGBUS（PAC 崩溃）

- **现象**：App 启动即 SIGBUS，崩溃栈指向 libpcap 内部，随机性出现
- **根因**：`pcap_loop` 的 C 函数指针回调跨调用栈被 libpcap 间接调用。Apple Silicon 的 PAC（Pointer Authentication Codes）对函数指针签名验证，Swift 闭包经 `@convention(c)` 转换的指针跨 PAC 边界时签名失效 → SIGBUS
- **修复**：弃用 `pcap_loop` 回调，改 `pcap_next_ex` 阻塞循环（`captureLoop`）
- **教训**：Apple Silicon 上向 C 库传函数指针回调要三思；轮询式 API 通常更稳

## 2. 无符号下溢 SIGTRAP

- **现象**：pcap 正常运行后随机 SIGTRAP 闪退
- **根因**：UE5 有符号向量解码里 `v -= modulus`，扫描垃圾位解出 `v < modulus` 时 UInt64 下溢——Swift 对无符号下溢默认触发运行时陷阱
- **修复**：`v = v &- modulus`（回绕减法，语义等价补码减法）
- **教训**：位流扫描器在垃圾数据上运行，所有算术都要按「输入可能是任意位模式」防御

## 3. findCandidates Range 溢出 SIGTRAP

- **现象**：接入真实游戏流量后闪退（模拟流量不崩）
- **根因**：扫描窗 `for offset in 190..<searchEnd`，短包时 `payload.count*8-60 < 190`，Swift Range 要求 lowerBound ≤ upperBound → 运行时陷阱
- **修复**：`guard searchEnd > 190` + `bits()` 全套防护（count>63、数组越界、data.count>14 前置检查）
- **教训**：真实流量包长分布与想象不同；Range 字面量是 Swift 最常见隐藏陷阱

## 4. pcap_lookupdev 抓错网卡

- **现象**：pcap 启动成功、循环正常，但永远 0 包
- **根因**：`pcap_lookupdev` 在 macOS 只返回默认路由网卡（en0/WiFi），游戏流量可能走 en8（有线/USB）
- **修复**：改用 `pcap_findalldevs` 枚举全部网卡，跳过 lo0/pdp_ip/utun/awdl/xhc20 桥接等虚拟网卡，逐个 open+compile+setfilter，第一个成功的即工作网卡
- **教训**：「API 返回成功」≠「抓到了你要的流量」；网卡选择必须显式化

## 5. CIImage 裁剪 Y 翻转

- **现象**：速度数字槽位裁剪位置系统性偏移
- **根因**：ScreenCaptureKit/CVImageBuffer 行序与 CGImage 坐标系 y 方向相反，直接按归一化坐标裁剪裁的是镜像区域
- **修复**：CIImage 路径裁剪时显式镜像 `ciRect.y = sh - yMax`；且 CI 裁剪纯 crop 不插值
- **教训**：跨框架（ScreenCaptureKit↔CoreImage）的坐标语义必须逐项对表

## 6. BPF 权限重启即失效

- **现象**：`sudo chmod 666 /dev/bpf*` 后正常，重启后 pcap 又 Permission denied
- **根因**：macOS 每次启动重建 `/dev/bpf*` 设备节点，权限回 root-only
- **修复**：App 内密码弹窗 → osascript 安装 `com.aurora.bpf-setup` LaunchDaemon（RunAtLoad 每次开机自动 chmod 666）——一次输入永久生效
- **教训**：设备节点权限是易失的，任何依赖 /dev 权限的方案都要考虑重启

## 7. SwiftUI App 的 print 不回终端

- **现象**：调试 print 消失，终端和 `log show` 都看不到
- **根因**：裸可执行 SwiftUI App 的 stdout 不回终端；并发线程高频 print 有竞争
- **修复**：`pcapLog` 写文件 `/tmp/aurora_pcap.log`（FileHandle seekToEnd 追加；早期「读全文+append+写回」在 10Hz 下 IO 爆炸且互相覆盖丢行）
- **教训**：SwiftUI App 的调试输出从一开始就该走文件日志

## 8. CoreML 加载 .mlpackage 报 "Compile the model"

- **现象**：`MLModel(contentsOf:)` 对 `.mlpackage` 抛 *"Unable to load model … Compile the model with Xcode or MLModel.compileModel(at:)"*
- **根因**：新版 macOS 的 CoreML 不再隐式编译 `.mlpackage`，必须显式编译
- **修复**：`let compiled = try MLModel.compileModel(at: url)` 先编译，再 `MLModel(contentsOf: compiled)` 加载编译产物
- **教训**：分发 CoreML 模型优先用预编译 `.mlmodelc`；用 `.mlpackage` 就必须走 compileModel

## 9. 二进制签名与 xattr

- **现象**：App SIGKILL「Code Signature Invalid」
- **根因**：`xattr -cr` 删掉代码签名本身；或先签名 `.build` 内产物再 cp（cp 破坏签名）
- **修复**：固定顺序 `swift build → cp 到目标 → codesign 目标文件 → xattr -d com.apple.quarantine`（只删隔离属性）。固化在 `run.sh`
- **教训**：签名操作的对象和顺序是强约束

## 10. 宏插件在中文路径 Xcode 下 malformed

- **现象**：`swift build` 报 *"external macro implementation type 'ObservationMacros.ObservableMacro' could not be found … swift-plugin-server produced malformed response"*
- **根因**：`xcode-select` 指向中文路径外置盘 `/Volumes/项目依赖/Xcode.app`，其 `swift-plugin-server`（`@Observable` 宏实现）在受限环境下响应异常
- **缓解**：编译需要完整权限（宏插件要写临时缓存）；根治需将 Xcode 装到无中文的本地路径
- **教训**：工具链路径含中文/外置盘会在最深处（编译器插件）咬人

## 11. 静态链接 OpenCV 缺 HAL / BLAS 符号（2026-09-27）

- **现象**：SPM 主 target 链接期报一片 undefined symbol，两轮：
  ① `carotene_o4t::*` ② `_cblas_sgemm$NEWLAPACK$ILP64` / `_dgels$NEWLAPACK$ILP64`
- **根因**：`libopencv_core.a` 等静态库不是自包含的。
  ① ARM SIMD HAL 在 `3rdparty/libtegra_hal.a` / `libkleidicv*.a`
  ② LAPACK/BLAS 走 Apple `Accelerate` 框架
- **修复**：`linkerSettings` 补 11 个 `.linkedLibrary` + `.linkedFramework("Accelerate")`
- **教训**：静态库的传递依赖不会自动带出，要按 undefined symbol 逐个补齐

## 12. SPM `-L` 相对路径与符号链接陷阱（2026-09-27）

- **现象**：`ld: library 'opencv_core' not found`，但库文件确实在
- **根因**：两个坑叠加 ——
  ① `-L` 用相对路径时，SwiftPM 在 **link 阶段**按构建产物目录解析，不是按包根
  ② `Vendor/opencv/lib` 曾被做成符号链接，形成嵌套自指
- **修复**：`-L` 一律用**绝对路径**（`#filePath` 推导包根）；静态库必须是**实体文件**
- **教训**：构建系统里的路径基准点（cwd vs 产物目录）必须显式确认，不能猜

## 13. SwiftPM manifest 里没有 Foundation（2026-09-27）

- **现象**：`Package.swift` 里写 `"\(#filePath)".replacingOccurrences(of:...)` 报
  *"value of type 'String' has no member 'replacingOccurrences'"*
- **根因**：manifest 在受限沙盒里编译，**只有标准库，没有 Foundation**
- **修复**：改用纯标准库字符串 API（`lastIndex(of:)` + 切片）推导包根
- **教训**：manifest 是独立执行环境，不能当普通 Swift 源码写

## 14. 池化 CVPixelBuffer 跨步骤持有 → use-after-recycle（2026-09-27）

- **现象**：光流偶发读到"错帧"或崩溃（隐患，未实际触发即被改掉）
- **根因**：`CaptureEngine` 直通缓冲是**池化私有缓冲**，`inferFast` 拷贝完就归还池子，
  下一帧可能拿到同一 IOSurface 被覆写。若把引用存起来留到 tick 后半段再用，就是 use-after-recycle
- **修复**：在**帧消费点同步**完成灰度转换（转成自己的私有缓冲就与池子彻底解耦）
- **教训**：池化缓冲的生命周期只在当前回调内有效，跨步骤传递必须显式拷贝

## 15. 光流延迟随调度优先级剧变（2026-09-27）

- **现象**：同一份光流代码，空载 p95 1.7ms，加背景负载后报 12.96ms「超标」
- **根因**：测的是**主线程默认 QoS**，不是生产的 `.userInteractive`。
  光流延迟高度依赖调度优先级，同优先级硬抢 CPU 会抖到十几毫秒
- **修复**：自检显式 `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)`；
  并如实记录边界（7 路负载 @ UTILITY → 3.7ms ✓；同优先级占死 8 核 → ~9ms ✗）
- **教训**：性能判据必须对齐**生产的调度条件**，否则测出来的数没有意义

## 16. OpenCV 线程数不是越多越快（2026-09-27）

- **现象**：DIS 光流默认（用满 8 核）在 7 路负载下 p95 达 20.9ms；固定 2 线程只要 3.53ms
- **根因**：线程越多，被抢占的方式越杂乱，**尾延迟越差**。空载时 nt=4 最快，
  但生产环境不是空载
- **修复**：`cv::setNumThreads(2)`（`flow_bridge.cpp` 的 `kOpenCVThreads`）
- **教训**：并行度要按**最差工况**选，不是按空载最快选

## 17. 伪诊断比没有诊断更坏（2026-09-27）

- **现象**：用户报「看不到车道线」，而 `--yolopx-selftest` 打印
  `可行驶占比: 0.00%  车道线占比: 0.000%`，看起来像"模型没输出"
- **根因**：**那行数字是字段初值，不是测量结果** —— 自检里
  `engine.infer()` 一次都没被调用过。打印的 `drivableRatio`/`laneRatio`
  从未被赋值
- **后果**：一个**看起来在验证**的检查项，实际什么都没验。
  「掩码到底出不出」在全项目里没有任何证据，排查方向被误导到模型侧
- **修复**：给自检加真实推理（A2 节），用真实游戏画面跑完整链路。
  实测 da=3772 格 / ll=1158 格 —— **模型一直是好的，问题在显示层**
- **教训**：**打印一个未被赋值的字段，等于伪造证据**。自检里的每个数字
  都要能追溯到一次真实调用；加了真实推理后，"降级判定: 否"这类
  状态才第一次有了意义

## 18. 单开关管两件事 = 小的把大的拖死（2026-09-27）

- **现象**：车道线看不见，**连可行驶区也一起看不见**
- **根因**：`isDegraded` 是 da/ll 的**或**关系，却同时控制两层掩码的显示。
  车道线是细目标（前景占比 1.3~2.6%，天然贴近下限），它一塌陷就把
  可行驶区也压暗到 `0.18 × 0.35 = 0.063`（几乎不可见）
- **修复**：拆成 `laneDegraded` / `drivableDegraded` 分别调暗；
  **决策层继续用合并后的 `isDegraded`**（语义不变，不引入新风险）
- **协议设计注意**：新增 bit 时，旧发送方不发该位 → 恒为 0。
  要确认这个默认值落在**安全方向**（这里是"不压暗"= 偏亮，能看见），
  而不是反方向
- **教训**：合并指标适合做**决策门控**（宁可保守），但不适合做**显示分层** ——
  显示要如实表达"哪一部分不可信"，而不是"有任意一部分不可信就全体变暗"

## 19. 内层循环里的除法：40 万次/帧（2026-09-27）

- **现象**：`convertToGray` 实测 1.43ms，远超预期
- **根因**：内层循环逐像素算 `x * srcW / dstW`。而生产路径 640→640 时
  **srcW == dstW，这个除法恒等于 x** —— 纯浪费
- **实测**（M3，640×640，n=40）：
  | 写法 | p50 |
  |---|---|
  | 逐像素除法 | 0.639 ms |
  | 同尺寸直接步进 | **0.040 ms**（快 16 倍） |
  | 预计算列偏移表 | 0.264 ms |
- **修复**：加 `sameSize` 快路径；非同尺寸时列映射提到行循环外预计算
- **教训**：**把"恒定成立"的条件也当变量算**，是缩放类代码最常见的性能坑。
  写通用循环时先问一句：生产路径上这个量真的是变的吗？

## 20. 验证脚本本身可能骗你（2026-09-27）

- **现象**：自写的共享内存往返脚本报「5 项失败，逐格差异 6500」，
  看起来像位打包有严重 bug
- **根因**：该脚本复刻生产读写时**自身写错了**（累加器位序、起始偏移、
  清零行为与生产不一致），不是生产代码问题
- **修复**：改用**单格探针**（放一格看回读到哪）做确定性定位 ——
  9/9 精确命中，证明生产实现逐格无损
- **教训**：验证工具要先自证。**"测试失败"的第一反应应是怀疑测试本身**，
  尤其当失败模式呈现出"格数对但逐格差"这种置换特征时 ——
  真实 bug 通常不会这么整齐。用单点确定性探针比整体比对更快定位

## 21. ★ `drawingGroup()` 用在会动的子树上 = 每帧重建离屏纹理（2026-09-28）

- **现象**：用户报「一开自动驾驶就卡得离谱，卡到逆天，基本不能动」。
  引擎日志显示 `capGap/capWork` 从 11ms 雪崩到 **2081ms**，`tickGap` 到 **17044ms**（17 秒一帧），
  系统 load average 飙到 **171**（8 核机器）。
- **我的错误推理链**：
  1. 用 `CIGaussianBlur` 离线测出光斑 blur 是预览框里最贵的绘制（p50 2.13~4.20ms）；
  2. 推断「栅格化缓存起来就好了」，于是加了 `.drawingGroup()`；
  3. **没有在真实 UI 上验证**就部署了。
- **实际结果：更卡。** `sample` 抓真实堆栈（3 秒 / 1ms 采样）铁证：
  ```
  1402/1402 个主线程样本全在：
    CA::Transaction::commit()
      → CA::Layer::display_if_needed
      → RBLayer displayWithBounds
      → RB::DisplayList::render
      → RenderState::RootTexture::make_texture()   ← 1110 个样本卡在这里
    并出现 RB::DisplayList::FilterStyle<RB::Filter::GaussianBlur>::draw
  ```
- **机理**：`.drawingGroup()` 要求 SwiftUI 把子树渲染进**一张离屏纹理**。
  而外层还有 `.offset` 动画每帧改变位置 → 每次位置变化都让离屏纹理**失效并重建**
  （`make_texture` = 重新分配 + 全量重绘）。
  于是从「一次高斯卷积」变成「离屏合成 + 卷积 + 再合成，且纹理每帧重建」——**净变慢**。
- **修复**：移除 `.drawingGroup()`，回到 `.blur(radius: 60)` 直绘。
  修复后 CPU 从 30.5% 降到 6.9%，上述三个热点归零。
- **教训（两条）**：
  1. **`drawingGroup()` 只适合内容与位置都稳定的子树**。子树里有动画/位移时，
     它正好踩中最不适用的场景，比不加还慢。
  2. **离线微基准不能替代真实 UI 堆栈采样**。CIGaussianBlur 夹具里没有 SwiftUI 的
     离屏合成语义，所以完全测不出这一层，还给了我"有据可依"的错觉。
     改 UI 渲染路径后，**必须**用 `sample <pid> 3` 抓真实堆栈验证。

## 22. ★ "后台线程"不等于"空闲线程"（2026-09-28）

- **现象**：把 1ms 的光流计算从主线程搬到 `captureEngine.onYoloFrame` 回调
  （理由："captureQueue 是后台线程，挪走能省主线程时间"）
- **根因**：`captureQueue` **不是普通后台队列**，它是 SCStream 的采样队列：
  ```swift
  stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)  // CaptureEngine:237
  config.queueDepth = 3                                                          // CaptureEngine:225
  ```
  在这条队列上做同步计算 = 推迟帧消费 → 3 帧缓冲更快填满 → 系统施压 → 帧到达间隔拉长。
  日志里 `capGap` 与 `capWork` **同步**暴涨（301ms → 2081ms）就是这个特征：
  不是"处理慢"，而是"帧来得慢 + 处理路径被自己堵住"。
- **修复**：移回主线程 tick。光流真实成本实测只有 **0.96ms**（p95 1.25ms），
  占 33.33ms 预算的 2.9%，完全不值得为省它冒并发风险。
- **附带教训**：我的「1.7ms」是在**合成块状图**上测的。用真实游戏画面
  （纹理梯度 8.58 vs 合成图 2.51）实测 DIS 反而**更快**（0.96ms）——
  纹理丰富时 DIS 收敛更快。**性能数据必须在真实输入分布上取。**
- **教训**：挪动计算前先确认那条队列**承载什么**。承担实时数据源回调
  （屏幕采集/音频采集/网络收包）的队列上只应做最少的工作。

## 23. `pkill -f` 子串不匹配会静默失败（2026-09-28）

- **现象**：收尾时执行 `pkill -f "AuroraDrive --engine" 2>/dev/null || true`，
  以为停掉了测试引擎，实际**没停**——它又跑了 18 小时
- **根因**：真实命令行是 `./AuroraDriveUI --engine`，
  而模式 `"AuroraDrive --engine"` 里 `AuroraDrive` 后面紧跟空格，
  **不匹配** `AuroraDriveUI`。`2>/dev/null` 又把 pkill 的报错吞了
- **后果**：僵尸引擎持有 `engine.lock`(flock) 与 socket，用户 UI 连上去后
  心跳超时、反复报"引擎失联"，排查方向被完全带偏
- **修复/纪律**：
  1. 杀进程前先 `pgrep -fl` 确认匹配到了谁，**再**执行 kill
  2. 不要用 `2>/dev/null` 吞掉 pkill 的报错——失败必须可见
  3. 用能唯一匹配的模式（如 `pkill -f "AuroraDriveUI"`），或按 PID 精确杀
- **教训**：**"我以为停掉了"是危险的假设**。测试收尾必须有可验证的确认步骤
  （`pgrep` 返回空、socket 文件消失），而不是发个命令就当成功

## 24. ★ 守卫用了协议里不存在的字段 → 引擎模式下掩码全部不画（2026-09-28）

- **现象**：用户报「看不到可行驶区域和车道线，只能看到检测框」。
  引擎日志明确显示掩码是好的：`det=3 da=3353格 ll=900格 降级=false`，
  且 `maskSeq` 在驾驶时正常递增（0→9→14）——**引擎侧一切正常**。
- **根因（我的 bug）**：两处代码对撞。
  ```swift
  // EngineClient.swift —— 引擎模式重建 metrics
  engineMaskMetrics = LetterboxMetrics(ratio: ratio, padX: padX, padY: padY,
                                       padBottom: 0, newW: 0, newH: 0,   // ← 硬填 0
                                       srcW: srcW, srcH: srcH)

  // AuroraDriveApp.swift —— MaskOverlay 绘制守卫
  guard active, metrics.newW > 0, metrics.srcW > 0 else { return }        // ← 恒假
  ```
  **共享内存协议头从来没传输 `newW`/`newH`**（EngineMain 只写
  ratio/padX/padY/srcW/srcH），所以客户端只能硬填 0 → 守卫恒假 → 每帧直接 return。
- **为什么本地自检测不出来**：本地模式走 `yolopxEngine.metrics`，那是模型真实产出的
  `LetterboxMetrics`，`newW` 是真实值（640×416）→ 守卫通过。
  **这个 bug 只在引擎模式暴露**。自检 46/46、7/7、15/15 全绿，却完全掩盖了它。
- **决定性证据**：复刻 `MaskOverlay` 的绘制数学做离线验证，三种配置
  （本地 / 引擎修复前 / 引擎修复后）产出的几何**完全一致**：
  ```
  可行驶区矩形数 = 99      车道线矩形数 = 176
  可行驶区 bbox = (67,194) 1073x743   占视口 98.4%
  车道线   bbox = (67,269) 1073x668   占视口 88.5%
  ```
  唯一差别是守卫：修复前 `✗ 失败`，修复后 `✓ 通过`。
  **这证明 `newW` 对绘制数学毫无作用**——它纯粹是个错误的判据。
- **修复（两步都做）**：
  ① 把 `newW`/`newH` 真正写进协议（offset 128/132，位于原本空闲的头部区，
     headerSize=4096 仅用到 125 字节，不移动任何既有字段 → 向后兼容）；
  ② 同时去掉 `MaskOverlay` 里对 `newW` 的守卫依赖，只保留真正被用到的 `srcW > 0`。
  **② 是必须的**：只做①的话旧引擎客户端仍会被卡住。
- **教训（三条）**：
  1. **守卫条件必须用"真正参与计算的量"。** `newW` 在整个绘制数学里只出现在守卫那一行
     （`grep 'metrics\.' MaskOverlay` 可直接验证）。拿一个不参与计算的量当"能不能画"
     的判据，一旦它对不上就是全盲。
  2. **发送方与接收方字段集必须对齐核查。** 我在协议里发 5 个几何字段，
     收端却按 7 个去用。写跨进程协议时，应当**逐字段对照**发送/接收两侧。
  3. **自检全绿 ≠ 功能正常。** 46 项自检覆盖的是模型与算法层，而这是
     "传输层几何字段缺失 + 显示层守卫耦合"的复合 bug，两层各自的单测都测不到。
     **必须补一条端到端的掩码可见性验证**（见下方「待办」节）。

---

## 25. ⚠️ 【待修】`LaneFallback` 仍有 §24 同形的守卫依赖（2026-09-29 复核发现）

- **现象**：§24 修复了 `MaskOverlay` 对协议不存在字段 `newW` 的守卫依赖，
  但**同类写法在另一处仍然存在**——`LaneFallback.swift:170`：
  ```swift
  guard ... ,
        metrics.newW > 0, metrics.newH > 0 else {
      reset()
      return nil
  }
  ```
- **为何目前没复发**：§24 的修复②已把 `newW`/`newH` **真正写进协议**（offset 128/132），
  所以引擎模式下这两个值现在是真实的（640×416）。**症状因此不出现**。
- **为何仍是隐患**：这正是 §24 的教训 1 所说的模式——**守卫条件用了"不参与计算"的量**。
  - 若将来某个引擎版本/candidate 回退路径不写这两格 → `newW=0` → `LaneFallback`
    **静默失效**（`reset()` + `return nil`，无日志、无告警）
  - 且它**不在 `MaskOverlay` 路径上**，所以即使复现，用户看到的也只是"车道线兜底不生效"，
    很难与显示层问题区分
- **修复建议**（待用户确认后执行，本轮**不动代码**）：
  1. 优先方案：与 §24 一致——**只保留真正参与计算的守卫**。`LaneFallback` 的后续计算
     （`scale = inputSize / laneMask.width`）用的是 `laneMask.width`，**不是 `newW`**，
     故 `newW`/`newH` 大概率可直接从守卫里去掉
  2. 兜底方案：保留守卫但在 `else` 分支里**加一次日志**（让静默失效变成可观测）
- **教训**：修一处「守卫耦合」bug 时，**必须 `grep` 全仓同类写法**，
  而不是只修报警的那一处。§24 修复时若做过这一步，本条本可一并发现。

---

## 26. ⚠️ 【待修】`/tmp/aurora_pcap.log` 只追加、无轮转（2026-09-29 实测确认）

- **现状**（`CoordinateCapture.swift:507-518` `pcapLog`）：
  ```swift
  let path = "/tmp/aurora_pcap.log"          // ← 固定路径
  if let handle = try? FileHandle(forWritingTo: url) {
      try? handle.seekToEnd()                 // ← 永久追加
      handle.write(Data(line.utf8))
  ```
  **全仓 `grep -i "rotate|truncate|removeItem"` 对日志路径 0 命中**——**没有任何轮转/上限逻辑**。
- **实测影响**：当前 `/tmp/aurora_pcap.log` 已是 **654 KB**（最后写入 09-29 13:23）。
  按 `COMM_AUDIT_2026-09-12.md` 的估算**约 51 MB/天**（持续驾驶场景）。
  `/tmp` 在 macOS 上由系统按需清理，但**长时间连续运行时不受控**。
- **为何危险**：
  1. **该文件属主是 `root:wheel`**（实测 `-rw-r--r-- 1 root wheel`）——
     因为抓包进程需 root 权限，日志也随之由 root 创建。
     普通用户进程**无法删除/截断**它，只能读。清理需 `sudo`。
  2. 文件句柄**每写一行开关一次**（`FileHandle` → `close`），
     这本身是性能设计问题（高频路径上反复 open/close），但**避免了口资源泄漏**——
     两害相权，属已知取舍。
  3. 无轮转 + root 属主 = **磁盘告警时用户无法自助处理**。
- **修复建议**（待用户确认，本轮**不动代码**）：
  1. 加一次性初始化截断（进程启动时 truncate 到 0），或
  2. 改为按大小轮转（如 >10MB 时重命名并保留 1 份），或
  3. 至少降低日志级别（`[STATS]` 行改为每 60s 一条而非每窗口一条）
- **历史**：`COMM_AUDIT_2026-09-12.md` **已报告过**此问题，至今未修——
  属「报告了但没排上」的待办，非遗漏。

---

## 27. ★ 注释声称"已移植"、实际只移植了外壳 —— `dodge` 技能（2026-09-29 复核发现）

> **这一类坑比"没写注释"更危险**：注释给了**虚假的完成感**，
> 让人以为功能已对齐，从而**不再去核实**。

### 现状

`AIAgentPanel.swift:1328` 的注释写着：

```swift
/// 自动闪避（MaaNTE SoundDodge 思路移植）
/// 真实链路：周期性快速闪避（空格跳跃 + Shift 疾跑闪避组合），
/// 用于躲红圈/追踪弹；可中途停止。
private func performDodgeLoop(...) {
```

但**实现只是固定周期的盲按键**（`:1355-1360`）：

```swift
for round in 1...maxRounds {
    control.pressGameKey(.space, duration: 0.12)   // 固定按空格
    control.pressGameKey(.shift, duration: 0.10)   // 固定按 Shift
    usleep(0.9 * 1_000_000)                        // 固定睡 0.9 秒
}
```

**「SoundDodge」的核心是音频识别，而这里一个字都没用到声音。**

### MaaNTE 的真实实现（`MaaNTE/agent/custom/action/SoundTrigger/`，571 行）

| 文件 | 行数 | 作用 |
|---|---|---|
| `SoundListener.py` | 215 | **音频监听 + 指纹匹配**（核心） |
| `SoundDodgeAction.py` | 250 | 闪避/反击动作编排 |
| `DodgeCounterTrigger.py` | 95 | 反击触发 |

**`SoundListener` 的关键参数**（源码实测）：

| 参数 | 值 | 含义 |
|---|---|---|
| `sr` | 32000 | 采样率 |
| `chunk` / `sample_len` / `interval` | 1600 / 0.2 s / **0.05 s** | 每 50 ms 处理一个 200 ms 窗口 |
| `degree` / `cut_off` | 4 阶 / **1000 Hz** | **巴特沃斯高通滤波**（滤掉低频 BGM，保留攻击音效） |
| `threshold` / `counter_threshold` | **0.13** / **0.12** | 闪避音效 / 反击音效的匹配阈值 |
| `_trigger_cd` | 0.5 s | 触发冷却 |

**流程**：`soundcard` 采集系统音频 → 高通滤波 → 与预存音效（`dodge.wav` / `counter.wav`）
做**指纹互相关** → 超阈值即触发。

### 行为差距

| 维度 | MaaNTE | AuroraDrive |
|---|---|---|
| 触发依据 | **听到攻击音效** | ❌ 固定周期，与游戏状态无关 |
| 反击 | ✅ 有 | ❌ 无 |
| 副作用 | 精确、省操作 | ⚠️ **无攻击时也在闪**（浪费 + 可能误触跳跃/疾跑） |

**✅ 实测确认 AuroraDrive 无任何音频识别能力**：
`grep "soundcard|librosa|AVAudioEngine|CoreAudio|SoundListener" Sources/` → **零命中**。

> ⚠️ **一处易混淆**：`GameModeDefender.swift` 确实 `import AudioToolbox`，
> 但那是**播放静音音频**（AudioQueue 2×11025 帧零采样循环）以**让 CoreAudio
> 实时线程保持活跃**（防游戏被系统降频），**与音频识别完全无关**。

### 教训（可推广）

1. **注释里的"移植"要分级**：是「**行为等价移植**」还是「**思路借用**」？
   本处注释写"思路移植"，但实际连"思路"都没借到——**只借了个名字**。
2. **跨语言移植时最容易丢的就是"触发源"**：
   MaaNTE 是 Python（有 librosa/scipy 生态），移植到 Swift 时
   **音频处理链被整个砍掉**，只留下按键动作——**而按键动作才是外壳**。
3. **复核移植完整度的方法**：对照**输入→决策→输出**三段，
   逐段确认。本处 **输入段（音频）完全缺失**，只保留了**输出段（按键）**。

### 建议（待用户确认，本轮不动代码）

| 选项 | 说明 |
|---|---|
| **A. 只修注释**（最低成本） | 把"思路移植"改为"**仅动作层，未含音频识别**" |
| **B. 补齐音频识别** | macOS 可用 **ScreenCaptureKit 系统音频采集**（复用现有屏幕捕获权限），
算法用 **Accelerate/vDSP** 做高通 + 互相关，**无需引入 librosa/scipy**；音效样本可直接复用 `MaaNTE/assets/resource/base/sounds/` |
| C. 保持现状 | 但**至少要在技能说明里标注"盲闪避"**，避免用户误以为它能自动响应攻击 |

**推荐 A（立刻做）+ B（排期）**——A 消除误导，B 是真正的能力补齐。

---

## 28. 断头吸附不迭代 = 假修（距离≈0 却没连上）（2026-10-06）

- **现象**：路网修复第一版只跑**一轮**断头吸附，修完仍有 **26 个断头**距离最近路 ≈0px 却始终没连上——「修了等于没修」
- **根因**：吸附的实现是**在目标边上切开并插入新节点**（`mode="split"`）。而 split 插进来的新节点，在新图里自己就是**度=1**——它又成了新的断头。单轮算法处理完这批新断头时就收工了
- **修复**：改成**迭代到收敛**——每轮重建度表，无断头或一轮 0 吸附才 break，最多 10 轮（`tools/roadnet/fix_roadnet.py:143-153`，注释 `:143-145` 明写「必须迭代到收敛……原实现只跑一轮，导致 26 个残留断头」）。实测吸附 80 处、迭代收敛后 0 残留（`models/route_graph_fixed_diag.json`：`adsorbed=80`）
- **教训**：「修复动作会制造新的待修对象」时，单遍算法必然留尾巴；凡是 split/insert 类操作，都要问一句**新产物本身满足不满足收敛条件**

## 29. `difflib` 的 `ratio()` 不是 LCS —— 它是 Ratcliff-Obershelp 递归累加（2026-10-06）

- **现象**：把 `difflib.SequenceMatcher.ratio()` 按「最长公共子序列 × 2 / 总长」移植到 Swift（只算**单个**最长匹配块），与 Python 原版比对 **348 对文本错 226 对，最大偏差 0.476**
- **根因**：`ratio()` = `2*M / T`，但 M 不是 LCS——是 **Ratcliff-Obershelp**：找到最长匹配块后在**左右剩余区间递归**继续找、把各块长度**累加**。两者经常相等，但不是恒等：最小反例 `aba` vs `bca`，LCS=2 而递归累加只算到中间的 `b`（M=1）——本小姐实测暴力搜索确认。另注意它自带 `autojunk` 启发式（长串中出现率 >1% 的元素可能被当垃圾位剔除）
- **修复**：Swift 侧按 Ratcliff-Obershelp 逐位重实现 `sequenceRatio`（`Sources/AuroraDrive/Inference/QuestPanelReader.swift:47-52` 坑 1 注释），修后与 Python 全量对拍零偏差
- **教训**：**「两个指标大部分时候相等」是最阴的移植坑**——小样测试全绿、真实数据翻车。跨语言移植相似度函数必须拿**全量数据对拍**，不能拿几个例子过一下就算

## 30. CRLF 让 Swift `Character`（字素簇）与 Python `len()` 错位（2026-10-06）

- **现象**：quest 索引里有 4 条 key 含 `\r\n`（如「前往赤龙古堡\r\n（小队成员…）」）。Swift 按 `Character` 数长度时与 Python `len()` 对不上 → 长度比、切片、长度守卫全部错位，匹配行为悄悄偏离
- **根因**：Python `len()` 按 **Unicode 码点**（scalar）计数；Swift 的 `Character` 按**字素簇**计数——`\r\n` 在 Swift 是 **1 个** Character，Python 算 **2 个**。合成字符（组合符号/emoji）同理
- **修复**：`QuestPanelReader` 全程用 `Unicode.Scalar` 计数与切片，不用 `Character`（`Sources/AuroraDrive/Inference/QuestPanelReader.swift:54-60` 坑 2 注释、`:275-284` clean/string 原语、`:329/:340/:719` 等全部 `unicodeScalars.count`）；修后 5157 对向量零偏差
- **教训**：跨语言对齐字符串长度时，比较基准必须钉死在**码点**层面；含 `\r\n`/组合字符的数据会让字素簇计数静默错位

## 31. Vision `.fast` 读中文全错——不是慢一点，是完全不可用（2026-10-06）

- **现象**：任务面板 OCR 用 `.fast` 档实测 4 条中文读出 **0/4 全错**；换 `.accurate` 后 **4/4 全对**
- **实测数字**（ROI 1088×135，2940×1912 全屏，暖机后 n=120，`QuestPanelReader.swift:519-527` 注释）：`.accurate` p50 33.6ms / p95 40.7ms；`.fast` p50 4.2ms / p95 7.2ms——快 8 倍但**全错**
- **根因**：Vision 的 fast 档对中文 UI 小字的识别率趋近于零，不是「速度换精度」的连续权衡
- **修复**：中文识别**只能** `.accurate`（`LoginAssistant.swift:48`、`QuestPanelReader.swift:650`）；33.6ms ≈ 一整个 30Hz 帧预算，故 ROI 裁剪留主线程、Vision 丢专用后台队列 + `ocrInFlight` 防重入
- **教训**：识别档位要先在**真实目标数据**上验证「能不能用」，再谈「多快」；快 8 倍的档位错 100% 等于零

## 32. 构建静默不重编译 —— SwiftPM 缓存让代码改动不生效（2026-10-06）

- **现象**：改了 Swift 源码，跑构建后行为没变——编译「成功」但产物还是旧的
- **根因**：SwiftPM 的增量缓存按 **mtime** 判断要不要重编，工作区快照/git 操作会让 mtime 不可靠，缓存命中时**静默跳过重编译**，不报任何错
- **修复**：`run.sh` 构建前固定 `rm -rf .build` 全量重编译（`run.sh:76-77`，注释「必须先清缓存! SwiftPM 缓存会导致代码改动不生效」）；`--disable-sandbox` 下 scratch 统一放 `.build/scratch` 与增量构建共用缓存（`run.sh:84`）
- **教训**：**「构建成功」≠「重编译了」**。排查「改了没生效」类问题时，第一步先确认产物 mtime 晚于源码 mtime；长期解是构建入口强制清缓存

## 33. `--wire-selftest` 必须带 `AURORA_UI_LOCAL=1`（2026-10-06）

- **现象**：直接跑 `./AuroraDriveUI --wire-selftest` 行为不对——自检语义建立在「本地模式、必然没连引擎」的前提上
- **根因**：该自检的用例（如「未连接时发送 → 期望按未连接语义处理」「`AURORA_UI_LOCAL=1` → `wantsEngineMode=false` 不启动重连轮询」）**只在前置条件成立时才有确定结果**；不带环境变量时 UI 会尝试连引擎，前提被破坏
- **修复**：固定用法 `AURORA_UI_LOCAL=1 ./AuroraDriveUI --wire-selftest`（`Sources/AuroraDrive/Core/WireSelfTest.swift:36` 文件头用法、`:65/:99-101` 两个用例的显式前提注释；flag 注册见 `AuroraDriveApp.swift:945`）
- **教训**：依赖环境前置条件的自检入口，要把**完整调用命令**写进文件头；裸 flag 能跑不等于跑的是设计里的那个实验

---

## 📋 待办（2026-09-29 补登 / 修复文档内部断链）

> ⚠️ **本节为 2026-09-29 补写**。第 24 条末句原文写「见文档末尾的待办」，
> 但**原文并无此节**（内部断链）。此处按第 24 条的实际诉求补登，内容忠实于原文语境。

| # | 待办项 | 来源 | 优先级 |
|---|---|---|---|
| 1 | **补一条端到端掩码可见性验证**——覆盖「传输层几何字段缺失 + 显示层守卫耦合」这类复合 bug。现有 46 项自检只覆盖模型与算法层，两层各自的单测都测不到此类问题 | §24 教训 3 | **高** |
| **1b** | **【2026-09-29 新增】修 `LaneFallback.swift:170` 的 `newW`/`newH` 守卫依赖**——§24 同形隐患（见 §25），当前因协议已补传该字段而暂不复发 | §25 | **高** |
| **1c** | **【2026-09-29 新增】全仓 `grep 'metrics\\.newW'` / `metrics\\.newH`**，确认不存在第三处同类守卫 | §25 教训 | 中 |
| **1d** | **【2026-09-29 新增】`/tmp/aurora_pcap.log` 加轮转/上限**——现为纯追加、root 属主、~51MB/天，见 §26。09-12 已报告未修 | §26 | **高（运维）** |
| 2 | 跨进程协议**逐字段对照核查**机制——发送侧 5 个几何字段 vs 接收侧 7 个的错配应当被自动发现 | §24 教训 2 | 中 |
| 3 | `isDegraded` 单开关拆分（da/ll 独立标志）已完成代码侧修复（bit2/bit3），**需补显示层的回归验证** | §18 + §24 | 中 |
| 4 | 掩码阈值「未覆盖区间」（ll 10.7%~25%、da 38.1%~70%）待有真实 seg 头崩塌素材后按分位数重标 | `YolopxEngine.swift:237-246` | 精度线 |
| **5** | **【2026-09-29 新增】修 `AIAgentPanel.swift:1328` 的误导注释**——"MaaNTE SoundDodge 思路移植"应改为"仅动作层，未含音频识别"（见 §27） | §27 | **高（成本极低）** |
| **5b** | **【2026-09-29 新增】评估补齐音频闪避**——ScreenCaptureKit 系统音频 + vDSP 高通/互相关，可复用 MaaNTE 的 `dodge.wav`/`counter.wav`（见 §27 选项 B） | §27 | 中（功能增强） |

**相关交叉引用**：
- §24 的根因与修复 → `代码-07`「9-28 血泪史」节
- §18 的 flags 位定义 → `代码-06`「掩码 flags 位定义」节
- 阈值双向判据 → `04-vision-inference` §4.8.1
- §27 的完整实现对照 → `.dsh-workspace-notes/笔记-00-工作区总览与过期清单.md` 第十七节
