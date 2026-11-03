import { useId, useState } from 'react'
import { contactContent } from '../content/site'
import { cn } from '../lib/cn'
import { Reveal } from './Reveal'
import { Section } from './ui'

/**
 * 联系表单
 *
 * 规范：DESIGN_SYSTEM.md §5.10
 *   - --container-narrow (760px) 单列居中（表单是居中窄列的例外）
 *   - label：--text-label (11px mono 全大写)，必填项后加 --accent 的 "*"
 *   - input：height 48px，padding 0 16px，--radius-sm，bg --bg-inset，border --stroke-input
 *   - textarea：min-height 140px
 *   - 校验时机：失焦校验（onBlur），输入时清除错误（onChange 不重新校验）
 *   - 提交时校验全部，不通过聚焦第一个错误字段并滚动到它
 *   - 错误信息用 aria-describedby 关联，aria-invalid 标记字段
 *   - 提交按钮宽度固定
 *   - Success 态：整块表单替换为成功面板，淡入 240ms
 */
type FieldName = 'name' | 'email' | 'topic' | 'message'
type Errors = Partial<Record<FieldName, string>>

const VALIDATORS: Record<FieldName, (v: string) => string | undefined> = {
  name: (v) => (v.trim().length === 0 ? '请填写称呼' : undefined),
  email: (v) =>
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim())
      ? undefined
      : '请填写有效的邮箱地址',
  topic: (v) => (v.trim().length === 0 ? '请选择一个主题' : undefined),
  message: (v) =>
    v.trim().length < 10 ? '请至少写 10 个字，描述具体些更容易被解答' : undefined,
}

export function ContactForm() {
  const baseId = useId()
  const [values, setValues] = useState<Record<FieldName, string>>({
    name: '',
    email: '',
    topic: contactContent.form.topics[0].value,
    message: '',
  })
  const [errors, setErrors] = useState<Errors>({})
  const [status, setStatus] = useState<'idle' | 'submitting' | 'success'>('idle')

  const fieldId = (name: FieldName) => `${baseId}-${name}`
  const errorId = (name: FieldName) => `${baseId}-${name}-error`

  function handleBlur(name: FieldName) {
    const message = VALIDATORS[name](values[name])
    setErrors((prev) => {
      const next = { ...prev }
      if (message) next[name] = message
      else delete next[name]
      return next
    })
  }

  function handleChange(name: FieldName, value: string) {
    setValues((prev) => ({ ...prev, [name]: value }))
    // 输入时清除错误，不重新校验
    setErrors((prev) => {
      if (!prev[name]) return prev
      const next = { ...prev }
      delete next[name]
      return next
    })
  }

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault()

    const nextErrors: Errors = {}
    for (const name of Object.keys(VALIDATORS) as FieldName[]) {
      const message = VALIDATORS[name](values[name])
      if (message) nextErrors[name] = message
    }

    if (Object.keys(nextErrors).length > 0) {
      setErrors(nextErrors)
      const firstInvalid = (Object.keys(VALIDATORS) as FieldName[]).find(
        (name) => nextErrors[name],
      )
      if (firstInvalid) {
        const el = document.getElementById(fieldId(firstInvalid))
        el?.focus()
        el?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      }
      return
    }

    setStatus('submitting')
    // 后端尚未接入 —— 这里先演示提交态与成功态，接入真实接口时替换此段。
    await new Promise((resolve) => setTimeout(resolve, 600))
    setStatus('success')
  }

  if (status === 'success') {
    return (
      <Section id="contact-form" alt aria-labelledby="contact-form-title">
        <div className="mx-auto w-full" style={{ maxWidth: '760px' }}>
          <div
            role="status"
            className="rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)] p-8"
          >
            <div className="flex items-center gap-3">
              <span aria-hidden="true" className="text-[var(--success)]">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                  <path
                    d="M5 12.5l4.5 4.5L19 7.5"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </span>
              <h2
                id="contact-form-title"
                className="text-[length:var(--text-h3)] tracking-[-0.015em]"
              >
                信息已校验通过
              </h2>
            </div>
            <p className="mt-4 max-w-[42em] text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
              你好，{values.name.trim()}。表单后端还在接入中，这条消息目前只在前端完成校验与提交演练，
              还不会被真正发送 —— 换成一次「看起来成功」的假动作是我们不做的。
            </p>
            <p className="mt-4 max-w-[42em] text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
              请直接把内容发到
              <a
                href="https://github.com/DuoduoChubbyKitty/AuroraDrive/issues"
                target="_blank"
                rel="noreferrer noopener"
                className="link-underline mx-1 text-[var(--accent)]"
              >
                GitHub Issues
              </a>
              ，或走下面的合作洽谈渠道。
            </p>
            <button
              type="button"
              onClick={() => {
                setStatus('idle')
                setValues({ name: '', email: '', topic: contactContent.form.topics[0].value, message: '' })
              }}
              className="mt-6 inline-flex h-11 items-center rounded-[var(--radius-md)] border border-[var(--stroke-default)] px-4 text-[14px] text-[var(--text-primary)] transition-colors duration-120 hover:border-[var(--accent-line)] hover:bg-[var(--bg-elevated)]"
            >
              再写一条
            </button>
          </div>
        </div>
      </Section>
    )
  }

  return (
    <Section id="contact-form" alt aria-labelledby="contact-form-title">
      <div className="mx-auto w-full" style={{ maxWidth: '760px' }}>
        <Reveal>
          <div className="mb-10">
            <h2
              id="contact-form-title"
              className="text-[length:var(--text-h1)] leading-[1.08] tracking-[-0.025em]"
            >
              {contactContent.form.title}
            </h2>
            <p className="mt-5 max-w-[42em] text-[length:var(--text-lead)] leading-[1.55] text-[var(--text-secondary)]">
              {contactContent.form.lead}
            </p>
          </div>
        </Reveal>

        <Reveal>
          <form onSubmit={handleSubmit} noValidate className="space-y-6">
            <Field
              id={fieldId('name')}
              name="name"
              label="称呼"
              required
              error={errors.name}
              errorId={errorId('name')}
            >
              <input
                id={fieldId('name')}
                name="name"
                type="text"
                value={values.name}
                onChange={(e) => handleChange('name', e.target.value)}
                onBlur={() => handleBlur('name')}
                aria-invalid={errors.name ? true : undefined}
                aria-describedby={errors.name ? errorId('name') : undefined}
                placeholder="怎么称呼你"
                className={inputClass(errors.name)}
              />
            </Field>

            <Field
              id={fieldId('email')}
              name="email"
              label="邮箱"
              required
              error={errors.email}
              errorId={errorId('email')}
            >
              <input
                id={fieldId('email')}
                name="email"
                type="email"
                value={values.email}
                onChange={(e) => handleChange('email', e.target.value)}
                onBlur={() => handleBlur('email')}
                aria-invalid={errors.email ? true : undefined}
                aria-describedby={errors.email ? errorId('email') : undefined}
                placeholder="name@example.com"
                className={inputClass(errors.email)}
              />
            </Field>

            <Field id={fieldId('topic')} name="topic" label="主题" required>
              <select
                id={fieldId('topic')}
                name="topic"
                value={values.topic}
                onChange={(e) => handleChange('topic', e.target.value)}
                onBlur={() => handleBlur('topic')}
                className={cn(inputClass(undefined), 'appearance-none pr-10')}
              >
                {contactContent.form.topics.map((topic) => (
                  <option key={topic.value} value={topic.value}>
                    {topic.label}
                  </option>
                ))}
              </select>
            </Field>

            <Field
              id={fieldId('message')}
              name="message"
              label="留言"
              required
              error={errors.message}
              errorId={errorId('message')}
            >
              <textarea
                id={fieldId('message')}
                name="message"
                value={values.message}
                onChange={(e) => handleChange('message', e.target.value)}
                onBlur={() => handleBlur('message')}
                aria-invalid={errors.message ? true : undefined}
                aria-describedby={errors.message ? errorId('message') : undefined}
                placeholder="带上 macOS 版本、芯片型号与相关日志片段，会快很多。"
                className={cn(
                  inputClass(errors.message),
                  'min-h-[140px] w-full resize-y py-4 leading-[1.6]',
                )}
              />
            </Field>

            <div className="flex items-center gap-4 pt-2">
              <button
                type="submit"
                disabled={status === 'submitting'}
                className="inline-flex h-12 w-[180px] items-center justify-center gap-2 rounded-[var(--radius-md)] border border-transparent bg-[var(--accent)] text-[15px] font-semibold text-[var(--text-inverse)] transition-all duration-150 hover:bg-[var(--accent-hover)] hover:shadow-[var(--glow-accent)] hover:-translate-y-px disabled:cursor-not-allowed disabled:opacity-45 disabled:hover:translate-y-0 disabled:hover:shadow-none"
              >
                {status === 'submitting' && (
                  <span
                    aria-hidden="true"
                    className="inline-block size-3.5 animate-spin rounded-full border-[1.5px] border-current border-t-transparent"
                    style={{ animationDuration: '1s' }}
                  />
                )}
                {status === 'submitting' ? '发送中…' : '发送消息'}
              </button>
              <p className="text-[length:var(--text-xs)] leading-[1.5] text-[var(--text-tertiary)]">
                表单后端接入中，当前为前端模拟提交。
              </p>
            </div>
          </form>
        </Reveal>
      </div>
    </Section>
  )
}

function inputClass(error?: string) {
  return cn(
    'h-12 w-full rounded-[var(--radius-sm)] border bg-[var(--bg-inset)] px-4 text-[length:var(--text-body)] text-[var(--text-primary)] transition-[border-color,box-shadow] duration-[140ms] placeholder:text-[var(--text-tertiary)]',
    error
      ? 'border-[var(--danger)]'
      : 'border-[var(--stroke-input)] hover:border-[var(--stroke-strong)]',
    'focus:border-[var(--stroke-focus)] focus:shadow-[0_0_0_3px_var(--accent-subtle)] focus:outline-none',
  )
}

function Field({
  id,
  name,
  label,
  required,
  error,
  errorId,
  children,
}: {
  id: string
  name: string
  label: string
  required?: boolean
  error?: string
  errorId?: string
  children: React.ReactNode
}) {
  return (
    <div>
      <label
        htmlFor={id}
        className="mb-2 block font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-secondary)]"
      >
        {label}
        {required && (
          <span className="ml-1 text-[var(--accent)]" aria-hidden="true">
            *
          </span>
        )}
      </label>
      {children}
      {error && (
        <p
          id={errorId}
          role="alert"
          className="mt-2 flex items-start gap-2 text-[length:var(--text-xs)] text-[var(--danger)]"
        >
          <span aria-hidden="true" className="mt-[2px] inline-block w-0.5 self-stretch bg-[var(--danger)]" />
          {error}
        </p>
      )}
      {name === 'topic' && (
        <p className="mt-2 text-[length:var(--text-xs)] text-[var(--text-tertiary)]">
          主题只用于我们分类，不会改变处理方式。
        </p>
      )}
    </div>
  )
}
