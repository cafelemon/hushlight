import { Brain, Pin, Trash2 } from 'lucide-react'
import { useState } from 'react'
import { useHushlight } from '../app/HushlightContext'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'

export function MemoriesPage() {
  const { snapshot, loading, error, deleteMemory } = useHushlight()
  const [pendingDelete, setPendingDelete] = useState<string | null>(null)
  if (!snapshot) return <PageState loading={loading} error={error} />
  return <><PageHeader eyebrow="记忆" title="只留下真正有帮助的事" description="记忆应当有来源、可纠正、可删除。这里的两条内容是说明性示例，并未保存到云端。" />
    {snapshot.memories.length ? <div className="memory-list">{snapshot.memories.map((memory) => <article className="memory-row" key={memory.id}><div className="memory-icon"><Brain /></div><div><div className="memory-title"><strong>{memory.title}</strong>{memory.pinned && <span><Pin size={13} />已固定</span>}</div><p>{memory.detail}</p><small>{memory.sourceLabel} · {memory.updatedAt}</small></div><button className="icon-button danger" aria-label={`删除${memory.title}`} onClick={() => setPendingDelete(memory.id)}><Trash2 size={18} /></button>{pendingDelete === memory.id && <div className="confirm-bar"><span>仅从本地预览中移除这条示例？</span><button onClick={() => setPendingDelete(null)}>取消</button><button className="danger-text" onClick={async () => { await deleteMemory(memory.id); setPendingDelete(null) }}>移除</button></div>}</article>)}</div> : <div className="empty-hero compact"><Brain size={36} /><h2>这里暂时是空的</h2><p>经你确认的偏好和边界会出现在这里。</p></div>}
  </>
}

