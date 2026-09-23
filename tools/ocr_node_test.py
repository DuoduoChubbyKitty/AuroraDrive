#!/usr/bin/env python3
"""OCR 节点全量测试（正确的两段式 det→rec 管线）。

修正了之前的三个错误：
  1. 缺 det 阶段 —— 整块 ROI 直接喂 rec 会返回空串
  2. 检测框未外扩 —— rec 需要 2px padding
  3. 缩放用 INTER_LINEAR —— 应为 INTER_CUBIC

策略：每张样本只跑一次 det+rec 并缓存全部文字+坐标，
      再按节点 ROI 做空间匹配（159 次 ≪ 111×263 次）。

输出 build/ocr_full_test.json
"""
import onnxruntime as ort
import numpy as np
import cv2
import json
import os
import glob
import re
import time

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
OCR = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6'
SUB = 'medium'
CACHE = f'{ROOT}/data/_gray_cache'
TXT_CACHE = f'{ROOT}/build/ocr_text_cache.json'
OUT = f'{ROOT}/build/ocr_full_test.json'
IMG_W, IMG_H = 1280, 832

print(f'加载 {SUB} 模型...', flush=True)
det = ort.InferenceSession(f'{OCR}/{SUB}/det.onnx', providers=['CPUExecutionProvider'])
rec = ort.InferenceSession(f'{OCR}/{SUB}/rec.onnx', providers=['CPUExecutionProvider'])
chars = [l.decode('utf-8').rstrip('\r\n') for l in open(f'{OCR}/{SUB}/keys.txt', 'rb')]
print(f'  字典 {len(chars)} 类', flush=True)


def recog(crop):
    if crop.size == 0 or crop.shape[0] < 4 or crop.shape[1] < 4:
        return '', 0.0
    h, w = crop.shape[:2]
    rw = max(1, int(np.ceil(48 * w / h)))
    im = cv2.resize(crop, (rw, 48), interpolation=cv2.INTER_CUBIC)
    im = im.astype(np.float32).transpose(2, 0, 1)[None]
    im = (im / 255.0 - 0.5) / 0.5
    lg = rec.run(None, {rec.get_inputs()[0].name: im})[0][0]
    idx = lg.argmax(-1); cf = lg.max(-1)
    out, ks, prev = [], [], -1
    for i, k in enumerate(idx):
        if k != prev and k != 0 and 0 <= k - 1 < len(chars):
            out.append(chars[k - 1]); ks.append(cf[i])
        prev = k
    return ''.join(out), (float(np.mean(ks)) if ks else 0.0)


def ocr_image(img):
    """整图 det + rec，返回 [{t,c,x,y,w,h}]"""
    h, w = img.shape[:2]
    nh = (h + 31) // 32 * 32
    nw = (w + 31) // 32 * 32
    r = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_CUBIC)
    x = r.astype(np.float32) / 255.0
    x = (x - np.array([0.485, 0.456, 0.406], np.float32)) / np.array([0.229, 0.224, 0.225], np.float32)
    out = det.run(None, {det.get_inputs()[0].name: x.transpose(2, 0, 1)[None]})[0][0, 0]
    m = (out > 0.3).astype(np.uint8) * 255
    m = cv2.dilate(m, np.ones((3, 3), np.uint8), iterations=2)
    cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    res = []
    for c in cnts:
        bx, by, bw, bh = cv2.boundingRect(c)
        if bw < 6 or bh < 6:
            continue
        bx, by = int(bx * w / nw), int(by * h / nh)
        bw, bh = int(bw * w / nw), int(bh * h / nh)
        y0, y1 = max(0, by - 2), min(h, by + bh + 2)
        x0, x1 = max(0, bx - 2), min(w, bx + bw + 2)
        t, cf = recog(img[y0:y1, x0:x1])
        if t.strip():
            res.append({'t': t, 'c': round(cf, 3), 'x': bx, 'y': by, 'w': bw, 'h': bh})
    return res


def main():
    t0 = time.time()
    if os.path.exists(TXT_CACHE):
        cache = json.load(open(TXT_CACHE))
        print(f'复用文字缓存 {len(cache)} 张', flush=True)
    else:
        shots = sorted(glob.glob(f'{CACHE}/*.png'))
        cache = {}
        for i, p in enumerate(shots):
            img = cv2.imread(p)
            if img is None:
                continue
            cache[os.path.basename(p)] = ocr_image(img)
            if (i + 1) % 10 == 0:
                el = time.time() - t0
                print(f'  OCR {i+1}/{len(shots)}  ({el:.0f}s, 预计 {el/(i+1)*len(shots):.0f}s)', flush=True)
                json.dump(cache, open(TXT_CACHE, 'w'), ensure_ascii=False)
        json.dump(cache, open(TXT_CACHE, 'w'), ensure_ascii=False)
        print(f'文字缓存完成 {len(cache)} 张  {time.time()-t0:.0f}s', flush=True)

    nodes = json.load(open(f'{ROOT}/build/nodes_inventory.json'))
    ov = json.load(open(f'{ROOT}/build/maa_override_all.json'))

    targets = [(k, v) for k, v in nodes.items()
               if v.get('type') == 'OCR' and v.get('expected')
               and isinstance(v.get('roi'), list) and len(v['roi']) == 4]
    print(f'OCR 节点 {len(targets)}', flush=True)

    def in_roi(t, roi):
        cx = t['x'] + t['w'] / 2
        cy = t['y'] + t['h'] / 2
        return (roi[0] <= cx <= roi[0] + roi[2]) and (roi[1] <= cy <= roi[1] + roi[3])

    def collect(roi):
        """把落在 ROI 内的文字按位置排序拼起来"""
        hits = []
        for key, items in cache.items():
            for t in items:
                if in_roi(t, roi):
                    hits.append((t['t'], t['c'], key))
        return hits

    results = {}
    for i, (name, v) in enumerate(targets):
        exps = v['expected']
        if not isinstance(exps, list):
            exps = [exps]
        exps = [e for e in exps if isinstance(e, str)]
        if not exps:
            continue
        new = ov.get(name, {}).get('recognition', {}).get('param', {}).get('roi')
        if not new:
            continue

        def judge(roi):
            best = {'hit': False, 'text': '', 'conf': 0.0, 'pat': None, 'shot': None}
            seen = {}
            for txt, conf, key in collect(roi):
                seen.setdefault(key, []).append(txt)
            for key, txts in seen.items():
                joined = ' '.join(txts)
                for p in exps:
                    try:
                        rx = re.compile(p)
                    except re.error:
                        rx = re.compile(re.escape(p))
                    if rx.search(joined):
                        if not best['hit'] or len(joined) < len(best['text']):
                            best = {'hit': True, 'text': joined, 'conf': 1.0,
                                    'pat': p, 'shot': key}
                        break
                if best['hit']:
                    break
            if not best['hit']:
                # 记录最接近的一条，便于诊断
                allt = [(t, c, k) for k, items in cache.items()
                        for t, c in [(it['t'], it['c']) for it in items] if in_roi(
                            {'x': 0, 'y': 0, 'w': 0, 'h': 0}, roi) or True]
                near = []
                for k, items in cache.items():
                    for it in items:
                        if in_roi(it, roi):
                            near.append(it['t'])
                best['text'] = ' '.join(near[:6])
            return best

        bo = judge(v['roi'])
        bn = judge(new)
        results[name] = {
            'roi_orig': v['roi'], 'roi_new': new, 'expected': exps,
            'orig_hit': bo['hit'], 'orig_text': bo['text'][:80],
            'new_hit': bn['hit'], 'new_text': bn['text'][:80],
            'matched_pat': bn['pat'], 'shot': bn['shot'],
            'verdict': ('both_hit' if bo['hit'] and bn['hit'] else
                        'fixed' if bn['hit'] and not bo['hit'] else
                        'broke' if bo['hit'] and not bn['hit'] else 'miss'),
        }
        if (i + 1) % 20 == 0:
            print(f'  节点 {i+1}/{len(targets)}', flush=True)

    json.dump(results, open(OUT, 'w'), ensure_ascii=False, indent=1)

    v = {}
    for r in results.values():
        v[r['verdict']] = v.get(r['verdict'], 0) + 1
    print('\n═══ 结果 ═══')
    for k, c in sorted(v.items(), key=lambda x: -x[1]):
        print(f'  {k:10s} {c}')
    no = sum(1 for r in results.values() if r['orig_hit'])
    nn = sum(1 for r in results.values() if r['new_hit'])
    print(f'\n原 ROI 命中 {no}/{len(results)}   修正后命中 {nn}/{len(results)}')
    print(f'总耗时 {time.time()-t0:.0f}s -> {OUT}')


if __name__ == '__main__':
    main()
