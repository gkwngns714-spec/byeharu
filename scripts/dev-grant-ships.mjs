// DEV / TEST ONLY — grant ships to ONE player's base for manual M6 combat testing.
//
//   node scripts/dev-grant-ships.mjs --email test@example.com
//   node scripts/dev-grant-ships.mjs --user-id <uuid>
//
// SAFETY:
//  - Uses the SERVICE-ROLE key (server-side only). NEVER import this into frontend code.
//  - Refuses to run without an explicit --email or --user-id target.
//  - Only updates base_units for the ONE resolved user. No buildings / training /
//    production / migration — it just adds to the existing base_units rows.
//  - Uses Node's built-in fetch (Node 18+), so it needs no npm install.

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
const userIdArg = getArg('--user-id')

if (!email && !userIdArg) {
  console.error(`Refusing to run: no target user specified.
  node scripts/dev-grant-ships.mjs --email <email>
  node scripts/dev-grant-ships.mjs --user-id <uuid>`)
  process.exit(2)
}

const GRANT = { scout: 50, corvette: 25, frigate: 10 }
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }

async function jget(path) {
  const res = await fetch(BASE_URL + path, { headers: H })
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${await res.text()}`)
  return res.json()
}

async function resolveUserId() {
  if (userIdArg) return userIdArg
  for (let page = 1; page <= 20; page++) {
    const data = await jget(`/auth/v1/admin/users?page=${page}&per_page=200`)
    const users = data.users ?? []
    const u = users.find((x) => (x.email ?? '').toLowerCase() === email.toLowerCase())
    if (u) return u.id
    if (users.length < 200) break
  }
  throw new Error(`No user found with email ${email}`)
}

async function main() {
  const userId = await resolveUserId()
  const bases = await jget(`/rest/v1/bases?select=id&player_id=eq.${userId}`)
  if (!bases.length) throw new Error(`No base for user ${userId} (have they signed up / bootstrapped?)`)
  const baseId = bases[0].id
  console.log(`Granting ships to base ${baseId} (user ${userId}):`)

  for (const [unit, amt] of Object.entries(GRANT)) {
    const rows = await jget(`/rest/v1/base_units?select=id,quantity&base_id=eq.${baseId}&unit_type_id=eq.${unit}`)
    if (rows.length) {
      const newQty = rows[0].quantity + amt
      const res = await fetch(`${BASE_URL}/rest/v1/base_units?id=eq.${rows[0].id}`, {
        method: 'PATCH',
        headers: { ...H, Prefer: 'return=minimal' },
        body: JSON.stringify({ quantity: newQty, updated_at: new Date().toISOString() }),
      })
      if (!res.ok) throw new Error(`PATCH ${unit} → ${res.status} ${await res.text()}`)
      console.log(`  ${unit}: ${rows[0].quantity} → ${newQty} (+${amt})`)
    } else {
      const res = await fetch(`${BASE_URL}/rest/v1/base_units`, {
        method: 'POST',
        headers: { ...H, Prefer: 'return=minimal' },
        body: JSON.stringify({ base_id: baseId, unit_type_id: unit, quantity: amt }),
      })
      if (!res.ok) throw new Error(`POST ${unit} → ${res.status} ${await res.text()}`)
      console.log(`  ${unit}: 0 → ${amt} (new)`)
    }
  }
  console.log('Done. Reload the app to see the new ships.')
}

main().catch((e) => { console.error('ERROR:', e.message); process.exitCode = 1 })
