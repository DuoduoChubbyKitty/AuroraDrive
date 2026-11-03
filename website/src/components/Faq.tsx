import { useId, useState } from 'react'
import { faqSection } from '../content/site'
import { cn } from '../lib/cn'
import { RevealGroup, RevealItem } from './Reveal'
import { Section, SectionHeading } from './ui'

/**
 * FAQ 手风琴
 *
 * 规范：DESIGN_SYSTEM.md §5.7
 *   - 展开动画用 grid-template-rows: 0fr → 1fr 技巧，overflow: hidden
 *   - 时长 260ms，cubic-bezier(0.4, 0, 0.2, 1)
 *   - 箭头旋转 180°
 *   - 一次只展开一项
 *   - 语义：<button aria-expanded> + <div role="region" aria-labelledby>
 *   - 容器 max-width 760px
 */
export function Faq({ items = faqSection.items }: { items?: typeof faqSection.items }) {
  const [openIndex, setOpenIndex] = useState<number | null>(0)
  const baseId = useId()

  return (
    <Section id="faq" alt aria-labelledby="faq-title">
      <div className="mx-auto w-full" style={{ maxWidth: '760px' }}>
        <SectionHeading
          id="faq-title"
          eyebrow={faqSection.eyebrow}
          title={faqSection.title}
          lead={faqSection.lead}
          align="center"
        />

        <RevealGroup className="mt-12 overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)]">
          {items.map((item, index) => {
            const isOpen = openIndex === index
            const buttonId = `${baseId}-q-${index}`
            const panelId = `${baseId}-a-${index}`

            return (
              <RevealItem
                key={item.q}
                className={cn(
                  'border-b border-[var(--stroke-subtle)] last:border-b-0',
                )}
              >
                <h3>
                  <button
                    type="button"
                    id={buttonId}
                    aria-expanded={isOpen}
                    aria-controls={panelId}
                    onClick={() => setOpenIndex(isOpen ? null : index)}
                    className="flex w-full items-center justify-between gap-4 px-6 py-5 text-left transition-colors duration-120 hover:bg-[var(--bg-surface)]"
                  >
                    <span className="text-[length:var(--text-body)] font-medium leading-[1.5] text-[var(--text-primary)]">
                      {item.q}
                    </span>
                    <span
                      aria-hidden="true"
                      className={cn(
                        'shrink-0 text-[var(--text-tertiary)] transition-transform duration-[260ms] hover:text-[var(--accent)]',
                        isOpen && 'rotate-180 text-[var(--accent)]',
                      )}
                      style={{ transitionTimingFunction: 'cubic-bezier(0.4, 0, 1, 1)' }}
                    >
                      <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                        <path
                          d="M5.5 9l6.5 6.5L18.5 9"
                          stroke="currentColor"
                          strokeWidth="1.75"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                        />
                      </svg>
                    </span>
                  </button>
                </h3>

                <div
                  id={panelId}
                  role="region"
                  aria-labelledby={buttonId}
                  className="grid transition-[grid-template-rows] duration-[260ms]"
                  style={{
                    gridTemplateRows: isOpen ? '1fr' : '0fr',
                    transitionTimingFunction: 'cubic-bezier(0.4, 0, 0.2, 1)',
                  }}
                >
                  <div className="overflow-hidden">
                    <p className="px-6 pb-5 pr-10 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                      {item.a}
                    </p>
                  </div>
                </div>
              </RevealItem>
            )
          })}
        </RevealGroup>
      </div>
    </Section>
  )
}
