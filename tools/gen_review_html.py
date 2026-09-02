#!/usr/bin/env python3
import csv, base64, io
from PIL import Image
from pathlib import Path

crops_dir = Path("data/speed_crops_v2")
rows = list(csv.DictReader(open("/tmp/speed_labels.csv")))

parts = ['<!DOCTYPE html><html><head><meta charset="utf-8">']
parts.append('<style>')
parts.append('body{font-family:sans-serif;background:#1a1a1a;color:#eee;margin:20px}')
parts.append('table{border-collapse:collapse;width:100%}')
parts.append('th{background:#333;padding:8px;text-align:left;position:sticky;top:0;z-index:1}')
parts.append('td{padding:6px 12px;border-bottom:1px solid #333}')
parts.append('tr:hover{background:#222}')
parts.append('img{border:1px solid #555;image-rendering:pixelated;width:150px;height:53px}')
parts.append('.fn{font-family:monospace;font-size:13px}')
parts.append('.ocr{font-size:18px;font-weight:bold;color:#0ff;min-width:80px;text-align:center}')
parts.append('.err{color:#f55}')
parts.append('.empty{color:#888}')
parts.append('</style></head><body>')
parts.append('<h2>速度表标注审查 (共{}张)</h2>'.format(len(rows)))
parts.append('<table><tr><th>文件名</th><th>截图(放大3倍)</th><th>OCR结果</th><th>你的修正</th></tr>')

for r in rows:
    fname = r.get("\xef\xbb\xbf\xe6\x96\x87\xe4\xbb\xb6\xe5\x90\x8d","") or r.get("文件名","") or r.get("filename","")
    ocr_val = r.get("速度(km/h)","").strip()
    if not ocr_val:
        ocr_val = r.get("speed","").strip()
    
    img_path = crops_dir / fname
    if img_path.exists():
        img = Image.open(img_path)
        img = img.resize((img.width*3, img.height*3), Image.NEAREST)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        img_b64 = base64.b64encode(buf.getvalue()).decode()
        img_tag = '<img src="data:image/png;base64,{}">'.format(img_b64)
    else:
        img_tag = "(missing)"
    
    if not ocr_val:
        cls = "empty"
        display = "—"
    elif ocr_val.isdigit() and int(ocr_val) <= 300:
        cls = "ocr"
        display = ocr_val
    else:
        cls = "err"
        display = "?{}".format(ocr_val)
    
    parts.append('<tr><td class="fn">{}</td><td>{}</td><td class="{}">{}</td><td><input type="text" size="6"></td></tr>'.format(fname, img_tag, cls, display))

parts.append('</table></body></html>')

out = Path.home()/"Desktop"/"速度审查表.html"
out.write_text("".join(parts), encoding="utf-8")
print("生成: {}".format(out))
