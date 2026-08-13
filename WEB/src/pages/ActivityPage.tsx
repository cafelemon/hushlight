import { Activity } from 'lucide-react'
import { useHushlight } from '../app/HushlightContext'
import { ActivityList } from '../components/ActivityList'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'

export function ActivityPage() {
  const { snapshot, loading, error } = useHushlight()
  if (!snapshot) return <PageState loading={loading} error={error} />
  return <><PageHeader eyebrow="活动记录" title="发生过什么，一目了然" description="成功、失败、阻止和待确认分别记录。说明性示例不会被当作真实动作结果。" />
    <section className="section-block"><div className="section-heading"><div><span className="eyebrow">最近 7 天</span><h2>动作与连接记录</h2></div><Activity className="accent-icon" /></div><ActivityList activities={snapshot.activities} /></section>
  </>
}

