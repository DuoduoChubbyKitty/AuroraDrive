import { heroContent } from '../content/site'
import { ButtonLink } from './ui'
import { StatusDot } from './ui'

/**
 * Hero
 *
 * 规范：DESIGN_SYSTEM.md §5.2
 *   - lg 以上左右分栏（左文 5 / 右视觉 7，gap 48px）；md 及以下上下
 *   - 禁止居中排版
 *   - H1 --text-display，max-width 14em，最多 2 行
 *   - 背景 4 层：bg-base / 极光光晕(blur 120px, opacity .18) / 网格底纹 / 颗粒噪点
 *   - 右侧视觉位放"实时管线示意"构件（管线图 + 状态灯 + 数字），不是氛围插画
 *   - 免责角标固定右下，--warning 竖条
 */
export function Hero() {
  const titleLines = heroContent.title.split('\n')

  return (
    <section className="relative overflow-hidden" aria-labelledby="hero-title">
      {/* ── 背景层 L1/L2/L3 ─────────────────────────────────────── */}
      <div aria-hidden="true" className="pointer-events-none absolute inset-0">
        {/* L1 极光光晕 */}
        <div
          className="absolute -right-1/4 -top-1/4 h-[60%] w-[120%] opacity-[var(--hero-glow-opacity)]"
          style={{
            background:
              'linear-gradient(100deg, var(--accent) 0%, var(--accent-2) 48%, var(--accent-3) 100%)',
            filter: 'blur(120px)',
          }}
        />
        {/* L2 仪表网格底纹 */}
        <div
          className="absolute inset-0"
          style={{
            backgroundImage:
              'linear-gradient(var(--grid-line) 1px, transparent 1px), linear-gradient(90deg, var(--grid-line) 1px, transparent 1px)',
            backgroundSize: '48px 48px',
            maskImage:
              'radial-gradient(ellipse at 50% 0%, black, transparent 72%)',
            WebkitMaskImage:
              'radial-gradient(ellipse at 50% 0%, black, transparent 72%)',
          }}
        />
        {/* L3 颗粒噪点 */}
        <svg className="absolute inset-0 size-full opacity-[0.035] mix-blend-overlay">
          <filter id="hero-grain">
            <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" />
          </filter>
          <rect width="100%" height="100%" filter="url(#hero-grain)" />
        </svg>
      </div>

      <div className="container-page relative pb-16 pt-12 lg:pb-20 lg:pt-20">
        <div className="grid grid-cols-1 items-start gap-8 lg:grid-cols-12 lg:gap-12">
          {/* ── 左：文案 ──────────────────────────────────────────── */}
          <div className="lg:col-span-5">
            <span className="eyebrow inline-flex items-center gap-2">
              <StatusDot />
              {heroContent.eyebrow}
            </span>

            <h1
              id="hero-title"
              className="mt-6 text-[length:var(--text-display)] leading-[1.04] tracking-[-0.03em] max-sm:leading-[1.12]"
              style={{ maxWidth: '14em' }}
            >
              {titleLines.map((line, i) => (
                <span key={line} className="block">
                  {i === titleLines.length - 1 ? (
                    <>
                      {line.replace(heroContent.gradientWord, '')}
                      <span className="aurora-text">{heroContent.gradientWord}</span>
                    </>
                  ) : (
                    line
                  )}
                </span>
              ))}
            </h1>

            <p
              className="mt-6 max-w-[46em] text-[length:var(--text-lead)] leading-[1.55] text-[var(--text-secondary)]"
            >
              {heroContent.lead}
            </p>

            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <ButtonLink to={heroContent.primaryCta.to} size="lg" className="w-full sm:w-auto">
                {heroContent.primaryCta.label}
              </ButtonLink>
              <ButtonLink
                to={heroContent.secondaryCta.to}
                size="lg"
                variant="secondary"
                className="w-full sm:w-auto"
              >
                {heroContent.secondaryCta.label}
              </ButtonLink>
            </div>
          </div>

          {/* ── 右：实时管线示意（不是氛围插画） ──────────────────── */}
          <div className="lg:col-span-7">
            <PipelineConsole />
          </div>
        </div>

        {/* ── 免责角标 ───────────────────────────────────────────── */}
        <div className="mt-12 flex justify-start lg:mt-16 lg:justify-end">
          <div className="flex max-w-[320px] gap-3 rounded-[var(--radius-xs)] border border-[var(--stroke-default)] bg-[var(--bg-inset)] p-3">
            <span
              aria-hidden="true"
              className="w-0.5 shrink-0 self-stretch bg-[var(--warning)]"
            />
            <p className="text-[12.5px] leading-[1.5] text-[var(--text-tertiary)]">
              {heroContent.disclaimer}
            </p>
          </div>
        </div>
      </div>
    </section>
  )
}

/**
 * 实时管线示意 —— 管线图 + 状态灯 + 数字
 * 用直角折线（工程图语汇），不是曲线插画。
 */
function PipelineConsole() {
  const stages = [
    { idx: '01', label: '捕获', tech: 'ScreenCaptureKit', read: '15fps' },
    { idx: '02', label: '推理', tech: 'CoreML / M9', read: '15Hz' },
    { idx: '03', label: '注入', tech: 'CGEvent', read: '按键事件' },
  ]

  return (
    <div className="surface-card overflow-hidden">
      {/* 标题栏 */}
      <div className="flex items-center justify-between gap-3 border-b border-[var(--stroke-default)] bg-[var(--bg-card)] px-4 py-2.5">
        <div className="flex items-center gap-2.5">
          <StatusDot />
          <span className="font-mono text-[12px] text-[var(--text-tertiary)]">
            aurora-engine · runtime
          </span>
        </div>
        <span className="font-mono text-[11px] uppercase tracking-[0.08em] text-[var(--text-disabled)]">
          live
        </span>
      </div>

      {/* 管线图 */}
      <div className="p-5 sm:p-6">
        <ol className="grid grid-cols-1 gap-3 sm:grid-cols-3 sm:gap-0">
          {stages.map((stage, i) => (
            <li key={stage.idx} className="relative sm:pr-6">
              {/* 连接线（直角折线） */}
              {i < stages.length - 1 && (
                <span
                  aria-hidden="true"
                  className="absolute left-0 top-6 hidden h-px w-full bg-[var(--stroke-strong)] sm:block sm:left-auto sm:right-0 sm:top-6 sm:w-6 sm:-translate-x-0"
                  style={{ right: 0, top: 24 }}
                />
              )}
              <div className="relative">
                <div className="flex items-center gap-2">
                  <span className="font-mono text-[11px] text-[var(--text-tertiary)]">
                    {stage.idx}
                  </span>
                  <span className="font-mono text-[11px] uppercase tracking-[0.08em] text-[var(--accent)]">
                    {stage.label}
                  </span>
                </div>
                <div className="mt-2 h-px w-full bg-[var(--stroke-subtle)]" />
                <p className="mt-2 font-mono text-[12px] text-[var(--text-secondary)]">
                  {stage.tech}
                </p>
                <p className="num mt-1 text-[13px] text-[var(--text-primary)]">
                  {stage.read}
                </p>
              </div>
            </li>
          ))}
        </ol>

        {/* 仪表读数 */}
        <dl className="mt-6 grid grid-cols-2 gap-px overflow-hidden rounded-[var(--radius-sm)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)]">
          {heroContent.readouts.map((item) => (
            <div key={item.label} className="bg-[var(--bg-inset)] px-4 py-3">
              <dt className="font-mono text-[10.5px] uppercase tracking-[0.08em] text-[var(--text-tertiary)]">
                {item.label}
              </dt>
              <dd
                className="num mt-1 text-[15px]"
                style={{
                  color:
                    item.tone === 'accent'
                      ? 'var(--accent)'
                      : 'var(--text-primary)',
                }}
              >
                {item.value}
              </dd>
            </div>
          ))}
        </dl>

        <p className="mt-4 font-mono text-[12px] leading-[1.6] text-[var(--text-tertiary)]">
          {heroContent.pipelineCaption}
        </p>
      </div>
    </div>
  )
}
