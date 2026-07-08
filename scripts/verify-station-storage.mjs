// STATION-STORAGE verify — server-side proof that the per-port storage foundation (migrations 0157/0158)
// is correctly applied and the core seam works. Read-mostly; the one mutating check (store creation) reveals
// the seed ports, creates a second store for an existing player, then CLEANS UP (deletes the created store and
// re-hides the ports) unless --keep is passed.
//
//   node scripts/verify-station-storage.mjs          # full check + cleanup
//   node scripts/verify-station-storage.mjs --keep   # leave ports revealed (for the manual dock A/B test)
//
// SAFETY: service-role key (server-side only). It never touches a player's EXISTING starter store, combat,
// movement, migrations, or UI. Built-in fetch (Node 18+); no npm install. Mirrors scripts/dev-mainship-flag.mjs.

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
const BASE_URL = env.VITE_SUPABASE_URL
const KEY = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!BASE_URL || !KEY) {
  console.error('Missing VITE_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY (.env.local or env).')
  process.exit(2)
}
const KEEP = process.argv.slice(2).includes('--keep')

// The 3 WORLD-HUB-1B seed ports (fixed literal UUIDs from migration 0066).
const STARTER_PORT = 'b1a00001-0066-4a00-8a00-000000000001' // Haven Reach
const SECOND_PORT  = 'b1a00002-0066-4a00-8a00-000000000002' // Slagworks Anchorage
const SEED_PORTS = [STARTER_PORT, SECOND_PORT, 'b1a00003-0066-4a00-8a00-000000000003']

const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }
async function jget(path) {
  const res = await fetch(BASE_URL + path, { headers: H })
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${await res.text()}`)
  return res.json()
}
async function rpc(name, body) {
  const res = await fetch(`${BASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: H, body: JSON.stringify(body ?? {}),
  })
  if (!res.ok) throw new Error(`RPC ${name} → ${res.status} ${await res.text()}`)
  const t = await res.text()
  return t ? JSON.parse(t) : null
}
async function patch(path, body) {
  const res = await fetch(BASE_URL + path, { method: 'PATCH', headers: { ...H, Prefer: 'return=minimal' }, body: JSON.stringify(body) })
  if (!res.ok) throw new Error(`PATCH ${path} → ${res.status} ${await res.text()}`)
}
async function del(path) {
  const res = await fetch(BASE_URL + path, { method: 'DELETE', headers: { ...H, Prefer: 'return=minimal' } })
  if (!res.ok) throw new Error(`DELETE ${path} → ${res.status} ${await res.text()}`)
}

let pass = 0, fail = 0
const check = (name, ok, detail = '') => {
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`)
  ok ? pass++ : fail++
}

async function main() {
  // 1) Flag present + false by default.
  const flag = await jget('/rest/v1/game_config?select=key,value&key=eq.station_storage_enabled')
  check('flag station_storage_enabled exists', flag.length === 1, flag[0]?.value)
  check('flag defaults to false', flag[0]?.value === 'false')

  // 2) bases.location_id column exists (selecting it errors if the column is missing).
  let baseSample
  try {
    baseSample = await jget('/rest/v1/bases?select=id,player_id,location_id&limit=5')
    check('bases.location_id column present', true)
  } catch (e) {
    check('bases.location_id column present', false, e.message)
    return
  }

  // 3) Existing Home Bases backfilled onto the starter port.
  const nullLoc = await jget('/rest/v1/bases?select=id&location_id=is.null')
  check('all existing bases have a location_id (backfill ran)', nullLoc.length === 0, `${nullLoc.length} still null`)
  const onStarter = await jget(`/rest/v1/bases?select=id&location_id=eq.${STARTER_PORT}`)
  check('at least one base sits on the starter port', onStarter.length >= 1, `${onStarter.length} store(s)`)

  // 4) Read RPC deployed + well-shaped (service-role has no auth.uid → 'no_main_ship', proving it runs).
  const dark = await rpc('get_my_docked_store')
  check('get_my_docked_store deployed + returns an envelope', dark && typeof dark === 'object' && 'docked' in dark, JSON.stringify(dark))

  // 5) Core seam: get_or_create_store — reveal ports, prove idempotency + a SECOND store, then clean up.
  const player = baseSample[0]?.player_id
  if (!player) { check('a player exists to test the store seam', false); return }
  let createdSecond = null
  try {
    await patch(`/rest/v1/locations?id=in.(${SEED_PORTS.join(',')})`, { status: 'active' })
    check('seed ports revealed (status active)', true)

    const eligible = await rpc('is_home_port_eligible', { p_location_id: STARTER_PORT })
    check('starter port is dockable once revealed', eligible === true)

    const s1 = await rpc('get_or_create_store', { p_player: player, p_location: STARTER_PORT })
    const s1again = await rpc('get_or_create_store', { p_player: player, p_location: STARTER_PORT })
    check('get_or_create_store is idempotent for a port', s1 && s1 === s1again, `${s1}`)
    check('idempotent store equals the backfilled starter base', onStarter.some((b) => b.id === s1))

    const s2 = await rpc('get_or_create_store', { p_player: player, p_location: SECOND_PORT })
    createdSecond = s2
    check('a DIFFERENT port yields a DIFFERENT store (multi-store per player)', s2 && s2 !== s1, `${s2}`)
    const s2row = await jget(`/rest/v1/bases?select=id,location_id&id=eq.${s2}`)
    check('second store is anchored to the second port', s2row[0]?.location_id === SECOND_PORT)
  } finally {
    // Cleanup: remove the store we created, and (unless --keep) re-hide the ports to restore the dark state.
    if (createdSecond) {
      try { await del(`/rest/v1/bases?id=eq.${createdSecond}`) ; console.log('   ↳ cleaned up test store') } catch (e) { console.log('   ↳ store cleanup failed:', e.message) }
    }
    if (!KEEP) {
      try { await patch(`/rest/v1/locations?id=in.(${SEED_PORTS.join(',')})`, { status: 'hidden' }); console.log('   ↳ re-hid seed ports (dark restored)') } catch (e) { console.log('   ↳ port re-hide failed:', e.message) }
    } else {
      console.log('   ↳ --keep: seed ports left REVEALED for manual testing')
    }
  }

  console.log(`\n${fail === 0 ? '✅ PASS' : '❌ FAIL'} — ${pass} passed, ${fail} failed`)
  process.exitCode = fail === 0 ? 0 : 1
}

main().catch((e) => { console.error('ERROR:', e.message); process.exitCode = 1 })
