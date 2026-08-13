import { LoaderCircle, WifiOff } from 'lucide-react'

export function PageState({ loading, error }: { loading: boolean; error: string | null }) {
  if (loading) return <div className="page-state"><LoaderCircle className="spin" aria-hidden="true" /><p>正在准备小熙的状态…</p></div>
  if (error) return <div className="page-state error"><WifiOff aria-hidden="true" /><p>{error}</p></div>
  return null
}

