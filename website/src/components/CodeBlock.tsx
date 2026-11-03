import { useCallback, useRef, useState } from 'react'

/* ============================================================
   语法高亮 —— 轻量分词高亮
   规范：DESIGN_SYSTEM.md §5.7（代码窗）
   颜色令牌见 index.css 的 --syn-*
   ============================================================ */

const KEYWORDS = new Set([
  'func',
  'let',
  'var',
  'if',
  'else',
  'for',
  'while',
  'return',
  'import',
  'class',
  'struct',
  'enum',
  'protocol',
  'extension',
  'guard',
  'switch',
  'case',
  'default',
  'break',
  'continue',
  'nil',
  'true',
  'false',
  'self',
  'super',
  'init',
  'deinit',
  'static',
  'public',
  'private',
  'internal',
  'open',
  'override',
  'final',
  'lazy',
  'weak',
  'unowned',
  'async',
  'await',
  'throws',
  'try',
  'catch',
  'in',
  'where',
  'as',
  'is',
  'some',
  'any',
])

const TYPES = new Set([
  'Int',
  'Double',
  'Float',
  'String',
  'Bool',
  'CGFloat',
  'Void',
  'Any',
  'Data',
  'Date',
  'URL',
  'Array',
  'Dictionary',
  'Set',
  'Optional',
])

type TokenKind =
  | 'comment'
  | 'string'
  | 'keyword'
  | 'type'
  | 'number'
  | 'function'
  | 'punct'
  | 'path'
  | 'plain'

const KIND_CLASS: Record<TokenKind, string> = {
  comment: 'text-[var(--syn-comment)]',
  string: 'text-[var(--syn-string)]',
  keyword: 'text-[var(--syn-keyword)]',
  type: 'text-[var(--syn-type)]',
  number: 'text-[var(--syn-number)]',
  function: 'text-[var(--syn-function)]',
  punct: 'text-[var(--syn-punct)]',
  path: 'text-[var(--syn-path)]',
  plain: 'text-[var(--text-primary)]',
}

/** 把一行代码切成带类型的 token */
function tokenize(line: string): { text: string; kind: TokenKind }[] {
  const tokens: { text: string; kind: TokenKind }[] = []
  let i = 0
  const push = (text: string, kind: TokenKind) => {
    if (text) tokens.push({ text, kind })
  }

  while (i < line.length) {
    const ch = line[i]

    // 注释
    if (ch === '/' && line[i + 1] === '/') {
      push(line.slice(i), 'comment')
      break
    }

    // 字符串
    if (ch === '"' || ch === "'") {
      let j = i + 1
      while (j < line.length && line[j] !== ch) {
        if (line[j] === '\\') j++
        j++
      }
      push(line.slice(i, Math.min(j + 1, line.length)), 'string')
      i = j + 1
      continue
    }

    // 标识符 / 关键字 / 类型
    if (/[A-Za-z_]/.test(ch)) {
      let j = i
      while (j < line.length && /[A-Za-z0-9_]/.test(line[j])) j++
      const word = line.slice(i, j)
      const nextChar = line[j]
      if (KEYWORDS.has(word)) push(word, 'keyword')
      else if (TYPES.has(word)) push(word, 'type')
      else if (nextChar === '(') push(word, 'function')
      else if (/^[A-Z]/.test(word)) push(word, 'type')
      else push(word, 'plain')
      i = j
      continue
    }

    // 数字
    if (/[0-9]/.test(ch)) {
      let j = i
      while (j < line.length && /[0-9._xXa-fA-F]/.test(line[j])) j++
      push(line.slice(i, j), 'number')
      i = j
      continue
    }

    // 路径 / 标点
    if (/[.\/#]/.test(ch)) {
      let j = i
      while (j < line.length && /[A-Za-z0-9._\-/#]/.test(line[j])) j++
      push(line.slice(i, j), 'path')
      i = j
      continue
    }

    push(ch, 'punct')
    i++
  }

  return tokens
}

function HighlightedLine({ line }: { line: string }) {
  const tokens = tokenize(line)
  return (
    <>
      {tokens.map((t, idx) => (
        <span key={idx} className={KIND_CLASS[t.kind]}>
          {t.text}
        </span>
      ))}
      {tokens.length === 0 ? ' ' : null}
    </>
  )
}

/* ============================================================
   代码窗
   ============================================================ */

export function CodeBlock({
  code,
  filename,
  language = 'swift',
  showLineNumbers = true,
  copyable = true,
  maxHeight,
}: {
  code: string
  filename?: string
  language?: 'swift' | 'bash' | 'json'
  showLineNumbers?: boolean
  copyable?: boolean
  maxHeight?: number
}) {
  const [copied, setCopied] = useState(false)
  const timer = useRef<number | undefined>(undefined)

  const handleCopy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(code)
      setCopied(true)
      window.clearTimeout(timer.current)
      // 保持 1600ms 再淡回（DESIGN_SYSTEM §6.5）
      timer.current = window.setTimeout(() => setCopied(false), 1600)
    } catch {
      // 剪贴板不可用（如非安全上下文）——降级为选中文本提示
      setCopied(false)
    }
  }, [code])

  const lines = code.replace(/\n$/, '').split('\n')

  return (
    <div className="code-window">
      {/* 标题栏 */}
      <div className="flex items-center justify-between gap-3 border-b border-[var(--stroke-default)] bg-[var(--bg-card)] px-4 py-2.5">
        <div className="flex min-w-0 items-center gap-3">
          <div className="flex shrink-0 gap-1.5" aria-hidden="true">
            <span className="size-2 rounded-full bg-[var(--stroke-strong)]" />
            <span className="size-2 rounded-full bg-[var(--stroke-strong)]" />
            <span className="size-2 rounded-full bg-[var(--stroke-strong)]" />
          </div>
          {filename && (
            <span className="truncate font-mono text-[12px] text-[var(--text-tertiary)]">
              {filename}
            </span>
          )}
          <span className="hidden shrink-0 font-mono text-[11px] uppercase tracking-[0.08em] text-[var(--text-disabled)] sm:inline">
            {language}
          </span>
        </div>

        {copyable && (
          <button
            type="button"
            onClick={handleCopy}
            aria-label={copied ? '已复制到剪贴板' : '复制代码到剪贴板'}
            className="shrink-0 rounded-[var(--radius-sm)] border border-transparent px-2 py-1 font-mono text-[11px] text-[var(--text-tertiary)] transition-colors duration-120 hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)]"
          >
            {copied ? (
              <span className="text-[var(--accent)]">✓ 已复制</span>
            ) : (
              '复制'
            )}
          </button>
        )}
      </div>

      {/* 代码体 */}
      <div
        className="overflow-auto"
        style={maxHeight ? { maxHeight } : undefined}
      >
        <pre className="min-w-full p-4 font-mono text-[length:var(--text-mono)] leading-[1.6]">
          <code>
            {lines.map((line, idx) => (
              <div key={idx} className="flex">
                {showLineNumbers && (
                  <span
                    aria-hidden="true"
                    className="mr-4 shrink-0 select-none text-right text-[var(--text-disabled)] tabular-nums"
                    style={{ minWidth: '1.75em' }}
                  >
                    {idx + 1}
                  </span>
                )}
                <span className="whitespace-pre">
                  <HighlightedLine line={line} />
                </span>
              </div>
            ))}
          </code>
        </pre>
      </div>

      {/* 复制反馈 —— aria-live 让屏幕阅读器也能感知 */}
      <span className="sr-only" role="status" aria-live="polite">
        {copied ? '代码已复制到剪贴板' : ''}
      </span>
    </div>
  )
}

/* ============================================================
   命令行块 —— 比代码窗更简的形态，用于 install / run 命令
   ============================================================ */

export function CommandBlock({
  command,
  prompt = '$',
}: {
  command: string
  prompt?: string
}) {
  const [copied, setCopied] = useState(false)
  const timer = useRef<number | undefined>(undefined)

  const handleCopy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(command)
      setCopied(true)
      window.clearTimeout(timer.current)
      timer.current = window.setTimeout(() => setCopied(false), 1600)
    } catch {
      setCopied(false)
    }
  }, [command])

  return (
    <div className="flex items-center gap-3 rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-inset)] px-4 py-3">
      <span
        aria-hidden="true"
        className="shrink-0 font-mono text-[var(--accent)] select-none"
      >
        {prompt}
      </span>
      <code className="min-w-0 flex-1 overflow-x-auto whitespace-nowrap font-mono text-[length:var(--text-mono)] text-[var(--text-primary)]">
        {command}
      </code>
      <button
        type="button"
        onClick={handleCopy}
        aria-label={copied ? '已复制命令' : '复制命令'}
        className="shrink-0 rounded-[var(--radius-sm)] px-2 py-1 font-mono text-[11px] text-[var(--text-tertiary)] transition-colors duration-120 hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)]"
      >
        {copied ? (
          <span className="text-[var(--accent)]">✓</span>
        ) : (
          '复制'
        )}
      </button>
      <span className="sr-only" role="status" aria-live="polite">
        {copied ? '命令已复制到剪贴板' : ''}
      </span>
    </div>
  )
}
