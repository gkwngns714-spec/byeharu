#!/usr/bin/env node
// Byeharu Project Map — live production overlay.
//
// The repo scan knows what EXISTS. This knows what is actually LIVE.
// Reads two sources of production truth:
//   1. game_config  — via the anon key (game_config_public_read makes it readable)
//   2. Deploy Supabase migrations — via `gh run list`, to see the deploy frontier
//
// Everything it cannot prove is reported as unknown rather than assumed.
//
//   node tools/projectmap/scan/live.mjs [--env <path to .env.local>]
//   -> tools/projectmap/public/live.json

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = join(HERE, '..', '..', '..')
const OUT = join(HERE, '..', 'public', 'live.json')

const argEnv = process.argv.indexOf('--env')
const ENV_PATH = argEnv > -1 ? process.argv[argEnv + 1] : join(REPO, '.env.local')

function loadEnv(p) {
  const e = {}
  try {
    for (const l of readFileSync(p, 'utf8').split('\n')) {
      const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/)
      if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '')
    }
  } catch { /* no env file — handled below */ }
  return e
}

const env = { ...loadEnv(ENV_PATH), ...process.env }
const url = env.VITE_SUPABASE_URL
const anon = env.VITE_SUPABASE_ANON_KEY

const live = {
  fetchedAt: new Date().toISOString(),
  sources: {},
  flags: {},        // name -> true | false   (only what prod actually returned)
  configRows: 0,
  deploy: { state: 'unknown', runs: [] },
}

// ── 1. production flags ───────────────────────────────────────────────────────
if (!url || !anon) {
  live.sources.gameConfig = {
    ok: false,
    reason: `no VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY (looked in ${ENV_PATH})`,
  }
  console.error(`! game_config: skipped — no credentials at ${ENV_PATH}`)
} else {
  try {
    const res = await fetch(`${url}/rest/v1/game_config?select=key,value`, {
      headers: { apikey: anon, authorization: `Bearer ${anon}` },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const rows = await res.json()
    live.configRows = rows.length
    for (const r of rows) {
      if (!/_enabled$/.test(r.key)) continue
      // game_config.value is jsonb — true, "true", or "TRUE" have all appeared.
      const v = typeof r.value === 'boolean' ? r.value : String(r.value).replace(/"/g, '').toLowerCase() === 'true'
      live.flags[r.key] = v
    }
    live.sources.gameConfig = { ok: true, host: new URL(url).host, rows: rows.length }
    console.log(`game_config: ${rows.length} rows, ${Object.keys(live.flags).length} flags`)
  } catch (err) {
    live.sources.gameConfig = { ok: false, reason: String(err.message ?? err) }
    console.error(`! game_config: ${err.message ?? err}`)
  }
}

// ── 2. migration deploy frontier ──────────────────────────────────────────────
// Migrations do NOT auto-apply: the Deploy workflow waits on a production
// environment approval. A pending/failed run means main is ahead of prod.
try {
  const raw = execFileSync('gh', [
    'run', 'list', '--limit', '60',
    '--json', 'databaseId,name,status,conclusion,headBranch,createdAt',
  ], { cwd: REPO, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
  const runs = JSON.parse(raw)
    .filter((r) => /deploy supabase/i.test(r.name))
    .map((r) => ({
      id: r.databaseId, status: r.status, conclusion: r.conclusion,
      branch: r.headBranch, createdAt: r.createdAt,
    }))
  live.deploy.runs = runs.slice(0, 10)
  const newest = runs[0]
  if (!newest) live.deploy.state = 'no-runs'
  else if (newest.conclusion === 'success') live.deploy.state = 'success'
  else if (newest.status === 'pending' || newest.status === 'waiting' || newest.status === 'queued') live.deploy.state = 'awaiting-approval'
  else if (newest.conclusion === 'cancelled') live.deploy.state = 'cancelled'
  else if (newest.conclusion === 'failure') live.deploy.state = 'failed'
  else live.deploy.state = newest.status ?? 'unknown'
  live.sources.deploy = { ok: true, newest }
  console.log(`deploy: newest run ${newest?.id ?? '—'} -> ${live.deploy.state}`)
} catch (err) {
  live.sources.deploy = { ok: false, reason: 'gh CLI unavailable or not authenticated' }
  console.error('! deploy runs: gh unavailable — deploy state stays unknown')
}

mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, JSON.stringify(live, null, 1))

const on = Object.entries(live.flags).filter(([, v]) => v).map(([k]) => k)
console.log(`\nLIVE flags (${on.length}):`)
for (const f of on.sort()) console.log(`  + ${f}`)
console.log(`\n-> ${OUT}`)
