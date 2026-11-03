import type { FeatureIcon } from '../content/site'

/**
 * 线性图标集
 *
 * 规范：DESIGN_SYSTEM.md §5.3
 *   24×24，1.5px 线性 SVG，stroke 用 currentColor
 *   仅在图标承载独立含义时使用，不做装饰
 */
const PATHS: Record<FeatureIcon, React.ReactNode> = {
  capture: (
    <>
      <rect x="3" y="5" width="18" height="14" rx="1.5" />
      <path d="M8 5V3.5h8V5" />
      <path d="M3 10.5h18" />
    </>
  ),
  inference: (
    <>
      <rect x="7" y="7" width="10" height="10" rx="1.5" />
      <path d="M10 10.5h4M10 13.5h4" />
      <path d="M10 7V4.5M14 7V4.5M10 19.5V17M14 19.5V17" />
      <path d="M7 10H4.5M7 14H4.5M19.5 10H17M19.5 14H17" />
    </>
  ),
  inject: (
    <>
      <rect x="2.5" y="6" width="19" height="12" rx="1.5" />
      <path d="M6 10h.01M9.5 10h.01M13 10h.01M16.5 10h.01M6 14h12" />
    </>
  ),
  network: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 3.5v17M3.5 12h17" />
      <circle cx="12" cy="12" r="2.5" />
    </>
  ),
  ocr: (
    <>
      <rect x="3" y="4.5" width="18" height="15" rx="1.5" />
      <path d="M7 9h10M7 12.5h6M7 16h8" />
    </>
  ),
  agent: (
    <>
      <rect x="4" y="7" width="16" height="12" rx="1.5" />
      <path d="M12 7V3.5" />
      <circle cx="12" cy="3" r="1" />
      <path d="M8.5 11v1.5M15.5 11v1.5" />
      <path d="M9.5 16h5" />
    </>
  ),
  map: (
    <>
      <path d="M9 4.5 3.5 7v12.5L9 17l6 2.5 5.5-2.5V4.5L15 7 9 4.5Z" />
      <path d="M9 4.5V17M15 7v12.5" />
    </>
  ),
  shield: (
    <>
      <path d="M12 3.5 5 6.2v5.1c0 4.2 2.8 7.7 7 9.2 4.2-1.5 7-5 7-9.2V6.2L12 3.5Z" />
      <path d="M9 12.2l2.2 2.2 4-4.2" />
    </>
  ),
  display: (
    <>
      <rect x="2.5" y="4.5" width="19" height="12.5" rx="1.5" />
      <path d="M8.5 20.5h7M12 17v3.5" />
    </>
  ),
  docs: (
    <>
      <path d="M6 3.5h7.5L19 9v11.5H6V3.5Z" />
      <path d="M13.5 3.5V9H19" />
      <path d="M9 13h7M9 16.5h5" />
    </>
  ),
  license: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M14.8 9.2a3.6 3.6 0 1 0 0 5.6" />
      <path d="M14.8 9.2V6.5M14.8 17.5v-2.7" />
    </>
  ),
  process: (
    <>
      <rect x="2.5" y="4" width="8" height="7" rx="1" />
      <rect x="13.5" y="13" width="8" height="7" rx="1" />
      <path d="M10.5 7.5h3a2 2 0 0 1 2 2V13" />
      <path d="M13.5 15.5h-3a2 2 0 0 1-2-2V13" />
    </>
  ),
}

export function Icon({
  name,
  className = '',
}: {
  name: FeatureIcon
  className?: string
}) {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={className}
    >
      {PATHS[name]}
    </svg>
  )
}
