// MINING-P12 verification — DARK POSTURE + contracts (slices A–G).
//   node scripts/verify-mining.mjs
//
// Proves, with a throwaway authenticated user, that the whole mining surface ships dark and
// locked exactly as migrations 0102–0106 claim:
//   • command_mining_extract → {ok:false, code:'feature_disabled'} (the 0104 wrapper envelope;
//     the writer + wrapper both reject BEFORE any read while mining_enabled='false')
//   • get_my_mining_extractions → {ok:false, reason:'mining_disabled'} (0106 read envelope)
//   • mining_fields leaks NOTHING to clients (RLS with no client policy/grant — 0103)
//   • mining_extractions is own-row-only (a fresh user sees zero rows)
//   • internal surfaces (mining_extract / process_mining_securing) are denied to client roles
//     (osn_distance's denial is verify:exploration's assertion — its slice owns it; not re-asserted)
//   • mining_enabled, mining_extract_radius and mining_extract_cooldown_seconds EXIST and carry a
//     usable value — presence and shape, never a pinned seed (READ-ONLY; see §4 for why)
//
// ⚠ STALE BEYOND §4 — NOT REPAIRED HERE. Sections 1–3 assert the DARK path (command_mining_extract
// → 'feature_disabled', get_my_mining_extractions → 'mining_disabled'), which was correct while
// mining_enabled was seeded false. Migration 0300 LIT mining_enabled, and production reads it true
// today, so those sections now assert a world that no longer exists. Repointing them onto the lit
// path is its own slice: it needs the extract → pending row → cooldown → securing-deposit run this
// header already defers, and this script is not wired into any CI workflow, so nothing regressed
// silently. Do not read a green §1–3 as proof of anything until that repoint lands.
//
// DELIBERATELY NOT COPIED from verify-mainship-send.mjs: its set_game_config flag flip. This
// script NEVER writes game_config and NEVER sets mining_enabled — lit-path verification
// (extract → pending row → cooldown → securing deposit with the flag on) is deferred to the human
// owner's activation checklist (DEV_LOG 2026-07-04 Phase 12 closing entry): flip the flag on a
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
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'minetest', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

async function main() {
  console.log(`\nMining (Phase 12 dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Dark rejection (mining_enabled = 'false'; server-rejected, never UI-only) ──────────────
  console.log('\n1. Dark rejection:')
  {
    // The wrapper gates BEFORE ship resolution (anti-probe), so a zero ship id gets the same answer.
    const { data, error } = await me.rpc('command_mining_extract', { p_main_ship_id: ZERO, p_request_id: ZERO })
    !error && data?.ok === false && data?.code === 'feature_disabled'
      ? ok("command_mining_extract → {ok:false, code:'feature_disabled'}")
      : bad('extract dark rejection', error?.message ?? JSON.stringify(data))
  }
  {
    const { data, error } = await me.rpc('get_my_mining_extractions')
    !error && data?.ok === false && data?.reason === 'mining_disabled'
      ? ok("get_my_mining_extractions → {ok:false, reason:'mining_disabled'}")
      : bad('read dark rejection', error?.message ?? JSON.stringify(data))
  }

  // ── 2) No field leak (hidden until extraction — 0103: RLS enabled, no client policy/grant) ────
  console.log('\n2. No field leak:')
  {
    const { data, error } = await me.from('mining_fields').select('*')
    error || (data ?? []).length === 0
      ? ok(`mining_fields unreadable by authenticated clients (${error ? 'denied' : '0 rows'})`)
      : bad('field leak', `client read ${data.length} hidden field row(s)!`)
  }
  {
    const { data, error } = await me.from('mining_extractions').select('*')
    !error && (data ?? []).length === 0
      ? ok('mining_extractions own-row RLS holds (fresh user sees 0 rows)')
      : bad('extractions RLS', error?.message ?? `${data?.length} row(s) visible`)
  }

  // ── 3) Internal surfaces locked — client-role denial (the verify-m45 ACL idiom, which asserts
  //       via the anon/authenticated clients; no service-role assertion is needed for denials).
  //       osn_distance is deliberately NOT re-asserted here — verify:exploration owns it (0099).
  console.log('\n3. Internal surfaces locked:')
  for (const [fn, args] of [
    ['mining_extract', { p_player: ZERO, p_main_ship_id: ZERO, p_request_id: ZERO }],
    ['process_mining_securing', {}],
  ]) {
    ;(await me.rpc(fn, args)).error ? ok(`${fn} denied to authenticated client`) : bad(`${fn} denied`, 'EXECUTED — hole!')
  }
  for (const [fn, args] of [
    ['command_mining_extract', { p_main_ship_id: ZERO, p_request_id: ZERO }],
    ['get_my_mining_extractions', {}],
  ]) {
    ;(await anon.rpc(fn, args)).error ? ok(`${fn} denied to anon`) : bad(`${fn} anon ACL`, 'anon executed it!')
  }

  // ── 4) Config presence (READ-ONLY — this script never writes game_config) ─────────────────────
  // game_config.value is jsonb (0003), so supabase-js returns a JS boolean/number; compare
  // tolerantly of storage form (the server's cfg_bool/cfg_num are storage-form-agnostic the same
  // way).
  //
  // THESE ASSERT SHAPE, NOT THE SEED. They used to pin the literals 0102 seeded — `mining_enabled`
  // false, `mining_extract_radius` 750, cooldown 300 — and two of the three had gone false: 0300 lit
  // mining_enabled, and production has run the radius at 60 since 2026-07-18. A check that asserts a
  // seed is asserting a WORLD, so it fails on a correct system the moment the owner legitimately
  // retunes it, and it was never testing what its name claimed. What this script OWNS is that the
  // three keys EXIST and carry a usable value; what the value should BE is the owner's decision,
  // recorded in migration 0320 and settable with `node scripts/set-knob.mjs <key> <value>`. Each
  // check prints the live value so a drift is still visible to a human reading the output.
  console.log('\n4. Config presence:')
  {
    const v = await cfgVal(me, 'mining_enabled')
    typeof v === 'boolean'
      ? ok(`mining_enabled present (currently ${v ? 'LIT' : 'dark'})`)
      : bad('mining_enabled', `is not a boolean — reads ${JSON.stringify(v)}`)
  }
  {
    const v = await cfgVal(me, 'mining_extract_radius')
    Number.isFinite(Number(v)) && Number(v) > 0
      ? ok(`mining_extract_radius present and sane (${Number(v)} world units)`)
      : bad('mining_extract_radius', `is not a positive number — reads ${JSON.stringify(v)}`)
  }
  {
    const v = await cfgVal(me, 'mining_extract_cooldown_seconds')
    Number.isFinite(Number(v)) && Number(v) >= 0
      ? ok(`mining_extract_cooldown_seconds present and sane (${Number(v)}s)`)
      : bad('mining_extract_cooldown_seconds', `is not a non-negative number — reads ${JSON.stringify(v)}`)
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
    console.log(`\nMining dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
