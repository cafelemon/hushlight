import { Apple, Download, FileDown, Laptop, ShieldCheck } from 'lucide-react'
import { useHushlight } from '../app/HushlightContext'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'
import { StatusPill } from '../components/StatusPill'

export function BridgePage() {
  const { snapshot, loading, error, reload } = useHushlight()
  if (!snapshot) return <PageState loading={loading} error={error} onRetry={() => void reload()} />
  return <><PageHeader eyebrow="Bridge 与权限" title="连接这台电脑" description="Bridge 让小熙在你明确需要时使用受支持的本地能力。每项能力可以单独停用。" />
    <section className="bridge-banner"><div><span className="eyebrow light">PC Bridge</span><h2>尚未连接这台电脑</h2><p>正式安装包和自动绑定将在 W1/W2 接入。你不需要解压脚本、填写地址或打开终端。</p></div><button className="button light" disabled><Download size={17} /> 下载（待发布）</button></section>
    <div className="platform-grid">{snapshot.bridges.map((bridge) => <article className="platform-row" key={bridge.platform}>{bridge.platform === 'macOS' ? <Apple /> : <Laptop />}<div><strong>{bridge.platform}</strong><p>正式安装包尚未发布</p></div><StatusPill status={bridge.state} /></article>)}</div>
    <section className="section-block"><div className="section-heading"><div><span className="eyebrow">能力权限</span><h2>按你能得到的结果来说明</h2></div><ShieldCheck className="accent-icon" /></div><div className="permission-list">{snapshot.permissions.map((permission) => <div className="permission-row" key={permission.id}><div><div className="permission-title"><strong>{permission.name}</strong><span>{permission.level}</span></div><p>{permission.description}</p></div><button className="switch" aria-label={`${permission.name}权限`} aria-pressed={permission.enabled} disabled><span /></button></div>)}</div><div className="inline-note"><ShieldCheck size={18} /><p>消息发送属于 L3 外部动作：草稿不会发送，每次发送前都必须复述对象和完整内容并获得明确确认。</p></div></section>
    <section className="diagnostic-row"><span className="setting-icon"><FileDown /></span><div><strong>诊断与支持</strong><p>Bridge 连接后可以生成脱敏诊断包；默认不包含聊天正文、联系人、凭据和敏感路径。</p></div><button className="button secondary small" disabled>导出诊断（待连接）</button></section>
  </>
}
