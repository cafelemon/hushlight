import { LoaderCircle, WifiOff } from 'lucide-react'

export function PageState({ loading, error, onRetry }: { loading: boolean; error: string | null; onRetry?: () => void }) {
  if (loading) return <div className="page-state" role="status"><LoaderCircle className="spin" aria-hidden="true" /><p>正在准备小熙的状态…</p></div>
  if (error) return <div className="page-state error" role="alert"><WifiOff aria-hidden="true" /><p>{error}</p>{onRetry && <button className="button secondary" onClick={onRetry}>重新读取</button>}</div>
  return null
}
