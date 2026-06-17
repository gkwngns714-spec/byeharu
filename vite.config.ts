import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
// base '/byeharu/' = served as a GitHub Pages project site at
// https://<owner>.github.io/byeharu/. BrowserRouter reads this via BASE_URL.
export default defineConfig({
  base: '/byeharu/',
  plugins: [react(), tailwindcss()],
})
