#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════════════════════════
// REHEARSAL for migration 20260618000352 — a disposable WASM Postgres, the DEPLOYED function
// bodies captured verbatim from production, the migration file UNMODIFIED, and one scenario per
// thing that must happen or must not.
//
//   node scripts/sortie-home-0352-rehearsal.mjs
//
// ── WHY THIS EXISTS ALONGSIDE CI ────────────────────────────────────────────────────────────────
// The disposable-matrix (`supabase start`, the whole chain against a real Postgres) is the only
// real gate — see the repo's own ci-apply-proof discipline. This is not a substitute for it. It is
// the leg that can be run in SECONDS, on a machine with no Docker and no psql, against the bodies
// production ACTUALLY carries rather than the bodies the migration chain would rebuild. Those two
// are not always the same thing: a hunk is sliced against the deployed text, and only the deployed
// text can prove it lands.
//
//   mkdir -p /tmp/pglite && cd /tmp/pglite && npm init -y && npm i @electric-sql/pglite
//   PGLITE_DIR=/tmp/pglite/node_modules/@electric-sql/pglite node scripts/sortie-home-0352-rehearsal.mjs
//
// PGlite is deliberately NOT a repo dependency (adding one would change package.json for a
// developer tool), so it is resolved from outside the repo — the 0349 rehearsal's own convention.
//
// ── WHAT IS NOT REHEARSED — said out loud, not left to be assumed ───────────────────────────────
// 1. THE MIGRATION CHAIN. The fixture is built from production's CATALOG (columns, CHECKs, unique
//    indexes) and production's FUNCTION BODIES, not by applying 0001..0349. A defect that only
//    appears when the chain builds the schema differently is invisible here and visible in CI.
// 2. POSTGIS. PGlite has none, so `geometry` columns are created as text. Nothing this migration
//    touches reads one; the ambush resolver does, and it is only ever created, never called.
// 3. pg_cron. Single-process WASM: the 30-second reconciler cannot be raced. The reconciler's leaf
//    is CALLED directly instead, which is what the cron does, one ship at a time.
// 4. RLS, roles and grants. Everything runs as the connection owner in both worlds.
// ═══════════════════════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.dirname(HERE);
const MIGRATION = path.join(REPO, 'supabase', 'migrations', '20260618000352_a_sortie_knows_where_home_is.sql');
const MIG_SQL = readFileSync(MIGRATION, 'utf8').replace(/\r\n/g, '\n');

// The rehearsal must rehearse THIS file, whole. If it ever stops carrying its own bookends the
// harness would be running a fragment and reporting on it.
for (const needle of ['\nbegin;\n', '\ncommit;\n', 'do $rewrite$', 'public.fleet_return_port', 'fleets_group_fleet_has_anchor']) {
  if (!MIG_SQL.includes(needle)) throw new Error(`migration drifted: ${needle} not found — the rehearsal would be rehearsing a different program`);
}

// ── the captured artefacts ───────────────────────────────────────────────────────────────────────
// Both are produced read-only from production by scripts/capture-0352-rehearsal-inputs.mjs and are
// passed in, never committed: the live engine is the authority and a checked-in copy is a second
// one that drifts. Point at them with --inputs <dir> (default: alongside this script).
const inputsArg = process.argv.indexOf('--inputs');
const INPUTS = inputsArg !== -1 ? process.argv[inputsArg + 1] : path.join(HERE, '.0352-inputs');
const SCHEMA_SQL = readFileSync(path.join(INPUTS, 'fixture-schema.sql'), 'utf8');
const BODIES = JSON.parse(readFileSync(path.join(INPUTS, 'deployed-bodies.json'), 'utf8'));

const pgliteDir = process.env.PGLITE_DIR;
let PGlite;
try {
  ({ PGlite } = await import(pgliteDir ? pathToFileURL(path.join(pgliteDir, 'dist', 'index.js')).href : '@electric-sql/pglite'));
} catch (e) {
  console.error(String(e.message || e));
  console.error('Cannot load @electric-sql/pglite. It is deliberately NOT a repo dependency. Install it outside the repo:');
  console.error('  mkdir -p /tmp/pglite && cd /tmp/pglite && npm init -y && npm i @electric-sql/pglite');
  console.error('  PGLITE_DIR=/tmp/pglite/node_modules/@electric-sql/pglite node scripts/sortie-home-0352-rehearsal.mjs');
  process.exit(2);
}

// ═══ THE MEASURED PRODUCTION SHAPE THE FIXTURE REPRODUCES ════════════════════════════════════════
// Read-only from production 2026-08-09. The owner's real ids, and the exact fleet shape that lost
// its ships twice that day: a GROUP fleet (group_id set, main_ship_id NULL) carrying a sortie
// manifest, with return_location_id NULL and origin_base_id anchored at Haven.
const P = {
  p1:    '218500ff-9cf6-408f-b3cd-5e92b4562168',   // the owner
  p2:    'ff63f0de-0000-4000-8000-000000000002',   // a second player — the "stranger's port" control
  group: 'df4649fc-8cfa-42c3-9c22-a6bad1ab46ba',
  haven: { loc: 'b1a00001-0066-4a00-8a00-000000000001', zone: 'a1e259e9-01d5-433a-bf82-77cd1ca89bb0', sector: 'a148a10f-f58b-4092-a844-d8475285b630', name: 'Haven',     x: -150, y: -90 },
  slag:  { loc: 'b1a00002-0066-4a00-8a00-000000000002', zone: 'dc41e669-1e48-4ce3-a715-23c910280585', sector: 'd91b22b7-7a29-4445-bb6d-f7c1e62ef66a', name: 'Slagworks', x:  210, y: -30 },
  drift: { loc: 'b1a00003-0066-4a00-8a00-000000000003', zone: 'cc000003-0000-4000-8000-000000000003', sector: 'cc000013-0000-4000-8000-000000000013', name: 'Driftmarch',x:   30, y: 240 },
  baseHaven: 'e0d7f142-902d-4e06-bb5e-b407391f509d',
  baseSlag:  'b07491b2-0000-4000-8000-000000000001',
  baseP2:    'cc99cc99-0000-4000-8000-000000000001',
  ships: ['8f59d19c-9f02-437a-82f0-3418b382ede2', '2aaec01b-c0b8-4482-b659-ea92d81ea151',
          '46203293-8de6-4b8b-9254-40259b08fdb3', 'f1d2d27b-f550-4699-bf95-d845558dba54',
          '41c804a6-3946-4a6d-bce2-9aef3255e405'],
};
const q = (s) => (s === null || s === undefined ? 'null' : `'${s}'`);

function worldSql() {
  const L = [];
  L.push(`insert into supabase_migrations.schema_migrations(version) values ('20260618000349');`);
  L.push(`insert into auth.users(id,email) values (${q(P.p1)},'owner@example.com'), (${q(P.p2)},'other@example.com');`);
  let si = 0;
  for (const k of ['haven', 'slag', 'drift']) {
    const p = P[k]; si += 1;
    L.push(`insert into public.sectors(id,name,sector_index,x,y) values (${q(p.sector)}, ${q(p.name + ' sector')}, ${si}, ${p.x}, ${p.y});`);
    L.push(`insert into public.zones(id,sector_id,name,x,y) values (${q(p.zone)}, ${q(p.sector)}, ${q(p.name + ' zone')}, ${p.x}, ${p.y});`);
    L.push(`insert into public.locations(id,zone_id,name,location_type,x,y,status) values (${q(p.loc)}, ${q(p.zone)}, ${q(p.name)}, 'trade_outpost', ${p.x}, ${p.y}, 'active');`);
  }
  // bases.x/y == their port's x/y — the invariant assert (f) pins, and the reason the anchor port is
  // the point the return leg physically flies to.
  L.push(`insert into public.bases(id,player_id,name,sector_id,x,y,status,location_id,created_at) values
    (${q(P.baseHaven)}, ${q(P.p1)}, 'Home Base', ${q(P.haven.sector)}, ${P.haven.x}, ${P.haven.y}, 'active', ${q(P.haven.loc)}, now() - interval '60 days'),
    (${q(P.baseSlag)},  ${q(P.p1)}, 'Slagworks', ${q(P.slag.sector)},  ${P.slag.x},  ${P.slag.y},  'active', ${q(P.slag.loc)},  now() - interval '30 days'),
    (${q(P.baseP2)},    ${q(P.p2)}, 'Home Base', ${q(P.drift.sector)}, ${P.drift.x}, ${P.drift.y}, 'active', ${q(P.drift.loc)}, now() - interval '60 days');`);
  for (const [k, v] of Object.entries({
    fleet_movement_unified_enabled: 'true', launch_from_dock_enabled: 'true',
    combat_telegraph_enabled: 'true', sortie_manifest_ttl_seconds: '3600',
  })) L.push(`insert into public.game_config(key,value) values (${q(k)}, '${v}'::jsonb);`);
  L.push(`insert into public.ship_groups(group_id,player_id,group_index,name) values (${q(P.group)}, ${q(P.p1)}, 1, 'Wing');`);
  L.push(`insert into public.main_ship_hull_types(hull_type_id,name,base_hp,base_speed,base_cargo_capacity,base_support_capacity,base_captain_slots,base_module_slots,base_cargo_capacity_m3)
    values ('starter_frigate','Starter Frigate',500,10,50,10,8,3,50) on conflict do nothing;`);
  for (const s of P.ships) {
    L.push(`insert into public.main_ship_instances
      (main_ship_id,player_id,hull_type_id,name,status,hp,max_hp,cargo_capacity,support_capacity,
       captain_slots,module_slots,cargo_capacity_m3,group_id,is_command_ship)
      values (${q(s)},${q(P.p1)},'starter_frigate','Sparrow','returning',500,500,50,10,8,3,50,${q(P.group)},${s === P.ships[0]});`);
  }
  return L.join('\n');
}

/** THE INCIDENT'S OWN FLEET SHAPE: a group fleet with a manifest and NO recorded return port. */
function sortieFleetSql(id, { rlid = null, anchor = P.baseHaven, status = 'completed', ageDays = 0, player = P.p1, members = P.ships } = {}) {
  const L = [];
  L.push(`insert into public.fleets (id,player_id,origin_base_id,status,location_mode,current_base_id,group_id,return_location_id,updated_at)
    values (${q(id)},${q(player)},${q(anchor)},${q(status)},'base',${q(anchor)},${q(P.group)},${q(rlid)}, now() - interval '${ageDays} days');`);
  for (const m of members) L.push(`insert into public.group_sortie_members(fleet_id,main_ship_id,player_id) values (${q(id)},${q(m)},${q(player)});`);
  return L.join('\n');
}

async function fresh(extra = '') {
  const db = await new PGlite();
  for (const stmt of SCHEMA_SQL.split(/;\r?\n/).map((s) => s.trim()).filter(Boolean)) {
    try { await db.exec(stmt + ';'); } catch (e) { if (!/already exists/.test(String(e.message))) throw e; }
  }
  for (const d of Object.values(BODIES)) await db.exec(d);
  await db.exec(worldSql());
  if (extra) await db.exec(extra);
  return db;
}
const rows = async (db, sql) => (await db.query(sql)).rows;
const one  = async (db, sql) => (await rows(db, sql))[0];
async function tryExec(db, sql) {
  try { await db.exec(sql); return { ok: true, code: null, message: '' }; }
  catch (e) { return { ok: false, code: e?.cause?.code ?? e?.code ?? null, message: String(e.message || e) }; }
}

let pass = 0, fail = 0;
const ok = (name, cond, detail = '') => { if (cond) { pass++; console.log(`   PASS  ${name}`); } else { fail++; console.log(`   FAIL  ${name}  ${detail}`); } };
const head = (t) => console.log(`\n══ ${t}`);

console.log('══════════ REHEARSAL · 0352 a sortie knows where home is ══════════');
console.log(`   migration: ${MIGRATION}`);
console.log(`   inputs:    ${INPUTS}  (${Object.keys(BODIES).length} deployed function bodies)`);

// ── A — THE MIGRATION APPLIES, AND EVERY REWRITTEN BODY COMPILES ────────────────────────────────
head('A · the file applies whole, against the bodies production actually carries');
{
  const db = await fresh(sortieFleetSql('972e97c1-4d4d-4d46-b67d-14d4392ccf3d'));
  const r = await tryExec(db, MIG_SQL);
  ok('the migration committed (all 4 hunks landed exactly-once; all 8 self-asserts passed)', r.ok, r.message);
  if (!r.ok) { console.log('\n   the file did not apply — every scenario below would be meaningless'); process.exit(1); }

  ok('public.fleet_return_port(uuid) exists', !!(await one(db, `select to_regprocedure('public.fleet_return_port(uuid)') p`)).p);
  ok('the CHECK exists', !!(await one(db, `select 1 x from pg_constraint where conname='fleets_group_fleet_has_anchor'`)));
  ok('bases.location_id is NOT NULL',
     !!(await one(db, `select 1 x from pg_attribute where attrelid='public.bases'::regclass and attname='location_id' and attnotnull`)));
  // POSITIVE CONTROL on that probe — a column that must stay nullable.
  ok('fleets.return_location_id is still nullable (the recorded choice is an OVERRIDE)',
     !(await one(db, `select 1 x from pg_attribute where attrelid='public.fleets'::regclass and attname='return_location_id' and attnotnull`)));

  // RE-APPLY MUST FAIL. A rewriter that silently no-ops on a second run is a rewriter whose
  // exactly-once probe is not doing anything.
  const again = await tryExec(db, MIG_SQL);
  ok('re-applying the file FAILS rather than silently no-opping', !again.ok, 'it applied twice');
  ok('…and it says which already-landed step refused it (the constraint, before the surgery)',
     /fleets_group_fleet_has_anchor|REWRITE FAIL/.test(again.message), again.message.slice(0, 200));
}

// ── B — THE INCIDENT, BEFORE AND AFTER ──────────────────────────────────────────────────────────
head("B · the owner's incident: an ambush-created sortie with no recorded return port");
{
  const F = '972e97c1-4d4d-4d46-b67d-14d4392ccf3d';
  const ship = P.ships[0];

  const before = await fresh(sortieFleetSql(F));
  await before.exec(`select public.nohome_dock_returning_ship(${q(ship)});`);
  const b = await one(before, `select s.status, (select count(*)::int from public.fleets f where f.main_ship_id=${q(ship)} and f.status='present') as docked
                                 from public.main_ship_instances s where s.main_ship_id=${q(ship)}`);
  ok("BEFORE (deployed 0349 body): the ship is written 'home' with no fleet — the defect",
     b.status === 'home' && b.docked === 0, JSON.stringify(b));

  const after = await fresh(sortieFleetSql(F));
  await after.exec(MIG_SQL);
  const port = await one(after, `select public.fleet_return_port(${q(F)}) p`);
  ok('AFTER: the leaf resolves the sortie fleet to its anchor port (Haven)', port.p === P.haven.loc, JSON.stringify(port));
  await after.exec(`select public.nohome_dock_returning_ship(${q(ship)});`);
  const a = await one(after, `select s.status,
      (select l.name from public.fleets f join public.locations l on l.id=f.current_location_id
        where f.main_ship_id=${q(ship)} and f.status='present' limit 1) as port,
      (select count(*)::int from public.location_presence lp join public.fleets f on f.id=lp.fleet_id
        where f.main_ship_id=${q(ship)} and lp.status='active') as presences,
      (select f.origin_base_id from public.fleets f where f.main_ship_id=${q(ship)} and f.status='present' limit 1) as anchor
      from public.main_ship_instances s where s.main_ship_id=${q(ship)}`);
  ok('AFTER: the ship is DOCKED at Haven — the port its fleet physically landed at', a.port === 'Haven', JSON.stringify(a));
  ok('AFTER: it has exactly one active presence there', a.presences === 1, JSON.stringify(a));
  ok('AFTER: its new tagged fleet carries an anchor of its own ([R6])', a.anchor === P.baseHaven, JSON.stringify(a));
  ok("AFTER: the ship reads 'home' — but 'home' now means DOCKED, because it has a fleet", a.status === 'home', JSON.stringify(a));

  // …and every one of the five members lands at the same port. THE FLEET COMES HOME TOGETHER.
  for (const s of P.ships.slice(1)) await after.exec(`select public.nohome_dock_returning_ship(${q(s)});`);
  const ports = await rows(after, `select distinct l.name from public.fleets f join public.locations l on l.id=f.current_location_id
                                    where f.status='present' and f.main_ship_id is not null`);
  ok('AFTER: all five members dock at ONE port', ports.length === 1 && ports[0].name === 'Haven', JSON.stringify(ports));
}

// ── C — THE RECORDED CHOICE STILL WINS, AND STILL EXPIRES ───────────────────────────────────────
head('C · the override: a chosen port beats the anchor, and a stale choice does not');
{
  const F = '11111111-1111-4111-8111-111111111111';
  const ship = P.ships[0];

  const fresh1 = await fresh(sortieFleetSql(F, { rlid: P.slag.loc, ageDays: 0 }));
  await fresh1.exec(MIG_SQL);
  ok('a FRESH sortie that chose Slagworks resolves to Slagworks, not to its Haven anchor',
     (await one(fresh1, `select public.fleet_return_port(${q(F)}) p`)).p === P.slag.loc);
  await fresh1.exec(`select public.nohome_dock_returning_ship(${q(ship)});`);
  ok('…and the ship docks there',
     (await one(fresh1, `select l.name from public.fleets f join public.locations l on l.id=f.current_location_id
                          where f.main_ship_id=${q(ship)} and f.status='present'`))?.name === 'Slagworks');

  // 0349's property, KEPT: a seventeen-day-old corpse's chosen port is not believed.
  // 0352's change, ADDED: the ship is no longer stranded for it — it goes to the anchor.
  const stale = await fresh(sortieFleetSql(F, { rlid: P.slag.loc, ageDays: 17 }));
  await stale.exec(MIG_SQL);
  ok('a SEVENTEEN-DAY-OLD sortie no longer names Slagworks (0349 fleet_sortie_still_speaks, kept)',
     (await one(stale, `select public.fleet_return_port(${q(F)}) p`)).p !== P.slag.loc);
  ok("…it falls back to the fleet's own anchor instead of answering nothing (0352)",
     (await one(stale, `select public.fleet_return_port(${q(F)}) p`)).p === P.haven.loc);
  await stale.exec(`select public.nohome_dock_returning_ship(${q(ship)});`);
  const s = await one(stale, `select l.name from public.fleets f join public.locations l on l.id=f.current_location_id
                               where f.main_ship_id=${q(ship)} and f.status='present'`);
  ok("…and the ship docks at Haven — never at the stale sortie's Slagworks", s?.name === 'Haven', JSON.stringify(s));

  // A LIVE fleet always speaks, at any age — 0349's other direction, unchanged.
  const parked = await fresh(sortieFleetSql(F, { rlid: P.slag.loc, ageDays: 17, status: 'idle' }));
  await parked.exec(MIG_SQL);
  ok('a LIVE fleet parked for seventeen days still names its chosen port (0349, unchanged)',
     (await one(parked, `select public.fleet_return_port(${q(F)}) p`)).p === P.slag.loc);
}

// ── D — NEVER A STRANGER'S PORT ─────────────────────────────────────────────────────────────────
head("D · 0349's fail-closed concern, answered structurally rather than by refusal");
{
  const F = '22222222-2222-4222-8222-222222222222';
  // A fleet owned by p1 whose origin_base_id names a base belonging to p2. The anchor branch
  // requires bases.player_id = fleets.player_id, so it must resolve to NOTHING rather than send the
  // ship to another player's port.
  // It is seeded AFTER the migration on purpose: assert (a) REFUSES TO DEPLOY over an unresolvable
  // fleet, and that refusal is itself worth seeing — it is demonstrated at the foot of this block.
  const db = await fresh();
  await db.exec(MIG_SQL);
  await db.exec(`insert into public.fleets (id,player_id,origin_base_id,status,location_mode,group_id,updated_at)
      values (${q(F)},${q(P.p1)},${q(P.baseP2)},'completed','base',${q(P.group)}, now());`);
  ok("a fleet anchored on ANOTHER player's base resolves to NULL, not to that player's port",
     (await one(db, `select public.fleet_return_port(${q(F)}) p`)).p === null);
  // and the resolver then makes NO WRITE at all (the [R5] arm).
  const shipOnly = '33333333-3333-4333-8333-333333333333';
  await db.exec(`insert into public.main_ship_instances
    (main_ship_id,player_id,hull_type_id,name,status,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,cargo_capacity_m3,group_id)
    values (${q(shipOnly)},${q(P.p1)},'starter_frigate','Orphan','returning',10,10,1,1,1,1,1,${q(P.group)});`);
  const t0 = await one(db, `select status, updated_at from public.main_ship_instances where main_ship_id=${q(shipOnly)}`);
  await db.exec(`select public.nohome_dock_returning_ship(${q(shipOnly)});`);
  const t1 = await one(db, `select status, updated_at from public.main_ship_instances where main_ship_id=${q(shipOnly)}`);
  ok("a ship with NO fleet at all is left EXACTLY as it was — no location-less 'home' is created",
     t1.status === t0.status && String(t1.updated_at) === String(t0.updated_at), JSON.stringify([t0, t1]));

  // AND THE DEPLOY GATE ITSELF: a world that already carries an unresolvable fleet must be REFUSED,
  // not migrated over. This is assert (a) doing its job, demonstrated rather than asserted in prose.
  const gated = await fresh(`insert into public.fleets (id,player_id,origin_base_id,status,location_mode,group_id,updated_at)
      values (${q(F)},${q(P.p1)},${q(P.baseP2)},'completed','base',${q(P.group)}, now());`);
  const g = await tryExec(gated, MIG_SQL);
  ok('the migration REFUSES to deploy over a fleet that cannot resolve a return port', !g.ok, 'it deployed anyway');
  ok('…and assert (a) is the one that says so', /ASSERT \(a\) FAIL/.test(g.message), g.message.slice(0, 200));
}

// ── E — THE CHECK: a sortie cannot be created without an anchor, and nothing else is refused ────
head('E · fleets_group_fleet_has_anchor — refuses the sortie shape, exempts the commissioning fleet');
{
  const db = await fresh();
  await db.exec(MIG_SQL);
  const sortie = await tryExec(db, `insert into public.fleets (player_id,origin_base_id,status,location_mode,group_id)
                                      values (${q(P.p1)}, null, 'idle','base',${q(P.group)});`);
  ok('a GROUP fleet with no anchor is REFUSED', !sortie.ok, 'it was accepted');
  ok('…by the named CHECK, not by something else', /fleets_group_fleet_has_anchor/.test(sortie.message), sortie.message.slice(0, 200));

  const perShip = await tryExec(db, `insert into public.fleets (player_id,origin_base_id,status,location_mode,main_ship_id)
                                       values (${q(P.p1)}, null, 'present','location',${q(P.ships[0])});`);
  ok('a PER-SHIP fleet with no anchor is still allowed — first-ship commissioning keeps working', perShip.ok, perShip.message.slice(0, 200));

  const loner = await tryExec(db, `insert into public.fleets (player_id,origin_base_id,status,location_mode)
                                     values (${q(P.p1)}, null, 'idle','base');`);
  ok('a group-less unit fleet with no anchor is still allowed', loner.ok, loner.message.slice(0, 200));

  const anchored = await tryExec(db, `insert into public.fleets (player_id,origin_base_id,status,location_mode,group_id)
                                        values (${q(P.p1)}, ${q(P.baseHaven)}, 'idle','base',${q(P.group)});`);
  ok('an ANCHORED group fleet is accepted', anchored.ok, anchored.message.slice(0, 200));

  const baseNoPort = await tryExec(db, `insert into public.bases (player_id,name,x,y,status) values (${q(P.p1)},'Nowhere',0,0,'active');`);
  ok('a base that names no port is REFUSED (bases.location_id NOT NULL)', !baseNoPort.ok, 'it was accepted');
}

// ── F — THE ONE RULE IN THE HUNT, AND THE TWO MINT GUARDS, IN THE EMITTED TEXT ──────────────────
head('F · the emitted bodies carry one rule and two guards');
{
  const db = await fresh();
  await db.exec(MIG_SQL);
  const src = async (fn) => (await one(db, `select regexp_replace(p.prosrc,'--[^'||chr(10)||']*','','g') s
                                              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                                             where n.nspname='public' and p.proname='${fn}'`)).s;
  const hunt = await src('send_ship_group_hunt');
  const count = (h, n) => h.split(n).length - 1;
  ok('send_ship_group_hunt assigns v_return exactly twice', count(hunt, 'v_return :=') === 2, String(count(hunt, 'v_return :=')));
  ok('…and both are the same one rule', count(hunt, 'v_return := coalesce(p_return_location_id, v_o_loc);') === 2);
  ok("…none of the head's three other expressions survives",
     count(hunt, 'coalesce(p_return_location_id, v_gf.current_location_id)') === 0
     && count(hunt, 'coalesce(p_return_location_id, v_dock_loc)') === 0);
  const go = await src('command_ship_group_go');
  ok('command_ship_group_go refuses a mint with no anchor', /if v_base\.id is null then\s*\n\s*return jsonb_build_object\('ok', false, 'reason', 'no_origin'\);\s*\n\s*end if;\s*\n\s*insert into public\.fleets/.test(go));
  const asg = await src('assign_ship_to_group');
  ok('assign_ship_to_group skips its heal-mint with no anchor', /if v_base is not null then\s*\n\s*insert into public\.fleets/.test(asg));
  const noh = await src('nohome_dock_returning_ship');
  ok('nohome_dock_returning_ship composes the leaf twice and reads no `bases` row',
     count(noh, 'public.fleet_return_port(') === 2 && count(noh, 'bases') === 0);
  ok("…and no longer writes status='home' itself", count(noh, "status = 'home'") === 0);
}

// ── G — THE FALLBACK AGREES WITH THE PHYSICS ────────────────────────────────────────────────────
head('G · the anchor port is the point the return leg flies to');
{
  const db = await fresh();
  await db.exec(MIG_SQL);
  const n = await one(db, `select count(*)::int c from public.bases b join public.locations l on l.id=b.location_id
                            where b.x is distinct from l.x or b.y is distinct from l.y`);
  ok("every base sits at its own port's coordinate", n.c === 0, JSON.stringify(n));
  for (const fn of ['process_combat_ticks', 'presence_request_leave', 'combat_flee_pending']) {
    const s = await one(db, `select position('origin_base_id' in p.prosrc) > 0 as reads,
                                    position('fleet_return_port' in p.prosrc) > 0 as touched
                               from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                              where n.nspname='public' and p.proname='${fn}'`);
    ok(`${fn} still flies to origin_base_id and was NOT re-created by this slice`, s.reads && !s.touched, JSON.stringify(s));
  }
  const amb = await one(db, `select md5(p.prosrc) m from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                              where n.nspname='public' and p.proname='pirate_intercept_resolve_due_for_movement'`);
  const orig = Object.entries(BODIES).find(([k]) => k.startsWith('pirate_intercept_resolve_due_for_movement#'))[1];
  const body = orig.slice(orig.indexOf('AS $function$') + 'AS $function$'.length, orig.lastIndexOf('$function$'));
  const { createHash } = await import('node:crypto');
  ok('the AMBUSH that caused the incident is byte-untouched — it needed no line at all',
     amb.m === createHash('md5').update(body).digest('hex'), amb.m);
}

console.log(`\n══════════ ${pass} passed, ${fail} failed ══════════`);
process.exit(fail === 0 ? 0 : 1);
