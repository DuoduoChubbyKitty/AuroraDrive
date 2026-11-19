#!/usr/bin/env python3
"""只运行纯逻辑测试，不加载模型、不注入按键。
OCR finish/confirmedSpeed 和限速 guard 从生产源码原样抽取，依赖用无 I/O 状态壳提供。
"""
from pathlib import Path
import subprocess
import tempfile
import re

root = Path(__file__).resolve().parents[2]
src = root / 'Sources/AuroraDrive'
ocr = (src / 'Inference/SpeedOCRReader.swift').read_text()
app = (src / 'App/AuroraDriveApp.swift').read_text()

def block(text, start):
    a = text.index(start)
    b = text.index('{', a)
    level = 1
    i = b + 1
    while level:
        if text[i] == '{': level += 1
        elif text[i] == '}': level -= 1
        i += 1
    return text[a:i]

constants = '\n'.join(re.findall(r'    nonisolated static (?:let|var) (?:speedRange|maxJumpKmh|confirmCount|confirmWindowSec|confirmToleranceKmh|minConfirmAgreement)[^\n]*', ocr))
finish = block(ocr, '    private func finish(').replace('private func finish', 'func finish')
confirm = block(ocr, '    private static func confirmedSpeed(')
result = block(ocr, '    private struct RecognitionResult').replace('private struct', 'struct')
ocr_shell = '''import Foundation
final class OCRHarness {
var generation = 0
var isInferencing = false
var confidence = 0.0
var lastObservationUptime: Double?
var invalidationID: UInt64 = 0
var errorMessage: String?
var lastOCRDiagnostic = ""
var lastValidSpeed: Double?
var candidates: [(speed: Int, time: Date)] = []
var speedKmh = -1.0
var lastResultTime: Date?
'''
wiring = (src / 'App/ControlWiring.swift').read_text()
guard_class = block(wiring, 'final class SpeedLimitGuard')
threshold = re.search(r'static let unlimitedThreshold[^\n]*', wiring).group()
# 编译真实 guard，只有其 DriveState 常量依赖用同源值替代。
guard_source = 'import Foundation\nimport Observation\nenum DriveState { ' + threshold + '\n}\n' + guard_class

# 接线断言防止纯逻辑测试通过、生产调用点却仍用错速度。
assert app.index('let revokeAssist = speedTracking.update') < app.index('assistEngine.infer(image: cg')
assert 'if speedValid && assistImageFresh' in app
assert 'let assistLive = speedValid && isAlive(assistEngine)' in app
assert 'let assistCommand = speedValid ? commandOf(assistEngine) : .idle' in app
assert 'if revokeAssist { assistEngine.reset() }' in app
assert 'speedKmh: effectiveSpeed' not in app
assert 'speedValid ? trustedSpeedKmh : nil' in app
assert 'isDriving && speedValid && trustedSpeedKmh < 1.0' in app
assert 'self.pendingNativeObservedAt = ProcessInfo.processInfo.systemUptime' in app
assert 'lastObservationUptime = observedAt' in ocr
assert 'lastResultTime.map' not in app[app.index('let revokeAssist ='):app.index('// ── 1. 感知层')]
print('PASS: production wiring assertions', flush=True)
with tempfile.TemporaryDirectory(prefix='aurora-speed-tests-') as directory:
    out = Path(directory)
    (out / 'OCRHarness.swift').write_text(ocr_shell + constants + '\n' + result + '\n' + finish + '\n' + confirm + '\n}')
    (out / 'Guard.swift').write_text(guard_source)
    binary = out / 'tests'
    subprocess.run(['swiftc', '-parse-as-library', str(src / 'Agent/SpeedExtrapolator.swift'),
                    str(src / 'Agent/SpeedTrackingState.swift'), str(out / 'OCRHarness.swift'),
                    str(out / 'Guard.swift'), str(Path(__file__).with_name('Tests.swift')),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
