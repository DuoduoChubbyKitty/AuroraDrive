import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'

/* ============================================================
   按钮
   规范：DESIGN_SYSTEM.md §5 —— hover 位移 ≤2px，不改变尺寸与布局属性
   ============================================================ */

type Variant = 'primary' | 'secondary' | 'ghost'
type Size = 'md' | 'lg'

const base =
  'inline-flex items-center justify-center gap-2 font-medium ' +
  'rounded-[var(--radius-md)] border transition-all duration-150 ' +
  'whitespace-nowrap select-none'

const variants: Record<Variant, string> = {
  primary:
    'bg-[var(--accent)] text-[var(--text-inverse)] border-transparent ' +
    'font-semibold hover:bg-[var(--accent-hover)] ' +
    'hover:shadow-[var(--glow-accent)] hover:-translate-y-px',
  secondary:
    'bg-transparent text-[var(--text-primary)] border-[var(--stroke-default)] ' +
    'hover:bg-[var(--bg-elevated)] hover:border-[var(--accent-line)]',
  ghost:
    'bg-transparent text-[var(--text-secondary)] border-transparent ' +
    'hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)]',
}

const sizes: Record<Size, string> = {
  md: 'h-10 px-4 text-[14px]',
  lg: 'h-12 px-6 text-[15px]',
}

interface ButtonBaseProps {
  variant?: Variant
  size?: Size
  children: ReactNode
  className?: string
}

export function Button({
  variant = 'primary',
  size = 'md',
  children,
  className = '',
  ...rest
}: ButtonBaseProps & React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      className={`${base} ${variants[variant]} ${sizes[size]} ${className}`}
      {...rest}
    >
      {children}
    </button>
  )
}

export function ButtonLink({
  variant = 'primary',
  size = 'md',
  children,
  className = '',
  to,
  href,
  external,
  ...rest
}: ButtonBaseProps & {
  to?: string
  href?: string
  external?: boolean
}) {
  const cls = `${base} ${variants[variant]} ${sizes[size]} ${className}`

  if (external && href) {
    return (
      <a
        href={href}
        target="_blank"
        rel="noreferrer noopener"
        className={cls}
        {...rest}
      >
        {children}
      </a>
    )
  }

  if (to) {
    return (
      <Link to={to} className={cls} {...rest}>
        {children}
      </Link>
    )
  }

  return (
    <a href={href} className={cls} {...rest}>
      {children}
    </a>
  )
}

/* ============================================================
   区块容器
   ============================================================ */

export function Section({
  children,
  className = '',
  id,
  alt = false,
  'aria-labelledby': ariaLabelledBy,
}: {
  children: ReactNode
  className?: string
  id?: string
  alt?: boolean
  'aria-labelledby'?: string
}) {
  return (
    <section
      id={id}
      aria-labelledby={ariaLabelledBy}
      className={`section-y ${alt ? 'bg-[var(--bg-surface)]' : ''} ${className}`}
    >
      <div className="container-page">{children}</div>
    </section>
  )
}

/** 区块标题组：眉标 + 标题 + 导语 */
export function SectionHeading({
  eyebrow,
  title,
  lead,
  align = 'left',
  id,
}: {
  eyebrow?: string
  title: ReactNode
  lead?: ReactNode
  align?: 'left' | 'center'
  id?: string
}) {
  const alignCls =
    align === 'center' ? 'items-center text-center mx-auto' : 'items-start text-left'
  return (
    <div className={`flex flex-col ${alignCls} max-w-3xl`}>
      {eyebrow && <span className="eyebrow mb-4">{eyebrow}</span>}
      <h2
        id={id}
        className="text-[length:var(--text-h1)] leading-[1.08] tracking-[-0.025em]"
      >
        {title}
      </h2>
      {lead && (
        <p className="mt-5 text-[length:var(--text-lead)] leading-[1.55] text-[var(--text-secondary)]">
          {lead}
        </p>
      )}
    </div>
  )
}

/* ============================================================
   徽标 / 标签
   ============================================================ */

export function Badge({
  children,
  tone = 'neutral',
  className = '',
}: {
  children: ReactNode
  tone?: 'neutral' | 'accent' | 'success' | 'warning' | 'danger' | 'info'
  className?: string
}) {
  const tones: Record<string, string> = {
    neutral:
      'bg-[var(--bg-inset)] text-[var(--text-secondary)] border-[var(--stroke-default)]',
    accent:
      'bg-[var(--accent-subtle)] text-[var(--accent)] border-[var(--accent-line)]',
    success:
      'bg-[var(--success-bg)] text-[var(--success)] border-transparent',
    warning:
      'bg-[var(--warning-bg)] text-[var(--warning)] border-transparent',
    danger: 'bg-[var(--danger-bg)] text-[var(--danger)] border-transparent',
    info: 'bg-[var(--info-bg)] text-[var(--info)] border-transparent',
  }
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-[var(--radius-sm)] border px-2 py-0.5 font-mono text-[11px] font-medium tracking-[0.06em] ${tones[tone]} ${className}`}
    >
      {children}
    </span>
  )
}

/** 状态灯 —— 全站唯一允许的无限循环动效，用于表达"运行中" */
export function StatusDot({ color = 'var(--accent)' }: { color?: string }) {
  return (
    <span
      aria-hidden="true"
      className="pulse-dot inline-block size-1.5 rounded-full"
      style={{ backgroundColor: color }}
    />
  )
}
