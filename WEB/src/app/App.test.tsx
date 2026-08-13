import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { App } from './App'
import { HushlightProvider } from './HushlightContext'
import { createPreviewRepository } from '../data/previewRepository'

describe('App', () => {
  it('shows the preview source and honest disconnected state', async () => {
    render(<MemoryRouter><HushlightProvider repository={createPreviewRepository()}><App /></HushlightProvider></MemoryRouter>)
    expect(await screen.findByText('本地预览')).toBeInTheDocument()
    expect(screen.getAllByText('尚未连接').length).toBeGreaterThan(0)
    expect(screen.getByRole('heading', { name: /这里是小熙的大本营/ })).toBeInTheDocument()
  })
})

