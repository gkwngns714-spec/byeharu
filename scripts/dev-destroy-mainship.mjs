// DEV / TEST ONLY — put ONE account's main ship into the destroyed/needs-repair state for the
// Phase 10F UI smoke test.
//
//   node scripts/dev-destroy-mainship.mjs --email someone@example.com
//
// It ONLY resolves the user by email and calls the existing canonical helper
// public.dev_set_main_ship_destroyed(p_player) — it does NOT duplicate any destroy/cleanup logic.
// The ship row is NOT deleted; status='destroyed' means disabled/needs-repair, recoverable via the
// in-app "Repair main ship" button (repair_main_ship).
//
// SAFETY: SERVICE-ROLE key (server-side only). Refuses without --email. Not a player path; the RPC
// is service_role-only. Built-in fetch (Node 18+); no npm install.

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
  console.error('Refusing to run: no target user.\n  node scripts/dev-destroy-mainship.mjs --email <email>')
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
  // Collect ALL matches across pages and refuse if 0 or >1 — never act on an ambiguous target.
  const matches = []
  for (let page = 1; page <= 20; page++) {
    const data = await jget(`/auth/v1/admin/users?page=${page}&per_page=200`)
    const users = data.users ?? []
    for (const x of users) {
      if ((x.email ?? '').toLowerCase() === email.toLowerCase()) matches.push(x.id)
    }
    if (users.length < 200) break
  }
  if (matches.length === 0) throw new Error(`No user found with email ${email} — doing nothing.`)
  if (matches.length > 1) throw new Error(`Refusing: ${matches.length} users match ${email} (ambiguous) — doing nothing.`)
  return matches[0]
}

async function main() {
  const userId = await resolveUserId()
  console.log(`Target: ${email} (user ${userId})`)

  console.log('Calling public.dev_set_main_ship_destroyed (canonical helper)…')
  const result = await rpc('dev_set_main_ship_destroyed', { p_player: userId })
  console.log(`  → ${JSON.stringify(result)}`)

  const after = await jget(`/rest/v1/main_ship_instances?select=main_ship_id,status,hp,max_hp&player_id=eq.${userId}`)
  const s = after[0]
  for (const row of after) console.log(`  ship: ${row.main_ship_id} | status=${row.status} | hp=${row.hp}/${row.max_hp}`)

  const ok = s && s.status === 'destroyed' && s.hp === 0
  console.log(ok ? '\n✅ Main ship is disabled (status=destroyed, hp=0). Repair it in-app to recover.' : '\n❌ Unexpected state (want status=destroyed, hp=0).')
  process.exitCode = ok ? 0 : 1
}

main().catch((e) => { console.error('ERROR:', e.message); process.exitCode = 1 })
