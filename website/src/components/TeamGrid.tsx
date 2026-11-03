import { teamSection } from '../content/site'
import { RevealGroup, RevealItem } from './Reveal'
import { Section, SectionHeading } from './ui'

/**
 * 团队成员 —— 角色位，不虚构人名与照片
 *
 * 规范：DESIGN_SYSTEM.md §5.8
 *   - 横向条目：flex row，gap 24px
 *   - 头像 72×72，--radius-sm（方形微圆角，不用圆形）
 *   - 抽象几何头像：CSS 渐变 + 首字母，不用人像图片
 *   - 姓名/角色位 --font-mono 12px --accent
 *   - 不做 hover 上浮（非可点击目标）
 */
export function TeamGrid() {
  return (
    <Section id="team" aria-labelledby="team-title">
      <SectionHeading
        id="team-title"
        eyebrow={teamSection.eyebrow}
        title={teamSection.title}
        lead={teamSection.lead}
      />

      <RevealGroup className="mt-12 grid grid-cols-1 gap-x-8 gap-y-10 md:grid-cols-2">
        {teamSection.members.map((member) => (
          <RevealItem key={member.role}>
            <article className="flex items-start gap-6">
              <div
                aria-hidden="true"
                className="flex size-[72px] shrink-0 items-center justify-center rounded-[var(--radius-sm)] border border-[var(--stroke-default)] font-mono text-[24px] font-semibold text-[var(--text-primary)]"
                style={{
                  background: `linear-gradient(135deg, ${member.gradient[0]}22, ${member.gradient[1]}33)`,
                }}
              >
                {member.initial}
              </div>
              <div className="min-w-0">
                <h3 className="text-[length:var(--text-h3)] leading-[1.25] tracking-[-0.015em]">
                  {member.role}
                </h3>
                <p className="mt-2 font-mono text-[12px] tracking-[0.04em] text-[var(--accent)]">
                  {member.scope.split('。')[0]}
                </p>
                <p className="mt-3 max-w-[42em] text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                  {member.scope}
                </p>
              </div>
            </article>
          </RevealItem>
        ))}
      </RevealGroup>

      <p className="mt-10 font-mono text-[12px] text-[var(--text-tertiary)]">
        {teamSection.note}
      </p>
    </Section>
  )
}
