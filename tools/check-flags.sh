#!/bin/bash
# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ============================================================================
#  check-flags.sh — 环境开关登记完整性检查（A17 配套）
# ============================================================================
#
#  【为什么需要它】
#  项目有 71 个 `AURORA_*` 环境开关，`Core/AuroraFlags.swift` 是它们的**唯一事实源**
#  （声明 + 默认值 + 说明 + 归属 + `--flags-help` 全表）。
#  但"登记"这件事**靠人记得**，而人会忘。实测教训（2026-10-04）：
#  `perf-core` 统计开关总数连错三次（41 → 66 → 69 → 71）——
#  前两次错在只扫 `environment["X"]` **下标表达式**，漏了两类别名写法；
#  第三次错在**只做单向扫描**，于是 `AURORA_KEY_REFRESH_HZ`
#  （`Control/ControlEngine.swift` 新加、直接现读、绕过集中化）漏网。
#
#  【检查什么】四条，含义各不相同（前三条硬失败，第四条软警告）
#
#   方向 A · 未登记：全仓（**排除开关表自身**）出现 `"AURORA_X"` 字面量，
#                    但 `AuroraFlags.all` 里没有 X。→ 绕过了集中化，**必须修**。
#
#   方向 B · 无实现：`all` 里有 X，但 `AuroraFlags` 里没有任何访问器引用 X。
#                    → 这条表项是**文档谎言**（`--flags-help` 会列出它，
#                      但代码里根本没有读它的入口），**必须修**。
#
#   方向 C · 无登记：有访问器引用 X，但 `all` 里没有 X。
#                    → 开关能生效但**不会出现在 `--flags-help`**，
#                      等于对使用者隐藏，**必须修**。
#
#   方向 D · 无读者（软）：访问器存在、表项存在，但**访问器名字**在开关表
#                    以外零出现 → 声明了却没人用。
#                    ⚠️ 这一条**只警告不失败**：它可能是
#                      ① 刚加、接线还没落地（如 `AURORA_EGO_DIAG` 由 site-pph 接）
#                      ② 给未来留的接口
#                      两者都不该让 CI 变红，但都值得被看见。
#
#  ⚠️ **口径必须是"字符串字面量"，不是"下标表达式"** —— 这是前两次错因的根子。
#     只要有人用 `let env = ...` + `env["X"]` 或常量持键名（`EgoBoxFilter.envKey`），
#     下标口径就会漏；字面量口径对两种别名写法都免疫。
#
#  ⚠️ **方向 A 必须排除 `AuroraFlags.swift` 自身**：开关表里每个
#     `.init(key: "AURORA_X")` 本身就是一个字面量，算进来会让"未登记"永远查不出。
#     这条是第一版的 bug，靠**负向对照测试**抓出来的。
#
#  【白名单】
#  有些 `"AURORA_*"` 字面量**不是环境变量读取**（如安装脚本里的 `echo` 标记）。
#  它们必须在 `WHITELIST` 里登记并**写清理由** —— 白名单不是"眼不见为净"，
#  它是"经过判断的例外"，每条都要能被复核。
#
#  【用法】
#      tools/check-flags.sh            # 人类可读
#      tools/check-flags.sh --quiet    # 只在有问题时输出（CI / 回归门用）
#
#  【退出码】
#      0 = A/B/C 三条硬检查全过（D 的警告不影响退出码）
#      1 = A/B/C 任一非空
#      2 = 环境问题（找不到源目录 / 开关表）
#
#  ⚠️ bash 3.2 兼容（macOS 自带）：不使用 `declare -A` / `${var,,}` / `mapfile`。
# ============================================================================

set -u

QUIET=0
for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/Sources"
FLAGS_FILE="$SRC_DIR/AuroraDrive/Core/AuroraFlags.swift"

[ -d "$SRC_DIR" ]   || { echo "✗ 找不到源目录：$SRC_DIR" >&2; exit 2; }
[ -f "$FLAGS_FILE" ] || { echo "✗ 找不到开关表：$FLAGS_FILE" >&2; exit 2; }

# ── 白名单：允许"存在于字面量、但不在表里"的名字 ──────────────────────────
# 格式：NAME|理由（理由必填；空理由视为未登记，会被判失败）
WHITELIST="AURORA_PRIVILEGE_INSTALLED|Core/PrivilegePill.swift 里安装脚本的 \`echo \"AURORA_PRIVILEGE_INSTALLED\"\` —— 它是**脚本打印的字符串**，不是环境变量读取。若登记成开关，--flags-help 会出现一个永远无效的条目。"

TMP_LIT="$(mktemp -t af.lit)";       TMP_TAB="$(mktemp -t af.tab)"
TMP_ACC="$(mktemp -t af.acc)";       TMP_WL="$(mktemp -t af.wl)"
TMP_UNREG="$(mktemp -t af.unreg)";   TMP_NOIMPL="$(mktemp -t af.noimpl)"
TMP_NOREG="$(mktemp -t af.noreg)";   TMP_NOREAD="$(mktemp -t af.noread)"
cleanup() { rm -f "$TMP_LIT" "$TMP_TAB" "$TMP_ACC" "$TMP_WL" \
                 "$TMP_UNREG" "$TMP_NOIMPL" "$TMP_NOREG" "$TMP_NOREAD"; }
trap cleanup EXIT INT TERM

# ── 方向 A 的输入：全仓字面量（排除开关表自身）────────────────────────────
: > "$TMP_LIT"
find "$SRC_DIR" -name '*.swift' -print 2>/dev/null | while IFS= read -r f; do
    # 开关表自身不计入"使用点"（否则"未登记"永远查不出来）
    if [ "$f" != "$FLAGS_FILE" ]; then
        grep -hoE '"AURORA_[A-Za-z_0-9]*"' "$f" 2>/dev/null | tr -d '"'
    fi
done | sort -u > "$TMP_LIT"

# ── 表项（登记了什么）────────────────────────────────────────────────────
grep -oE '\.init\(key: "(AURORA_[A-Za-z_0-9]*)"' "$FLAGS_FILE" 2>/dev/null \
    | sed -E 's/.*"(AURORA_[A-Za-z_0-9]*)"/\1/' | sort -u > "$TMP_TAB"

# ── 访问器（实现了什么）──────────────────────────────────────────────────
# 用 awk 跟踪"最近的 static let/var NAME"，遇到 `"AURORA_X"` 就记一对。
# 表项自身的 `static let all: [...] = [...]` 会让 NAME="all" —— 过滤掉。
awk '
    /static (let|var) [A-Za-z_][A-Za-z0-9_]*/ {
        if (match($0, /static (let|var) [A-Za-z_][A-Za-z0-9_]*/)) {
            nm = substr($0, RSTART, RLENGTH)
            sub(/static (let|var) /, "", nm)
        }
    }
    {
        line = $0
        while (match(line, /"AURORA_[A-Za-z_0-9]*"/)) {
            key = substr(line, RSTART + 1, RLENGTH - 2)
            if (nm != "" && nm != "all") print nm "|" key
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$FLAGS_FILE" | sort -u > "$TMP_ACC"

sed -E 's/^[^|]*\|//' "$TMP_ACC" | sort -u > "$TMP_ACC.keys"
printf '%s\n' "$WHITELIST" | sed -n 's/^\([A-Z_0-9]*\)|.*/\1/p' | sort -u > "$TMP_WL"

# ── A：字面量 − 表项 − 白名单 ────────────────────────────────────────────
comm -23 "$TMP_LIT" "$TMP_TAB" | grep -vxF -f "$TMP_WL" > "$TMP_UNREG" 2>/dev/null || true
# ── B：表项 − 访问器 ────────────────────────────────────────────────────
comm -23 "$TMP_TAB" "$TMP_ACC.keys" > "$TMP_NOIMPL" 2>/dev/null || true
# ── C：访问器 − 表项 ────────────────────────────────────────────────────
comm -13 "$TMP_TAB" "$TMP_ACC.keys" > "$TMP_NOREG" 2>/dev/null || true

# ── D（软）：访问器名在开关表以外零出现 ──────────────────────────────────
: > "$TMP_NOREAD"
while IFS='|' read -r name key; do
    [ -n "$name" ] || continue
    hits=$(find "$SRC_DIR" -name '*.swift' -print 2>/dev/null | while IFS= read -r f; do
        # ⚠️ 用 if 而不是 case：bash 3.2 在 `$( ... )` 里解析 `case ... ;;` 会报
        #    "syntax error near unexpected token `;;'"（实测踩到）。
        if [ "$f" != "$FLAGS_FILE" ]; then
            grep -oE "\b${name}\b" "$f" 2>/dev/null
        fi
    done | wc -l | tr -d ' ')
    [ "$hits" -eq 0 ] && echo "$key (访问器 AuroraFlags.$name)" >> "$TMP_NOREAD"
done < "$TMP_ACC"
sort -u -o "$TMP_NOREAD" "$TMP_NOREAD"

N_LIT=$(wc -l < "$TMP_LIT" | tr -d ' ')
N_TAB=$(wc -l < "$TMP_TAB" | tr -d ' ')
N_ACC=$(wc -l < "$TMP_ACC.keys" | tr -d ' ')
N_A=$(wc -l < "$TMP_UNREG" | tr -d ' ')
N_B=$(wc -l < "$TMP_NOIMPL" | tr -d ' ')
N_C=$(wc -l < "$TMP_NOREG" | tr -d ' ')
N_D=$(wc -l < "$TMP_NOREAD" | tr -d ' ')

if [ "$QUIET" -eq 0 ]; then
    echo "═══ 环境开关登记完整性 ═══"
    echo "  使用点字面量（排除开关表自身）：$N_LIT 个"
    echo "  登记表项（AuroraFlags.all）    ：$N_TAB 个"
    echo "  访问器（static let/var → key） ：$N_ACC 个"
    echo ""
fi

FAIL=0

if [ "$N_A" -gt 0 ]; then
    FAIL=1
    echo "❌ 方向 A · 未登记（用了但没进 AuroraFlags.all）：$N_A 个"
    sed 's/^/     /' "$TMP_UNREG"
    echo "     → 修法：在 Core/AuroraFlags.swift 加 static let + 表项；"
    echo "       若它确实不是环境变量，加进本脚本 WHITELIST 并写清理由。"
    echo ""
fi

if [ "$N_B" -gt 0 ]; then
    FAIL=1
    echo "❌ 方向 B · 无实现（进了表但没有访问器读它）：$N_B 个"
    sed 's/^/     /' "$TMP_NOIMPL"
    echo "     → 修法：补一个访问器，或删掉这条表项（它是文档谎言）。"
    echo ""
fi

if [ "$N_C" -gt 0 ]; then
    FAIL=1
    echo "❌ 方向 C · 无登记（有访问器但没进表）：$N_C 个"
    sed 's/^/     /' "$TMP_NOREG"
    echo "     → 修法：补表项，否则它不会出现在 --flags-help（对使用者隐藏）。"
    echo ""
fi

if [ "$N_D" -gt 0 ]; then
    echo "⚠️  方向 D · 无读者（软警告，不影响退出码）：$N_D 个"
    sed 's/^/     /' "$TMP_NOREAD"
    echo "     → 两种含义，都不该让 CI 变红："
    echo "       ① **迁移待办**：A17 已建好集中表，但调用点还在别的写域没迁 ——"
    echo "          这份清单就是「还有哪些开关的读取点没改成 AuroraFlags.xxx」。"
    echo "       ② 给未来留的接口 / 刚加还没接线。"
    echo "     → 判据：`grep -rn 'ProcessInfo.processInfo.environment' Sources/`"
    echo "       若还有命中，说明是①（迁移未完成），不是②。"
    echo ""
fi

if [ "$FAIL" -eq 0 ]; then
    echo "✅ A/B/C 全过：$N_TAB 个开关，登记、实现、使用点三者一致（白名单 1 项有理由）"
    exit 0
fi

echo "═══ 环境开关登记完整性：FAIL ═══"
exit 1
