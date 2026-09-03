# 四级 · 踩坑实录

> 开发过程中真实发生过、并已修复的崩溃与隐性故障。每条：现象 → 根因 → 修复。只记录**能对应当前代码**的坑。
> 上级：[开发者文档](../DEVELOPER_GUIDE.md) ｜ English: [Pitfalls](en/pitfalls.en.md)

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
