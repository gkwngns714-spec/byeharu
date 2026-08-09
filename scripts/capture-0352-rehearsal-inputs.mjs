#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════════════════════════
// CAPTURE the inputs scripts/sortie-home-0352-rehearsal.mjs runs against — READ-ONLY, from the
// live database. Two artefacts, neither committed:
//
//   .0352-inputs/fixture-schema.sql     — CREATE TABLE for the tables the rehearsal needs, built
//                                         from information_schema + pg_constraint + pg_indexes, so
//                                         the CHECKs and unique indexes are the REAL ones.
//   .0352-inputs/deployed-bodies.json   — pg_get_functiondef() for every function the rehearsal
//                                         creates, VERBATIM. Retyping one would rehearse a function
//                                         that does not exist.
//
//   node scripts/capture-0352-rehearsal-inputs.mjs            # writes scripts/.0352-inputs/
//   node scripts/capture-0352-rehearsal-inputs.mjs --out DIR
//
// WHY NOT COMMIT THEM. The live engine is the authority. A checked-in copy is a second one, and it
// drifts silently the first time any migration re-emits one of these bodies — at which point the
// rehearsal would go on passing against a function nobody runs. Re-capture before every run; it
// costs one read-only round trip.
//
// It reads SUPABASE_PROJECT_ID + SUPABASE_ACCESS_TOKEN from .env.local (git-ignored) and issues ONE
// query, wrapped in `begin; set transaction read only; … rollback;`.
// ═══════════════════════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.dirname(HERE);
const outArg = process.argv.indexOf('--out');
const OUT = outArg !== -1 ? process.argv[outArg + 1] : path.join(HERE, '.0352-inputs');
const envArg = process.argv.indexOf('--env');
const ENVFILE = envArg !== -1 ? process.argv[envArg + 1] : path.join(REPO, '.env.local');

const env = Object.fromEntries(
  readFileSync(ENVFILE, 'utf8').split(/\r?\n/)
    .filter((l) => l.trim() && !l.trim().startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
if (!env.SUPABASE_PROJECT_ID || !env.SUPABASE_ACCESS_TOKEN) {
  console.error(`${ENVFILE} must carry SUPABASE_PROJECT_ID and SUPABASE_ACCESS_TOKEN`);
  process.exit(2);
}

// Every function the rehearsal creates. The three surgery targets, the resolver, everything the
// migration's own asserts inspect, and everything the scenarios actually CALL.
const FUNCTIONS = [
  'cfg_num', 'cfg_bool', 'fleet_is_live', 'fleet_sortie_still_speaks', 'osn_distance', 'set_game_config',
  'nohome_dock_returning_ship', 'send_ship_group_hunt', 'command_ship_group_go', 'assign_ship_to_group',
  'process_combat_ticks', 'presence_request_leave', 'combat_flee_pending',
  'pirate_intercept_resolve_due_for_movement', 'movement_settle_arrival', 'fleet_complete',
  'fleet_set_in_space', 'process_mainship_expeditions', 'group_sortie_release', 'mainship_resolve_fleet',
  'fleet_create', 'port_entry_commission_build', 'get_or_create_store', 'initialize_new_player',
  'presence_create', 'presence_complete', 'mainship_mark_docked_at_location', 'is_home_port_eligible',
  'worldstate_register_presence', 'worldstate_unregister_presence', 'activity_start',
];
// Tables in dependency order. `pending_encounters` is here only because combat_flee_pending declares
// a %rowtype over it — plpgsql resolves DECLARE types at CREATE time, so the table must exist even
// though nothing in the rehearsal reads a row from it.
const TABLES = [
  'sectors', 'zones', 'locations', 'location_state', 'game_config', 'main_ship_hull_types', 'ship_groups',
  'bases', 'main_ship_instances', 'fleets', 'fleet_units', 'fleet_movements', 'group_sortie_members',
  'location_presence', 'space_anchors', 'location_services', 'danger_zones', 'combat_encounters',
  'combat_units', 'player_wallet', 'pirate_intercepts', 'fleet_route_legs', 'reward_grants',
  'pending_encounters',
];

const lit = (a) => a.map((x) => `'${x}'`).join(',');
const sql = `
select jsonb_build_object(
  'fns', (select jsonb_object_agg(k, d) from (
      select p.proname || '#' || pg_get_function_identity_arguments(p.oid) k, pg_get_functiondef(p.oid) d
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prokind = 'f' and p.proname in (${lit(FUNCTIONS)})) t),
  'cols', (select jsonb_object_agg(table_name, cols) from (
      select table_name, jsonb_agg(jsonb_build_object(
               'n', column_name,
               't', case when data_type = 'USER-DEFINED' then udt_name else data_type end,
               'nn', is_nullable = 'NO', 'd', column_default) order by ordinal_position) cols
        from information_schema.columns
       where table_schema = 'public' and table_name in (${lit(TABLES)}) group by table_name) x),
  'cons', (select jsonb_object_agg(t, c) from (
      select cl.relname t, jsonb_agg(jsonb_build_object('n', con.conname, 'd', pg_get_constraintdef(con.oid),
                                                        'ty', con.contype) order by con.contype desc, con.conname) c
        from pg_constraint con join pg_class cl on cl.oid = con.conrelid
        join pg_namespace ns on ns.oid = cl.relnamespace
       where ns.nspname = 'public' and cl.relname in (${lit(TABLES)}) group by cl.relname) y),
  'idx', (select jsonb_agg(indexdef) from pg_indexes
           where schemaname = 'public' and tablename in (${lit(TABLES)}) and indexdef ilike '%unique%')
) j`;

const res = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: `begin;\nset transaction read only;\n${sql};\nrollback;` }),
});
const text = await res.text();
if (!res.ok) { console.error(`HTTP ${res.status}`); console.error(text); process.exit(1); }
const j = JSON.parse(text)[0].j;

const missingFn = FUNCTIONS.filter((f) => !Object.keys(j.fns ?? {}).some((k) => k.startsWith(f + '#')));
const missingTb = TABLES.filter((t) => !(j.cols ?? {})[t]);
if (missingFn.length || missingTb.length) {
  console.error(`the target database is missing ${missingFn.length} function(s) and ${missingTb.length} table(s) the rehearsal needs:`);
  for (const f of missingFn) console.error(`  function public.${f}`);
  for (const t of missingTb) console.error(`  table public.${t}`);
  console.error('Refusing to write a partial fixture — a rehearsal built on one would pass by omission.');
  process.exit(1);
}

// PGlite carries no PostGIS, so a geometry column becomes text. Nothing 0352 touches reads one; the
// ambush resolver does, and the rehearsal only ever CREATES that function, never calls it.
const TYPE = { 'timestamp with time zone': 'timestamptz', 'character varying': 'text', geometry: 'text', ARRAY: 'text[]' };
const out = [];
out.push('-- GENERATED, READ-ONLY, DO NOT COMMIT — scripts/capture-0352-rehearsal-inputs.mjs');
// Supabase's roles. The migration REVOKEs/GRANTs on them (the house ACL posture), so they must
// exist or the file cannot apply at all — PGlite starts with none of them.
out.push("do $r$ begin create role anon nologin; exception when duplicate_object then null; end $r$;");
out.push("do $r$ begin create role authenticated nologin; exception when duplicate_object then null; end $r$;");
out.push("do $r$ begin create role service_role nologin; exception when duplicate_object then null; end $r$;");
out.push('create schema if not exists auth;');
out.push('create table auth.users (id uuid primary key, email text);');
out.push('create schema if not exists supabase_migrations;');
out.push('create table supabase_migrations.schema_migrations (version text primary key);');
for (const t of TABLES) {
  const lines = j.cols[t].map((c) => {
    const ty = TYPE[c.t] ?? c.t;
    return `  ${c.n} ${ty}${c.nn ? ' not null' : ''}${c.d ? ` default ${c.d}` : ''}`;
  });
  // FKs are added afterwards so table order can never block creation; everything else is inline.
  for (const c of (j.cons[t] ?? []).filter((x) => x.ty !== 'f')) lines.push(`  constraint ${c.n} ${c.d}`);
  out.push(`create table public.${t} (\n${lines.join(',\n')}\n);`);
}
const have = new Set([...TABLES, 'users']);
for (const t of TABLES) for (const c of (j.cons[t] ?? [])) {
  if (c.ty !== 'f') continue;
  const target = (/REFERENCES ([a-z_.]+)\(/.exec(c.d)?.[1] ?? '').replace('auth.', '');
  if (!have.has(target)) { out.push(`-- SKIPPED FK ${t}.${c.n} -> ${target} (outside the fixture)`); continue; }
  out.push(`alter table public.${t} add constraint ${c.n} ${c.d};`);
}
for (const d of (j.idx ?? [])) { if (!/_pkey/.test(d)) out.push(d.replace(/ ON public\./, ' on public.') + ';'); }

mkdirSync(OUT, { recursive: true });
writeFileSync(path.join(OUT, 'fixture-schema.sql'), out.join('\n') + '\n');
writeFileSync(path.join(OUT, 'deployed-bodies.json'), JSON.stringify(j.fns, null, 1));
console.log(`captured ${Object.keys(j.fns).length} function bodies and ${TABLES.length} tables -> ${OUT}`);
