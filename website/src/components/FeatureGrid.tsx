import { featureGrid } from '../content/site'
import { Icon } from './Icon'
import { RevealGroup, RevealItem } from './Reveal'
import { Section, SectionHeading } from './ui'

/**
 * 功能特性网格
 *
 * 规范：DESIGN_SYSTEM.md §5.3
 *   - md 2 列 / lg 3 列 / xl 4 列，gap 32px
 *   - 卡片：--bg-card，1px --stroke-default，--radius-md，padding 24px，无阴影
 *   - 内部结构：序号 → 图标 → 标题 → 正文（必须含具体数字或机制）→ 来源引用
 *   - Hover：描边 → --accent-line，translateY(-2px)，--shadow-md，禁止缩放
 *
 * 差异化：部分卡片改为横向条目（左数字/图形 40%，右文字 60%），
 * 与常规卡片混排形成节奏 —— 避免「每卡一图标一标题一行字」的模板感。
 */
export function FeatureGrid() {
  const items = featureGrid.items

  return (
    <Section id="features" aria-labelledby="features-title">
      <SectionHeading
        id="features-title"
        eyebrow={featureGrid.eyebrow}
        title={featureGrid.title}
        lead={featureGrid.lead}
      />

      <RevealGroup className="mt-12 grid grid-cols-1 gap-6 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
        {items.map((item, index) => {
          // 每 5 张插一张横向条目卡，打破均匀三行模板
          const wide = index % 5 === 4

          if (wide) {
            return (
              <RevealItem
                key={item.index}
                className="md:col-span-2 lg:col-span-3 xl:col-span-4"
              >
                <article className="surface-card hover-lift flex flex-col gap-6 p-6 sm:flex-row sm:items-start sm:gap-8">
                  <div className="sm:w-[40%] sm:shrink-0">
                    <span className="font-mono text-[11px] text-[var(--text-tertiary)]">
                      {item.index}
                    </span>
                    <div className="mt-4 flex size-12 items-center justify-center rounded-[var(--radius-sm)] border border-[var(--stroke-default)] bg-[var(--bg-inset)] text-[var(--accent)]">
                      {item.icon && <Icon name={item.icon} />}
                    </div>
                    <h3 className="mt-5 text-[length:var(--text-h3)] leading-[1.25] tracking-[-0.015em]">
                      {item.title}
                    </h3>
                  </div>
                  <div className="sm:w-[60%]">
                    <p className="text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                      {item.body}
                    </p>
                    {item.source && (
                      <p className="mt-4 font-mono text-[12px] text-[var(--text-tertiary)]">
                        {item.source}
                      </p>
                    )}
                  </div>
                </article>
              </RevealItem>
            )
          }

          return (
            <RevealItem key={item.index} className="h-full">
              <article className="surface-card hover-lift flex h-full flex-col p-6">
                <div className="flex items-start justify-between gap-4">
                  <span className="font-mono text-[11px] text-[var(--text-tertiary)]">
                    {item.index}
                  </span>
                  {item.icon && (
                    <span className="text-[var(--accent)]">
                      <Icon name={item.icon} />
                    </span>
                  )}
                </div>
                <h3 className="mt-4 text-[length:var(--text-h3)] leading-[1.25] tracking-[-0.015em]">
                  {item.title}
                </h3>
                <p className="mt-3 flex-1 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                  {item.body}
                </p>
                {item.source && (
                  <p className="mt-5 font-mono text-[12px] text-[var(--text-tertiary)]">
                    {item.source}
                  </p>
                )}
              </article>
            </RevealItem>
          )
        })}
      </RevealGroup>
    </Section>
  )
}
