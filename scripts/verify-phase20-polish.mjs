// PHASE20-POLISH verification — DARK POSTURE + contracts (slices 1–4, migrations 0139–0142).
//   node scripts/verify-phase20-polish.mjs
//
// Proves, with anon/authenticated clients only, that the whole Phase-20 polish surface ships dark and
// locked exactly as migrations 0139–0142 claim:
//   • World Events schema (0139): world_events is a server-only table (RLS on, no client policy/grant).
//   • World Events writers (0140): world_events_publish / world_events_set_active are service-role-only
//     (client-revoked), idempotent via a nullable-unique dedup_key; both no-op while dark.
//   • World Events read surface (0141): get_world_events is authenticated-only and FAIL-CLOSED — while
//     phase20_polish_enabled is false it returns { ok:true, events:[] } without reading the table.
//   • UI asset vocabulary (0142): ui_asset_catalog is server-only static Reference/Config (seed-only, no
//     runtime writer); get_ui_asset_catalog is authenticated-only and fail-closed → empty while dark.
// The whole surface is gated by the phase20_polish_enabled master flag (still 'false').
//
// NO-FLAG-WRITE / NO-LIT-PATH stance carried VERBATIM from verify-world-balance.mjs (the verify:ranking
// mechanism): this script NEVER writes game_config and NEVER flips phase20_polish_enabled. The surface
// exercises NO lit path at all — lit-path verification (flag on → world_events_publish a scoped event →
// get_world_events returns it with its resolved severity icon; retire via world_events_set_active) is
// DEFERRED to the human owner's activation checklist: flip the flag on a DEV database and run the lit
// checks there, never here.
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
const createdUserIds = []
const newUser = createUserFactory({ url, anonKey, emailPrefix: 'phase20', createdUserIds })

// game_config is public-read (0003); same query shape as the siblings' cfgVal, via the CLIENT role
// and strictly read-only (this script owns no set_game_config path at all).
const cfgVal = async (client, k) => (await client.from('game_config').select('value').eq('key', k).maybeSingle()).data?.value

async function main() {
  console.log(`\nPhase 20 Polish (dark posture) verification against ${url}\n`)
  const u = await newUser('a')
  const me = u.client
  ok('signed up throwaway user')

  // ── 1) Config presence (READ-ONLY — this script never writes game_config) ─────────────────────────
  // game_config.value is jsonb (0003): 'false' stores as a JSON boolean, so supabase-js returns JS
  // false — compare tolerantly of storage form via String() (the server's cfg_bool is storage-agnostic).
  console.log('\n1. Config presence:')
  {
    const v = await cfgVal(me, 'phase20_polish_enabled')
    String(v) === 'false' ? ok('phase20_polish_enabled = false (dark master gate)') : bad('phase20_polish_enabled', `reads ${JSON.stringify(v)}`)
  }

  // ── 2) Read surfaces dark + ACL-correct (0141 get_world_events, 0142 get_ui_asset_catalog) ────────
  // Authenticated: each returns ok:true with an EMPTY list (flag-gated fail-closed → empty while dark,
  // without reading the table). Anon: DENIED (granted to authenticated only, revoked from anon/public).
  console.log('\n2. Read surfaces dark + ACL-correct:')
  {
    const { data, error } = await me.rpc('get_world_events', { p_location_id: null, p_zone_id: null })
    if (error) bad('get_world_events authenticated', error.message)
    else (data?.ok === true && Array.isArray(data.events) && data.events.length === 0)
      ? ok('get_world_events → ok:true, empty events (fail-closed while dark)')
      : bad('get_world_events dark shape', `got ${JSON.stringify(data)}`)
    ;(await anon.rpc('get_world_events', { p_location_id: null, p_zone_id: null })).error
      ? ok('get_world_events denied to anon (authenticated-only)')
      : bad('get_world_events anon ACL', 'anon executed it!')
  }
  {
    const { data, error } = await me.rpc('get_ui_asset_catalog', { p_asset_kind: null })
    if (error) bad('get_ui_asset_catalog authenticated', error.message)
    else (data?.ok === true && Array.isArray(data.assets) && data.assets.length === 0)
      ? ok('get_ui_asset_catalog → ok:true, empty assets (fail-closed while dark)')
      : bad('get_ui_asset_catalog dark shape', `got ${JSON.stringify(data)}`)
    ;(await anon.rpc('get_ui_asset_catalog', { p_asset_kind: null })).error
      ? ok('get_ui_asset_catalog denied to anon (authenticated-only)')
      : bad('get_ui_asset_catalog anon ACL', 'anon executed it!')
  }

  // ── 3) World Events writers locked (service-role-only ACL — 0140) ─────────────────────────────────
  // VALID-shaped args (full arg set / random uuid) so the denial proves the LOCK, not argument
  // validation. Both writers are granted to service_role ONLY (revoked from public/anon/authenticated),
  // so a client call must error for BOTH authenticated and anon.
  console.log('\n3. World Events writers locked:')
  const lockedFns = [
    ['world_events_publish', {
      p_event_type: 'notice', p_scope: 'global', p_zone_id: null, p_location_id: null,
      p_title: 'verify', p_body: null, p_severity: 'info',
      p_starts_at: '2026-01-01T00:00:00Z', p_ends_at: null, p_dedup_key: null,
    }],
    ['world_events_set_active', { p_event_id: randomUUID(), p_is_active: false }],
  ]
  for (const [fn, args] of lockedFns) {
    ;(await me.rpc(fn, args)).error
      ? ok(`${fn} denied to authenticated client`)
      : bad(`${fn} denied`, 'EXECUTED — hole!')
    ;(await anon.rpc(fn, args)).error
      ? ok(`${fn} denied to anon`)
      : bad(`${fn} anon ACL`, 'anon executed it!')
  }

  // ── 4) world_events is server-only (0139 — RLS on, no client policy/grant; the mining_fields posture) ─
  console.log('\n4. world_events server-only:')
  {
    // Authenticated + anon SELECT both denied (no client read grant/policy). A fresh DB carries no rows
    // regardless — denial is the posture proof (the only client path is the flag-gated get_world_events).
    ;(await me.from('world_events').select('*')).error
      ? ok('authenticated SELECT on world_events denied (server-only)')
      : bad('world_events auth read', 'authenticated SELECT permitted — should be server-only!')
    ;(await anon.from('world_events').select('*')).error
      ? ok('anon SELECT on world_events denied (server-only)')
      : bad('world_events anon read', 'anon SELECT permitted — should be server-only!')
  }
  {
    // No client write path — the sole writers are world_events_publish / world_events_set_active.
    const row = { event_type: 'notice', scope: 'global', title: `p20-verify-${randomUUID()}` }
    ;(await me.from('world_events').insert(row)).error
      ? ok('world_events insert denied to authenticated client')
      : bad('world_events write path', 'INSERTED — hole!')
  }

  // ── 5) ui_asset_catalog is server-only, still static — no runtime writer added (0142 law) ──────────
  console.log('\n5. ui_asset_catalog server-only, still static:')
  {
    // Authenticated + anon SELECT both denied (no client read grant/policy — the world_events/mining_fields
    // posture). The only client path is the flag-gated get_ui_asset_catalog.
    ;(await me.from('ui_asset_catalog').select('*')).error
      ? ok('authenticated SELECT on ui_asset_catalog denied (server-only)')
      : bad('ui_asset_catalog auth read', 'authenticated SELECT permitted — should be server-only!')
    ;(await anon.from('ui_asset_catalog').select('*')).error
      ? ok('anon SELECT on ui_asset_catalog denied (server-only)')
      : bad('ui_asset_catalog anon read', 'anon SELECT permitted — should be server-only!')
  }
  {
    // No client write path — the catalog is seed-migration-only Reference/Config; Phase 20 added no
    // runtime writer. A direct authenticated INSERT is denied.
    const row = { asset_kind: 'icon', asset_key: `p20-verify-${randomUUID()}`, display_name: 'verify', asset_ref: 'icon.verify' }
    ;(await me.from('ui_asset_catalog').insert(row)).error
      ? ok('ui_asset_catalog insert denied to authenticated client (still static)')
      : bad('ui_asset_catalog write path', 'INSERTED — hole!')
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
    console.log(`\nPhase 20 Polish dark posture: ${counts.pass} passed, ${counts.fail} failed\n`)
    process.exitCode = counts.fail > 0 ? 1 : 0
  })
