import { Link } from 'react-router-dom'
import { pricingSection } from '../content/site'
import { RevealGroup, RevealItem } from './Reveal'
import { Section, SectionHeading } from './ui'
import { cn } from '../lib/cn'

/**
 * 定价方案对比
 *
 * 规范：DESIGN_SYSTEM.md §5.6
 *   - 桌面三列方案卡 + 全宽功能对比表
 *   - 推荐卡：1px --accent 边框 + 顶部 2px 极光渐变细线 + 「推荐」标签
 *   - 对比表：--text-label 表头，行高 48px，只用分隔线不用斑马纹
 *   - 单元格 ✓ 用 --success SVG 描边，✕ 用 --text-disabled
 *   - 移动：方案卡堆叠，对比表横向滚动，首列 sticky
 */
export function PricingTable({ compact = false }: { compact?: boolean }) {
  return (
    <Section id="pricing" alt aria-labelledby="pricing-title">
      <SectionHeading
        id="pricing-title"
        eyebrow={pricingSection.eyebrow}
        title={pricingSection.title}
        lead={pricingSection.lead}
      />

      {/* 方案卡 */}
      <RevealGroup className="mt-12 grid grid-cols-1 gap-6 md:grid-cols-3">
        {pricingSection.plans.map((plan) => (
          <RevealItem key={plan.id} className="h-full">
            <article
              className={cn(
                'relative flex h-full flex-col overflow-hidden rounded-[var(--radius-md)] bg-[var(--bg-card)] p-8',
                plan.featured
                  ? 'border border-[var(--accent)]'
                  : 'border border-[var(--stroke-default)]',
              )}
            >
              {plan.featured && (
                <span
                  aria-hidden="true"
                  className="absolute inset-x-0 top-0 h-[2px]"
                  style={{
                    background:
                      'linear-gradient(90deg, var(--accent), var(--accent-2), var(--accent-3))',
                  }}
                />
              )}

              <div className="flex items-start justify-between gap-3">
                <h3 className="text-[length:var(--text-h3)] leading-[1.25] tracking-[-0.015em]">
                  {plan.name}
                </h3>
                {plan.featured && (
                  <span className="shrink-0 rounded-[var(--radius-xs)] bg-[var(--accent-subtle)] px-2 py-0.5 font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--accent)]">
                    推荐
                  </span>
                )}
              </div>

              <p className="mt-2 text-[length:var(--text-sm)] text-[var(--text-tertiary)]">
                {plan.tagline}
              </p>

              <p className="mt-6 flex items-baseline gap-2">
                <span className="num text-[length:var(--text-h2)] font-semibold leading-none tracking-[-0.02em] text-[var(--text-primary)]">
                  {plan.price}
                </span>
                <span className="text-[length:var(--text-xs)] text-[var(--text-tertiary)]">
                  {plan.priceNote}
                </span>
              </p>

              <ul className="mt-6 flex-1 space-y-3">
                {plan.includes.map((item) => (
                  <li key={item} className="flex gap-3 text-[length:var(--text-sm)] leading-[1.6]">
                    <span aria-hidden="true" className="mt-[7px] shrink-0 text-[var(--accent)]">
                      <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                        <path
                          d="M5 12.5l4.5 4.5L19 7.5"
                          stroke="currentColor"
                          strokeWidth="2"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                        />
                      </svg>
                    </span>
                    <span className="text-[var(--text-secondary)]">{item}</span>
                  </li>
                ))}
              </ul>

              <Link
                to={plan.ctaHref}
                className={cn(
                  'mt-8 inline-flex h-12 w-full items-center justify-center rounded-[var(--radius-md)] border text-[15px] font-semibold transition-all duration-150',
                  plan.featured
                    ? 'border-transparent bg-[var(--accent)] text-[var(--text-inverse)] hover:bg-[var(--accent-hover)] hover:shadow-[var(--glow-accent)] hover:-translate-y-px'
                    : 'border-[var(--stroke-default)] bg-transparent text-[var(--text-primary)] hover:border-[var(--accent-line)] hover:bg-[var(--bg-elevated)]',
                )}
              >
                {plan.ctaLabel}
              </Link>
            </article>
          </RevealItem>
        ))}
      </RevealGroup>

      {/* 功能对比表 */}
      {!compact && (
        <div className="mt-12 overflow-x-auto rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)]">
          <table className="data-table min-w-[640px]">
            <caption className="sr-only">三档支持方案功能对比表</caption>
            <thead>
              <tr>
                <th scope="col" className="sticky left-0 z-[1] bg-[var(--bg-card)]">
                  功能
                </th>
                {pricingSection.plans.map((plan) => (
                  <th key={plan.id} scope="col" className="text-center">
                    {plan.name}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {pricingSection.comparison.map((row) => (
                <tr key={row.label}>
                  <th
                    scope="row"
                    className="sticky left-0 z-[1] whitespace-nowrap bg-[var(--bg-card)] text-left text-[length:var(--text-sm)] font-normal text-[var(--text-secondary)]"
                  >
                    {row.label}
                  </th>
                  {row.values.map((value, i) => (
                    <td key={`${row.label}-${i}`} className="text-center">
                      <CellValue value={value} />
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <p className="mt-6 max-w-[68em] text-[length:var(--text-xs)] leading-[1.6] text-[var(--text-tertiary)]">
        {pricingSection.footnote}
      </p>
    </Section>
  )
}

function CellValue({ value }: { value: string }) {
  if (value === 'yes') {
    return (
      <span className="inline-flex text-[var(--success)]" aria-label="支持">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <path
            d="M5 12.5l4.5 4.5L19 7.5"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </span>
    )
  }
  if (value === 'no') {
    return (
      <span className="inline-flex text-[var(--text-disabled)]" aria-label="不支持">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <path
            d="M6.5 6.5l11 11M17.5 6.5l-11 11"
            stroke="currentColor"
            strokeWidth="1.75"
            strokeLinecap="round"
          />
        </svg>
      </span>
    )
  }
  if (value === 'partial') {
    return (
      <span className="text-[var(--text-tertiary)]" aria-label="部分支持">
        —
      </span>
    )
  }
  return <span className="text-[var(--text-secondary)]">{value}</span>
}
