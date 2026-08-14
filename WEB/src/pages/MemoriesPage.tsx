import { Brain, Pencil, Pin, Trash2 } from 'lucide-react'
import { useState } from 'react'
import { useHushlight } from '../app/HushlightContext'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'
import type { MemoryUpdate } from '../domain/models'

interface MemoryDraft extends MemoryUpdate { id: string }

export function MemoriesPage() {
  const { snapshot, loading, error, reload, saving, operationError, clearOperationError, updateMemory, deleteMemory } = useHushlight()
  const [pendingDelete, setPendingDelete] = useState<string | null>(null)
  const [draft, setDraft] = useState<MemoryDraft | null>(null)
  if (!snapshot) return <PageState loading={loading} error={error} onRetry={() => void reload()} />
  return <><PageHeader eyebrow="记忆" title="只留下真正有帮助的事" description="记忆应当有来源、可纠正、可删除。这里的两条内容是说明性示例，并未保存到云端。" />
    {operationError && <div className="operation-error" role="alert">{operationError}<button onClick={clearOperationError}>关闭</button></div>}
    {snapshot.memories.length ? <div className="memory-list">{snapshot.memories.map((memory) => <article className="memory-row" key={memory.id}><div className="memory-icon"><Brain /></div>{draft?.id === memory.id ? <form className="memory-edit-form" onSubmit={async (event) => { event.preventDefault(); if (await updateMemory(draft.id, { title: draft.title.trim(), detail: draft.detail.trim(), pinned: draft.pinned })) setDraft(null) }}><label>记忆名称<input value={draft.title} maxLength={40} required onChange={(event) => setDraft({ ...draft, title: event.target.value })} /></label><label>记忆内容<textarea value={draft.detail} maxLength={240} required rows={3} onChange={(event) => setDraft({ ...draft, detail: event.target.value })} /></label><label className="checkbox-label"><input type="checkbox" checked={draft.pinned} onChange={(event) => setDraft({ ...draft, pinned: event.target.checked })} />固定这条记忆</label><div className="form-actions"><button type="button" className="button secondary small" disabled={saving} onClick={() => setDraft(null)}>取消</button><button type="submit" className="button primary small" disabled={saving || !draft.title.trim() || !draft.detail.trim()}>{saving ? '正在保存…' : '保存更改'}</button></div></form> : <><div><div className="memory-title"><strong>{memory.title}</strong>{memory.pinned && <span><Pin size={13} />已固定</span>}</div><p>{memory.detail}</p><small>{memory.sourceLabel} · {memory.updatedAt}</small></div><div className="memory-actions"><button className="icon-button" aria-label={`编辑${memory.title}`} disabled={saving} onClick={() => { clearOperationError(); setPendingDelete(null); setDraft({ id: memory.id, title: memory.title, detail: memory.detail, pinned: memory.pinned }) }}><Pencil size={18} /></button><button className="icon-button danger" aria-label={`删除${memory.title}`} disabled={saving} onClick={() => { clearOperationError(); setDraft(null); setPendingDelete(memory.id) }}><Trash2 size={18} /></button></div></>}{pendingDelete === memory.id && <div className="confirm-bar" role="alertdialog" aria-label={`确认删除${memory.title}`}><span>仅从本地预览中移除这条示例？</span><button disabled={saving} onClick={() => setPendingDelete(null)}>取消</button><button className="danger-text" disabled={saving} onClick={async () => { if (await deleteMemory(memory.id)) setPendingDelete(null) }}>{saving ? '正在移除…' : '移除'}</button></div>}</article>)}</div> : <div className="empty-hero compact"><Brain size={36} /><h2>这里暂时是空的</h2><p>经你确认的偏好和边界会出现在这里。</p></div>}
  </>
}
