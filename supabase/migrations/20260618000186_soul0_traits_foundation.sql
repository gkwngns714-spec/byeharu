-- Byeharu — SOUL-0 (SHIP-SOUL packet, slice 0): the per-ship traits FOUNDATION — every ship gets
-- its own ORIGINAL stats/quirks, the Uncharted-Waters "this ship is MINE" identity (owner
-- directive). This slice ships the catalog + the instance table + the deterministic roll writer
-- ONLY — NO commission hook (SOUL-1 owns the parity re-creates of the commission path + the
-- adapter fold), NO adapter change, NO read RPC, NO frontend. DOUBLY DARK: behind the new
-- `ship_traits_enabled='false'` gate AND nothing calls the roll function yet.
--
-- ── STAT-KEY VERIFICATION (the 0183 lesson — a typo'd key is a dead trait) ───────────────────────
-- The adapter's TRUE head is 0180 (creates at 0044→0115→0122→0170→0180, grep-verified; 0181..0184
-- never re-create it). Its MODULE loop reads stats_json keys, coalesced to 0 (0180:212–219):
--     attack / defense / repair / cargo / scan / mining / evasion + speed_mult_bonus
-- — the ONE shared stat vocabulary (0042 base_stats_json / 0111 module stats_json / 0117 captain
-- stats_json). Trait seeds below use EXACTLY these input keys (never the output keys
-- survival/mining_yield). HONESTY NOTE on the self-assert: the adapter reads these keys from
-- MODULES (m.stats_json) / captains / hulls — the TRAITS fold lands in SOUL-1, so nothing reads
-- ship_trait_types.stats_json yet. The self-assert therefore pins every seeded key against the
-- HARDCODED vocabulary list above (kept in lockstep with 0180's module-read set), NOT against
-- prosrc — a prosrc pin would prove a read edge that does not exist yet (the 0111/0117
-- nothing-reads-this-yet posture, stated honestly).
--
-- ── DETERMINISM (the 0041 law, via the 0176 pure-hash technique — reused, never reinvented) ──────
-- `pirate_loot_for_wave` (0041) is deterministic BY CONSTRUCTION ("Deterministic (no RNG) so tests
-- are stable"); 0176's generator extended that with a pure hash for "random" choices:
-- hashtextextended over a salted key, mapped to a range via the ((h % n + n) % n) idiom — NO
-- setseed/random() anywhere (session RNG is order-dependent and parallel-unsafe; the packet's
-- notional md5 technique is normalized to the repo's shipped hashtextextended idiom, which 0176
-- already proved GUC-stable). A ship's traits are a PURE FUNCTION of its main_ship_id:
--     slot 1:  hashtextextended('<ship_id>:soul:1', 0)            → index in [0, catalog_count)
--     slot 2:  hashtextextended('<ship_id>:soul:2', 0), then a deterministic re-salt loop
--              ('<ship_id>:soul:2:<attempt>' for attempt 2, 3, …) until distinct from slot 1
-- indexed into the catalog ORDER BY trait_type_id COLLATE "C" (the deterministic total order —
-- THE COLLATION LAW, hostile-review M1: the order is pinned to "C" byte order BOTH on the column
-- definition AND on every ORDER BY (writer + proof, lockstep), because the DB default collation
-- (glibc/ICU) can re-order underscore-adjacent ids across environments/upgrades, which would
-- silently change every UNROLLED ship's derivation; rolled rows are immutable and safe either
-- way). Same ship id ⇒ same two traits, forever, provable by re-derivation (the proof
-- re-derives inline under the same pin). NOTE the derivation is deterministic AT A FIXED
-- CATALOG: it maps into the catalog's size and order, so any catalog change before a ship is
-- rolled changes its derivation — ACT-SOUL must assert catalog count = 8 (the catalog-freeze
-- precondition) before the backfill roll.
--
-- REPLAY ENVELOPE (hostile-review M2): the returned traits/hp_mult always come from the STORED
-- rows — the ship's truth. On a fresh roll they ARE this call's derivation; on a re-call
-- (inserted = 0) they are the ORIGINAL roll, so a catalog grown between roll and replay can
-- never make the envelope contradict the ship (and a replay on a veteran ship truthfully
-- reports its 1.08, not a default).
--
-- ── THE ROLL WRITER — sole writer, idempotent, immutability by construction ──────────────────────
-- `soul_roll_traits_for_ship(p_main_ship_id)`: SECURITY DEFINER, service_role ONLY (the 0145/0176
-- private-writer posture — a server op, not a player command; no wrapper exists). Gate-FIRST on
-- `ship_traits_enabled` (reject-before-any-read, envelope not raise — the D2 cron-safety shape,
-- adopted even though no cron calls it). Inserts the 2 rows `on conflict (main_ship_id, slot) do
-- nothing` — a re-call computes the SAME traits and inserts ZERO rows, so a re-roll is impossible
-- by construction. hp_mult (only veteran_frame carries > 1.0 today) applies ONLY when the rows
-- actually landed this call (inserted = 2 — a replay can never re-raise hp): max_hp :=
-- round(base × mult), hp scaled proportionally, both writes `>`-guarded monotonic (the 0171
-- backfill posture — never lower; hp/max_hp are the 0043 integer columns, hull-copied at
-- commission). The ship row is locked FOR UPDATE first, serializing concurrent rolls.
--
-- ── IMMUTABILITY (insert-only ACLs — schema-enforced, not policy-promised) ───────────────────────
-- main_ship_traits has NO update/delete path: no client policy or grant beyond owner-read SELECT
-- (default table grants stripped — the 0176/0177 revoke posture), and the sole writer's body
-- contains no UPDATE/DELETE against the table (prosrc-pinned below). The extra
-- unique (main_ship_id, trait_type_id) makes slot-distinctness a SCHEMA fact too: a buggy
-- duplicate roll raises instead of storing corrupt state (fail-closed).
--
-- ── SEED MAGNITUDES [D — owner-tunable; banded against the shipped catalogs] ─────────────────────
-- Traits are BIRTHMARKS, not equipment — every magnitude sits BELOW the same-stat module band
-- (0111/0183: autocannon attack 10 · shield defense 12 · cargo lattice 25 · sensor scan 8 ·
-- rig mining 8 · thruster evasion 3 + speed 0.1) and at-or-below the captain band (0117: 3–8):
-- attack ≤ 6, defense ≤ 8, cargo ≤ 8, scan ≤ 5, mining ≤ 4, evasion ≤ 6, |speed| ≤ 0.08,
-- hp_mult ≤ 1.08 (≈ +40 hp on the 500-hp starter). Five of eight carry a MINUS key — the
-- ROADMAP law-4 tradeoff posture (never a plain buff table). Flavor copy in the catalog register
-- (0042/0107/0117 — short, evocative, Uncharted-Waters "ships have souls").
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this slice — the 0098/0103/0107 precedent): §1
-- gains `ship_trait_types` (Reference/Config catalog — migration-seeded, NO runtime writer,
-- public read) and `main_ship_traits` (sole writer = the roll fn, insert-only, owner-read). NO §2
-- Ship-Soul system row yet — the roll fn exists but NOTHING calls it until SOUL-1 wires the
-- commission hook + adapter fold, and a doc must never describe a live system that isn't (the
-- 0111:57–58 / 0117 deferral posture; recorded in DEV_LOG).

-- ── (a) the dark capability gate (OFF / inert; no caller exists yet) ─────────────────────────────
insert into public.game_config (key, value, description) values
  ('ship_traits_enabled', 'false',
   'SOUL-0: server-authoritative dark gate for per-ship original traits (Ship Soul). OFF until '
   || 'the owner explicitly enables it. Every trait function (the 0186 roll writer today; the '
   || 'SOUL-1 commission hook + adapter fold later) must check this FIRST and reject-before-any-read '
   || 'while false; the UI surface stays hidden independently (fails closed both sides).')
on conflict (key) do nothing;

-- ── (b) ship_trait_types — the trait catalog (Reference/Config; public read-only) ────────────────
create table public.ship_trait_types (
  -- COLLATE "C": the id column IS the derivation's total order — byte-order-pinned so the DB
  -- default collation (glibc/ICU differences, locale upgrades) can never re-order the catalog
  -- and silently change an unrolled ship's derivation (the collation law; hostile-review M1).
  trait_type_id text collate "C" primary key,
  name          text not null,
  description   text not null,
  stats_json    jsonb not null default '{}'::jsonb,
  hp_mult       numeric not null default 1.0 check (hp_mult >= 1.0)
);

alter table public.ship_trait_types enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate.
-- Only migrations / service_role (admin) write (the 0039/0042/0107/0117 catalog posture; default
-- table grants stripped first — the 0176 revoke idiom).
revoke all on table public.ship_trait_types from public, anon, authenticated;
create policy "ship_trait_types_public_read" on public.ship_trait_types for select using (true);
grant select on public.ship_trait_types to anon, authenticated;

comment on column public.ship_trait_types.stats_json is
  'SOUL-0: a ship''s birthmark stat contributions in the ONE shared input vocabulary '
  '(attack/defense/repair/cargo/scan/mining/evasion + optional speed_mult_bonus — the 0180 '
  'adapter''s module-read key set). First consumer arrives with the SOUL-1 adapter fold — '
  'nothing reads this yet.';
comment on column public.ship_trait_types.hp_mult is
  'SOUL-0: multiplicative max-hp birthmark (>= 1.0 by CHECK — a trait never lowers hp). Applied '
  'ONCE by the roll writer at roll time (max_hp := round(base × mult), hp scaled proportionally, '
  'monotonic — the 0171 never-lower posture); NOT re-derived at read time.';

-- ── (c) the 8 trait seeds [D] (idempotent; catalog tone per 0042/0107/0117) ──────────────────────
insert into public.ship_trait_types (trait_type_id, name, description, stats_json, hp_mult) values
  ('veteran_frame',      'Veteran Frame',
   'A frame that has outlived three refits and every storm the void ever threw at it. Old bones hold.',
   '{"defense": 5}'::jsonb, 1.08),
  ('tuned_thrusters',    'Tuned Thrusters',
   'Some yard hand tuned her drives past the manual''s red line and never signed the work. She runs light, and she runs fast.',
   '{"speed_mult_bonus": 0.08, "cargo": -3}'::jsonb, 1.0),
  ('reinforced_plating', 'Reinforced Plating',
   'Double-laid plating over every seam. She shrugs off fire other hulls remember — and lumbers for it.',
   '{"defense": 8, "speed_mult_bonus": -0.04}'::jsonb, 1.0),
  ('smugglers_holds',    'Smuggler''s Holds',
   'False bulkheads and hollow decking from an earlier, quieter career. The inspectors never did find everything.',
   '{"cargo": 8, "scan": -2}'::jsonb, 1.0),
  ('keen_arrays',        'Keen Arrays',
   'Her arrays were calibrated by someone who truly cared. She sees what other ships sail straight past.',
   '{"scan": 5}'::jsonb, 1.0),
  ('hungry_guns',        'Hungry Guns',
   'Her mounts were bored out for heavier batteries than the class allows. The armor paid the bill.',
   '{"attack": 6, "defense": -3}'::jsonb, 1.0),
  ('steady_rigger',      'Steady Rigger',
   'Laid down by a rig crew that believed in doing it right the first time. Everything aboard works, and keeps working.',
   '{"mining": 4, "repair": 2}'::jsonb, 1.0),
  ('ill_omened',         'Ill-Omened',
   'Dockhands mutter when she berths and won''t say why. Whatever curses her, incoming fire somehow always lands elsewhere.',
   '{"evasion": 6, "attack": -2}'::jsonb, 1.0)
on conflict (trait_type_id) do nothing;

-- ── (d) main_ship_traits — the per-ship rolled traits (Ship Soul; owner-read; insert-only) ───────
create table public.main_ship_traits (
  main_ship_id  uuid not null references public.main_ship_instances (main_ship_id) on delete cascade,
  slot          int  not null check (slot in (1, 2)),
  trait_type_id text not null references public.ship_trait_types (trait_type_id),
  rolled_at     timestamptz not null default now(),
  unique (main_ship_id, slot),
  -- slot-distinctness as a SCHEMA fact (fail-closed: a buggy duplicate roll raises, never lands).
  unique (main_ship_id, trait_type_id)
);

alter table public.main_ship_traits enable row level security;
-- Owner-read via the owning ship (the 0074 ship_cargo_lots EXISTS idiom — no player_id column to
-- leak a pooled read). NO insert/update/delete policy and NO write grant → clients cannot mutate;
-- the ONLY writer is the SECURITY DEFINER roll function below. Owner data — authenticated only,
-- never anon/public.
revoke all on table public.main_ship_traits from public, anon, authenticated;
create policy "main_ship_traits_select_own" on public.main_ship_traits
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = main_ship_traits.main_ship_id
        and m.player_id = auth.uid()
    )
  );
grant select on public.main_ship_traits to authenticated;

comment on table public.main_ship_traits is
  'SOUL-0: a ship''s two rolled birthmark traits — IMMUTABLE once rolled (insert-only: no '
  'update/delete path exists anywhere; the sole writer is soul_roll_traits_for_ship, idempotent '
  'on (main_ship_id, slot)). NOTHING rolls or reads these yet — SOUL-1 owns the commission hook '
  'and the adapter fold. DARK behind ship_traits_enabled.';

-- ── (e) soul_roll_traits_for_ship — THE sole writer (deterministic, idempotent, service-only) ────
create or replace function public.soul_roll_traits_for_ship(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship     main_ship_instances%rowtype;
  v_count    integer;
  v_h        bigint;
  v_idx1     integer;
  v_idx2     integer;
  v_attempt  integer := 0;
  v_salt     text;
  v_t1       text;
  v_t2       text;
  v_n        integer;
  v_inserted integer := 0;
  v_mult     numeric := 1.0;
  v_old_max  integer;
  v_new_max  integer;
begin
  -- DARK gate FIRST (reject-before-any-read; envelope, never a raise — the D2 cron-safety shape).
  if not public.cfg_bool('ship_traits_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- Lock the ship row: concurrent rolls for one ship fully serialize (the second call then takes
  -- the idempotent zero-insert path below and can never double-apply the hp raise).
  select * into v_ship from main_ship_instances
    where main_ship_id = p_main_ship_id
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'ship_not_found');
  end if;

  select count(*) into v_count from ship_trait_types;
  if v_count < 2 then
    -- unreachable after this migration's seed self-assert; fail-closed anyway.
    return jsonb_build_object('ok', false, 'code', 'catalog_too_small');
  end if;

  -- slot 1: pure hash of the salted ship id → an index in [0, catalog_count), into the
  -- catalog's deterministic total order (ORDER BY trait_type_id COLLATE "C" — the collation
  -- law: the derivation order is byte-order-pinned, never the DB default collation). The
  -- ((h % n + n) % n) mapping is the 0176 generator idiom, reused verbatim; no session RNG.
  v_h    := hashtextextended(p_main_ship_id::text || ':soul:1', 0);
  v_idx1 := (((v_h % v_count) + v_count) % v_count)::integer;
  select trait_type_id into v_t1 from ship_trait_types
    order by trait_type_id collate "C" offset v_idx1 limit 1;

  -- slot 2: same technique, re-salted deterministically until distinct from slot 1
  -- (attempt 1 = ':soul:2'; attempt k ≥ 2 appends ':<k>'). Pure function of the ship id.
  loop
    v_attempt := v_attempt + 1;
    if v_attempt > 64 then
      -- probability ~ (1/8)^64 with the seeded catalog; a hard bound beats a silent fallback.
      raise exception 'soul_roll_traits_for_ship: no distinct slot-2 trait for % after 64 re-salts (catalog %)',
        p_main_ship_id, v_count;
    end if;
    v_salt := p_main_ship_id::text || ':soul:2' || case when v_attempt = 1 then '' else ':' || v_attempt end;
    v_h    := hashtextextended(v_salt, 0);
    v_idx2 := (((v_h % v_count) + v_count) % v_count)::integer;
    exit when v_idx2 <> v_idx1;
  end loop;
  select trait_type_id into v_t2 from ship_trait_types
    order by trait_type_id collate "C" offset v_idx2 limit 1;

  -- the ONLY writes to main_ship_traits anywhere: idempotent inserts on the (ship, slot) key.
  -- A re-call computes the SAME traits and lands ZERO rows — a re-roll cannot exist.
  insert into main_ship_traits (main_ship_id, slot, trait_type_id)
    values (p_main_ship_id, 1, v_t1)
    on conflict (main_ship_id, slot) do nothing;
  get diagnostics v_n = row_count; v_inserted := v_inserted + v_n;
  insert into main_ship_traits (main_ship_id, slot, trait_type_id)
    values (p_main_ship_id, 2, v_t2)
    on conflict (main_ship_id, slot) do nothing;
  get diagnostics v_n = row_count; v_inserted := v_inserted + v_n;

  -- The envelope's traits/hp_mult come from the STORED rows — the ship's truth (hostile-review
  -- M2): on a fresh roll they ARE this call's derivation; on a replay (inserted = 0) they are
  -- the ORIGINAL roll, so a catalog grown between roll and replay can never make the envelope
  -- contradict the ship, and a replay on a veteran ship truthfully reports its stored 1.08.
  select min(trait_type_id) filter (where slot = 1),
         min(trait_type_id) filter (where slot = 2)
    into v_t1, v_t2
    from main_ship_traits where main_ship_id = p_main_ship_id;
  select a.hp_mult * b.hp_mult into v_mult
    from ship_trait_types a, ship_trait_types b
    where a.trait_type_id = v_t1 and b.trait_type_id = v_t2;
  v_mult := coalesce(v_mult, 1.0);

  -- hp_mult applies ONLY when this call actually rolled the ship (both rows fresh) — a replay
  -- (inserted = 0) can never re-raise hp. base = the ship's max_hp at roll time (hull-copied at
  -- commission, 0043); round(base × mult), hp scaled proportionally, both `>`-guarded monotonic
  -- (the 0171 never-lower posture; hp_mult >= 1.0 by CHECK, so the guard is belt-and-braces).
  if v_inserted = 2 and v_mult > 1.0 then
    v_old_max := v_ship.max_hp;
    v_new_max := round(v_old_max * v_mult)::integer;
    update main_ship_instances
       set max_hp     = v_new_max,
           hp         = greatest(hp, least(v_new_max, round(hp::numeric * v_new_max / v_old_max)::integer)),
           updated_at = now()
     where main_ship_id = p_main_ship_id
       and v_new_max > max_hp;
  end if;

  return jsonb_build_object(
    'ok', true, 'main_ship_id', p_main_ship_id,
    'traits', jsonb_build_array(v_t1, v_t2),
    'inserted', v_inserted, 'hp_mult', v_mult);
end;
$$;

-- ACL (the 0145/0176 private-writer posture): a server op, not a player command — no wrapper.
revoke execute on function public.soul_roll_traits_for_ship(uuid) from public, anon, authenticated;
grant  execute on function public.soul_roll_traits_for_ship(uuid) to service_role;

-- ── (f) SELF-ASSERTS — the migration proves its own grounding or refuses to land ─────────────────
do $$
declare
  v_n      integer;
  v_prosrc text;
  v_coll   text;
  r        record;
begin
  -- (1) catalog seeded 8 EXACT (id + stats_json + hp_mult pinned verbatim), and exactly 8 total.
  select count(*) into v_n from public.ship_trait_types t
    join (values
      ('veteran_frame',      '{"defense": 5}'::jsonb,                            1.08::numeric),
      ('tuned_thrusters',    '{"speed_mult_bonus": 0.08, "cargo": -3}'::jsonb,   1.0),
      ('reinforced_plating', '{"defense": 8, "speed_mult_bonus": -0.04}'::jsonb, 1.0),
      ('smugglers_holds',    '{"cargo": 8, "scan": -2}'::jsonb,                  1.0),
      ('keen_arrays',        '{"scan": 5}'::jsonb,                               1.0),
      ('hungry_guns',        '{"attack": 6, "defense": -3}'::jsonb,              1.0),
      ('steady_rigger',      '{"mining": 4, "repair": 2}'::jsonb,                1.0),
      ('ill_omened',         '{"evasion": 6, "attack": -2}'::jsonb,              1.0)
    ) v(id, stats, mult)
    on v.id = t.trait_type_id and t.stats_json = v.stats and t.hp_mult = v.mult;
  if v_n <> 8 then
    raise exception 'SOUL-0 self-assert FAIL: % of 8 trait rows carry the exact seeded shape', v_n;
  end if;
  select count(*) into v_n from public.ship_trait_types;
  if v_n <> 8 then
    raise exception 'SOUL-0 self-assert FAIL: catalog holds % rows (want exactly 8 — no strays)', v_n;
  end if;
  -- exactly ONE hp_mult carrier, and it is veteran_frame (the only birthmark that touches hp).
  select count(*) into v_n from public.ship_trait_types
    where hp_mult > 1.0 and trait_type_id <> 'veteran_frame';
  if v_n <> 0 then
    raise exception 'SOUL-0 self-assert FAIL: % non-veteran_frame trait(s) carry hp_mult > 1', v_n;
  end if;

  -- (2) THE STAT-KEY PIN: every seeded stats_json key ∈ the ONE shared input vocabulary —
  --     HARDCODED here in lockstep with the 0180 adapter head's module-read set
  --     (attack/defense/repair/cargo/scan/mining/evasion/speed_mult_bonus, 0180:212–219).
  --     NOT prosrc-pinned: the adapter reads these keys from MODULES/captains/hulls — the traits
  --     fold lands in SOUL-1, so no trait read edge exists yet to pin (stated honestly).
  for r in
    select t.trait_type_id, k.key
      from public.ship_trait_types t, lateral jsonb_object_keys(t.stats_json) k(key)
  loop
    if r.key <> all (array['attack','defense','repair','cargo','scan','mining','evasion','speed_mult_bonus']) then
      raise exception 'SOUL-0 self-assert FAIL: % seeds stats key ''%'' outside the shared adapter vocabulary (dead trait)',
        r.trait_type_id, r.key;
    end if;
  end loop;

  -- (3) the traits table is EMPTY (nothing rolls yet — SOUL-1 owns the commission hook).
  select count(*) into v_n from public.main_ship_traits;
  if v_n <> 0 then
    raise exception 'SOUL-0 self-assert FAIL: main_ship_traits holds % rows at foundation time (want 0)', v_n;
  end if;

  -- (4) the gate exists and is DARK (seeded by THIS migration — nothing can have flipped it).
  if (select value #>> '{}' from public.game_config where key = 'ship_traits_enabled') is distinct from 'false' then
    raise exception 'SOUL-0 self-assert FAIL: ship_traits_enabled is % (want ''false'' — the dark seed)',
      coalesce((select value #>> '{}' from public.game_config where key = 'ship_traits_enabled'), '<missing>');
  end if;

  -- (5) the roll writer is deterministic BY CONSTRUCTION — no session RNG token in the deployed
  --     body, the salt + pure-hash + idempotence tokens present, and no update/delete against
  --     the traits table anywhere in it (insert-only immutability, prosrc-pinned).
  select prosrc into v_prosrc from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'soul_roll_traits_for_ship';
  if v_prosrc is null then
    raise exception 'SOUL-0 self-assert FAIL: soul_roll_traits_for_ship not found';
  end if;
  if strpos(v_prosrc, 'random(') > 0 or strpos(v_prosrc, 'setseed') > 0 then
    raise exception 'SOUL-0 self-assert FAIL: the roll fn body carries a session-RNG token (the 0041 determinism law)';
  end if;
  if strpos(v_prosrc, ':soul:') = 0 or strpos(v_prosrc, 'hashtextextended') = 0 then
    raise exception 'SOUL-0 self-assert FAIL: the roll fn body lost the '':soul:'' salt / pure-hash technique';
  end if;
  if strpos(v_prosrc, 'on conflict (main_ship_id, slot) do nothing') = 0 then
    raise exception 'SOUL-0 self-assert FAIL: the roll fn body lost the idempotent (ship, slot) insert';
  end if;
  if strpos(v_prosrc, 'update main_ship_traits') > 0 or strpos(v_prosrc, 'delete from main_ship_traits') > 0 then
    raise exception 'SOUL-0 self-assert FAIL: the roll fn body mutates main_ship_traits beyond insert (immutability breach)';
  end if;

  -- (5b) THE COLLATION LAW: the derivation's total order is byte-order-pinned — on the COLUMN
  --      (attcollation = "C") and in the writer's ORDER BY (prosrc token). The DB default
  --      collation must never be what orders the catalog (it can re-order underscore-adjacent
  --      ids across glibc/ICU environments and silently change unrolled derivations).
  select c.collname into v_coll
    from pg_attribute a join pg_collation c on c.oid = a.attcollation
    where a.attrelid = 'public.ship_trait_types'::regclass and a.attname = 'trait_type_id';
  if v_coll is distinct from 'C' then
    raise exception 'SOUL-0 self-assert FAIL: trait_type_id collation is % (want "C" — the derivation-order pin)',
      coalesce(v_coll, '<db default>');
  end if;
  if strpos(v_prosrc, 'order by trait_type_id collate "C"') = 0 then
    raise exception 'SOUL-0 self-assert FAIL: the roll fn ORDER BY lost the collate "C" pin (derivation order unpinned)';
  end if;

  -- (6) ACLs: the writer is service-only; the tables are read-only to clients (owner/public read,
  --     zero client write privilege — insert-only immutability is a GRANT fact, not a promise).
  if has_function_privilege('anon', 'public.soul_roll_traits_for_ship(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.soul_roll_traits_for_ship(uuid)', 'execute') then
    raise exception 'SOUL-0 self-assert FAIL: a client role can execute the roll fn (service_role only)';
  end if;
  if not has_function_privilege('service_role', 'public.soul_roll_traits_for_ship(uuid)', 'execute') then
    raise exception 'SOUL-0 self-assert FAIL: service_role cannot execute the roll fn';
  end if;
  if not has_table_privilege('authenticated', 'public.ship_trait_types', 'select')
     or not has_table_privilege('anon', 'public.ship_trait_types', 'select') then
    raise exception 'SOUL-0 self-assert FAIL: the trait catalog is not public-readable';
  end if;
  if not has_table_privilege('authenticated', 'public.main_ship_traits', 'select') then
    raise exception 'SOUL-0 self-assert FAIL: authenticated cannot read main_ship_traits (owner-read RLS needs the grant)';
  end if;
  if has_table_privilege('anon', 'public.main_ship_traits', 'select') then
    raise exception 'SOUL-0 self-assert FAIL: anon can read main_ship_traits (owner data)';
  end if;
  for r in
    select role_name, table_name, priv
      from (values ('anon','ship_trait_types'), ('authenticated','ship_trait_types'),
                   ('anon','main_ship_traits'), ('authenticated','main_ship_traits')) t(role_name, table_name),
           (values ('insert'), ('update'), ('delete')) p(priv)
  loop
    if has_table_privilege(r.role_name, 'public.' || r.table_name, r.priv) then
      raise exception 'SOUL-0 self-assert FAIL: % holds % on % (clients must have zero write privilege)',
        r.role_name, r.priv, r.table_name;
    end if;
  end loop;

  raise notice 'SOUL-0 self-assert ok: 8 traits pinned verbatim (keys within the shared 0180 vocabulary; veteran_frame the sole hp_mult 1.08 carrier); traits table empty; ship_traits_enabled dark; roll fn deterministic (pure-hash '':soul:'' salt, no session RNG, derivation order collate-"C"-pinned on column + ORDER BY, stored-row replay envelope), idempotent, insert-only, service-role-only; client write privilege zero on both tables';
end $$;
