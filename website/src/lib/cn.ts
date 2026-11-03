/**
 * 合并 className —— 极简实现，避免引入 clsx 依赖
 */
export function cn(
  ...parts: Array<string | false | null | undefined>
): string {
  return parts.filter(Boolean).join(' ')
}
