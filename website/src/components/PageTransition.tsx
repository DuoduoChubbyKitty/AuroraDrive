import { useEffect, useLayoutEffect, useRef } from 'react'
import { useLocation, useNavigationType } from 'react-router-dom'
import { AnimatePresence, motion, useReducedMotion } from 'framer-motion'
import type { ReactNode } from 'react'

/**
 * 页面过渡容器
 *
 * 规范来源：DESIGN_SYSTEM.md §6.6
 *
 * 核心时间轴（总 560ms，出场短、进场长）：
 *   T0        旧页面开始 exit：opacity 1→0（200ms, ease-in），y 0→-8
 *   T0+200ms  旧页面卸载（mode="wait" 保证同一时刻只有一版 DOM）
 *   T0+200ms  新页面进场：opacity 0→1（360ms, ease-out），y 12→0
 *   T0+560ms  稳定
 *
 * 防闪烁硬规则：
 *   1. 页面根背景色恒定 var(--bg-base)，不随路由改变
 *   2. initial 上绝不设 scale（亚像素渲染会抖动）
 *   3. 进场位移 ≤16px
 *   4. 路由切换期间不设 scroll-behavior: smooth
 *   5. initial={false} —— 首屏不做入场动画（刷新页面整页飘是头号破坏方式）
 *   6. mode="wait" 串行，不做交叉淡入（否则两层半透明重影）
 *
 * 移动端：进场压到 280ms、位移减到 8px（小屏上大幅位移容易晕）
 *
 * 滚动位置：
 *   - pathname 变化的瞬间（useLayoutEffect，早于绘制）立即 scrollTo instant
 *   - scrollRestoration = 'manual'，由本组件接管
 *   - POP（前进/后退）时用 location.key 缓存恢复历史位置
 *   - hash 跳转等进场动画结束后再 scrollIntoView smooth
 */

/** location.key → scrollY */
const scrollPositions = new Map<string, number>()

/** 记录每个 key 对应的 pathname，用于 POP 恢复时反查 */
const keyToPath = new Map<string, string>()

export function PageTransition({ children }: { children: ReactNode }) {
  const location = useLocation()
  const navigationType = useNavigationType()
  const reduced = useReducedMotion() ?? false
  const previousPath = useRef<string | null>(null)
  const previousKey = useRef<string | null>(null)
  const pendingRestore = useRef<number | null>(null)

  // 接管浏览器原生滚动恢复，避免与动画打架
  useEffect(() => {
    if ('scrollRestoration' in window.history) {
      window.history.scrollRestoration = 'manual'
    }
  }, [])

  useLayoutEffect(() => {
    const path = location.pathname

    // 进场前把旧页面的滚动位置存起来（供 POP 恢复）
    if (previousKey.current !== null) {
      scrollPositions.set(previousKey.current, window.scrollY)
      if (previousPath.current) {
        keyToPath.set(previousKey.current, previousPath.current)
      }
    }

    // 立即归零 —— 用 instant，不能用 smooth
    // smooth 会造成"旧页淡出的同时缓慢上滑"的廉价感
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' })

    // POP（前进/后退）：记住目标位置，等进场动画结束后用 instant 恢复
    if (navigationType === 'POP') {
      const saved = scrollPositions.get(location.key)
      if (saved !== undefined) {
        pendingRestore.current = saved
      }
    }

    previousPath.current = path
    previousKey.current = location.key
  }, [location.pathname, location.key, navigationType])

  // POP 位置恢复 —— 进场动画结束后执行，用 instant 避免与进场位移叠加
  useEffect(() => {
    if (pendingRestore.current === null) return
    const target = pendingRestore.current
    pendingRestore.current = null
    const timer = window.setTimeout(
      () => window.scrollTo({ top: target, left: 0, behavior: 'instant' }),
      reduced ? 0 : 380,
    )
    return () => window.clearTimeout(timer)
  }, [location.key, reduced])

  // hash 目标：等进场动画结束再平滑滚动，并留出吸顶导航的高度
  useEffect(() => {
    if (!location.hash) return
    const timer = window.setTimeout(() => {
      const target = document.querySelector(location.hash)
      if (!target) return
      // 区块自带 section-y 顶部内边距（112px）。若直接对齐区块顶部，
      // 标题会被推到视口下方 100px 之外，看起来像"跳过头了"。
      // 因此定位到区块内的标题元素，让标题正好落在导航栏下方。
      const heading = target.querySelector<HTMLElement>('h2, h3')
      ;(heading ?? target).scrollIntoView({
        behavior: reduced ? 'instant' : 'smooth',
        block: 'start',
      })
    }, reduced ? 0 : 380)
    return () => window.clearTimeout(timer)
  }, [location.hash, reduced])

  const isMobile = typeof window !== 'undefined' && window.innerWidth < 768

  const enterDuration = reduced ? 0.16 : isMobile ? 0.28 : 0.36
  const exitDuration = reduced ? 0.16 : isMobile ? 0.16 : 0.2
  const enterY = reduced ? 0 : isMobile ? 8 : 12
  const exitY = reduced ? 0 : isMobile ? -6 : -8

  return (
    <AnimatePresence mode="wait" initial={false}>
      <motion.main
        key={location.pathname}
        initial="enter"
        animate="center"
        exit="exit"
        variants={{
          enter: {
            opacity: 0,
            y: enterY,
            transition: { duration: enterDuration, ease: [0.16, 1, 0.3, 1] },
          },
          center: {
            opacity: 1,
            y: 0,
            transition: { duration: enterDuration, ease: [0.16, 1, 0.3, 1] },
          },
          exit: {
            opacity: 0,
            y: exitY,
            transition: { duration: exitDuration, ease: [0.5, 0, 0.9, 0.5] },
          },
        }}
        style={{ backgroundColor: 'var(--bg-base)' }}
      >
        {children}
      </motion.main>
    </AnimatePresence>
  )
}
