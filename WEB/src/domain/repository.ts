import type { CompanionSettings, HushlightSnapshot, MemoryUpdate } from './models'

export interface HushlightRepository {
  getSnapshot(): Promise<HushlightSnapshot>
  updateSettings(settings: CompanionSettings): Promise<HushlightSnapshot>
  updateMemory(id: string, memory: MemoryUpdate): Promise<HushlightSnapshot>
  deleteMemory(id: string): Promise<HushlightSnapshot>
}
