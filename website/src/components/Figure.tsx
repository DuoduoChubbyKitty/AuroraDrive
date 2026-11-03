import { cn } from '../lib/cn'

/**
 * AI 配图容器
 *
 * 规范：DESIGN_SYSTEM.md §5.12
 *   1. AI 图不做背景填充 + 压文字 —— 图与文字是兄弟容器
 *   2. 每张图放在独立容器帧内：1px --stroke-default 描边 + --radius-md + --bg-inset 底
 *   6. 统一裁切比例
 *   7. loading="lazy" + decoding="async" + 明确 width/height 防 CLS
 *   8. 每张图必须有 alt
 *
 * @param ratio  CSS aspect-ratio（如 '16 / 9'）
 * @param eager  首屏图用 true（Hero / 第一屏）
 */
export function Figure({
  src,
  alt,
  ratio = '16 / 9',
  eager = false,
  caption,
  className,
  imgClassName,
}: {
  src: string
  alt: string
  ratio?: string
  eager?: boolean
  caption?: string
  className?: string
  imgClassName?: string
}) {
  return (
    <figure
      className={cn(
        'overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-inset)]',
        className,
      )}
    >
      <div className="relative w-full" style={{ aspectRatio: ratio }}>
        <img
          src={src}
          alt={alt}
          width={1600}
          height={1116}
          loading={eager ? 'eager' : 'lazy'}
          decoding="async"
          fetchPriority={eager ? 'high' : 'auto'}
          className={cn('absolute inset-0 size-full object-cover', imgClassName)}
        />
      </div>
      {caption && (
        <figcaption className="border-t border-[var(--stroke-subtle)] px-4 py-2.5 font-mono text-[12px] text-[var(--text-tertiary)]">
          {caption}
        </figcaption>
      )}
    </figure>
  )
}
