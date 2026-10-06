#!/bin/bash
# ============================================================================
#  scripts/regression-gate.sh —— 七维度「零劣化」门禁
# ============================================================================
#
#  【为什么需要它】
#  全队 7 个人在做性能优化。没有门禁时，「悄悄降质换速度」在流程上**不可能被
#  发现** —— 因为没有任何一条命令会因为劣化而失败。本脚本就是那条命令。
#
#  用户的硬要求（原话）：
#    「确保没有降任何频率、任何画质、任何输出频率、任何线程循环数、
#      任何模型质量、任何的质量、任何的画质和任何的帧率」
#
#  【用法】
#    # 1) 首次：把当前状态冻结成参考基线
#    bash scripts/regression-gate.sh --freeze
#
#    # 2) 每次优化落地后：一条命令跑完
#    bash scripts/regression-gate.sh
#
#    # 3) 只比两个已有快照（不重新采集）
#    bash scripts/regression-gate.sh --baseline A.json --current B.json
#
#    # 4) 优化**故意**改变了画面（例如新增图层）时，把画质项降级为 WARN
#    bash scripts/regression-gate.sh --allow-image-change
#
#  【退出码】0 = 七维度全部通过；1 = 有劣化；2 = 用法/环境错误
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

FROZEN="$ROOT/tools/perf/baseline-frozen.json"
CURRENT="$ROOT/tools/perf/baseline-current.json"
BASELINE=""
CUR_ARG=""
FREEZE=0
ALLOW_IMG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --freeze) FREEZE=1; shift ;;
        --baseline) BASELINE="${2:-}"; shift 2 ;;
        --current)  CUR_ARG="${2:-}"; shift 2 ;;
        --allow-image-change) ALLOW_IMG=1; shift ;;
        *) echo "未知参数：$1"; exit 2 ;;
    esac
done

BIN="$ROOT/.build/scratch/release/AuroraDrive"

# ── 构建/验收锁：门禁全程持锁 ─────────────────────────────────────────────
# 理由见 scripts/build-lock.sh 头部：SwiftPM 全模块编译，一个人写坏全组验不了；
# 且并发基准会让 loadavg 冲高，使耗时类判据全部失真。
if [ "${AURORA_SKIP_BUILD_LOCK:-0}" != "1" ] && [ "$FREEZE" != "1" ]; then
    if ! bash "$ROOT/scripts/build-lock.sh" acquire "regression-gate"; then
        echo ""
        echo "  ✗ 拿不到构建锁 —— 拒绝在并发环境下跑门禁。"
        exit 3
    fi
    trap 'bash "$ROOT/scripts/build-lock.sh" release >/dev/null 2>&1' EXIT
fi

# ── 采集模式 ──────────────────────────────────────────────────────────────
if [ "$FREEZE" = "1" ]; then
    [ -x "$BIN" ] || { echo "✗ 先构建 release：swift build -c release --disable-sandbox --scratch-path .build/scratch"; exit 2; }
    bash "$ROOT/scripts/perf-snapshot.sh" "$BIN" "$FROZEN" "冻结基线" || exit 2
    echo ""
    echo "✅ 已冻结参考基线：$FROZEN"
    echo "   之后每次优化后跑：bash scripts/regression-gate.sh"
    exit 0
fi

if [ -z "$BASELINE" ]; then
    # 默认：拿冻结基线 vs 现采当前快照
    [ -f "$FROZEN" ] || { echo "✗ 还没有冻结基线。先跑：bash scripts/regression-gate.sh --freeze"; exit 2; }
    [ -x "$BIN" ] || { echo "✗ 找不到 release 二进制：$BIN"; exit 2; }
    BASELINE="$FROZEN"
    echo "采集当前快照…"
    bash "$ROOT/scripts/perf-snapshot.sh" "$BIN" "$CURRENT" "门禁检查" >/dev/null 2>&1 || { echo "✗ 快照采集失败"; exit 2; }
    CUR_ARG="$CURRENT"
fi
[ -n "$CUR_ARG" ] || CUR_ARG="$CURRENT"
[ -f "$BASELINE" ] || { echo "✗ 基线不存在：$BASELINE"; exit 2; }
[ -f "$CUR_ARG" ]  || { echo "✗ 当前快照不存在：$CUR_ARG"; exit 2; }

# ── 比对 ──────────────────────────────────────────────────────────────────
GATE_BASE="$BASELINE" GATE_CUR="$CUR_ARG" GATE_ALLOW_IMG="$ALLOW_IMG" \
python3 - <<'PY'
import json, os, sys

base = json.load(open(os.environ['GATE_BASE'], encoding='utf-8'))
cur  = json.load(open(os.environ['GATE_CUR'],  encoding='utf-8'))
ALLOW_IMG = os.environ['GATE_ALLOW_IMG'] == '1'

rows = []   # (维度, 指标, 基线, 当前, 判据, 结论)

def num(x):
    return x if isinstance(x, (int, float)) else None

def cmp_max(dim, name, b, c, tol_pct=10.0, tol_abs=0.0):
    """越大越差：耗时类。"""
    b, c = num(b), num(c)
    if b is None or c is None:
        rows.append((dim, name, b, c, '缺失', 'SKIP')); return
    limit = max(b * (1 + tol_pct / 100.0), b + tol_abs)
    ok = c <= limit
    rows.append((dim, name, f'{b:.3f}', f'{c:.3f}',
                 f'≤{limit:.3f} (+{tol_pct:g}%)', 'PASS' if ok else 'FAIL'))

def cmp_min(dim, name, b, c, tol_pct=5.0):
    """越小越差：频率类。"""
    b, c = num(b), num(c)
    if b is None or c is None:
        rows.append((dim, name, b, c, '缺失', 'SKIP')); return
    limit = b * (1 - tol_pct / 100.0)
    ok = c >= limit
    rows.append((dim, name, f'{b:.3f}', f'{c:.3f}',
                 f'≥{limit:.3f} (-{tol_pct:g}%)', 'PASS' if ok else 'FAIL'))

def cmp_eq(dim, name, b, c, allow=False):
    if b is None or c is None:
        rows.append((dim, name, b, c, '缺失', 'SKIP')); return
    ok = (b == c)
    verdict = 'PASS' if ok else ('WARN' if allow else 'FAIL')
    rows.append((dim, name, str(b)[:16], str(c)[:16], '完全相等', verdict))

D  = base.get('dimensions', {})
DC = cur.get('dimensions', {})

# ── 1. 帧率/频率 ─────────────────────────────────────────────────────────
bf, cf = D.get('frames', {}), DC.get('frames', {})
for view in sorted(set(bf) | set(cf)):
    for key in ('①', '②', '③'):
        b = bf.get(view, {}).get(key, {})
        c = cf.get(view, {}).get(key, {})
        label = f'{view}m/{key}{b.get("name","")[:8]}'
        cmp_max('1 帧率', f'{label} p50', b.get('p50'), c.get('p50'), tol_pct=10.0)
        cmp_max('1 帧率', f'{label} p95', b.get('p95'), c.get('p95'), tol_pct=15.0)
for k in ('marker_layer_new_ms', 'near_marker_new_ms'):
    cmp_max('1 帧率', k, D.get('frames_extra', {}).get(k),
            DC.get('frames_extra', {}).get(k), tol_pct=10.0)

# ── 2. 输出频率 ──────────────────────────────────────────────────────────
br, cr = D.get('rates', {}), DC.get('rates', {})
for k in sorted(set(br) | set(cr)):
    if k.endswith('_hz'):
        cmp_min('2 输出频率', k, br.get(k), cr.get(k), tol_pct=5.0)
    elif k.endswith('_count'):
        cmp_min('2 输出频率', k, br.get(k), cr.get(k), tol_pct=5.0)

# ── 2b. 真实推理成本 infer.*（比 submit.* 有意义得多）────────────────────
# site-main 实测：submit.yolopx p50=0.019ms vs infer.yolopx p50=12.405ms
# = 650 倍。只看 submit 会漏掉全部真实开销，所以单列一维。
binf, cinf = D.get('infer', {}), DC.get('infer', {})
for k in sorted(set(binf) | set(cinf)):
    b, c = binf.get(k, {}), cinf.get(k, {})
    if not k.startswith('infer.'):
        continue
    cmp_max('2b 推理成本', f'{k} p50', b.get('p50'), c.get('p50'), tol_pct=10.0)
    cmp_max('2b 推理成本', f'{k} p95', b.get('p95'), c.get('p95'), tol_pct=15.0)
for k in ('opticalflow', 'tick.loop'):
    b, c = binf.get(k, {}), cinf.get(k, {})
    cmp_max('2b 推理成本', f'{k} p50', b.get('p50'), c.get('p50'), tol_pct=10.0)
    cmp_max('2b 推理成本', f'{k} p95', b.get('p95'), c.get('p95'), tol_pct=15.0)

# ── 3. 画质 ──────────────────────────────────────────────────────────────
bi, ci = D.get('image_quality', {}), DC.get('image_quality', {})
if bi.get('exists') and ci.get('exists'):
    cmp_eq('3 画质', 'PNG 像素指纹(64×64)', bi.get('pixel_sig_64'), ci.get('pixel_sig_64'), allow=ALLOW_IMG)
    cmp_eq('3 画质', 'PNG md5', bi.get('md5'), ci.get('md5'), allow=ALLOW_IMG)
    cmp_eq('3 画质', '出图尺寸', str(bi.get('size')), str(ci.get('size')))
    rows.append(('3 画质', '非纯色图(颜色数>1)', bi.get('distinct_colors_64'), ci.get('distinct_colors_64'),
                 '>1', 'PASS' if (ci.get('distinct_colors_64') or 0) > 1 else 'FAIL'))
else:
    rows.append(('3 画质', 'PNG 存在', bi.get('exists'), ci.get('exists'), '都要存在', 'FAIL'))

# ── 4. 模型质量 ──────────────────────────────────────────────────────────
bq, cq = D.get('model_quality', {}), DC.get('model_quality', {})
cmp_min('4 模型质量', 'R2 检测框数量', bq.get('R2_det_count'), cq.get('R2_det_count'), tol_pct=0.0)
cmp_min('4 模型质量', 'R3 可行驶掩码 %', bq.get('R3_drivable_pct'), cq.get('R3_drivable_pct'), tol_pct=0.0)
cmp_min('4 模型质量', 'R3 车道线掩码 %', bq.get('R3_lane_pct'), cq.get('R3_lane_pct'), tol_pct=0.0)
for k in sorted(set(bq) | set(cq)):
    if k.endswith('-selftest'):
        b, c = bq.get(k, {}), cq.get(k, {})
        # 从「无失败」退化到「有失败」= FAIL
        bad = (not b.get('has_fail_marker', False)) and c.get('has_fail_marker', False)
        rows.append(('4 模型质量', k + ' 失败标记', b.get('has_fail_marker'), c.get('has_fail_marker'),
                     '不得新增', 'FAIL' if bad else 'PASS'))

# ── 5. 线程数 ────────────────────────────────────────────────────────────
bt, ct = D.get('threads', {}), DC.get('threads', {})
cmp_max('5 线程数', '峰值线程', bt.get('peak'), ct.get('peak'), tol_pct=10.0, tol_abs=2)

# ── 6. 内存 ──────────────────────────────────────────────────────────────
bm, cm = D.get('memory', {}), DC.get('memory', {})
cmp_max('6 内存', 'T5 RSS 增长 MB', bm.get('T5_rss_growth_mb'), cm.get('T5_rss_growth_mb'), tol_pct=50.0)
if (cm.get('T5_rss_growth_mb') or 0) > 50:
    rows.append(('6 内存', 'T5 硬上限 <50MB', 50, cm.get('T5_rss_growth_mb'), '≤50', 'FAIL'))
cmp_max('6 内存', 'MapTileCache.tile ms', bm.get('T6_map_tile_ms'), cm.get('T6_map_tile_ms'), tol_pct=20.0)
cmp_max('6 内存', '首帧加载 ms', bm.get('T4_first_frame_load_ms'), cm.get('T4_first_frame_load_ms'), tol_pct=20.0)
# ⚠️ 同 error 数：判据必须是「**不得新增**」而非「不得有」。
#    基线里本来就有 ❌（例如 T5b 的已知问题）时，自比必须 PASS，
#    否则门禁会「喊狼来了」—— 一个总报红的门禁没人会看。
_bm_fail, _cm_fail = bool(bm.get('has_fail_marker')), bool(cm.get('has_fail_marker'))
rows.append(('6 内存', 'map-selftest 失败标记', _bm_fail, _cm_fail, '不得新增',
             'FAIL' if (_cm_fail and not _bm_fail) else 'PASS'))

# ── 7. 工程化 ────────────────────────────────────────────────────────────
be, ce = D.get('engineering', {}), DC.get('engineering', {})
rows.append(('7 工程化', 'unhandled 警告', be.get('unhandled_lines'), ce.get('unhandled_lines'),
             '=0', 'PASS' if ce.get('unhandled_lines') == 0 else 'FAIL'))
cmp_max('7 工程化', '编译警告数', be.get('warning_count'), ce.get('warning_count'), tol_pct=0.0, tol_abs=0)
# ⚠️ 不能要求 error 恒为 0：别的 agent 在途代码会让它非 0，
#    那与「本次改动是否劣化」无关。判据是**不增加**（自比必须 PASS）。
cmp_max('7 工程化', 'error 数', be.get('error_count'), ce.get('error_count'), tol_pct=0.0, tol_abs=0)
rows.append(('7 工程化', 'check-package-sources', be.get('check_package_sources_ok'), ce.get('check_package_sources_ok'),
             '通过', 'PASS' if ce.get('check_package_sources_ok') else 'FAIL'))

# ── 负载可信度提示 ───────────────────────────────────────────────────────
lb, lc = base.get('load', {}), cur.get('load', {})
unreliable = lb.get('timing_unreliable') or lc.get('timing_unreliable')

# ── 输出 ─────────────────────────────────────────────────────────────────
W = 34
print('=' * 100)
print('  七维度「零劣化」门禁')
print('=' * 100)
print(f"  基线：{base.get('label')}  ({base.get('timestamp')})  负载 {lb.get('load1')}/{lb.get('ncpu')} = {lb.get('oversub')}×")
print(f"  当前：{cur.get('label')}  ({cur.get('timestamp')})  负载 {lc.get('load1')}/{lc.get('ncpu')} = {lc.get('oversub')}×")
if unreliable:
    print()
    print('  ⚠️⚠️  有一侧负载超过核数 1.5 倍 —— **耗时类结论不可信**，请空载重跑。')
    print('        （本门禁仍会给出结论，但耗时项的 FAIL 可能是假红灯）')
print('-' * 100)
print(f"  {'维度':<12} {'指标':<{W}} {'基线':>12} {'当前':>12}  {'判据':<18} 结论")
print('-' * 100)
last_dim = None
for dim, name, b, c, crit, verdict in rows:
    d = dim if dim != last_dim else ''
    last_dim = dim
    mark = {'PASS': '✅', 'FAIL': '❌', 'WARN': '⚠️', 'SKIP': '–'}[verdict]
    bs = '—' if b is None else str(b)[:12]
    cs = '—' if c is None else str(c)[:12]
    print(f"  {d:<12} {name[:W]:<{W}} {bs:>12} {cs:>12}  {crit[:18]:<18} {mark} {verdict}")
print('-' * 100)

fails = [r for r in rows if r[5] == 'FAIL']
warns = [r for r in rows if r[5] == 'WARN']
skips = [r for r in rows if r[5] == 'SKIP']

print()
print(f"  合计 {len(rows)} 项：✅ {len(rows)-len(fails)-len(warns)-len(skips)} 通过 / ❌ {len(fails)} 劣化 / ⚠️ {len(warns)} 警告 / – {len(skips)} 缺失")
if fails:
    print()
    print('  ❌ 劣化清单：')
    for dim, name, b, c, crit, _ in fails:
        print(f'     · [{dim}] {name}：{b} → {c}（判据 {crit}）')
if skips:
    print()
    print('  – 缺失项（基线或当前快照里没有该指标，通常是自检输出格式变了）：')
    for dim, name, b, c, crit, _ in skips[:10]:
        print(f'     · [{dim}] {name}')
print()
if fails:
    print('  ❌ 门禁不通过 —— 有人降质了，或测量环境不可比。')
    sys.exit(1)
print('  ✅ 七维度全部通过：没有降频率 / 画质 / 输出频率 / 线程数 / 模型质量 / 帧率 / 工程化程度。')
sys.exit(0)
PY
