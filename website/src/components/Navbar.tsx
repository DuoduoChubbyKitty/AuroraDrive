import { useEffect, useRef, useState } from 'react'
import { Link, NavLink, useLocation } from 'react-router-dom'
import { AnimatePresence, motion, useReducedMotion } from 'framer-motion'
import { navigation, siteMeta } from '../content/site'
import { ButtonLink } from './ui'
import { ThemeToggle } from './ThemeToggle'
import { cn } from '../lib/cn'

/**
 * 导航栏
 *
 * 规范：DESIGN_SYSTEM.md §5.1
 *   - 高度 64px（桌面）/ 56px（移动）
 *   - sticky top:0, z-index 100
 *   - 顶部透明；滚动后 backdrop-filter: blur(20px) saturate(160%) + 78% bg-base
 *   - 滚动切换用 IntersectionObserver 打在 1px 哨兵上（不用 scroll 事件）
 *   - 当前页：--text-primary + 下方 2px --accent 指示条（scaleX 0→1）
 *   - 移动端：右侧抽屉，宽 min(88vw, 360px)，280ms ease-out 滑入
 *
 * 说明：Navbar 位于 PageTransition 之外，因此路由切换时不会跟着淡出淡入，
 * 保持导航的连续性。
 */
export function Navbar() {
  const [scrolled, setScrolled] = useState(false)
  const [drawerOpen, setDrawerOpen] = useState(false)
  const sentinelRef = useRef<HTMLDivElement | null>(null)
  const location = useLocation()
  const reduced = useReducedMotion() ?? false

  // 滚动状态：IntersectionObserver 打在页面顶部 1px 哨兵上
  useEffect(() => {
    const sentinel = sentinelRef.current
    if (!sentinel) return

    if (typeof IntersectionObserver === 'undefined') {
      const onScroll = () => setScrolled(window.scrollY > 8)
      onScroll()
      window.addEventListener('scroll', onScroll, { passive: true })
      return () => window.removeEventListener('scroll', onScroll)
    }

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          // 哨兵离开视口顶端即视为已滚动
          setScrolled(!entry.isIntersecting)
        }
      },
      { threshold: 0 },
    )
    observer.observe(sentinel)
    return () => observer.disconnect()
  }, [])

  // 路由变化时关闭抽屉
  useEffect(() => {
    setDrawerOpen(false)
  }, [location.pathname])

  // 抽屉打开时锁定滚动
  useEffect(() => {
    if (!drawerOpen) return
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = prev
    }
  }, [drawerOpen])

  // Esc 关闭抽屉
  useEffect(() => {
    if (!drawerOpen) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setDrawerOpen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [drawerOpen])

  return (
    <>
      {/* 1px 哨兵 —— 滚动状态探测用 */}
      <div ref={sentinelRef} aria-hidden="true" className="h-px w-full" />

      <header
        className={cn(
          'sticky top-0 z-[100] transition-[background-color,border-color,backdrop-filter] duration-[240ms]',
          scrolled
            ? 'border-b border-[var(--stroke-subtle)] bg-[color-mix(in_srgb,var(--bg-base)_78%,transparent)] backdrop-blur-[20px] backdrop-saturate-[160%]'
            : 'border-b border-transparent bg-transparent',
        )}
      >
        <div className="container-page flex h-14 items-center justify-between gap-4 lg:h-16">
          {/* Logo —— layoutId 做共享元素连续性（仅 Logo 与主题按钮使用） */}
          <Link
            to="/"
            className="flex shrink-0 items-center gap-2.5 text-[var(--text-primary)]"
            aria-label={`${siteMeta.name} 首页`}
          >
            <motion.span layoutId="aurora-logo-mark" className="inline-flex">
              <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden="true">
                <circle cx="10" cy="10" r="3" fill="var(--accent)" />
                <path
                  d="M10 1.6a8.4 8.4 0 0 1 7.3 4.2"
                  stroke="var(--accent-2)"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                />
                <path
                  d="M10 18.4A8.4 8.4 0 0 1 2.7 14.2"
                  stroke="var(--accent-2)"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                />
              </svg>
            </motion.span>
            <span className="font-[var(--font-display)] text-[18px] font-bold tracking-[-0.02em]">
              {siteMeta.name}
            </span>
          </Link>

          {/* 桌面导航 */}
          <nav aria-label="主导航" className="hidden lg:block">
            <ul className="flex items-center gap-7">
              {navigation.map((item) => (
                <li key={item.to}>
                  <NavLink
                    to={item.to}
                    end={item.to === '/'}
                    className={({ isActive }) =>
                      cn(
                        'relative block py-2 text-[14px] transition-colors duration-160',
                        isActive
                          ? 'text-[var(--text-primary)]'
                          : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                      )
                    }
                  >
                    {({ isActive }) => (
                      <>
                        {item.label}
                        <span
                          aria-hidden="true"
                          className={cn(
                            'absolute -bottom-px left-0 h-0.5 w-full origin-left bg-[var(--accent)] transition-transform duration-200',
                            isActive ? 'scale-x-100' : 'scale-x-0',
                          )}
                          style={{ transitionTimingFunction: 'cubic-bezier(0.2, 0, 0, 1)' }}
                        />
                      </>
                    )}
                  </NavLink>
                </li>
              ))}
            </ul>
          </nav>

          {/* 右侧操作区 */}
          <div className="flex shrink-0 items-center gap-2">
            <motion.span layoutId="aurora-theme-toggle" className="inline-flex">
              <ThemeToggle />
            </motion.span>
            <ButtonLink to="/docs" size="md" className="hidden sm:inline-flex">
              快速开始
            </ButtonLink>

            {/* 移动端汉堡 */}
            <button
              type="button"
              onClick={() => setDrawerOpen(true)}
              className="inline-flex size-9 items-center justify-center rounded-[var(--radius-sm)] border border-transparent text-[var(--text-secondary)] transition-colors duration-120 hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)] lg:hidden"
              aria-label="打开导航菜单"
              aria-expanded={drawerOpen}
              aria-controls="mobile-nav-drawer"
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                <g stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
                  <path d="M3.75 6.75h16.5" />
                  <path d="M3.75 12h16.5" />
                  <path d="M3.75 17.25h16.5" />
                </g>
              </svg>
            </button>
          </div>
        </div>
      </header>

      {/* 移动端抽屉 */}
      <AnimatePresence>
        {drawerOpen && (
          <>
            <motion.div
              key="scrim"
              className="fixed inset-0 z-[110] bg-[var(--bg-scrim)] lg:hidden"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: reduced ? 0 : 0.24 }}
              onClick={() => setDrawerOpen(false)}
              aria-hidden="true"
            />
            <motion.div
              key="drawer"
              id="mobile-nav-drawer"
              role="dialog"
              aria-modal="true"
              aria-label="导航菜单"
              className="fixed inset-y-0 right-0 z-[120] flex w-[min(88vw,360px)] flex-col border-l border-[var(--stroke-default)] bg-[var(--bg-elevated)] lg:hidden"
              initial={{ x: reduced ? 0 : '100%' }}
              animate={{ x: 0 }}
              exit={{ x: reduced ? 0 : '100%' }}
              transition={{ duration: reduced ? 0 : 0.28, ease: [0.16, 1, 0.3, 1] }}
            >
              <div className="flex h-14 items-center justify-between border-b border-[var(--stroke-default)] px-5">
                <span className="font-[var(--font-display)] text-[16px] font-bold">
                  {siteMeta.name}
                </span>
                <button
                  type="button"
                  onClick={() => setDrawerOpen(false)}
                  className="inline-flex size-11 items-center justify-center rounded-[var(--radius-sm)] text-[var(--text-secondary)] transition-colors duration-120 hover:bg-[var(--bg-card)] hover:text-[var(--text-primary)]"
                  aria-label="关闭导航菜单"
                >
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                    <g stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
                      <path d="M6 6l12 12" />
                      <path d="M18 6L6 18" />
                    </g>
                  </svg>
                </button>
              </div>

              <nav aria-label="移动端导航" className="flex-1 overflow-y-auto py-2">
                <ul>
                  {navigation.map((item) => (
                    <li key={item.to}>
                      <NavLink
                        to={item.to}
                        end={item.to === '/'}
                        className={({ isActive }) =>
                          cn(
                            'flex min-h-11 items-center px-5 text-[15px] transition-colors duration-160',
                            isActive
                              ? 'border-l-2 border-[var(--accent)] bg-[var(--bg-card)] text-[var(--text-primary)]'
                              : 'border-l-2 border-transparent text-[var(--text-secondary)] hover:bg-[var(--bg-card)] hover:text-[var(--text-primary)]',
                          )
                        }
                      >
                        {item.label}
                      </NavLink>
                    </li>
                  ))}
                </ul>
              </nav>

              <div className="border-t border-[var(--stroke-default)] p-5">
                <ButtonLink to="/docs" size="lg" className="w-full">
                  快速开始
                </ButtonLink>
              </div>
            </motion.div>
          </>
        )}
      </AnimatePresence>
    </>
  )
}
