import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
// Self-hosted fonts (@fontsource — bundled by Vite, no CDN, works offline on GitHub Pages).
// These load the families the src/index.css @theme tokens name: --font-sans ('Inter') and
// --font-mono ('JetBrains Mono'). Weights: sans 400/500/600 · mono 400/500.
import '@fontsource/inter/400.css'
import '@fontsource/inter/500.css'
import '@fontsource/inter/600.css'
import '@fontsource/jetbrains-mono/400.css'
import '@fontsource/jetbrains-mono/500.css'
import './index.css'
import { App } from './app/App'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
