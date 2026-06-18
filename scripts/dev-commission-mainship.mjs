// DEV / TEST ONLY — commission ONE starter main ship for a single account (manual 10D test setup).
//
//   node scripts/dev-commission-mainship.mjs --email someone@example.com
//
// This is NOT the future player-facing "Commission ship" feature. It is a one-time controlled seed
// so an account can manually test the already-built + verified 10C/10D main-ship send/recall path.
//
// SAFETY:
//  - Uses the SERVICE-ROLE key (server-side only; never in frontend). Refuses without --email.
//  - Calls ONLY the existing, deployed helper public.ensure_main_ship_for_player(uuid), which is
//    idempotent (player_id is UNIQUE with on-conflict-do-nothing) — it cannot create duplicates.
//  - No migration, no schema change, no combat/destruction, no old-system writes. It commissions a
//    starter-frigate at status 'home' and reads it back. Nothing else.
//  - Built-in fetch (Node 18+), so no npm install needed.

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

const args = process.argv.slice(2)
const getArg = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined }
const email = getArg('--email')
if (!email) {
  console.error('Refusing to run: no target user.\n  node scripts/dev-commission-mainship.mjs --email <email>')
  process.exit(2)
}

const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }

async function jget(path) {
  const res = await fetch(BASE_URL + path, { headers: H })
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${await res.text()}`)
  return res.json()
}
async function rpc(name, body) {
  const res = await fetch(`${BASE_URL}/rest/v1/rpc/${name}`, { method: 'POST', headers: H, body: JSON.stringify(body) })
  if (!res.ok) throw new Error(`RPC ${name} → ${res.status} ${await res.text()}`)
  return res.json()
}
async function resolveUserId() {
  for (let page = 1; page <= 20; page++) {
    const data = await jget(`/auth/v1/admin/users?page=${page}&per_page=200`)
    const users = data.users ?? []
    const u = users.find((x) => (x.email ?? '').toLowerCase() === email.toLowerCase())
    if (u) return u.id
    if (users.length < 200) break
  }
  throw new Error(`No user found with email ${email}`)
}

async function shipsFor(userId) {
  return jget(`/rest/v1/main_ship_instances?select=main_ship_id,name,status&player_id=eq.${userId}`)
}

async function main() {
  const userId = await resolveUserId()
  console.log(`Target: ${email} (user ${userId})`)

  const before = await shipsFor(userId)
  console.log(`Existing main ships before: ${before.length}`)

  console.log('Calling public.ensure_main_ship_for_player (idempotent)…')
  await rpc('ensure_main_ship_for_player', { p_player: userId })

  const after = await shipsFor(userId)
  console.log(`Main ships after: ${after.length}`)
  for (const s of after) console.log(`  → ${s.main_ship_id} | ${s.name} | status=${s.status}`)

  const ok = after.length === 1 && after[0].status === 'home'
  console.log(ok ? '\n✅ Exactly one main ship, status = home.' : '\n❌ Unexpected state (want exactly 1 row, status home).')
  process.exitCode = ok ? 0 : 1
}

main().catch((e) => { console.error('ERROR:', e.message); process.exitCode = 1 })
