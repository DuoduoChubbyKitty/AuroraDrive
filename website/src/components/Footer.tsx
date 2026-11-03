import { Link } from 'react-router-dom'
import { footerContent, siteMeta } from '../content/site'

/**
 * 页脚
 *
 * 规范：DESIGN_SYSTEM.md §5.11
 *   - 顶部 1px --stroke-default 全宽横线
 *   - 上区 4 列（品牌 + 3 组链接）
 *   - 免责区：--bg-inset 底 + 3px --warning 左边框
 *   - 致谢区块单列，必须包含 MaaNTE 的 AGPL-3.0 传染性说明
 *
 * Footer 位于 PageTransition 之外 —— 路由切换时保持静止，维持连续性。
 */
export function Footer() {
  return (
    <footer className="border-t border-[var(--stroke-default)] bg-[var(--bg-surface)]">
      <div className="container-page py-16 lg:py-20">
        {/* 上区：品牌 + 3 组链接 */}
        <div className="grid grid-cols-1 gap-10 sm:grid-cols-2 lg:grid-cols-4 lg:gap-12">
          <div>
            <div className="flex items-center gap-2.5">
              <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden="true">
                <circle cx="10" cy="10" r="3" fill="var(--accent)" />
                <path
                  d="M10 1.6a8.4 8.4 0 0 1 7.3 4.2"
                  stroke="var(--accent-2)"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                />
                <path
                  d="M10 18.4A8.4 8.4 0 0 1 2.7 14.2"
                  stroke="var(--accent-2)"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                />
              </svg>
              <span className="font-[var(--font-display)] text-[18px] font-bold tracking-[-0.02em]">
                {siteMeta.name}
              </span>
            </div>
            <p className="mt-4 max-w-[24em] text-[14px] leading-[1.6] text-[var(--text-secondary)]">
              {footerContent.tagline}
            </p>
            <span className="mt-5 inline-flex items-center rounded-[var(--radius-xs)] border border-[var(--stroke-default)] px-2 py-1 font-mono text-[11px] text-[var(--text-tertiary)]">
              {siteMeta.license}
            </span>
          </div>

          {footerContent.groups.map((group) => (
            <nav key={group.title} aria-label={group.title}>
              <h2 className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
                {group.title}
              </h2>
              <ul className="mt-5 space-y-3">
                {group.links.map((link) =>
                  'href' in link && link.href ? (
                    <li key={link.label}>
                      <a
                        href={link.href}
                        target={link.external ? '_blank' : undefined}
                        rel={link.external ? 'noreferrer noopener' : undefined}
                        className="link-underline text-[14px] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                      >
                        {link.label}
                      </a>
                    </li>
                  ) : (
                    <li key={link.label}>
                      <Link
                        to={'to' in link ? link.to : '/'}
                        className="link-underline text-[14px] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                      >
                        {link.label}
                      </Link>
                    </li>
                  ),
                )}
              </ul>
            </nav>
          ))}
        </div>

        {/* 免责与合规区 —— BRIEF 第六节原文 */}
        <div className="mt-14 rounded-[var(--radius-sm)] border-l-[3px] border-[var(--warning)] bg-[var(--bg-inset)] p-5">
          <h2 className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--warning)]">
            使用须知 / Disclaimer
          </h2>
          <p className="mt-3 max-w-[68em] text-[12.5px] leading-[1.6] text-[var(--text-secondary)]">
            {footerContent.disclaimer}
          </p>
        </div>

        {/* 致谢与第三方许可 */}
        <div className="mt-8">
          <h2 className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
            致谢与第三方许可 / Acknowledgements
          </h2>
          <ul className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-3">
            {footerContent.acknowledgements.map((item) => (
              <li
                key={item.name}
                className="rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)] p-4"
              >
                <div className="flex items-baseline justify-between gap-3">
                  <span className="font-mono text-[13px] font-semibold text-[var(--text-primary)]">
                    {item.name}
                  </span>
                  <span className="shrink-0 font-mono text-[11px] text-[var(--accent)]">
                    {item.license}
                  </span>
                </div>
                <p className="mt-2 text-[13px] leading-[1.6] text-[var(--text-secondary)]">
                  {item.usage}
                </p>
              </li>
            ))}
          </ul>
        </div>

        {/* 下区 */}
        <div className="mt-12 flex flex-col gap-3 border-t border-[var(--stroke-subtle)] pt-8 sm:flex-row sm:items-center sm:justify-between">
          <p className="font-mono text-[12px] text-[var(--text-tertiary)]">
            {footerContent.copyright}
          </p>
          <p className="font-mono text-[12px] text-[var(--text-tertiary)]">
            {siteMeta.license} ·{' '}
            <a
              href={siteMeta.repo}
              target="_blank"
              rel="noreferrer noopener"
              className="link-underline text-[var(--text-secondary)]"
            >
              GitHub
            </a>
          </p>
        </div>
      </div>
    </footer>
  )
}
