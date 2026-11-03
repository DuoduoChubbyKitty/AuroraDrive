import { useEffect, useRef, useState } from 'react'
import { easeOutExpo } from './easing'

/**
 * 数字滚动计数
 *
 * 规范：DESIGN_SYSTEM.md §5.4
 *   - 触发：IntersectionObserver，threshold 0.4，once（进入视口触发一次，不重播）
 *   - 时长：1200ms，缓动 cubic-bezier(0.16, 1, 0.3, 1)
 *   - 小数位保留原位数（1.91 不能滚成 2）
 *   - 千分位每帧格式化
 *   - prefers-reduced-motion 下直接呈现终值
 *
 * @param target   目标数值
 * @param decimals 小数位数
 */
export function useCountUp(target: number) {
  const [value, setValue] = useState(0)
  const [started, setStarted] = useState(false)
  const ref = useRef<HTMLSpanElement | null>(null)
  const frameRef = useRef<number | undefined>(undefined)
  const startedRef = useRef(false)

  useEffect(() => {
    const el = ref.current
    if (!el) return

    const reduced =
      typeof window.matchMedia === 'function' &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches

    if (reduced || typeof IntersectionObserver === 'undefined') {
      setValue(target)
      setStarted(true)
      return
    }

    const run = () => {
      const duration = 1200
      const startTime = performance.now()

      const tick = (now: number) => {
        const elapsed = now - startTime
        const t = Math.min(1, elapsed / duration)
        const eased = easeOutExpo(t)
        setValue(target * eased)
        if (t < 1) {
          frameRef.current = requestAnimationFrame(tick)
        } else {
          setValue(target)
        }
      }

      frameRef.current = requestAnimationFrame(tick)
    }

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting && !startedRef.current) {
            startedRef.current = true
            setStarted(true)
            observer.unobserve(entry.target)
            run()
          }
        }
      },
      { threshold: 0.4 },
    )

    observer.observe(el)
    return () => {
      observer.disconnect()
      if (frameRef.current !== undefined) cancelAnimationFrame(frameRef.current)
    }
  }, [target])

  return { ref, value, started }
}

/** 千分位格式化 */
export function formatNumber(value: number, decimals = 0): string {
  const fixed = value.toFixed(decimals)
  const [intPart, decPart] = fixed.split('.')
  const withSeparator = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return decPart ? `${withSeparator}.${decPart}` : withSeparator
}
