import { fireEvent, render, screen } from '@testing-library/react'
import { vi } from 'vitest'
import { PageState } from './PageState'

describe('PageState', () => {
  it('offers a retry action for recoverable read failures', () => {
    const onRetry = vi.fn()
    render(<PageState loading={false} error="暂时无法读取" onRetry={onRetry} />)

    fireEvent.click(screen.getByRole('button', { name: '重新读取' }))

    expect(onRetry).toHaveBeenCalledOnce()
  })

  it('announces loading without exposing a retry action', () => {
    render(<PageState loading error={null} onRetry={() => undefined} />)

    expect(screen.getByRole('status')).toHaveTextContent('正在准备小熙的状态')
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
  })
})

