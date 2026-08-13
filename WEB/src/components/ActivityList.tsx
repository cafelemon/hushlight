import { StatusPill } from './StatusPill'
import type { ActivityItem } from '../domain/models'

export function ActivityList({ activities }: { activities: ActivityItem[] }) {
  if (!activities.length) return <div className="empty-state"><strong>还没有活动记录</strong><p>小熙完成或阻止动作后，会把真实结果留在这里。</p></div>
  return <div className="activity-list">{activities.map((item) => (
    <article className="activity-row" key={item.id}>
      <div><div className="activity-title"><strong>{item.title}</strong>{item.isExample && <span className="example-tag">说明示例</span>}</div><p>{item.detail}</p></div>
      <div className="activity-meta"><StatusPill status={item.status} /><time>{item.happenedAt}</time></div>
    </article>
  ))}</div>
}

