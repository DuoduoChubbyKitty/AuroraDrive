# MaaNTE vs AuroraDrive 对比分析

## 核心差异

### 1. 窗口模式

| 特性 | MaaNTE (Windows) | AuroraDrive (macOS) |
|------|------------------|---------------------|
| 窗口大小 | 可控制 (默认 1280×720) | 全屏，不可控 |
| 截图方式 | 直接截取游戏窗口 | 截取整个屏幕 |
| 小地图位置 | 固定 (28, 15, 150, 150) | 相对坐标 (百分比) |

### 2. 坐标获取

| 方式 | MaaNTE | AuroraDrive |
|------|--------|-------------|
| 网络坐标 | ✅ pcap/pktmon | ❌ 不可用 |
| 视觉匹配 | ✅ 主方案 | ✅ 主方案 |
| 双保险 | ✅ 网络优先 | ⚠️ 仅视觉 |

### 3. 预处理流程

**MaaNTE (成功关键)**:
```
截图 → HSV过滤 → 圆形掩码 → V通道 → -3偏移 → NCC匹配
```

**AuroraDrive (当前)**:
```
截图 → 灰度转换 → NCC匹配
```

**缺失**: HSV过滤、圆形掩码、灰度对齐

---

## 移植建议

### 高优先级（提升匹配率）

1. **HSV颜色过滤**
   - 去除UI图标干扰
   - 保留低饱和度区域（地图纹理）

2. **圆形掩码**
   - 只保留小地图圆形区域
   - 忽略方形边缘的黑色背景

3. **灰度对齐偏移**
   - 减去固定值 (-3) 对齐大地图
   - 补偿动态光照差异

### 中优先级（提升鲁棒性）

4. **全局搜索区域约束**
   - 避开纯黑/纯白区域
   - 只在有效坐标范围搜索

5. **Teleport检测**
   - 跳变 >320px 时触发全局重搜
   - 避免连续定位错误

### 低优先级（可选增强）

6. **网络坐标备用**
   - 实现 BPF 抓包（macOS）
   - 作为视觉定位的 fallback

---

## 技术细节

### MaaNTE 预处理代码

```python
# 圆形掩码
template_mask = np.zeros((h, w), dtype=np.uint8)
cv2.circle(template_mask, center, min(w, h) // 2 - 11, 255, -1)

# HSV过滤
hsv_img = cv2.cvtColor(minimap, cv2.COLOR_BGR2HSV)
color_mask = cv2.inRange(hsv_img, [0, 0, 0], [179, 66, 80])

# 结合掩码
combined_mask = cv2.bitwise_and(color_mask, template_mask)
mini_gray = cv2.bitwise_and(v_channel, combined_mask)

# 灰度对齐
template = cv2.subtract(mini_gray, 3)
```

### AuroraDrive 当前代码

```swift
// VisualLocator.swift:502
static func minimapBytes(from img: CGImage, side: Int) -> [UInt8]? {
    guard let f = scaledGrayFloatPixels(img, targetW: side, targetH: side) else { return nil }
    return f.map { UInt8(min(255, max(0, Int($0 * 255.0)))) }
}
```

**问题**: 直接灰度转换，无预处理

---

## 参考资料

- MaaNTE: `/Users/dupi/Desktop/MaaNTE/agent/custom/action/Navi/map_locator.py`
- AuroraDrive: `/Users/dupi/Desktop/自动驾驶系统/src/AuroraDrive/VisualLocator.swift`
- Bug记录: `/Users/dupi/Desktop/自动驾驶系统/docs/BUGS.md`
