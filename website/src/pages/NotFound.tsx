import { ButtonLink } from '../components/ui'

/**
 * 404 页 —— 保持视觉语言一致（直角、描边、等宽标签）
 */
export function NotFound() {
  return (
    <section className="container-page flex min-h-[70vh] flex-col items-start justify-center py-24">
      <span className="eyebrow">HTTP 404</span>
      <h1 className="mt-6 text-[length:var(--text-h1)] leading-[1.08] tracking-[-0.025em]">
        这一页不在三段闭环里
      </h1>
      <p className="mt-5 max-w-[42em] text-[length:var(--text-lead)] leading-[1.55] text-[var(--text-secondary)]">
        你要找的地址不存在。可以从首页开始，或直接看架构与实现 —— 那里有全部可核对的细节。
      </p>
      <div className="mt-8 flex flex-col gap-3 sm:flex-row">
        <ButtonLink to="/" size="lg">
          回到首页
        </ButtonLink>
        <ButtonLink to="/architecture" size="lg" variant="secondary">
          看架构与实现
        </ButtonLink>
      </div>
    </section>
  )
}
