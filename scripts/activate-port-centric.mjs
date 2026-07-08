// PORT-CENTRIC ACTIVATION — the direct, guarded live pivot (reveal the 3 starter ports + flip the two flags).
//
//   node scripts/activate-port-centric.mjs --confirm
//
// Does exactly what the gated CI runbook does, via the service-role RPCs (same pattern as
// scripts/dev-mainship-flag.mjs): reveal_starter_ports() (ONE-WAY, self-guarded) + set_game_config for
// mainship_space_movement_enabled and station_storage_enabled. Refuses to run without --confirm.
//
// PRECONDITIONS asserted before any write: the 3 canonical ports are hidden (or already all active =
// idempotent skip); mainship_send_enabled=true (the first-trip bridge); mainship_space_movement_enabled=false
// (refuse to re-enable). POSTCONDITIONS verified after: both flags true, 3 ports active, map shows 3.
//
// REVERSIBILITY: the two flags flip back to false to dark the surfaces again; the port reveal is ONE-WAY (by
// design — reveal_starter_ports has no unreveal). Built-in fetch (Node 18+); no npm install.

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
const BASE = env.VITE_SUPABASE_URL
const KEY = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!BASE || !KEY) { console.error('Missing VITE_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY (.env.local).'); process.exit(2) }
if (!process.argv.slice(2).includes('--confirm')) {
  console.error('Refusing to run: this is a LIVE, partly ONE-WAY pivot (port reveal). Re-run with --confirm.')
  process.exit(2)
}

const PORTS = ['b1a00001-0066-4a00-8a00-000000000001', 'b1a00002-0066-4a00-8a00-000000000002', 'b1a00003-0066-4a00-8a00-000000000003']
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }
async function jget(path) { const r = await fetch(BASE + path, { headers: H }); if (!r.ok) throw new Error(`GET ${path} -> ${r.status} ${await r.text()}`); return r.json() }
async function rpc(name, body) { const r = await fetch(`${BASE}/rest/v1/rpc/${name}`, { method: 'POST', headers: H, body: JSON.stringify(body ?? {}) }); if (!r.ok) throw new Error(`RPC ${name} -> ${r.status} ${await r.text()}`); const t = await r.text(); return t ? JSON.parse(t) : null }
const flagVal = (rows, key) => rows.find((r) => r.key === key)?.value
const idList = PORTS.join(',')

async function main() {
  console.log('== PORT-CENTRIC ACTIVATION ==\n')

  // ── Preconditions ──────────────────────────────────────────────────────────────────────────────
  const flags = await jget(`/rest/v1/game_config?select=key,value&key=in.(mainship_send_enabled,mainship_space_movement_enabled,station_storage_enabled)`)
  const send = flagVal(flags, 'mainship_send_enabled')
  const space = flagVal(flags, 'mainship_space_movement_enabled')
  const store = flagVal(flags, 'station_storage_enabled')
  const ports = await jget(`/rest/v1/locations?select=id,name,status&id=in.(${idList})`)
  const hidden = ports.filter((p) => p.status === 'hidden').length
  const active = ports.filter((p) => p.status === 'active').length
  console.log(`preflight: send=${send} space=${space} store=${store} | ports hidden=${hidden} active=${active}`)

  if (ports.length !== 3) throw new Error(`expected 3 canonical ports, found ${ports.length} — abort`)
  if (send !== true) throw new Error(`mainship_send_enabled must be true (the first-trip bridge); got ${send} — abort`)
  if (space === true) throw new Error('mainship_space_movement_enabled is already true — refusing to re-enable')

  // ── 1. Reveal ports (one-way; skip if already revealed) ──────────────────────────────────────────
  if (hidden === 3) {
    console.log('\n[1/3] revealing 3 starter ports (reveal_starter_ports)…')
    await rpc('reveal_starter_ports')
    const after = await jget(`/rest/v1/locations?select=id,status&id=in.(${idList})`)
    const na = after.filter((p) => p.status === 'active').length
    if (na !== 3) throw new Error(`reveal did not activate 3 ports (active=${na}) — STOP, verify manually`)
    console.log('      -> 3 ports active ✓')
  } else if (active === 3) {
    console.log('\n[1/3] ports already revealed (3 active) — skipping reveal.')
  } else {
    throw new Error(`mixed port states (hidden=${hidden}, active=${active}) — abort, resolve manually`)
  }

  // ── 2. Enable OSN port-to-port movement ──────────────────────────────────────────────────────────
  console.log('\n[2/3] set mainship_space_movement_enabled = true…')
  await rpc('set_game_config', { p_key: 'mainship_space_movement_enabled', p_value: true })

  // ── 3. Enable station storage (the docked-port hangar) ───────────────────────────────────────────
  console.log('[3/3] set station_storage_enabled = true…')
  await rpc('set_game_config', { p_key: 'station_storage_enabled', p_value: true })

  // ── Postconditions ───────────────────────────────────────────────────────────────────────────────
  const f2 = await jget(`/rest/v1/game_config?select=key,value&key=in.(mainship_space_movement_enabled,station_storage_enabled)`)
  const p2 = await jget(`/rest/v1/locations?select=id,status&id=in.(${idList})`)
  const okSpace = flagVal(f2, 'mainship_space_movement_enabled') === true
  const okStore = flagVal(f2, 'station_storage_enabled') === true
  const okPorts = p2.filter((p) => p.status === 'active').length === 3
  let mapN = -1
  try { const wm = await rpc('get_world_map'); mapN = JSON.stringify(wm).match(/b1a0000[123]-0066/g)?.length ?? 0 } catch {}

  console.log('\n== POSTCONDITIONS ==')
  console.log(`${okSpace ? '✅' : '❌'} mainship_space_movement_enabled = true`)
  console.log(`${okStore ? '✅' : '❌'} station_storage_enabled = true`)
  console.log(`${okPorts ? '✅' : '❌'} 3 starter ports active`)
  console.log(`${mapN >= 3 ? '✅' : 'ℹ️ '} ports visible in get_world_map (${mapN})`)

  const pass = okSpace && okStore && okPorts
  console.log(`\n${pass ? '✅ ACTIVATION COMPLETE' : '❌ ACTIVATION INCOMPLETE — review above'}`)
  if (pass) {
    console.log('\nNext: your ship is still at "home" — travel it to a revealed port (Haven/Slagworks/Driftmarch)')
    console.log('via the Map to dock; the Port tab + Hangar then light up. Frontend home-base cleanup is Stage 3.')
    console.log('To roll back the surfaces (reveal stays): set both flags false via scripts/dev-mainship-flag.mjs pattern.')
  }
  process.exitCode = pass ? 0 : 1
}

main().catch((e) => { console.error('\nERROR:', e.message); process.exitCode = 1 })
