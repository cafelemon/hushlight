import { Navigate, Route, Routes } from 'react-router'
import { AppShell } from '../components/AppShell'
import { ActivityPage } from '../pages/ActivityPage'
import { BridgePage } from '../pages/BridgePage'
import { CompanionPage } from '../pages/CompanionPage'
import { DashboardPage } from '../pages/DashboardPage'
import { DevicesPage } from '../pages/DevicesPage'
import { MemoriesPage } from '../pages/MemoriesPage'

export function App() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<DashboardPage />} />
        <Route path="devices" element={<DevicesPage />} />
        <Route path="companion" element={<CompanionPage />} />
        <Route path="bridge" element={<BridgePage />} />
        <Route path="memories" element={<MemoriesPage />} />
        <Route path="activity" element={<ActivityPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}

