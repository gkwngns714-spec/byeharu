// CAPTAIN-P16 verification — DARK POSTURE + contracts (slices 1–3, recruitment surface).
//   node scripts/verify-captain-progression.mjs
//
// Proves, with a throwaway authenticated user, that the whole captain-RECRUITMENT surface ships dark
// and locked exactly as migrations 0124–0126 claim:
//   • recruit_captain → {ok:false, code:'feature_disabled', message:…} (the 0126 wrapper envelope; the
//     anti-probe gate answers BEFORE any validation while captain_progression_enabled='false' — a
//     syntactically valid request_id AND a REAL captain type id ('gunnery_veteran') are passed
//     precisely so the identical dark answer proves the gate fires FIRST). CODE-keyed, like
//     craft_module (0109): the recruit command mirrors the module-craft code envelope, NOT the
//     reason-keyed assignment surface (0120/0123).
//   • captain_recipe_ingredients carries the 0125 recipe seeds PUBLICLY (the item_types/captain_types
//     posture): reading the five seeded recipes' (captain_type_id, item_id, qty) rows back verbatim IS
//     the posture assertion, and every qty > 0
//   • captain_recruit_receipts is own-row-only (a fresh user sees zero rows) and has NO client write
//     path (direct inserts denied — 0126)
//   • internal surface (production_recruit_captain) is denied to client roles; the public
//     recruit_captain is denied to anon
//   • captain_progression_enabled reads 'false' (READ-ONLY)
//
// DELIBERATELY NOT COPIED from verify-mainship-send.mjs: its set_game_config flag flip — the
// verify:exploration/verify:mining/verify:modules/verify:fitting/verify:captain mechanism, followed
// exactly (verify-captain.mjs:24–32): this script NEVER writes game_config and NEVER sets
// captain_progression_enabled. The surface exercises NO lit path at all — lit-path verification
// (flag on → recruit within balance → success + one new captain_instances row + one receipt →
// insufficient balance → insufficient_items → verbatim replay returns the original receipt WITHOUT a
// second mint/spend → unknown_captain / no_recipe reasons) is deferred to the human owner's
// activation checklist: flip the flag on a DEV database and run the lit checks there, never here.
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
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'caprectest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

// The 0125 recipe seed contract, asserted verbatim (public Reference/Config — reading it IS the
// posture). One implicit recipe per captain type = its {item_id: qty} rows; captain_memory_shard is
// the shared rare gating ingredient on every recipe.
const EXPECTED_RECIPES = {
  gunnery_veteran:     { captain_memory_shard: 1, weapon_parts: 3, pirate_alloy: 2 },
  trade_broker:        { captain_memory_shard: 1, scrap: 8, repair_parts: 2 },
  survey_cartographer: { captain_memory_shard: 1, scan_data: 4, anomaly_shard: 2 },
  extraction_foreman:  { captain_memory_shard: 1, ore: 6, crystal: 2 },
  fleet_quartermaster: { captain_memory_shard: 1, repair_parts: 3, engine_parts: 2 },
}
const sortedJson = (o) => JSON.stringify(Object.entries(o ?? {}).sort())

async function main() {
  console.log(`\nCaptain recruitment (Phase 16 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (captain_progression_enabled = 'false'; server-rejected, never UI-only) ────
  console.log('\n1. Dark rejection:')
  {
    // A syntactically VALID request_id + a REAL captain type id: any non-disabled answer would mean
    // validation ran before the gate — the identical dark answer proves the gate fires FIRST. The
    // 0126 wrapper is CODE-keyed (like craft_module), so match code:'feature_disabled'.
    const { data, error } = await me.rpc('recruit_captain', { p_request_id: ZERO, p_captain_type: 'gunnery_veteran' })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("recruit_captain → {ok:false, code:'feature_disabled'}")
      : bad('recruit dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) Recipe catalog contract (0125 — PUBLIC read by design, the item_types posture; exact seeds) ─
  console.log('\n2. Recipe catalog contract (captain_type_id / item_id / qty):')
  {
    const { data, error } = await me.from('captain_recipe_ingredients').select('captain_type_id, item_id, qty')
    if (error) bad('captain_recipe_ingredients read', error.message)
    else {
      const rows = data ?? []
      rows.every((r) => r.qty > 0)
        ? ok('every captain_recipe_ingredients.qty > 0')
        : bad('recipe qty > 0', JSON.stringify(rows.filter((r) => !(r.qty > 0))))
      for (const [captainType, exp] of Object.entries(EXPECTED_RECIPES)) {
        const actual = Object.fromEntries(rows.filter((r) => r.captain_type_id === captainType).map((r) => [r.item_id, r.qty]))
        sortedJson(actual) === sortedJson(exp)
          ? ok(`${captainType}: ${JSON.stringify(exp)} (0125 seed verbatim)`)
          : bad(`${captainType} recipe`, `got ${JSON.stringify(actual)}`)
      }
    }
  }

  // ── 3) Player-state RLS + NO client write path (0126 posture) ──────────────────────────────────
  console.log('\n3. Player-state RLS + no client write path:')
  {
    const { data, error } = await me.from('captain_recruit_receipts').select('*')
    !error && (data ?? []).length === 0
      ? ok('captain_recruit_receipts own-row RLS holds (fresh user sees 0 rows)')
      : bad('captain_recruit_receipts RLS', error?.message ?? `${data?.length} row(s) visible`)
  }
  {
    // Sole writer is production_recruit_captain (server-only); no insert policy / no write grant.
    const row = { player_id: u.userId, request_id: ZERO, captain_type_id: 'gunnery_veteran', instance_id: ZERO }
    ;(await me.from('captain_recruit_receipts').insert(row)).error
      ? ok('captain_recruit_receipts insert denied to authenticated client')
      : bad('captain_recruit_receipts write path', 'INSERTED — hole!')
  }

  // ── 4) Internal surface locked — client-role denial (the verify-captain ACL idiom, via the
  //       anon/authenticated clients; no service-role assertion is needed for denials).
  console.log('\n4. Internal surface locked:')
  ;(await me.rpc('production_recruit_captain', { p_player: ZERO, p_captain_type: 'gunnery_veteran', p_request_id: ZERO })).error
    ? ok('production_recruit_captain denied to authenticated client')
    : bad('production_recruit_captain denied', 'EXECUTED — hole!')
  ;(await anon.rpc('recruit_captain', { p_request_id: ZERO, p_captain_type: 'gunnery_veteran' })).error
    ? ok('recruit_captain denied to anon')
    : bad('recruit_captain anon ACL', 'anon executed it!')

  // ── 5) Config presence (READ-ONLY — this script never writes game_config) ──────────────────────
  // game_config.value is jsonb (0003): the seeded literal 'false' (0124) stores as a JSON boolean,
  // so supabase-js returns JS false — compare tolerantly of storage form (the server's cfg_bool is
  // storage-form-agnostic the same way).
  console.log('\n5. Config presence:')
  {
    const v = await cfgVal(me, 'captain_progression_enabled')
    String(v) === 'false' ? ok('captain_progression_enabled = false (dark)') : bad('captain_progression_enabled', `reads ${JSON.stringify(v)}`)
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (shared idiom): delete the verifier-owned throwaway user (cascade removes its game
    // data — captain_recruit_receipts included, the 0126 player FK). No flag entry is passed — this
    // verifier touches NO flag, so there is nothing to restore.
    if (admin) {
      const { failures } = await teardownVerifier({ admin, createdUserIds })
      failures.forEach((f) => bad('TEARDOWN', f))
    } else if (createdUserIds.length > 0) {
      console.log(`  · teardown skipped (no SUPABASE_SERVICE_ROLE_KEY) — throwaway user(s) left: ${createdUserIds.join(', ')}`)
    }
    console.log(`\nCaptain recruitment dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
