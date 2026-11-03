import { contactContent as C, siteMeta } from '../content/site'
import { PageHero } from '../components/PageHero'
import { ContactChannels, RepoBanner } from '../components/ContactChannels'
import { ContactForm } from '../components/ContactForm'
import { Reveal } from '../components/Reveal'
import { Section } from '../components/ui'

/**
 * 联系页
 */
export function Contact() {
  return (
    <>
      <PageHero
        eyebrow={C.hero.eyebrow}
        title={C.hero.title}
        lead={C.hero.lead}
        aside={
          <div className="surface-card p-6 sm:p-7">
            <span className="font-mono text-[11px] uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
              提问之前
            </span>
            <ul className="mt-5 space-y-4">
              {[
                '带上 macOS 版本与芯片型号',
                '带上你的机型与相关日志片段',
                '描述你期望的行为与实际行为',
              ].map((tip) => (
                <li key={tip} className="flex gap-3 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
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
                  {tip}
                </li>
              ))}
            </ul>
            <a
              href={siteMeta.repo}
              target="_blank"
              rel="noreferrer noopener"
              className="link-underline mt-6 inline-block font-mono text-[12.5px] text-[var(--text-secondary)]"
            >
              {siteMeta.repo}
            </a>
          </div>
        }
      />

      <ContactForm />

      {/* ── 提问渠道 ───────────────────────────────────────────── */}
      <ContactChannels />

      <RepoBanner />

      {/* ── 免责角标（BRIEF 强制：Hero + 页脚两处） ───────────────── */}
      <Section id="disclaimer" aria-labelledby="disclaimer-title">
        <Reveal>
          <div className="mx-auto flex max-w-[760px] gap-4 rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-inset)] p-6">
            <span aria-hidden="true" className="w-1 shrink-0 self-stretch bg-[var(--warning)]" />
            <div>
              <h2
                id="disclaimer-title"
                className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--warning)]"
              >
                使用须知 / Disclaimer
              </h2>
              <p className="mt-3 text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
                本项目仅供研究与个人学习使用。使用本软件自动控制游戏可能违反游戏服务条款，作者不对封号或其他任何后果负责，请自行评估风险。
              </p>
            </div>
          </div>
        </Reveal>
      </Section>
    </>
  )
}
