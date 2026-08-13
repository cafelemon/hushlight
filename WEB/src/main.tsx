import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router'
import { App } from './app/App'
import { HushlightProvider } from './app/HushlightContext'
import { previewRepository } from './data/previewRepository'
import './styles/global.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter>
      <HushlightProvider repository={previewRepository}>
        <App />
      </HushlightProvider>
    </BrowserRouter>
  </StrictMode>,
)

