// EXPLORATION-P11 verification — DARK POSTURE + contracts (slices A–H).
//   node scripts/verify-exploration.mjs
//
// Proves, with a throwaway authenticated user, that the whole exploration surface ships dark and
// locked exactly as migrations 0097–0101 claim:
//   • command_exploration_scan → {ok:false, code:'feature_disabled'} (the 0099/0100 wrapper envelope;
//     the writer + wrapper both reject BEFORE any read while exploration_enabled='false')
//   • get_my_exploration_discoveries → {ok:false, reason:'exploration_disabled'} (0101 read envelope)
//   • exploration_sites leaks NOTHING to clients (RLS with no client policy/grant — 0098)
//   • exploration_discoveries is own-row-only (a fresh user sees zero rows)
//   • internal surfaces (exploration_scan / process_exploration_securing / osn_distance) are denied
//     to client roles
//   • exploration_enabled reads 'false' and exploration_scan_radius reads '750' (READ-ONLY)
//
// DELIBERATELY NOT COPIED from verify-mainship-send.mjs: its set_game_config flag flip (lines
// 49/98/105 there). This script NEVER writes game_config and NEVER sets exploration_enabled —
// lit-path verification (scan → discovery → securing deposit with the flag on) is deferred to the
// human owner's activation checklist (DEV_LOG 2026-07-04 Phase 11 closing entry): flip the flag on a
// DEV database and run the lit checks there, never here.
//
// Keys: VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY required. SUPABASE_SERVICE_ROLE_KEY is OPTIONAL
// and used ONLY for teardown (delete the throwaway user via the shared teardownVerifier — the
// verify-mainship-* cleanup idiom); every ASSERTION runs with anon/authenticated clients only.
// Without the key, teardown is skipped with a note (verify-m3/m4 precedent: they also sign up
// throwaway users with no admin cleanup).

import { createClient } from '@supabase/supabase-js'
import { teardownVerifier } from './lib/verifier-teardown.mjs'
import { Abort, createReporter, createUserFactory, resolveEnv } from './lib/verify-harness.mjs'

// env/keys, reporter, and throwaway-signup come from the shared harness (scripts/lib/
// verify-harness.mjs — the canonical copy of the blocks the sibling verifiers still inline).
const { url, anonKey, serviceKey } = resolveEnv()

const admin = serviceKey ? createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } }) : null
const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })

const { counts, ok, bad } = createReporter()
const ZERO = '00000000-0000-0000-0000-000000000000'
const createdUserIds = []
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'exploretest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

async function main() {
  console.log(`\nExploration (Phase 11 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (exploration_enabled = 'false'; server-rejected, never UI-only) ─────────
  console.log('\n1. Dark rejection:')
  {
    // The wrapper gates BEFORE ship resolution (anti-probe), so a zero ship id gets the same answer.
    const { data, error } = await me.rpc('command_exploration_scan', { p_main_ship_id: ZERO, p_request_id: ZERO })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("command_exploration_scan → {ok:false, code:'feature_disabled'}")
      : bad('scan dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_my_exploration_discoveries')
    !error && data?.ok === false && data?.reason === 'exploration_disabled'
      ? ok("get_my_exploration_discoveries → {ok:false, reason:'exploration_disabled'}")
      : bad('read dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) No site leak (hidden until discovery — 0098: RLS enabled, no client policy/grant) ──────
  console.log('\n2. No site leak:')
  {
    const { data, error } = await me.from('exploration_sites').select('*')
    error || (data ?? []).length === 0
      ? ok(`exploration_sites unreadable by authenticated clients (${error ? 'denied' : '0 rows'})`)
      : bad('site leak', `client read ${data.length} hidden site row(s)!`)
  }
  {
    const { data, error } = await me.from('exploration_discoveries').select('*')
    !error && (data ?? []).length === 0
      ? ok('exploration_discoveries own-row RLS holds (fresh user sees 0 rows)')
      : bad('discoveries RLS', error?.message ?? `${data?.length} row(s) visible`)
  }

  // ── 3) Internal surfaces locked — client-role denial (the verify-m45 ACL idiom, which asserts
  //       via the anon/authenticated clients; no service-role assertion is needed for denials) ────
  console.log('\n3. Internal surfaces locked:')
  for (const [fn, args] of [
    ['exploration_scan', { p_player: ZERO, p_main_ship_id: ZERO, p_request_id: ZERO }],
    ['process_exploration_securing', {}],
    ['osn_distance', { ax: 0, ay: 0, bx: 3, by: 4 }],
  ]) {
    ;(await me.rpc(fn, args)).error ? ok(`${fn} denied to authenticated client`) : bad(`${fn} denied`, 'EXECUTED — hole!')
  }
  for (const [fn, args] of [
    ['command_exploration_scan', { p_main_ship_id: ZERO, p_request_id: ZERO }],
    ['get_my_exploration_discoveries', {}],
  ]) {
    ;(await anon.rpc(fn, args)).error ? ok(`${fn} denied to anon`) : bad(`${fn} anon ACL`, 'anon executed it!')
  }

  // ── 4) Config presence (READ-ONLY — this script never writes game_config) ─────────────────────
  // game_config.value is jsonb (0003): the seeded literals 'false' (0097) / '750' (0099) store as
  // JSON boolean/number, so supabase-js returns JS false / 750 — compare tolerantly of storage form
  // (the server's cfg_bool/cfg_num are storage-form-agnostic the same way).
  console.log('\n4. Config presence:')
  {
    const v = await cfgVal(me, 'exploration_enabled')
    String(v) === 'false' ? ok("exploration_enabled = false (dark)") : bad('exploration_enabled', `reads ${JSON.stringify(v)}`)
  }
  {
    const v = await cfgVal(me, 'exploration_scan_radius')
    Number(v) === 750 ? ok('exploration_scan_radius = 750') : bad('exploration_scan_radius', `reads ${JSON.stringify(v)}`)
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
    console.log(`\nExploration dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
