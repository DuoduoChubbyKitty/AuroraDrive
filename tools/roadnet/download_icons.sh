#!/usr/bin/env bash
# ============================================================================
#  download_icons.sh — 下载地图标记图标 → models/map_icons/
# ============================================================================
#
#  为什么要落盘这个脚本，而不是「跑一次就好」：
#    图标是**外部资源**，服务器可能改版/下线。脚本留档 + 计数校验，
#    将来任何人在任何时候都能复现这份图标集，而不是"不知道哪来的 149 个文件"。
#
#  ── 为什么用 curl 而不是 python urllib ────────────────────────────────────
#   实测 urllib 直接报 `SSL: CERTIFICATE_VERIFY_FAILED`（本地缺 CA 根证书），
#    而 curl 走系统钥匙串证书链正常 200。这不是网站的问题，是 Python 环境问题。
#
#  ── 为什么不打包 maante 的瓦片 ────────────────────────────────────────────
#   实测 maante 底图与我们的 bigworldmap-13056 是**同一份影像**
#   （256² 上采样 vs 512² 瓦片相关系数 0.9901）。它的 3516 张瓦片 / 28.4 MB
#   唯一价值是省内存，与本次目标无关。而图标只有 596 KB。
#
#  用法：
#    tools/roadnet/download_icons.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUTDIR="$ROOT/models/map_icons"
SRC="$ROOT/models/FINAL_complete_map_database.json"
BASE="https://nteguide.com/images/map/icons"

# ── 取唯一 icon 名（用系统 python3，只是 json 解析，不需要 cv2）──
PY=""
for c in "$ROOT/tools/ayolom/.venv/bin/python" python3; do
  if [ -x "$(command -v "$c" 2>/dev/null || echo "$c")" ] && "$c" -c "import json" 2>/dev/null; then
    PY="$c"; break
  fi
done
if [ -z "$PY" ]; then
  echo "✗ 找不到可用的 python" >&2; exit 1
fi

if [ ! -f "$SRC" ]; then
  echo "✗ 找不到源数据：$SRC" >&2; exit 1
fi

mkdir -p "$OUTDIR"

NAMES_FILE="$(mktemp -t icons)"
"$PY" - "$SRC" <<'PYEOF' > "$NAMES_FILE"
import json, sys
db = json.load(open(sys.argv[1], encoding="utf-8"))
seen, out = set(), []
for m in db.get("markers_all", []):
    b = (m.get("icon") or "").split("/")[-1].split(".")[0]
    if b and b not in seen:
        seen.add(b); out.append(b)
print("\n".join(out))
PYEOF

TOTAL=$(grep -c . "$NAMES_FILE" || true)
echo "═══ 下载地图图标 ═══"
echo "  唯一图标 $TOTAL 个 → $OUTDIR"

ok=0; bad=0; skip=0
# 缺失清单写到临时文件 —— **不能写在 models/ 里**：那是数据目录，
# 混入一个 _missing.txt 会让人误以为它是数据的一部分。
MISSING="$(mktemp -t icons_missing)"
: > "$MISSING"
while IFS= read -r name; do
  [ -z "$name" ] && continue
  dest="$OUTDIR/$name.webp"
  # 已存在且非空 → 跳过（幂等，重跑不重复下载）
  if [ -s "$dest" ]; then skip=$((skip+1)); continue; fi
  code=$(curl -s -o "$dest" -w "%{http_code}" --max-time 15 "$BASE/$name.webp" 2>/dev/null || echo 000)
  sz=$(stat -f%z "$dest" 2>/dev/null || echo 0)
  if [ "$code" = "200" ] && [ "$sz" -gt 200 ]; then
    ok=$((ok+1))
  else
    bad=$((bad+1)); echo "$name" >> "$MISSING"; rm -f "$dest"
  fi
done < "$NAMES_FILE"
rm -f "$NAMES_FILE"

# ── 统计（含之前已存在的）──
have=$(find "$OUTDIR" -name '*.webp' -size +200c 2>/dev/null | wc -l | tr -d ' ')
total_bytes=$(du -sk "$OUTDIR" 2>/dev/null | awk '{print $1}')
echo
echo "  本次新下 $ok · 已存在跳过 $skip · 失败 $bad"
echo "  目录现有 $have 个 webp，合计 ${total_bytes} KB"

if [ -s "$MISSING" ]; then
  echo "  ⚠️ 缺图标（这些标记将回落默认圆点）："
  sed 's/^/      /' "$MISSING"
  rm -f "$MISSING"
else
  rm -f "$MISSING"
  echo "  ✓ 全部图标就位"
fi

# 期望：152 个唯一图标，实测 150 成功 / 2 缺失（YH_UI_Mapicon_109、icon-poi，
# 共影响 7 个标记）。低于 145 视为源站/网络异常。
if [ "$have" -lt 145 ]; then
  echo "  ✗ 图标数偏少（现有 $have），检查网络或源站" >&2
  exit 1
fi
rm -f "$OUTDIR/_missing.txt"
echo "✓ 完成"
