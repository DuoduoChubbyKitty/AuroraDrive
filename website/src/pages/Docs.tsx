import { docsContent as D, faqSection, quickStart } from '../content/site'
import { PageHero } from '../components/PageHero'
import { Figure } from '../components/Figure'
import { Reveal, RevealGroup, RevealItem } from '../components/Reveal'
import { Section, SectionHeading } from '../components/ui'
import { CodeBlock } from '../components/CodeBlock'
import { Faq } from '../components/Faq'

/**
 * 文档与快速开始页
 * 面向：macOS / 视觉工程开发者
 */
export function Docs() {
  return (
    <>
      <PageHero
        eyebrow={D.hero.eyebrow}
        title={D.hero.title}
        lead={D.hero.lead}
        aside={
          <div className="surface-card overflow-hidden">
            <div className="flex items-center justify-between gap-3 border-b border-[var(--stroke-default)] bg-[var(--bg-card)] px-4 py-2.5">
              <span className="font-mono text-[12px] text-[var(--text-tertiary)]">
                run.sh
              </span>
              <span className="font-mono text-[11px] uppercase tracking-[0.08em] text-[var(--text-disabled)]">
                bash
              </span>
            </div>
            <div className="px-4 py-3">
              <pre className="overflow-x-auto font-mono text-[13px] leading-[1.7]">
                <code>
                  <span className="text-[var(--accent)]">$</span>{' '}
                  <span className="text-[var(--text-primary)]">./run.sh --status</span>
                  {'\n'}
                  <span className="text-[var(--syn-comment)]"># environment OK</span>
                </code>
              </pre>
            </div>
          </div>
        }
      />

      {/* ── Quick Start ─────────────────────────────────────────── */}
      <Section id="quick-start" aria-labelledby="quick-start-title">
        <SectionHeading
          id="quick-start-title"
          eyebrow={D.quickStart.eyebrow}
          title={D.quickStart.title}
          lead={D.quickStart.lead}
        />
        <Reveal className="mt-10">
          <CodeBlock
            code={quickStart.code}
            filename="run.sh"
            language="bash"
            showLineNumbers={false}
          />
        </Reveal>
        <Reveal delay={0.06}>
          <dl className="mt-6 grid grid-cols-1 gap-px overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)] sm:grid-cols-2">
            <div className="bg-[var(--bg-card)] p-5">
              <dt className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
                环境要求
              </dt>
              <dd className="mt-3 font-mono text-[13px] leading-[1.7] text-[var(--text-primary)]">
                {quickStart.env.replace('环境要求：', '')}
              </dd>
            </div>
            <div className="bg-[var(--bg-card)] p-5">
              <dt className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
                系统权限
              </dt>
              <dd className="mt-3 font-mono text-[13px] leading-[1.7] text-[var(--text-primary)]">
                {quickStart.permissions.replace('系统权限：', '')}
              </dd>
            </div>
          </dl>
        </Reveal>
      </Section>

      {/* ── 上手指南 ────────────────────────────────────────────── */}
      <Section id="guides" alt aria-labelledby="guides-title">
        <SectionHeading
          id="guides-title"
          eyebrow={D.guides.eyebrow}
          title={D.guides.title}
          lead={D.guides.lead}
        />
        <RevealGroup className="mt-12 grid grid-cols-1 gap-6 md:grid-cols-2">
          {D.guides.items.map((item) => (
            <RevealItem key={item.index} className="h-full">
              <article className="surface-card flex h-full flex-col p-6">
                <span className="font-mono text-[11px] text-[var(--text-tertiary)]">
                  {item.index}
                </span>
                <h3 className="mt-4 text-[length:var(--text-h3)] tracking-[-0.015em]">
                  {item.title}
                </h3>
                <p className="mt-3 text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
                  {item.body}
                </p>
              </article>
            </RevealItem>
          ))}
        </RevealGroup>
      </Section>

      {/* ── 架构文档库 ──────────────────────────────────────────── */}
      <Section id="doc-library" aria-labelledby="doc-library-title">
        <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-12 lg:gap-12">
          <div className="lg:col-span-6">
            <Reveal>
              <SectionHeading
                id="doc-library-title"
                eyebrow={D.docsIndex.eyebrow}
                title={D.docsIndex.title}
                lead={D.docsIndex.lead}
              />
              <p className="mt-8 max-w-[42em] text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
                文档按代码-00 到 代码-39 编号，覆盖从捕获、推理、注入到定位、地图与 AI 助手的每一条链路。
                这种编号方式本身就是设计目标：任何一条结论都能被独立核对，不需要相信作者。
              </p>
              <div className="mt-8 flex flex-wrap gap-3">
                <a
                  href="https://github.com/DuoduoChubbyKitty/AuroraDrive"
                  target="_blank"
                  rel="noreferrer noopener"
                  className="inline-flex h-11 items-center rounded-[var(--radius-md)] border border-[var(--stroke-default)] px-4 text-[14px] text-[var(--text-primary)] transition-colors duration-120 hover:border-[var(--accent-line)] hover:bg-[var(--bg-elevated)]"
                >
                  在 GitHub 上浏览文档
                </a>
              </div>
            </Reveal>
          </div>
          <div className="lg:col-span-6">
            <Reveal delay={0.08}>
              <Figure
                src="/images/developer-docs.jpg"
                alt="抽象技术插画：精密线框与测量网格构成的文档结构意象"
                ratio="16 / 9"
              />
            </Reveal>
          </div>
        </div>
      </Section>

      <Faq items={faqSection.items.slice(1, 5)} />
    </>
  )
}
