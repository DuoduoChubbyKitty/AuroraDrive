import { architectureContent as C } from '../content/site'
import { PageHero } from '../components/PageHero'
import { Figure } from '../components/Figure'
import { Reveal, RevealGroup, RevealItem } from '../components/Reveal'
import { Section, SectionHeading, Badge, StatusDot } from '../components/ui'
import { FreshnessIndicator, TierMeter } from '../components/Tier'
import { cn } from '../lib/cn'

/**
 * 架构与实现页
 *
 * 面向：端到端自动驾驶研究者 / macOS 视觉工程开发者
 * 所有结论都对应 BRIEF 中的真实实现。
 */
export function Architecture() {
  return (
    <>
      <PageHero
        eyebrow={C.hero.eyebrow}
        title={C.hero.title}
        lead={C.hero.lead}
        aside={
          <div className="surface-card p-6 sm:p-7">
            <div className="flex items-center justify-between gap-3">
              <span className="font-mono text-[11px] uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
                实时管线 / runtime
              </span>
              <span className="inline-flex items-center gap-2 font-mono text-[11px] text-[var(--accent)]">
                <StatusDot />
                running
              </span>
            </div>
            <dl className="mt-6 grid grid-cols-2 gap-px overflow-hidden rounded-[var(--radius-sm)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)]">
              {[
                { k: '推理 tick', v: '15Hz' },
                { k: '抓屏帧率', v: '15fps' },
                { k: '光流 p95', v: '1.91ms' },
                { k: '共享内存', v: 'v3' },
              ].map((row) => (
                <div key={row.k} className="bg-[var(--bg-inset)] px-4 py-3">
                  <dt className="font-mono text-[10.5px] uppercase tracking-[0.08em] text-[var(--text-tertiary)]">
                    {row.k}
                  </dt>
                  <dd className="num mt-1 text-[15px] text-[var(--text-primary)]">{row.v}</dd>
                </div>
              ))}
            </dl>
            <p className="mt-5 font-mono text-[12px] leading-[1.6] text-[var(--text-tertiary)]">
              端到端 M9 单目模型 · YOLOPX 三合一 · PP-OCRv6 int8
            </p>
          </div>
        }
      />

      {/* ── 实时管线 ────────────────────────────────────────────── */}
      <Section id="pipeline" aria-labelledby="pipeline-title">
        <SectionHeading
          id="pipeline-title"
          eyebrow={C.pipeline.eyebrow}
          title={C.pipeline.title}
          lead={C.pipeline.lead}
        />
        <RevealGroup className="mt-12 grid grid-cols-1 gap-6 md:grid-cols-3">
          {C.pipeline.stages.map((stage) => (
            <RevealItem key={stage.index} className="h-full">
              <article className="surface-card flex h-full flex-col p-6">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="font-mono text-[11px] text-[var(--text-tertiary)]">
                    {stage.index}
                  </span>
                  <span className="num text-[13px] text-[var(--accent)]">
                    {stage.metric}
                  </span>
                </div>
                <h3 className="mt-4 text-[length:var(--text-h3)] tracking-[-0.015em]">
                  {stage.title}
                </h3>
                <p className="mt-2 font-mono text-[12px] text-[var(--text-tertiary)]">
                  {stage.source}
                </p>
                <p className="mt-4 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                  {stage.body}
                </p>
              </article>
            </RevealItem>
          ))}
        </RevealGroup>
      </Section>

      {/* ── 三档降级 ────────────────────────────────────────────── */}
      <Section id="degrade" alt aria-labelledby="degrade-title">
        <SectionHeading
          id="degrade-title"
          eyebrow={C.degrade.eyebrow}
          title={C.degrade.title}
          lead={C.degrade.lead}
        />

        <div className="mt-12 grid grid-cols-1 gap-10 lg:grid-cols-12 lg:gap-12">
          <Reveal className="lg:col-span-7">
            <ol className="space-y-4">
              {C.degrade.tiers.map((tier, index) => (
                <li
                  key={tier.name}
                  className="rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)] p-6"
                  style={{ borderLeftWidth: 3, borderLeftColor: `var(--${tier.tier})` }}
                >
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div className="flex items-center gap-3">
                      <span className="font-mono text-[11px] text-[var(--text-tertiary)]">
                        档位 {index + 1}
                      </span>
                      <h3 className="text-[length:var(--text-h3)] tracking-[-0.015em]">
                        {tier.name}
                      </h3>
                    </div>
                    <TierMeter tier={tier.tier} />
                  </div>
                  <p className="mt-3 font-mono text-[12px] text-[var(--text-tertiary)]">
                    {tier.model}
                  </p>
                  <p className="mt-3 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                    {tier.body}
                  </p>
                  <p className="mt-4 font-mono text-[12px] text-[var(--text-tertiary)]">
                    {tier.source}
                  </p>
                </li>
              ))}
            </ol>
          </Reveal>

          <div className="lg:col-span-5">
            <Reveal delay={0.08}>
              <Figure
                src="/images/degrade-cascade.jpg"
                alt="抽象技术插画：三条由亮至暗的平行能量层带，象征三档降级阶梯"
                ratio="16 / 9"
              />
            </Reveal>
            <Reveal delay={0.12}>
              <dl className="mt-8 space-y-5">
                {C.degrade.principles.map((p) => (
                  <div key={p.label}>
                    <dt className="font-mono text-[12px] font-semibold uppercase tracking-[0.06em] text-[var(--accent)]">
                      {p.label}
                    </dt>
                    <dd className="mt-2 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                      {p.body}
                    </dd>
                  </div>
                ))}
              </dl>
              <p className="mt-6 rounded-[var(--radius-sm)] border-l-[3px] border-[var(--warning)] bg-[var(--bg-inset)] p-4 text-[length:var(--text-xs)] leading-[1.6] text-[var(--text-secondary)]">
                {C.degrade.caution}
              </p>
            </Reveal>
          </div>
        </div>
      </Section>

      {/* ── 光流实测 ────────────────────────────────────────────── */}
      <Section id="flow" aria-labelledby="flow-title">
        <SectionHeading
          id="flow-title"
          eyebrow={C.flow.eyebrow}
          title={C.flow.title}
          lead={C.flow.lead}
        />
        <div className="mt-12 grid grid-cols-1 gap-10 lg:grid-cols-12 lg:gap-12">
          <Reveal className="lg:col-span-7">
            <div className="overflow-x-auto rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)]">
              <table className="data-table min-w-[520px]">
                <caption className="sr-only">光流方案本机实测耗时对比</caption>
                <thead>
                  <tr>
                    <th scope="col">实现</th>
                    <th scope="col" className="text-right">
                      耗时
                    </th>
                    <th scope="col" className="text-center">
                      结论
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {C.flow.rows.map((row) => (
                    <tr key={row.name}>
                      <th
                        scope="row"
                        className="text-left font-normal text-[length:var(--text-sm)] text-[var(--text-primary)]"
                      >
                        {row.name}
                      </th>
                      <td className="num text-right">
                        <span
                          className="text-[15px]"
                          style={{
                            color:
                              row.verdict === 'adopt'
                                ? 'var(--success)'
                                : 'var(--text-tertiary)',
                          }}
                        >
                          {row.value}
                        </span>
                        <span className="ml-1 text-[12px] text-[var(--text-tertiary)]">
                          {row.unit}
                        </span>
                      </td>
                      <td className="text-center">
                        <Badge tone={row.verdict === 'adopt' ? 'success' : 'neutral'}>
                          {row.verdict === 'adopt' ? '采用' : '不采用'}
                        </Badge>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-6 max-w-[68em] rounded-[var(--radius-sm)] border-l-[3px] border-[var(--accent)] bg-[var(--bg-inset)] p-4 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
              {C.flow.redline}
            </p>
          </Reveal>
          <div className="lg:col-span-5">
            <Reveal delay={0.08}>
              <Figure
                src="/images/optical-flow.jpg"
                alt="抽象技术插画：密集矢量流线场中有一段明显稀疏，象征光流方案实测对比"
                ratio="16 / 9"
              />
            </Reveal>
          </div>
        </div>
      </Section>

      {/* ── 进程与共享内存 ──────────────────────────────────────── */}
      <Section id="memory" alt aria-labelledby="memory-title">
        <SectionHeading
          id="memory-title"
          eyebrow={C.memory.eyebrow}
          title={C.memory.title}
          lead={C.memory.lead}
        />
        <div className="mt-12 grid grid-cols-1 gap-10 lg:grid-cols-12 lg:gap-12">
          <Reveal className="lg:col-span-6">
            <Figure
              src="/images/pipeline-shm.jpg"
              alt="抽象技术插画：两个并列的处理模块由一条横向数据总线连接，象征双进程共享内存"
              ratio="16 / 9"
            />
          </Reveal>
          <div className="lg:col-span-6">
            <Reveal delay={0.08}>
              <dl className="grid grid-cols-1 gap-px overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)] sm:grid-cols-2">
                {C.memory.facts.map((fact) => (
                  <div key={fact.label} className="bg-[var(--bg-card)] p-5">
                    <dt className="font-mono text-[11px] uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
                      {fact.label}
                    </dt>
                    <dd className="num mt-2 text-[16px] text-[var(--text-primary)]">
                      {fact.value}
                    </dd>
                    <p className="mt-1.5 font-mono text-[11.5px] text-[var(--text-tertiary)]">
                      {fact.note}
                    </p>
                  </div>
                ))}
              </dl>
              <p className="mt-6 max-w-[42em] text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
                {C.memory.body}
              </p>
            </Reveal>
          </div>
        </div>
      </Section>

      {/* ── 定位与路网先验 ──────────────────────────────────────── */}
      <Section id="location" aria-labelledby="location-title">
        <SectionHeading
          id="location-title"
          eyebrow={C.location.eyebrow}
          title={C.location.title}
          lead={C.location.lead}
        />

        <Reveal className="mt-12">
          <FreshnessIndicator items={C.location.freshness} />
        </Reveal>

        <div className="mt-10 grid grid-cols-1 gap-10 lg:grid-cols-12 lg:gap-12">
          <Reveal className="lg:col-span-6">
            <Figure
              src="/images/world-map.jpg"
              alt="抽象技术插画：俯视的矩形像素网格平面被十字准星锁定一点，象征大地图像素空间定位"
              ratio="16 / 9"
            />
          </Reveal>
          <div className="lg:col-span-6">
            <Reveal delay={0.08}>
              <h3 className="text-[length:var(--text-h3)] tracking-[-0.015em]">
                路网先验的实测收益
              </h3>
              <dl className="mt-6 space-y-4">
                {C.location.graph.map((row) => (
                  <div
                    key={row.label}
                    className="flex items-baseline justify-between gap-4 border-b border-[var(--stroke-subtle)] pb-4 last:border-b-0 last:pb-0"
                  >
                    <dt className="text-[length:var(--text-sm)] text-[var(--text-secondary)]">
                      {row.label}
                    </dt>
                    <dd className="num text-[18px]">
                      <span className="text-[var(--text-tertiary)]">{row.before}</span>
                      <span className="mx-2 text-[var(--text-disabled)]" aria-hidden="true">
                        →
                      </span>
                      <span className="text-[var(--text-primary)]">{row.after}</span>
                    </dd>
                  </div>
                ))}
              </dl>

              <h3 className="mt-10 text-[length:var(--text-h3)] tracking-[-0.015em]">
                地图多图层开关
              </h3>
              <ul className="mt-4 flex flex-wrap gap-2">
                {C.location.layers.map((layer) => (
                  <li key={layer}>
                    <Badge tone="neutral">{layer}</Badge>
                  </li>
                ))}
              </ul>

              <p className="mt-8 rounded-[var(--radius-sm)] border-l-[3px] border-[var(--warning)] bg-[var(--bg-inset)] p-4 text-[length:var(--text-xs)] leading-[1.6] text-[var(--text-secondary)]">
                {C.location.caution}
              </p>
            </Reveal>
          </div>
        </div>
      </Section>

      {/* ── AI 助手 ─────────────────────────────────────────────── */}
      <Section id="agent" alt aria-labelledby="agent-title">
        <SectionHeading
          id="agent-title"
          eyebrow={C.agent.eyebrow}
          title={C.agent.title}
          lead={C.agent.lead}
        />

        <div className="mt-12 grid grid-cols-1 gap-10 lg:grid-cols-12 lg:gap-12">
          <Reveal className="lg:col-span-6">
            <Figure
              src="/images/agent-tools.jpg"
              alt="抽象技术插画：中心节点向外辐射细光线，部分光线末端黯淡，象征工具注册表与未实装技能"
              ratio="16 / 9"
            />
          </Reveal>
          <div className="lg:col-span-6">
            <Reveal delay={0.08}>
              <h3 className="text-[length:var(--text-h3)] tracking-[-0.015em]">
                30 个工具的构成
              </h3>
              <ul className="mt-5 grid grid-cols-2 gap-px overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--stroke-subtle)] sm:grid-cols-3">
                {C.agent.breakdown.map((item) => (
                  <li key={item.label} className="bg-[var(--bg-card)] p-4">
                    <span className="num block text-[22px] font-semibold leading-none text-[var(--text-primary)]">
                      {item.count}
                    </span>
                    <span className="mt-2 block font-mono text-[11px] uppercase tracking-[0.08em] text-[var(--text-tertiary)]">
                      {item.label}
                    </span>
                    <span className="mt-1 block text-[12px] text-[var(--text-tertiary)]">
                      {item.note}
                    </span>
                  </li>
                ))}
              </ul>

              <dl className="mt-8 space-y-5">
                {C.agent.boundaries.map((b) => (
                  <div key={b.label}>
                    <dt className="font-mono text-[12px] font-semibold uppercase tracking-[0.06em] text-[var(--accent)]">
                      {b.label}
                    </dt>
                    <dd className="mt-2 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                      {b.body}
                    </dd>
                  </div>
                ))}
              </dl>

              <p className="mt-6 rounded-[var(--radius-sm)] border-l-[3px] border-[var(--warning)] bg-[var(--bg-inset)] p-4 text-[length:var(--text-xs)] leading-[1.6] text-[var(--text-secondary)]">
                {C.agent.caution}
              </p>
            </Reveal>
          </div>
        </div>
      </Section>

      {/* ── 显示增强边界 ────────────────────────────────────────── */}
      <Section id="display" aria-labelledby="display-title">
        <SectionHeading
          id="display-title"
          eyebrow={C.display.eyebrow}
          title={C.display.title}
          lead={C.display.lead}
        />
        <div className="mt-12 grid grid-cols-1 gap-10 lg:grid-cols-12 lg:gap-12">
          <Reveal className="lg:col-span-6">
            <ul className="space-y-4">
              {C.display.contrast.map((item) => (
                <li
                  key={item.side}
                  className={cn(
                    'rounded-[var(--radius-md)] border bg-[var(--bg-card)] p-6',
                    item.tone === 'ok'
                      ? 'border-[var(--success)]'
                      : 'border-[var(--danger)]',
                  )}
                  style={{ borderLeftWidth: 3 }}
                >
                  <span
                    className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em]"
                    style={{
                      color:
                        item.tone === 'ok'
                          ? 'var(--success)'
                          : 'var(--danger)',
                    }}
                  >
                    {item.side}
                  </span>
                  <p className="mt-3 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                    {item.body}
                  </p>
                </li>
              ))}
            </ul>
            <p className="mt-6 max-w-[42em] rounded-[var(--radius-sm)] border-l-[3px] border-[var(--accent)] bg-[var(--bg-inset)] p-4 text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
              {C.display.reason}
            </p>
          </Reveal>
          <div className="lg:col-span-6">
            <Reveal delay={0.08}>
              <Figure
                src="/images/display-boundary.jpg"
                alt="抽象技术插画：一条清晰的边界分隔两侧区域，象征显示层与决策链路的隔离"
                ratio="16 / 9"
              />
            </Reveal>
          </div>
        </div>
      </Section>

      {/* ── 技术栈 ──────────────────────────────────────────────── */}
      <Section id="stack" alt aria-labelledby="stack-title">
        <SectionHeading
          id="stack-title"
          eyebrow={C.stack.eyebrow}
          title={C.stack.title}
          lead={C.stack.lead}
        />
        <Reveal className="mt-12">
          <dl className="overflow-hidden rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-card)]">
            {C.stack.items.map((item) => (
              <div
                key={item.group}
                className="grid grid-cols-1 gap-2 border-b border-[var(--stroke-subtle)] px-6 py-5 last:border-b-0 sm:grid-cols-12 sm:gap-6"
              >
                <dt className="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--text-tertiary)] sm:col-span-3">
                  {item.group}
                </dt>
                <dd className="font-mono text-[13px] leading-[1.6] text-[var(--text-primary)] sm:col-span-9">
                  {item.value}
                </dd>
              </div>
            ))}
          </dl>
        </Reveal>
      </Section>
    </>
  )
}
