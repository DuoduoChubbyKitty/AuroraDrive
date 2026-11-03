import { quickStart } from '../content/site'
import { CommandBlock } from './CodeBlock'
import { Reveal } from './Reveal'

/**
 * 快速开始区块
 *
 * 规范：DESIGN_SYSTEM.md §5.5
 *   - 代码窗 + 命令行块组合
 *   - 命令以 $ 提示符开头，注释行用 --syn-comment
 *   - 代码块下方用 --text-xs --text-tertiary 列出环境要求
 *
 * 内容为 BRIEF 第七节原文，逐字照抄。
 */
export function QuickStart() {
  const [clone, cd, run, status] = quickStart.code.split('\n')

  return (
    <div className="grid grid-cols-1 gap-8 lg:grid-cols-12">
      <Reveal className="lg:col-span-7">
        <div className="space-y-3">
          <CommandBlock command={clone.replace(/^git clone /, 'git clone ')} />
          <CommandBlock command={cd} />
          <CommandBlock command={run.trim()} />
        </div>
        <p className="mt-5 font-mono text-[12px] leading-[1.6] text-[var(--text-tertiary)]">
          {quickStart.env}
        </p>
        <p className="mt-2 font-mono text-[12px] leading-[1.6] text-[var(--text-tertiary)]">
          {quickStart.permissions}
        </p>
      </Reveal>

      <Reveal className="lg:col-span-5" delay={0.08}>
        <div className="code-window">
          <div className="flex items-center justify-between gap-3 border-b border-[var(--stroke-default)] bg-[var(--bg-card)] px-4 py-2.5">
            <div className="flex items-center gap-3">
              <span aria-hidden="true" className="flex shrink-0 gap-1.5">
                <span className="size-2 rounded-full bg-[var(--stroke-strong)]" />
                <span className="size-2 rounded-full bg-[var(--stroke-strong)]" />
                <span className="size-2 rounded-full bg-[var(--stroke-strong)]" />
              </span>
              <span className="font-mono text-[12px] text-[var(--text-tertiary)]">
                run.sh
              </span>
            </div>
          </div>
          <div className="px-4 py-3">
            <p className="font-mono text-[13px] leading-[1.7] text-[var(--syn-comment)]">
              <span className="text-[var(--accent)]">$</span>{' '}
              <span className="text-[var(--text-primary)]">{status.trim()}</span>
            </p>
          </div>
          <div className="border-t border-[var(--stroke-default)] bg-[var(--bg-card)] px-4 py-2">
            <p className="font-mono text-[12px] text-[var(--text-tertiary)]">
              {quickStart.statusLine}
            </p>
          </div>
        </div>
      </Reveal>
    </div>
  )
}
