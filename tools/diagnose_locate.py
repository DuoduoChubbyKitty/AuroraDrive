#!/usr/bin/env python3
"""
AuroraDrive 定位诊断脚本 —— 验证 bigworldmap 能否被 VisualLocator 匹配
用法: python3 diagnose_locate.py [截图路径.png]
无参时输出一段自检说明
"""
import sys, os, math

def main():
    if len(sys.argv) > 1:
        screenshot = sys.argv[1]
        print(f"检查截图: {screenshot}")
        if not os.path.exists(screenshot):
            print(f"❌ 截图不存在: {screenshot}")
            return 1
        print(f"   大小: {os.path.getsize(screenshot)} bytes")
        print("   → 可用 ImageIO 打开检查尺寸/通道，但完整 NCC 匹配需 Swift 运行时")
        return 0

    map_path = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"
    if not os.path.exists(map_path):
        print("❌ 地图文件不存在!")
        return 1
    print(f"地图: {map_path} ({os.path.getsize(map_path)} bytes)")
    print()
    print("=== 定位失败可能原因 ===")
    print("""
1. 【ROI 位置不对】默认 minimapROI = (centerX:0.13, centerY:0.14, sideFraction:0.16)
   → 假设游戏小地图在屏幕左上角 (13%,14%)，边长 16%。
   若实际小地图在别处（如右下角/右上角），裁出来的 ROI 是空白/错位 → 永远匹配不上。
   建议：打开标注模式手动框选「标注小地图」重新设定 ROI。

2. 【模板内容不匹配】bigworldmap 是完整大图 (11264×11264)，NCC 在多尺度下匹配。
   但屏幕小地图可能只显示局部（150px 缩略图），而 bigworldmap 是全量。
   → 需确认视觉特征是否足够（道路/建筑轮廓 vs 纯色块）。

3. 【Game Mode 抢占】游戏模式可能改变了截屏分辨率/坐标系。
   → 运行时会打印 frame=WxH、side=Px rect=... 供排查。

4. 【阈值过高/过低】当前 scoreThreshold=0.5，一般合理。
   → 可先试 0.3（宽松）/ 0.7（严格）对照。
""")
    print("=== 下一步 ===")
    print("""
① 完全退出 AuroraDriveUI
② 重新勾权限（屏幕录制 + 辅助功能）
③ 启动: ./AuroraDriveUI --locate-live
④ 进入游戏，等 ~1 秒后 Ctrl+C 退出
⑤ 查看 /tmp/aurora_debug.log 里 [LOCATELIVE-DIAG] 行
   - 若 "prepare ok=false" → 地图加载失败
   - 若 "crop/minimapBytes failed" → ROI 裁切失败（side<24）
   - 若 "未命中" 带 score=X.XXX → 看分数决定阈值
   - 若 locate=1:X.XX → 其实命中了！看框架是否渲染
⑥ 若命中但框不显示 → 检查 MinimapLocatorView 渲染条件
""")
    return 0

if __name__ == "__main__":
    sys.exit(main())
