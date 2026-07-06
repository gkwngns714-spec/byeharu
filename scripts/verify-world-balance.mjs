// WORLD-BALANCE-P19 verification — DARK POSTURE + contracts (slices 1–3, migrations 0135–0137).
//   node scripts/verify-world-balance.mjs
//
// Proves, with anon/authenticated clients only, that the whole Phase-19 living-economy surface ships
// dark and locked exactly as migrations 0135–0137 claim:
//   • pirate pressure (0135): the tick reads combat_reports DOWNWARD for a defeat-driven danger term,
//     gated on world_balance_enabled; while dark the tick is byte-identical (no-op).
//   • price drift (0136): location_state.price_multiplier is World-State-owned, composed into every
//     Trade Market price via trade_effective_price → worldstate_current_price_multiplier; while dark
//     the multiplier is 1.0 (composition inert).
//   • field depletion (0137): mining_field_state is the World-State-owned per-field reserve, read via
//     worldstate_field_remaining and drawn down via worldstate_deplete_field; while dark both self-gate.
// Every World-State internal (worldstate_tick + the three helpers) is service-role-only; the new state
// is server-only (mining_field_state) or public-read-but-inert (location_state.price_multiplier=1.0);
// market_offers + mining_fields stay static (no runtime writer — Phase 19 added none).
//
// NO-FLAG-WRITE / NO-LIT-PATH stance carried VERBATIM from verify-location-investment.mjs (the
// verify:ranking mechanism): this script NEVER writes game_config and NEVER flips world_balance_enabled.
// The surface exercises NO lit path at all — lit-path verification (flag on → the tick raises pressure
// at recently-defeated locations and decays it; drifts location_state.price_multiplier toward the
// danger-premium target so trade_effective_price moves the charged/paid price in lockstep with the
// displayed price; depletes mining_field_state.reserve_fraction on each extraction, the bundle yield
// thinning but floored, while the tick regenerates it toward 1.0) is DEFERRED to the human owner's
// activation checklist: flip the flag on a DEV database and run the lit checks there, never here.
//
// Keys: VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY required. SUPABASE_SERVICE_ROLE_KEY is OPTIONAL and
// used ONLY for teardown (delete the throwaway user via the shared teardownVerifier — no flag entry is
// passed because this verifier touches NO flag); every ASSERTION runs with anon/authenticated clients only.

import { randomUUID } from 'node:crypto'
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
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'worldbal', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

async function main() {
  console.log(`\nWorld Balance (Phase 19 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Config presence (READ-ONLY — this script never writes game_config) ─────────────────────────
  // game_config.value is jsonb (0003): 'false' stores as a JSON boolean and the numeric tunables as
  // JSON numbers, so supabase-js returns JS false / numbers — compare tolerantly of storage form via
  // String() (the server's cfg_bool/cfg_num are storage-form-agnostic the same way).
  console.log('\n1. Config presence:')
  {
    const v = await cfgVal(me, 'world_balance_enabled')
    String(v) === 'false' ? ok('world_balance_enabled = false (dark master gate)') : bad('world_balance_enabled', `reads ${JSON.stringify(v)}`)
  }
  for (const [k, want] of [
    ['world_balance_defeat_window_seconds', '3600'],
    ['world_balance_price_pressure_coeff', '0.5'],
    ['world_balance_price_drift_rate', '0.1'],
    ['world_balance_price_multiplier_min', '0.5'],
    ['world_balance_price_multiplier_max', '2.0'],
    ['world_balance_field_depletion_per_extract', '0.1'],
    ['world_balance_field_regen_rate', '0.02'],
    ['world_balance_field_reserve_min', '0.1'],
  ]) {
    const v = await cfgVal(me, k)
    String(v) === want ? ok(`${k} = ${want}`) : bad(k, `reads ${JSON.stringify(v)} (want ${want})`)
  }

  // ── 2) Internal World-State functions locked (service-role-only ACL — 0135–0137) ──────────────────
  // VALID-shaped args (random uuids) so the denial proves the LOCK, not argument validation. worldstate_*
  // internals are granted to service_role ONLY (revoked from public/anon/authenticated), so a client call
  // must error for BOTH anon and authenticated.
  console.log('\n2. Internal World-State functions locked:')
  const lockedFns = [
    ['worldstate_current_price_multiplier', { p_location: randomUUID() }],
    ['worldstate_field_remaining', { p_field: randomUUID() }],
    ['worldstate_deplete_field', { p_field: randomUUID() }],
    ['worldstate_tick', {}],
  ]
  for (const [fn, args] of lockedFns) {
    ;(await me.rpc(fn, args)).error
      ? ok(`${fn} denied to authenticated client`)
      : bad(`${fn} denied`, 'EXECUTED — hole!')
    ;(await anon.rpc(fn, args)).error
      ? ok(`${fn} denied to anon`)
      : bad(`${fn} anon ACL`, 'anon executed it!')
  }

  // ── 3) mining_field_state is server-only (0137 — RLS on, no client policy/grant; the mining_fields posture) ─
  console.log('\n3. mining_field_state server-only:')
  {
    // Authenticated + anon SELECT both denied (no client read grant/policy). A fresh DB carries no rows
    // regardless — denial is the posture proof (never a client read path to world-state reserve).
    ;(await me.from('mining_field_state').select('*')).error
      ? ok('authenticated SELECT on mining_field_state denied (server-only)')
      : bad('mining_field_state auth read', 'authenticated SELECT permitted — should be server-only!')
    ;(await anon.from('mining_field_state').select('*')).error
      ? ok('anon SELECT on mining_field_state denied (server-only)')
      : bad('mining_field_state anon read', 'anon SELECT permitted — should be server-only!')
  }
  {
    // No client write path — the sole writers are World State's own worldstate_deplete_field + tick regen.
    const row = { field_id: ZERO, reserve_fraction: 1.0 }
    ;(await me.from('mining_field_state').insert(row)).error
      ? ok('mining_field_state insert denied to authenticated client')
      : bad('mining_field_state write path', 'INSERTED — hole!')
  }

  // ── 4) location_state.price_multiplier — public-readable but a dark no-op (composition inert at 1.0) ─
  console.log('\n4. location_state.price_multiplier dark no-op:')
  {
    // location_state is public-read (0031). The 0136 column is selectable; while dark the tick never
    // touches it, so EVERY existing row equals 1.0 (proving composition is inert). A fresh DB may carry
    // 0 rows — do not fail on emptiness; the column being selectable is itself the proof.
    const { data, error } = await anon.from('location_state').select('price_multiplier')
    if (error) {
      bad('location_state.price_multiplier readable', error.message)
    } else {
      const rows = data ?? []
      const allOne = rows.every((r) => Number(r.price_multiplier) === 1.0)
      allOne
        ? ok(`location_state.price_multiplier selectable; all ${rows.length} row(s) = 1.0 (dark no-op)`)
        : bad('location_state.price_multiplier dark no-op', `some row ≠ 1.0 while dark: ${JSON.stringify(rows.filter((r) => Number(r.price_multiplier) !== 1.0))}`)
    }
  }

  // ── 5) Static catalogs unchanged — no second writer added by Phase 19 (0136/0137 laws) ────────────
  // market_offers (public-read Reference/Config) and mining_fields (server-only Reference/Config) both
  // keep NO client write path: a direct authenticated INSERT/UPDATE is denied. Phase 19 composes on top
  // (location_state / mining_field_state) and added no runtime writer to either static catalog.
  console.log('\n5. Static catalogs — no second writer:')
  {
    const row = { location_id: ZERO, good_id: 'ore', buy_price: 1, sell_price: 2 }
    ;(await me.from('market_offers').insert(row)).error
      ? ok('market_offers insert denied to authenticated client (still static)')
      : bad('market_offers write path', 'INSERTED — hole!')
    ;(await me.from('market_offers').update({ sell_price: 999 }).eq('good_id', 'ore')).error
      ? ok('market_offers update denied to authenticated client (still static)')
      : bad('market_offers update path', 'UPDATED — hole!')
  }
  {
    const row = { name: `wb-verify-${randomUUID()}`, space_x: 0, space_y: 0, reward_bundle_json: { items: [] } }
    ;(await me.from('mining_fields').insert(row)).error
      ? ok('mining_fields insert denied to authenticated client (still static, server-only)')
      : bad('mining_fields write path', 'INSERTED — hole!')
    ;(await me.from('mining_fields').update({ is_active: false }).neq('id', ZERO)).error
      ? ok('mining_fields update denied to authenticated client (still static, server-only)')
      : bad('mining_fields update path', 'UPDATED — hole!')
  }
}

main()
  .catch((e) => { if (e instanceof Abort) bad('ABORTED', e.message); else bad('UNEXPECTED', e?.message ?? String(e)) })
  .finally(async () => {
    // Teardown (shared idiom): delete the verifier-owned throwaway user (cascade removes its game
    // data). No flag entry is passed — this verifier touches NO flag, so there is nothing to restore.
    if (admin) {
      const { failures } = await teardownVerifier({ admin, createdUserIds })
      failures.forEach((f) => bad('TEARDOWN', f))
    } else if (createdUserIds.length > 0) {
      console.log(`  · teardown skipped (no SUPABASE_SERVICE_ROLE_KEY) — throwaway user(s) left: ${createdUserIds.join(', ')}`)
    }
    console.log(`\nWorld Balance dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
