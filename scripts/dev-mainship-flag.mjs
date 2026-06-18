// DEV / TEST ONLY — toggle the single feature flag game_config.mainship_send_enabled.
//
//   node scripts/dev-mainship-flag.mjs --enabled true
//   node scripts/dev-mainship-flag.mjs --enabled false
//
// Manual 10D validation helper ONLY. It changes EXACTLY ONE key (mainship_send_enabled) via the
// existing owned writer public.set_game_config. It does NOT touch travel_scale, min_travel_seconds,
// ships, fleets, combat, old expedition data, migrations, or UI. It reports the final flag value.
//
// SAFETY: service-role key (server-side only); refuses unless --enabled is exactly true|false.
// Built-in fetch (Node 18+); no npm install.

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

const FLAG_KEY = 'mainship_send_enabled' // the ONLY key this tool may write

const env = { ...loadEnv('.env.local'), ...process.env }
const BASE_URL = env.VITE_SUPABASE_URL
const KEY = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!BASE_URL || !KEY) {
  console.error('Missing VITE_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY (.env.local or env).')
  process.exit(2)
}

const args = process.argv.slice(2)
const getArg = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined }
const raw = (getArg('--enabled') ?? '').toLowerCase()
if (raw !== 'true' && raw !== 'false') {
  console.error('Refusing to run: --enabled must be exactly "true" or "false".')
  process.exit(2)
}
const target = raw === 'true'

const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }

async function jget(path) {
  const res = await fetch(BASE_URL + path, { headers: H })
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${await res.text()}`)
  return res.json()
}
async function rpc(name, body) {
  const res = await fetch(`${BASE_URL}/rest/v1/rpc/${name}`, { method: 'POST', headers: H, body: JSON.stringify(body) })
  if (!res.ok) throw new Error(`RPC ${name} → ${res.status} ${await res.text()}`)
}

async function main() {
  const before = await jget(`/rest/v1/game_config?select=key,value&key=eq.${FLAG_KEY}`)
  console.log(`Before: ${FLAG_KEY} = ${before[0]?.value}`)

  console.log(`Setting ${FLAG_KEY} = ${target} (via set_game_config)…`)
  await rpc('set_game_config', { p_key: FLAG_KEY, p_value: target })

  const after = await jget(`/rest/v1/game_config?select=key,value&key=eq.${FLAG_KEY}`)
  const val = after[0]?.value
  console.log(`After:  ${FLAG_KEY} = ${val}`)

  const ok = val === target
  console.log(ok ? `\n✅ Flag is now ${val}.` : `\n❌ Flag did not change as expected (wanted ${target}).`)
  process.exitCode = ok ? 0 : 1
}

main().catch((e) => { console.error('ERROR:', e.message); process.exitCode = 1 })
