// DEV / ADMIN CLEANUP ONLY — remove throwaway test users (and ALL their data)
// created by the verification scripts. NEVER import this into frontend code.
//
//   node scripts/dev-clean-test-users.mjs --pattern "m%test%@example.com" --dry-run
//   node scripts/dev-clean-test-users.mjs --pattern "m%test%@example.com" --confirm
//
// SAFETY:
//  - DRY-RUN BY DEFAULT — deletes nothing unless --confirm is passed.
//  - --pattern is REQUIRED and MUST contain "test" (guards against broad/real-user
//    deletion). Pattern is SQL-LIKE (% = any, _ = one char).
//  - PROTECTED emails are never deleted, even if they match.
//  - Uses the SERVICE-ROLE key (server-side only). Node 18+ built-in fetch — no npm.
//
// HOW DELETION WORKS (verified against the schema): deleting one auth.users row
// cascades via FK `on delete cascade` to profiles, bases (→ base_units,
// base_resources), fleets (→ fleet_units, fleet_movements), location_presence,
// combat_encounters (→ combat_ticks, combat_events, combat_units, combat_reports),
// reward_grants. So this script deletes ONLY the auth user; the DB removes the rest.

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
const pattern = getArg('--pattern')
const confirm = args.includes('--confirm')

// Hard-protected emails — never deleted even if a pattern matches them.
const PROTECTED = new Set(['gkwngns714@gmail.com'])

if (!pattern) {
  console.error(`Refusing to run: --pattern is required.
  node scripts/dev-clean-test-users.mjs --pattern "m%test%@example.com" --dry-run
  node scripts/dev-clean-test-users.mjs --pattern "m%test%@example.com" --confirm`)
  process.exit(2)
}
if (!/test/i.test(pattern)) {
  console.error(`Refusing to run: --pattern must contain "test" (safety guard). Got: ${pattern}`)
  process.exit(2)
}

// SQL LIKE → RegExp (% → any, _ → one), regex-escaped, full-match, case-insensitive.
function likeToRegex(like) {
  const esc = like.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp('^' + esc.replace(/%/g, '.*').replace(/_/g, '.') + '$', 'i')
}
const re = likeToRegex(pattern)

const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }
async function jget(path) {
  const r = await fetch(BASE_URL + path, { headers: H })
  if (!r.ok) throw new Error(`GET ${path} → ${r.status} ${await r.text()}`)
  return r.json()
}
const countFor = async (table, userId) =>
  (await jget(`/rest/v1/${table}?select=id&player_id=eq.${userId}`)).length

async function listAllUsers() {
  const all = []
  for (let page = 1; page <= 50; page++) {
    const data = await jget(`/auth/v1/admin/users?page=${page}&per_page=200`)
    const users = data.users ?? []
    all.push(...users)
    if (users.length < 200) break
  }
  return all
}

async function main() {
  console.log(`\ndev-clean-test-users · mode: ${confirm ? 'DELETE (--confirm)' : 'DRY-RUN'}`)
  console.log(`  pattern: ${pattern}   regex: ${re}\n`)

  const users = await listAllUsers()
  const matched = users.filter((u) => u.email && re.test(u.email) && !PROTECTED.has(u.email.toLowerCase()))
  const protectedHits = users.filter((u) => u.email && re.test(u.email) && PROTECTED.has(u.email.toLowerCase()))
  if (protectedHits.length) console.log(`(skipping ${protectedHits.length} PROTECTED email(s) that matched the pattern)\n`)

  if (!matched.length) {
    console.log('No matching test users found. Nothing to do.')
    return
  }

  let tB = 0, tF = 0, tP = 0, tE = 0, tR = 0
  console.log(`Matched ${matched.length} test user(s):`)
  for (const u of matched) {
    const [b, f, p, e, r] = await Promise.all([
      countFor('bases', u.id),
      countFor('fleets', u.id),
      countFor('location_presence', u.id),
      countFor('combat_encounters', u.id),
      countFor('combat_reports', u.id),
    ])
    tB += b; tF += f; tP += p; tE += e; tR += r
    console.log(`  ${u.email}  →  bases ${b}, fleets ${f}, presences ${p}, encounters ${e}, reports ${r}`)
  }
  console.log(`\nTotals to be removed: users ${matched.length} · bases ${tB} · fleets ${tF} · presences ${tP} · encounters ${tE} · reports ${tR}`)
  console.log('  (+ their base_units/base_resources, fleet_units, fleet_movements, combat_ticks/events/units, reward_grants via cascade)')

  if (!confirm) {
    console.log('\nDRY-RUN — nothing was deleted. Re-run with --confirm to delete.')
    return
  }

  console.log(`\nDeleting ${matched.length} user(s)…`)
  let ok = 0, fail = 0
  for (const u of matched) {
    const res = await fetch(`${BASE_URL}/auth/v1/admin/users/${u.id}`, { method: 'DELETE', headers: H })
    if (res.ok) { ok++; console.log(`  ✓ ${u.email}`) }
    else { fail++; console.log(`  ✗ ${u.email} → ${res.status} ${await res.text()}`) }
  }
  console.log(`\nDone. Deleted ${ok}, failed ${fail}. World-state active_fleets self-corrects on the next 60s tick.`)
}

main().catch((e) => { console.error('ERROR:', e.message); process.exitCode = 1 })
