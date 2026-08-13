import { Bot, Link2, QrCode } from 'lucide-react'
import { useHushlight } from '../app/HushlightContext'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'

export function DevicesPage() {
  const { snapshot, loading, error } = useHushlight()
  if (!snapshot) return <PageState loading={loading} error={error} />
  return <><PageHeader eyebrow="设备" title="你的小熙" description="绑定、查看和管理桌面设备。设备状态将以云端的最后确认结果为准。" />
    <section className="empty-hero"><div className="empty-illustration"><Bot size={42} /><span /></div><h2>还没有绑定设备</h2><p>设备通电后扫描屏幕上的二维码，把她添加到这个账户。W0 暂未接入真实扫码流程。</p><button className="button primary" disabled><QrCode size={17} /> 扫码绑定（待接入）</button></section>
    <section className="section-block"><div className="section-heading"><div><span className="eyebrow">绑定会发生什么</span><h2>只需要三步</h2></div></div><ol className="steps"><li><span>1</span><div><strong>设备通电</strong><p>小熙进入待绑定状态并显示一次性二维码。</p></div></li><li><span>2</span><div><strong>在这里确认</strong><p>登录后扫描二维码，核对设备名称。</p></div></li><li><span>3</span><div><strong>连接电脑</strong><p>安装 Bridge 后自动关联，不填写端口或令牌。</p></div></li></ol><div className="inline-note"><Link2 size={18} /><p>Bridge 不是基础聊天的前置条件；未连接时，本地能力会明确保持不可用。</p></div></section>
  </>
}

