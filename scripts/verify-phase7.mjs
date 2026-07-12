// Phase 7 verification — Main Ship Instance.  node scripts/verify-phase7.mjs
//
// One main ship per player, server-authoritative. Service-role drives the locked
// ensure/get/rename fns; anon clients verify public-read hull, owner-read instance,
// cross-user RLS, and that clients cannot write. Regression (verify-phase6 → … → m2/m3/m4)
// proves the fleet/combat/production engine is unchanged, unless PHASE7_SKIP_REGRESS=1.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'

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
const anonKey = env.VITE_SUPABASE_ANON_KEY
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !anonKey) { console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY'); process.exit(2) }
if (!serviceKey) { console.error('phase7 verify needs SUPABASE_SERVICE_ROLE_KEY (server-side).'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }
class Abort extends Error {}
const die = (m) => { throw new Abort(m) }

const ensure = (player) => admin.rpc('ensure_main_ship_for_player', { p_player: player })
const rename = (player, name) => admin.rpc('rename_main_ship', { p_player: player, p_name: name })
const shipRows = async (player) => (await admin.from('main_ship_instances').select('*').eq('player_id', player)).data ?? []
const oneShip = async (player) => (await shipRows(player))[0]

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `p7test.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  return { client: c, userId: su.user.id }
}

async function main() {
  console.log(`\nPhase 7 (Main Ship Instance) verification against ${url}\n`)
  const u1 = await newUser('a')
  const u2 = await newUser('b')
  ok('signed up two throwaway users')

  // 1/2. starter hull exists & is public-read.
  const { data: hulls, error: hErr } = await anon.from('main_ship_hull_types').select('*')
  if (hErr) die(`hull types not readable: ${hErr.message}`)
  const starter = (hulls ?? []).find((h) => h.hull_type_id === 'starter_frigate')
  starter ? ok('1/2. starter hull exists and is publicly readable (starter_frigate)') : bad('1/2. starter hull', JSON.stringify(hulls))
  starter && starter.base_support_capacity === 10 && starter.base_hp > 0 && starter.base_module_slots >= 2 && starter.base_captain_slots >= 1
    ? ok(`   hull stats sane (hp ${starter.base_hp}, support_capacity ${starter.base_support_capacity}, captain ${starter.base_captain_slots}, module ${starter.base_module_slots})`)
    : bad('   hull stats', JSON.stringify(starter))

  // 3. client cannot write hull types.
  const ih = await u1.client.from('main_ship_hull_types').insert({ hull_type_id: `hack_${Date.now()}`, name: 'X', base_hp: 1, base_speed: 1, base_cargo_capacity: 0, base_support_capacity: 0, base_captain_slots: 0, base_module_slots: 0 })
  ih.error ? ok('3. client INSERT into main_ship_hull_types blocked') : bad('3. hull write', 'EXECUTED — hole!')

  // 4. ensure creates one ship.
  await ensure(u1.userId)
  const s1 = await oneShip(u1.userId)
  s1 ? ok('4. ensure_main_ship_for_player created a main ship') : bad('4. create', 'no ship')

  // 5. idempotent — second call creates no duplicate.
  const before = await ensure(u1.userId)
  await ensure(u1.userId)
  const rows1 = await shipRows(u1.userId)
  rows1.length === 1 && rows1[0].main_ship_id === s1.main_ship_id
    ? ok('5. ensure is idempotent — exactly one ship, same id (no duplicates)') : bad('5. idempotency', `${rows1.length} ships`)

  // 6. owner can read own ship.
  const ownView = (await u1.client.from('main_ship_instances').select('*')).data ?? []
  ownView.length === 1 && ownView[0].main_ship_id === s1.main_ship_id ? ok('6. player can read own main ship (owner-read RLS)') : bad('6. owner read', JSON.stringify(ownView))

  // 7. cannot read another player's ship.
  const u2Sees = (await u2.client.from('main_ship_instances').select('main_ship_id')).data ?? []
  !u2Sees.some((r) => r.main_ship_id === s1.main_ship_id) ? ok("7. player cannot read another player's main ship") : bad('7. cross-user RLS', "u2 saw u1's ship")

  // 8. client cannot insert/update/delete the instance.
  const ci = await u1.client.from('main_ship_instances').insert({ player_id: u1.userId, hull_type_id: 'starter_frigate', hp: 1, max_hp: 1, cargo_capacity: 0, support_capacity: 999, captain_slots: 0, module_slots: 0 })
  await u1.client.from('main_ship_instances').update({ support_capacity: 999, hp: 99999 }).eq('player_id', u1.userId)
  await u1.client.from('main_ship_instances').delete().eq('player_id', u1.userId)
  void ci // insert may error or RLS-no-op; the real assertion is "no mutation" below
  const afterClient = await oneShip(u1.userId)
  afterClient && afterClient.support_capacity === s1.support_capacity && afterClient.hp === s1.hp
    ? ok('8. client INSERT/UPDATE/DELETE of main_ship_instances all blocked (row unchanged, not deleted)') : bad('8. client write', JSON.stringify(afterClient))

  // 8b. client cannot call the server-only RPCs.
  ;(await u1.client.rpc('ensure_main_ship_for_player', { p_player: u1.userId })).error ? ok('8b. ensure_main_ship_for_player denied to client') : bad('8b. ensure denied', 'EXECUTED')
  ;(await u1.client.rpc('rename_main_ship', { p_player: u2.userId, p_name: 'pwn' })).error ? ok('8b. rename_main_ship denied to client') : bad('8b. rename denied', 'EXECUTED')

  // 9. valid stat values.
  const s = await oneShip(u1.userId)
  s.max_hp > 0 && s.hp >= 0 && s.hp <= s.max_hp && s.cargo_capacity >= 0 && s.cargo_used === 0 &&
    s.support_capacity === starter.base_support_capacity && s.captain_slots === starter.base_captain_slots && s.module_slots === starter.base_module_slots
    ? ok(`9. ship stats valid & copied from hull (hp ${s.hp}/${s.max_hp}, support ${s.support_capacity}, captain ${s.captain_slots}, module ${s.module_slots})`)
    : bad('9. stats', JSON.stringify(s))

  // 10. status defaults to home; name defaults to Byeharu.
  s.status === 'home' && s.name === 'Sparrow' ? ok("10. status defaults to 'home' (name 'Sparrow' — 0184)") : bad('10. defaults', `${s.status}/${s.name}`)

  // 11. rename works (trim) + validates empty / overlong.
  const rr = await rename(u1.userId, '  Aqua Voyager  ')
  ;(await oneShip(u1.userId)).name === 'Aqua Voyager' ? ok('11. rename_main_ship trims + sets name') : bad('11. rename', JSON.stringify(rr))
  ;(await rename(u1.userId, '   ')).error ? ok('11. rename rejects empty/whitespace name') : bad('11. empty name', 'accepted')
  ;(await rename(u1.userId, 'x'.repeat(60))).error ? ok('11. rename rejects overlong name (>40)') : bad('11. long name', 'accepted')
  ;(await rename(u2.userId, 'Ghost')).error ? ok('11. rename rejects player with no ship') : bad('11. no-ship rename', 'accepted')

  // 12/13/14. regression — fleet/combat/production engine unchanged.
  console.log('\n12/13/14. Regression (Phase6 → Phase5 → Phase4 → Inventory → M4.5 → M5 → M2/M3/M4):')
  if (env.PHASE7_SKIP_REGRESS === '1') console.log('  · skipped (PHASE7_SKIP_REGRESS=1)')
  else { try { execSync('node scripts/verify-phase6.mjs', { stdio: 'inherit' }); ok('verify:phase6 (full chain) passed — combat + build queue + support metadata unchanged') } catch { bad('regression', 'verify:phase6 non-zero exit') } }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(() => { console.log(`\nPhase 7: ${pass} passed, ${fail} failed\n`); process.exitCode = fail > 0 ? 1 : 0 })
