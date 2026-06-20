// OSN-2b closure diagnostic — READ-ONLY live distribution of main_ship_instances.spatial_state.
//   node scripts/osn2-spatial-distribution.mjs
//
// main_ship_instances is owner-read (RLS player_id = auth.uid()), so the anon/publishable key
// cannot see other players' rows. This uses the service-role key (CI secret) to read the FULL
// distribution. It performs NO writes — a single SELECT of spatial_state (+ status for context).
//
// Closure expectation (OSN-2a deployed 0054 with NO back-fill; no writer sets a non-null value yet):
//   NULL                              → all existing/legacy ships
//   in_space                          → 0 (until OSN-3 produces it)
//   home / at_location / in_transit   → 0 (else a live ship would render as null/hidden — investigate)
//   destroyed                         → 0 today (the destruction path sets status='destroyed' only,
//                                        not spatial_state) — any nonzero is reported, not failed.
// Exits non-zero ONLY if a home/at_location/in_transit row exists (a real hide-the-ship risk).

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

function loadEnv(p) {
  const e = {}
  try { for (const l of readFileSync(p, 'utf8').split('\n')) { const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/); if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '') } } catch {}
  return e
}
const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const key = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !key) { console.error('needs VITE_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })

const { data, error } = await admin.from('main_ship_instances').select('spatial_state, status')
if (error) { console.error('query failed:', error.message); process.exit(1) }

const dist = {}
for (const r of data) {
  const k = r.spatial_state === null ? 'NULL' : String(r.spatial_state)
  dist[k] = (dist[k] || 0) + 1
}
console.log(`\nmain_ship_instances total rows: ${data.length}`)
console.log('spatial_state distribution:', JSON.stringify(dist, null, 0))

const hideRisk = data.filter((r) => ['home', 'at_location', 'in_transit'].includes(r.spatial_state))
const inSpace = data.filter((r) => r.spatial_state === 'in_space')
const ssDestroyed = data.filter((r) => r.spatial_state === 'destroyed')
console.log(`in_space rows: ${inSpace.length} (expected 0 pre-OSN-3)`)
console.log(`spatial_state='destroyed' rows: ${ssDestroyed.length} (expected 0; status-based destroyed is separate)`)
console.log(`home/at_location/in_transit rows: ${hideRisk.length} (MUST be 0 — else a live ship would render hidden)`)

if (hideRisk.length > 0) {
  console.error('\nFAIL: live rows use home/at_location/in_transit — OSN-2b would hide these ships. Decide rendering before closing.')
  process.exitCode = 1
} else {
  console.log('\nOK: no spatial_state value is hidden by the OSN-2b resolver.')
  process.exitCode = 0
}
