// CAPTAIN-P15 verification — DARK POSTURE + contracts (slices A–G).
//   node scripts/verify-captain.mjs
//
// Proves, with a throwaway authenticated user, that the whole captain-assignment surface ships dark
// and locked exactly as migrations 0117–0123 claim:
//   • assign_captain_to_ship / unassign_captain_from_ship → {ok:false, reason:'captain_assignment_disabled'}
//     (the 0120 wrapper envelope; the anti-probe gate answers BEFORE any validation while
//     captain_assignment_enabled='false' — syntactically valid uuids/request_ids are passed precisely
//     so the identical answer proves the gate fires FIRST). Reason-keyed, not code-keyed: the whole
//     captain surface uses ONE reason vocabulary (the 0120 locked adaptation of 0113's code envelope).
//   • get_my_captain_instances / get_my_ship_captains → the SAME {ok:false, reason:'captain_assignment_disabled'}
//     (0123 read envelopes — the ONE server-driven visibility signal)
//   • captain_types carries the 0117 catalog columns PUBLICLY (id/name/specialization/description/
//     stats_json — the item_types/module_types posture): reading the five seeded archetypes' values
//     back verbatim IS the posture assertion, and every specialization sits in the CHECK set
//     ('combat','trade','exploration','mining','support')
//   • captain_instances / ship_captain_assignments / captain_assignment_receipts are own-row-only (a
//     fresh user sees zero rows) and have NO client write path (direct inserts denied)
//   • internal surfaces (captain_assign_apply / captain_execute_command / captain_command_client_envelope /
//     mainship_space_assert_settled_safe) are denied to client roles; the four public RPCs are denied
//     to anon
//   • captain_assignment_enabled reads 'false' (READ-ONLY)
//
// DELIBERATELY NOT COPIED from verify-mainship-send.mjs: its set_game_config flag flip — the
// verify:exploration/verify:mining/verify:modules/verify:fitting mechanism, followed exactly
// (verify-fitting.mjs:20–28): this script NEVER writes game_config and NEVER sets
// captain_assignment_enabled. The surface exercises NO lit path at all — lit-path verification
// (assign within slots → success + adapter stats change with specialization tradeoffs → over-capacity
// captain_slots_full → settled-SAFE ship_not_settled → already_assigned/not_assigned → verbatim replay
// without double-assign → unassign reverts the adapter stats) is deferred to the human owner's
// activation checklist (DEV_LOG 2026-07-04 Phase 15 closing entry): flip the flag on a DEV database and
// run the lit checks there, never here.
//
// Keys: VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY required. SUPABASE_SERVICE_ROLE_KEY is OPTIONAL
// and used ONLY for teardown (delete the throwaway user via the shared teardownVerifier — no flag
// entry is passed because this verifier touches NO flag); every ASSERTION runs with
// anon/authenticated clients only.

import { createClient } from '@supabase/supabase-js'
import { teardownVerifier } from './lib/verifier-teardown.mjs'
import { Abort, createReporter, createUserFactory, resolveEnv } from './lib/verify-harness.mjs'

// env/keys, reporter, and throwaway-signup come from the shared harness (scripts/lib/
// verify-harness.mjs) — ZERO inline harness copies (the harness header's law).
const { url, anonKey, serviceKey } = resolveEnv()

const admin = serviceKey ? createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } }) : null
const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })

const { counts, ok, bad } = createReporter()
const ZERO = '00000000-0000-0000-0000-000000000000'
const createdUserIds = []
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'captest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

// The 0117 seed contract, asserted verbatim (public Reference/Config — reading it IS the posture).
const SPECIALIZATIONS = ['combat', 'trade', 'exploration', 'mining', 'support']
const EXPECTED_CAPTAIN_CATALOG = {
  gunnery_veteran: {
    name: 'Gunnery Veteran', specialization: 'combat',
    description: 'A scarred line officer who squeezes real firepower out of any mounted battery.',
    stats: { attack: 4 },
  },
  trade_broker: {
    name: 'Licensed Trade Broker', specialization: 'trade',
    description: 'Knows every port ledger trick and stows cargo tighter than the manual allows.',
    stats: { cargo: 8 },
  },
  survey_cartographer: {
    name: 'Survey Cartographer', specialization: 'exploration',
    description: 'Charts the sensor noise other crews discard into usable survey data.',
    stats: { scan: 3 },
  },
  extraction_foreman: {
    name: 'Extraction Foreman', specialization: 'mining',
    description: 'Runs the rig cycle by ear and never wastes a bite of the seam.',
    stats: { mining: 4 },
  },
  fleet_quartermaster: {
    name: 'Fleet Quartermaster', specialization: 'support',
    description: 'Keeps hull patches and spare parts moving before anyone has to ask.',
    stats: { repair: 3 },
  },
}
const sortedJson = (o) => JSON.stringify(Object.entries(o ?? {}).sort())

async function main() {
  console.log(`\nCaptain assignment (Phase 15 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (captain_assignment_enabled = 'false'; server-rejected, never UI-only) ────
  console.log('\n1. Dark rejection:')
  {
    // Syntactically VALID uuids + request id: any non-disabled answer would mean validation ran
    // before the gate — the identical dark answer proves the gate fires FIRST.
    const { data, error } = await me.rpc('assign_captain_to_ship', { p_request_id: ZERO, p_captain_instance_id: ZERO, p_main_ship_id: ZERO })
    !error && data?.ok === false && data?.reason === 'captain_assignment_disabled'
      ? ok("assign_captain_to_ship → {ok:false, reason:'captain_assignment_disabled'}")
      : bad('assign dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('unassign_captain_from_ship', { p_request_id: ZERO, p_captain_instance_id: ZERO })
    !error && data?.ok === false && data?.reason === 'captain_assignment_disabled'
      ? ok("unassign_captain_from_ship → {ok:false, reason:'captain_assignment_disabled'}")
      : bad('unassign dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_my_captain_instances')
    !error && data?.ok === false && data?.reason === 'captain_assignment_disabled'
      ? ok("get_my_captain_instances → {ok:false, reason:'captain_assignment_disabled'}")
      : bad('instances read dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_my_ship_captains', { p_main_ship_id: ZERO })
    !error && data?.ok === false && data?.reason === 'captain_assignment_disabled'
      ? ok("get_my_ship_captains → {ok:false, reason:'captain_assignment_disabled'}")
      : bad('ship-roster read dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) Catalog contract (0117 — PUBLIC read by design, the item_types posture; exact seeds) ────
  console.log('\n2. Catalog contract (id/name/specialization/description/stats_json):')
  {
    const { data, error } = await me.from('captain_types').select('id, name, specialization, description, stats_json')
    if (error) bad('captain_types columns read', error.message)
    else {
      const rows = data ?? []
      rows.every((r) => SPECIALIZATIONS.includes(r.specialization))
        ? ok(`every captain_types.specialization in CHECK set {${SPECIALIZATIONS.join(',')}}`)
        : bad('specialization CHECK set', JSON.stringify(rows.filter((r) => !SPECIALIZATIONS.includes(r.specialization))))
      for (const [id, exp] of Object.entries(EXPECTED_CAPTAIN_CATALOG)) {
        const row = rows.find((r) => r.id === id)
        row && row.name === exp.name && row.specialization === exp.specialization
          && row.description === exp.description && sortedJson(row.stats_json) === sortedJson(exp.stats)
          ? ok(`${id}: ${exp.specialization} / ${JSON.stringify(exp.stats)} (0117 seed verbatim)`)
          : bad(`${id} seed`, row ? `name ${JSON.stringify(row.name)}, spec ${row.specialization}, stats ${JSON.stringify(row.stats_json)}` : 'row missing')
      }
    }
  }

  // ── 3) Player-state RLS + NO client write path (0118/0119/0120 posture) ────────────────────────
  console.log('\n3. Player-state RLS + no client write path:')
  for (const table of ['captain_instances', 'ship_captain_assignments', 'captain_assignment_receipts']) {
    const { data, error } = await me.from(table).select('*')
    !error && (data ?? []).length === 0
      ? ok(`${table} own-row RLS holds (fresh user sees 0 rows)`)
      : bad(`${table} RLS`, error?.message ?? `${data?.length} row(s) visible`)
  }
  for (const [table, row] of [
    ['captain_instances', { player_id: u.userId, captain_type_id: 'gunnery_veteran', mint_key: ZERO }],
    ['ship_captain_assignments', { captain_instance_id: ZERO, main_ship_id: ZERO, player_id: u.userId }],
    ['captain_assignment_receipts', { player_id: u.userId, request_id: ZERO, action: 'assign', captain_instance_id: ZERO, main_ship_id: ZERO, result_json: {} }],
  ]) {
    ;(await me.from(table).insert(row)).error
      ? ok(`${table} insert denied to authenticated client`)
      : bad(`${table} write path`, 'INSERTED — hole!')
  }

  // ── 4) Internal surfaces locked — client-role denial (the verify-m45 ACL idiom, via the
  //       anon/authenticated clients; no service-role assertion is needed for denials).
  console.log('\n4. Internal surfaces locked:')
  for (const [fn, args] of [
    ['captain_assign_apply', { p_player_id: ZERO, p_captain_instance_id: ZERO, p_main_ship_id: ZERO }],
    ['captain_execute_command', { p_player_id: ZERO, p_action: 'assign', p_captain_instance_id: ZERO, p_main_ship_id: ZERO, p_request_id: ZERO }],
    ['captain_command_client_envelope', { p_res: {} }],
    ['mainship_space_assert_settled_safe', { p_main_ship_id: ZERO }],
  ]) {
    ;(await me.rpc(fn, args)).error ? ok(`${fn} denied to authenticated client`) : bad(`${fn} denied`, 'EXECUTED — hole!')
  }
  for (const [fn, args] of [
    ['assign_captain_to_ship', { p_request_id: ZERO, p_captain_instance_id: ZERO, p_main_ship_id: ZERO }],
    ['unassign_captain_from_ship', { p_request_id: ZERO, p_captain_instance_id: ZERO }],
    ['get_my_captain_instances', {}],
    ['get_my_ship_captains', { p_main_ship_id: ZERO }],
  ]) {
    ;(await anon.rpc(fn, args)).error ? ok(`${fn} denied to anon`) : bad(`${fn} anon ACL`, 'anon executed it!')
  }

  // ── 5) Config presence (READ-ONLY — this script never writes game_config) ──────────────────────
  // game_config.value is jsonb (0003): the seeded literal 'false' (0117) stores as a JSON boolean,
  // so supabase-js returns JS false — compare tolerantly of storage form (the server's cfg_bool is
  // storage-form-agnostic the same way).
  console.log('\n5. Config presence:')
  {
    const v = await cfgVal(me, 'captain_assignment_enabled')
    String(v) === 'false' ? ok('captain_assignment_enabled = false (dark)') : bad('captain_assignment_enabled', `reads ${JSON.stringify(v)}`)
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (shared idiom): delete the verifier-owned throwaway user (cascade removes its game
    // data — captain_instances/ship_captain_assignments/captain_assignment_receipts included, the
    // 0118/0119/0120 player FKs). No flag entry is passed — this verifier touches NO flag, so there
    // is nothing to restore.
    if (admin) {
      const { failures } = await teardownVerifier({ admin, createdUserIds })
      failures.forEach((f) => bad('TEARDOWN', f))
    } else if (createdUserIds.length > 0) {
      console.log(`  · teardown skipped (no SUPABASE_SERVICE_ROLE_KEY) — throwaway user(s) left: ${createdUserIds.join(', ')}`)
    }
    console.log(`\nCaptain assignment dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
