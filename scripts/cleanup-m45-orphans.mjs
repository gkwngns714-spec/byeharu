// ONE-TIME targeted cleanup of OLD M4.5-browser orphan runtime rows.
//   node scripts/cleanup-m45-orphans.mjs [--confirm]
//
// The old M4.5 browser test used emails 'm45browser.*@example.com' (no "test"), so the
// guarded cleanup_test_runtime can't remove its leftover. This deletes ONLY runtime rows
// whose owning player's email is PROVEN (via the auth admin API) to match 'm45browser.*'.
// Never TRUNCATE. Never touches bases/inventory/main_ship/config/world. Dry-run by default.
//
// Safety: a runtime row is deleted only if getUserById(player_id).email matches
// /^m45browser\./ — it cannot match m45testbrowser (new), m45test.* (verify), galaxytest*,
// or any real player.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

function loadEnv(p) {
  const e = {}
  try {
    for (const l of readFileSync(p, 'utf8').split('\n')) {
      const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/)
      if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '')
    }
  } catch {}
  return e
}
const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !serviceKey) { console.error('needs VITE_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const confirm = process.argv.includes('--confirm')
const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
const ORPHAN_RE = /^m45browser\./i

// runtime tables carrying player_id, child → parent order (fleet_units handled via fleet join)
const CHILD_FIRST = ['combat_ticks', 'combat_events', 'combat_reports', 'combat_encounters', 'location_presence', 'fleet_movements']
const PARENT_LAST = ['fleets', 'reward_grants', 'build_orders']
const ALL = [...CHILD_FIRST, ...PARENT_LAST]

console.log(`\nM4.5-browser orphan cleanup — ${confirm ? 'LIVE (deleting)' : 'DRY-RUN'} — ${url}\n`)

// 1. Collect distinct player_ids present in any runtime table.
const ids = new Set()
for (const t of ALL) {
  const { data, error } = await admin.from(t).select('player_id')
  if (error) { console.error(`read ${t} failed: ${error.message}`); process.exit(1) }
  for (const r of data ?? []) if (r.player_id) ids.add(r.player_id)
}

// 2. Prove ownership: keep only players whose email matches the OLD m45browser pattern.
const orphans = []
for (const id of ids) {
  const { data, error } = await admin.auth.admin.getUserById(id)
  const email = data?.user?.email ?? ''
  if (!error && ORPHAN_RE.test(email)) orphans.push({ id, email })
}

if (orphans.length === 0) {
  console.log('No m45browser orphan players found in runtime tables. Nothing to do.\n')
  process.exit(0)
}
const orphanIds = orphans.map((o) => o.id)
console.log('Proven M4.5-browser orphan players:')
orphans.forEach((o) => console.log(`  player_id=${o.id}  email=${o.email}`))

// 3. Show the rows that would be deleted (ownership-scoped).
console.log('\nRows owned by those players:')
const { data: fleetsRows } = await admin.from('fleets').select('id,status,player_id,origin_base_id').in('player_id', orphanIds)
;(fleetsRows ?? []).forEach((r) => console.log(`  fleets       id=${r.id} status=${r.status} player_id=${r.player_id} base=${r.origin_base_id}`))
const { data: boRows } = await admin.from('build_orders').select('id,status,player_id,base_id').in('player_id', orphanIds)
;(boRows ?? []).forEach((r) => console.log(`  build_orders id=${r.id} status=${r.status} player_id=${r.player_id} base=${r.base_id}`))
const fleetIds = (fleetsRows ?? []).map((f) => f.id)
for (const t of CHILD_FIRST.concat('reward_grants')) {
  const { data } = await admin.from(t).select('id').in('player_id', orphanIds)
  if ((data ?? []).length) console.log(`  ${t}: ${data.length} rows`)
}
if (fleetIds.length) {
  const { data: fu } = await admin.from('fleet_units').select('fleet_id').in('fleet_id', fleetIds)
  if ((fu ?? []).length) console.log(`  fleet_units: ${fu.length} rows (via fleet)`)
}

// 4. Delete, child-first (only if confirmed).
if (!confirm) {
  console.log('\nDRY-RUN — nothing deleted. Re-run with --confirm to delete the rows above.\n')
  process.exit(0)
}
let total = 0
const del = async (table, col, vals) => {
  if (!vals.length) return
  const { data, error } = await admin.from(table).delete().in(col, vals).select('id')
  if (error) { console.error(`delete ${table} failed: ${error.message}`); process.exit(1) }
  const n = (data ?? []).length
  total += n
  if (n) console.log(`  deleted ${n} from ${table}`)
}
for (const t of CHILD_FIRST) await del(t, 'player_id', orphanIds)
if (fleetIds.length) await del('fleet_units', 'fleet_id', fleetIds)
for (const t of PARENT_LAST) await del(t, 'player_id', orphanIds)
console.log(`\nDeleted ${total} orphan runtime rows for ${orphans.length} m45browser player(s).\n`)
