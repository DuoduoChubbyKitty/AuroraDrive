import { pricingPageContent as P } from '../content/site'
import { PageHero } from '../components/PageHero'
import { PricingTable } from '../components/PricingTable'
import { Faq } from '../components/Faq'
import { Figure } from '../components/Figure'
import { Reveal } from '../components/Reveal'
import { Section, SectionHeading } from '../components/ui'

/**
 * 支持与定价页
 */
export function Pricing() {
  return (
    <>
      <PageHero
        eyebrow={P.hero.eyebrow}
        title={P.hero.title}
        lead={P.hero.lead}
        aside={
          <div className="surface-card p-6 sm:p-7">
            <span className="font-mono text-[11px] uppercase tracking-[0.1em] text-[var(--text-tertiary)]">
              许可状态 / license
            </span>
            <p className="num mt-4 text-[20px] font-semibold text-[var(--text-primary)]">
              GPL-3.0-or-later
            </p>
            <p className="mt-4 max-w-[42em] text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
              源码许可不随支持档位变化。任何一档都能 fork 走，改名、改协议、闭源商用 —— 只要遵守 GPL 的义务。
            </p>
            <ul className="mt-6 space-y-2">
              {[
                '社区版 · ¥0 永久免费',
                '支持者 · ¥0 永久免费',
                '企业定制 · ¥0 永久免费',
              ].map((row) => (
                <li key={row} className="flex items-center gap-3 font-mono text-[12.5px] text-[var(--text-secondary)]">
                  <span aria-hidden="true" className="size-1.5 rounded-full bg-[var(--accent)]" />
                  {row}
                </li>
              ))}
            </ul>
          </div>
        }
      />

      <PricingTable />

      <Section id="why-support" alt aria-labelledby="why-support-title">
        <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-12 lg:gap-12">
          <div className="lg:col-span-6">
            <Reveal>
              <SectionHeading
                id="why-support-title"
                eyebrow="为什么免费"
                title="开源不等于不用成本"
                lead="维护一台 macOS 实时系统要花真实的时间：追着系统更新适配、复现不同机型上的权限问题、把 40 篇文档跟代码同步更新。这些成本由项目自己承担，转移成本的方式不是收费 —— 而是欢迎你一起把这部分时间投进来。"
              />
              <ul className="mt-8 space-y-4">
                {[
                  {
                    t: '环境问题很难远程猜',
                    d: '屏幕录制授权、辅助功能信任、BPF 权限恢复、libpcap 抓包是否被系统防火墙拦截 —— 这些都只能看日志判断。',
                  },
                  {
                    t: '文档要跟得上代码',
                    d: '每次改一处布局或参数，对应的文件:行号 引用就要更新。40 篇文档的维护成本不低。',
                  },
                  {
                    t: '路线先验要重建',
                    d: '地图数据变化后，664 节点 / 932 边的 route_graph.json 需要重新生成与验证。',
                  },
                ].map((item) => (
                  <li key={item.t} className="border-l border-[var(--stroke-default)] pl-5">
                    <h3 className="text-[length:var(--text-sm)] font-semibold text-[var(--text-primary)]">
                      {item.t}
                    </h3>
                    <p className="mt-2 text-[length:var(--text-sm)] leading-[1.7] text-[var(--text-secondary)]">
                      {item.d}
                    </p>
                  </li>
                ))}
              </ul>
            </Reveal>
          </div>
          <div className="lg:col-span-6">
            <Reveal delay={0.08}>
              <Figure
                src="/images/open-source.jpg"
                alt="抽象技术插画：开放的极光带贯穿深色空间，象征开源项目的持续维护"
                ratio="16 / 9"
              />
            </Reveal>
          </div>
        </div>
      </Section>

      <Faq items={faqSlice} />
    </>
  )
}

/** 关于「支持」的补充问答 —— 取自全站 FAQ 中与商业/许可相关的条目 */
const faqSlice = [
  {
    q: '支持档会影响我 fork 后的代码吗？',
    a: '不会。仓库的许可证始终是 GPL-3.0-or-later，与你是否付费无关 —— 三档都是 ¥0。三档提供的都是对接与协作，不改变源码的许可证义务，也不限制你 fork、改名或二次发布。',
  },
  {
    q: '企业定制会签 NDA 吗？',
    a: '可以谈，但有一条底线不会变：源码的 GPL-3.0-or-later 义务不因 NDA 消失。整套方案不收费。我们能保密的是你的业务数据、内部部署方案与未公开的自研模型，而不是 GPL 的条款本身。',
  },
  {
    q: '支持者能帮我改代码吗？',
    a: '可以。支持者档包含环境问题定位、降级阈值与模型路径调优建议；涉及实际代码改动的部分走企业定制。两档都不收费，协作范围在开始前确认清楚即可。',
  },
  {
    q: '如果我只想自己用，还需要付费吗？',
    a: '不需要，也没有什么地方需要付。社区版包含完整源码、全部功能与全部模型文件，你自己构建自己跑一分钱都不用付。三档都是 ¥0，唯一的区别是你愿意参与多少社区协作。',
  },
]
