// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later
// 网络定位自愈引擎：诊断+修复+回退+恢复

import Foundation
import Darwin

/// 定位模式
enum LocatorMode: String {
    case network = "pcap"       // 网络定位（主力）
    case visual = "visual"      // 视觉定位（临时顶班）
    case failed = "failed"      // 两个都挂了
}

/// 自愈状态
enum HealState {
    case healthy                // 网络正常
    case degraded               // 网络挂了，视觉顶着
    case diagnosing             // 正在诊断原因
    case repairing              // 正在修复
    case healed                 // 修复成功，切回网络
}

/// 诊断结果
enum Diagnosis {
    case interfaceDown          // 网卡挂了
    case gameNotRunning          // 游戏没跑
    case bpfDeviceBusy          // BPF设备被占
    case portChanged             // 端口30031变了
    case permissionLost          // root权限丢了
    case unknownButDead          // 一切正常但读不到包
}

/// 网络定位自愈引擎
/// pcap失败 → 切视觉 → 后台诊断 → 修复 → 切回网络
final class NetworkHealer {
    
    // ── 依赖 ──
    private let capture: CoordinateCapture
    private var visualLocator: VisualLocator?
    private let mapPath: String
    
    // ── 状态 ──
    private(set) var mode: LocatorMode = .network
    private(set) var healState: HealState = .healthy
    private(set) var lastDiagnosis: Diagnosis?
    private(set) var lastError: String = ""
    private(set) var repairAttempts: Int = 0
    private(set) var lastHealTime: Date?
    
    // ── 定时器 ──
    private var healTimer: DispatchSourceTimer?
    private let healQueue = DispatchQueue(label: "com.aurora.healer", qos: .utility)
    private let healInterval: TimeInterval = 5.0  // 5秒诊断一次
    private let maxRepairAttempts = 3  // 连续3次修复失败才放弃
    
    // ── 回调 ──
    var onModeChange: ((LocatorMode) -> Void)?
    var onDiagnosis: ((Diagnosis, String) -> Void)?
    
    init(capture: CoordinateCapture, mapPath: String) {
        self.capture = capture
        self.mapPath = mapPath
    }
    
    // MARK: - 启动自愈监控
    
    func start() {
        guard healTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: healQueue)
        timer.schedule(deadline: .now(), repeating: healInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.healthCheck()
        }
        timer.resume()
        healTimer = timer
        print("[Healer] 自愈引擎已启动（每\(Int(healInterval))秒检查一次）")
    }
    
    func stop() {
        healTimer?.cancel()
        healTimer = nil
        visualLocator?.cleanup()
        visualLocator = nil
        print("[Healer] 自愈引擎已停止")
    }
    
    // MARK: - 健康检查
    
    private func healthCheck() {
        // 检查网络定位是否还活着
        if mode == .network {
            // 主力模式：检查pcap是否还在读包
            if let pose = capture.read(maxAge: 3.0) {
                // 网络正常，有最新数据
                _ = pose
                healState = .healthy
                return
            }
            // 网络定位读不到包了！开始降级
            print("[Healer] ⚠️ 网络定位无数据，降级到视觉定位")
            switchToVisual(reason: "网络定位超时无数据")
            return
        }
        
        if mode == .visual {
            // 降级模式：尝试诊断+修复网络
            if repairAttempts >= maxRepairAttempts {
                // 达到最大修复次数，但继续每5秒试一次（不放弃）
                repairAttempts = 0  // 重置，继续尝试
            }
            healState = .diagnosing
            let diag = diagnose()
            lastDiagnosis = diag
            healState = .repairing
            let repaired = attemptRepair(diag)
            if repaired {
                print("[Healer] ✅ 网络定位修复成功，切回主力")
                switchToNetwork()
            } else {
                repairAttempts += 1
                print("[Healer] 修复失败(第\(repairAttempts)次)，保持视觉定位，5秒后重试")
            }
        }
    }
    
    // MARK: - 诊断
    
    private func diagnose() -> Diagnosis {
        // 检查1: 是否有root权限
        if getuid() != 0 {
            print("[Healer] 诊断: 权限丢失（不是root）")
            return .permissionLost
        }
        
        // 检查2: 网卡还在吗
        var errbuf = [CChar](repeating: 0, count: 256)
        if let dev = pcap_lookupdev(&errbuf) {
            let devName = String(cString: dev)
            // 尝试打开看看
            let testHandle = pcap_open_live(devName, 65535, 0, 1, &errbuf)
            if testHandle == nil {
                let err = String(cString: errbuf)
                if err.contains("SIOCIFCREATE") || err.contains("Permission") {
                    print("[Healer] 诊断: BPF设备权限不足 - \(err)")
                    return .permissionLost
                }
                if err.contains("No such") || err.contains("not found") {
                    print("[Healer] 诊断: 网卡消失 - \(err)")
                    return .interfaceDown
                }
                print("[Healer] 诊断: BPF设备被占 - \(err)")
                return .bpfDeviceBusy
            }
            // 网卡能打开，关闭测试句柄
            if let testHandle = testHandle { pcap_close(testHandle) }
            
            // 检查3: 游戏还在跑吗（检查30031端口有没有流量）
            // 简单检查：看有没有进程在用30031端口
            let netstatResult = runShellCommand("lsof -i :30031 2>/dev/null | wc -l")
            if let count = Int(netstatResult.trimmingCharacters(in: .whitespaces)), count <= 1 {
                print("[Healer] 诊断: 端口30031无进程使用，游戏可能没跑")
                return .gameNotRunning
            }
            
            // 检查4: 一切正常但读不到包
            print("[Healer] 诊断: 系统正常但pcap无数据，可能游戏网络变了")
            return .unknownButDead
        }
        
        print("[Healer] 诊断: 无法找到网卡")
        return .interfaceDown
    }
    
    // MARK: - 修复策略
    
    private func attemptRepair(_ diag: Diagnosis) -> Bool {
        switch diag {
        case .permissionLost:
            // 重新弹sudo密码（通过osascript）
            print("[Healer] 修复: 重新请求管理员权限...")
            let result = runShellCommand("osascript -e 'do shell script \"echo ok\" with administrator privileges' 2>&1")
            if result.contains("ok") {
                print("[Healer] 权限恢复，重启pcap")
                return restartCapture()
            }
            print("[Healer] 权限恢复失败")
            return false
            
        case .interfaceDown:
            // 尝试重启网卡
            print("[Healer] 修复: 尝试重启网络服务...")
            _ = runShellCommand("osascript -e 'do shell script \"networksetup -setairportpower en0 on\" with administrator privileges' 2>&1")
            Thread.sleep(forTimeInterval: 2)
            return restartCapture()
            
        case .gameNotRunning:
            // 游戏没跑，等它跑起来
            print("[Healer] 修复: 等待游戏启动...")
            Thread.sleep(forTimeInterval: 2)
            return restartCapture()
            
        case .bpfDeviceBusy:
            // BPF设备被占，先关旧句柄再重开
            print("[Healer] 修复: 关闭旧BPF句柄，重新打开...")
            capture.close()
            Thread.sleep(forTimeInterval: 1)
            return restartCapture()
            
        case .portChanged:
            // 端口变了，扫描新端口
            print("[Healer] 修复: 扫描游戏新端口...")
            // TODO: 扫描所有TCP端口找UE5流量
            return restartCapture()
            
        case .unknownButDead:
            // 万能修复：关掉重来
            print("[Healer] 修复: 重启pcap抓包...")
            capture.close()
            Thread.sleep(forTimeInterval: 1)
            return restartCapture()
        }
    }
    
    // MARK: - 模式切换
    
    private func switchToVisual(reason: String) {
        mode = .visual
        healState = .degraded
        lastError = reason
        print("[Healer] 切换到视觉定位: \(reason)")
        
        // 初始化VisualLocator（懒加载）
        if visualLocator == nil {
            let vl = VisualLocator(mapPath: mapPath)
            let err = vl.prepare()
            if err == nil {
                visualLocator = vl
                print("[Healer] VisualLocator已初始化")
            } else {
                print("[Healer] VisualLocator初始化失败: \(err ?? "")")
                mode = .failed
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onModeChange?(.visual)
            if let diag = self?.lastDiagnosis {
                self?.onDiagnosis?(diag, reason)
            }
        }
    }
    
    private func switchToNetwork() {
        mode = .network
        healState = .healed
        lastHealTime = Date()
        repairAttempts = 0
        print("[Healer] 切回网络定位 ✓")
        
        DispatchQueue.main.async { [weak self] in
            self?.onModeChange?(.network)
        }
    }
    
    // MARK: - 重启pcap
    
    private func restartCapture() -> Bool {
        capture.close()
        Thread.sleep(forTimeInterval: 0.5)
        let ok = capture.start()
        if ok {
            // 验证：等2秒看能不能读到包
            Thread.sleep(forTimeInterval: 2)
            if capture.read(maxAge: 3.0) != nil {
                return true
            }
            print("[Healer] pcap重启了但读不到包")
            return false
        }
        return false
    }
    
    // MARK: - 获取当前定位结果
    
    /// 返回当前最佳定位（网络优先，视觉备用）
    func currentLocation() -> (mapX: Double, mapY: Double, heading: Double, mode: LocatorMode)? {
        if mode == .network {
            if let pose = capture.read(maxAge: 1.0) {
                let (x, y, h) = worldToMapPixel(pose)
                return (x, y, h, .network)
            }
        }
        if mode == .visual || mode == .network {
            // 视觉定位需要截图，这里返回nil由DriveState处理
            return nil
        }
        return nil
    }
    
    // MARK: - 工具
    
    private func runShellCommand(_ cmd: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
    
    deinit { stop() }
}
