import { Suspense, lazy, useEffect } from 'react'
import {
  BrowserRouter,
  Route,
  Routes,
  useLocation,
} from 'react-router-dom'
import { Navbar } from './components/Navbar'
import { Footer } from './components/Footer'
import { PageTransition } from './components/PageTransition'
import { pageMeta, siteMeta } from './content/site'

/**
 * 路由级代码分割
 *
 * 性能目标：首屏只加载首页所需的 chunk。
 * Home 同步引入（首屏必需），其余页面 lazy 加载 —— 访问时才下载。
 * Suspense fallback 用静态占位块（DESIGN_SYSTEM §6.4：不用骨架屏 shimmer）。
 */
import { Home } from './pages/Home'

const Architecture = lazy(() =>
  import('./pages/Architecture').then((m) => ({ default: m.Architecture })),
)
const Docs = lazy(() =>
  import('./pages/Docs').then((m) => ({ default: m.Docs })),
)
const Pricing = lazy(() =>
  import('./pages/Pricing').then((m) => ({ default: m.Pricing })),
)
const About = lazy(() =>
  import('./pages/About').then((m) => ({ default: m.About })),
)
const Contact = lazy(() =>
  import('./pages/Contact').then((m) => ({ default: m.Contact })),
)
const NotFound = lazy(() =>
  import('./pages/NotFound').then((m) => ({ default: m.NotFound })),
)

/**
 * 应用外壳
 *
 * 页面过渡的关键结构（DESIGN_SYSTEM §6.6）：
 *   <Navbar />  ←── 位于 PageTransition 之外
 *   <PageTransition>{routes}</PageTransition>
 *   <Footer />  ←── 位于 PageTransition 之外
 *
 * Navbar / Footer 若放进 PageTransition，会跟着页面一起淡出淡入，
 * 破坏「同一部机器的不同面板」的连续性感知。
 */
export default function App() {
  return (
    <BrowserRouter>
      <Shell />
    </BrowserRouter>
  )
}

function Shell() {
  const location = useLocation()

  // 页面标题与 description 随路由更新
  useEffect(() => {
    const meta = pageMeta[location.pathname]
    document.title = meta ? meta.title : `${siteMeta.name} · ${siteMeta.tagline}`

    const desc = document.querySelector('meta[name="description"]')
    if (desc && meta) {
      desc.setAttribute('content', meta.description)
    }
  }, [location.pathname])

  return (
    <div className="flex min-h-screen flex-col">
      <Navbar />

      <div className="flex-1">
        <PageTransition>
          <Suspense fallback={<RouteFallback />}>
            <Routes location={location}>
              <Route path="/" element={<Home />} />
              <Route path="/architecture" element={<Architecture />} />
              <Route path="/docs" element={<Docs />} />
              <Route path="/pricing" element={<Pricing />} />
              <Route path="/about" element={<About />} />
              <Route path="/contact" element={<Contact />} />
              <Route path="*" element={<NotFound />} />
            </Routes>
          </Suspense>
        </PageTransition>
      </div>

      <Footer />
    </div>
  )
}

/** 路由懒加载占位 —— 静态内陷块 + 等宽文本，不用骨架屏 shimmer */
function RouteFallback() {
  return (
    <div className="container-page py-24">
      <div className="rounded-[var(--radius-md)] border border-[var(--stroke-default)] bg-[var(--bg-inset)] p-8">
        <p className="font-mono text-[12px] text-[var(--text-tertiary)]">
          ⟨ loading route ⟩
        </p>
      </div>
    </div>
  )
}
