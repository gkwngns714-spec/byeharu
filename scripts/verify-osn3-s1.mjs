// OSN-3 S1 live verification (post-deploy). Covers the Supabase-specific surface the disposable
// postgres proofs cannot: RLS/grants on the new tables, both flags OFF, the write-once trigger on the
// REAL fleets table, and the live coordinate-movement distribution. (Constraint LOGIC is proven on an
// ephemeral postgres:15 in scripts/osn3-s1-*-proof.sql.)
//   node scripts/verify-osn3-s1.mjs   (needs SUPABASE_SERVICE_ROLE_KEY)
//
// Read-mostly: it creates ONE throwaway user + a service-role-inserted main-ship fleet to exercise the
// trigger, then deletes the user (cascade) in finally. No flag is changed; no coordinate writer exists.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

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
const cfgVal = async (k) => (await admin.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

let probeUserId = null

async function newUser(tag) {
  const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: su, error } = await c.auth.signUp({ email: `osn3s1test.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
  if (error) die(`signup failed: ${error.message}`)
  if (!su.session) die('no session — email confirmation still ON')
  return { client: c, userId: su.user.id }
}

async function main() {
  console.log(`\nOSN-3 S1 live verification against ${url}\n`)

  // 1) both flags OFF
  String(await cfgVal('mainship_send_enabled')) === 'false' ? ok('1. mainship_send_enabled = false') : bad('1. send flag', String(await cfgVal('mainship_send_enabled')))
  String(await cfgVal('mainship_space_movement_enabled')) === 'false' ? ok('2. mainship_space_movement_enabled = false') : bad('2. space flag', String(await cfgVal('mainship_space_movement_enabled')))

  // 3) new tables exist (service-role count head)
  {
    const a = await admin.from('main_ship_space_movements').select('id', { count: 'exact', head: true })
    const b = await admin.from('main_ship_space_command_receipts').select('id', { count: 'exact', head: true })
    !a.error ? ok(`3. main_ship_space_movements exists (rows=${a.count})`) : bad('3. movements table', a.error.message)
    !b.error ? ok(`3a. main_ship_space_command_receipts exists (rows=${b.count})`) : bad('3a. receipts table', b.error.message)
    a.count === 0 ? ok('3b. zero coordinate-movement rows (no writer in S1)') : bad('3b. distribution', `${a.count} rows`)
  }

  const u = await newUser('a'); probeUserId = u.userId
  await admin.rpc('ensure_main_ship_for_player', { p_player: u.userId })
  const shipId = (await admin.from('main_ship_instances').select('main_ship_id').eq('player_id', u.userId).maybeSingle()).data?.main_ship_id
  if (!shipId) die('probe ship not commissioned')
  const baseId = (await admin.from('bases').select('id').eq('player_id', u.userId).limit(1).maybeSingle()).data?.id

  // 4) RLS: authenticated owner-read on movements returns only own rows (none); receipts not readable
  {
    const ownMv = await u.client.from('main_ship_space_movements').select('id')
    !ownMv.error && (ownMv.data?.length ?? 0) === 0 ? ok('4. authenticated owner-read movements = own rows only (0)') : bad('4. movements RLS read', JSON.stringify(ownMv.error ?? ownMv.data))
    const rcpt = await u.client.from('main_ship_space_command_receipts').select('id')
    ;(rcpt.error || (rcpt.data?.length ?? 0) === 0) ? ok('4a. receipts not readable by authenticated (denied/empty)') : bad('4a. receipts RLS', JSON.stringify(rcpt.data))
  }

  // 5) authenticated CANNOT write the new tables (no insert/update/delete grant)
  {
    const ins = await u.client.from('main_ship_space_movements').insert({
      main_ship_id: shipId, fleet_id: shipId, player_id: u.userId, origin_kind: 'space', origin_x: 0, origin_y: 0,
      target_kind: 'space', target_x: 1, target_y: 1, speed_used: 1, depart_at: new Date(Date.now()).toISOString(), arrive_at: new Date(Date.now() + 60000).toISOString(),
    })
    ins.error ? ok('5. authenticated INSERT into movements denied') : bad('5. movements write', 'insert succeeded!')
    const insR = await u.client.from('main_ship_space_command_receipts').insert({ main_ship_id: shipId, player_id: u.userId, request_id: shipId, command_type: 'x', canonical_payload_hash: 'x', outcome_status: 'x' })
    insR.error ? ok('5a. authenticated INSERT into receipts denied') : bad('5a. receipts write', 'insert succeeded!')
  }

  // 6) write-once trigger on the REAL fleets table (service-role direct inserts; cleanup via user delete)
  if (baseId) {
    const fleetIns = await admin.from('fleets').insert({ player_id: u.userId, origin_base_id: baseId, status: 'idle', location_mode: 'base', current_base_id: baseId, main_ship_id: shipId }).select('id').maybeSingle()
    if (fleetIns.error) { bad('6. fleet insert (setup)', fleetIns.error.message) }
    else {
      const fId = fleetIns.data.id
      const reassign = await admin.from('fleets').update({ main_ship_id: shipId }).eq('id', fId) // same value → allowed (no change)
      !reassign.error ? ok('6. same-value main_ship_id update allowed') : bad('6. same-value', reassign.error.message)
      const detach = await admin.from('fleets').update({ main_ship_id: null }).eq('id', fId) // detach while ship exists → rejected
      detach.error ? ok('6a. detach (ship still exists) rejected by write-once trigger') : bad('6a. detach', 'detach allowed!')
      // parent-deletion orphaning: delete the ship → FK SET NULL must succeed (trigger allows)
      const delShip = await admin.from('main_ship_instances').delete().eq('main_ship_id', shipId)
      !delShip.error ? ok('6b. ship hard-delete succeeded (FK SET NULL orphaning allowed)') : bad('6b. ship delete', delShip.error.message)
      const after = (await admin.from('fleets').select('main_ship_id').eq('id', fId).maybeSingle()).data
      after && after.main_ship_id === null ? ok('6c. fleet.main_ship_id orphaned to NULL after ship delete') : bad('6c. orphan', JSON.stringify(after))
    }
  } else {
    bad('6. trigger live', 'no base for probe user')
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    try { if (probeUserId) await admin.auth.admin.deleteUser(probeUserId) } catch {}
    console.log(`\nOSN-3 S1: ${pass} passed, ${fail} failed\n`)
    process.exitCode = fail > 0 ? 1 : 0
  })
