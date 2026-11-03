import { useCallback, useEffect, useState } from 'react'

export type Theme = 'light' | 'dark'

const STORAGE_KEY = 'aurora-theme'

function readTheme(): Theme {
  if (typeof window === 'undefined') return 'dark'
  const stored = localStorage.getItem(STORAGE_KEY)
  if (stored === 'light' || stored === 'dark') return stored
  return window.matchMedia('(prefers-color-scheme: light)').matches
    ? 'light'
    : 'dark'
}

function applyTheme(theme: Theme) {
  const root = document.documentElement
  root.dataset.theme = theme
  root.classList.toggle('dark', theme === 'dark')
  localStorage.setItem(STORAGE_KEY, theme)
}

/**
 * 主题切换。
 *
 * 优先走 View Transitions API 做圆形扩散（clip-path 动画），
 * 浏览器不支持时退化为直接切换（CSS 变量瞬时替换，不会闪烁）。
 */
export function useTheme() {
  const [theme, setTheme] = useState<Theme>(readTheme)

  useEffect(() => {
    // 与 index.html 内联脚本保持一致（内联脚本已设好，这里只做兜底同步）
    applyTheme(theme)
  }, [theme])

  const toggleTheme = useCallback(
    (origin?: { x: number; y: number }) => {
      const next: Theme = theme === 'dark' ? 'light' : 'dark'
      const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches

      const doc = document as Document & {
        startViewTransition?: (cb: () => void) => { finished: Promise<void> }
      }

      if (!reduced && typeof doc.startViewTransition === 'function') {
        const x = origin?.x ?? window.innerWidth - 48
        const y = origin?.y ?? 48
        const radius = Math.hypot(
          Math.max(x, window.innerWidth - x),
          Math.max(y, window.innerHeight - y),
        )

        const transition = doc.startViewTransition(() => {
          applyTheme(next)
          setTheme(next)
        })

        transition.finished
          .then(() => {
            document.documentElement.animate(
              {
                clipPath: [
                  `circle(0px at ${x}px ${y}px)`,
                  `circle(${radius}px at ${x}px ${y}px)`,
                ],
              },
              {
                duration: 420,
                easing: 'cubic-bezier(0.16, 1, 0.3, 1)',
                pseudoElement: '::view-transition-new(root)',
              },
            )
          })
          .catch(() => {
            /* 用户在过渡期间切了别的标签页，忽略 */
          })
      } else {
        applyTheme(next)
        setTheme(next)
      }
    },
    [theme],
  )

  return { theme, toggleTheme }
}
