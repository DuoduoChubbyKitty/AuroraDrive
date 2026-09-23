#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MaaNTE ROI 空间适配器 —— 把 1280x720 基准的 ROI 换算到 macOS 实际截图空间

背景
----
MaaNTE 的模板与 ROI 建立在 1280x720（720p）基准上。Windows 上它靠
`Common/ResizeGameWindow.json` 把游戏窗口强制设成 1280x720 来保证一致。

macOS 端窗口由系统决定（例：1470x923），不能改。实测结论：
  - UI 按【宽度】等比缩放：实测元素缩放比 1.16 ≈ 1470/1280 = 1.148
  - 因此把截图 LongSide 缩到 1280 后，模板尺寸精确对上（匹配分数 0.72~0.79）
  - 但高度变成 1280x803，比基准多出 83px
  - 顶部锚定的 UI 位置不变；底部锚定的 UI 下移 83px

本脚本不改 MaaNTE 原始资源，而是生成 MaaTaskerPostTask 的 pipeline_override，
把 ROI 的下边界扩展 dy，从而同时覆盖「顶部锚定」与「底部锚定」两种情况。

override 格式已由 MaaFramework 官方示例确认：
    {"节点名": {"roi": [x, y, w, h]}}
"""

import json
import re
import os
import sys
import argparse
from collections import OrderedDict

# ---------------------------------------------------------------- JSONC 解析

def strip_jsonc(text: str) -> str:
    """去掉 // 与 /* */ 注释，但不动字符串内部的字符。"""
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == '/' and i + 1 < n:
            if text[i + 1] == '/':
                while i < n and text[i] != '\n':
                    i += 1
                continue
            if text[i + 1] == '*':
                i += 2
                while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                    i += 1
                i += 2
                continue
        out.append(c)
        i += 1
    return ''.join(out)


def load_pipeline(path: str):
    """解析单个 pipeline 文件，容忍 JSONC 与空值。"""
    raw = open(path, encoding='utf-8').read()
    txt = strip_jsonc(raw)
    # 容忍尾随逗号
    txt = re.sub(r',(\s*[}\]])', r'\1', txt)
    try:
        return json.loads(txt)
    except json.JSONDecodeError:
        return None


# ---------------------------------------------------------------- 提取节点

ROI_KEYS = ('roi',)

def find_roi(node: dict):
    """从节点里找 roi，兼容 Pipeline v1（顶层）与 v2（recognition.param）。"""
    if not isinstance(node, dict):
        return None
    # v1
    r = node.get('roi')
    if isinstance(r, list) and len(r) == 4 and all(isinstance(v, (int, float)) for v in r):
        return r
    # v2
    rec = node.get('recognition')
    if isinstance(rec, dict):
        param = rec.get('param')
        if isinstance(param, dict):
            r = param.get('roi')
            if isinstance(r, list) and len(r) == 4 and all(isinstance(v, (int, float)) for v in r):
                return r
    return None


def roi_container(node: dict):
    """返回 roi 所在字典的引用，便于原地改写。"""
    if isinstance(node.get('roi'), list):
        return node
    rec = node.get('recognition')
    if isinstance(rec, dict):
        param = rec.get('param')
        if isinstance(param, dict) and isinstance(param.get('roi'), list):
            return param
    return None


def has_visual_reco(node: dict) -> bool:
    """判断节点是否依赖画面识别（TemplateMatch / OCR / FeatureMatch 等）。"""
    if not isinstance(node, dict):
        return False
    t = node.get('recognition')
    if isinstance(t, dict):
        t = t.get('type')
    if t is None:
        t = node.get('reco_type')
    if not isinstance(t, str):
        return True  # 未声明类型时默认按 TemplateMatch
    return t not in ('DirectHit',)


def collect(pipeline_dir: str):
    """扫描全部 pipeline，返回 [(文件, 节点名, roi, 模板/识别信息), ...]"""
    found = []
    for root, _, files in os.walk(pipeline_dir):
        for fn in sorted(files):
            if not fn.endswith('.json'):
                continue
            p = os.path.join(root, fn)
            data = load_pipeline(p)
            if not isinstance(data, dict):
                continue
            for node_name, node in data.items():
                if not isinstance(node, dict) or node_name.startswith('$'):
                    continue
                roi = find_roi(node)
                if roi is None:
                    continue
                if not has_visual_reco(node):
                    continue
                tpl = node.get('template')
                if tpl is None:
                    rec = node.get('recognition')
                    if isinstance(rec, dict) and isinstance(rec.get('param'), dict):
                        tpl = rec['param'].get('template')
                found.append((os.path.relpath(p, pipeline_dir), node_name, roi, tpl))
    return found


# ---------------------------------------------------------------- 生成 override

def build_override(pipeline_dir: str, dy: int, mode: str = 'expand'):
    """
    生成 pipeline_override 字典。

    mode='expand'  : roi 高度 + dy（同时覆盖顶部/底部锚定，最稳）
    mode='shift'   : roi 的 y + dy（只按底部锚定处理）
    """
    items = collect(pipeline_dir)
    override = OrderedDict()
    for f, name, roi, tpl in items:
        x, y, w, h = [int(v) for v in roi]
        if mode == 'expand':
            new = [x, y, w, h + dy]
        elif mode == 'shift':
            new = [x, y + dy, w, h]
        else:
            raise ValueError(f'未知 mode: {mode}')
        override[name] = {'roi': new}
    return override, items


# ---------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description='MaaNTE ROI 空间适配器')
    ap.add_argument('--pipeline', default='MaaNTE/assets/resource/base/pipeline',
                    help='pipeline 目录')
    ap.add_argument('--base-height', type=int, default=720, help='MaaNTE 基准高度')
    ap.add_argument('--live-height', type=int, default=803,
                    help='实际截图高度（LongSide 缩到 1280 后的高度）')
    ap.add_argument('--mode', choices=['expand', 'shift'], default='expand')
    ap.add_argument('--out', default='build/maa_pipeline_override.json',
                    help='override JSON 输出路径')
    ap.add_argument('--dry-run', action='store_true', help='只统计不写文件')
    args = ap.parse_args()

    dy = args.live_height - args.base_height
    if dy <= 0:
        print(f'[!] live_height({args.live_height}) <= base_height({args.base_height})，无需偏移')
        return 0

    override, items = build_override(args.pipeline, dy, args.mode)

    print(f'基准空间      : 1280x{args.base_height}')
    print(f'实际截图空间  : 1280x{args.live_height}')
    print(f'高度差 dy     : {dy}px')
    print(f'模式          : {args.mode}'
          f'  ({"ROI 高度 +dy，覆盖两种锚定" if args.mode=="expand" else "ROI 整体下移 dy"})')
    print(f'扫描到 ROI 节点: {len(items)} 个')
    print(f'生成 override  : {len(override)} 条')
    print()

    # 按 ROI 底边位置分类，看看有多少真正受影响
    top = bottom = 0
    for _, _, roi, _ in items:
        if int(roi[1]) + int(roi[3]) > 640:
            bottom += 1
        else:
            top += 1
    print(f'  底边 <= 640（顶部/中部锚定，偏移无影响）: {top} 个')
    print(f'  底边 >  640（底部锚定区，偏移生效）    : {bottom} 个')
    print()

    if args.dry_run:
        print('[dry-run] 未写文件')
        return 0

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(override, f, ensure_ascii=False, indent=2)
    print(f'已写入: {args.out}  ({os.path.getsize(args.out)} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
