#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 V5 图 + POI 导成浏览器可直接寻路的格式（前端跑 A*）"""
import json, os
G='tools/roadnet/v5_graph.json'; W='tools/roadnet/web'
d=json.load(open(G))
# 图：精简字段
gj={'meta':d['meta'],
    'nodes':[[n['id'],n['x'],n['y']] for n in d['nodes']],
    'edges':[[e['a'],e['b'],round(e['len_m'],1),e['poly']] for e in d['edges']]}
open(f'{W}/route_graph.json','w').write(json.dumps(gj,separators=(',',':')))
print('route_graph.json %.0f KB'%(os.path.getsize(f'{W}/route_graph.json')/1024))
# POI
pois=json.load(open('/tmp/poi_13056.json'))
simple=[{'x':round(p['x'],1),'y':round(p['y'],1),'n':p['n'],'t':p.get('t','')} for p in pois]
open(f'{W}/poi.json','w').write(json.dumps(simple,ensure_ascii=False,separators=(',',':')))
print('poi.json %.0f KB  共 %d 个'%(os.path.getsize(f'{W}/poi.json')/1024,len(simple)))
from collections import Counter
print('  类型:',dict(Counter(p['t'] for p in simple).most_common(10)))
