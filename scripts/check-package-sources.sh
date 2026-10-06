#!/bin/bash
# ============================================================================
#  check-package-sources.sh —— 校验 Package.swift 的 target 划分与磁盘实际一致
# ============================================================================
#
#  【为什么需要这个脚本】
#  `Package.swift` 的主 target 用 `path: "."`，源码由 `sources:` 声明。
#  历史上这里是**逐文件手工白名单**，于是有两类反复踩的坑：
#    · 新增 .swift 忘了登记 → `cannot find 'Xxx' in scope`（编译期才炸）
#    · 删除 .swift 忘了注销 → 同上
#  2026-10-04（P5-A7）已把 `sources:` 改成**目录级**，新文件自动纳入，
#  但下面这些仍然只能靠脚本守：
#    · `Sources/` 下出现不属于任何 target 的孤儿 .swift
#    · `Sources/AuroraDrive/` 下混进非 .swift 文件（会变成 unhandled 警告）
#    · 仓库顶层新增目录/文件后忘了加进 `exclude`（会变成 unhandled 警告，
#      而且 SwiftPM 会去遍历整个仓库根，拖慢每一次构建）
#
#  【用法】
#    bash scripts/check-package-sources.sh              # 校验，0=一致 1=有差异
#    bash scripts/check-package-sources.sh --gen-exclude # 打印重新生成的 exclude 块
#
#  【注意】本机 bash 是 3.2，不支持关联数组（declare -A）—— 故逻辑用 python3 写。
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

python3 - "$@" <<'PY'
import json, os, re, subprocess, sys

ROOT = os.getcwd()
GEN_EXCLUDE = '--gen-exclude' in sys.argv
MANIFEST = 'Package.swift'

# ── 1. 解析 Package.swift：取出每个 target 的 name / path / sources / exclude ──
def match_bracket(text, open_idx, op='[', cl=']'):
    """从 open_idx 处的括号开始做配对，返回闭括号下标。"""
    depth = 0
    i = open_idx
    while i < len(text):
        if text[i] == op:
            depth += 1
        elif text[i] == cl:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError(f'括号不配对 @ {open_idx}')

def parse_manifest(path):
    src = open(path, encoding='utf-8').read()
    targets = []
    # 逐个 .target( / .executableTarget( 声明
    for m in re.finditer(r'\.(?:executable)?[Tt]arget\(', src):
        head = m.end()
        # 该 target 声明块的结束：下一个同级声明或文件末尾，用括号配对求
        depth = 1
        i = head
        while i < len(src) and depth:
            if src[i] == '(':
                depth += 1
            elif src[i] == ')':
                depth -= 1
            i += 1
        block = src[head:i]
        name = re.search(r'name:\s*"([^"]+)"', block)
        tpath = re.search(r'\bpath:\s*"([^"]+)"', block)
        def arr(key):
            mm = re.search(rf'\b{key}:\s*\[', block)
            if not mm:
                return []
            ob = block.index('[', mm.start())
            cb = match_bracket(block, ob)
            return re.findall(r'"([^"]+)"', block[ob:cb])
        targets.append({
            'name': name.group(1) if name else '?',
            'path': tpath.group(1) if tpath else None,
            'sources': arr('sources'),
            'exclude': arr('exclude'),
        })
    return targets

try:
    targets = parse_manifest(MANIFEST)
except Exception as e:
    print(f'❌ 解析 {MANIFEST} 失败：{e}')
    sys.exit(2)

if not targets:
    print(f'❌ 未能从 {MANIFEST} 解析出任何 target')
    sys.exit(2)

# ── 2. 用 SwiftPM 自己的视角拿「实际参与编译的源文件」（权威） ──
try:
    out = subprocess.run(['swift', 'package', 'describe', '--type', 'json'],
                         capture_output=True, text=True, timeout=300)
    described = {t['name']: t for t in json.loads(out.stdout)['targets']}
except Exception as e:
    print(f'❌ swift package describe 失败：{e}')
    print(out.stderr[:800] if 'out' in dir() else '')
    sys.exit(2)

# ── 3. 磁盘扫描 ──
SKIP_DIRS = {'.build', 'build', '.git', '.swiftpm', '__pycache__'}
def walk_swift(top):
    found = []
    for r, ds, fs in os.walk(top):
        ds[:] = [d for d in ds if d not in SKIP_DIRS]
        for f in fs:
            if f.endswith('.swift'):
                found.append(os.path.relpath(os.path.join(r, f), ROOT))
    return sorted(found)

def walk_nonswift(top):
    found = []
    for r, ds, fs in os.walk(top):
        ds[:] = [d for d in ds if d not in SKIP_DIRS]
        for f in fs:
            if not f.endswith('.swift'):
                found.append(os.path.relpath(os.path.join(r, f), ROOT))
    return sorted(found)

errors, warns = [], []

# ── 检查 1：每个 target 声明的 sources 路径必须存在 ──
for t in targets:
    for s in t['sources']:
        base = os.path.normpath(os.path.join(t['path'] or '.', s))
        if not os.path.exists(base):
            errors.append(f"[{t['name']}] sources 指向的路径不存在：{s}  (解析为 {base})")

# ── 检查 2/3/4：SwiftPM 实际编译的文件集合 ──
compiled = set()
for name, d in described.items():
    for s in d.get('sources', []):
        compiled.add(os.path.normpath(os.path.join(d.get('path', '.'), s)))

# 2：Sources/AuroraDrive 下每个 .swift 都必须被编译
for f in walk_swift('Sources/AuroraDrive'):
    if os.path.normpath(f) not in compiled:
        errors.append(f'[漏登记] {f} 不在任何 target 的 sources 里 → 会报 cannot find ... in scope')

# 3：Sources/ 下的孤儿 .swift（不属于任何 target）
for f in walk_swift('Sources'):
    if os.path.normpath(f) not in compiled:
        errors.append(f'[孤儿文件] {f} 位于 Sources/ 但不属于任何 target')

# 4：声明的 sources 里每个 .swift 都必须在磁盘上
for name, d in described.items():
    for s in d.get('sources', []):
        p = os.path.normpath(os.path.join(d.get('path', '.'), s))
        if not os.path.isfile(p):
            errors.append(f"[{name}] sources 里的 {s} 在磁盘上不存在")

# ── 检查 5/6：unhandled 完整性（Sources/AuroraDrive 非源码 + 顶层条目须在 exclude 里） ──
aurora = next((t for t in targets if t['name'] == 'AuroraDrive'), None)
if aurora is None:
    errors.append('未找到名为 AuroraDrive 的 target')
else:
    exc = set(aurora['exclude'])
    for f in walk_nonswift('Sources/AuroraDrive'):
        if f not in exc:
            errors.append(f'[unhandled] {f} 既非源码也不在 exclude 里 → 会产生 unhandled 警告')

    KEEP_TOP = {'Sources', 'Vendor', 'Package.swift'}
    for e in sorted(os.listdir('.')):
        if e in KEEP_TOP:
            continue
        if e not in exc:
            errors.append(f'[unhandled] 顶层条目 {e} 不在 exclude 里 → SwiftPM 会遍历它并报警告')

    # Vendor 下未编译的 .swift（提示性质，不算错）
    vendored = [f for f in walk_swift('Vendor') if os.path.normpath(f) not in compiled]
    if vendored:
        warns.append(f'Vendor/ 下 {len(vendored)} 个 .swift 刻意不参与编译（MetalGoose 根层等）：'
                     + ', '.join(vendored[:5]) + (' …' if len(vendored) > 5 else ''))

# ── --gen-exclude：重新生成 exclude 块 ──
if GEN_EXCLUDE:
    items = []
    for e in sorted(os.listdir('.')):
        if e not in ('Sources', 'Vendor', 'Package.swift'):
            items.append(e)
    for e in sorted(os.listdir('Sources')):
        if e != 'AuroraDrive':
            items.append(f'Sources/{e}')
    for e in sorted(os.listdir('Vendor')):
        if e != 'MetalGoose':
            items.append(f'Vendor/{e}')
    for e in sorted(os.listdir('Vendor/MetalGoose')):
        if e != 'Engine':
            items.append(f'Vendor/MetalGoose/{e}')
    for e in sorted(os.listdir('Vendor/MetalGoose/Engine')):
        if not e.endswith('.swift'):
            items.append(f'Vendor/MetalGoose/Engine/{e}')
    items += walk_nonswift('Sources/AuroraDrive')
    print('            exclude: [')
    for x in items:
        print(f'                "{x}",')
    print('            ],')
    sys.exit(0)

# ── 输出 ──
print('=' * 68)
print('  Package.swift ↔ 磁盘 一致性校验')
print('=' * 68)
print(f'  target 数：{len(targets)}   实际编译源文件：{len(compiled)} 个')
for t in targets:
    d = described.get(t['name'], {})
    print(f"    · {t['name']:<24} path={t['path'] or '.':<28} 源文件 {len(d.get('sources', [])):>3} 个")
print()

if warns:
    for w in warns:
        print(f'  ⚠️  {w}')
    print()

if errors:
    print(f'  ❌ 发现 {len(errors)} 个不一致：')
    for e in errors:
        print(f'     · {e}')
    print()
    print('  提示：顶层/非源码条目缺失可用 `bash scripts/check-package-sources.sh --gen-exclude`')
    print('        重新生成 exclude 块后贴回 Package.swift。')
    sys.exit(1)

print('  ✅ 全部一致：sources 与磁盘相符，无孤儿文件，exclude 覆盖完整（不会有 unhandled 警告）')
sys.exit(0)
PY
