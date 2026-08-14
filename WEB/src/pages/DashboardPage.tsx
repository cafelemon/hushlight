import { ArrowRight, Bot, Laptop, ShieldCheck, Sparkles } from 'lucide-react'
import { Link } from 'react-router'
import { useHushlight } from '../app/HushlightContext'
import { ActivityList } from '../components/ActivityList'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'
import { StatusPill } from '../components/StatusPill'

export function DashboardPage() {
  const { snapshot, loading, error, reload } = useHushlight()
  if (!snapshot) return <PageState loading={loading} error={error} onRetry={() => void reload()} />
  const enabledPermissions = snapshot.permissions.filter((item) => item.enabled).length
  return <>
    <PageHeader eyebrow="你的 Hushlight" title={`${snapshot.userName}，这里是小熙的大本营`} description="查看连接、陪伴设置和最近发生的事情。日常交流仍然交给小熙。" />
    <section className="welcome-panel">
      <div className="companion-orbit" aria-hidden="true"><span className="face">⌣</span></div>
      <div><span className="eyebrow light">从这里开始</span><h2>先把小熙和这台电脑连接起来</h2><p>设备还没有绑定，Bridge 也尚未连接。完成后，小熙才能按你的请求播放音乐、设置提醒或准备消息草稿。</p><div className="button-row"><Link className="button primary" to="/devices">绑定设备 <ArrowRight size={17} /></Link><Link className="button secondary dark" to="/bridge">了解 Bridge</Link></div></div>
    </section>
    <section className="summary-grid" aria-label="连接摘要">
      <Link className="summary-item" to="/devices"><span className="summary-icon"><Bot /></span><div><span>小熙设备</span><strong>{snapshot.device ? snapshot.device.name : '尚未绑定'}</strong></div><StatusPill status={snapshot.device?.state ?? 'not_connected'} /></Link>
      <Link className="summary-item" to="/bridge"><span className="summary-icon"><Laptop /></span><div><span>这台电脑</span><strong>Bridge 未连接</strong></div><StatusPill status="not_connected" /></Link>
      <Link className="summary-item" to="/bridge"><span className="summary-icon"><ShieldCheck /></span><div><span>已启用能力</span><strong>{enabledPermissions} / {snapshot.permissions.length}</strong></div><span className="summary-arrow"><ArrowRight /></span></Link>
    </section>
    <div className="content-grid">
      <section className="section-block"><div className="section-heading"><div><span className="eyebrow">最近活动</span><h2>每个结果都有出处</h2></div><Link to="/activity">查看全部</Link></div><ActivityList activities={snapshot.activities.slice(0, 3)} /></section>
      <aside className="section-block soft"><Sparkles className="accent-icon" /><span className="eyebrow">陪伴模式</span><h2>{snapshot.settings.mode === 'balanced' ? '自然平衡' : snapshot.settings.mode === 'quiet' ? '安静陪伴' : '温暖主动'}</h2><p>小熙会先回应你的感受，再判断你想聊天、安静，还是需要一个小动作。</p><Link className="text-link" to="/companion">调整陪伴方式 <ArrowRight size={16} /></Link></aside>
    </div>
  </>
}
