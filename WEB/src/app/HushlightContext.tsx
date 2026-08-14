import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import type { CompanionSettings, HushlightSnapshot, MemoryUpdate } from '../domain/models'
import type { HushlightRepository } from '../domain/repository'

interface HushlightContextValue {
  snapshot: HushlightSnapshot | null
  loading: boolean
  error: string | null
  saving: boolean
  operationError: string | null
  reload: () => Promise<void>
  clearOperationError: () => void
  updateSettings: (settings: CompanionSettings) => Promise<boolean>
  updateMemory: (id: string, memory: MemoryUpdate) => Promise<boolean>
  deleteMemory: (id: string) => Promise<boolean>
}

const HushlightContext = createContext<HushlightContextValue | null>(null)

export function HushlightProvider({ repository, children }: { repository: HushlightRepository; children: ReactNode }) {
  const [snapshot, setSnapshot] = useState<HushlightSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [operationError, setOperationError] = useState<string | null>(null)
  const readSequence = useRef(0)
  const mutationInFlight = useRef(false)

  const reload = useCallback(async () => {
    const sequence = ++readSequence.current
    setLoading(true)
    setError(null)
    try {
      const result = await repository.getSnapshot()
      if (sequence === readSequence.current) setSnapshot(result)
    } catch {
      if (sequence === readSequence.current) setError('暂时无法读取小熙的状态，请稍后重试。')
    } finally {
      if (sequence === readSequence.current) setLoading(false)
    }
  }, [repository])

  useEffect(() => {
    void reload()
    return () => { readSequence.current += 1 }
  }, [reload])

  const mutate = useCallback(async (operation: () => Promise<HushlightSnapshot>) => {
    if (mutationInFlight.current) return false
    mutationInFlight.current = true
    setSaving(true)
    setOperationError(null)
    try {
      setSnapshot(await operation())
      return true
    } catch {
      setOperationError('这次更改没有保存，请稍后重试。')
      return false
    } finally {
      mutationInFlight.current = false
      setSaving(false)
    }
  }, [])

  const value = useMemo<HushlightContextValue>(() => ({
    snapshot,
    loading,
    error,
    saving,
    operationError,
    reload,
    clearOperationError: () => setOperationError(null),
    updateSettings: (settings) => mutate(() => repository.updateSettings(settings)),
    updateMemory: (id, memory) => mutate(() => repository.updateMemory(id, memory)),
    deleteMemory: (id) => mutate(() => repository.deleteMemory(id)),
  }), [snapshot, loading, error, saving, operationError, reload, mutate, repository])

  return <HushlightContext.Provider value={value}>{children}</HushlightContext.Provider>
}

export function useHushlight() {
  const value = useContext(HushlightContext)
  if (!value) throw new Error('useHushlight must be used inside HushlightProvider')
  return value
}
