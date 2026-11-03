/**
 * cubic-bezier 缓动求解器
 *
 * 规范：DESIGN_SYSTEM.md §5.4 / §6.1
 *   数字滚动使用 cubic-bezier(0.16, 1, 0.3, 1)（ease-out，末段减速）
 *   实现方式：牛顿迭代 + 二分兜底求 t，再取 y
 */
export type Easing = (x: number) => number

/** 单个坐标轴上的三次贝塞尔：P0=(0,0), P1=(p1), P2=(p2), P3=(1,1) */
function axisValue(t: number, p1: number, p2: number): number {
  const mt = 1 - t
  return 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t
}

/** 该轴上的导数（牛顿迭代用） */
function axisSlope(t: number, p1: number, p2: number): number {
  const mt = 1 - t
  return (
    3 * mt * mt * p1 + 6 * mt * t * (p2 - p1) + 3 * t * t * (1 - p2)
  )
}

export function cubicBezier(
  x1: number,
  _y1: number,
  x2: number,
  _y2: number,
): Easing {
  return (x: number) => {
    if (x <= 0) return 0
    if (x >= 1) return 1

    // 牛顿迭代求 t（x 轴）
    let t = x
    for (let i = 0; i < 8; i += 1) {
      const slope = axisSlope(t, x1, x2)
      if (slope === 0) break
      const err = axisValue(t, x1, x2) - x
      t -= err / slope
      if (t < 0) t = 0
      if (t > 1) t = 1
    }

    // 牛顿迭代失败时二分兜底
    if (Math.abs(axisValue(t, x1, x2) - x) > 1e-6) {
      let lo = 0
      let hi = 1
      t = x
      for (let i = 0; i < 24; i += 1) {
        const v = axisValue(t, x1, x2)
        if (Math.abs(v - x) < 1e-6) break
        if (v > x) hi = t
        else lo = t
        t = (lo + hi) / 2
      }
    }

    return axisValue(t, _y1, _y2)
  }
}

/** DESIGN_SYSTEM §5.4 数字滚动缓动 */
export const easeOutExpo = cubicBezier(0.16, 1, 0.3, 1)
