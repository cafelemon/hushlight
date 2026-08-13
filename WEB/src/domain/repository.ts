import type { CompanionSettings, HushlightSnapshot } from './models'

export interface HushlightRepository {
  getSnapshot(): Promise<HushlightSnapshot>
  updateSettings(settings: CompanionSettings): Promise<HushlightSnapshot>
  deleteMemory(id: string): Promise<HushlightSnapshot>
}

