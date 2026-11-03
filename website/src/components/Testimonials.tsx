import { testimonialSection } from '../content/site'
import { RevealGroup, RevealItem } from './Reveal'
import { Section, SectionHeading } from './ui'

/**
 * 用户评价 —— 场景/角色证言
 *
 * 规范：DESIGN_SYSTEM.md §5.9
 *   - 引号标记用 --text-label 尺寸的 " 字符（不用大号引号图标）
 *   - 正文 --text-body 16px / 1.7
 *   - 1px --stroke-subtle 分隔
 *   - 署名行：头像 40×40（--radius-xs）+ 姓名 + 身份
 *   - 不使用星级评分（虚构评分违背诚实原则）
 *   - 卡片顶部不加彩色条
 *   - 网格：lg 3 列 / md 2 列 / 移动 1 列
 */
export function Testimonials() {
  return (
    <Section id="testimonials" alt aria-labelledby="testimonials-title">
      <SectionHeading
        id="testimonials-title"
        eyebrow={testimonialSection.eyebrow}
        title={testimonialSection.title}
        lead={testimonialSection.lead}
      />

      <RevealGroup className="mt-12 grid grid-cols-1 gap-6 md:grid-cols-2 lg:grid-cols-3">
        {testimonialSection.items.map((item) => (
          <RevealItem key={item.persona} className="h-full">
            <figure className="flex h-full flex-col rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)] p-8">
              <span
                aria-hidden="true"
                className="font-mono text-[11px] leading-none text-[var(--accent)]"
              >
                &quot;
              </span>
              <blockquote className="mt-3 flex-1 text-[length:var(--text-body)] leading-[1.7] text-[var(--text-primary)]">
                {item.quote}
              </blockquote>

              <div className="mt-6 border-t border-[var(--stroke-subtle)] pt-5">
                <div className="flex items-center gap-3">
                  <span
                    aria-hidden="true"
                    className="flex size-10 shrink-0 items-center justify-center rounded-[var(--radius-xs)] border border-[var(--stroke-default)] font-mono text-[14px] font-semibold text-[var(--text-primary)]"
                    style={{
                      background: `linear-gradient(135deg, ${item.gradient[0]}22, ${item.gradient[1]}33)`,
                    }}
                  >
                    {item.initial}
                  </span>
                  <div className="min-w-0">
                    <figcaption className="text-[length:var(--text-sm)] font-semibold text-[var(--text-primary)]">
                      {item.persona}
                    </figcaption>
                    <p className="mt-0.5 text-[length:var(--text-xs)] text-[var(--text-tertiary)]">
                      {item.role}
                    </p>
                  </div>
                </div>
                <p className="num mt-4 text-[12px] text-[var(--text-tertiary)]">
                  {item.fact}
                </p>
              </div>
            </figure>
          </RevealItem>
        ))}
      </RevealGroup>
    </Section>
  )
}
