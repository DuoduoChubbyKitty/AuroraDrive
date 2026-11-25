#!/bin/bash
# ============================================================================
#  scripts/check-dead-code.sh —— 已确认「未接线」符号的防复活静态断言
# ============================================================================
#
#  【为什么需要它】
#  「risk 头未接线」这类事实此前只存在于注释里（口头约定）。注释挡不住
#  有人某天顺手把 risk 接进控制/安全链——那属于安全链语义变更，必须先过
#  阈值口径评审。本脚本把它变成机器断言：一旦出现新的消费点就 FAIL，
#  接线者必须显式改这里的判据（= 显式承认自己在改安全链）。
#
#  【判据口径】
#  · V3Decision.risk：Sources/ 非自检代码的消费点数必须为 0。
#    - 模式 `X.risk`（带接收者）——能命中 decision.risk / d.risk 这类真消费；
#    - 不会误伤 `return .risk`（MissionConsole 的 SwiftUI Color.risk，
#      前面是空格不是接收者）；
#    - 排除 *SelfTest*.swift（自检的范围/不变性检查是合法读者）、
#      InferenceEngineV3.swift（声明与文档本身）、InferenceEngineV2.swift
#      （V2 aux 有自己的 risk 通道，与 V3Decision.risk 无关）；
#    - 豁免一行已登记的只读读者：EngineMain 心跳统计行的 `v3:risk=` 观测段
#      （2026-11-25 T-02 加的纯展示，绝不构成接线）。新增任何 `.risk` 消费点
#      都会 FAIL —— 接线必须先过阈值口径评审。
#
#  【用法】
#    bash scripts/check-dead-code.sh
#  【退出码】0 = 全部断言通过；1 = 有符号被复活（打印命中行）
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0

echo "── 断言 1：V3Decision.risk 在非自检代码里 0 消费点 ──"
# 带接收者的 `.risk` 才算消费点；`return .risk`（Color）不带接收者，不匹配。
# 已登记的合法读者只有一处：EngineMain 心跳统计行的只读观测（2026-11-25
# T-02 加的 `v3:risk=` 展示段）——按 `v3:risk=` 标记精准豁免该行；
# 除此之外出现任何 `.risk` 消费点都算接线，必须先过阈值口径评审。
HITS=$(grep -rnE '[A-Za-z0-9_)]\.risk\b' Sources/ \
    | grep -v 'SelfTest' \
    | grep -v 'Inference/InferenceEngineV3.swift' \
    | grep -v 'Inference/InferenceEngineV2.swift' \
    | grep -v 'v3:risk=' \
    || true)
if [ -n "$HITS" ]; then
    echo "  ✗ risk 出现了新的消费点（接线必须先过阈值口径评审，并同步改本判据）："
    echo "$HITS" | sed 's/^/      /'
    FAIL=1
else
    echo "  ✓ 非自检代码 0 消费点（V3Decision.risk 仍未接线；唯一登记读者=心跳观测行）"
fi

echo ""
if [ "$FAIL" -ne 0 ]; then
    echo "✗ check-dead-code 未通过。"
    exit 1
fi
echo "✓ check-dead-code 全部通过。"
exit 0
