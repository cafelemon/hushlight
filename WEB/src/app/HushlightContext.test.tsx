import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { useHushlight, HushlightProvider } from './HushlightContext'
import { createPreviewRepository } from '../data/previewRepository'
import type { CompanionSettings, HushlightSnapshot, MemoryUpdate } from '../domain/models'
import type { HushlightRepository } from '../domain/repository'

class RecoverableRepository implements HushlightRepository {
  private snapshot: HushlightSnapshot | null = null
  reads = 0

  async getSnapshot() {
    this.reads += 1
    if (this.reads === 1) throw new Error('offline')
    this.snapshot ??= await createPreviewRepository().getSnapshot()
    return structuredClone(this.snapshot)
  }

  async updateSettings(settings: CompanionSettings) {
    this.snapshot ??= await createPreviewRepository().getSnapshot()
    this.snapshot.settings = settings
    return structuredClone(this.snapshot)
  }

  async updateMemory(_id: string, _memory: MemoryUpdate): Promise<HushlightSnapshot> {
    this.snapshot ??= await createPreviewRepository().getSnapshot()
    return structuredClone(this.snapshot)
  }

  async deleteMemory(_id: string): Promise<HushlightSnapshot> {
    throw new Error('write failed')
  }
}

function ContextProbe() {
  const { snapshot, loading, error, reload, deleteMemory, saving, operationError } = useHushlight()
  if (loading) return <p>loading</p>
  if (!snapshot) return <><p>{error}</p><button onClick={reload}>retry</button></>
  return <>
    <p>{snapshot.source}</p>
    <button disabled={saving} onClick={() => void deleteMemory('memory-example-1')}>delete</button>
    {operationError && <p role="alert">{operationError}</p>}
  </>
}

describe('HushlightProvider', () => {
  it('recovers from an initial read failure without remounting the app', async () => {
    const repository = new RecoverableRepository()
    render(<HushlightProvider repository={repository}><ContextProbe /></HushlightProvider>)

    expect(await screen.findByText('暂时无法读取小熙的状态，请稍后重试。')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'retry' }))

    expect(await screen.findByText('preview')).toBeInTheDocument()
    expect(repository.reads).toBe(2)
  })

  it('surfaces mutation failures while preserving the last good snapshot', async () => {
    const repository = new RecoverableRepository()
    repository.reads = 1
    render(<HushlightProvider repository={repository}><ContextProbe /></HushlightProvider>)
    expect(await screen.findByText('preview')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'delete' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('这次更改没有保存，请稍后重试。')
    await waitFor(() => expect(screen.getByRole('button', { name: 'delete' })).toBeEnabled())
    expect(screen.getByText('preview')).toBeInTheDocument()
  })
})
