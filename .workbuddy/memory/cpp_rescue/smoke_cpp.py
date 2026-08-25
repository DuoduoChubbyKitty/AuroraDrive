#!/usr/bin/env python3.11
# autodrive_core 冒烟测试（巡查用，15 项）
# 覆盖：bike_step / IDM / MOBIL / TrafficManager / GridIndex / render_cameras
import sys, os, math
import numpy as np

sys.path.insert(0, "/Users/dupi/Desktop/自动驾驶系统/cpp/build")
import autodrive_core as ad

PASS, FAIL = [], []


def check(name, cond, info=""):
    (PASS if cond else FAIL).append(name)
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  | " + str(info)) if info else ""))


print("=== 1. bike_step (S6 零速耦合航向) ===")
e = ad.EgoState(0, 0, 0, 0.0, 0.0)
ad.bike_step(e, 0.4, 0.0, 0.1)
check("bike_step:S6 v=0 无横摆", abs(e.heading - 0.0) < 1e-6, f"heading={e.heading}")

e2 = ad.EgoState(0, 0, 0, 0.0, 36.0)  # 10 m/s
h0 = e2.heading
ad.bike_step(e2, 0.2, 0.0, 0.1)
check("bike_step:有速转向改变航向", abs(e2.heading - h0) > 1e-4, f"dh={e2.heading-h0:.5f}")

e3 = ad.EgoState(0, 0, 0, 0.0, 0.0)
ad.bike_step(e3, 0.0, 2.0, 1.0)  # a=2 m/s^2, 1s -> 2 m/s = 7.2 km/h
check("bike_step:S2 加速度量纲 m/s^2", abs(e3.speed_kmh - 7.2) < 0.5, f"v={e3.speed_kmh:.3f} km/h")

e4 = ad.EgoState(0, 0, 0, 0.0, 36.0)
ad.bike_step(e4, 0.0, 0.0, 1.0)
check("bike_step:直行位移≈v*dt", abs(math.hypot(e4.pos.x, e4.pos.y) - 10.0) < 1.0,
      f"d={math.hypot(e4.pos.x, e4.pos.y):.3f}")

print("=== 2. IDM (m/s^2 量纲) ===")
idm = ad.IDM(v0=30.0, a_max=1.5, b=2.0, s0=2.0, T=1.5)
a_free = idm.accel(0.0, 1e5, 0.0)
check("IDM:自由流加速≈a_max", 0.5 < a_free <= 1.6, f"a={a_free:.4f}")
a_close = idm.accel(20.0, 2.0, 20.0)  # 极近距离 + 高接近率
check("IDM:近距强减速", a_close < -2.0, f"a={a_close:.4f}")
check("IDM:输出有限(非 NaN/Inf)", math.isfinite(a_free) and math.isfinite(a_close))

print("=== 3. MOBIL (S3 量纲/S8 双侧) ===")
mb = ad.MOBIL()
check("MOBIL:参数可读写", hasattr(mb, "p") and hasattr(mb, "a_th") and hasattr(mb, "b_safe"),
      f"p={mb.p} a_th={mb.a_th} b_safe={mb.b_safe}")
safe_ok = mb.safe(-0.5)          # 轻微减速 -> 安全
safe_bad = mb.safe(-99.0)        # 剧烈减速 -> 不安全
check("MOBIL:safe 判据正确", bool(safe_ok) and not bool(safe_bad), f"{safe_ok}/{safe_bad}")

print("=== 4. TrafficManager (S4 逐车长度 / 换道 / M2 网格) ===")
tm = ad.TrafficManager(50.0)
rng = np.random.default_rng(0)
for i in range(60):
    tm.add(float(i * 20), float((i % 3) * 3.5), 0.0, 15.0 + (i % 5),
           4.5 + (i % 4) * 0.7, 1.9, i % 3)
check("TM:count 正确", tm.count() == 60, tm.count())
xy0 = tm.vehicles_xy().copy()
for _ in range(20):
    tm.update(0.05, 3.5)
xy1 = tm.vehicles_xy()
check("TM:vehicles_xy 形状 [N,5]", xy1.shape == (60, 5), xy1.shape)
check("TM:update 后位置推进", np.abs(xy1[:, 0] - xy0[:, 0]).max() > 0.5,
      f"maxdx={np.abs(xy1[:,0]-xy0[:,0]).max():.3f}")
check("TM:无 NaN/Inf(数值安全)", bool(np.isfinite(xy1).all()))

print("=== 5. GridIndex (M2 空间网格) ===")
g = ad.GridIndex(100.0)
pts = np.array([[0, 0, 0], [50, 0, 0], [100, 0, 0]], dtype=np.float32)
g.add_road(1, pts)
r = g.query_roads(10.0, 0.0, 60.0)
check("GridIndex:query_roads 命中", 1 in r, r)

g2 = ad.GridIndex(100.0)
for i in range(20):
    g2.add_vehicle(1000 + i, float(i * 30), 0.0)
qv = g2.query_vehicles(0.0, 0.0, 50.0)
far = [v for v in qv if v >= 1000 and (v - 1000) * 30 > 150]
check("GridIndex:M2 query_vehicles 半径过滤",
      len(qv) > 0 and all(v >= 1000 for v in qv) and not far, sorted(qv)[:10])

print("=== 6. render_cameras (原地渲染 / dtype) ===")
n_cam, H, W = 10, 64, 96
imgs = np.zeros((n_cam, H, W, 3), dtype=np.float32)
roads_xyz = np.array([[x, 0.0, 0.0] for x in range(0, 200, 5)], dtype=np.float32)
roads_off = np.array([0, len(roads_xyz)], dtype=np.float32)
bldg_xy = np.array([[30.0, 12.0], [34.0, 12.0], [34.0, 16.0], [30.0, 16.0]], dtype=np.float32)
bldg_off = np.array([0, 4], dtype=np.float32)
bldg_h = np.array([20.0], dtype=np.float32)
az = np.array([i * 36.0 * math.pi / 180.0 for i in range(n_cam)], dtype=np.float32)
ad.render_cameras(imgs, 0.0, 0.0, 1.5, 0.0, roads_xyz, roads_off,
                  bldg_xy, bldg_off, bldg_h, az, 150.0)
check("render:原地写回(非全零)", float(imgs.max()) > 0.0, f"max={imgs.max():.4f}")
check("render:黑屏兜底 0.3/0.25 量级", float(imgs.min()) >= 0.0 and float(imgs.max()) <= 1.5,
      f"min={imgs.min():.4f} max={imgs.max():.4f}")
try:
    bad = np.zeros((n_cam, H, W, 3), dtype=np.float64)
    ad.render_cameras(bad, 0.0, 0.0, 1.5, 0.0, roads_xyz, roads_off,
                      bldg_xy, bldg_off, bldg_h, az, 150.0)
    ok_dtype = False
    detail = "float64 未报错(危险: 静默丢结果)"
except TypeError as ex:
    ok_dtype = True
    detail = "float64 已拒绝"
check("render:float64 报错(dtype 守卫)", ok_dtype, detail)

print()
print(f"RESULT: {len(PASS)} PASS / {len(FAIL)} FAIL  (total {len(PASS)+len(FAIL)})")
if FAIL:
    print("FAILED:", FAIL)
sys.exit(0)
