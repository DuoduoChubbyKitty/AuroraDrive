import { useEffect, useState } from 'react'

/**
 * 媒体查询 Hook —— 响应式行为的 JS 侧判断
 *
 * 仅在必须改变渲染结构时使用（例如移动端抽屉）。
 * 纯样式差异一律交给 CSS 媒体查询，避免重复渲染。
 */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return false
    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return
    const mql = window.matchMedia(query)
    const onChange = (e: MediaQueryListEvent) => setMatches(e.matches)
    setMatches(mql.matches)
    mql.addEventListener('change', onChange)
    return () => mql.removeEventListener('change', onChange)
  }, [query])

  return matches
}

/** 是否处于移动端断点（< 1024px，导航折叠为抽屉） */
export function useIsMobileNav(): boolean {
  return useMediaQuery('(max-width: 1023px)')
}
