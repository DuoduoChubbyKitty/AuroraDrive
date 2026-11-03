import { Hero } from '../components/Hero'
import { FeatureGrid } from '../components/FeatureGrid'
import { Stats } from '../components/Stats'
import { QuickStart } from '../components/QuickStart'
import { Faq } from '../components/Faq'
import { PricingTable } from '../components/PricingTable'
import { TeamGrid } from '../components/TeamGrid'
import { Testimonials } from '../components/Testimonials'
import { ContactForm } from '../components/ContactForm'
import { Section, SectionHeading } from '../components/ui'
import { Reveal } from '../components/Reveal'
import { Figure } from '../components/Figure'

/**
 * 首页 —— 三类受众全覆盖
 *
 * 必含区块：导航栏、Hero、功能特性网格、数据统计区、代码/命令展示、
 *           定价方案对比、FAQ 手风琴、团队成员、用户评价、联系表单、页脚
 * （导航栏与页脚在 App 布局层，位于 PageTransition 之外）
 */
export function Home() {
  return (
    <>
      <Hero />

      <FeatureGrid />
      <Stats />

      {/* 代码 / 命令展示 */}
      <Section id="quick-start" alt aria-labelledby="quick-start-title">
        <SectionHeading
          id="quick-start-title"
          eyebrow="快速开始"
          title="十分钟跑起来"
          lead="命令与环境要求取自仓库 README 原文，逐字照抄。复制到终端即可。"
        />
        <div className="mt-12">
          <QuickStart />
        </div>
      </Section>

      {/* 插画区 —— AI 图与文字是兄弟容器，不是叠加 */}
      <Section id="loop" aria-labelledby="loop-title">
        <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-12 lg:gap-12">
          <div className="lg:col-span-6">
            <Reveal>
              <span className="eyebrow">三段式闭环</span>
              <h2
                id="loop-title"
                className="mt-6 text-[length:var(--text-h1)] leading-[1.08] tracking-[-0.025em]"
              >
                看得见 → 想得出 → 按得下
              </h2>
              <p className="mt-5 max-w-[42em] text-[length:var(--text-lead)] leading-[1.55] text-[var(--text-secondary)]">
                捕获与推理跑在引擎进程里，注入通过 CGEvent 以真实按键事件回到游戏。
                每一段都有独立的失败处理：看不见画面、拿不到焦点、权限不足，都会明确拒绝而不是静默乱按。
              </p>
              <dl className="mt-10 grid grid-cols-1 gap-6 sm:grid-cols-3">
                {[
                  { t: '看得见', d: 'ScreenCaptureKit 抓帧，15fps' },
                  { t: '想得出', d: 'CoreML 推理，15Hz tick' },
                  { t: '按得下', d: 'CGEvent 注入真实按键' },
                ].map((item) => (
                  <div key={item.t} className="border-l border-[var(--stroke-default)] pl-4">
                    <dt className="font-mono text-[13px] font-semibold text-[var(--text-primary)]">
                      {item.t}
                    </dt>
                    <dd className="mt-2 text-[length:var(--text-sm)] leading-[1.6] text-[var(--text-secondary)]">
                      {item.d}
                    </dd>
                  </div>
                ))}
              </dl>
            </Reveal>
          </div>
          <div className="lg:col-span-6">
            <Reveal delay={0.08}>
              <Figure
                src="/images/hero-banner.jpg"
                alt="抽象技术插画：极光缎带贯穿深色几何结构，象征实时数据管线"
                ratio="16 / 9"
              />
            </Reveal>
          </div>
        </div>
      </Section>

      <PricingTable />
      <Faq />
      <TeamGrid />
      <Testimonials />

      {/* ── 联系表单（后期将接入后端，当前为前端模拟提交） ───────── */}
      <ContactForm />
    </>
  )
}
