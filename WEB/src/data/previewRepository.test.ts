import { createPreviewRepository } from './previewRepository'

describe('previewRepository', () => {
  it('always identifies preview data and starts disconnected', async () => {
    const snapshot = await createPreviewRepository().getSnapshot()
    expect(snapshot.source).toBe('preview')
    expect(snapshot.device).toBeNull()
    expect(snapshot.bridges.every((bridge) => bridge.state === 'not_connected')).toBe(true)
  })

  it('updates settings without mutating an earlier snapshot', async () => {
    const repository = createPreviewRepository()
    const before = await repository.getSnapshot()
    const after = await repository.updateSettings({ ...before.settings, mode: 'quiet' })
    expect(before.settings.mode).toBe('balanced')
    expect(after.settings.mode).toBe('quiet')
  })

  it('removes only the requested preview memory', async () => {
    const repository = createPreviewRepository()
    const before = await repository.getSnapshot()
    const after = await repository.deleteMemory(before.memories[0].id)
    expect(after.memories).toHaveLength(before.memories.length - 1)
    expect(after.memories.some((item) => item.id === before.memories[0].id)).toBe(false)
  })
})

