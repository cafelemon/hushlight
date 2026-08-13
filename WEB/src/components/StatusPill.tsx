import { AlertTriangle, CheckCircle2, CircleDashed, ShieldX } from 'lucide-react'
import type { ActivityStatus, ConnectionState } from '../domain/models'

const labels: Record<ActivityStatus | ConnectionState, string> = {
  success: '已完成', failure: '失败', blocked: '已阻止', pending: '待确认',
  online: '在线', offline: '离线', not_connected: '尚未连接', unknown: '未知',
}

export function StatusPill({ status }: { status: ActivityStatus | ConnectionState }) {
  const tone = status === 'success' || status === 'online' ? 'success'
    : status === 'failure' || status === 'offline' ? 'danger'
    : status === 'pending' || status === 'unknown' ? 'warning' : 'neutral'
  const Icon = tone === 'success' ? CheckCircle2 : tone === 'danger' ? AlertTriangle : status === 'blocked' ? ShieldX : CircleDashed
  return <span className={`status-pill ${tone}`}><Icon size={14} aria-hidden="true" />{labels[status]}</span>
}

