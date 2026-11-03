import { motion } from 'framer-motion'
import { useTheme } from '../hooks/useTheme'

/**
 * 主题切换按钮
 *
 * 规范：DESIGN_SYSTEM.md §5.1（36×36，--radius-sm，hover 显示 --bg-elevated）
 *      §7.2（圆形扩散由 useTheme 内部的 View Transitions 实现）
 *
 * 图标旋转 180° —— 240ms（§6.3）
 */
export function ThemeToggle({ className = '' }: { className?: string }) {
  const { theme, toggleTheme } = useTheme()
  const isDark = theme === 'dark'

  return (
    <button
      type="button"
      onClick={(e) => {
        const rect = e.currentTarget.getBoundingClientRect()
        toggleTheme({
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
        })
      }}
      className={`inline-flex size-9 items-center justify-center rounded-[var(--radius-sm)] border border-transparent text-[var(--text-secondary)] transition-colors duration-120 hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)] ${className}`}
      aria-label={isDark ? '切换到亮色模式' : '切换到深色模式'}
      title={isDark ? '切换到亮色模式' : '切换到深色模式'}
    >
      <motion.span
        key={theme}
        aria-hidden="true"
        initial={{ rotate: -90, opacity: 0 }}
        animate={{ rotate: 0, opacity: 1 }}
        transition={{ duration: 0.24, ease: [0.16, 1, 0.3, 1] }}
        className="inline-flex"
      >
        {isDark ? (
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <circle
              cx="12"
              cy="12"
              r="4.25"
              stroke="currentColor"
              strokeWidth="1.5"
            />
            <g stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
              <path d="M12 2.75v2.5" />
              <path d="M12 18.75v2.5" />
              <path d="M2.75 12h2.5" />
              <path d="M18.75 12h2.5" />
              <path d="M5.46 5.46l1.77 1.77" />
              <path d="M16.77 16.77l1.77 1.77" />
              <path d="M18.54 5.46l-1.77 1.77" />
              <path d="M7.23 16.77l-1.77 1.77" />
            </g>
          </svg>
        ) : (
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <path
              d="M20.5 14.6A8.6 8.6 0 0 1 9.4 3.5a8.6 8.6 0 1 0 11.1 11.1Z"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinejoin="round"
            />
          </svg>
        )}
      </motion.span>
    </button>
  )
}
