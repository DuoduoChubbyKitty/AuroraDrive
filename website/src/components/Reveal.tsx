import type { ElementType, ReactNode } from 'react'
import { motion } from 'framer-motion'
import { useScrollReveal, staggerDelay } from '../hooks/useScrollReveal'

/**
 * 滚动渐入容器
 *
 * 规范：DESIGN_SYSTEM.md §6.2
 *   位移 translateY(20px) → 0（移动端 16px）
 *   时长 640ms，缓动 cubic-bezier(0.16, 1, 0.3, 1)
 *   错峰 delay = index * 70ms，最大总延迟 280ms
 *   Reduced motion：仅 opacity，无位移
 *
 * @param index  同级错峰序号
 * @param from   入场方向，默认从下往上
 */
export function Reveal({
  children,
  index = 0,
  from = 'up',
  className,
  as: Tag = 'div',
  delay,
}: {
  children: ReactNode
  index?: number
  from?: 'up' | 'left' | 'none'
  className?: string
  as?: ElementType
  delay?: number
}) {
  const { ref, visible, reduced } = useScrollReveal<HTMLDivElement>()

  const offset = reduced || from === 'none' ? 0 : from === 'left' ? -16 : 20
  const Component = motion[Tag as 'div'] ?? motion.div

  return (
    <Component
      ref={ref}
      className={className}
      initial={{ opacity: 0, y: from === 'left' ? 0 : offset, x: from === 'left' ? offset : 0 }}
      animate={
        visible
          ? { opacity: 1, y: 0, x: 0 }
          : { opacity: 0, y: from === 'left' ? 0 : offset, x: from === 'left' ? offset : 0 }
      }
      transition={{
        duration: reduced ? 0.2 : 0.64,
        ease: [0.16, 1, 0.3, 1],
        delay: reduced ? 0 : (delay ?? staggerDelay(index)),
      }}
    >
      {children}
    </Component>
  )
}

/**
 * 分组错峰容器 —— 一次性为子元素应用错峰延迟
 */
export function RevealGroup({
  children,
  className,
  step = 70,
  as: Tag = 'div',
}: {
  children: ReactNode
  className?: string
  step?: number
  as?: ElementType
}) {
  const { ref, visible, reduced } = useScrollReveal<HTMLDivElement>()
  const Component = motion[Tag as 'div'] ?? motion.div

  return (
    <Component
      ref={ref}
      className={className}
      initial="hidden"
      animate={visible ? 'show' : 'hidden'}
      variants={{
        hidden: {},
        show: {
          transition: { staggerChildren: reduced ? 0 : step / 1000 },
        },
      }}
    >
      {children}
    </Component>
  )
}

/** 错峰子项 —— 需放在 RevealGroup 内 */
export function RevealItem({
  children,
  className,
  from = 'up',
}: {
  children: ReactNode
  className?: string
  from?: 'up' | 'left' | 'none'
}) {
  const reduced = useReducedMotionSafe()
  const offset = reduced || from === 'none' ? 0 : from === 'left' ? -16 : 20

  return (
    <motion.div
      className={className}
      variants={{
        hidden: { opacity: 0, y: from === 'left' ? 0 : offset, x: from === 'left' ? offset : 0 },
        show: { opacity: 1, y: 0, x: 0 },
      }}
      transition={{
        duration: reduced ? 0.2 : 0.64,
        ease: [0.16, 1, 0.3, 1],
      }}
    >
      {children}
    </motion.div>
  )
}

// 局部引入，避免循环依赖
import { useReducedMotion } from 'framer-motion'
function useReducedMotionSafe() {
  return useReducedMotion() ?? false
}
