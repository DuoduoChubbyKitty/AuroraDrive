import { statsSection } from '../content/site'
import type { StatItem } from '../content/site'
import { formatNumber, useCountUp } from '../lib/useCountUp'
import { RevealGroup, RevealItem } from './Reveal'
import { Section, SectionHeading } from './ui'

/**
 * 数据统计区
 *
 * 规范：DESIGN_SYSTEM.md §5.4 —— 全站最重要的视觉资产
 *   - 布局 4 列（xl）/ 3（lg）/ 2（md）/ 1（xs）
 *   - 分隔：列间 1px 竖线 --stroke-subtle；外框上下各 1px --stroke-default
 *   - 数值：--font-mono，clamp(34px,4vw,56px)，tabular-nums
 *   - 单位 0.5em，--text-tertiary，不参与滚动计数
 *   - 标签：11px mono 全大写
 *   - 滚动计数：IO threshold 0.4，once，1200ms ease-out
 *   - 前后对比用两段并置，不做动画对撞
 */
export function Stats() {
  return (
    <Section id="stats" alt aria-labelledby="stats-title">
      <SectionHeading
        id="stats-title"
        eyebrow={statsSection.eyebrow}
        title={statsSection.title}
        lead={statsSection.lead}
      />

      {/* 6 个数字用 3 列（2 行 × 3）—— 4 列会让末行只落 2 个，留出空洞 */}
      <RevealGroup className="mt-12 grid grid-cols-1 gap-px border-y border-[var(--stroke-default)] bg-[var(--stroke-subtle)] sm:grid-cols-2 lg:grid-cols-3">
        {statsSection.items.map((item) => (
          <RevealItem key={item.label} className="bg-[var(--bg-surface)]">
            <StatCell item={item} />
          </RevealItem>
        ))}
      </RevealGroup>
    </Section>
  )
}

function StatCell({ item }: { item: StatItem }) {
  const { ref, value } = useCountUp(item.value)
  const decimals = item.decimals ?? 0

  return (
    <div className="px-1 py-8 sm:px-6">
      <p className="num text-[length:clamp(34px,4vw,56px)] font-semibold leading-none tracking-[-0.03em] text-[var(--text-primary)]">
        <span ref={ref}>{formatNumber(value, decimals)}</span>
        {item.unit && (
          <span className="ml-[0.15em] text-[0.5em] font-normal text-[var(--text-tertiary)]">
            {item.unit}
          </span>
        )}
      </p>
      <p className="mt-4 font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
        {item.label}
      </p>
      {item.note && (
        <p className="mt-2 text-[length:var(--text-xs)] leading-[1.5] text-[var(--text-tertiary)]">
          {item.note}
        </p>
      )}
    </div>
  )
}

/**
 * 前后对比型指标 —— 两段并置（旧值 --text-tertiary + 箭头 + 新值 --text-primary）
 * 用于「19.3% → 5.4%」「612 → 664」这类数据
 */
export function StatCompare({
  before,
  after,
  label,
  note,
  unit,
}: {
  before: string
  after: string
  label: string
  note?: string
  unit?: string
}) {
  return (
    <div className="px-1 py-8 sm:px-6">
      <p className="num text-[length:clamp(28px,3.2vw,44px)] font-semibold leading-none tracking-[-0.03em]">
        <span className="text-[var(--text-tertiary)]">{before}</span>
        <span className="mx-2 text-[var(--text-disabled)]" aria-hidden="true">
          →
        </span>
        <span className="text-[var(--text-primary)]">{after}</span>
        {unit && (
          <span className="ml-[0.15em] text-[0.5em] font-normal text-[var(--text-tertiary)]">
            {unit}
          </span>
        )}
      </p>
      <p className="mt-4 font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
        {label}
      </p>
      {note && (
        <p className="mt-2 text-[length:var(--text-xs)] leading-[1.5] text-[var(--text-tertiary)]">
          {note}
        </p>
      )}
    </div>
  )
}
