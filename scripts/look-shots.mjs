#!/usr/bin/env node
// LOOK-SHOTS — screenshot the REAL screens (mounted with fixture data by tests/harness/look.html)
// at mobile widths, for the visual-redesign before/after record.
//
//   node scripts/look-shots.mjs [outDir]        (default ./look-shots)
//
// Starts its OWN Vite dev server — with the app's tailwind pipeline, which the stock
// tests/harness/vite.config.ts (the behavior-proof uispec server) deliberately omits — then
// drives Playwright over every screen × state combination:
//   ship | fleet | port | command | map  ×  active | empty   at 390×844
//   ship | port                          ×  active | empty   at 320×700
// The server root is the REPO ROOT (page: /tests/harness/look.html), NOT tests/harness: Tailwind
// v4's automatic source detection scans from the Vite root, and rooting at tests/harness generates
// utilities only for classes used in the harness files — every class used only in src/ goes
// missing and the real screens render flat (verified the expensive way). If port 5199 is already
// serving this page it is reused.
// No production access: dummy VITE_SUPABASE_* env set BEFORE the server starts (process env
// outranks .env.local) + the harness's own offline network stub answering every supabase path.

import { mkdir, stat } from 'node:fs/promises'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { createServer } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { chromium } from '@playwright/test'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const outDir = resolve(process.argv[2] ?? './look-shots')
const PORT = 5199
const BASE = `http://localhost:${PORT}`
const PAGE = `${BASE}/tests/harness/look.html`

// Dummy env: keeps the supabase client constructible at import. The harness's fetch stub answers
// every /rest/v1 + /auth/v1 request in-page, so this URL is never actually contacted.
process.env.VITE_SUPABASE_URL ??= 'http://127.0.0.1:9797'
process.env.VITE_SUPABASE_ANON_KEY ??= 'look-harness-dummy-key'

async function alreadyServing() {
  try {
    const r = await fetch(PAGE, { signal: AbortSignal.timeout(1500) })
    return r.ok
  } catch {
    return false
  }
}

// per-screen readiness marker: something that only exists once the real screen rendered.
const MARKERS = {
  ship: 'h1:has-text("Ships")',
  fleet: 'h1:has-text("Fleet")',
  port: 'h1:has-text("Port")',
  // MISSION-TAB: the ops destination renamed (was command/"Command").
  mission: 'h1:has-text("Mission")',
  map: '[data-testid="galaxy-map-screen"]',
}

const combos = []
for (const screen of ['ship', 'fleet', 'port', 'mission', 'map'])
  for (const state of ['active', 'empty']) combos.push({ screen, state, w: 390, h: 844 })
for (const screen of ['ship', 'port'])
  for (const state of ['active', 'empty']) combos.push({ screen, state, w: 320, h: 700 })

let server = null
let browser = null
let failures = 0
try {
  if (await alreadyServing()) {
    console.log(`[look-shots] reusing the server already on :${PORT}`)
  } else {
    server = await createServer({
      configFile: false,
      root: repoRoot, // repo root, NOT tests/harness — see the header (tailwind source detection)
      cacheDir: join(tmpdir(), 'osn-look-shots-vite'),
      plugins: [react(), tailwindcss()],
      logLevel: 'warn',
      server: { port: PORT, strictPort: true, fs: { allow: [repoRoot] } },
    })
    await server.listen().catch((e) => {
      console.error(`[look-shots] could not bind :${PORT} — is the stock uispec harness server running? Stop it and re-run. (${e.message})`)
      process.exit(1)
    })
    console.log(`[look-shots] harness server up on :${PORT} (tailwind pipeline active)`)
  }

  await mkdir(outDir, { recursive: true })
  browser = await chromium.launch()

  for (const { screen, state, w, h } of combos) {
    const page = await browser.newPage({ viewport: { width: w, height: h } })
    const pageErrors = []
    page.on('pageerror', (e) => pageErrors.push(String(e)))
    const url = `${PAGE}?screen=${screen}&state=${state}`
    const file = join(outDir, `${screen}-${state}-${w}w.png`)
    try {
      await page.goto(url, { waitUntil: 'networkidle' })
      await page.waitForSelector(MARKERS[screen], { timeout: 15000 })
      await page.evaluate(() => document.fonts.ready)
      await page.waitForTimeout(400) // one settle beat for the stub-fed panels
      await page.screenshot({ path: file })
      const { size } = await stat(file)
      const flag = size > 10_000 ? 'ok' : 'SUSPICIOUSLY SMALL'
      console.log(`[look-shots] ${file}  (${size} bytes, ${flag})`)
      if (size <= 10_000) failures++
      if (pageErrors.length) {
        failures++
        console.error(`[look-shots] PAGE ERRORS on ${url}:\n  ${pageErrors.join('\n  ')}`)
      }
    } catch (e) {
      failures++
      console.error(`[look-shots] FAILED ${url}: ${e.message ?? e}`)
      try {
        await page.screenshot({ path: file.replace(/\.png$/, '.failed.png') })
      } catch {
        /* nothing to save */
      }
    } finally {
      await page.close()
    }
  }

  // ACCOUNT (2026-08-03): one extra shot with the top-corner profile panel OPEN (identity,
  // credits, totals, sign out) — taken on the mission screen, both fixture states.
  for (const state of ['active', 'empty']) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } })
    const pageErrors = []
    page.on('pageerror', (e) => pageErrors.push(String(e)))
    const url = `${PAGE}?screen=mission&state=${state}`
    const file = join(outDir, `account-open-${state}-390w.png`)
    try {
      await page.goto(url, { waitUntil: 'networkidle' })
      await page.waitForSelector(MARKERS.mission, { timeout: 15000 })
      await page.click('[data-testid="account-open"]')
      await page.waitForSelector('[data-testid="account-panel"]', { timeout: 5000 })
      await page.evaluate(() => document.fonts.ready)
      await page.waitForTimeout(400)
      await page.screenshot({ path: file })
      const { size } = await stat(file)
      console.log(`[look-shots] ${file}  (${size} bytes, ${size > 10_000 ? 'ok' : 'SUSPICIOUSLY SMALL'})`)
      if (size <= 10_000) failures++
      if (pageErrors.length) {
        failures++
        console.error(`[look-shots] PAGE ERRORS on ${url} (account open):\n  ${pageErrors.join('\n  ')}`)
      }
    } catch (e) {
      failures++
      console.error(`[look-shots] FAILED account-open ${url}: ${e.message ?? e}`)
    } finally {
      await page.close()
    }
  }
} finally {
  if (browser) await browser.close()
  if (server) await server.close()
}

console.log(failures === 0 ? '[look-shots] all shots saved.' : `[look-shots] ${failures} problem(s) — see above.`)
process.exit(failures === 0 ? 0 : 1)
