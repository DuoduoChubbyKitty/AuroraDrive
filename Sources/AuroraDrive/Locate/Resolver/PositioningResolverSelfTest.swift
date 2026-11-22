// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// 定位决策真值表自检（--positioning-selftest）。纯逻辑、无 IO，不联网不碰游戏。

func runPositioningResolverSelfTest() -> Int32 {
    var pass = 0
    var fail = 0
    func check(_ name: String, _ got: PositioningMode, _ want: PositioningMode) {
        if got == want { pass += 1; print("  ✅ \(name) → \(got.rawValue)") }
        else { fail += 1; print("  ❌ \(name) → \(got.rawValue)，期望 \(want.rawValue)") }
    }

    print("═══ 定位方式决策自检（--positioning-selftest）═══")

    // 规则①：内置启动器云端 —— 不管抓屏目标是什么都走视觉
    check("云端启动(浏览器)", PositioningResolver.resolve(launchSource: .cloud, captureIsBrowser: true), .visual)
    check("云端启动(非浏览器边界)", PositioningResolver.resolve(launchSource: .cloud, captureIsBrowser: false), .visual)

    // 规则②：内置启动器本地 —— 不管浏览器标志都走网络
    check("本地启动(非浏览器)", PositioningResolver.resolve(launchSource: .local, captureIsBrowser: false), .network)
    check("本地启动(浏览器边界)", PositioningResolver.resolve(launchSource: .local, captureIsBrowser: true), .network)

    // 规则③：来源未知 —— 靠浏览器识别
    check("未知+浏览器 → 视觉", PositioningResolver.resolve(launchSource: .unknown, captureIsBrowser: true), .visual)
    check("未知+非浏览器 → 网络", PositioningResolver.resolve(launchSource: .unknown, captureIsBrowser: false), .network)

    print("═══ 结果：\(pass) 通过 / \(fail) 失败 ═══")
    return Int32(fail)
}
