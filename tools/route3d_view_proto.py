# -*- coding: utf-8 -*-
"""3D 路线导航 —— 干净版：稀疏标记 + 道路带 + 转向提示"""
import json, numpy as np
from PIL import Image, ImageDraw, ImageFont

def font(sz):
    for fp in ['/System/Library/Fonts/PingFang.ttc','/System/Library/Fonts/Hiragino Sans GB.ttc']:
        try: return ImageFont.truetype(fp, sz)
        except: pass
    return ImageFont.load_default()

d=json.load(open('/Users/dupi/Desktop/自动驾驶系统/models/FINAL_complete_map_database.json'))
mk=d['markers_all']; wps=d['waypoints']
cx,cy = wps[10]['x'], wps[10]['y']

# 只取传送点+地标（稀疏、有意义）
near=[m for m in mk if abs(m['x']-cx)<7 and abs(m['y']-cy)<7
      and m.get('type') in ('waypoint','tower','phone_booth')]
print(f"稀疏标记: {len(near)}")

W,H=1280,720; CAM_H,CAM_BACK,FOV=10.0,16.0,58.0
f=(H/2)/np.tan(np.radians(FOV/2))
cam=np.array([cx,cy+CAM_BACK,CAM_H]); tgt=np.array([cx,cy-7.0,1.0])
Fw=tgt-cam; Fw/=np.linalg.norm(Fw); UP=np.array([0,0,1.0])
Rt=np.cross(Fw,UP); Rt/=np.linalg.norm(Rt); Up=np.cross(Rt,Fw)
def proj(p):
    dd=np.asarray(p,float)-cam
    x,y,z=dd@Rt, dd@Fw, dd@Up
    return (W/2+f*x/y, H/2-f*z/y, y) if y>0.3 else None

img=Image.new('RGB',(W,H),(5,8,12)); dr=ImageDraw.Draw(img,'RGBA')

# 天空渐变
for i in range(300):
    t=i/300; dr.line([(0,i),(W,i)], fill=(int(8+22*t),int(14+38*t),int(24+55*t),255))

# 地面网格
for g in np.arange(-7,7.5,0.8):
    for ax in (0,1):
        pts=[]
        for t in np.arange(-7,7,0.35):
            p=proj([cx+g,cy+t,0] if ax==0 else [cx+t,cy+g,0])
            if p: pts.append((p[0],p[1]))
        if len(pts)>1: dr.line(pts, fill=(26,72,100,120), width=1)

# 道路带（宽路，模拟可行驶区域）
road=[(cx+4.5*np.sin(t*2.6)*t, cy-t*9.0) for t in np.linspace(0,1,80)]
L,R_=[],[]
for (rx,ry) in road:
    L.append(proj([rx-1.6,ry,0.02])); R_.append(proj([rx+1.6,ry,0.02]))
band=[p[:2] for p in L if p]+[p[:2] for p in reversed(R_) if p]
if len(band)>3: dr.polygon(band, fill=(20,52,74,150))

# 路线（三层发光）
pts=[proj([x,y,0.15]) for x,y in road]; pts=[(p[0],p[1]) for p in pts if p]
for w,c,a in [(26,(0,190,255),70),(13,(0,229,255),170),(4,(220,255,255),255)]:
    if len(pts)>1: dr.line(pts, fill=(*c,a), width=w, joint='curve')

# 起点终点
s=proj([road[0][0],road[0][1],0.2]); e=proj([road[-1][0],road[-1][1],0.2])
if e:
    dr.ellipse([e[0]-13,e[1]-13,e[0]+13,e[1]+13], outline=(255,90,110,255), width=4)
    dr.ellipse([e[0]-6,e[1]-6,e[0]+6,e[1]+6], fill=(255,90,110,255))

# 稀疏标记
for m in near:
    h=1.8 if m.get('type')=='waypoint' else 1.0
    b=proj([m['x'],m['y'],0]); t=proj([m['x'],m['y'],h])
    if b and t:
        c=(255,178,58,235) if m.get('type')=='waypoint' else (108,235,255,200)
        dr.line([(b[0],b[1]),(t[0],t[1])], fill=c, width=4)
        dr.ellipse([t[0]-6,t[1]-6,t[0]+6,t[1]+6], fill=c)
        nm=(m.get('name') or '')[:6]
        if nm and m.get('type')=='waypoint':
            dr.text((t[0]+10,t[1]-12), nm, font=font(16), fill=(255,215,150,230))

# 自车
ev=proj([cx,cy,0.5])
if ev:
    s=20
    dr.polygon([(ev[0],ev[1]-s),(ev[0]-s*.72,ev[1]+s*.62),(ev[0]+s*.72,ev[1]+s*.62)],
               fill=(255,255,255,255), outline=(0,229,255,255))

# HUD
dr.rectangle([0,0,W,42], fill=(0,0,0,175))
dr.text((26,11),"3D 路线导航 · 异环 NTE", font=font(20), fill=(0,229,255,255))
dr.text((W-330,11),f"FOV {FOV:.0f}°  臂长 {CAM_BACK:.0f}m  高 {CAM_H:.0f}m", font=font(16), fill=(140,200,235,220))
dr.rectangle([0,H-92,W,H], fill=(0,0,0,205))
dr.text((28,H-74),"下一转向", font=font(17), fill=(150,190,220,230))
dr.text((28,H-48),"左转 · 120m 后", font=font(28), fill=(0,229,255,255))
dr.text((330,H-48),"距离 342m", font=font(24), fill=(235,245,255,235))
dr.text((540,H-48),"预计 28s", font=font(24), fill=(235,245,255,235))
img.save('/tmp/route3d_clean.png'); print("→ /tmp/route3d_clean.png")
