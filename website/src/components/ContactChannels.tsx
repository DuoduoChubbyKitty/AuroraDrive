import { contactContent as C, siteMeta } from '../content/site'
import { Reveal, RevealGroup, RevealItem } from '../components/Reveal'
import { Section, SectionHeading } from '../components/ui'

/**
 * 联系渠道区块
 *
 * 本区块只提供「去哪里提问」的渠道导航。
 * 说明文字如实标注「后端接入中」，为后续接入真实后端留出口径。
 */
export function ContactChannels() {
  return (
    <Section id="channels" aria-labelledby="channels-title">
      <Reveal>
        <SectionHeading
          id="channels-title"
          eyebrow={C.channels.eyebrow}
          title={C.channels.title}
          lead={C.channels.lead}
        />
      </Reveal>

      <RevealGroup className="mt-12 grid grid-cols-1 gap-6 md:grid-cols-3">
        {C.channels.items.map((item) => (
          <RevealItem key={item.index} className="h-full">
            <article className="surface-card hover-lift flex h-full flex-col p-6">
              <span className="font-mono text-[11px] text-[var(--text-tertiary)]">
                {item.index}
              </span>
              <h3 className="mt-4 text-[length:var(--text-h3)] leading-snug font-semibold">
                {item.title}
              </h3>
              <p className="mt-3 flex-1 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                {item.body}
              </p>
              <a
                href={item.href}
                target={item.href.startsWith('http') ? '_blank' : undefined}
                rel={item.href.startsWith('http') ? 'noreferrer noopener' : undefined}
                className="mt-6 inline-flex items-center gap-1.5 font-mono text-[12.5px] text-[var(--accent)] transition-colors duration-150 hover:text-[var(--accent-hover)]"
              >
                {item.action}
                <span aria-hidden="true">→</span>
              </a>
            </article>
          </RevealItem>
        ))}
      </RevealGroup>

      <Reveal>
        <p className="mt-10 text-[length:var(--text-xs)] leading-relaxed text-[var(--text-tertiary)]">
          表单后端正在接入中，当前为前端模拟提交。急事请直接走 GitHub Issues ——
          那里能直接看到回复。
        </p>
      </Reveal>
    </Section>
  )
}

/**
 * 仓库地址展示 —— 代替表单的「联系方式」区块
 */
export function RepoBanner() {
  return (
    <Section id="repo" alt aria-labelledby="repo-title">
      <Reveal>
        <div className="surface-card flex flex-col gap-6 p-7 sm:flex-row sm:items-center sm:justify-between sm:p-8">
          <div>
            <span className="eyebrow">源码仓库</span>
            <h2
              id="repo-title"
              className="mt-3 text-[length:var(--text-h3)] font-semibold"
            >
              一条命令，把整个项目拿到你机器上
            </h2>
            <p className="mt-3 font-mono text-[12.5px] text-[var(--text-secondary)]">
              {siteMeta.repo}
            </p>
          </div>
          <a
            href={siteMeta.repo}
            target="_blank"
            rel="noreferrer noopener"
            className="inline-flex h-11 shrink-0 items-center justify-center gap-2 rounded-[var(--radius-md)] bg-[var(--accent-fill)] px-5 text-[14px] font-semibold text-[var(--text-inverse)] transition-all duration-150 hover:bg-[var(--accent-hover)] hover:shadow-[var(--glow-accent)] hover:-translate-y-px"
          >
            打开仓库
            <span aria-hidden="true">↗</span>
          </a>
        </div>
      </Reveal>
    </Section>
  )
}
