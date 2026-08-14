import type { HushlightRepository } from '../domain/repository'
import type { CompanionSettings, HushlightSnapshot, MemoryUpdate } from '../domain/models'

const initialSnapshot: HushlightSnapshot = {
  source: 'preview',
  userName: '晚上好',
  account: { state: 'preview' },
  subscription: { status: 'unavailable' },
  device: null,
  bridges: [
    { platform: 'macOS', state: 'not_connected' },
    { platform: 'Windows', state: 'not_connected' },
  ],
  permissions: [
    { id: 'music', name: '播放音乐', description: '让小熙播放、暂停和切换网易云音乐', enabled: false, level: 'L2' },
    { id: 'volume', name: '调节音量', description: '读取并调节这台电脑的系统音量', enabled: false, level: 'L2' },
    { id: 'reminder', name: '提醒与计时', description: '创建、修改或取消本地提醒', enabled: false, level: 'L2' },
    { id: 'open', name: '打开内容', description: '只打开已登记的软件和安全链接', enabled: false, level: 'L2' },
    { id: 'message', name: '消息草稿与发送', description: '草稿不发送；每次发送都需要你的明确确认', enabled: false, level: 'L3' },
  ],
  settings: {
    mode: 'balanced',
    voice: '小熙 · 自然',
    proactiveCare: true,
    quietHours: '23:00–08:00',
  },
  memories: [
    {
      id: 'memory-example-1',
      title: '音乐偏好示例',
      detail: '工作时更喜欢安静、节奏稳定的纯音乐。',
      sourceLabel: '说明性示例 · 未保存到云端',
      updatedAt: '刚刚',
      pinned: false,
    },
    {
      id: 'memory-example-2',
      title: '陪伴边界示例',
      detail: '深夜不主动发起对话，明确提醒除外。',
      sourceLabel: '说明性示例 · 未保存到云端',
      updatedAt: '刚刚',
      pinned: true,
    },
  ],
  activities: [
    { id: 'activity-1', title: 'Bridge 尚未连接', detail: '安装并连接后，这里会显示来自电脑的真实动作结果。', status: 'blocked', happenedAt: '当前', isExample: false },
    { id: 'activity-2', title: '播放音乐', detail: '说明性示例：已开始播放「柔和专注」。', status: 'success', happenedAt: '示例', isExample: true },
    { id: 'activity-3', title: '发送消息', detail: '说明性示例：等待你确认收件人和完整内容。', status: 'pending', happenedAt: '示例', isExample: true },
  ],
}

const clone = (snapshot: HushlightSnapshot): HushlightSnapshot => structuredClone(snapshot)

class PreviewRepository implements HushlightRepository {
  private snapshot = clone(initialSnapshot)

  async getSnapshot() {
    return clone(this.snapshot)
  }

  async updateSettings(settings: CompanionSettings) {
    this.snapshot.settings = { ...settings }
    return clone(this.snapshot)
  }

  async updateMemory(id: string, memory: MemoryUpdate) {
    this.snapshot.memories = this.snapshot.memories.map((item) => item.id === id
      ? { ...item, ...memory, updatedAt: '刚刚' }
      : item)
    return clone(this.snapshot)
  }

  async deleteMemory(id: string) {
    this.snapshot.memories = this.snapshot.memories.filter((memory) => memory.id !== id)
    return clone(this.snapshot)
  }
}

export const previewRepository = new PreviewRepository()
export const createPreviewRepository = () => new PreviewRepository()
