import { Activity, Bot, Brain, HeartHandshake, Home, Laptop, Sparkles } from 'lucide-react'
import { NavLink, Outlet } from 'react-router'
import { useHushlight } from '../app/HushlightContext'

const navigation = [
  { to: '/', label: '总览', icon: Home, end: true },
  { to: '/devices', label: '设备', icon: Bot },
  { to: '/companion', label: '陪伴设置', icon: HeartHandshake },
  { to: '/bridge', label: 'Bridge 与权限', icon: Laptop },
  { to: '/memories', label: '记忆', icon: Brain },
  { to: '/activity', label: '活动记录', icon: Activity },
]

export function AppShell() {
  const { snapshot } = useHushlight()
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand" aria-label="Hushlight 小熙">
          <span className="brand-mark"><Sparkles size={20} aria-hidden="true" /></span>
          <span><strong>Hushlight</strong><small>小熙</small></span>
        </div>
        <nav className="primary-nav" aria-label="主要导航">
          {navigation.map(({ to, label, icon: Icon, end }) => (
            <NavLink key={to} to={to} end={end} className={({ isActive }) => isActive ? 'nav-link active' : 'nav-link'}>
              <Icon size={19} aria-hidden="true" /><span>{label}</span>
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-note">
          <span className="eyebrow">W0 骨架</span>
          <p>当前没有连接真实云端、设备或电脑。</p>
        </div>
      </aside>
      <div className="main-column">
        <header className="topbar">
          <div className="mobile-brand"><Sparkles size={18} /><strong>小熙</strong></div>
          <nav className="mobile-nav" aria-label="移动端导航">
            {navigation.map(({ to, label, end }) => <NavLink key={to} to={to} end={end}>{label}</NavLink>)}
          </nav>
          <div className="preview-badge"><span className="preview-dot" />{snapshot?.source === 'live' ? '实时数据' : '本地预览'}</div>
        </header>
        <main className="page-container"><Outlet /></main>
      </div>
    </div>
  )
}

