-- Byeharu — COMMAND-BUFFS: the FINALE of the owner's fleet reshape. Migration 0205. DARK behind the
-- new flag `command_buffs_enabled` (seeded false).
--
-- ── THE OWNER'S DESIGN (build exactly this) ──────────────────────────────────────────────────────
-- "Each tier will have ~10 buffs, assigned RANDOMLY when bought or manufactured. More buffs added
-- later — keep in mind for spaghetti." → a command-buff CATALOG organized by ship TIER, ~10 per
-- tier, EXTENSIBLE (additive on-conflict-do-nothing seeds — a later buff never re-derives a rolled
-- ship). At commission/build a ship rolls ONE buff from its tier's pool, DETERMINISTICALLY (the
-- 0041 law via the 0186 pure-hash technique — reused, never reinvented), stored in the ship's "buff
-- slot" (main_ship_instances.command_buff_id), IMMUTABLE once rolled.
-- "Command ship will provide those buffs … a buff slot, activated only when the ship is set on
-- command ship." → the rolled buff is DORMANT; it applies FLEET-WIDE (every ship in the fleet) only
-- when this ship has is_command_ship=true (FLEET-CONTROL, 0204). "That is the spirit" (a fleet-wide
-- themed bonus) → the buff's stats_json folds into every fleet member's stats via the ONE adapter.
--
-- ── NO SPAGHETTI — this maps onto SHIP-SOUL almost exactly (reuse, never a new mechanism) ─────────
--   · CATALOG mirrors ship_trait_types (SOUL-0, 0186): a new command_buff_types (buff_id / tier /
--     name / description / stats_json in the shared 0180/0198 adapter vocabulary). A ship's TIER is
--     a property of its HULL — this slice ADDS main_ship_hull_types.tier (starter_frigate=T0;
--     bulk_hauler / strike_corvette=T1, the 0185 header's own T0/T1 split) and seeds ~10 buffs for
--     T0 and ~10 for T1 (themed: gunnery-command → fleet attack, engineering-command → fleet speed,
--     logistics-command → fleet cargo, …; owner-tunable magnitudes). Extensible: more buffs per tier
--     are one additive on-conflict-do-nothing seed, more TIERS one more hull tier + pool.
--   · ROLL mirrors soul_roll_traits_for_ship (0186): deterministic
--     hashtextextended('<ship_id>:cmdbuff', 0) → an index into the tier pool's collate-"C" total
--     order → ONE buff. Stored via a NULL-guarded monotonic UPDATE (immutable once set; a re-call
--     lands zero rows). The roll is ALWAYS-ON additive data (a ship always has a rolled buff) —
--     NOT gated: it is inert until the fold flag + a command ship. Hooked at commission by an
--     AFTER-INSERT TRIGGER on main_ship_instances (the ROOMS-8 seed-trigger pattern, 0203 — covers
--     EVERY commission path WITHOUT re-creating one of the commission functions, the
--     minimal-spaghetti seam) + a monotonic backfill for existing ships (both call the ONE roll
--     writer — one derivation, never two).
--
-- ── THE ADAPTER FOLD (the ONE re-create — parity critical) ───────────────────────────────────────
-- calculate_expedition_stats — TRUE head 20260618000198 (NANGUARD; creates
-- 0044→0115→0122→0170→0180→0193→0196→0198, grep-verified; FLEET-CONTROL 0204 and ROOMS-8 0203 did
-- NOT touch it, re-verified). Re-created from that head VERBATIM with ONE marked
-- `-- COMMAND-BUFFS (0205)` hunk: when cfg_bool('command_buffs_enabled') AND this ship is in a fleet
-- (v_ship.group_id not null), fold the fleet's ACTIVE command ship(s)' rolled buff stats_json
-- FLEET-WIDE into THIS ship's totals (the same additive fold shape + shared 8-key vocabulary as the
-- module / trait fold; NO tradeoff CASE — a command buff is a pure fleet bonus, its costs, if any,
-- live in its stats_json). DOUBLE-GATED: flag false → the loop is skipped ENTIRELY (dark = zero
-- command_buff reads, byte-identical output); flag true + no command ship / ungrouped ship = an
-- empty loop (byte-identical output) — the DECKS-3 / level double inertness.
-- DEPENDENCY (documented): is_command_ship is only meaningfully set when FLEET-CONTROL is used, so
-- the fold in practice needs fleet_control_enabled too; but the FOLD itself gates ONLY on
-- command_buffs_enabled (the roll + catalog are additive / always-on and never gated).
-- EXTRACT-AND-DIFF: the re-create is the 0198 body byte-identical EXCEPT the marked hunk (3 added
-- declares + the fold loop + `+ v_cmdbuff_speed_bonus` inside the ONE speed multiplier). EVERY
-- accumulated fold — 0115 modules, 0122 captains, 0170 hull, 0180 level, 0193 traits, 0196 affinity,
-- 0198 nanguard — is byte-identical and re-pinned by the §4 accumulated-hunk law.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this slice): command_buff_types is Reference/Config
-- (migration-seeded, no runtime writer, public read — the 0117 posture). main_ship_hull_types.tier
-- is additive Reference/Config. main_ship_instances.command_buff_id has ONE writer — the roll
-- trigger / backfill (command_buff_roll_for_ship); the adapter is the new READER (fold). No flag
-- flipped.
--
-- Forward-only: 0001–0204 unedited.

-- ── §1) NEW flag command_buffs_enabled (game_config bool, seeded FALSE) ───────────────────────────
-- The 0186/0204 dark-seed idiom: on conflict do nothing so a re-apply never un-flips a live
-- activation. OFF on live — dark until a human runs scripts/activate-command-buffs.sql.
insert into public.game_config (key, value, description) values
  ('command_buffs_enabled', 'false',
   'COMMAND-BUFFS (0205): server gate for the FLEET-WIDE command-buff fold. When true, '
   'calculate_expedition_stats folds a fleet''s ACTIVE command ship(s)'' rolled command_buff_types '
   'stats_json into EVERY fleet member''s totals (dormant otherwise). The per-ship roll + the '
   'catalog are additive / always-on and NOT gated by this flag — only the FOLD is. In practice the '
   'fold needs fleet_control_enabled too (is_command_ship is only meaningfully set under '
   'FLEET-CONTROL). OFF on live — dark until a human flips it.')
on conflict (key) do nothing;

-- ── §2) main_ship_hull_types.tier — a hull's command-buff TIER (additive Reference/Config) ────────
-- The 0185 header already partitions the hulls into T0 (starter_frigate) and T1 (bulk_hauler /
-- strike_corvette); this makes that split a COLUMN the roll reads. Default 'T0' so any hull added
-- without a tier still rolls from the T0 pool (never a tier-less ship); the two T1 hulls are set
-- explicitly. Free text (no CHECK) — a future T2+ tier is one seed away, never a schema change.
alter table public.main_ship_hull_types
  add column if not exists tier text not null default 'T0';
update public.main_ship_hull_types
   set tier = 'T1' where hull_type_id in ('bulk_hauler', 'strike_corvette') and tier <> 'T1';
comment on column public.main_ship_hull_types.tier is
  'COMMAND-BUFFS (0205): the hull''s command-buff tier (T0 starter_frigate; T1 bulk_hauler / '
  'strike_corvette — the 0185 split). The roll picks ONE buff from command_buff_types WHERE '
  'tier = this. Default T0; extensible (a new tier is a new hull tier + its buff pool).';

-- ── §3) command_buff_types — the command-buff catalog (Reference/Config; public read-only) ────────
create table public.command_buff_types (
  -- COLLATE "C": the id column IS the derivation's total order — byte-order-pinned so the DB
  -- default collation (glibc/ICU differences, locale upgrades) can never re-order a tier pool and
  -- silently change an unrolled ship's derivation (the 0186 collation law; hostile-review M1).
  buff_id     text collate "C" primary key,
  tier        text not null,
  name        text not null,
  description text not null,
  stats_json  jsonb not null default '{}'::jsonb
);

alter table public.command_buff_types enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate. Only
-- migrations / service_role (admin) write (the 0117/0186 catalog posture; default table grants
-- stripped first — the 0176 revoke idiom).
revoke all on table public.command_buff_types from public, anon, authenticated;
create policy "command_buff_types_public_read" on public.command_buff_types for select using (true);
grant select on public.command_buff_types to anon, authenticated;

comment on column public.command_buff_types.stats_json is
  'COMMAND-BUFFS (0205): a command buff''s FLEET-WIDE stat contributions in the ONE shared input '
  'vocabulary (attack/defense/repair/cargo/scan/mining/evasion + optional speed_mult_bonus — the '
  '0180/0198 adapter''s module-read key set). Folded into every fleet member''s totals when the '
  'buff''s ship is an ACTIVE command ship and command_buffs_enabled is lit.';

-- ── §3a) the T0 buff pool (~10; themed fleet bonuses, owner-tunable; additive on-conflict seeds) ──
-- FLEET-WIDE magnitudes are deliberately MODEST (a T0 command applies to up to 8 hulls at once) and
-- sit at/below the birthmark band (0186): attack ≤ 3, defense ≤ 3, cargo ≤ 4, scan/mining/repair
-- ≤ 2, evasion ≤ 3, speed ≤ +3%. Themes name a command doctrine (Uncharted-Waters flavor).
insert into public.command_buff_types (buff_id, tier, name, description, stats_json) values
  ('t0_gunnery_command',      'T0', 'Gunnery Command',
   'A flag gunner who calls the whole line''s fire. Every hull shoots a shade truer.',
   '{"attack": 3}'::jsonb),
  ('t0_bulwark_command',      'T0', 'Bulwark Command',
   'Standing damage-control doctrine, drilled fleet-wide. The whole formation holds together longer.',
   '{"defense": 3}'::jsonb),
  ('t0_engineering_command',  'T0', 'Engineering Command',
   'A chief engineer whose burn tables the whole fleet flies to. Everyone runs a touch lighter.',
   '{"speed_mult_bonus": 0.03}'::jsonb),
  ('t0_logistics_command',    'T0', 'Logistics Command',
   'A quartermaster who packs every hold in the fleet like a master. More rides home each run.',
   '{"cargo": 4}'::jsonb),
  ('t0_survey_command',       'T0', 'Survey Command',
   'Shared sensor picture, one honest chart. The fleet sees the black a little clearer.',
   '{"scan": 2}'::jsonb),
  ('t0_prospector_command',   'T0', 'Prospector Command',
   'A mining boss who reads a rock at a glance and tells the fleet where to bite.',
   '{"mining": 2}'::jsonb),
  ('t0_evasion_command',      'T0', 'Evasion Command',
   'Standing jink patterns the whole fleet knows cold. Incoming fire finds less to hit.',
   '{"evasion": 3}'::jsonb),
  ('t0_repair_command',       'T0', 'Repair Command',
   'A damage-control net across the fleet — spare hands, spare parts, one shared bench.',
   '{"repair": 2}'::jsonb),
  ('t0_vanguard_command',     'T0', 'Vanguard Command',
   'A hard-charging doctrine — hit first, hold the line. A little more bite, a little more armor.',
   '{"attack": 2, "defense": 2}'::jsonb),
  ('t0_quartermaster_command','T0', 'Quartermaster Command',
   'A steward who keeps the fleet stocked and mended between ports. Fuller holds, faster fixes.',
   '{"cargo": 3, "repair": 1}'::jsonb)
on conflict (buff_id) do nothing;

-- ── §3b) the T1 buff pool (~10; the T0 themes, doctrine-grade — stronger for the built hulls) ─────
insert into public.command_buff_types (buff_id, tier, name, description, stats_json) values
  ('t1_gunnery_doctrine',     'T1', 'Gunnery Doctrine',
   'A fleet-wide fire-control doctrine, rehearsed until the line volleys as one gun.',
   '{"attack": 6}'::jsonb),
  ('t1_bulwark_doctrine',     'T1', 'Bulwark Doctrine',
   'Layered damage-control across every hull. The formation takes a beating and keeps its shape.',
   '{"defense": 6}'::jsonb),
  ('t1_engineering_doctrine', 'T1', 'Engineering Doctrine',
   'Overhauled drives and a shared burn discipline. The whole fleet runs fast and clean.',
   '{"speed_mult_bonus": 0.06}'::jsonb),
  ('t1_logistics_doctrine',   'T1', 'Logistics Doctrine',
   'A convoy master''s stowage doctrine — not a cubic metre of hold wasted anywhere in the fleet.',
   '{"cargo": 8}'::jsonb),
  ('t1_survey_doctrine',      'T1', 'Survey Doctrine',
   'A fused sensor grid the whole fleet reads from. Little in the dark stays hidden.',
   '{"scan": 4}'::jsonb),
  ('t1_prospector_doctrine',  'T1', 'Prospector Doctrine',
   'A mining doctrine that reads a field cold and works it dry. The fleet hauls out more.',
   '{"mining": 4}'::jsonb),
  ('t1_evasion_doctrine',     'T1', 'Evasion Doctrine',
   'Fleet-wide evasion drills flown to muscle memory. The line is a hard thing to land a shot on.',
   '{"evasion": 5}'::jsonb),
  ('t1_field_repair_doctrine','T1', 'Field-Repair Doctrine',
   'A mobile repair doctrine — the fleet mends itself in the black without ever making port.',
   '{"repair": 4}'::jsonb),
  ('t1_strike_doctrine',      'T1', 'Strike Doctrine',
   'An overgunned assault doctrine — hit hard, hold harder. More bite AND more armor across the line.',
   '{"attack": 4, "defense": 3}'::jsonb),
  ('t1_convoy_doctrine',      'T1', 'Convoy Doctrine',
   'A fast-freight doctrine: heavy holds that still make good time. The fleet hauls more, faster.',
   '{"cargo": 6, "speed_mult_bonus": 0.02}'::jsonb)
on conflict (buff_id) do nothing;

-- ── §4) main_ship_instances.command_buff_id — the ship's rolled BUFF SLOT (nullable FK; immutable) ─
-- One nullable column (the cleanest for a single buff-slot — the owner's own steer). NULL until the
-- roll lands (a hull whose tier has no pool stays NULL — fail-closed). Sole writer:
-- command_buff_roll_for_ship (the trigger / backfill). Immutable once set: the writer's UPDATE is
-- NULL-guarded, so a re-fire can never change it.
alter table public.main_ship_instances
  add column if not exists command_buff_id text references public.command_buff_types (buff_id);
comment on column public.main_ship_instances.command_buff_id is
  'COMMAND-BUFFS (0205): the ship''s ONE rolled command buff (command_buff_types.buff_id) — a '
  'deterministic function of the ship id + its hull tier, IMMUTABLE once set (the sole writer''s '
  'UPDATE is NULL-guarded). DORMANT until this ship is an ACTIVE command ship (is_command_ship, '
  '0204) in a fleet AND command_buffs_enabled is lit — then it folds FLEET-WIDE through the adapter.';

-- ── §5) command_buff_roll_for_ship — THE sole writer (deterministic, idempotent, service-only) ────
-- The soul_roll_traits_for_ship (0186) shape, single-slot: NOT gated (the roll is always-on additive
-- data — inert until the fold flag + a command ship). Locks the ship FOR UPDATE (serializes
-- concurrent rolls), rolls ONE buff from the ship's hull-tier pool by pure hash, and writes it
-- NULL-guarded (immutable). A tier with no pool (a future tier) rolls nothing — fail-closed, no write.
create or replace function public.command_buff_roll_for_ship(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship    main_ship_instances%rowtype;
  v_tier    text;
  v_count   integer;
  v_h       bigint;
  v_idx     integer;
  v_buff    text;
  v_updated integer := 0;
begin
  -- Lock the ship row: concurrent rolls for one ship fully serialize (the second call then takes the
  -- NULL-guarded zero-write path below and can never overwrite the first roll).
  select * into v_ship from main_ship_instances
    where main_ship_id = p_main_ship_id
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'ship_not_found');
  end if;

  -- IMMUTABILITY by construction: a ship that already carries a buff is never re-rolled (the replay
  -- envelope reports its STORED buff — the ship's truth, the 0186 M2 posture).
  if v_ship.command_buff_id is not null then
    return jsonb_build_object('ok', true, 'main_ship_id', p_main_ship_id,
      'command_buff_id', v_ship.command_buff_id, 'rolled', false);
  end if;

  -- the ship's tier IS its hull's tier (the additive §2 column).
  select tier into v_tier from main_ship_hull_types where hull_type_id = v_ship.hull_type_id;
  if v_tier is null then
    return jsonb_build_object('ok', false, 'code', 'hull_tier_unknown');
  end if;

  select count(*) into v_count from command_buff_types where tier = v_tier;
  if v_count < 1 then
    -- a tier with no buffs yet (a future tier): roll nothing, leave the slot NULL (fail-closed).
    return jsonb_build_object('ok', false, 'code', 'tier_pool_empty', 'tier', v_tier);
  end if;

  -- pure hash of the salted ship id → an index in [0, pool_count), into the tier pool's
  -- deterministic total order (ORDER BY buff_id COLLATE "C" — the collation law). The
  -- ((h % n + n) % n) mapping is the 0186 idiom, reused verbatim; no session RNG (the 0041 law).
  v_h   := hashtextextended(p_main_ship_id::text || ':cmdbuff', 0);
  v_idx := (((v_h % v_count) + v_count) % v_count)::integer;
  select buff_id into v_buff from command_buff_types
    where tier = v_tier
    order by buff_id collate "C" offset v_idx limit 1;

  -- the ONLY write: monotonic + NULL-guarded (immutable once set — a re-call lands zero rows).
  update main_ship_instances
     set command_buff_id = v_buff, updated_at = now()
   where main_ship_id = p_main_ship_id and command_buff_id is null;
  get diagnostics v_updated = row_count;

  return jsonb_build_object('ok', true, 'main_ship_id', p_main_ship_id,
    'tier', v_tier, 'command_buff_id', v_buff, 'rolled', v_updated > 0);
end;
$$;

-- ACL (the 0186 private-writer posture): a server op, not a player command — no wrapper.
revoke execute on function public.command_buff_roll_for_ship(uuid) from public, anon, authenticated;
grant  execute on function public.command_buff_roll_for_ship(uuid) to service_role;

-- ── §6) the commission ROLL HOOK — an AFTER-INSERT trigger (the ROOMS-8 seed-trigger pattern) ─────
-- Fires on EVERY commission path WITHOUT re-creating one of the commission functions (the
-- minimal-spaghetti seam, 0203). Definer-to-definer (the 0169/0193 leaf-call pattern): this
-- SECURITY DEFINER trigger body executes as the function owner, which may execute the
-- service_role-only roll writer. Idempotent + NULL-guarded → a re-fire can never re-roll. NOT gated
-- (always-on additive data). No AFTER-UPDATE trigger exists on main_ship_instances (grep-verified),
-- so the roll's self-UPDATE fires nothing and cannot recurse.
create or replace function public.command_buff_roll_on_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.command_buff_roll_for_ship(NEW.main_ship_id);
  return NEW;
end $$;

comment on function public.command_buff_roll_on_commission() is
  'COMMAND-BUFFS (0205): AFTER-INSERT-on-main_ship_instances hook that rolls the new ship''s command '
  'buff (always-on additive data — NOT flag-gated; inert until a command ship + the fold flag). '
  'Covers every commission path without re-creating one — the ROOMS-8 minimal-spaghetti seam.';

create trigger trg_command_buff_roll
  after insert on public.main_ship_instances
  for each row execute function public.command_buff_roll_on_commission();

-- ── §7) BACKFILL existing ships (monotonic — only rolls buff-less ships; the ONE writer) ──────────
-- Deterministic (the same pure-hash roll writer, per ship). MONOTONIC: the writer's NULL guard never
-- moves an already-rolled slot. Zero-or-more ships; on a fresh chain every ship gets its buff.
do $$
declare
  r record;
begin
  for r in select main_ship_id from public.main_ship_instances where command_buff_id is null loop
    perform public.command_buff_roll_for_ship(r.main_ship_id);
  end loop;
end $$;

-- ── §8) calculate_expedition_stats — the 0198 (NANGUARD) TRUE-head body VERBATIM + the ONE marked
--    COMMAND-BUFFS fleet-wide fold hunk. PARITY DISCIPLINE (extract-and-diff — this is the hottest
--    function in the game with 8+ accumulated hunks): the body below is byte-identical to 0198 §1
--    EXCEPT the marked `-- COMMAND-BUFFS (0205)` additions (3 declares + the fold loop + the one
--    speed-multiplier token). Every accumulated 0115/0122/0170/0180/0193/0196/0198 hunk survives —
--    re-pinned in §9. ─────────────────────────────────────────────────────────────────────────────
create or replace function public.calculate_expedition_stats(
  p_player        uuid,
  p_main_ship_id  uuid,
  p_loadout       jsonb default '[]'::jsonb,
  p_activity_type text default 'pirate_hunt')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ship   public.main_ship_instances%rowtype;
  v_speed  numeric;
  r        record;
  v_used   integer := 0;
  -- accumulated support contributions
  a_combat    numeric := 0;
  a_survival  numeric := 0;
  a_repair    numeric := 0;
  a_cargo     numeric := 0;
  a_scout     numeric := 0;
  a_mining    numeric := 0;
  a_retreat   numeric := 0;
  a_attention numeric := 0;
  a_spd_pen   numeric := 0;
  v_warnings  jsonb := '[]'::jsonb;
  v_final_speed numeric;
  -- fitted modules (Phase 14, 0115)
  m                 record;
  v_mod_used        integer := 0;
  v_mod_speed_bonus numeric := 0;
  -- assigned captains (Phase 15, 0122)
  c                 record;
  v_cap_used        integer := 0;
  v_cap_speed_bonus numeric := 0;
  -- TEAM-ACTIVATION-PREP (0170): hull base combat stats (packet §1.4 delta)
  v_hull_stats      jsonb := '{}'::jsonb;
  -- C2-2 (0180): captain level fold — the growth flag + bonus knob, read ONCE at entry (never
  -- per-captain: a mid-scan config write must not split one ship's captains across two regimes).
  -- While captain_growth_enabled is false, v_growth pins the multiplier to exactly 1.0 regardless
  -- of level; the knob is floored at 0 so a mis-set negative value never makes leveling a nerf.
  -- NaN guard (review L1): cfg_num transits float8 — a mis-set "NaN" string would pass greatest()
  -- (NaN sorts above all numerics in PG) and poison every folded stat.
  -- NANGUARD (0198): the guard is the WORKING equality test (= 'NaN'::double precision — the 0182
  -- worldstate-knob precedent). PG makes NaN = NaN TRUE, so this arm is REACHABLE and floors a
  -- mis-set "NaN" knob to 0. (The 0180 head shipped the dead x-not-equal-x shape, a PG no-op whose
  -- arm was unreachable; corrected here.)
  v_growth          boolean := public.cfg_bool('captain_growth_enabled');
  v_lvl_bonus_raw   double precision := coalesce(public.cfg_num('captain_level_bonus_per_level'), 0);
  v_lvl_bonus       numeric := greatest(0, case when v_lvl_bonus_raw = 'NaN'::double precision then 0 else v_lvl_bonus_raw end)::numeric;   -- NANGUARD (0198): was `<>` (a PG no-op)
  v_lvl_mult        numeric := 1;
  -- SOUL-1 (0193): ship-trait fold — the gate read ONCE at entry (the 0180 v_growth posture: a
  -- mid-scan config write must never split one ship's read across regimes). While false the
  -- trait read below is SKIPPED ENTIRELY (knob-gated read: dark = zero trait-table reads and a
  -- byte-identical output); lit with zero rolled rows = an empty loop (byte-identical output) —
  -- the DOUBLE inertness.
  v_traits_enabled    boolean := public.cfg_bool('ship_traits_enabled');
  tr                  record;
  v_trait_speed_bonus numeric := 0;
  -- DECKS-3 (0196): station-affinity fold — the bonus knob, read ONCE at entry (the exact 0180
  -- v_lvl_bonus posture, guard SHAPE mirrored for parity: never a knob read per row, never split
  -- across regimes mid-scan). Seeded '0' → ×(1 + 0) = ×1.0 exactly — byte-inert while unflipped;
  -- floored at 0 so a mis-set negative value never makes a matched station a nerf. v_aff_mult is
  -- assigned per captain inside the loop (from the two ALREADY-JOINED columns), the knob never
  -- re-read. NANGUARD (0198): both knob guards here use the WORKING equality test
  -- (= 'NaN'::double precision — the 0182 worldstate-knob precedent). PG makes NaN = NaN TRUE, so
  -- the arm is REACHABLE and a knob mis-set to "NaN" is floored to 0 (never poisons the folded
  -- stats). The 0180/0196 heads shipped the dead x-not-equal-x shape (a PG no-op whose arm was
  -- unreachable); this slice corrected BOTH adapter guards and their pinned self-asserts.
  v_aff_bonus_raw   double precision := coalesce(public.cfg_num('station_affinity_bonus'), 0);
  v_aff_bonus       numeric := greatest(0, case when v_aff_bonus_raw = 'NaN'::double precision then 0 else v_aff_bonus_raw end)::numeric;   -- NANGUARD (0198): was `<>` (a PG no-op)
  v_aff_mult        numeric := 1;
  -- COMMAND-BUFFS (0205): the FLEET-WIDE command-buff fold — the gate read ONCE at entry (the 0180
  -- v_growth / 0193 v_traits_enabled posture: a mid-scan config write must never split one ship's
  -- read across regimes). While false the fleet-buff loop below is SKIPPED ENTIRELY (knob-gated
  -- read: dark = zero command_buff reads, byte-identical output); lit with an ungrouped ship or no
  -- active command ship in the fleet = an empty loop (byte-identical output) — the DECKS-3 / level
  -- DOUBLE inertness. Depends on fleet_control_enabled for is_command_ship to be meaningfully set
  -- (documented); the FOLD gates on command_buffs_enabled alone (the roll + catalog are always-on).
  v_cmdbuffs_enabled    boolean := public.cfg_bool('command_buffs_enabled');
  cb                    record;
  v_cmdbuff_speed_bonus numeric := 0;
begin
  -- (0) Activity must be a known type (no activity logic runs here — just validation).
  if coalesce(p_activity_type, '') not in ('pirate_hunt','trade_run','exploration','mining','none') then
    raise exception 'calculate_expedition_stats: unknown activity_type %', p_activity_type;
  end if;

  -- (1)(2) Read the player's main ship (must exist AND be owned by p_player).
  select * into v_ship from main_ship_instances
    where main_ship_id = p_main_ship_id and player_id = p_player;
  if not found then
    raise exception 'calculate_expedition_stats: main ship % not found for player %', p_main_ship_id, p_player;
  end if;
  select base_speed into v_speed from main_ship_hull_types where hull_type_id = v_ship.hull_type_id;
  v_speed := coalesce(v_speed, 1);

  -- TEAM-ACTIVATION-PREP (0170): the HULL's own combat stats feed the SAME accumulators the
  -- support-craft / module / captain feeds use (ONE stat pipeline, no parallel hull pipeline) —
  -- the exact packet-§1.4 shape. coalesce-to-0 keeps the function byte-inert for any hull whose
  -- base_stats_json carries no attack/defense keys (the 0043 '{}' default), the D1 parity idiom.
  -- No tradeoff CASE: the hull IS the ship — its attention/speed cost is already the baseline.
  select coalesce(base_stats_json, '{}'::jsonb) into v_hull_stats
    from main_ship_hull_types where hull_type_id = v_ship.hull_type_id;
  a_combat   := a_combat   + coalesce((v_hull_stats->>'attack')::numeric, 0);
  a_survival := a_survival + coalesce((v_hull_stats->>'defense')::numeric, 0);
  -- END TEAM-ACTIVATION-PREP (0170) delta — everything below is the 0122 head, byte-identical.

  -- SOUL-1 (0193): the ship's rolled BIRTHMARK TRAITS (main_ship_traits × ship_trait_types) feed
  -- the SAME accumulators — placed adjacent to the hull fold because traits are part of the SHIP
  -- ITSELF, another additive contribution ahead of the equipment loops (all contributions are
  -- additive into one accumulator set, so order cannot change the sum — adjacency to the 0170
  -- hull idiom is documentation, not arithmetic). Same key vocabulary as the module loop
  -- (0180:212–219), coalesced to 0 — the ONE fold idiom, no second trait reader. KNOB-GATED read:
  -- skipped entirely while dark. NO tradeoff CASE: a trait's costs live IN its stats_json minus
  -- keys (five of eight seeds — the 0186 law-4 posture). hp_mult is NOT read here — it was
  -- applied ONCE at roll time to max_hp by soul_roll_traits_for_ship (0186); re-scaling it in the
  -- adapter would double-apply.
  if v_traits_enabled then
    for tr in
      select y.stats_json
      from main_ship_traits mt
      join ship_trait_types y on y.trait_type_id = mt.trait_type_id
      where mt.main_ship_id = v_ship.main_ship_id
    loop
      a_combat    := a_combat    + coalesce((tr.stats_json->>'attack')::numeric, 0);
      a_survival  := a_survival  + coalesce((tr.stats_json->>'defense')::numeric, 0);
      a_repair    := a_repair    + coalesce((tr.stats_json->>'repair')::numeric, 0);
      a_cargo     := a_cargo     + coalesce((tr.stats_json->>'cargo')::numeric, 0);
      a_scout     := a_scout     + coalesce((tr.stats_json->>'scan')::numeric, 0);
      a_mining    := a_mining    + coalesce((tr.stats_json->>'mining')::numeric, 0);
      a_retreat   := a_retreat   + coalesce((tr.stats_json->>'evasion')::numeric, 0);
      v_trait_speed_bonus := v_trait_speed_bonus + coalesce((tr.stats_json->>'speed_mult_bonus')::numeric, 0);
    end loop;
  end if;
  -- END SOUL-1 (0193) trait-fold hunk — everything below is the 0180 head, byte-identical, except
  -- the ONE marked final-speed line.

  -- COMMAND-BUFFS (0205): the ship's FLEET's ACTIVE command ship(s)' rolled command buffs feed the
  -- SAME accumulators — placed adjacent to the trait fold because a command buff is a FLEET-level
  -- identity contribution, additive ahead of the equipment loops (all contributions are additive
  -- into one accumulator set, so order cannot change the sum — adjacency is documentation, not
  -- arithmetic). Same key vocabulary + coalesce-to-0 as the trait / module loops — the ONE fold
  -- idiom, no second buff reader. DOUBLE-GATED: the loop is skipped ENTIRELY while dark (zero
  -- command_buff reads, byte-identical output), and an ungrouped ship (group_id null) or a fleet
  -- with no ACTIVE command ship carrying a buff yields an EMPTY loop (byte-identical output). NO
  -- tradeoff CASE and NO scaling — a command buff is a pure fleet bonus (its costs, if any, live in
  -- its stats_json minus keys). Owner-scoped defense-in-depth on the self-join (cs.player_id =
  -- v_ship.player_id): a fleet is one player's, so this can never fold a foreign ship's buff.
  if v_cmdbuffs_enabled and v_ship.group_id is not null then
    for cb in
      select cbt.stats_json
      from main_ship_instances cs
      join command_buff_types cbt on cbt.buff_id = cs.command_buff_id
      where cs.group_id = v_ship.group_id
        and cs.player_id = v_ship.player_id
        and cs.is_command_ship
    loop
      a_combat    := a_combat    + coalesce((cb.stats_json->>'attack')::numeric, 0);
      a_survival  := a_survival  + coalesce((cb.stats_json->>'defense')::numeric, 0);
      a_repair    := a_repair    + coalesce((cb.stats_json->>'repair')::numeric, 0);
      a_cargo     := a_cargo     + coalesce((cb.stats_json->>'cargo')::numeric, 0);
      a_scout     := a_scout     + coalesce((cb.stats_json->>'scan')::numeric, 0);
      a_mining    := a_mining    + coalesce((cb.stats_json->>'mining')::numeric, 0);
      a_retreat   := a_retreat   + coalesce((cb.stats_json->>'evasion')::numeric, 0);
      v_cmdbuff_speed_bonus := v_cmdbuff_speed_bonus + coalesce((cb.stats_json->>'speed_mult_bonus')::numeric, 0);
    end loop;
  end if;
  -- END COMMAND-BUFFS (0205) fleet-buff hunk — everything below is the 0198 head, byte-identical,
  -- except the ONE marked final-speed line (+ v_cmdbuff_speed_bonus).

  -- (3)(4)(5)(6)(8) Normalize + validate the loadout, accumulate capacity + effects.
  -- Duplicates are COMBINED (summed) deterministically. Invalid entries are REJECTED.
  for r in
    with norm as (
      select trim(el->>'support_craft_type_id')      as type_id,
             (el->>'quantity')::numeric               as qty
      from jsonb_array_elements(coalesce(p_loadout, '[]'::jsonb)) el
    ),
    agg as (
      select type_id, sum(qty) as qty
      from norm
      group by type_id
    )
    select a.type_id, a.qty,
           s.capacity_cost, s.role, s.activity_tags, s.base_stats_json
    from agg a
    left join support_craft_types s on s.support_craft_type_id = a.type_id
  loop
    -- (5) quantity must be a positive integer (rejects 0, negatives, NaN/Inf, fractions).
    if r.qty is null or r.qty <> floor(r.qty) or r.qty <= 0 or r.qty >= 1e9 then
      raise exception 'calculate_expedition_stats: invalid quantity % for %', r.qty, coalesce(r.type_id, '(null)');
    end if;
    -- (4) every support craft type must exist.
    if r.capacity_cost is null then
      raise exception 'calculate_expedition_stats: unknown support craft type %', coalesce(r.type_id, '(null)');
    end if;

    v_used := v_used + (r.capacity_cost * r.qty)::integer;

    -- (8) controlled effects: physical stats from base_stats_json; pirate_attention +
    --     speed penalty from role rules. Conservative, linear within the capacity cap.
    a_combat    := a_combat    + coalesce((r.base_stats_json->>'attack')::numeric, 0)  * r.qty;
    a_survival  := a_survival  + coalesce((r.base_stats_json->>'defense')::numeric, 0) * r.qty;
    a_repair    := a_repair    + coalesce((r.base_stats_json->>'repair')::numeric, 0)  * r.qty;
    a_cargo     := a_cargo     + coalesce((r.base_stats_json->>'cargo')::numeric, 0)   * r.qty;
    a_scout     := a_scout     + coalesce((r.base_stats_json->>'scan')::numeric, 0)    * r.qty;
    a_mining    := a_mining    + coalesce((r.base_stats_json->>'mining')::numeric, 0)  * r.qty;
    a_retreat   := a_retreat   + coalesce((r.base_stats_json->>'evasion')::numeric, 0) * r.qty;
    a_attention := a_attention + (case r.role when 'combat_damage' then 2 when 'cargo' then 2 when 'heavy_cargo' then 4 else 0 end) * r.qty;
    a_spd_pen   := a_spd_pen   + (case r.role when 'combat_damage' then 0.05 when 'heavy_cargo' then 0.08 when 'extraction' then 0.02 else 0 end) * r.qty;

    -- non-fatal warning if this craft isn't typically useful for the chosen activity.
    if p_activity_type <> 'none' and not (coalesce(r.activity_tags, '[]'::jsonb) ? p_activity_type) then
      v_warnings := v_warnings || to_jsonb(format('%s is not typically useful for %s', r.type_id, p_activity_type));
    end if;
  end loop;

  -- (7) capacity is a HARD cap — reject over-capacity loadouts.
  if v_used > v_ship.support_capacity then
    raise exception 'calculate_expedition_stats: loadout uses % support capacity, ship limit is %', v_used, v_ship.support_capacity;
  end if;

  -- (M — Phase 14, 0115) FITTED MODULES feed the SAME accumulators, capacity-limited with
  -- tradeoffs (never a raw sum). Pure downward read of the ship's fit set; no player filter is
  -- needed — the (1)(2) read proved the ship is p_player's, and fitting_apply's owner-consistency
  -- invariant (0112) guarantees every fitting on an owned ship belongs to that owner. No
  -- activity-tag warning here: module_types has no activity_tags column (0107/0111).
  for m in
    select t.slot_cost, t.slot_type, t.stats_json
    from ship_module_fittings f
    join module_instances i on i.id = f.module_instance_id
    join module_types t     on t.id = i.module_type_id
    where f.main_ship_id = v_ship.main_ship_id
  loop
    v_mod_used := v_mod_used + m.slot_cost;

    -- contributions: the exact stats_json key list the loadout loop reads, coalesced to 0 —
    -- modules and support craft flow through ONE set of accumulators (no parallel pipeline).
    a_combat    := a_combat    + coalesce((m.stats_json->>'attack')::numeric, 0);
    a_survival  := a_survival  + coalesce((m.stats_json->>'defense')::numeric, 0);
    a_repair    := a_repair    + coalesce((m.stats_json->>'repair')::numeric, 0);
    a_cargo     := a_cargo     + coalesce((m.stats_json->>'cargo')::numeric, 0);
    a_scout     := a_scout     + coalesce((m.stats_json->>'scan')::numeric, 0);
    a_mining    := a_mining    + coalesce((m.stats_json->>'mining')::numeric, 0);
    a_retreat   := a_retreat   + coalesce((m.stats_json->>'evasion')::numeric, 0);
    v_mod_speed_bonus := v_mod_speed_bonus + coalesce((m.stats_json->>'speed_mult_bonus')::numeric, 0);

    -- tradeoffs: the 0044 role-rule idiom as a slot_type CASE scaled by slot_cost (the module
    -- analogue of ×qty). weapon/cargo mirror the combat_damage/cargo role tradeoffs (more
    -- firepower / a bigger hold draws pirates and slows the burn); sensors emit (attention only);
    -- the engine's cost is the slot itself. Unknown/future slot_types: stats yes, tradeoff 0 —
    -- the same permissive posture as unmatched roles above.
    a_attention := a_attention + (case m.slot_type when 'weapon' then 2 when 'cargo' then 2 when 'sensor' then 1 else 0 end) * m.slot_cost;
    a_spd_pen   := a_spd_pen   + (case m.slot_type when 'weapon' then 0.03 when 'cargo' then 0.04 else 0 end) * m.slot_cost;
  end loop;

  -- (M7) module slots are a HARD cap — the 0044:112–115 mechanism verbatim. DEFENSE-IN-DEPTH:
  -- fitting_apply (0112) enforces this at fit time and is the primary gate; the adapter still
  -- refuses to compute stats from an over-capacity state rather than clamp or trust it.
  if v_mod_used > v_ship.module_slots then
    raise exception 'calculate_expedition_stats: fitted modules use % module slots, ship limit is %', v_mod_used, v_ship.module_slots;
  end if;

  -- (C — Phase 15, 0122) ASSIGNED CAPTAINS feed the SAME accumulators, headcount-limited with
  -- tradeoffs (never a raw sum). Pure downward read of the ship's roster; no player filter is
  -- needed — the (1)(2) read proved the ship is p_player's, and captain_assign_apply's
  -- owner-consistency invariant (0119) guarantees every assignment on an owned ship belongs to
  -- that owner (the 0115:47–50 rationale). No activity-tag warning here: captain_types has no
  -- activity_tags column (0117).
  for c in
    select t.specialization, t.stats_json,
           i.level,   -- C2-2 (0180): the captain's level (0177 column) joins the fold — additive column only
           st.affinity_specialization   -- DECKS-3 (0196): the held station's favored specialization (NULL when unstationed or the station has none — the Bridge); additive column only
    from ship_captain_assignments a
    join captain_instances i on i.id = a.captain_instance_id
    join captain_types t     on t.id = i.captain_type_id
    left join ship_stations st on st.station_id = a.station   -- DECKS-3 (0196): LEFT — a station-NULL row (general quarters) must KEEP folding at ×1.0; an inner join would silently drop that captain's whole contribution (dark-parity breach)
    where a.main_ship_id = v_ship.main_ship_id
  loop
    v_cap_used := v_cap_used + 1;

    -- C2-2 (0180): the level multiplier — GATED (v_growth false → exactly 1.0 whatever the level)
    -- and byte-inert at level 1 ((level - 1) = 0 → exactly 1.0 whatever the flag): the DOUBLE
    -- inertness. Scales ONLY this captain's stats_json contribution (the 8 reads below) — never
    -- the specialization tradeoffs (attention/speed cost stay level-flat: growth is never a
    -- stealth cost raise). v_lvl_bonus >= 0 and c.level >= 1 (0177 CHECK) → v_lvl_mult >= 1 always.
    v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end;

    -- DECKS-3 (0196): the station-affinity multiplier — the 0180 gated-multiplier shape mirrored.
    -- A MATCH (the held station's affinity_specialization equals THIS captain's specialization,
    -- the 0189 mapping: Gunnery=combat, Engineering=mining, Logistics=trade, Sensors=exploration,
    -- Medbay=support) → ×(1 + v_aff_bonus). EVERYTHING ELSE falls to the ELSE arm — exactly 1.0,
    -- never a knob read per row (the knob was read ONCE at entry): a MISMATCH (combat captain in
    -- Medbay), an UNSTATIONED captain (NULL station → NULL affinity via the LEFT join), and a
    -- no-affinity station (the Bridge, affinity NULL by seed) — NULL = <anything> is NULL in SQL,
    -- so both NULL shapes take the same no-match branch. DOUBLE-INERT: knob '0' (the committed
    -- seed) → ×(1+0) = ×1.0 exactly on every captain regardless of station; no match → ×1.0
    -- exactly regardless of the knob. Composes with the level multiplier at the EXISTING scale
    -- sites (contribution × v_lvl_mult × v_aff_mult — multiplication commutes; the token order is
    -- the pin) and scales ONLY this captain's stats_json contribution — never the specialization
    -- tradeoffs (affinity-flat: a matched station is never a stealth cost raise).
    -- v_aff_bonus >= 0 → v_aff_mult >= 1 always.
    v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end;

    -- contributions: the exact stats_json key list the loadout/module loops read, coalesced to
    -- 0 — captains, modules, and support craft flow through ONE set of accumulators.
    -- C2-2 (0180): each read scaled by the gated level multiplier (× 1.0 exactly while dark or at level 1).
    -- DECKS-3 (0196): × v_aff_mult composed at the same eight sites (× 1.0 exactly while the knob
    -- is 0 or the station doesn't match — the only modified pre-existing lines of this delta).
    a_combat    := a_combat    + coalesce((c.stats_json->>'attack')::numeric, 0)  * v_lvl_mult * v_aff_mult;
    a_survival  := a_survival  + coalesce((c.stats_json->>'defense')::numeric, 0) * v_lvl_mult * v_aff_mult;
    a_repair    := a_repair    + coalesce((c.stats_json->>'repair')::numeric, 0)  * v_lvl_mult * v_aff_mult;
    a_cargo     := a_cargo     + coalesce((c.stats_json->>'cargo')::numeric, 0)   * v_lvl_mult * v_aff_mult;
    a_scout     := a_scout     + coalesce((c.stats_json->>'scan')::numeric, 0)    * v_lvl_mult * v_aff_mult;
    a_mining    := a_mining    + coalesce((c.stats_json->>'mining')::numeric, 0)  * v_lvl_mult * v_aff_mult;
    a_retreat   := a_retreat   + coalesce((c.stats_json->>'evasion')::numeric, 0) * v_lvl_mult * v_aff_mult;
    v_cap_speed_bonus := v_cap_speed_bonus + coalesce((c.stats_json->>'speed_mult_bonus')::numeric, 0) * v_lvl_mult * v_aff_mult;
    -- END C2-2 (0180) + DECKS-3 (0196) hunks — everything below is the 0170 head, byte-identical.

    -- tradeoffs: the 0044/0115 idiom as a specialization CASE, ONE slot each so no cost scaling
    -- (a captain occupies exactly one slot — the 0117 headcount decision). A captain draws
    -- attention like crewed hardware; support-role captains are the low-profile option.
    -- Unknown/future specializations: stats yes, tradeoff 0 — the same permissive posture as
    -- above (the 0117 CHECK constrains the set today; 'else' is forward-compatibility).
    a_attention := a_attention + (case c.specialization when 'combat' then 2 when 'trade' then 1 when 'exploration' then 1 when 'mining' then 1 else 0 end);
    a_spd_pen   := a_spd_pen   + (case c.specialization when 'combat' then 0.02 when 'trade' then 0.02 when 'mining' then 0.02 else 0 end);
  end loop;

  -- (C7) captain slots are a HARD cap — the 0044:112–115 / 0115:194–196 mechanism, count-based
  -- (one captain = one slot). DEFENSE-IN-DEPTH: captain_assign_apply (0119) enforces this at
  -- assign time and is the primary gate; the adapter still refuses to compute stats from an
  -- over-capacity state rather than clamp or trust it.
  if v_cap_used > v_ship.captain_slots then
    raise exception 'calculate_expedition_stats: assigned captains use % captain slots, ship limit is %', v_cap_used, v_ship.captain_slots;
  end if;

  -- final speed = hull base speed raised by module + captain bonuses (additively inside the ONE
  -- multiplier, before penalties — the slice-locked order), reduced by penalties, floored so it
  -- never goes <= 0. With zero captains v_cap_speed_bonus = 0 and this reduces exactly to the
  -- 0115 expression (and with zero modules too, to 0044's).
  -- SOUL-1 (0193): + v_trait_speed_bonus joins the ONE multiplier (exactly + 0 while dark or
  -- trait-less, so the value is unchanged).
  -- COMMAND-BUFFS (0205): + v_cmdbuff_speed_bonus joins the SAME ONE multiplier (the only modified
  -- pre-existing line of this delta — exactly + 0 while dark, ungrouped, or command-ship-less, so
  -- the value is unchanged).
  v_final_speed := round(greatest(0.2, v_speed * (1 + v_mod_speed_bonus + v_cap_speed_bonus + v_trait_speed_bonus + v_cmdbuff_speed_bonus) * (1 - a_spd_pen)), 3);

  -- (9)(10)(11) Build the normalized stat object. Every field is coalesced + clamped to
  -- >= 0 and rounded → never NaN, never negative, deterministic for the same input.
  return jsonb_build_object(
    'main_ship_id',           v_ship.main_ship_id,
    'activity_type',          p_activity_type,
    'support_capacity_used',  v_used,
    'support_capacity_limit', v_ship.support_capacity,
    'module_slots_used',      v_mod_used,
    'module_slots_limit',     v_ship.module_slots,
    'captain_slots_used',     v_cap_used,
    'captain_slots_limit',    v_ship.captain_slots,
    'speed',            v_final_speed,
    'cargo_capacity',   greatest(0, v_ship.cargo_capacity + round(a_cargo)::integer),
    'combat_power',     greatest(0, round(a_combat, 2)),
    'survival',         greatest(0, round(a_survival, 2)),
    'retreat_safety',   greatest(0, round(a_retreat, 2)),
    'scouting',         greatest(0, round(a_scout, 2)),
    'mining_yield',     greatest(0, round(a_mining, 2)),
    'repair',           greatest(0, round(a_repair, 2)),
    'pirate_attention', greatest(0, round(a_attention, 2)),
    'warnings',         v_warnings
  );
end;
$$;

-- ── ACL — re-asserted for the re-created adapter (the 0044/0115/0122/0170/0180/0193/0198 posture
--    verbatim: server-only, service_role, NEVER clients — only the get_my_expedition_preview
--    wrapper (0049/0159) is client-exposed). The TARGETED idiom. ─────────────────────────────────
revoke execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant  execute on function public.calculate_expedition_stats(uuid, uuid, jsonb, text) to service_role;

-- ── §9) SELF-ASSERTS — the migration proves its own grounding or refuses to land ─────────────────
do $cmdbuff$
declare
  v_src text;
  v_n   integer;
  v_tok text;
  r     record;
begin
  -- ══ A) the flag is committed DARK (seeded by THIS migration — nothing can have flipped it) ═══════
  if coalesce((select value #>> '{}' from public.game_config where key = 'command_buffs_enabled'), 'false') <> 'false' then
    raise exception 'COMMAND-BUFFS self-assert FAIL: command_buffs_enabled is % (want ''false'' — the dark seed)',
      coalesce((select value #>> '{}' from public.game_config where key = 'command_buffs_enabled'), '<missing>');
  end if;

  -- ══ B) the TIER column: every hull carries a tier; the 0185 split is exact ═══════════════════════
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='main_ship_hull_types' and column_name='tier'
        and is_nullable='NO') then
    raise exception 'COMMAND-BUFFS self-assert FAIL: main_ship_hull_types.tier missing / nullable';
  end if;
  if (select tier from public.main_ship_hull_types where hull_type_id='starter_frigate') is distinct from 'T0' then
    raise exception 'COMMAND-BUFFS self-assert FAIL: starter_frigate is not tier T0';
  end if;
  select count(*) into v_n from public.main_ship_hull_types
    where hull_type_id in ('bulk_hauler','strike_corvette') and tier = 'T1';
  if v_n <> 2 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the two built hulls are not tier T1 (% of 2)', v_n;
  end if;

  -- ══ C) the CATALOG: ~10 per tier (>= 10 each), collate-"C" order pin, keys within the shared
  --    adapter vocabulary (a typo'd key is a dead buff — the 0186 stat-key law). ═══════════════════
  select count(*) into v_n from public.command_buff_types where tier='T0';
  if v_n < 10 then raise exception 'COMMAND-BUFFS self-assert FAIL: T0 pool holds % buffs (want >= 10)', v_n; end if;
  select count(*) into v_n from public.command_buff_types where tier='T1';
  if v_n < 10 then raise exception 'COMMAND-BUFFS self-assert FAIL: T1 pool holds % buffs (want >= 10)', v_n; end if;
  -- the collation law: buff_id is byte-order-pinned (a glibc/ICU re-order would change unrolled
  -- derivations). The writer + backfill ORDER BY collate "C" is pinned in (E).
  select c.collname into v_tok
    from pg_attribute a join pg_collation c on c.oid = a.attcollation
    where a.attrelid = 'public.command_buff_types'::regclass and a.attname = 'buff_id';
  if v_tok is distinct from 'C' then
    raise exception 'COMMAND-BUFFS self-assert FAIL: buff_id collation is % (want "C" — the derivation-order pin)', coalesce(v_tok,'<db default>');
  end if;
  for r in
    select t.buff_id, k.key
      from public.command_buff_types t, lateral jsonb_object_keys(t.stats_json) k(key)
  loop
    if r.key <> all (array['attack','defense','repair','cargo','scan','mining','evasion','speed_mult_bonus']) then
      raise exception 'COMMAND-BUFFS self-assert FAIL: buff % seeds stats key ''%'' outside the shared adapter vocabulary (dead buff)',
        r.buff_id, r.key;
    end if;
  end loop;

  -- ══ D) the BUFF SLOT + the BACKFILL: every ship whose hull tier has a pool carries a rolled buff
  --    (the trigger + backfill did their job). A tier with no pool would legitimately leave NULL —
  --    but every current hull tier (T0/T1) has a pool, so no ship may be NULL. ════════════════════
  if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name='main_ship_instances' and column_name='command_buff_id') then
    raise exception 'COMMAND-BUFFS self-assert FAIL: main_ship_instances.command_buff_id missing';
  end if;
  select count(*) into v_n
    from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
    join (select tier, count(*) as c from public.command_buff_types group by tier) p on p.tier = h.tier
    where i.command_buff_id is null;
  if v_n <> 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: % ship(s) with a pooled hull tier carry no rolled buff (backfill incomplete)', v_n;
  end if;
  -- every stored command_buff_id is a real catalog id AND matches the ship's hull tier (a roll can
  -- never cross tiers — the FK backstops existence; this pins the tier discipline too).
  select count(*) into v_n
    from public.main_ship_instances i
    join public.main_ship_hull_types h on h.hull_type_id = i.hull_type_id
    join public.command_buff_types b on b.buff_id = i.command_buff_id
    where b.tier <> h.tier;
  if v_n <> 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: % ship(s) carry a buff from a foreign tier', v_n;
  end if;

  -- ══ E) the ROLL WRITER + the TRIGGER: deterministic by construction (no session RNG), the
  --    pure-hash ':cmdbuff' salt + collate-"C" order + NULL-guarded write present; the AFTER-INSERT
  --    trigger is wired. ═══════════════════════════════════════════════════════════════════════════
  select prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public' and p.proname='command_buff_roll_for_ship';
  if v_src is null then raise exception 'COMMAND-BUFFS self-assert FAIL: command_buff_roll_for_ship not deployed'; end if;
  if strpos(v_src, 'random(') > 0 or strpos(v_src, 'setseed') > 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the roll fn carries a session-RNG token (the 0041 determinism law)';
  end if;
  if strpos(v_src, ':cmdbuff') = 0 or strpos(v_src, 'hashtextextended') = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the roll fn lost the '':cmdbuff'' salt / pure-hash technique';
  end if;
  if strpos(v_src, 'order by buff_id collate "C"') = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the roll fn ORDER BY lost the collate "C" pin (derivation order unpinned)';
  end if;
  if strpos(v_src, 'command_buff_id is null') = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the roll fn lost the NULL-guarded (immutable) write';
  end if;
  select count(*) into v_n from pg_trigger where tgname='trg_command_buff_roll' and not tgisinternal;
  if v_n <> 1 then raise exception 'COMMAND-BUFFS self-assert FAIL: the AFTER-INSERT roll trigger is missing'; end if;

  -- ══ F) the ADAPTER: the ONE marked fleet-buff fold present + gated, no random(), and EVERY
  --    accumulated hunk survives the re-create (the accumulated-hunk law — 8+ hunks). ═════════════
  select prosrc into v_src from pg_proc
    where oid = 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)'::regprocedure;
  if v_src is null then raise exception 'COMMAND-BUFFS self-assert FAIL: calculate_expedition_stats not deployed'; end if;
  -- the new fold: the gate read + the group-scoped command-ship loop + the speed token, exactly once.
  if position('v_cmdbuffs_enabled    boolean := public.cfg_bool(''command_buffs_enabled'')' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the adapter lacks the command_buffs_enabled gate read';
  end if;
  if position('if v_cmdbuffs_enabled and v_ship.group_id is not null then' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the adapter lacks the double-gated fleet-buff fold (flag + group_id)';
  end if;
  v_tok := 'join command_buff_types cbt on cbt.buff_id = cs.command_buff_id';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: % command_buff read sites in the adapter (want exactly 1 — the ONE fold idiom)', v_n;
  end if;
  if position('cs.is_command_ship' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the fleet-buff fold does not scope to ACTIVE command ships (is_command_ship)';
  end if;
  v_tok := '(cb.stats_json->>';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: % command-buff stats_json reads (want exactly 8 — the shared vocabulary: 7 accumulators + speed_mult_bonus)', v_n;
  end if;
  if position('+ v_cmdbuff_speed_bonus) * (1 - a_spd_pen)' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the command-buff speed contribution is not inside the ONE final-speed multiplier';
  end if;
  -- NO scaling of the buff contribution (a command buff is a pure fleet bonus — costs live in the
  -- stats_json minus keys, never a multiplier). No "* cb." scale token may exist.
  if position('* cb.' in v_src) > 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: a command-buff contribution is scaled (buffs fold unscaled)';
  end if;
  if position('random(' in v_src) > 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: calculate_expedition_stats contains random() (0041)';
  end if;
  -- the ACCUMULATED-HUNK LAW: every prior fold survives the re-create byte-for-byte (the marked hunk
  -- is the ONLY change). 0198 NANGUARD guards + the 0196 affinity + the 0180 level + 0193 traits +
  -- 0115/0122/0170 hunks — re-run the load-bearing pins.
  v_tok := '* v_lvl_mult * v_aff_mult';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 8 then raise exception 'COMMAND-BUFFS self-assert FAIL: % composed scale sites (want the 0196 head''s 8)', v_n; end if;
  if position('case when v_lvl_bonus_raw = ''NaN''::double precision then 0 else v_lvl_bonus_raw end' in v_src) = 0
     or position('case when v_aff_bonus_raw = ''NaN''::double precision then 0 else v_aff_bonus_raw end' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: a 0198 NANGUARD working-idiom guard vanished';
  end if;
  if position('v_lvl_bonus_raw <> v_lvl_bonus_raw' in v_src) > 0 or position('v_aff_bonus_raw <> v_aff_bonus_raw' in v_src) > 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: a dead x<>x NaN guard re-grew (0198 regression)';
  end if;
  if position('v_lvl_mult := case when v_growth then 1 + (c.level - 1) * v_lvl_bonus else 1 end' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the 0180 gated level-multiplier vanished'; end if;
  if position('v_aff_mult := case when c.affinity_specialization = c.specialization then 1 + v_aff_bonus else 1 end' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the 0196 no-match affinity CASE vanished'; end if;
  v_tok := 'left join ship_stations st on st.station_id = a.station';
  v_n := (length(v_src) - length(replace(v_src, v_tok, ''))) / length(v_tok);
  if v_n <> 1 then raise exception 'COMMAND-BUFFS self-assert FAIL: % LEFT station join sites (want the 0196 head''s 1)', v_n; end if;
  if position('if v_traits_enabled then' in v_src) = 0 or position('from main_ship_traits' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the 0193 knob-gated trait fold vanished'; end if;
  if position('(v_hull_stats->>''attack'')' in v_src) = 0
     or position('from ship_module_fittings f' in v_src) = 0
     or position('from ship_captain_assignments a' in v_src) = 0 then
    raise exception 'COMMAND-BUFFS self-assert FAIL: a 0115/0122/0170 hunk vanished (accumulated-hunk law)'; end if;

  -- ══ G) ACLs: catalog public-read; roll writer + adapter server-only; the trigger fn service-only. ═
  if not has_table_privilege('authenticated', 'public.command_buff_types', 'select')
     or not has_table_privilege('anon', 'public.command_buff_types', 'select') then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the buff catalog is not public-readable';
  end if;
  for r in
    select role_name, priv
      from (values ('anon'),('authenticated')) t(role_name),
           (values ('insert'),('update'),('delete')) p(priv)
  loop
    if has_table_privilege(r.role_name, 'public.command_buff_types', r.priv) then
      raise exception 'COMMAND-BUFFS self-assert FAIL: % holds % on command_buff_types (catalog is read-only to clients)', r.role_name, r.priv;
    end if;
  end loop;
  if has_function_privilege('anon', 'public.command_buff_roll_for_ship(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.command_buff_roll_for_ship(uuid)', 'execute') then
    raise exception 'COMMAND-BUFFS self-assert FAIL: the roll writer is client-executable (service_role only)';
  end if;
  if not has_function_privilege('service_role', 'public.command_buff_roll_for_ship(uuid)', 'execute') then
    raise exception 'COMMAND-BUFFS self-assert FAIL: service_role cannot execute the roll writer';
  end if;
  if has_function_privilege('authenticated', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute')
     or has_function_privilege('anon', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'COMMAND-BUFFS self-assert FAIL: calculate_expedition_stats is client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.calculate_expedition_stats(uuid, uuid, jsonb, text)', 'execute') then
    raise exception 'COMMAND-BUFFS self-assert FAIL: calculate_expedition_stats not granted to service_role';
  end if;

  raise notice 'COMMAND-BUFFS self-assert ok: command_buffs_enabled dark; hull tier column (starter_frigate T0, the two built hulls T1); command_buff_types >= 10 per tier, buff_id collate-"C"-pinned, all stats keys in the shared adapter vocabulary; every pooled-tier ship carries a rolled buff matching its tier (trigger + backfill), immutable NULL-guarded roll deterministic (pure-hash '':cmdbuff'' salt, no session RNG, collate-"C" order), AFTER-INSERT trigger wired; the adapter carries the ONE double-gated fleet-buff fold (1 read site, 8 shared-vocabulary keys, is_command_ship-scoped, unscaled, speed inside the one multiplier, no random()) with EVERY accumulated 0115/0122/0170/0180/0193/0196/0198 hunk surviving the re-create; ACLs catalog-public / writer+adapter server-only';
end $cmdbuff$;
