// LOCATION-INVEST-P18 verification — DARK POSTURE + contracts (slices 0–2, migrations 0132–0134).
//   node scripts/verify-location-investment.mjs
//
// Proves, with anon/authenticated clients only, that the whole Location Investment surface ships dark
// and locked exactly as migrations 0132–0134 claim:
//   • every client-callable RPC → {ok:false, code:'feature_disabled'} while
//     location_investment_enabled='false' — each called with VALID-shaped args (random uuids, a real
//     amount/limit) precisely so the identical dark answer proves the anti-probe gate fires BEFORE any
//     validation (ownership / not_docked / unknown_location are NOT reached). CODE-keyed, matching the
//     0133/0134 envelopes.
//   • location_investments is OWNER-READ, NOT public (the Phase-18 divergence from Ranking's public
//     tables): the authenticated own-set reads back empty (0 rows) on a fresh DB, and anon has NO
//     SELECT grant at all (denied — never other players' rows).
//   • location_investments has NO client write path (direct insert denied — no insert policy / no
//     write grant, 0132).
//   • internal surface (location_investment_invest sole writer + location_investment_current_window
//     helper) is service-role-only — denied to authenticated AND to anon (0133/0134).
//   • location_investment_enabled reads 'false' + the three tunables carry their seeded values
//     (READ-ONLY).
//
// DELIBERATE DEVIATION from the instruction's Group-2 wording ("anon direct select returns 0 rows"):
// the shipped 0132 grant is `grant select … to authenticated` ONLY — anon has NO SELECT grant, so an
// anon select is DENIED, not 0-rows. Denial is the STRONGER, truthful proof of the owner-read (NOT
// public) posture — so this script asserts anon-DENIED + authenticated-0-rows. (Ranking's tables are
// public-read → verify-ranking asserts anon-permitted; Investment's are owner-read → the opposite.)
//
// NO-FLAG-WRITE / NO-LIT-PATH stance carried VERBATIM from verify-ranking.mjs (the
// verify:exploration/mining/modules/fitting/captain(-progression)/ranking mechanism): this script
// NEVER writes game_config and NEVER flips location_investment_enabled. The surface exercises NO lit
// path at all — lit-path verification (flag on → a docked ship → invest_in_location debits credits via
// wallet_debit and appends exactly one ledger row → a replay of the same request_id is a no-op, no
// double debit → get_location_development reflects the new all_time_total/season_total →
// get_location_investment_leaderboard ranks the contributor within the current window → crossing into
// the next window resets season_total while all_time_total and the ledger persist → withdrawal/payout
// is impossible, one-way sink) is DEFERRED to the human owner's activation checklist: flip the flag on
// a DEV database and run the lit checks there, never here.
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
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'locinvest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

async function main() {
  console.log(`\nLocation Investment (Phase 18 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (location_investment_enabled = 'false'; server-rejected, never UI-only) ─────
  // VALID-shaped args (random uuids + a real amount/limit): any non-disabled answer (ship_not_owned /
  // not_docked / unknown_location) would mean validation ran before the gate — the identical dark
  // answer proves the anti-probe gate fires FIRST. CODE-keyed, matching the 0133/0134 envelopes.
  console.log('\n1. Dark rejection:')
  {
    const { data, error } = await me.rpc('invest_in_location', { p_ship: randomUUID(), p_amount: 1, p_request_id: randomUUID() })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("invest_in_location → {ok:false, code:'feature_disabled'} (gate before ownership)")
      : bad('invest_in_location dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_location_development', { p_location_id: randomUUID() })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("get_location_development → {ok:false, code:'feature_disabled'} (gate before unknown_location)")
      : bad('get_location_development dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_location_investment_leaderboard', { p_location_id: randomUUID(), p_limit: 10 })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("get_location_investment_leaderboard → {ok:false, code:'feature_disabled'} (gate before validation)")
      : bad('get_location_investment_leaderboard dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_my_location_investments')
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("get_my_location_investments → {ok:false, code:'feature_disabled'}")
      : bad('get_my_location_investments dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) Owner-read posture (0132 — NOT public; the Phase-18 divergence from Ranking's public tables) ─
  console.log('\n2. Owner-read posture (NOT public):')
  {
    // Authenticated: the RLS own-set (player_id = auth.uid()) is empty on a fresh DB — reading it back
    // empty IS the posture assertion (a fresh user owns no contributions), never another player's rows.
    const { data, error } = await me.from('location_investments').select('*')
    !error && (data ?? []).length === 0
      ? ok('authenticated own-set of location_investments reads back empty (0 rows)')
      : bad('location_investments own-read', error?.message ?? `${data?.length} row(s) — unexpected on fresh DB`)
  }
  {
    // Anon: NO SELECT grant at all (0132 grants to authenticated ONLY) → denied. This is the owner-read
    // (NOT public) proof — the exact opposite of Ranking's anon-permitted public tables.
    ;(await anon.from('location_investments').select('*')).error
      ? ok('anon SELECT on location_investments denied (owner-read, NOT public)')
      : bad('location_investments anon posture', 'anon SELECT permitted — should be owner-read only!')
  }

  // ── 3) No client write path (0132 — sole writer is location_investment_invest, server-only) ──────
  console.log('\n3. No client write path:')
  {
    const row = { player_id: u.userId, request_id: randomUUID(), location_id: ZERO, amount: 1 }
    ;(await me.from('location_investments').insert(row)).error
      ? ok('location_investments insert denied to authenticated client')
      : bad('location_investments write path', 'INSERTED — hole!')
  }

  // ── 4) Internal surface locked — client-role denial (the 0133/0134 service-role-only ACL) ────────
  console.log('\n4. Internal surface locked:')
  ;(await me.rpc('location_investment_invest', { p_player: ZERO, p_ship: ZERO, p_amount: 1, p_request_id: ZERO })).error
    ? ok('location_investment_invest denied to authenticated client')
    : bad('location_investment_invest denied', 'EXECUTED — hole!')
  ;(await anon.rpc('location_investment_invest', { p_player: ZERO, p_ship: ZERO, p_amount: 1, p_request_id: ZERO })).error
    ? ok('location_investment_invest denied to anon')
    : bad('location_investment_invest anon ACL', 'anon executed it!')
  ;(await me.rpc('location_investment_current_window')).error
    ? ok('location_investment_current_window denied to authenticated client')
    : bad('location_investment_current_window denied', 'EXECUTED — hole!')
  ;(await anon.rpc('location_investment_current_window')).error
    ? ok('location_investment_current_window denied to anon')
    : bad('location_investment_current_window anon ACL', 'anon executed it!')

  // ── 5) Config presence (READ-ONLY — this script never writes game_config) ────────────────────────
  // game_config.value is jsonb (0003): 'false' stores as a JSON boolean and the numeric tunables as
  // JSON numbers, so supabase-js returns JS false / numbers — compare tolerantly of storage form via
  // String() (the server's cfg_bool/cfg_num are storage-form-agnostic the same way).
  console.log('\n5. Config presence:')
  {
    const v = await cfgVal(me, 'location_investment_enabled')
    String(v) === 'false' ? ok('location_investment_enabled = false (dark)') : bad('location_investment_enabled', `reads ${JSON.stringify(v)}`)
  }
  for (const [k, want] of [
    ['location_investment_min_amount', '1'],
    ['location_investment_season_seconds', '604800'],
    ['location_investment_season_epoch_seconds', '1767225600'],
  ]) {
    const v = await cfgVal(me, k)
    String(v) === want ? ok(`${k} = ${want}`) : bad(k, `reads ${JSON.stringify(v)} (want ${want})`)
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
    console.log(`\nLocation Investment dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
