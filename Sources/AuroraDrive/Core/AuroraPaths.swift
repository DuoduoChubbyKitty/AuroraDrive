// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later
// 项目根定位：源码重组进 Sources/AuroraDrive/Core/ 后，#filePath 不再指向项目根。
// 本文件提供统一的多候选根目录解析，供 models/data/recordings 等资源定位使用。

import Foundation

enum AuroraPaths {

    // ========================================================================
    //  P-3（2026-10-04）：`cachedRoot` 从「无同步的 static var」改为 `static let`
    // ========================================================================
    //
    // 【改前】
    //     nonisolated(unsafe) static var cachedRoot: URL?
    //     static func projectRoot() -> URL {
    //         if let cached = cachedRoot { return cached }
    //         ... 探测 ...
    //         cachedRoot = c; return c
    //     }
    //
    // 【它错在哪】
    //   ① **数据竞争**：`projectRoot()` 会被**多个线程**调用 —— 主线程（UI/模型加载）
    //      与后台队列（`SpeedOCRReader.loadModelsOnBackground`、推理队列）都会调。
    //      两个线程同时看到 `cachedRoot == nil` → **各探测一遍**（最多 8 次 stat），
    //      然后各自写回。写回本身是良性的（结果相同），但这是**未定义行为**：
    //      Swift 不保证 `URL?` 的并发读写不撕裂。
    //   ② `nonisolated(unsafe)` 这个标注本身就是"我知道有竞争、但先绕过检查" ——
    //      它把风险从编译器转移到了读者身上。**这不是工程化写法。**
    //
    // 【改后】`static let` + 惰性求值
    //   Swift 的 `static let` 由 `swift_once` 保证：**线程安全 + 全生命周期只求值一次**。
    //   首访时算一次（探测 4 个候选），之后每次调用只是一次内存读 ——
    //   比原来"读 var + 判 nil"还快，且**零锁成本**（不需要 NSLock / once 手写）。
    //
    // 【语义等价性】原来的缓存**本来就是"算一次就固定"**（没有任何失效路径），
    //   所以 `static let` 与"首次写入后不再变"的 var 语义完全一致。
    //   唯一差别：改前若首访并发，可能探测两次；改后严格一次。**更严格，不是更松**。

    /// 解析结果缓存。`static let` → `swift_once` 保证线程安全且只求值一次。
    private static let cachedRoot: URL = resolveRoot()

    /// 定位项目根目录。按优先级尝试多个候选，取第一个能验证的（含 Package.swift 或 models/）。
    ///
    /// 调用方无需关心缓存 —— 本函数每次都是一次内存读（见 `cachedRoot` 的说明）。
    static func projectRoot() -> URL { cachedRoot }

    /// 真正做探测的那一次（**全进程只跑一次**）。
    private static func resolveRoot() -> URL {
        var candidates: [URL] = []

        // 1. 本文件编译期路径上溯 4 级：Sources/AuroraDrive/Core/AuroraPaths.swift → 项目根
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent())

        // 2. 当前工作目录（从项目根手动启动时的常见情况）
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        // 3. 可执行文件所在目录（双击 AuroraDriveUI 启动时 cwd 即此处）
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir)
        }

        // 4. 从可执行文件目录**逐级上溯**（最多 6 级）找项目根
        //
        // ⚠️ P-1（2026-10-04）：这里原来是**硬编码绝对路径**
        //     `URL(fileURLWithPath: "/Users/dupi/Desktop/自动驾驶系统")`
        //     —— 把「某个开发者的桌面」写进了产品源码。后果：
        //       · 换机器 / 换用户名 → 这条候选**永远失效**，而且是**静默失效**
        //         （它是兜底，失效了不报错，只是少一条路）；
        //       · 源码里出现个人路径，既是隐私问题，也是"这代码只在我机器上跑"的气味。
        //
        // 【第一版改法我写错过，记在这里】我最初把它换成
        //   `FileManager.default.homeDirectoryForCurrentUser`（用户主目录）。
        //   那是**把一条能用的兜底换成一条永远不命中的死候选** ——
        //   主目录下没有 `Package.swift` 也没有 `models/`，等于白写。
        //   教训：**兜底候选的价值在于"真的可能命中"，不是"看起来更通用"。**
        //
        // 【现在的做法】从可执行文件目录**逐级上溯**。它机器无关，且真的能命中：
        //   · `run.sh` 把二进制拷到项目根 → 候选 3 已命中（execDir 就是根）；
        //   · 直接跑 `.build/scratch/release/AuroraDrive` → 上溯 3 级即到项目根；
        //   · 装到别处、或从别处启动 → 只要二进制在项目树内就仍能找到。
        //   6 级足够覆盖 SwiftPM 的构建目录深度（release/ → macosx/ → scratch/ →
        //   .build/ → 根，共 4 级），留 2 级余量。
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            var dir = execDir
            for _ in 0..<6 {
                dir = dir.deletingLastPathComponent()
                if dir.path == "/" { break }        // 已到根，停止
                candidates.append(dir)
            }
        }

        let fm = FileManager.default
        for c in candidates {
            if fm.fileExists(atPath: c.appendingPathComponent("Package.swift").path)
                || fm.fileExists(atPath: c.appendingPathComponent("models").path) {
                return c
            }
        }

        // 全部候选失败：回退第一个候选（调用方仍需处理资源缺失）
        return candidates[0]
    }

    /// models/ 目录（CoreML 模型、字模库、地图资源）
    static func modelsDir() -> URL {
        projectRoot().appendingPathComponent("models")
    }

    /// data/ 目录（raw_clips / glyph_clips 训练数据）
    static func dataDir() -> URL {
        projectRoot().appendingPathComponent("data")
    }
}
