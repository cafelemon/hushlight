import { BellOff, MessageCircleHeart, MoonStar } from 'lucide-react'
import { useState } from 'react'
import { useHushlight } from '../app/HushlightContext'
import { PageHeader } from '../components/PageHeader'
import { PageState } from '../components/PageState'
import type { CompanionSettings } from '../domain/models'

const modes: { id: CompanionSettings['mode']; name: string; description: string }[] = [
  { id: 'balanced', name: '自然平衡', description: '想聊时回应，也尊重安静和自然结束。' },
  { id: 'quiet', name: '安静陪伴', description: '减少主动发起，更克制地回应和建议。' },
  { id: 'warm', name: '温暖主动', description: '在频率预算内，更主动地问候与提醒。' },
]

export function CompanionPage() {
  const { snapshot, loading, error, updateSettings } = useHushlight()
  const [saved, setSaved] = useState(false)
  if (!snapshot) return <PageState loading={loading} error={error} />
  const save = async (settings: CompanionSettings) => { await updateSettings(settings); setSaved(true); window.setTimeout(() => setSaved(false), 1800) }
  return <><PageHeader eyebrow="陪伴设置" title="让小熙更懂你的节奏" description="选择回应方式和主动边界。W0 的调整只保存在当前本地预览会话。" action={saved && <span className="save-toast">已更新本地预览</span>} />
    <section className="section-block"><div className="section-heading"><div><span className="eyebrow">陪伴模式</span><h2>你希望她怎样在身边</h2></div></div><div className="choice-grid">{modes.map((mode) => <button key={mode.id} className={snapshot.settings.mode === mode.id ? 'choice-card selected' : 'choice-card'} onClick={() => save({ ...snapshot.settings, mode: mode.id })} aria-pressed={snapshot.settings.mode === mode.id}><MessageCircleHeart /><strong>{mode.name}</strong><span>{mode.description}</span></button>)}</div></section>
    <section className="settings-list"><div className="setting-row"><span className="setting-icon"><MoonStar /></span><div><strong>静默时段</strong><p>默认在 {snapshot.settings.quietHours} 不主动发起对话，明确提醒除外。</p></div><button className="button secondary small" disabled>调整（待接入）</button></div><div className="setting-row"><span className="setting-icon"><BellOff /></span><div><strong>主动关怀</strong><p>每天最多 3 次；连续忽略后自动降低频率。</p></div><button className="switch" aria-label="主动关怀" aria-pressed={snapshot.settings.proactiveCare} onClick={() => save({ ...snapshot.settings, proactiveCare: !snapshot.settings.proactiveCare })}><span /></button></div></section>
  </>
}

