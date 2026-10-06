#!/bin/bash
# ============================================================================
#  tools/check-c7-gate.sh —— C7「路况观测门」源码级回归守卫
# ============================================================================
#
#  【守的是什么】
#  2026-10-05 修掉的安全缺陷：§4.4 自动速度的路况判定门原本写成
#        if autoSpeedEnabled, isDriving, !unlimitedLockedByUser { ... }
#  它把**整块路况判定**包住了，后果是一条完整的失效链：
#        用户把限速滑块拉到底（= 不限速）
#     →  roadCondition 永不再更新
#     →  needsTakeover 恒为 false
#     →  **接管告警横幅永不显示**
#  而"我刚决定不限速"恰恰是最该提醒用户留意的时刻。这是**安全缺陷**。
#
#  【为什么必须源码级检查】
#  这条缺陷**测不出来**——它在调用方的门上，不在纯函数里。
#  `--limit-selftest` 已覆盖 `autoSpeedTarget` 的全部优先级分支
#  （用户不限速 / 自动不限速 / 关机 / 各档位），全绿；
#  但门一旦被放回调用方，**每一个断言都仍然通过**：那叫「恰好通过」。
#  纯函数级自测**结构上**看不见调用点的条件。
#
#  【检查什么】
#   A1. §4.4 的门**必须**走 `shouldObserveRoadCondition(...)` 纯函数
#       （只查 §4.4 那一段，不查全文件 —— 见下方 2026-10-05 教训）
#   A2. 该纯函数签名**不含**任何限速状态（结构上排斥这类错误回潮）
#   B.  用户不限速保护必须**存在**于 applyRoadCondition（防止修 A 时删掉它）
#   C.  §4.4 的观测门里不得再出现「不限速」条件（这就是原缺陷的形状）
#
#  【⚠️ 2026-10-05 的教训：为什么 A1 只查 §4.4 而不是全文件】
#  第一版 A1 写的是「全文件 grep shouldObserveRoadCondition(...) ≥ 1 处」。
#  随后为了验证 C7，在 `--limit-selftest` 里加了 3 条自测断言 ——
#  它们也调用这个纯函数。于是负向对照①（把门退回内联写法）**不再被抓住**：
#  全文件计数从 1 变 3，检查照样通过 → **假绿**。
#  「旁证也会被写坏」：任何"全文件计数 ≥ N"式检查都会被无关改动弄瞎。
#  所以现在严格限定在 §4.4 区域内查，并且负向对照必须**真的弄坏源码**再断言报红。
#
#  【负向对照：这个门禁**必须会失败**】
#  自测把真实源码复制到临时目录、在里面注入三种坏写法，断言检查报红：
#      ① 退回调用方内联门（原缺陷形状）
#      ② 纯函数签名偷偷加回限速状态
#      ③ 把「用户不限速」保护整个删掉
#  每次都**断言注入确实改动了文件**——注入静默失配正是第一版的假绿来源
#  （`str.replace` 找不到就什么都不做还退出 0，于是"坏样本"其实是好样本）。
#      bash tools/check-c7-gate.sh --selftest
#
#  【本仓 bash 是 3.2 的硬规矩】所有变量引用一律写 `${VAR}`，不管后面跟什么。
#    bash 3.2 不做 UTF-8 感知，`$VAR` 紧跟全角标点会把标点字节并进变量名。
#
#  用法： bash tools/check-c7-gate.sh [--selftest]
#  退出码：0 = 通过；1 = 违反；2 = 用法/环境错误
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 检查主体是 python：BSD grep/awk 的 `\s` 转义与跨行匹配太脆，
# 已经在这上面栽过一次（`grep -vE '^\s*//'` 在 BSD 上不剥注释）。
# python 的 re 跨平台一致，且能把"注入是否真的生效"写成硬断言。
exec python3 - "$ROOT" "${1:-}" <<'PY'
import os, re, shutil, sys, tempfile

ROOT, MODE = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
APP  = os.path.join(ROOT, "Sources/AuroraDrive/App/AuroraDriveApp.swift")
WIRE = os.path.join(ROOT, "Sources/AuroraDrive/App/ControlWiring.swift")

RC_BAD = 1
results = []

def rep(ok, name, detail=""):
    results.append(ok)
    mark = "✅" if ok else "❌"
    print(f"  {mark} {name}" + (f"  — {detail}" if detail and not ok else ""))


def region_44(app_src):
    """取 §4.4 自动速度那一段（不含 §4.5）。

    只看这一段是有意的：门在不在调用方，是**局部**事实。
    全文件计数会被同名的自测断言污染（2026-10-05 假绿根因）。
    """
    lines = app_src.splitlines()
    start = end = None
    for i, ln in enumerate(lines):
        if "── 4.4 自动速度" in ln and start is None:
            start = i
        elif "── 4.5 限速硬闸" in ln and start is not None:
            end = i
            break
    if start is None:
        return None
    return "\n".join(lines[start:end if end is not None else len(lines)])


def strip_line_comments(seg):
    """剥掉整行注释（含缩进的 `//`）。

    必须剥：A/C 两处检查的正上方就有一段文档注释，里面**故意**写着
    原缺陷的形状 `if autoSpeedEnabled, isDriving, !unlimitedLockedByUser`
    作为"勿改回去"的警示。不剥注释就会把那段说明当成真代码。
    """
    out = []
    for ln in seg.splitlines():
        if ln.lstrip().startswith("//"):
            continue
        # 行尾注释也去掉，避免 `code  // 说明 unlimitedLockedByUser` 误判
        out.append(re.sub(r"//.*$", "", ln))
    return "\n".join(out)


def check(app_path, wire_path):
    results.clear()
    app_src  = open(app_path,  encoding="utf-8").read()
    wire_src = open(wire_path, encoding="utf-8").read()

    # ── A1. §4.4 的门必须走纯函数（限区域内查）──────────────────────────
    seg = region_44(app_src)
    if seg is None:
        rep(False, "A1 · 找不到 §4.4 自动速度段", "文件结构变了？注释标题被改？")
    else:
        n = len(re.findall(r"DriveState\.shouldObserveRoadCondition\s*\(", seg))
        if n >= 1:
            rep(True, f"A1 · §4.4 观测门走纯函数 shouldObserveRoadCondition（段内 {n} 处）")
        else:
            rep(False, "A1 · §4.4 观测门未走纯函数",
                "段内找不到 shouldObserveRoadCondition(...) 调用")

    # ── A2. 纯函数签名不得含限速状态（结构上排斥回潮）──────────────────
    m = re.search(
        r"static func shouldObserveRoadCondition\s*\((.*?)\)\s*->\s*Bool",
        wire_src, re.S)
    if not m:
        rep(False, "A2 · 纯函数 shouldObserveRoadCondition 不存在")
    else:
        sig = re.sub(r"\s+", "", m.group(1))
        bad = [t for t in ("unlimited", "speedLimit", "isUnlimited") if t in sig]
        if bad:
            rep(False, "A2 · 纯函数签名含限速状态",
                f"签名里出现 {bad} —— 这正是缺陷的形状")
        else:
            rep(True, "A2 · 纯函数签名只含 autoSpeedEnabled/isDriving（不含限速状态）")

    # ── B. 用户不限速保护必须存在于 applyRoadCondition ──────────────────
    mb = re.search(r"func applyRoadCondition\s*\(.*?\n(.*?)\n    \}", wire_src, re.S)
    body = mb.group(1) if mb else ""
    if re.search(r"guard\s+!unlimitedLockedByUser", body):
        rep(True, "B  · applyRoadCondition 保留用户不限速保护（guard !unlimitedLockedByUser）")
    else:
        rep(False, "B  · applyRoadCondition 丢失用户不限速保护",
            "用户拉到底选不限速后会被自动判定改回 —— §4.4 明文禁止")

    # ── C. 缺陷形状：观测门里出现不限速条件 ────────────────────────────
    if seg is None:
        rep(False, "C  · 无法检查 §4.4 缺陷形状（段未取到）")
    else:
        code = strip_line_comments(seg)
        hit = re.search(r"if\b[^\n{]*\b(?:unlimitedLockedByUser|isUnlimited)\b", code)
        if hit:
            rep(False, "C  · §4.4 观测门里又出现了「不限速」条件",
                f"这就是 2026-10-05 的安全缺陷本身（告警会永不显示）：{hit.group(0).strip()}")
        else:
            rep(True, "C  · §4.4 观测门里没有「不限速」条件（无缺陷形状）")

    return all(results)


def inject(path, pattern, repl, label):
    """在副本上做正则注入，并**硬断言**真的改动了。

    第一版用 str.replace() 且不校验返回值 —— 静默失配时"坏样本"其实是
    好样本，负向对照于是永远通过（假绿）。现在失配即抛错。
    """
    src = open(path, encoding="utf-8").read()
    new, n = re.subn(pattern, repl, src, count=1, flags=re.S)
    if n != 1:
        raise SystemExit(f"  ⚠️ 注入失败〔{label}〕：正则没有匹配到目标，"
                         f"负向对照无效 —— 必须先修注入，再谈门禁。")
    open(path, "w", encoding="utf-8").write(new)


# ══════════════════════════════════════════════════════════════════════════
if MODE == "--selftest":
    print("═══ check-c7-gate.sh 自测（负向对照）═══")
    ok = True
    # 留一份原始快照，自测结束后用它做真实比对（证明没碰真源码）
    orig_app  = open(APP,  encoding="utf-8").read()
    orig_wire = open(WIRE, encoding="utf-8").read()

    print("\n── 正向：当前真实源码必须通过 ──")
    if check(APP, WIRE):
        print("  ✅ 当前源码通过（这是应有的状态）")
    else:
        print("  ❌ 当前源码就没通过 —— 先修代码再谈门禁")
        ok = False

    print("\n── 负向：三种坏写法必须全部被抓住 ──")
    work = tempfile.mkdtemp()
    app_c, wire_c = os.path.join(work, "A.swift"), os.path.join(work, "W.swift")

    cases = [
        ("① 退回调用方内联门（原缺陷形状）", app_c,
         r"if DriveState\.shouldObserveRoadCondition\(autoSpeedEnabled:\s*autoSpeedEnabled,\s*\n\s*isDriving:\s*isDriving\)\s*\{",
         "if autoSpeedEnabled, isDriving, !unlimitedLockedByUser {"),
        ("② 纯函数签名偷偷加回限速状态", wire_c,
         r"static func shouldObserveRoadCondition\(autoSpeedEnabled: Bool,\s*\n\s*isDriving: Bool\) -> Bool \{\s*\n\s*autoSpeedEnabled && isDriving",
         "static func shouldObserveRoadCondition(autoSpeedEnabled: Bool,\n"
         "                                           isDriving: Bool,\n"
         "                                           unlimitedLockedByUser: Bool) -> Bool {\n"
         "        autoSpeedEnabled && isDriving && !unlimitedLockedByUser"),
        ("③ 把「用户不限速」保护整个删掉", wire_c,
         r"guard !unlimitedLockedByUser else \{ return \}",
         ""),
    ]

    for name, target, pat, repl in cases:
        shutil.copy(APP, app_c); shutil.copy(WIRE, wire_c)
        try:
            inject(target, pat, repl, name)
        except SystemExit as e:
            print(e); ok = False; continue
        if check(app_c, wire_c):
            print(f"  ❌ {name} —— 检查竟然通过了（假阴性！这个门禁没在守东西）")
            ok = False
        else:
            print(f"  ✅ {name} —— 检查报红（符合预期）")

    # 还原确认：全程在副本上注入，真源码必须一字未动。
    # 这里必须做**真实比对**，不能写恒真断言 —— 否则就是自欺。
    print("")
    if open(APP, encoding="utf-8").read() == orig_app \
       and open(WIRE, encoding="utf-8").read() == orig_wire:
        print("  ✅ 自测未改动真实源码（全程在副本上注入）")
    else:
        print("  ❌ 真实源码被自测改动了 —— 立即检查！"); ok = False
    shutil.rmtree(work, ignore_errors=True)

    print("")
    print("  ✅ C7 门禁自测全部通过（含 3 条负向对照）" if ok
          else "  ❌ C7 门禁自测失败")
    sys.exit(0 if ok else RC_BAD)

# ══════════════════════════════════════════════════════════════════════════
print("═══ C7 路况观测门守卫 ═══")
for p in (APP, WIRE):
    if not os.path.exists(p):
        print(f"  ✗ 找不到源码 {p}"); sys.exit(2)

if check(APP, WIRE):
    print("\n  ✅ C7 通过：观测门与「不限速优先」已正确分离")
    sys.exit(0)
else:
    print("\n  ❌ C7 违反：用户拉到底选不限速时，接管告警可能永不显示")
    print("     修法见 ControlWiring.swift 的 shouldObserveRoadCondition 文档注释")
    sys.exit(RC_BAD)
PY
