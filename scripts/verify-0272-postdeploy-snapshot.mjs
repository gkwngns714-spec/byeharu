// ════════════════════════════════════════════════════════════════════════════════════════════════════
// MIGRATION 0272 — READ-ONLY POST-DEPLOYMENT SNAPSHOT (anon key / PostgREST)
//
// ██ READ-ONLY. Every request this file makes is an HTTP GET against PostgREST. There is no POST,
// ██ PATCH, PUT, DELETE or RPC call anywhere in it. It writes NOTHING to the database, flips NO flag,
// ██ activates NO binding, cleans up NO runtime state, and does NOT deploy or approve anything. Its
// ██ only side effect is an optional local JSON file (--out). SAFE to point at production.
//
//   node scripts/verify-0272-postdeploy-snapshot.mjs --phase before --out /tmp/pd0272.before.json
//   …the owner releases the deployment gate (a separate, human act this file never performs)…
//   node scripts/verify-0272-postdeploy-snapshot.mjs --phase after  --out /tmp/pd0272.after.json
//   node scripts/verify-0272-postdeploy-snapshot.mjs --diff /tmp/pd0272.before.json /tmp/pd0272.after.json
//
// ── WHY THIS EXISTS ALONGSIDE THE .sql (the decision, and its honest limit) ────────────────────────
// scripts/verify-0272-postdeploy.sql is the COMPLETE verifier, but it needs a DB_URL — a psql/SQL-editor
// session as a role that can read pg_proc, supabase_migrations.schema_migrations and combat_encounters.
// The anon key is the credential that is actually to hand on a dev machine, and it can read the ENTIRE
// encounter-content chain plus game_config plus encounter_runtime_state (all four are public-select by
// design — 0260 grants `select` on encounter_runtime_state to anon/authenticated while revoking every
// write). So this file settles the CONTENT + CONFIG + RUNTIME-STATE half of the verification with the
// credential you have, and states — precisely, as SQL you can paste — the half it cannot settle.
//
// ── WHAT THIS FILE CANNOT SETTLE (RLS / catalog, anon returns [] or 404) ──────────────────────────
//   (1) the migration head              → supabase_migrations.schema_migrations is not exposed
//   (2) the deployed function bodies    → pg_proc is not exposed
//   (3) whether any encounter is live   → combat_encounters / combat_units are RLS-blocked to anon
// For each, the exact statement the OWNER must run as service_role (or in the Supabase SQL editor) is
// printed at the end of every run under OWNER-MUST-RUN. Nothing here silently assumes them.
//
// ── MARKERS ───────────────────────────────────────────────────────────────────────────────────────
//   PD0272S_FINDING [BLOCK|WARN|INFO] <code> …
//   PD0272S_PASS phase=<p>            / PD0272S_BLOCKED phase=<p> n=<N>   (exit 1)
//   PD0272S_DIFF_PASS / PD0272S_DIFF_FAIL
// ════════════════════════════════════════════════════════════════════════════════════════════════════

import { readFileSync, writeFileSync } from 'node:fs'
import { resolveEnv } from './lib/verify-harness.mjs'

const argv = process.argv.slice(2)
const argOf = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt }

// ── expectations. Every one is overridable from the environment so the file never has to be edited.
const EXPECT = {
  eliteKey: 'encounter_elite_difficulty_multiplier',
  eliteValue: process.env.PD0272_ELITE_MULTIPLIER ?? '2',
  canaryBinding: process.env.PD0272_CANARY_BINDING ?? '2f7bcf88-d810-47b4-8e04-748655688b55',
  otherBinding: process.env.PD0272_OTHER_BINDING ?? '2d491cde-e6fa-4087-8e80-3029522731cd',
  runtimeLocation: process.env.PD0272_RUNTIME_LOCATION ?? '75baf5d7-6b06-4567-84c9-de97938aa251',
  runtimeProfile: process.env.PD0272_RUNTIME_PROFILE ?? '4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9',
  runtimeLastSpawnAt: process.env.PD0272_RUNTIME_LAST_SPAWN_AT ?? '2026-07-22T06:03:27.318703+00:00',
  runtimeActiveCount: process.env.PD0272_RUNTIME_ACTIVE_COUNT ?? '2',
}

// key → expected value. The pirate-intercept flag and its four tuning knobs are INTENDED per migration
// 0236: they are pinned here so an unrelated deployment moving them is caught, and they are NEVER
// reported as defects at their intended values.
const CONFIG_EXPECT = [
  ['encounter_resolver_enabled', 'false', 'PD04_RESOLVER_FLAG'],
  ['enemy_content_registry_enabled', 'true', 'PD05_AUTHORING_FLAG'],
  ['encounter_authoring_enabled', 'true', 'PD05_AUTHORING_FLAG'],
  ['encounter_binding_authoring_enabled', 'true', 'PD05_AUTHORING_FLAG'],
  ['spatial_combat_enabled', 'true', 'PD06_SPATIAL_COMBAT'],
  ['fleet_movement_unified_enabled', 'true', 'PD07_MOVEMENT_FLAG'],
  ['mainship_send_enabled', 'false', 'PD07_MOVEMENT_FLAG'],
  ['mainship_space_movement_enabled', 'false', 'PD07_MOVEMENT_FLAG'],
  ['mainship_coordinate_travel_enabled', 'false', 'PD07_MOVEMENT_FLAG'],
  ['fleet_control_enabled', 'false', 'PD07_MOVEMENT_FLAG'],
  ['timed_docking_enabled', 'false', 'PD07_MOVEMENT_FLAG'],
  ['pirate_intercept_enabled', 'true', 'PD08_INTERCEPT'],
  ['pirate_intercept_base_risk', '1.0', 'PD08_INTERCEPT_KNOB'],
  ['pirate_intercept_min_risk', '0.98', 'PD08_INTERCEPT_KNOB'],
  ['pirate_intercept_max_risk', '1.0', 'PD08_INTERCEPT_KNOB'],
  ['pirate_intercept_exposure_floor', '1.0', 'PD08_INTERCEPT_KNOB'],
]

const OWNER_MUST_RUN = [
  ['migration head (before must be 20260618000271, after exactly 20260618000272, nothing beyond)',
   'select max(version) as head, count(*) as applied,\n' +
   '       (select count(*) from supabase_migrations.schema_migrations where version > \'20260618000272\') as beyond_0272\n' +
   '  from supabase_migrations.schema_migrations;'],
  ['the DEPLOYED body of the one function 0272 re-creates (a version number proves nothing about WHICH body landed)',
   'select md5(prosrc) as body_md5,\n' +
   '       position(\'multiplier_v1\' in prosrc) > 0 as has_0272_elite_policy,\n' +
   '       position(\'encounter_elite_difficulty_multiplier\' in prosrc) > 0 as reads_multiplier,\n' +
   '       position(\'disabled_v1\' in prosrc) > 0 as still_0261\n' +
   '  from pg_proc where oid = \'public.resolve_location_encounter(uuid,text)\'::regprocedure;'],
  ['proof 0272 did NOT touch the tick — this md5 must be IDENTICAL before and after the deployment',
   'select md5(prosrc) from pg_proc where oid = \'public.process_combat_ticks()\'::regprocedure;'],
  ['whether the residual runtime-state row corresponds to encounters that are still LIVE (the ONE read that settles the classification)',
   'select ce.id, ce.status, ce.created_at, ce.updated_at, ce.player_id,\n' +
   '       ce.resolved_plan_json->>\'encounter_profile_id\' as profile_id\n' +
   '  from public.combat_encounters ce\n' +
   ' where ce.location_id = \'' + EXPECT.runtimeLocation + '\'\n' +
   '   and ce.resolved_plan_json->>\'encounter_profile_id\' = \'' + EXPECT.runtimeProfile + '\'\n' +
   ' order by ce.created_at;\n' +
   '-- The classification hinges on: how many of these rows are in status active/retreating?\n' +
   '--   0 live  -> the residual row is HISTORICAL-HARMLESS (the expected answer)\n' +
   '--   >0 live -> the DERIVED cap is already consumed and a canary would be suppressed'],
  ['the same question for EVERY location, so no other binding has unexplained live runtime state',
   'select ce.location_id, ce.resolved_plan_json->>\'encounter_profile_id\' as profile_id,\n' +
   '       ce.status, count(*)\n' +
   '  from public.combat_encounters ce\n' +
   ' where ce.resolved_plan_json is not null\n' +
   ' group by 1,2,3 order by 1,2,3;'],
]

const { url, anonKey } = resolveEnv()
const H = { apikey: anonKey, Authorization: `Bearer ${anonKey}`, Accept: 'application/json' }

// The ONLY network verb in this file.
async function get(path) {
  const res = await fetch(`${url}/rest/v1/${path}`, { method: 'GET', headers: H })
  const body = await res.text()
  if (!res.ok) throw new Error(`GET ${path} -> ${res.status} ${body.slice(0, 300)}`)
  return JSON.parse(body)
}

const findings = { block: 0, warn: 0 }
const block = (code, msg) => { findings.block++; console.log(`PD0272S_FINDING [BLOCK] ${code} :: ${msg}`) }
const warn = (code, msg) => { findings.warn++; console.log(`PD0272S_FINDING [WARN] ${code} :: ${msg}`) }
const info = (code, msg) => console.log(`PD0272S_FINDING [INFO] ${code} :: ${msg}`)

// jsonb scalars come back already decoded by PostgREST; normalise to a stable string.
const s = (v) => (v === null || v === undefined ? '(absent)' : typeof v === 'object' ? JSON.stringify(v) : String(v))
const numEq = (a, b) => /^-?\d+(\.\d+)?$/.test(a) && /^-?\d+(\.\d+)?$/.test(b) && Number(a) === Number(b)

// ── the snapshot: every value is bucketed as expected_to_change or must_not_change ────────────────
async function snapshot() {
  const snap = { expected_to_change: {}, must_not_change: {} }
  const E = snap.expected_to_change
  const M = snap.must_not_change

  const cfg = await get('game_config?select=key,value&order=key')
  const cfgMap = new Map(cfg.map((r) => [r.key, r.value]))
  E[`cfg.${EXPECT.eliteKey}`] = s(cfgMap.get(EXPECT.eliteKey))
  E['cfg.row_count'] = String(cfg.length)
  for (const [k] of CONFIG_EXPECT) M[`cfg.${k}`] = s(cfgMap.get(k))

  const bindings = await get('location_encounter_bindings?select=id,location_id,encounter_profile_id,active,revision,weight&order=id')
  M['binding.row_count'] = String(bindings.length)
  for (const b of bindings) {
    M[`binding.${b.id}`] = `active:${b.active}|revision:${b.revision}|weight:${b.weight}|profile:${b.encounter_profile_id}|location:${b.location_id}`
  }

  const profiles = await get('encounter_profiles?select=id,key,active,revision,active_encounter_cap,cooldown_seconds,reward_override_id&order=key')
  for (const p of profiles) {
    M[`encounter_profile.${p.key}`] = `id:${p.id}|active:${p.active}|revision:${p.revision}|cap:${p.active_encounter_cap}|cooldown_s:${p.cooldown_seconds}|reward_override:${s(p.reward_override_id)}`
  }
  const pmembers = await get('encounter_profile_members?select=id,encounter_profile_id,fleet_template_id,weight&order=id')
  for (const m of pmembers) M[`encounter_profile_member.${m.id}`] = `profile:${m.encounter_profile_id}|template:${m.fleet_template_id}|weight:${m.weight}`

  const templates = await get('enemy_fleet_templates?select=id,key,active,revision&order=key')
  for (const t of templates) M[`fleet_template.${t.key}`] = `id:${t.id}|active:${t.active}|revision:${t.revision}`

  const tmembers = await get('enemy_fleet_template_members?select=id,fleet_template_id,enemy_archetype_id,min_count,max_count,weight,elite_chance&order=id')
  M['template_member.row_count'] = String(tmembers.length)
  M['template_member.elite_nonzero'] = String(tmembers.filter((m) => Number(m.elite_chance ?? 0) > 0).length)
  for (const m of tmembers) {
    M[`template_member.${m.id}`] = `min:${m.min_count}|max:${m.max_count}|weight:${m.weight}|elite_chance:${m.elite_chance}|template:${m.fleet_template_id}|archetype:${m.enemy_archetype_id}`
  }

  const archetypes = await get('enemy_archetypes?select=id,key,active,revision,base_difficulty,unit_type_id,behavior_key,stat_overrides,default_reward_profile_id&order=key')
  for (const a of archetypes) {
    M[`archetype.${a.key}`] = `id:${a.id}|active:${a.active}|revision:${a.revision}|base_difficulty:${a.base_difficulty}|unit_type:${a.unit_type_id}|behavior:${a.behavior_key}|stat_overrides:${s(a.stat_overrides)}|default_reward:${s(a.default_reward_profile_id)}`
  }

  const rewards = await get('reward_profiles?select=id,key,active,revision,resource_grants&order=key')
  for (const r of rewards) M[`reward_profile.${r.key}`] = `id:${r.id}|active:${r.active}|revision:${r.revision}|grants:${s(r.resource_grants)}`

  const rts = await get('encounter_runtime_state?select=location_id,encounter_profile_id,last_spawn_at,active_count&order=location_id,encounter_profile_id')
  M['runtime_state.row_count'] = String(rts.length)
  for (const r of rts) M[`runtime_state.${r.location_id}|${r.encounter_profile_id}`] = `last_spawn_at:${r.last_spawn_at}|active_count:${r.active_count}`

  return { snap, cfgMap, bindings, tmembers, rts }
}

function assertPosture(phase, { snap, cfgMap, bindings, tmembers, rts }) {
  // ── PD03 the ONE intended config delta ─────────────────────────────────────────────────────────
  const eliteRaw = cfgMap.get(EXPECT.eliteKey)
  const elitePresent = cfgMap.has(EXPECT.eliteKey)
  if (phase === 'before') {
    if (elitePresent) block('PD03_BEFORE_KEY_PRESENT', `${EXPECT.eliteKey} already exists (=${s(eliteRaw)}) — 0272 has already been applied; this is not a pre-deploy state`)
    else info('PD03_BEFORE_KEY_ABSENT', `${EXPECT.eliteKey} is absent — the independent proof, needing no catalog access, that 0272 has NOT been applied`)
  } else {
    if (!elitePresent) block('PD03_KEY_MISSING', `${EXPECT.eliteKey} is ABSENT after the deployment — 0272 section 1 did not land`)
    else if (s(eliteRaw) !== EXPECT.eliteValue && !numEq(s(eliteRaw), EXPECT.eliteValue)) block('PD03_VALUE', `${EXPECT.eliteKey} = ${s(eliteRaw)} (want ${EXPECT.eliteValue}); 0272 seeds on-conflict-do-nothing, so a differing value means a pre-existing or hand-tuned row`)
    else info('PD03_KEY_OK', `${EXPECT.eliteKey} = ${s(eliteRaw)} — the additive elite multiplier landed with its expected value`)
  }

  // ── PD04..PD08 configuration unchanged ─────────────────────────────────────────────────────────
  for (const [k, want, code] of CONFIG_EXPECT) {
    if (!cfgMap.has(k)) { block(`${code}_MISSING`, `game_config key ${k} is absent`); continue }
    const got = s(cfgMap.get(k))
    if (got !== want && !numEq(got, want)) block(code, `${k} = ${got} (want ${want}) — this flag/knob MOVED; 0272 changes no configuration except the additive elite multiplier`)
  }
  info('PD04_PD08_CONFIG', `${CONFIG_EXPECT.length} configuration key(s) checked and captured in the digest`)

  // ── PD09 bindings ──────────────────────────────────────────────────────────────────────────────
  const bindingBlocksBefore = findings.block
  if (bindings.length !== 2) block('PD09_BINDING_COUNT', `${bindings.length} binding(s) exist (want 2) — the binding set changed`)
  for (const b of bindings) {
    if (b.active) block('PD09_BINDING_ACTIVE', `binding ${b.id} is ACTIVE — 0272 activates nothing and the post-canary posture is both bindings inactive`)
    if (b.revision !== 2) block('PD09_BINDING_REVISION', `binding ${b.id} revision ${b.revision} (want 2) — the binding was edited`)
    if (![EXPECT.canaryBinding, EXPECT.otherBinding].includes(b.id)) block('PD09_BINDING_UNEXPECTED', `binding ${b.id} was not in the reviewed set`)
  }
  for (const id of [EXPECT.canaryBinding, EXPECT.otherBinding]) {
    if (!bindings.some((b) => b.id === id)) block('PD09_BINDING_MISSING', `expected binding ${id} disappeared`)
  }
  if (findings.block === bindingBlocksBefore) info('PD09_BINDINGS', `${bindings.length} binding(s): all present, all inactive, all revision 2`)

  // ── PD10 elite_chance authored nowhere ─────────────────────────────────────────────────────────
  const elite = tmembers.filter((m) => Number(m.elite_chance ?? 0) > 0)
  if (elite.length > 0) block('PD10_ELITE_CHANCE_AUTHORED', `${elite.length} enemy_fleet_template_members row(s) carry elite_chance > 0 (${elite.map((m) => m.id).join(', ')}). 0272 WIRES elite but AUTHORS nothing — authoring elite content is a separate, owner-gated act.`)
  else info('PD10_ELITE_CHANCE', `0 of ${tmembers.length} template member(s) carry elite_chance > 0 (unchanged)`)

  // ── PD12 runtime state ─────────────────────────────────────────────────────────────────────────
  if (rts.length !== 1) block('PD12_ROW_COUNT', `encounter_runtime_state holds ${rts.length} row(s) (want 1). Deploying 0272 cannot create or remove one — the single function it re-creates only READS the table.`)
  const row = rts.find((r) => r.location_id === EXPECT.runtimeLocation && r.encounter_profile_id === EXPECT.runtimeProfile)
  if (!row) {
    block('PD12_RESIDUAL_ROW_GONE', `the known residual (${EXPECT.runtimeLocation}, ${EXPECT.runtimeProfile}) row is gone. NOTHING in the repository ever deletes an encounter_runtime_state row, so its disappearance means an out-of-band write.`)
  } else {
    info('PD12_RESIDUAL_ROW', `last_spawn_at=${row.last_spawn_at} active_count=${row.active_count} — active_count is a CUMULATIVE spawn counter (only ever incremented; there is NO decrement anywhere in the repository) and is NOT the cap authority. Only last_spawn_at is load-bearing, as the cooldown anchor.`)
    if (EXPECT.runtimeLastSpawnAt && new Date(row.last_spawn_at).getTime() !== new Date(EXPECT.runtimeLastSpawnAt).getTime()) {
      block('PD12_LAST_SPAWN_MOVED', `last_spawn_at is ${row.last_spawn_at}, expected ${EXPECT.runtimeLastSpawnAt} — a fresh encounter resolution happened while the resolver is supposed to be dark`)
    }
    if (String(row.active_count) !== EXPECT.runtimeActiveCount) {
      block('PD12_ACTIVE_COUNT_MOVED', `active_count is ${row.active_count}, expected ${EXPECT.runtimeActiveCount} — it is incremented ONLY by the resolved-spawn arm of process_combat_ticks at first resolution, so a change means the resolver spawned`)
    }
    // the cooldown reading: the ONLY way this row can affect behaviour.
    const profile = snap.must_not_change['encounter_profile.canary_encounter'] ?? ''
    const cd = Number((profile.match(/cooldown_s:(\d+)/) ?? [, '0'])[1])
    const elapsed = (Date.now() - new Date(row.last_spawn_at).getTime()) / 1000
    if (cd > 0 && elapsed < cd) warn('PD12_COOLDOWN_LIVE', `the residual last_spawn_at is INSIDE the ${cd}s cooldown window (elapsed ${elapsed.toFixed(0)}s) — it WOULD suppress the next spawn of this profile`)
    else info('PD12_COOLDOWN_EXPIRED', `elapsed ${Math.round(elapsed)}s since last_spawn_at vs a ${cd}s cooldown — the row's ONLY load-bearing effect has long since lapsed, so it cannot suppress a spawn`)
  }

  // ── PD13: not settleable with the anon key. Say so; never assume it. ───────────────────────────
  warn('PD13_LIVE_ENCOUNTERS_UNKNOWN', 'combat_encounters is RLS-blocked to anon (a select returns []), so THIS RUN CANNOT prove whether any resolved encounter is still live. See OWNER-MUST-RUN #4. Do not read the empty result as "no live encounters".')
  warn('PD01_PD02_CATALOG_UNKNOWN', 'supabase_migrations.schema_migrations and pg_proc are not exposed over PostgREST, so THIS RUN CANNOT prove the migration head or which function body is deployed. See OWNER-MUST-RUN #1-#3, or run scripts/verify-0272-postdeploy.sql with a DB_URL.')
}

function printOwnerMustRun() {
  console.log('\n════════ OWNER-MUST-RUN — the reads this anon-key run CANNOT perform ════════')
  console.log('Run these as service_role (Supabase SQL editor or psql). All are SELECTs; none writes.\n')
  OWNER_MUST_RUN.forEach(([why, sql], i) => {
    console.log(`── #${i + 1} ${why}`)
    console.log(sql.split('\n').map((l) => `   ${l}`).join('\n'))
    console.log('')
  })
  console.log('Or, for all of the above at once with a DB_URL:')
  console.log('   DB_URL="postgres://…" ./scripts/verify-0272-postdeploy.sh before   # then, after the deploy:')
  console.log('   DB_URL="postgres://…" ./scripts/verify-0272-postdeploy.sh after')
  console.log('   ./scripts/verify-0272-postdeploy.sh diff <before.log> <after.log>\n')
}

// ── diff mode: pure local JSON, no network ────────────────────────────────────────────────────────
function runDiff(a, b) {
  const A = JSON.parse(readFileSync(a, 'utf8'))
  const B = JSON.parse(readFileSync(b, 'utf8'))
  let moved = 0
  let intended = 0
  const keys = [...new Set([...Object.keys(A.must_not_change), ...Object.keys(B.must_not_change)])].sort()
  console.log('── must_not_change.* — ANY difference here is a defect ─────────────────────────────')
  for (const k of keys) {
    const x = A.must_not_change[k]
    const y = B.must_not_change[k]
    if (x !== y) { moved++; console.log(`  MOVED ${k}\n    before: ${s(x)}\n    after : ${s(y)}`) }
  }
  if (moved === 0) console.log('  ok: every must_not_change.* value is byte-identical across the deployment')
  console.log('\n── expected_to_change.* — these SHOULD differ (the evidence 0272 landed) ────────────')
  for (const k of [...new Set([...Object.keys(A.expected_to_change), ...Object.keys(B.expected_to_change)])].sort()) {
    const x = A.expected_to_change[k]
    const y = B.expected_to_change[k]
    console.log(`  ${x === y ? 'same ' : 'moved'} ${k}: ${s(x)} -> ${s(y)}`)
    if (x !== y) intended++
  }
  console.log('')
  if (moved === 0 && intended > 0) { console.log(`PD0272S_DIFF_PASS — ${intended} intended value(s) moved, 0 unintended. Nothing was written.`); return 0 }
  if (intended === 0) console.log('PD0272S_DIFF_FAIL — nothing changed at all: the deployment did not land, or both snapshots are the same phase')
  if (moved > 0) console.log(`PD0272S_DIFF_FAIL — ${moved} must_not_change.* value(s) MOVED across the deployment`)
  return 1
}

async function main() {
  if (argv[0] === '--diff') {
    const a = argv[1]
    const b = argv[2]
    if (!a || !b) { console.error('usage: --diff <before.json> <after.json>'); process.exit(2) }
    process.exit(runDiff(a, b))
  }

  const phase = (argOf('--phase', 'after') || 'after').toLowerCase()
  if (!['before', 'after'].includes(phase)) { console.error('--phase must be before|after'); process.exit(2) }

  console.log(`\n════════ MIGRATION 0272 POST-DEPLOYMENT SNAPSHOT — READ-ONLY (anon key) ════════`)
  console.log(`target : ${url}`)
  console.log(`phase  : ${phase}`)
  console.log(`now    : ${new Date().toISOString()}`)
  console.log('NOTHING IS WRITTEN TO THE DATABASE BY THIS FILE.\n')

  const data = await snapshot()
  assertPosture(phase, data)

  const out = argOf('--out')
  if (out) {
    writeFileSync(out, JSON.stringify({ phase, captured_at: new Date().toISOString(), url, ...data.snap }, null, 2))
    console.log(`\nsnapshot written to ${out}`)
  } else {
    console.log('\n(no --out given; pass --out <file.json> to capture this phase for the BEFORE/AFTER diff)')
  }

  printOwnerMustRun()

  if (findings.block === 0) {
    console.log(`PD0272S_PASS phase=${phase} blockers=0 warnings=${findings.warn} — the anon-readable posture is exactly as required. Nothing was written.`)
    console.log('A single PASS proves POSTURE, not "unchanged": capture BOTH phases with --out and run --diff.')
    process.exit(0)
  }
  console.log(`PD0272S_BLOCKED phase=${phase} n=${findings.block} warnings=${findings.warn} — see every PD0272S_FINDING [BLOCK] line above. Nothing was written.`)
  process.exit(1)
}

main().catch((e) => { console.error('PD0272S_ERROR', e.message); process.exit(2) })
