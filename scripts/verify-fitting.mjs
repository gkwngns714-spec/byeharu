// FITTING-P14 verification — DARK POSTURE + contracts (slices A–G).
//   node scripts/verify-fitting.mjs
//
// Proves, with a throwaway authenticated user, that the whole module-fitting surface ships dark
// and locked exactly as migrations 0111–0116 claim:
//   • fit_module_to_ship / unfit_module_from_ship → {ok:false, code:'feature_disabled'} (the 0113
//     wrapper envelope; the anti-probe gate answers BEFORE any validation while
//     module_fitting_enabled='false' — syntactically valid uuids/request_ids are passed precisely
//     so the identical answer proves the gate fires FIRST)
//   • get_my_ship_fittings → {ok:false, reason:'module_fitting_disabled'} (0116 read envelope)
//   • module_types carries the 0111 fitting catalog columns PUBLICLY (slot_cost / stats_json —
//     the item_types posture, deliberately inverted from mining's hidden fields: reading the four
//     archetypes' seeded values back verbatim IS the posture assertion), every slot_cost >= 1
//   • ship_module_fittings / module_fitting_receipts are own-row-only (a fresh user sees zero
//     rows) and have NO client write path (inserts denied)
//   • internal surfaces (fitting_apply / fitting_execute_command / the client-envelope mapper)
//     are denied to client roles; the three public RPCs are denied to anon
//   • module_fitting_enabled reads 'false' (READ-ONLY)
//
// DELIBERATELY NOT COPIED from verify-mainship-send.mjs: its set_game_config flag flip — the
// verify:exploration/verify:mining/verify:modules mechanism, followed exactly
// (verify-mining.mjs:16–20): this script NEVER writes game_config and NEVER sets
// module_fitting_enabled. The twins exercise NO lit path at all — lit-path verification (fit
// within slots → success + adapter stats change with tradeoffs → over-capacity insufficient_slots
// → settled-SAFE ship_not_settled → already_fitted/not_fitted → verbatim replay without
// double-fit → unfit reverts the adapter stats) is deferred to the human owner's activation
// checklist (DEV_LOG 2026-07-04 Phase 14 closing entry): flip the flag on a DEV database and run
// the lit checks there, never here.
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
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'fittest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

// The 0111 seed contract, asserted verbatim (public Reference/Config — reading it IS the posture).
const EXPECTED_FITTING_CATALOG = {
  autocannon_battery: { slot_cost: 1, stats: { attack: 10 } },
  vector_thruster_kit: { slot_cost: 1, stats: { evasion: 3, speed_mult_bonus: 0.1 } },
  expanded_cargo_lattice: { slot_cost: 2, stats: { cargo: 25 } },
  deep_scan_sensor_array: { slot_cost: 1, stats: { scan: 8 } },
}
const sortedJson = (o) => JSON.stringify(Object.entries(o ?? {}).sort())

async function main() {
  console.log(`\nModule fitting (Phase 14 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (module_fitting_enabled = 'false'; server-rejected, never UI-only) ──────
  console.log('\n1. Dark rejection:')
  {
    // Syntactically VALID uuids + request id: any non-feature_disabled answer would mean
    // validation ran before the gate — the identical dark answer proves the gate fires FIRST.
    const { data, error } = await me.rpc('fit_module_to_ship', { p_module_instance_id: ZERO, p_main_ship_id: ZERO, p_request_id: ZERO })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("fit_module_to_ship → {ok:false, code:'feature_disabled'}")
      : bad('fit dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('unfit_module_from_ship', { p_module_instance_id: ZERO, p_request_id: ZERO })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("unfit_module_from_ship → {ok:false, code:'feature_disabled'}")
      : bad('unfit dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_my_ship_fittings')
    !error && data?.ok === false && data?.reason === 'module_fitting_disabled'
      ? ok("get_my_ship_fittings → {ok:false, reason:'module_fitting_disabled'}")
      : bad('read dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) Catalog contract (0111 — PUBLIC read by design, the item_types posture; exact seeds) ───
  console.log('\n2. Catalog contract (slot_cost / stats_json):')
  {
    const { data, error } = await me.from('module_types').select('id, slot_cost, stats_json')
    if (error) bad('module_types fitting columns read', error.message)
    else {
      const rows = data ?? []
      rows.every((r) => r.slot_cost >= 1)
        ? ok('every module_types.slot_cost >= 1')
        : bad('slot_cost check', JSON.stringify(rows.filter((r) => !(r.slot_cost >= 1))))
      for (const [id, exp] of Object.entries(EXPECTED_FITTING_CATALOG)) {
        const row = rows.find((r) => r.id === id)
        row && row.slot_cost === exp.slot_cost && sortedJson(row.stats_json) === sortedJson(exp.stats)
          ? ok(`${id}: slot_cost ${exp.slot_cost} + stats ${JSON.stringify(exp.stats)} (0111 seed verbatim)`)
          : bad(`${id} seed`, row ? `slot_cost ${row.slot_cost}, stats ${JSON.stringify(row.stats_json)}` : 'row missing')
      }
    }
  }

  // ── 3) Player-state RLS + NO client write path (0112/0113 posture) ─────────────────────────────
  console.log('\n3. Player-state RLS + no client write path:')
  {
    const { data, error } = await me.from('ship_module_fittings').select('*')
    !error && (data ?? []).length === 0
      ? ok('ship_module_fittings own-row RLS holds (fresh user sees 0 rows)')
      : bad('fittings RLS', error?.message ?? `${data?.length} row(s) visible`)
  }
  {
    const { data, error } = await me.from('module_fitting_receipts').select('*')
    !error && (data ?? []).length === 0
      ? ok('module_fitting_receipts own-row RLS holds (fresh user sees 0 rows)')
      : bad('fitting receipts RLS', error?.message ?? `${data?.length} row(s) visible`)
  }
  for (const [table, row] of [
    ['ship_module_fittings', { module_instance_id: ZERO, main_ship_id: ZERO, player_id: u.userId }],
    ['module_fitting_receipts', { player_id: u.userId, request_id: ZERO, action: 'fit', module_instance_id: ZERO, main_ship_id: ZERO, result_json: {} }],
  ]) {
    ;(await me.from(table).insert(row)).error
      ? ok(`${table} insert denied to authenticated client`)
      : bad(`${table} write path`, 'INSERTED — hole!')
  }

  // ── 4) Internal surfaces locked — client-role denial (the verify-m45 ACL idiom, via the
  //       anon/authenticated clients; no service-role assertion is needed for denials).
  console.log('\n4. Internal surfaces locked:')
  for (const [fn, args] of [
    ['fitting_apply', { p_player: ZERO, p_module_instance_id: ZERO, p_main_ship_id: ZERO }],
    ['fitting_execute_command', { p_player: ZERO, p_action: 'fit', p_module_instance_id: ZERO, p_main_ship_id: ZERO, p_request_id: ZERO }],
    ['fitting_command_client_envelope', { p_res: {} }],
  ]) {
    ;(await me.rpc(fn, args)).error ? ok(`${fn} denied to authenticated client`) : bad(`${fn} denied`, 'EXECUTED — hole!')
  }
  for (const [fn, args] of [
    ['fit_module_to_ship', { p_module_instance_id: ZERO, p_main_ship_id: ZERO, p_request_id: ZERO }],
    ['unfit_module_from_ship', { p_module_instance_id: ZERO, p_request_id: ZERO }],
    ['get_my_ship_fittings', {}],
  ]) {
    ;(await anon.rpc(fn, args)).error ? ok(`${fn} denied to anon`) : bad(`${fn} anon ACL`, 'anon executed it!')
  }

  // ── 5) Config presence (READ-ONLY — this script never writes game_config) ─────────────────────
  // game_config.value is jsonb (0003): the seeded literal 'false' (0111) stores as a JSON boolean,
  // so supabase-js returns JS false — compare tolerantly of storage form (the server's cfg_bool is
  // storage-form-agnostic the same way).
  console.log('\n5. Config presence:')
  {
    const v = await cfgVal(me, 'module_fitting_enabled')
    String(v) === 'false' ? ok('module_fitting_enabled = false (dark)') : bad('module_fitting_enabled', `reads ${JSON.stringify(v)}`)
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (shared idiom): delete the verifier-owned throwaway user (cascade removes its game
    // data — ship_module_fittings/module_fitting_receipts included, the 0112/0113 player FKs). No
    // flag entry is passed — this verifier touches NO flag, so there is nothing to restore.
    if (admin) {
      const { failures } = await teardownVerifier({ admin, createdUserIds })
      failures.forEach((f) => bad('TEARDOWN', f))
    } else if (createdUserIds.length > 0) {
      console.log(`  · teardown skipped (no SUPABASE_SERVICE_ROLE_KEY) — throwaway user(s) left: ${createdUserIds.join(', ')}`)
    }
    console.log(`\nModule fitting dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
