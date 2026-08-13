import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { CompanionSettings, HushlightSnapshot } from '../domain/models'
import type { HushlightRepository } from '../domain/repository'

interface HushlightContextValue {
  snapshot: HushlightSnapshot | null
  loading: boolean
  error: string | null
  updateSettings: (settings: CompanionSettings) => Promise<void>
  deleteMemory: (id: string) => Promise<void>
}

const HushlightContext = createContext<HushlightContextValue | null>(null)

export function HushlightProvider({ repository, children }: { repository: HushlightRepository; children: ReactNode }) {
  const [snapshot, setSnapshot] = useState<HushlightSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    repository.getSnapshot().then((result) => {
      if (active) setSnapshot(result)
    }).catch(() => {
      if (active) setError('暂时无法读取小熙的状态，请稍后重试。')
    }).finally(() => {
      if (active) setLoading(false)
    })
    return () => { active = false }
  }, [repository])

  const value = useMemo<HushlightContextValue>(() => ({
    snapshot,
    loading,
    error,
    updateSettings: async (settings) => setSnapshot(await repository.updateSettings(settings)),
    deleteMemory: async (id) => setSnapshot(await repository.deleteMemory(id)),
  }), [snapshot, loading, error, repository])

  return <HushlightContext.Provider value={value}>{children}</HushlightContext.Provider>
}

export function useHushlight() {
  const value = useContext(HushlightContext)
  if (!value) throw new Error('useHushlight must be used inside HushlightProvider')
  return value
}

