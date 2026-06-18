// READ-ONLY diagnostic: who owns the current runtime rows? Prints each distinct player_id
// in the runtime tables, that user's email (via auth admin API), and how many rows they own.
// Deletes NOTHING. Used to tell test leftovers from real player data.
//   node scripts/whoami-runtime.mjs

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

function loadEnv(p) {
  const e = {}
  try { for (const l of readFileSync(p, 'utf8').split('\n')) { const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/); if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '') } } catch {}
  return e
}
const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !serviceKey) { console.error('needs VITE_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }
const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

const TABLES = ['combat_ticks', 'combat_events', 'combat_reports', 'combat_encounters', 'location_presence', 'fleet_movements', 'fleets', 'reward_grants', 'build_orders']
const counts = {} // playerId -> { table: n }
for (const t of TABLES) {
  const { data, error } = await admin.from(t).select('player_id')
  if (error) { console.error(`read ${t}: ${error.message}`); continue }
  for (const r of data ?? []) {
    if (!r.player_id) continue
    counts[r.player_id] ??= {}
    counts[r.player_id][t] = (counts[r.player_id][t] ?? 0) + 1
  }
}
const ids = Object.keys(counts)
console.log(`\nRuntime row owners — ${ids.length} distinct player(s) — ${url}\n`)
for (const id of ids) {
  const { data } = await admin.auth.admin.getUserById(id)
  const email = data?.user?.email ?? '(unknown / deleted user)'
  const isTest = /test/i.test(email)
  console.log(`  ${isTest ? 'TEST ' : 'REAL '} ${email}  player_id=${id}`)
  console.log(`        ${JSON.stringify(counts[id])}`)
}
console.log('')
