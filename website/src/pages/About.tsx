import { aboutContent as A } from '../content/site'
import { PageHero } from '../components/PageHero'
import { Reveal, RevealGroup, RevealItem } from '../components/Reveal'
import { Section, SectionHeading, Badge } from '../components/ui'
import { StatCompare } from '../components/Stats'
import { TeamGrid } from '../components/TeamGrid'

/**
 * 关于项目页
 */
export function About() {
  return (
    <>
      <PageHero
        eyebrow={A.hero.eyebrow}
        title={A.hero.title}
        lead={A.hero.lead}
        aside={
          <div className="surface-card p-6 sm:p-7">
            <span className="font-mono text-[11px] uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
              一句话定位
            </span>
            <p className="mt-4 max-w-[42em] text-[length:var(--text-body)] leading-[1.7] text-[var(--text-primary)]">
              看得见 → 想得出 → 按得下的三段式闭环桌面系统。
            </p>
            <div className="mt-6 flex flex-wrap gap-2">
              <Badge tone="accent">GPL-3.0-or-later</Badge>
              <Badge tone="neutral">macOS 26+</Badge>
              <Badge tone="neutral">Apple Silicon</Badge>
              <Badge tone="neutral">Swift 6 / SwiftUI</Badge>
            </div>
          </div>
        }
      />

      {/* ── 是什么 / 不是什么 ──────────────────────────────────── */}
      <Section id="position" aria-labelledby="position-title">
        <SectionHeading
          id="position-title"
          eyebrow={A.position.eyebrow}
          title={A.position.title}
          lead={A.position.lead}
        />
        <div className="mt-12 grid grid-cols-1 gap-6 lg:grid-cols-2">
          <Reveal>
            <div className="surface-card h-full p-8">
              <h3 className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--success)]">
                它是
              </h3>
              <ul className="mt-6 space-y-4">
                {A.position.is.map((item) => (
                  <li key={item} className="flex gap-3">
                    <span aria-hidden="true" className="mt-[7px] shrink-0 text-[var(--success)]">
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
                    <span className="text-[length:var(--text-body)] leading-[1.7] text-[var(--text-secondary)]">
                      {item}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
          <Reveal delay={0.08}>
            <div className="surface-card h-full p-8">
              <h3 className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-disabled)]">
                它不是
              </h3>
              <ul className="mt-6 space-y-4">
                {A.position.isNot.map((item) => (
                  <li key={item} className="flex gap-3">
                    <span aria-hidden="true" className="mt-[7px] shrink-0 text-[var(--text-disabled)]">
                      <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                        <path
                          d="M6.5 6.5l11 11M17.5 6.5l-11 11"
                          stroke="currentColor"
                          strokeWidth="1.75"
                          strokeLinecap="round"
                        />
                      </svg>
                    </span>
                    <span className="text-[length:var(--text-body)] leading-[1.7] text-[var(--text-secondary)]">
                      {item}
                    </span>
                  </li>
                ))}
              </ul>
              <p className="mt-8 border-t border-[var(--stroke-subtle)] pt-6 text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-tertiary)]">
                说清边界比什么都重要。一个名字听起来像通用 SDK 的项目，最容易让人按错误的预期去用它。
              </p>
            </div>
          </Reveal>
        </div>
      </Section>

      {/* ── 三类受众 ────────────────────────────────────────────── */}
      <Section id="audiences" alt aria-labelledby="audiences-title">
        <SectionHeading
          id="audiences-title"
          eyebrow={A.audiences.eyebrow}
          title={A.audiences.title}
          lead={A.audiences.lead}
        />
        <RevealGroup className="mt-12 grid grid-cols-1 gap-6 lg:grid-cols-3">
          {A.audiences.items.map((item) => (
            <RevealItem key={item.index} className="h-full">
              <article className="surface-card flex h-full flex-col p-8">
                <span className="num text-[13px] text-[var(--text-tertiary)]">
                  {item.index}
                </span>
                <h3 className="mt-4 text-[length:var(--text-h3)] leading-[1.25] tracking-[-0.015em]">
                  {item.title}
                </h3>
                <p className="mt-4 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-tertiary)]">
                  {item.need}
                </p>
                <p className="mt-5 flex-1 text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
                  {item.answer}
                </p>
                <a
                  href={item.cta.to}
                  className="link-underline mt-6 self-start text-[14px] text-[var(--accent)]"
                >
                  {item.cta.label} →
                </a>
              </article>
            </RevealItem>
          ))}
        </RevealGroup>
      </Section>

      {/* ── 工程规模 ────────────────────────────────────────────── */}
      <Section id="scale" aria-labelledby="scale-title">
        <SectionHeading
          id="scale-title"
          eyebrow={A.scale.eyebrow}
          title={A.scale.title}
          lead={A.scale.lead}
        />
        <Reveal className="mt-12">
          <dl className="grid grid-cols-1 gap-px overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)] sm:grid-cols-2 lg:grid-cols-4">
            {A.scale.items.map((item) => (
              <div key={item.label} className="bg-[var(--bg-card)] p-8">
                <dt className="sr-only">{item.label}</dt>
                <dd>
                  <span className="num block text-[length:clamp(32px,4vw,48px)] font-semibold leading-none tracking-[-0.03em] text-[var(--text-primary)]">
                    {item.value.toLocaleString('en-US')}
                    <span className="ml-[0.15em] text-[0.42em] font-normal text-[var(--text-tertiary)]">
                      {item.unit}
                    </span>
                  </span>
                  <span className="mt-4 block font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
                    {item.label}
                  </span>
                </dd>
              </div>
            ))}
          </dl>
        </Reveal>

        {/* 前后对比指标 */}
        <Reveal className="mt-8">
          <div className="grid grid-cols-1 gap-px overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)] sm:grid-cols-3">
            <StatCompare
              before="19.3%"
              after="5.4%"
              label="路网断头率"
              note="加入 route_graph.json 先验后"
            />
            <StatCompare
              before="612"
              after="664"
              label="路网节点"
              note="边数同时从 825 增至 932"
            />
            <StatCompare
              before="10.28ms"
              after="1.91ms"
              label="光流耗时"
              note="Apple VTOpticalFlow 对比 OpenCV DIS"
              unit=""
            />
          </div>
        </Reveal>
      </Section>

      {/* ── 开源与合规 ──────────────────────────────────────────── */}
      <Section id="license" alt aria-labelledby="license-title">
        <SectionHeading
          id="license-title"
          eyebrow={A.license.eyebrow}
          title={A.license.title}
          lead={A.license.lead}
        />

        <Reveal className="mt-12">
          <div className="surface-card p-8">
            <div className="flex flex-wrap items-center justify-between gap-4">
              <h3 className="text-[length:var(--text-h3)] tracking-[-0.015em]">
                {A.license.self.name}
              </h3>
              <Badge tone="accent">{A.license.self.license}</Badge>
            </div>
            <p className="mt-4 max-w-[42em] text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
              {A.license.self.usage}
            </p>
            <p className="mt-4 font-mono text-[12px] text-[var(--text-tertiary)]">
              {A.license.self.note}
            </p>
          </div>
        </Reveal>

        <RevealGroup className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-3">
          {A.license.thirdParty.map((item) => (
            <RevealItem key={item.name} className="h-full">
              <article className="surface-card flex h-full flex-col p-8">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <h3 className="font-mono text-[15px] font-semibold text-[var(--text-primary)]">
                    {item.name}
                  </h3>
                  <Badge tone={item.license === 'AGPL-3.0' ? 'warning' : 'neutral'}>
                    {item.license}
                  </Badge>
                </div>
                <p className="mt-5 flex-1 text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
                  {item.usage}
                </p>
                <p className="mt-5 border-t border-[var(--stroke-subtle)] pt-4 text-[length:var(--text-xs)] leading-[1.6] text-[var(--text-tertiary)]">
                  {item.note}
                </p>
              </article>
            </RevealItem>
          ))}
        </RevealGroup>
      </Section>

      <TeamGrid />
    </>
  )
}
