#!/usr/bin/env python3
"""用游戏官方本地化文本验证所有 OCR 节点的 expected 是否真实存在。

四种匹配强度：
  strong  —— 正则 fullmatch / 模板占位符填充后匹配 / 完整句精确命中
  medium  —— 完整句片段（子串）命中
  weak    —— 宽泛正则 search 命中远长文本（假阳性风险）
  none    —— 未命中

关键设计（v2 修正）：
  ① 模板化匹配：游戏文案含 {0}/{1}/%s 占位符，替换为数字后再匹配正则
  ② 动态模板不可静态验证 -> unknown，而非 absent
  ③ 短正则命中超长文本 -> weak，避免假阳性升级
  ④ 多语言 key 对齐：>=2 种语言的 expected 命中同一 key -> 提升为 strong

输出 build/route1_i18n_verify.json
"""
import json, re, os, sys
from collections import defaultdict

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
EX = f'{ROOT}/build/ExtractForNTE/HT/Content/Localization/Game'

LANGS = [('zh-Hans', 'Game.json'), ('zh-CN', 'game.json'),
         ('zh-Hant', 'Game.json'), ('en', 'game.json'),
         ('ja', 'game.json'), ('ko', 'Game.json')]

def load_all():
    entries = []
    for lang, fn in LANGS:
        p = f'{EX}/{lang}/{fn}'
        if not os.path.exists(p):
            continue
        d = json.load(open(p, encoding='utf-8'))
        for ns, items in d.items():
            if not isinstance(items, dict):
                continue
            for k, v in items.items():
                if isinstance(v, str) and v.strip():
                    entries.append((lang, v, f'{ns}.{k}', v.lower()))
    return entries

PLACEHOLDER = re.compile(r'\{[0-9]+\}|%[sdfM]|%[0-9]+\$[s]')
DYNAMIC_RE = re.compile(r'\\d|\{[0-9]+\}|%[sdfM]')

def fill_template(raw):
    s = PLACEHOLDER.sub('5', raw)
    return s

def literal_of(pat, all_text):
    """取正则里的字面锚点（最长的中英文片段）"""
    lits = re.findall(r'[\u4e00-\u9fff]{2,}|[A-Za-z]{3,}', pat)
    if not lits:
        return None
    # 用全库出现次数最少的那个（最有区分度）
    lits.sort(key=lambda s: (all_text.lower().count(s.lower()), -len(s)))
    return lits[0]

def compile_pat(p):
    try:
        return re.compile(p)
    except re.error:
        return re.compile(re.escape(p))

def main():
    entries = load_all()
    print(f'加载 {len(entries)} 条本地化文本（{len(LANGS)} 种语言）', flush=True)
    alltext = '\n'.join(v for _, v, _, _ in entries)

    nodes = json.load(open(f'{ROOT}/build/nodes_inventory.json'))
    targets = {k: v for k, v in nodes.items()
               if v.get('type') == 'OCR' and v.get('expected')}
    print(f'OCR 节点 {len(targets)}', flush=True)

    out = {}
    for name, v in targets.items():
        exps = v['expected'] if isinstance(v['expected'], list) else [v['expected']]
        exps = [e for e in exps if isinstance(e, str)]
        detail = {}
        for e in exps:
            pat = compile_pat(e)
            lit = literal_of(e, alltext)
            full, tmpl, search = [], [], []
            for lang, raw, key, low in entries:
                if lit and lit.lower() not in low and '{' not in raw:
                    continue
                if pat.fullmatch(raw):
                    full.append((raw, lang, key))
                    if len(full) >= 3:
                        break
                elif PLACEHOLDER.search(raw):
                    f = fill_template(raw)
                    if pat.fullmatch(f) or pat.search(f):
                        tmpl.append((raw, lang, key))
                        if len(tmpl) >= 3:
                            break
                elif pat.search(raw) and len(search) < 6:
                    search.append((raw, lang, key))

            if full:
                strength, kind, hits = 'strong', 'fullmatch', full[:3]
            elif tmpl:
                strength, kind, hits = 'strong', 'dynamic-template', tmpl[:3]
            elif search:
                # 短正则命中超长文本 -> weak
                shortest = min(search, key=lambda x: len(x[0]))
                extra = len(shortest[0]) - len(lit or '')
                if len(lit or '') >= 3 and extra <= 12:
                    strength, kind, hits = 'medium', 'substring', [shortest]
                else:
                    strength, kind, hits = 'weak', 'loose-search', [shortest]
            else:
                dyn = bool(DYNAMIC_RE.search(e))
                strength, kind, hits = ('none', 'dynamic-not-applicable' if dyn else 'absent'), [], []

            detail[e] = {
                'strength': strength, 'match_kind': kind,
                'hits': [{'text': h[0][:60], 'lang': h[1], 'key': h[2]} for h in hits],
                'dynamic': bool(DYNAMIC_RE.search(e)),
            }

        # ④ 多语言 key 对齐提升
        key_langs = defaultdict(set)
        for e, d in detail.items():
            for h in d['hits']:
                key_langs[h['key']].add(h['lang'])
        for k, langs in key_langs.items():
            if len(langs) >= 2:
                for e, d in detail.items():
                    if any(h['key'] == k for h in d['hits']) and d['strength'] in ('medium', 'weak'):
                        d['strength'] = 'strong'
                        d['match_kind'] += '+key-aligned'

        st = [d['strength'] for d in detail.values()]
        if 'strong' in st:
            verdict = 'confirmed'
        elif 'medium' in st:
            verdict = 'likely'
        elif 'weak' in st:
            verdict = 'unknown'
        elif any(d['dynamic'] for d in detail.values()):
            verdict = 'unknown'
        else:
            verdict = 'absent'

        out[name] = {'expected': exps, 'detail': detail, 'verdict': verdict,
                     'roi': v.get('roi'), 'file': v.get('file')}

    json.dump({'source': 'Abino01/ExtractForNTE', 'langs': [l for l, _ in LANGS],
               'texts': len(entries), 'nodes': out},
              open(f'{ROOT}/build/route1_i18n_verify.json', 'w'),
              ensure_ascii=False, indent=1)

    c = defaultdict(int)
    for d in out.values():
        c[d['verdict']] += 1
    print('\n═══ 全部 OCR 节点 expected 验证 ═══')
    for k in ['confirmed', 'likely', 'unknown', 'absent']:
        print(f'  {k:10s} {c.get(k,0)}')

    abs_nodes = [n for n, d in out.items() if d['verdict'] == 'absent']
    print(f'\n═══ absent {len(abs_nodes)} 个（真问题）═══')
    for n in abs_nodes:
        d = out[n]
        print(f"  {n[:46]:<48s} {d['expected'][0][:34]!r}  [{d['file']}]")

    unk = [n for n, d in out.items() if d['verdict'] == 'unknown']
    print(f'\n═══ unknown {len(unk)} 个（多为动态模板/宽正则）═══')
    for n in unk[:14]:
        kinds = {d['match_kind'] for d in out[n]['detail'].values()}
        print(f"  {n[:46]:<48s} {out[n]['expected'][0][:26]!r}  {kinds}")


if __name__ == '__main__':
    main()
