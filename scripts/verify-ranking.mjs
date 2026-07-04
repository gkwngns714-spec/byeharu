// RANKING-P17 verification — DARK POSTURE + contracts (slices 0–4 + post-audit commit-safe accrual;
// migrations 0127–0131, 0144/0145).
//   node scripts/verify-ranking.mjs
//
// Proves, with anon/authenticated clients only, that the whole Ranking surface ships dark and locked
// exactly as migrations 0127–0131 claim:
//   • get_ranking_seasons() → {ok:false, code:'feature_disabled'} and
//     get_ranking_leaderboard(<any valid uuid>,'combat',10) → {ok:false, code:'feature_disabled'} —
//     the anti-probe gate answers BEFORE any validation while ranking_enabled='false' (a syntactically
//     valid uuid + a REAL dimension are passed precisely so the identical dark answer proves the gate
//     fires FIRST — unknown_season / invalid_dimension are NOT reached). CODE-keyed, matching the 0131
//     read surface (and the 0129/0130 writers).
//   • ranking_seasons + ranking_standings are PUBLIC-READ (the 0127/0128 posture): anon can SELECT
//     them (permitted, 0 rows on a fresh DB — reading the public tables back IS the posture assertion,
//     the catalog-table precedent)
//   • ranking_seasons + ranking_standings have NO client write path (direct inserts denied — no insert
//     policy / no write grant, 0127/0128)
//   • ranking_counted_grants (0144 schema / 0145 accrual writer) is SERVER-ONLY — client SELECT (anon
//     AND authenticated) denied and a valid-shaped authenticated INSERT denied (RLS, no client
//     policy/grant; the mining_fields/securing-table posture, not the public-read standings posture)
//   • internal surface (ranking_season_open, ranking_accrue_standings, ranking_score_delta) is
//     service-role-only — denied to authenticated AND to anon (0129/0130)
//   • ranking_enabled reads 'false' (READ-ONLY)
//
// DELIBERATELY NOT COPIED from verify-mainship-send.mjs: its set_game_config flag flip — the
// verify:exploration/verify:mining/verify:modules/verify:fitting/verify:captain(-progression)
// mechanism, followed exactly (verify-captain-progression.mjs:21–28): this script NEVER writes
// game_config and NEVER sets ranking_enabled. The surface exercises NO lit path at all — lit-path
// verification (flag on → ranking_season_open opens an active season → deposit finalized reward_grants
// → ranking_accrue_standings folds them once → a re-run is a no-op → get_ranking_leaderboard ranks
// them, overall = sum of per-dimension scores → opening a new season closes the prior active one while
// PRESERVING the closed season's standings rows) is deferred to the human owner's activation checklist:
// flip the flag on a DEV database and run the lit checks there, never here.
//
// Keys: VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY required. SUPABASE_SERVICE_ROLE_KEY is OPTIONAL and
// used ONLY for teardown (delete the throwaway user via the shared teardownVerifier — no flag entry is
// passed because this verifier touches NO flag); every ASSERTION runs with anon/authenticated clients only.

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
const WINDOW_START = '2026-01-01T00:00:00Z'   // fixed literals — no lit path, values never persisted
const WINDOW_END = '2026-01-08T00:00:00Z'
const createdUserIds = []
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'ranktest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

async function main() {
  console.log(`\nRanking (Phase 17 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (ranking_enabled = 'false'; server-rejected, never UI-only) ───────────────
  console.log('\n1. Dark rejection:')
  {
    const { data, error } = await me.rpc('get_ranking_seasons')
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("get_ranking_seasons → {ok:false, code:'feature_disabled'}")
      : bad('get_ranking_seasons dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    // A syntactically VALID uuid + a REAL dimension: any non-disabled answer (unknown_season /
    // invalid_dimension) would mean validation ran before the gate — the identical dark answer proves
    // the anti-probe gate fires FIRST. CODE-keyed, like the 0131 read surface.
    const { data, error } = await me.rpc('get_ranking_leaderboard', { p_season_id: ZERO, p_dimension: 'combat', p_limit: 10 })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("get_ranking_leaderboard → {ok:false, code:'feature_disabled'} (gate before validation)")
      : bad('get_ranking_leaderboard dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) Public-read posture (0127/0128 — anon SELECT permitted; reading them back IS the assertion) ─
  console.log('\n2. Public-read posture (anon):')
  {
    const { data, error } = await anon.from('ranking_seasons').select('*')
    !error && (data ?? []).length === 0
      ? ok('anon can SELECT ranking_seasons (public-read; 0 rows on fresh DB)')
      : bad('ranking_seasons public read', error?.message ?? `${data?.length} row(s) — unexpected on fresh DB`)
  }
  {
    const { data, error } = await anon.from('ranking_standings').select('*')
    !error && (data ?? []).length === 0
      ? ok('anon can SELECT ranking_standings (public-read; 0 rows on fresh DB)')
      : bad('ranking_standings public read', error?.message ?? `${data?.length} row(s) — unexpected on fresh DB`)
  }

  // ── 3) No client write path (0127/0128 — sole writers are Ranking's own server-only fns) ────────
  console.log('\n3. No client write path:')
  {
    // Sole writer is ranking_season_open (server-only); no insert policy / no write grant.
    const row = { cadence: 'weekly', label: 'x', starts_at: WINDOW_START, ends_at: WINDOW_END }
    ;(await me.from('ranking_seasons').insert(row)).error
      ? ok('ranking_seasons insert denied to authenticated client')
      : bad('ranking_seasons write path', 'INSERTED — hole!')
  }
  {
    // Sole writer is ranking_accrue_standings (server-only); no insert policy / no write grant.
    const row = { season_id: ZERO, player_id: u.userId, dimension: 'combat', score: 1, events_counted: 1 }
    ;(await me.from('ranking_standings').insert(row)).error
      ? ok('ranking_standings insert denied to authenticated client')
      : bad('ranking_standings write path', 'INSERTED — hole!')
  }

  // ── 3b) ranking_counted_grants is SERVER-ONLY (0144 schema / 0145 accrual writer) ────────────────
  //   Unlike the PUBLIC-READ seasons/standings, the accrual consumption ledger leaks NOTHING to
  //   clients (RLS enabled, NO client policy/grant — the mining_fields/securing-table posture) and has
  //   NO client write path; its sole writer is the server-only ranking_accrue_standings (0145). Read
  //   denial mirrors the mining_fields server-only assertion (tolerant of 'denied' OR '0 rows'); the
  //   INSERT denial mirrors the section-3 ranking_seasons/standings write-path assertions exactly.
  console.log('\n3b. ranking_counted_grants server-only (0144/0145):')
  {
    const { data, error } = await me.from('ranking_counted_grants').select('*')
    error || (data ?? []).length === 0
      ? ok(`ranking_counted_grants unreadable by authenticated clients (${error ? 'denied' : '0 rows'})`)
      : bad('ranking_counted_grants read', `authenticated client read ${data.length} ledger row(s)!`)
  }
  {
    const { data, error } = await anon.from('ranking_counted_grants').select('*')
    error || (data ?? []).length === 0
      ? ok(`ranking_counted_grants unreadable by anon (${error ? 'denied' : '0 rows'})`)
      : bad('ranking_counted_grants anon read', `anon read ${data.length} ledger row(s)!`)
  }
  {
    // Sole writer is ranking_accrue_standings (server-only); no insert policy / no write grant. A
    // valid-shaped row (real columns/types) proves the denial is the grant/policy layer, not a
    // constraint trip.
    const row = { season_id: ZERO, grant_id: ZERO, player_id: u.userId, dimension: 'combat', score: 1, granted_at: WINDOW_START }
    ;(await me.from('ranking_counted_grants').insert(row)).error
      ? ok('ranking_counted_grants insert denied to authenticated client')
      : bad('ranking_counted_grants write path', 'INSERTED — hole!')
  }

  // ── 4) Internal surface locked — client-role denial (the verify-captain-progression ACL idiom, via
  //       the anon/authenticated clients; no service-role assertion is needed for denials).
  console.log('\n4. Internal surface locked:')
  ;(await me.rpc('ranking_season_open', { p_cadence: 'weekly', p_starts_at: WINDOW_START, p_ends_at: WINDOW_END, p_label: 'x' })).error
    ? ok('ranking_season_open denied to authenticated client')
    : bad('ranking_season_open denied', 'EXECUTED — hole!')
  ;(await me.rpc('ranking_accrue_standings')).error
    ? ok('ranking_accrue_standings denied to authenticated client')
    : bad('ranking_accrue_standings denied', 'EXECUTED — hole!')
  ;(await me.rpc('ranking_score_delta', { p_rewards: {} })).error
    ? ok('ranking_score_delta denied to authenticated client')
    : bad('ranking_score_delta denied', 'EXECUTED — hole!')
  ;(await anon.rpc('ranking_accrue_standings')).error
    ? ok('ranking_accrue_standings denied to anon')
    : bad('ranking_accrue_standings anon ACL', 'anon executed it!')

  // ── 5) Config presence (READ-ONLY — this script never writes game_config) ───────────────────────
  // game_config.value is jsonb (0003): the seeded literal 'false' (0127) stores as a JSON boolean, so
  // supabase-js returns JS false — compare tolerantly of storage form (the server's cfg_bool is
  // storage-form-agnostic the same way).
  console.log('\n5. Config presence:')
  {
    const v = await cfgVal(me, 'ranking_enabled')
    String(v) === 'false' ? ok('ranking_enabled = false (dark)') : bad('ranking_enabled', `reads ${JSON.stringify(v)}`)
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
    console.log(`\nRanking dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
