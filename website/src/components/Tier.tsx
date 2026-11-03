import { cn } from '../lib/cn'
import type { FreshnessKey, TierKey } from '../content/site'

/**
 * 降级档位指示条
 *
 * 规范：DESIGN_SYSTEM.md §2.5
 *   档位 1 E2E 端到端主驾  #35E0A1（青绿）—— 最强能力 → 满格进度条
 *   档位 2 YOLO 接管     #7C8CF8（靛紫）—— 能力下降 → 2/3 格
 *   档位 3 纯规则兜底    #8A97A8（钢灰）—— 最保守 → 视觉上「退后」
 *
 * 关键：规则档不是红色 —— 它是系统正常工作，不是故障。
 * 红/橙只保留给真正的异常（协议版本不匹配、权限缺失、网络定位 lost）。
 */
/** 档位进度格数 */
const TIER_LEVEL: Record<TierKey, number> = {
  'tier-e2e': 3,
  'tier-yolo': 2,
  'tier-rule': 1,
}

export function TierBadge({
  tier,
  name,
  active = false,
  className,
}: {
  tier: TierKey
  name: string
  active?: boolean
  className?: string
}) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-[var(--radius-xs)] border px-2 py-0.5 font-mono text-[11px] font-medium tracking-[0.06em]',
        active
          ? 'border-current'
          : 'border-[var(--stroke-default)] text-[var(--text-tertiary)]',
        className,
      )}
      style={
        active
          ? { color: `var(--${tier})`, backgroundColor: `var(--${tier}-bg)` }
          : undefined
      }
    >
      {active && (
        <span
          aria-hidden="true"
          className="pulse-dot inline-block size-1.5 rounded-full"
          style={{ backgroundColor: `var(--${tier})` }}
        />
      )}
      {name}
    </span>
  )
}

/**
 * 档位进度条 —— 三格，亮格数表示能力等级
 */
export function TierMeter({
  tier,
  className,
}: {
  tier: TierKey
  className?: string
}) {
  const level = TIER_LEVEL[tier]
  return (
    <div className={cn('flex items-center gap-1', className)} aria-hidden="true">
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="h-1.5 w-8 rounded-[1px] transition-colors duration-[320ms]"
          style={{
            backgroundColor:
              i < level ? `var(--${tier})` : 'var(--stroke-subtle)',
          }}
        />
      ))}
    </div>
  )
}

/**
 * 网络新鲜度指示器
 *
 * 规范：DESIGN_SYSTEM.md §2.5
 *   四档独立于降级三档：绿→蓝→橙→红，表达时间衰减而非能力等级。
 *   两套状态色不得混用。
 */
export function FreshnessIndicator({
  items,
  className,
}: {
  items: Array<{ key: FreshnessKey; name: string; range: string; body: string }>
  className?: string
}) {
  return (
    <ul className={cn('grid grid-cols-1 gap-px overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)] sm:grid-cols-2 lg:grid-cols-4', className)}>
      {items.map((item) => (
        <li key={item.key} className="bg-[var(--bg-card)] p-5">
          <div className="flex items-center gap-2">
            <span
              aria-hidden="true"
              className="inline-block size-2 rounded-full"
              style={{ backgroundColor: `var(--${item.key})` }}
            />
            <span className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-primary)]">
              {item.name}
            </span>
            <span className="num ml-auto text-[12px] text-[var(--text-tertiary)]">
              {item.range}
            </span>
          </div>
          <p className="mt-3 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
            {item.body}
          </p>
        </li>
      ))}
    </ul>
  )
}
