// Phase 10B verification — read-only main-ship expedition preview.
//   node scripts/verify-mainship-preview.mjs
//
// Proves get_my_expedition_preview is client-callable, auth.uid()-scoped, reuses
// calculate_expedition_stats, enforces support_capacity (as a preview warning, not a crash),
// shows a hull teaser when no ship exists, and WRITES NOTHING (a no-ship user still has none
// after previewing). calculate_expedition_stats stays server-only.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { teardownVerifier } from './lib/verifier-teardown.mjs'

function loadEnv(p) {
  const e = {}
  try { for (const l of readFileSync(p, 'utf8').split('\n')) { const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/); if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '') } } catch {}
  return e
}
const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const anonKey = env.VITE_SUPABASE_ANON_KEY
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !anonKey) { console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY'); process.exit(2) }
if (!serviceKey) { console.error('needs SUPABASE_SERVICE_ROLE_KEY (to commission a test ship)'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `mspreviewtest.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  const userId = su.user.id
  createdUserIds.push(userId)   // track immediately after creation for finally cleanup
  return { client: c, userId }
}
const preview = (client, loadout, activity = 'pirate_hunt') => client.rpc('get_my_expedition_preview', { p_loadout: loadout, p_activity_type: activity })
const createdUserIds = []

async function main() {
  console.log(`\nPhase 10B (main-ship preview) verification against ${url}\n`)

  // ── user WITH a commissioned ship ───────────────────────────────────────────
  const u1 = await newUser('a')
  await admin.rpc('ensure_main_ship_for_player', { p_player: u1.userId })
  ok('set up player + commissioned main ship (via service-role)')

  // Since migration 0170 the hull carries base combat stats (starter_frigate {attack 15}) folded
  // by the ONE adapter — a bare ship previews its hull seed (read live, never hardcoded), not 0.
  const hull = (await admin.from('main_ship_hull_types').select('base_stats_json').eq('hull_type_id', 'starter_frigate').single()).data
  const hullAtk = Number(hull?.base_stats_json?.attack ?? 0)
  const p0 = (await preview(u1.client, [])).data
  p0 && p0.has_ship === true && p0.valid === true && p0.stats?.combat_power === hullAtk
    ? ok(`1. empty loadout → has_ship, valid, base stats (combat ${hullAtk} = the hull seed)`) : bad('1. base preview', JSON.stringify(p0))

  // 0317 — the support-craft path the next three checks exercised is DELETED (it was unreachable:
  // p_loadout is '[]' at every call site, and this very client hard-codes []). The wrapper's own
  // p_loadout parameter is untouched, so the CONTRACT this file exists to prove is unchanged: a
  // loadout the adapter refuses must surface as valid:false with the message — never a crash, and
  // never a silently-ignored argument. That is now the single property, and the retired output
  // fields must be gone with it.
  const pRetired = (await preview(u1.client, [{ support_craft_type_id: 'missile_boat', quantity: 1 }])).data
  pRetired?.has_ship === true && pRetired.valid === false && /support craft|loadout/i.test(pRetired.error ?? '')
    ? ok('2. a non-empty loadout → valid:false + the retired-path message (refused, not silently ignored — 0317)')
    : bad('2. retired loadout', JSON.stringify(pRetired))

  const pFields = (await preview(u1.client, [])).data
  pFields?.stats && !('warnings' in pFields.stats) && !('support_capacity_used' in pFields.stats) && !('support_capacity_limit' in pFields.stats)
    ? ok('3. the retired stat fields (warnings / support_capacity_used / support_capacity_limit) are gone (0317)')
    : bad('3. retired fields', JSON.stringify(pFields?.stats))

  // the ship's own support_capacity is still reported on the SHIP object — only its duplicate
  // inside stats went away, so the number itself has not become unreachable.
  p0?.ship?.support_capacity === 10
    ? ok('4. the ship object still carries support_capacity (the column is unchanged)')
    : bad('4. ship support_capacity', JSON.stringify(p0?.ship))

  // ── user WITHOUT a ship → read-only hull teaser, no write ────────────────────
  const u2 = await newUser('b')
  const p2 = (await preview(u2.client, [])).data
  p2?.has_ship === false && p2.hull?.base_support_capacity === 10
    ? ok('5. no-ship player → hull teaser (no loadout stats)') : bad('5. hull teaser', JSON.stringify(p2))
  // read-only proof: previewing did NOT commission a ship
  ;((await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u2.userId)).data ?? []).length === 0
    ? ok('6. preview WROTE NOTHING (no-ship player still has no main ship)') : bad('6. read-only', 'preview created a ship!')

  // ── security: the stat adapter stays server-only ─────────────────────────────
  ;(await u1.client.rpc('calculate_expedition_stats', { p_player: u1.userId, p_main_ship_id: p0?.stats?.main_ship_id ?? '00000000-0000-0000-0000-000000000000', p_loadout: [], p_activity_type: 'pirate_hunt' })).error
    ? ok('7. calculate_expedition_stats still denied to clients (only the preview wrapper is exposed)') : bad('7. adapter exposed', 'client called calculate_expedition_stats!')
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (Legacy Main-Ship Verifier Safety Repair): delete verifier-created users (cascade
    // removes their game data). Preview never touches a feature flag.
    const { failures } = await teardownVerifier({ admin, createdUserIds })
    failures.forEach((f) => bad('TEARDOWN', f))
    console.log(`\nMain-ship preview: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
