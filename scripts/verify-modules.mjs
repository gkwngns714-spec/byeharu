// MODULES-P13 verification — DARK POSTURE + contracts (slices A–F).
//   node scripts/verify-modules.mjs
//
// Proves, with a throwaway authenticated user, that the whole module-crafting surface ships dark
// and locked exactly as migrations 0107–0110 claim:
//   • craft_module → {ok:false, code:'feature_disabled'} (the 0109 wrapper envelope; the writer +
//     wrapper both reject BEFORE any read while module_crafting_enabled='false')
//   • get_my_module_instances → {ok:false, reason:'module_crafting_disabled'} (0110 read envelope)
//   • module_types / module_recipe_ingredients are PUBLIC-READ catalogs (0107 — the item_types
//     posture, deliberately inverted from mining's hidden fields): the 4 seeded archetypes and
//     their 12 recipe rows read back exactly, every qty > 0, every ingredient id present in
//     item_types (the client-checkable form of FK validity)
//   • module_instances / module_craft_receipts are own-row-only (a fresh user sees zero rows) and
//     have NO client write path (inserts denied — to the catalogs too)
//   • internal surfaces (production_craft_module / modules_mint_instance) are denied to client
//     roles; both public RPCs are denied to anon
//   • module_crafting_enabled reads 'false' (READ-ONLY)
//
// DELIBERATELY NOT COPIED from verify-mainship-send.mjs: its set_game_config flag flip — the
// verify:exploration/verify:mining mechanism, followed exactly (verify-mining.mjs:16–20): this
// script NEVER writes game_config and NEVER sets module_crafting_enabled. The twins exercise NO
// lit path at all — lit-path verification (craft → exact recipe spend with ledger rows → ONE
// minted instance with the namespaced 'craft:' key → one receipt → verbatim replay without
// double-spend/double-mint → insufficient_items/unknown_module/no_recipe envelopes → same-key
// mint-once → owner-only newest-first read) is deferred to the human owner's activation checklist
// (DEV_LOG 2026-07-04 Phase 13 closing entry): flip the flag on a DEV database and run the lit
// checks there, never here.
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
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'modtest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

// The 0107 seed contract, asserted verbatim (public Reference/Config — reading it IS the posture).
const EXPECTED_TYPES = {
  autocannon_battery: 'weapon',
  vector_thruster_kit: 'engine',
  expanded_cargo_lattice: 'cargo',
  deep_scan_sensor_array: 'sensor',
}
const EXPECTED_RECIPES = {
  autocannon_battery: { weapon_parts: 4, pirate_alloy: 2, scrap: 6 },
  vector_thruster_kit: { engine_parts: 4, crystal: 2, scrap: 4 },
  expanded_cargo_lattice: { scrap: 10, pirate_alloy: 3, repair_parts: 2 },
  deep_scan_sensor_array: { scan_data: 5, anomaly_shard: 2, blueprint_fragment: 1 },
}

async function main() {
  console.log(`\nModule crafting (Phase 13 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (module_crafting_enabled = 'false'; server-rejected, never UI-only) ─────
  console.log('\n1. Dark rejection:')
  {
    // The wrapper gates BEFORE any validation (anti-probe), so dummy args get the same answer.
    const { data, error } = await me.rpc('craft_module', { p_request_id: ZERO, p_module_type: 'autocannon_battery' })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("craft_module → {ok:false, code:'feature_disabled'}")
      : bad('craft dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_my_module_instances')
    !error && data?.ok === false && data?.reason === 'module_crafting_disabled'
      ? ok("get_my_module_instances → {ok:false, reason:'module_crafting_disabled'}")
      : bad('read dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) Catalog seeds (0107 — PUBLIC read by design, the item_types posture; exact contract) ───
  console.log('\n2. Catalog seeds:')
  {
    const { data, error } = await me.from('module_types').select('id, slot_type')
    const got = Object.fromEntries((data ?? []).map((r) => [r.id, r.slot_type]))
    !error && (data ?? []).length === 4 &&
    JSON.stringify(Object.entries(got).sort()) === JSON.stringify(Object.entries(EXPECTED_TYPES).sort())
      ? ok('module_types = the 4 seeded archetypes (weapon/engine/cargo/sensor)')
      : bad('module_types seeds', error?.message ?? JSON.stringify(got))
  }
  {
    const { data, error } = await me.from('module_recipe_ingredients').select('module_type_id, item_id, qty')
    if (error) bad('module_recipe_ingredients read', error.message)
    else {
      const rows = data ?? []
      rows.length === 12
        ? ok('module_recipe_ingredients = 12 rows')
        : bad('recipe row count', `${rows.length} rows`)
      rows.every((r) => r.qty > 0)
        ? ok('every recipe qty > 0')
        : bad('recipe qty check', JSON.stringify(rows.filter((r) => !(r.qty > 0))))
      const got = {}
      for (const r of rows) (got[r.module_type_id] ??= {})[r.item_id] = r.qty
      Object.keys({ ...EXPECTED_RECIPES, ...got }).every(
        (t) => JSON.stringify(Object.entries(EXPECTED_RECIPES[t] ?? {}).sort()) === JSON.stringify(Object.entries(got[t] ?? {}).sort()),
      )
        ? ok('every recipe matches the 0107 seed contract exactly')
        : bad('recipe contents', JSON.stringify(got))
      // FK validity, client-checkable form: every ingredient id exists in the public item catalog.
      const itemIds = new Set(((await me.from('item_types').select('item_id')).data ?? []).map((r) => r.item_id))
      const missing = [...new Set(rows.map((r) => r.item_id))].filter((id) => !itemIds.has(id))
      missing.length === 0
        ? ok('every recipe item_id exists in item_types (FK-valid)')
        : bad('recipe FK validity', `unknown item ids: ${missing.join(', ')}`)
    }
  }

  // ── 3) Player-state RLS + NO client write path (0108/0109 posture) ────────────────────────────
  console.log('\n3. Player-state RLS + no client write path:')
  {
    const { data, error } = await me.from('module_instances').select('*')
    !error && (data ?? []).length === 0
      ? ok('module_instances own-row RLS holds (fresh user sees 0 rows)')
      : bad('instances RLS', error?.message ?? `${data?.length} row(s) visible`)
  }
  {
    const { data, error } = await me.from('module_craft_receipts').select('*')
    !error && (data ?? []).length === 0
      ? ok('module_craft_receipts own-row RLS holds (fresh user sees 0 rows)')
      : bad('receipts RLS', error?.message ?? `${data?.length} row(s) visible`)
  }
  for (const [table, row] of [
    ['module_instances', { player_id: u.userId, module_type_id: 'autocannon_battery', mint_key: `verify:${ZERO}` }],
    ['module_craft_receipts', { player_id: u.userId, request_id: ZERO, module_type_id: 'autocannon_battery', instance_id: ZERO }],
    ['module_types', { id: 'verify_bogus', name: 'x', slot_type: 'x', description: 'x' }],
    ['module_recipe_ingredients', { module_type_id: 'autocannon_battery', item_id: 'scrap', qty: 1 }],
  ]) {
    ;(await me.from(table).insert(row)).error
      ? ok(`${table} insert denied to authenticated client`)
      : bad(`${table} write path`, 'INSERTED — hole!')
  }

  // ── 4) Internal surfaces locked — client-role denial (the verify-m45 ACL idiom, via the
  //       anon/authenticated clients; no service-role assertion is needed for denials).
  console.log('\n4. Internal surfaces locked:')
  for (const [fn, args] of [
    ['production_craft_module', { p_player: ZERO, p_module_type: 'autocannon_battery', p_request_id: ZERO }],
    ['modules_mint_instance', { p_player: ZERO, p_module_type: 'autocannon_battery', p_key: `verify:${ZERO}` }],
  ]) {
    ;(await me.rpc(fn, args)).error ? ok(`${fn} denied to authenticated client`) : bad(`${fn} denied`, 'EXECUTED — hole!')
  }
  for (const [fn, args] of [
    ['craft_module', { p_request_id: ZERO, p_module_type: 'autocannon_battery' }],
    ['get_my_module_instances', {}],
  ]) {
    ;(await anon.rpc(fn, args)).error ? ok(`${fn} denied to anon`) : bad(`${fn} anon ACL`, 'anon executed it!')
  }

  // ── 5) Config presence (READ-ONLY — this script never writes game_config) ─────────────────────
  // game_config.value is jsonb (0003): the seeded literal 'false' (0107) stores as a JSON boolean,
  // so supabase-js returns JS false — compare tolerantly of storage form (the server's cfg_bool is
  // storage-form-agnostic the same way).
  console.log('\n5. Config presence:')
  {
    const v = await cfgVal(me, 'module_crafting_enabled')
    String(v) === 'false' ? ok('module_crafting_enabled = false (dark)') : bad('module_crafting_enabled', `reads ${JSON.stringify(v)}`)
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (shared idiom): delete the verifier-owned throwaway user (cascade removes its game
    // data — module_instances/module_craft_receipts included, 0108/0109 player FKs). No flag entry
    // is passed — this verifier touches NO flag, so there is nothing to restore.
    if (admin) {
      const { failures } = await teardownVerifier({ admin, createdUserIds })
      failures.forEach((f) => bad('TEARDOWN', f))
    } else if (createdUserIds.length > 0) {
      console.log(`  · teardown skipped (no SUPABASE_SERVICE_ROLE_KEY) — throwaway user(s) left: ${createdUserIds.join(', ')}`)
    }
    console.log(`\nModule crafting dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
