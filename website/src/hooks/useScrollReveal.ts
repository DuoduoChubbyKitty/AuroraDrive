import { useEffect, useRef, useState } from 'react'
import { useReducedMotion } from 'framer-motion'

/**
 * 滚动渐入（Scroll Reveal）
 *
 * 规范来源：DESIGN_SYSTEM.md §6.2
 *   - IntersectionObserver, threshold 0.15, rootMargin "0px 0px -10% 0px"
 *   - once: true，触发后 unobserve，上滚不重播
 *   - 位移 translateY(20px) → 0（移动端 16px）
 *   - 时长 640ms，缓动 --ease-out
 *   - 错峰 delay = index * 70ms，最大总延迟 280ms
 *   - Reduced motion：仅 opacity 0→1，无位移
 */
export function useScrollReveal<T extends HTMLElement = HTMLDivElement>(
  options: { threshold?: number; rootMargin?: string } = {},
) {
  const ref = useRef<T | null>(null)
  const [visible, setVisible] = useState(false)
  const reduced = useReducedMotion()

  useEffect(() => {
    const el = ref.current
    if (!el) return

    // 不支持 IO 的浏览器直接呈现最终态
    if (typeof IntersectionObserver === 'undefined') {
      setVisible(true)
      return
    }

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setVisible(true)
            observer.unobserve(entry.target)
          }
        }
      },
      {
        threshold: options.threshold ?? 0.15,
        rootMargin: options.rootMargin ?? '0px 0px -10% 0px',
      },
    )

    observer.observe(el)
    return () => observer.disconnect()
  }, [options.threshold, options.rootMargin])

  return { ref, visible, reduced }
}

/**
 * 错峰延迟计算 —— 最大总延迟 280ms
 * 超过 4 个元素后，后续元素统一用 min(index, 4) * 70ms
 */
export function staggerDelay(index: number, step = 70, max = 280) {
  return Math.min(index * step, max)
}
