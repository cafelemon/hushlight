export type DataSource = 'preview' | 'live'
export type ConnectionState = 'online' | 'offline' | 'not_connected' | 'unknown'
export type ActivityStatus = 'success' | 'failure' | 'blocked' | 'pending'

export interface Device {
  id: string
  name: string
  model: string
  state: ConnectionState
  lastSeen?: string
}

export interface Bridge {
  platform: 'macOS' | 'Windows'
  state: ConnectionState
  version?: string
}

export interface Permission {
  id: string
  name: string
  description: string
  enabled: boolean
  level: 'L0' | 'L1' | 'L2' | 'L3'
}

export interface CompanionSettings {
  mode: 'balanced' | 'quiet' | 'warm'
  voice: string
  proactiveCare: boolean
  quietHours: string
}

export interface AccountSummary {
  state: 'preview' | 'signed_out' | 'authenticated'
  displayName?: string
}

export interface SubscriptionSummary {
  status: 'unavailable' | 'trial' | 'active' | 'paused'
  planName?: string
  usageLabel?: string
}

export interface MemoryItem {
  id: string
  title: string
  detail: string
  sourceLabel: string
  updatedAt: string
  pinned: boolean
}

export type MemoryUpdate = Pick<MemoryItem, 'title' | 'detail' | 'pinned'>

export interface ActivityItem {
  id: string
  title: string
  detail: string
  status: ActivityStatus
  happenedAt: string
  isExample: boolean
}

export interface HushlightSnapshot {
  source: DataSource
  userName: string
  account: AccountSummary
  subscription: SubscriptionSummary
  device: Device | null
  bridges: Bridge[]
  permissions: Permission[]
  settings: CompanionSettings
  memories: MemoryItem[]
  activities: ActivityItem[]
}
