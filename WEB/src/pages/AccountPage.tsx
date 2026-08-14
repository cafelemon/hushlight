import { CreditCard, Gauge, LogIn, ShieldCheck, UserRound } from 'lucide-react'
import { Link } from 'react-router'
import { useHushlight } from '../app/HushlightContext'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'

export function AccountPage() {
  const { snapshot, loading, error, reload } = useHushlight()
  if (!snapshot) return <PageState loading={loading} error={error} onRetry={() => void reload()} />

  return <>
    <PageHeader eyebrow="账户与订阅" title="账户、用量和数据边界" description="登录、套餐与用量服务尚未接入。W0 只展示未来入口，不虚构账户、额度、价格或扣费记录。" />
    <section className="account-status"><span className="setting-icon"><UserRound /></span><div><span className="eyebrow">当前状态</span><h2>本地预览 · 未登录真实账户</h2><p>接入身份服务后，这里会显示经过验证的账户与设备归属。</p></div><button className="button primary" disabled><LogIn size={17} /> 登录（待接入）</button></section>
    <div className="account-grid">
      <section className="section-block"><CreditCard className="accent-icon" /><span className="eyebrow">订阅方案</span><h2>尚未启用</h2><p>月卡价格、免费额度和高频用户限额仍待真实成本与用户验证，不在 W0 预设。</p><button className="button secondary small" disabled>管理订阅（待接入）</button></section>
      <section className="section-block"><Gauge className="accent-icon" /><span className="eyebrow">用量与成本提示</span><h2>暂无真实用量</h2><p>未来只展示口径清晰、来自计费服务的轮次和额度，不用演示数字代替真实账单。</p></section>
      <section className="section-block"><ShieldCheck className="accent-icon" /><span className="eyebrow">你的数据</span><h2>记忆仍由你管理</h2><p>经确认的偏好可以查看、纠正和删除；删除后必须从检索与生成链路中失效。</p><Link className="text-link" to="/memories">前往记忆管理</Link></section>
    </div>
  </>
}
