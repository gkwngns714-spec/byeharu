// OSN-2a verification — schema-only durable open-space position on main_ship_instances.
//   node scripts/verify-osn2.mjs
//
// Proves migration 0054's columns + CHECK invariants WITH NO reader / resolver / RPC / flag /
// gameplay change. There is no arbitrary-SQL RPC, so the schema is exercised BEHAVIORALLY: a
// service-role client UPDATEs a THROWAWAY, ISOLATED probe ship with every spatial_state / coordinate
// combination and asserts which the DB accepts vs. rejects (a CHECK violation surfaces as a Postgres
// error). A normal authenticated client and an anon client are proven unable to write the new
// columns (owner-read RLS, no UPDATE grant).
//
// PROBE-FIXTURE SAFETY: the probe ship belongs to a freshly-created throwaway `osn2test.*` user and
// is created via ensure_main_ship_for_player. EVERY write is scoped by `main_ship_id = probeId`; no
// query ever targets another player's ship. The entire fixture (auth user → cascades to its base /
// fleets / ship) is DELETED in finally, so the user's live main ship and every ordinary player's
// main ship are never touched.
//
// Durable design (no forever-invalid assertions): this verifier does NOT assert "no row is 'home'"
// globally — future OSN-3/4 writers may legitimately create normalized 'home' rows. Instead it proves
// the migration's effect durably: spatial_state is nullable with NO default (a freshly ensured ship
// is NULL, never 'home'), legacy NULL is accepted and stays coordinate-free, and no operation flips a
// NULL state to 'home'. That the migration contains NO back-fill/UPDATE is confirmed by migration
// review, not by a global count that only holds immediately after this first migration.
//
// Needs SUPABASE_SERVICE_ROLE_KEY (commission the probe ship, drive UPDATEs, delete the fixture).
// Touches NO game_config / flags.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

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
if (!serviceKey) { console.error('needs SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }

// Read the three OSN-2 columns of the probe ship.
const spatial = async (id) =>
  (await admin.from('main_ship_instances').select('spatial_state,space_x,space_y').eq('main_ship_id', id).maybeSingle()).data
const isLegacyNull = (s) => s && s.spatial_state === null && s.space_x === null && s.space_y === null
// Attempt a service-role UPDATE of the three columns; return the Postgres error (or null on success).
const upd = async (id, f) =>
  (await admin.from('main_ship_instances').update(f).eq('main_ship_id', id)).error
const expectAccept = async (id, label, f) => { const e = await upd(id, f); e ? bad(label, `rejected: ${e.message}`) : ok(label) }
const expectReject = async (id, label, f) => { const e = await upd(id, f); e ? ok(`${label} (rejected: ${e.code || 'err'})`) : bad(label, 'accepted an invalid combination!') }

let probeUserId = null
let probeId = null

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `osn2test.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  return { client: c, userId: su.user.id }
}
const shipIdFor = async (userId) =>
  (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', userId).maybeSingle()).data?.main_ship_id

async function main() {
  console.log(`\nOSN-2a (main-ship spatial_state schema) verification against ${url}\n`)

  // ── Isolated probe fixture: throwaway user + its own ensured ship ───────────────────────────────
  const u = await newUser('a'); probeUserId = u.userId
  await admin.rpc('ensure_main_ship_for_player', { p_player: u.userId })
  probeId = await shipIdFor(u.userId)
  if (!probeId) die('probe ship not commissioned')
  const fresh = await spatial(probeId)

  // ── 1 — columns exist; a freshly-ensured ship is spatial_state=NULL, coords NULL ────────────────
  //        (proves the columns are nullable, have NO default, and are NOT set to 'home').
  if (fresh && 'spatial_state' in fresh && 'space_x' in fresh && 'space_y' in fresh) {
    isLegacyNull(fresh)
      ? ok('1. columns exist; fresh ensured ship = spatial_state NULL, space_x/space_y NULL (nullable, no default, not home)')
      : bad('1. fresh defaults', JSON.stringify(fresh))
  } else {
    bad('1. columns exist', `select returned ${JSON.stringify(fresh)}`)
  }

  // ── 2 — durable: ensure is idempotent and does NOT implicitly flip a NULL state to 'home' ───────
  await admin.rpc('ensure_main_ship_for_player', { p_player: u.userId }) // idempotent re-ensure
  {
    const s = await spatial(probeId)
    s.spatial_state === null
      ? ok('2. re-ensure leaves spatial_state NULL (no implicit NULL→home; no writer sets it yet)')
      : bad('2. implicit home', `spatial_state became ${JSON.stringify(s.spatial_state)}`)
  }

  // ── 3 — legacy NULL + null coords is ACCEPTED and stays coordinate-free ─────────────────────────
  await expectAccept(probeId, '3. NULL state + null coords accepted (legacy)', { spatial_state: null, space_x: null, space_y: null })
  isLegacyNull(await spatial(probeId)) ? ok('3a. legacy row remains coordinate-free after accept') : bad('3a. legacy coords', 'coords not null')

  // ── 4 — NULL state + non-null coords is REJECTED ───────────────────────────────────────────────
  await expectReject(probeId, '4. NULL state + coords', { spatial_state: null, space_x: 10, space_y: 20 })

  // ── 5 — coordinates without in_space (home + coords) REJECTED ──────────────────────────────────
  await expectReject(probeId, '5. home + coords', { spatial_state: 'home', space_x: 10, space_y: 20 })

  // ── 6 — half-pair (exactly one coordinate) REJECTED ────────────────────────────────────────────
  await expectReject(probeId, '6. half-pair (x set, y null)', { spatial_state: 'in_space', space_x: 10, space_y: null })
  await expectReject(probeId, '6a. half-pair (y set, x null)', { spatial_state: 'in_space', space_x: null, space_y: 20 })

  // ── 7 — in_space without coordinates REJECTED ──────────────────────────────────────────────────
  await expectReject(probeId, '7. in_space + null coords', { spatial_state: 'in_space', space_x: null, space_y: null })

  // ── 8 — in_space + both FINITE coordinates ACCEPTED (decimals prove double precision) ───────────
  await expectAccept(probeId, '8. in_space + finite coords (double precision)', { spatial_state: 'in_space', space_x: 128.5, space_y: -64.25 })
  {
    const s = await spatial(probeId)
    s.spatial_state === 'in_space' && s.space_x === 128.5 && s.space_y === -64.25
      ? ok('8a. parked coords round-trip exactly (128.5, -64.25)') : bad('8a. round-trip', JSON.stringify(s))
  }
  // Non-finite coordinates are sent as the string literals 'NaN'/'Infinity'/'-Infinity' — JSON has no
  // NaN/Infinity, so JS numbers would be coerced to null; the string form casts to float8 NaN/±Inf and
  // hits the CHECK. Each uses an otherwise-valid in_space shape (the other coordinate is finite).
  await expectReject(probeId, '8b. in_space + NaN x', { spatial_state: 'in_space', space_x: 'NaN', space_y: 0 })
  await expectReject(probeId, '8c. in_space + +Infinity x', { spatial_state: 'in_space', space_x: 'Infinity', space_y: 0 })
  await expectReject(probeId, '8d. in_space + -Infinity y', { spatial_state: 'in_space', space_x: 0, space_y: '-Infinity' })

  // ── 9 — every non-in_space domain value ACCEPTED with null coords ──────────────────────────────
  for (const st of ['home', 'at_location', 'in_transit', 'destroyed']) {
    await expectAccept(probeId, `9. ${st} + null coords accepted`, { spatial_state: st, space_x: null, space_y: null })
  }

  // ── 10 — out-of-domain spatial_state REJECTED ──────────────────────────────────────────────────
  await expectReject(probeId, '10. out-of-domain spatial_state (parked)', { spatial_state: 'parked', space_x: null, space_y: null })

  // ── 11 — destroyed retains NO coordinate (destroyed + coords REJECTED) ──────────────────────────
  await expectReject(probeId, '11. destroyed + coords', { spatial_state: 'destroyed', space_x: 1, space_y: 1 })

  // ── 12 — no client write: authenticated owner + anon cannot mutate the new columns ─────────────
  await upd(probeId, { spatial_state: null, space_x: null, space_y: null }) // reset to known legacy state
  {
    await u.client.from('main_ship_instances').update({ spatial_state: 'in_space', space_x: 5, space_y: 5 }).eq('main_ship_id', probeId)
    isLegacyNull(await spatial(probeId))
      ? ok('12. authenticated owner cannot write spatial columns (value unchanged)') : bad('12. client write', 'value changed')
  }
  {
    const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
    await anon.from('main_ship_instances').update({ spatial_state: 'in_space', space_x: 7, space_y: 7 }).eq('main_ship_id', probeId)
    isLegacyNull(await spatial(probeId))
      ? ok('12a. anon cannot write spatial columns (value unchanged)') : bad('12a. anon write', 'value changed')
  }

  // ── 13 — OSN-1 resolver source untouched: references NONE of the new columns ────────────────────
  {
    const here = dirname(fileURLToPath(import.meta.url))
    const src = readFileSync(join(here, '..', 'src', 'features', 'map', 'resolveMainShipMarker.ts'), 'utf8')
    const referencesNew = /spatial_state|space_x|space_y/.test(src)
    referencesNew
      ? bad('13. resolver untouched', 'resolveMainShipMarker.ts references a new OSN-2 column')
      : ok('13. OSN-1 resolver references none of the new columns (no read-model change)')
  }
  console.log('\n  (Engine regression M2/M3/M4/M4.5 runs separately via the auto verify:phase8 chain after deploy.)')
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Fully delete the isolated probe fixture: removing the auth user cascades to its base / fleets /
    // main_ship_instances row (player_id … on delete cascade). Fallback: delete the ship row directly.
    try {
      if (probeUserId) {
        const { error } = await admin.auth.admin.deleteUser(probeUserId)
        if (error && probeId) await admin.from('main_ship_instances').delete().eq('main_ship_id', probeId)
      } else if (probeId) {
        await admin.from('main_ship_instances').delete().eq('main_ship_id', probeId)
      }
    } catch {
      try { if (probeId) await admin.from('main_ship_instances').delete().eq('main_ship_id', probeId) } catch {}
    }
    console.log(`\nOSN-2a: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
