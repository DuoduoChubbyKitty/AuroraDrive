import type { ReactNode } from 'react'
import { Reveal } from './Reveal'

/**
 * 内页 Hero
 *
 * 规范：DESIGN_SYSTEM.md §5.2 —— 同样禁止居中排版
 *   左文 5 列 / 右视觉 7 列的分栏结构在子页复用
 */
export function PageHero({
  eyebrow,
  title,
  lead,
  aside,
}: {
  eyebrow: string
  title: string
  lead: string
  /** 右侧视觉位 —— 与文字是兄弟容器，不是叠加 */
  aside?: ReactNode
}) {
  return (
    <section className="relative overflow-hidden border-b border-[var(--stroke-subtle)]" aria-labelledby="page-hero-title">
      {/* 背景层 */}
      <div aria-hidden="true" className="pointer-events-none absolute inset-0">
        <div
          className="absolute -right-1/4 -top-1/3 h-[55%] w-[110%] opacity-[var(--hero-glow-opacity)]"
          style={{
            background:
              'linear-gradient(100deg, var(--accent) 0%, var(--accent-2) 48%, var(--accent-3) 100%)',
            filter: 'blur(120px)',
          }}
        />
        <div
          className="absolute inset-0"
          style={{
            backgroundImage:
              'linear-gradient(var(--grid-line) 1px, transparent 1px), linear-gradient(90deg, var(--grid-line) 1px, transparent 1px)',
            backgroundSize: '48px 48px',
            maskImage: 'radial-gradient(ellipse at 30% 0%, black, transparent 70%)',
            WebkitMaskImage: 'radial-gradient(ellipse at 30% 0%, black, transparent 70%)',
          }}
        />
      </div>

      <div className="container-page relative pb-16 pt-14 lg:pb-20 lg:pt-20">
        <div className="grid grid-cols-1 items-start gap-10 lg:grid-cols-12 lg:gap-12">
          <div className="lg:col-span-6">
            <Reveal>
              <span className="eyebrow">{eyebrow}</span>
              <h1
                id="page-hero-title"
                className="mt-6 text-[length:var(--text-display)] leading-[1.04] tracking-[-0.03em] max-sm:leading-[1.12]"
                style={{ maxWidth: '16em' }}
              >
                {title}
              </h1>
              <p className="mt-6 max-w-[46em] text-[length:var(--text-lead)] leading-[1.55] text-[var(--text-secondary)]">
                {lead}
              </p>
            </Reveal>
          </div>
          {aside && (
            <div className="lg:col-span-6">
              <Reveal delay={0.08}>{aside}</Reveal>
            </div>
          )}
        </div>
      </div>
    </section>
  )
}
