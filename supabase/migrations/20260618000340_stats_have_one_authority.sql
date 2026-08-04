-- Byeharu — STAT FOUNDATION (migration 0340): the canonical stat architecture, slices S1-S5 of
-- docs/STAT_ARCHITECTURE_CONTRACT.md, landed as ONE dark, additive, zero-reader foundation.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE HARD GUARANTEE: THIS SLICE CHANGES NO GAMEPLAY, AND IT IS NOT HIDDEN.
--
-- Those are two different things, and this migration deliberately does the first without the
-- second. The OWNER'S RULING (2026-08-04): "don't make anything dark, make it so that i can check.
-- It is pointless to be dark in my opinion." Taken literally, and correctly:
--
--   NOT CHANGED (the part that was ever actually protecting anyone):
--   • No pre-existing function is re-created, sliced, or text-patched. calculate_expedition_stats,
--     calculate_group_expedition_stats, combat_create_group_encounter, process_combat_ticks,
--     resolve_fleet_movement_speed and every mover are UNTOUCHED — asserted below by a blast-radius
--     check that proves each of their live bodies carries ZERO token from this slice.
--   • No existing table gains a column. No existing row is written. No consumer is cut over.
--   • Travel timing, in-progress movement rows, encounter creation and combat damage are therefore
--     bit-for-bit unchanged.
--
--   NOT HIDDEN (the part that was only ever hiding the work from its owner):
--   • THERE IS NO FEATURE FLAG IN THIS SLICE. An earlier draft seeded stat_resolver_enabled=false.
--     It gated nothing here — every line of this file runs regardless — so it was a flag that meant
--     "false" about nothing at all. Seeding an inert flag is precisely the "lit but inert" trap
--     that already produced five consumer-less stats and five zero-valued knobs in this repository.
--     It is removed. The slice that actually cuts a consumer over can seed the gate it needs, when
--     it needs it, and that gate will mean something.
--   • Every new TABLE is client-readable (RLS on, select granted). The registry is meant to be read.
--   • TWO CLIENT-FACING READ RPCs exist so the owner can CHECK this without a database console:
--       get_stat_definitions()   — the whole registry, as the client will eventually consume it
--       get_my_effective_stats() — resolve YOUR OWN ship or fleet, with the full contribution
--                                  breakdown, so every number can be traced to the row that made it
--     Both are read-only and STABLE. get_my_effective_stats is auth.uid()-scoped and refuses an
--     entity the caller does not own, so "inspectable" never becomes "readable across players" in
--     a live ~30-player game.
--   • The pure arithmetic leaves (stat_combine, stat_aggregate_fleet, buff_apply_stacking) and the
--     two buff WRITERS stay server-only. That is not darkness, it is the ordinary engine ACL: those
--     take raw contribution arrays and would let any caller assert any number about anything.
--
-- WHAT THIS ADDS — the three authorities of the contract, acyclic:
--
--        progression resolution ─┐
--        buff resolution ────────┼─> effective ship resolution ─> fleet aggregation
--        authoritative sources ──┘
--
--   (1) stat_definitions      — THE controlled vocabulary. One row adds an ordinary stat (contract
--                               §3.5, N=1). Carries identifier, scope, unit, numeric domain,
--                               permitted operations, permitted source categories, fleet
--                               aggregation, combat-snapshot policy, display metadata and clamps —
--                               all as CONTROLLED, CHECK-constrained fields. It can never carry
--                               executable SQL, a formula, an expression or an unvalidated
--                               identifier: there is no such column, and every text column that
--                               names a vocabulary is constrained to a closed enum or a
--                               subset-of-known-values array CHECK.
--   (2) progression_curves /  — THE XP authority. level is DERIVED from xp, never stored by this
--       progression_tracks      slice. One track: captain_v1. The deployed curve
--                               (0177:268-270, level = 1 + floor(sqrt(xp/100))) is preserved
--                               EXACTLY, now with the owner's functional cap of 99.
--   (3) buff_definitions /    — THE buff authority. Definition is catalog, instance is state.
--       buff_instances          Activation, expiry, eligibility, stacking policy and ordering live
--                               here and NOWHERE else; the stat resolver consumes normalized
--                               contributions and re-implements none of it.
--   (4) the resolvers         — resolve_effective_stats (ship + fleet), resolve_active_buffs,
--                               resolve_progression, each a thin GATHERER over pure, table-free
--                               leaves (stat_combine, stat_aggregate_fleet, buff_apply_stacking).
--                               That split is what makes this migration's deploy-time equivalence
--                               assert NON-VACUOUS on an empty disposable chain (contract §12.3).
--
-- OUT OF SCOPE, DELIBERATELY (contract §11 + the owner's slice boundary):
--   • Any consumer cutover. Nothing calls the new resolvers.
--   • The combat snapshot boundary. process_combat_ticks (~73,000 chars, held whole by no file) is
--     NOT re-emitted. combat_snapshot is REGISTERED per stat as frozen/live/not_applicable; the one
--     deliberate live re-read (0310's auto-exit max_hp denominator) is documented, not moved.
--   • The malformed-ship concealment handler at 0301:804-806. Its replacement is the later
--     combat-integration slice. This migration does not touch it.
--   • Cargo unit CONVERSION. Per the owner's post-census re-ruling, cargo modules, captain effects
--     and cargo traits ARE intended to affect real ship-bound VOLUME capacity, so cargo_volume_m3 is
--     registered as the canonical target with provenance — but the conversion is NOT ACTIVATED, no
--     +25 is copied into a volume field, and no live hold size changes. The legacy integer stays
--     DEPRECATED and non-authoritative. Conversion, hold changes, already-fitted modules and the
--     player-impact proof are a SEPARATE migration.
--   • Repairing the ambush consumer. pirate_intercept_plan_leg's fail-open (0301:545-547) is
--     DESIGNED against and PINNED here, and deliberately left in place; cutting it over is the
--     bounded consumer-retirement sequence.
--   • Any flag flip, any live row mutation, any balance change.
--
-- THE OWNER'S LATER RULINGS, FOLDED IN:
--   · STAT LIFECYCLE. Every stat declares active / dormant / deprecated, with no default and a
--     closed CHECK, so an undeclared or unknown lifecycle is REJECTED. Dormant means NOT COMPUTED on
--     any routine resolution path — it is absent from the routine registry snapshot, so nothing
--     gathers it, folds it or emits it; only an explicitly requested, authorized inspection call
--     resolves it, and even then it lands in a `dormant` map marked effective=false.
--   · THE FIVE CONFIRMED-DEAD OUTPUTS (retreat_safety, scouting, mining_yield, repair,
--     pirate_attention) are seeded DORMANT, not as ordinary active stats. Prior implementation
--     effort does not create gameplay semantics.
--   · THREE-WAY PROVENANCE. A real zero, a resolution failure and a not-applicable are three
--     different shapes in every result and are never collapsed into one value.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. DEPENDENCY GATE — abort loudly if a surface this slice reads is missing ────────────────────
do $sfdep$
begin
  if to_regclass('public.game_config') is null then
    raise exception 'STAT-FOUNDATION: public.game_config missing — the dark flag is seeded into it'; end if;
  if to_regprocedure('public.cfg_bool(text)') is null then
    raise exception 'STAT-FOUNDATION: public.cfg_bool(text) (0046) missing — the resolver reads the fold gates'; end if;
  if to_regprocedure('public.cfg_num(text)') is null then
    raise exception 'STAT-FOUNDATION: public.cfg_num(text) missing — the resolver reads the captain multiplier knobs'; end if;
  if to_regclass('public.main_ship_instances') is null or to_regclass('public.main_ship_hull_types') is null then
    raise exception 'STAT-FOUNDATION: main_ship_instances / main_ship_hull_types missing — the ship resolver reads them'; end if;
  -- The canonical cargo target reads the VOLUME column (0076), never the legacy integer.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'main_ship_instances'
                    and column_name = 'cargo_capacity_m3') then
    raise exception 'STAT-FOUNDATION: main_ship_instances.cargo_capacity_m3 (0076) missing — cargo_volume_m3 is based on it'; end if;
  if to_regclass('public.ship_groups') is null then
    raise exception 'STAT-FOUNDATION: public.ship_groups (0160) missing — fleet scope resolves a group_id'; end if;
  if to_regclass('public.main_ship_traits') is null or to_regclass('public.ship_trait_types') is null then
    raise exception 'STAT-FOUNDATION: main_ship_traits / ship_trait_types (0186/0193) missing'; end if;
  if to_regclass('public.ship_module_fittings') is null or to_regclass('public.module_instances') is null
     or to_regclass('public.module_types') is null then
    raise exception 'STAT-FOUNDATION: the module fitting chain (0107/0111/0112) missing'; end if;
  if to_regclass('public.ship_captain_assignments') is null or to_regclass('public.captain_instances') is null
     or to_regclass('public.captain_types') is null or to_regclass('public.ship_stations') is null then
    raise exception 'STAT-FOUNDATION: the captain chain (0117/0119/0196) missing'; end if;
  if to_regclass('public.command_buff_types') is null then
    raise exception 'STAT-FOUNDATION: public.command_buff_types (0205) missing — buff_definitions is seeded FROM it'; end if;
  if to_regprocedure('public.calculate_expedition_stats(uuid,uuid,jsonb,text)') is null then
    raise exception 'STAT-FOUNDATION: calculate_expedition_stats missing — this slice asserts it is NOT modified'; end if;
  if to_regprocedure('public.calculate_group_expedition_stats(uuid,uuid,text)') is null then
    raise exception 'STAT-FOUNDATION: calculate_group_expedition_stats missing — this slice asserts it is NOT modified'; end if;
end $sfdep$;

-- ── 1. THE REGISTRY — stat_definitions ───────────────────────────────────────────────────────────
-- Reference/Config posture (docs/SYSTEM_BOUNDARIES.md:27): migration-seeded only, NO runtime writer
-- ever, RLS on, select to clients, writes explicitly REVOKED.
--
-- REGISTRY LAW, enforced by the schema itself, not by review:
--   · every behavioural field is a CLOSED enum (CHECK ... in (...)) or an array CHECK-constrained to
--     be a subset of a closed enum. An unknown operation, an invalid scope, an invalid aggregation
--     rule and an unknown source category are all rejected by the TABLE, at insert time.
--   · there is NO column that can hold SQL, a formula, a dynamic expression, a consumer name that is
--     interpreted, or player-authored text. engine_consumer is documentation: nothing dispatches on
--     it, nothing executes it.
--   · fleet_aggregation is NOT NULL — "missing mandatory aggregation policy" is unrepresentable.
create table public.stat_definitions (
  -- COLLATE "C": the id column IS a total order used for deterministic breakdown ordering — byte
  -- order pinned so a locale upgrade can never re-order a result (the 0186/0205 collation law).
  stat_id            text collate "C" primary key,
  catalog_key        text collate "C" not null unique,
  display_name       text not null,
  display_order      integer not null unique,
  applies_to_scope   text not null check (applies_to_scope in ('ship','fleet','both')),
  value_kind         text not null check (value_kind in ('flat','fraction','multiplier')),
  unit               text not null,
  numeric_domain     text not null check (numeric_domain in ('integer','numeric')),
  round_to           integer not null check (round_to between 0 and 4),
  min_value          numeric,
  max_value          numeric,
  ship_base_source   text not null check (ship_base_source in ('none','instance_column','hull_column')),
  ship_base_ref      text,
  combination_class  text not null check (combination_class in ('additive','multiplier_bonus')),
  permitted_operations   text[] not null
    check (permitted_operations <@ array['base_override','flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[]),
  permitted_source_kinds text[] not null
    check (permitted_source_kinds <@ array['hull','trait','module','captain','command_ship','consumable','zone','event','debug','speed_penalty']::text[]),
  fleet_aggregation  text not null check (fleet_aggregation in
                       ('sum','min','max','average','weighted_average','primary_ship','none')),
  fleet_weight_stat  text collate "C" references public.stat_definitions (stat_id),
  combat_snapshot    text not null check (combat_snapshot in ('frozen','live','not_applicable')),
  combat_snapshot_live_reader text,
  engine_consumer    text,
  presentation_consumer text,
  deprecated_reason  text,
  revision           integer not null default 1 check (revision >= 1),

  -- ── LIFECYCLE (owner ruling, 2026-08-04). THE stat's standing, and the ONLY thing that decides
  --    whether it is computed at all. NO DEFAULT, on purpose: an INSERT that forgets to declare a
  --    lifecycle is REJECTED rather than silently promoted to a live gameplay stat. Any value
  --    outside the three is rejected by the CHECK. Fail closed at both ends.
  --
  --      active     — has an APPROVED gameplay (engine_consumer) or presentation
  --                   (presentation_consumer) consumer. Computed on the routine resolution path.
  --      dormant    — catalogued, NO consumer of any kind. NEVER computed on a routine resolution
  --                   path; it is absent from the routine registry snapshot, so the resolver cannot
  --                   reach it even by accident. It is resolvable ONLY through an explicitly
  --                   requested, authorized INSPECTION call, and even then its value is returned in
  --                   a separate `dormant` map carrying effective=false — never in `stats`, so no
  --                   client can describe it as an effective number.
  --      deprecated — legacy compatibility only. Still computed for its existing readers, but
  --                   engine_consumer MUST be null: it is forbidden to NEW gameplay consumers, and
  --                   the table is what forbids it.
  --
  --    THIS COLUMN REPLACED `is_active boolean`. Two columns deciding one question — "is this stat
  --    in play?" — is spaghetti, and the boolean could not express the three standings the owner
  --    named. It is folded, not doubled: there is exactly one lifecycle authority and every
  --    resolver reads it through the registry snapshot.
  lifecycle          text not null check (lifecycle in ('active','dormant','deprecated')),

  -- ── SUPERSESSION (the cargo re-ruling). A row may name the stat it is the canonical replacement
  --    for, together with the unit conversion between them. unit_conversion is a CLOSED enum, not
  --    free text: today the only expressible conversion is 'identity', so an undefined conversion
  --    is NULL and cannot be faked by writing a sentence into a text column. Adding a real
  --    conversion means adding an enum value in a migration — a reviewed act, not an edit.
  supersedes_stat_id text collate "C" references public.stat_definitions (stat_id),
  unit_conversion    text check (unit_conversion in ('identity')),
  intended_source_kinds text[] not null default '{}'::text[]
    check (intended_source_kinds <@ array['hull','trait','module','captain','command_ship','consumable','zone','event','debug','speed_penalty']::text[]),

  registered_in      text not null,
  constraint stat_definitions_base_ref_coherent
    check ((ship_base_source = 'none') = (ship_base_ref is null)),
  constraint stat_definitions_weight_coherent
    check ((fleet_aggregation = 'weighted_average') = (fleet_weight_stat is not null)),
  -- A fraction or a multiplier can NEVER be summed across a fleet. Eight ships each at +10% speed
  -- are not a fleet at +80% speed. This CHECK is what makes "blanket summing" unrepresentable
  -- rather than merely discouraged.
  constraint stat_definitions_no_blanket_sum
    check (fleet_aggregation <> 'sum' or value_kind = 'flat'),
  -- A stat that declares combat_snapshot='live' MUST name the function that re-reads it. A live
  -- re-read with no named reader is exactly the undocumented asymmetry this registry exists to end.
  constraint stat_definitions_live_reader_coherent
    check ((combat_snapshot = 'live') = (combat_snapshot_live_reader is not null)),
  constraint stat_definitions_clamp_coherent
    check (min_value is null or max_value is null or min_value <= max_value),

  -- ── THE LIFECYCLE LAW, enforced by the table so that no review step is load-bearing.
  -- active REQUIRES an approved consumer. "Active because a catalog mentions it" is exactly the
  -- error this closes: prior implementation effort does not create gameplay semantics.
  constraint stat_definitions_active_needs_consumer
    check (lifecycle <> 'active'
           or engine_consumer is not null or presentation_consumer is not null),
  -- dormant FORBIDS every consumer. The moment a stat acquires one it must be promoted in a
  -- migration, which is a decision, not a drift.
  constraint stat_definitions_dormant_has_no_consumer
    check (lifecycle <> 'dormant'
           or (engine_consumer is null and presentation_consumer is null)),
  -- deprecated is legacy compatibility ONLY: it may keep a display reader, it may NEVER hold a
  -- gameplay consumer, and it must say why it is deprecated.
  constraint stat_definitions_deprecated_is_legacy_only
    check (lifecycle <> 'deprecated'
           or (deprecated_reason is not null and engine_consumer is null)),
  -- ...and a deprecation reason may not be attached to a stat that is not deprecated, so the two
  -- can never disagree about which stats are legacy.
  constraint stat_definitions_reason_only_when_deprecated
    check (deprecated_reason is null or lifecycle = 'deprecated'),
  -- ── THE SUPERSESSION LAW.
  constraint stat_definitions_supersedes_not_self
    check (supersedes_stat_id is null or supersedes_stat_id <> stat_id),
  constraint stat_definitions_conversion_needs_supersession
    check (unit_conversion is null or supersedes_stat_id is not null),
  -- THE CARGO GUARD, structural (the 20260618000333 precedent: enforce, never comment). A stat
  -- that supersedes another but has NO DEFINED CONVERSION may accept NOTHING — no operation, no
  -- source category. This is what makes "do not copy the legacy integer into the volume field"
  -- impossible rather than merely forbidden: with both permitted lists empty, stat_combine raises
  -- on any contribution aimed at it, whatever the contribution's origin.
  constraint stat_definitions_undefined_conversion_accepts_nothing
    check (supersedes_stat_id is null or unit_conversion is not null
           or (permitted_operations = '{}'::text[] and permitted_source_kinds = '{}'::text[])),
  -- Nothing may be PERMITTED that was never declared INTENDED. Widening the resolver's input
  -- surface therefore requires editing the declared intent first, in the same reviewed row.
  constraint stat_definitions_permitted_within_intended
    check (permitted_source_kinds <@ intended_source_kinds)
);

comment on table public.stat_definitions is
  'STAT FOUNDATION (0340): THE controlled stat vocabulary. One row adds an ordinary stat. Every '
  'behavioural field is a closed enum or a subset-constrained array — unknown stats, unknown '
  'operations, invalid scopes and invalid aggregation rules are rejected by the table. No column '
  'holds SQL, a formula, an expression or player-authored text. Reference/Config: migration-seeded '
  'only, no runtime writer, ever.';
comment on column public.stat_definitions.catalog_key is
  'The legacy INPUT key a catalog writes in its stats_json (attack/defense/scan/...). stat_id is the '
  'OUTPUT name consumers already use. Both are preserved exactly, so the seed is behaviour-neutral.';
comment on column public.stat_definitions.permitted_source_kinds is
  'The source categories permitted to contribute to this stat. An empty array means NO source may '
  'contribute — the posture of a deprecated display-only legacy stat.';
comment on column public.stat_definitions.combat_snapshot is
  'frozen = captured once at encounter creation; live = re-read every tick (and then '
  'combat_snapshot_live_reader MUST name the re-reading function); not_applicable = the stat plays '
  'no part in combat. Declaring this per stat is what stops the frozen/live split from being an '
  'accident rediscovered by reading two migrations five hundred lines apart.';
comment on column public.stat_definitions.engine_consumer is
  'DOCUMENTATION ONLY — nothing dispatches on it and nothing executes it. Names the one function '
  'that DECIDES something with this stat, or NULL when no gameplay path decides anything with it.';
comment on column public.stat_definitions.presentation_consumer is
  'DOCUMENTATION ONLY. Names the one client surface that DISPLAYS this stat to a player. A stat '
  'with neither an engine nor a presentation consumer cannot be active — that is the table''s rule, '
  'not a convention.';
comment on column public.stat_definitions.deprecated_reason is
  'Non-null = this stat is legacy and must not be given new consumers or new contributions. It is '
  'permitted only on lifecycle = deprecated, so the two can never disagree.';
comment on column public.stat_definitions.lifecycle is
  'active = has an approved gameplay or presentation consumer, computed on the routine resolution '
  'path. dormant = catalogued with NO consumer; absent from the routine registry snapshot, so it '
  'is never computed on a routine path and is returned only by an explicitly requested authorized '
  'inspection call, in a separate map marked effective=false. deprecated = legacy compatibility '
  'only, still computed for existing readers, forbidden to new gameplay consumers. No default: an '
  'undeclared lifecycle is rejected.';
comment on column public.stat_definitions.supersedes_stat_id is
  'This stat is the canonical replacement for the named one. While unit_conversion is NULL the '
  'conversion is UNDEFINED and the table forbids this stat from accepting any contribution at all.';
comment on column public.stat_definitions.unit_conversion is
  'A CLOSED enum, never free text, so an undefined conversion cannot be faked with a sentence. '
  'NULL = undefined. Defining a real conversion means adding an enum value in a migration.';
comment on column public.stat_definitions.intended_source_kinds is
  'The source categories this stat is INTENDED to accept once its architecture is complete — a '
  'declaration of design intent that executes nothing. permitted_source_kinds must always be a '
  'subset of it, so widening what the resolver accepts requires stating the intent first.';

alter table public.stat_definitions enable row level security;
-- Explicit REVOKE, never a mere assert of absence: a Supabase project-default GRANT ALL to anon
-- aborted migration 0254 on its own self-assert. Strip first, then grant exactly select.
revoke all on table public.stat_definitions from public, anon, authenticated;
create policy "stat_definitions_public_read" on public.stat_definitions for select using (true);
grant select on table public.stat_definitions to anon, authenticated;
revoke insert, update, delete on table public.stat_definitions from anon, authenticated;

-- ── 1a. THE SEED — the deployed vocabulary, transcribed as data (contract §3.3) ───────────────────
-- TEN rows: the nine keys the deployed fold emits, plus cargo_volume_m3, the canonical cargo target.
-- stat_id is what calculate_expedition_stats EMITS; catalog_key is what the catalogs WRITE. Both are
-- copied from the live fold, so the vocabulary asserts nothing new about the game.
--
-- LIFECYCLE IS THE LOAD-BEARING FIELD HERE, and it is decided per row on EVIDENCE:
--   active     (3)  combat_power, survival, speed — each names the function that decides with it.
--   deprecated (1)  cargo_capacity — legacy display integer, forbidden a gameplay consumer.
--   dormant    (6)  cargo_volume_m3 (canonical target, conversion not activated) and the five
--                   confirmed-dead outputs: repair, scouting, mining_yield, retreat_safety,
--                   pirate_attention.
--
-- THE OWNER'S RULING THIS ENCODES: "Do not automatically seed these as active canonical gameplay
-- stats merely because old functions or catalogs mention them… Prior implementation effort does not
-- create gameplay semantics." A stat is active because something DECIDES with it, never because
-- something once computed it.
--
-- The two owner-decided aggregation corrections (contract §14 D3, option A) are still recorded:
--   scouting       sum -> max   (detection is intensive: the fleet sees as far as its best sensor)
--   retreat_safety sum -> min   (evasion is weakest-link: a fleet escapes as cleanly as its most
--                                exposed ship)
-- Both stats are dormant, so neither correction can move a gameplay number — it is preserved so the
-- decision survives until a consumer justifies promotion.
insert into public.stat_definitions (
  stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
  numeric_domain, round_to, min_value, max_value, ship_base_source, ship_base_ref,
  combination_class, permitted_operations, permitted_source_kinds, intended_source_kinds,
  fleet_aggregation, fleet_weight_stat, combat_snapshot, combat_snapshot_live_reader,
  engine_consumer, presentation_consumer, deprecated_reason, lifecycle,
  supersedes_stat_id, unit_conversion, registered_in) values

  -- ACTIVE. Both are frozen into combat_units at encounter creation and DECIDED upon there: the
  -- live combat_create_group_encounter head is 20260618000301:661, combat_power -> attack_snapshot
  -- and survival -> combat_units.defense at 0301:744.
  ('combat_power', 'attack', 'Combat Power', 10, 'both', 'flat', 'points',
   'numeric', 2, 0, null, 'none', null,
   'additive', array['flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   'sum', null, 'frozen', null,
   'combat_create_group_encounter', 'src/features/command/TeamPreviewSection.tsx', null, 'active',
   null, null, '0340'),

  ('survival', 'defense', 'Survival', 20, 'both', 'flat', 'points',
   'numeric', 2, 0, null, 'none', null,
   'additive', array['flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   'sum', null, 'frozen', null,
   'combat_create_group_encounter', 'src/features/command/TeamPreviewSection.tsx', null, 'active',
   null, null, '0340'),

  -- speed: the ONE multiplier stat. Base is the hull column (read LIVE on every fold today, never
  -- copied to the instance — contract §0 correction 1). min_value 0.2 is the deployed floor at
  -- 0205:662. Fleet rule is MIN: a fleet arrives together, so it travels at its slowest ship —
  -- already the rule in three independent places (0166:129-135, the mover's three inline copies at
  -- 0330:1473/:1715/:1790, and combat's combat_fleet_move_speed, whose LIVE head is
  -- 20260618000339_a_fight_you_can_move_in.sql:637 — 0339 re-created it as min(move_speed) scaled by
  -- greatest(cfg_num('combat_reposition_speed_scale'), 0). Any speed reasoning must use the 0339
  -- body, NOT the superseded 0337:133-146 one.)
  -- ACTIVE: command_ship_group_go reads totals.speed at 0330:777 and REFUSES the movement command
  -- when it is not > 0. Refusing a command is a decision, so speed has a gameplay consumer.
  ('speed', 'speed_mult_bonus', 'Speed', 30, 'both', 'multiplier', 'wu_per_second',
   'numeric', 3, 0.2, null, 'hull_column', 'base_speed',
   'multiplier_bonus', array['base_override','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['trait','module','captain','command_ship','speed_penalty','consumable','zone','event','debug']::text[],
   array['trait','module','captain','command_ship','speed_penalty','consumable','zone','event','debug']::text[],
   'min', null, 'frozen', null,
   'command_ship_group_go', null, null, 'active',
   null, null, '0340'),

  -- ── CARGO, AFTER THE OWNER'S RE-RULING (2026-08-04) ────────────────────────────────────────────
  -- The census was run and the ruling changed: cargo modules, captain effects and cargo traits ARE
  -- intended to affect real ship-bound VOLUME capacity. The canonical cargo stat is therefore volume
  -- in m3, and the unitless integer is legacy. What this slice may NOT do, and does not do:
  --   · it does NOT copy the existing +25 into the volume field — no unit conversion is defined and
  --     inventing one is forbidden;
  --   · it does NOT change a single live hold size;
  --   · it does NOT make the integer a second gameplay stat.
  -- So the canonical target is MODELLED, with provenance, and THE CONVERSION IS NOT ACTIVATED. The
  -- TABLE is what enforces that, not this comment: cargo_volume_m3 supersedes cargo_capacity with
  -- unit_conversion NULL, and stat_definitions_undefined_conversion_accepts_nothing then makes both
  -- of its permitted lists necessarily empty — so no module, trait or captain contribution can reach
  -- the volume field by ANY route, including one that reads the legacy `cargo` key. That is the
  -- 20260618000333:1926-1929 precedent (which forbids fleet_hold_capacity_m3 from reading the dead
  -- integer columns) re-expressed as a CONSTRAINT instead of a text scan.
  -- Conversion, hold-size changes, the treatment of already-fitted modules and the player-impact
  -- proof belong to a separate migration.
  --
  -- cargo_capacity: DEPRECATED, not merely "quarantined". It keeps its display reader
  -- (TeamDossier.tsx:131 renders the 'Cargo cap' chip) and can NEVER acquire a gameplay one —
  -- stat_definitions_deprecated_is_legacy_only forbids engine_consumer on a deprecated row.
  ('cargo_capacity', 'cargo', 'Cargo Capacity (legacy, display-only)', 40, 'ship', 'flat', 'points',
   'integer', 0, 0, null, 'instance_column', 'cargo_capacity',
   'additive', array[]::text[],
   array[]::text[], array[]::text[],
   'sum', null, 'not_applicable', null,
   null, 'src/features/command/TeamDossier.tsx',
   'DEPRECATED legacy display integer, non-authoritative. The canonical cargo authority is the '
   'ship-bound volume capacity in m3 (cargo_volume_m3 here; fleet_hold_capacity_m3 / '
   'fleet_hold_used_m3 in migration 20260618000333). This unitless number is differently unitised, '
   'drives no decision, takes no contributions, and must not be given new consumers. The unit '
   'conversion, any hold-size change, the treatment of already-fitted modules and the player-impact '
   'proof are a SEPARATE migration.',
   'deprecated', null, null, '0340'),

  -- cargo_volume_m3: THE CANONICAL TARGET, DORMANT. Its base is the ship's REAL cargo_capacity_m3
  -- column (added by 20260618000076), so an inspection reports the true ship-bound volume rather
  -- than a fabricated 0 — and its permitted lists are empty, so the +25 cargo module contributes
  -- NOTHING to it. intended_source_kinds records where those contributions WILL come from once a
  -- conversion exists; it executes nothing and permits nothing. Fleet rule is sum, matching
  -- fleet_hold_capacity_m3 (0333:402-421), which sums cargo_capacity_m3 over the fleet's ships.
  ('cargo_volume_m3', 'cargo_volume_m3', 'Cargo Volume', 45, 'both', 'flat', 'm3',
   'numeric', 2, 0, null, 'instance_column', 'cargo_capacity_m3',
   'additive', array[]::text[],
   array[]::text[],
   array['hull','trait','module','captain']::text[],
   'sum', null, 'not_applicable', null,
   null, null, null, 'dormant',
   'cargo_capacity', null, '0340'),

  -- ── THE FIVE CONFIRMED-DEAD OUTPUTS, SEEDED DORMANT (owner ruling, 2026-08-04) ─────────────────
  -- "Do not automatically seed these as active canonical gameplay stats merely because old functions
  -- or catalogs mention them… Prior implementation effort does not create gameplay semantics."
  --
  -- Verified consumer-free by replaying the chain, not by counting text: all five are accumulated by
  -- calculate_expedition_stats, re-summed by calculate_group_expedition_stats (0166:121-126),
  -- emitted and rendered — and no branch, comparison or threshold anywhere reads them. `repair` in
  -- particular is NOT the repair verb's input: 20260618000335_one_way_to_repair.sql and
  -- 20260618000336_combat_engine_repairs.sql contain no reference to a 'repair' stat key at all, and
  -- the repair economy prices off repair_credits_per_hp. `survival` is deliberately NOT among them:
  -- it is a real engine consumer (0301:744 -> combat_units.defense).
  --
  -- DORMANT IS NOT A LABEL, IT IS A BEHAVIOUR: these rows are absent from the routine registry
  -- snapshot, so no routine resolution gathers a contribution to them, folds them, aggregates them
  -- or emits them. The two aggregation corrections the owner already decided (D3-A: scouting
  -- sum->max, retreat_safety sum->min) are still recorded here so the decision is not lost when a
  -- consumer eventually justifies promoting them.
  ('repair', 'repair', 'Repair', 50, 'both', 'flat', 'points',
   'numeric', 2, 0, null, 'none', null,
   'additive', array['flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   'sum', null, 'not_applicable', null,
   null, null, null, 'dormant', null, null, '0340'),

  -- scouting: MAX (owner decision D3-A). Detection quality is intensive.
  ('scouting', 'scan', 'Scouting', 60, 'both', 'flat', 'points',
   'numeric', 2, 0, null, 'none', null,
   'additive', array['flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   'max', null, 'not_applicable', null,
   null, null, null, 'dormant', null, null, '0340'),

  ('mining_yield', 'mining', 'Mining Yield', 70, 'both', 'flat', 'points',
   'numeric', 2, 0, null, 'none', null,
   'additive', array['flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   'sum', null, 'not_applicable', null,
   null, null, null, 'dormant', null, null, '0340'),

  -- retreat_safety: MIN (owner decision D3-A). Evasion is weakest-link.
  ('retreat_safety', 'evasion', 'Retreat Safety', 80, 'both', 'flat', 'points',
   'numeric', 2, 0, null, 'none', null,
   'additive', array['flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   'min', null, 'not_applicable', null,
   null, null, null, 'dormant', null, null, '0340'),

  -- pirate_attention: DORMANT **DESPITE** 0331 having widened it across four catalog surfaces.
  -- 20260618000331_one_authority_for_attack.sql taught four stats_json catalogs to state it —
  -- ship traits (:471-475), command buffs (:493-496), modules (:500-508) and captains (:511-519),
  -- exactly the four its own assert loop enumerates at :749-759 — plus the hull base_stats_json at
  -- :454. NOTHING reads it. The pirate chain is pirate_intercept_plan_leg (0301:484) ->
  -- pirate_intercept_compute_risk (0233:335-355) -> typed_zone_pirate_candidates_v1 (0279:108), and
  -- every one of them takes combat_power + survival and nothing else; there is no attention term in
  -- pirate behaviour anywhere. 0331 records at :123 that no seeded catalog row even carries the key
  -- ("Byte-inert"), so what actually shipped was four surfaces PROMISING an effect that does not
  -- exist. Widening a stat across four more surfaces is not a consumer, and prior implementation
  -- effort does not create gameplay semantics. It stays dormant, it is not computed on any routine
  -- path, and this slice removes the client rows that presented it as an effective total.
  ('pirate_attention', 'pirate_attention', 'Pirate Attention', 90, 'both', 'flat', 'points',
   'numeric', 2, 0, null, 'none', null,
   'additive', array['flat','additive_pct','multiplicative_pct','clamp_min','clamp_max']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   array['hull','trait','module','captain','command_ship','consumable','zone','event','debug']::text[],
   'sum', null, 'not_applicable', null,
   null, null, null, 'dormant', null, null, '0340')

on conflict (stat_id) do nothing;

-- Ranges are DELIBERATELY absent from the registry, at either scope. Weapon range lives per weapon
-- in combat_units.weapons_json and aggregating it has already caused a shipped defect: freezing
-- my_range = max(range) per ship silently disabled a shorter gun on the same hull (0336:35-40). Any
-- future range stat must carry fleet_aggregation = 'none'.

-- ── 2. PROGRESSION — the XP authority ────────────────────────────────────────────────────────────
-- NO other function in this repository may carry an XP table or a level formula after the later
-- cutover slice. This slice establishes the authority; it retires nothing yet.
create table public.progression_curves (
  curve_id           text collate "C" primary key,
  kind               text not null check (kind in ('quadratic')),
  coefficient        numeric not null check (coefficient > 0),
  max_level          integer check (max_level is null or max_level >= 1),
  post_cap_behaviour text not null check (post_cap_behaviour in ('accumulate_xp_no_level','hard_stop')),
  registered_in      text not null
);

comment on table public.progression_curves is
  'STAT FOUNDATION (0340): THE level curve authority. kind=''quadratic'' means, and ONLY means, '
  'xp_for_level(L) = (L-1)^2 * coefficient and level_for_xp(x) = 1 + floor(sqrt(x / coefficient)). '
  'There is no formula column and no expression column: the shape is a closed enum and the only '
  'free parameter is a number.';

create table public.progression_tracks (
  track_id      text collate "C" primary key,
  entity_scope  text not null check (entity_scope in ('captain','ship','fleet','player')),
  curve_id      text not null references public.progression_curves (curve_id),
  xp_store      text not null check (xp_store in ('captain_instances')),
  is_active     boolean not null default true,
  registered_in text not null
);

comment on table public.progression_tracks is
  'STAT FOUNDATION (0340): the registered progression tracks. EXACTLY ONE is registered — captain_v1 '
  '— because XP exists on exactly one entity in this game. Ship XP, fleet XP and player level are '
  'DELIBERATELY not stubbed: registering an empty track for content that does not exist is the same '
  '"lit but inert" trap that produced five consumer-less stats. A track is registered when its XP '
  'source exists. xp_store is a closed enum, so a track can never name an arbitrary table.';

alter table public.progression_curves enable row level security;
revoke all on table public.progression_curves from public, anon, authenticated;
create policy "progression_curves_public_read" on public.progression_curves for select using (true);
grant select on table public.progression_curves to anon, authenticated;
revoke insert, update, delete on table public.progression_curves from anon, authenticated;

alter table public.progression_tracks enable row level security;
revoke all on table public.progression_tracks from public, anon, authenticated;
create policy "progression_tracks_public_read" on public.progression_tracks for select using (true);
grant select on table public.progression_tracks to anon, authenticated;
revoke insert, update, delete on table public.progression_tracks from anon, authenticated;

-- THE DEPLOYED CURVE, PRESERVED BIT FOR BIT. 0177:270 maintains
--     level = 1 + floor(sqrt((ci.xp + f.xp) / 100.0))::integer
-- and src/features/captains/captainProgress.ts:23/:29 mirrors it. coefficient = 100 reproduces both.
--
-- THE CAP (owner decision, contract §14 D1, option A): functional cap 99, owned HERE by the track's
-- curve and nowhere else — there is no literal 99 in any consumer. XP remains authoritative and
-- keeps accumulating past the cap (post_cap_behaviour = 'accumulate_xp_no_level'); only the LEVEL,
-- and therefore the stat multiplier that reads it, stops. Post-cap progression has no stat effect.
insert into public.progression_curves (curve_id, kind, coefficient, max_level, post_cap_behaviour, registered_in)
values ('captain_v1_quadratic_100', 'quadratic', 100, 99, 'accumulate_xp_no_level', '0340')
on conflict (curve_id) do nothing;

insert into public.progression_tracks (track_id, entity_scope, curve_id, xp_store, is_active, registered_in)
values ('captain_v1', 'captain', 'captain_v1_quadratic_100', 'captain_instances', true, '0340')
on conflict (track_id) do nothing;

-- ── 3. BUFFS — definition (catalog) and instance (state), separated by construction ───────────────
create table public.buff_definitions (
  buff_def_id      text collate "C" primary key,
  source_kind      text not null check (source_kind in ('command_ship','consumable','zone','event','debug')),
  target_scope     text not null check (target_scope in ('ship','fleet')),
  stat_id          text collate "C" not null references public.stat_definitions (stat_id),
  operation        text not null check (operation in
                     ('base_override','flat','additive_pct','multiplicative_pct','clamp_min','clamp_max')),
  magnitude        numeric not null,
  magnitude_per_level numeric,
  progression_track   text collate "C" references public.progression_tracks (track_id),
  stacking_group   text collate "C" not null,
  stacking_policy  text not null check (stacking_policy in
                     ('stack_all','highest_magnitude','latest_only','longest_remaining','first_only')),
  evaluation_order integer not null,
  duration_kind    text not null check (duration_kind in ('permanent','timed','while_source_holds')),
  default_duration_seconds integer check (default_duration_seconds is null or default_duration_seconds > 0),
  -- {key: scalar} or {key: [scalar, ...]}. MATCHED BY EQUALITY AGAINST p_context ONLY. Never parsed,
  -- never evaluated, never executed. A deploy-time assert walks every seeded row and refuses any
  -- value that is not a scalar or an array of scalars.
  context_restriction jsonb not null default '{}'::jsonb,
  is_active        boolean not null default true,
  registered_in    text not null,
  constraint buff_definitions_duration_coherent
    check ((duration_kind = 'timed') = (default_duration_seconds is not null)),
  constraint buff_definitions_level_scale_coherent
    check ((magnitude_per_level is null) = (progression_track is null)),
  constraint buff_definitions_context_is_object
    check (jsonb_typeof(context_restriction) = 'object')
);

comment on table public.buff_definitions is
  'STAT FOUNDATION (0340): THE buff catalog. NO EXECUTABLE EXPRESSION IS EVER STORED: magnitude is '
  'numeric, operation is a CHECK-constrained enum, and context_restriction is matched by EQUALITY '
  'against the caller-supplied context only. There is no formula column, no eval, no execute. A buff '
  'magnitude may be a constant, or a constant scaled by a progression LEVEL — never a function of a '
  'resolved stat, which is the single prohibition that keeps the resolver graph acyclic.';

create table public.buff_instances (
  buff_instance_id   uuid primary key default gen_random_uuid(),
  buff_def_id        text collate "C" not null references public.buff_definitions (buff_def_id),
  target_scope       text not null check (target_scope in ('ship','fleet')),
  target_entity_id   uuid not null,
  source_instance_id uuid,
  granted_at         timestamptz not null default now(),
  starts_at          timestamptz not null,
  expires_at         timestamptz,
  magnitude_override numeric,
  -- The idempotency key AND the duplicate-source-identity guard in one: the same definition, from
  -- the same source, on the same target, can exist exactly once.
  unique (buff_def_id, target_scope, target_entity_id, source_instance_id),
  constraint buff_instances_window_valid
    check (expires_at is null or expires_at > starts_at)
);

comment on table public.buff_instances is
  'STAT FOUNDATION (0340): active buff STATE. Sole writers are buff_grant / buff_revoke '
  '(service-role only). Empty at migration time and empty until a consumer slice grants something. '
  'Command-ship buffs are NOT stored here — they are DERIVED (see buff_derive_source_instances), '
  'which removes an entire class of desync bug: there is no reconciler to fall behind membership '
  'changes, and "what is buffing me" has exactly one producer.';

create index buff_instances_target_idx on public.buff_instances (target_scope, target_entity_id);

alter table public.buff_definitions enable row level security;
revoke all on table public.buff_definitions from public, anon, authenticated;
create policy "buff_definitions_public_read" on public.buff_definitions for select using (true);
grant select on table public.buff_definitions to anon, authenticated;
revoke insert, update, delete on table public.buff_definitions from anon, authenticated;

alter table public.buff_instances enable row level security;
revoke all on table public.buff_instances from public, anon, authenticated;
create policy "buff_instances_public_read" on public.buff_instances for select using (true);
grant select on table public.buff_instances to anon, authenticated;
revoke insert, update, delete on table public.buff_instances from anon, authenticated;

-- ── 3a. The 20 command_buff_types rows become the first registered buff source ────────────────────
-- SEEDED FROM THE CATALOG ITSELF, not transcribed. A hand-copied seed is a 20-row opportunity to
-- mistype a magnitude; this INSERT ... SELECT joins command_buff_types to stat_definitions through
-- catalog_key, so the definitions cannot disagree with the catalog they came from, today or after a
-- future catalog edit.
--
-- One row per (buff, stat) pair — a buff like t0_vanguard_command ({"attack":2,"defense":2}) touches
-- two stats and the model is one stat per definition.
--
-- Operation mapping, reproducing the deployed fold EXACTLY:
--   speed_mult_bonus -> additive_pct on `speed`  (0205:662 sums the bonuses inside ONE multiplier)
--   everything else  -> flat on its registered stat
--
-- Stacking: today the fold loops over EVERY is_command_ship row in the group and sums (0205:465-483)
-- — the index is not unique (0204:75-76) and set_fleet_command_ship never clears another ship's flag
-- (0204:117-119), so N flagged ships means N buffs summed with no rule saying so. That behaviour is
-- preserved and finally NAMED: stacking_policy = 'stack_all', stacking_group = 'command_doctrine:'
-- || stat_id. Changing it to one-doctrine-per-fleet is a one-row edit and a gameplay decision, not
-- an architecture one.
insert into public.buff_definitions (
  buff_def_id, source_kind, target_scope, stat_id, operation, magnitude,
  magnitude_per_level, progression_track, stacking_group, stacking_policy, evaluation_order,
  duration_kind, default_duration_seconds, context_restriction, is_active, registered_in)
select
  cbt.buff_id || ':' || d.stat_id,
  'command_ship',
  'fleet',
  d.stat_id,
  case when d.stat_id = 'speed' then 'additive_pct' else 'flat' end,
  (cbt.stats_json ->> d.catalog_key)::numeric,
  null,
  null,
  'command_doctrine:' || d.stat_id,
  'stack_all',
  100,
  'while_source_holds',
  null,
  '{}'::jsonb,
  true,
  '0340'
from public.command_buff_types cbt
join public.stat_definitions d
  on cbt.stats_json ? d.catalog_key
where jsonb_typeof(cbt.stats_json -> d.catalog_key) = 'number'
  -- ACTIVE ONLY. A buff definition is a contribution SOURCE, and a source aimed at a stat nothing
  -- consumes is the same lit-but-inert trap this slice exists to end — worse here, because a stored
  -- contribution to a stat that is absent from the routine snapshot would make stat_combine raise on
  -- an ordinary ship. The catalog's scan/mining/evasion/repair command buffs are therefore NOT
  -- registered while those stats are dormant. Promoting a stat is a migration, and that migration
  -- re-runs this seed; it is not something a catalog edit can do by itself.
  and d.lifecycle = 'active'
  and array_length(d.permitted_source_kinds, 1) is not null
  and 'command_ship' = any (d.permitted_source_kinds)
on conflict (buff_def_id) do nothing;

-- ── 4. NO FEATURE FLAG. Deliberately. ────────────────────────────────────────────────────────────
-- See the header. A flag that gates nothing is not a safety device, it is a lie about one. The
-- safety in this slice is structural and asserted at the bottom of this file: the live engine
-- functions carry ZERO token from here, so nothing can reach this code by accident.
--
-- THE SIX LIVE CALLERS OF THE PREDECESSOR AUTHORITY, for the record and for the parity harness.
-- calculate_group_expedition_stats(p_player, p_group_id, p_activity_type) — 0166:58, never
-- redefined — is the real fleet authority this foundation will eventually retire. It is often cited
-- as having "~15 call sites"; that is a count of TEXTUAL OCCURRENCES, most of which sit inside
-- function bodies a later migration re-created or dropped. Resolved by replaying the chain (latest
-- create-or-replace, then every later slice-hunk and drop) there are SIX live callers reading
-- exactly THREE key-shapes:
--
--   A1  command_ship_group_go          0330:777   totals.speed            min  (correct today)
--   A2  command_ship_group_dock        0330:1018  totals.speed            min; the value is then
--                                                 DISCARDED — the call exists only to satisfy
--                                                 movement_create's speed_used > 0 contract, and
--                                                 the path is itself dark (timed_docking_enabled)
--   A3  pirate_intercept_plan_leg      0301:542   combat_power + survival sum of two sums. NOTE: it
--                                                 FAILS OPEN — any raise sets v_combined := 0
--                                                 (0301:545-547), which reads as MAXIMUM pirate
--                                                 risk. A live hazard, recorded here, NOT fixed by
--                                                 this slice.
--   A4  process_pirate_route_legs      0301:2387  totals.speed            min; on failure it DELETES
--                                                 the fleet's remaining route
--   A5  pirate_intercept_preview_route 0233:1295  combat_power + survival UNREACHABLE — 0309 revoked
--                                                 EXECUTE from every client role and no server
--                                                 function calls it
--   A6  get_my_group_expedition_totals 0166:206   the WHOLE envelope, re-emitted verbatim — the only
--                                                 client door
--
-- The most-cited caller, pirate_intercept_evaluate_leg, was DROPPED at 0301:2457; its call is dead.
--
-- So the parity surface is three shapes: `speed` (min — already correct, so a NO-DIFFERENCE
-- expectation), `combat_power + survival` (both sum — also no difference), and the display
-- envelope. The ONLY intended differences are scouting (sum->max) and retreat_safety (sum->min),
-- both of which have zero engine consumers, plus the empty-fleet behaviour (the predecessor RAISES
-- empty_group at 0166:105; the canonical aggregation returns an explicit not_applicable result).
--
-- FIVE OUTPUT KEYS ARE DEAD — computed on every call and read by nothing, server or client:
-- retreat_safety, scouting, mining_yield, repair, pirate_attention. pirate_attention was newly
-- widened across four catalog surfaces by 0331 and STILL has no reader. All five are registered
-- with engine_consumer = null, which makes "display-only" a declared fact instead of a discovery.
-- survival is NOT among them: it is a real engine consumer (0301:744 -> combat_units.defense).

-- ── 5. THE PURE LEAVES — table-free, deterministic, and therefore provable on an EMPTY database ────
-- This split is the whole reason section 12's deploy-time equivalence assert is NON-VACUOUS: it
-- calls these leaves with a hard-coded contribution set and compares against the deployed expression
-- spelled out inline. It reads no game row, so it runs identically on a fresh disposable chain and
-- on production. Data-dependent parity lives in the CI proof, which builds its own fixtures.

-- stat_raise_malformed — the refusal leaf. A malformed source value is NEVER coalesced into a
-- plausible stat; it names the offending row and aborts. Returns numeric only so it can be used in
-- value position inside the gatherer's CASE.
create function public.stat_raise_malformed(p_source_kind text, p_source_id text, p_key text)
returns numeric
language plpgsql
immutable
as $$
begin
  raise exception 'STAT-FOUNDATION malformed contribution: source_kind=% source_id=% key=% is present but is not a JSON number. Refusing to fabricate a stat from malformed source data.',
    coalesce(p_source_kind, '(null)'), coalesce(p_source_id, '(null)'), coalesce(p_key, '(null)');
end;
$$;

-- stat_registry_snapshot — the registry as ONE ordered jsonb, stamped with its version. Every
-- resolver result carries registry_version, so a snapshot taken under version 6 stays legible
-- forever and a consumer can REFUSE a snapshot it does not understand instead of mis-reading it.
--
-- LIFECYCLE SCOPE — the ONE place that decides which stats exist for a given call:
--   'routine'    (the default, and what every gameplay path will ever get) — active + deprecated.
--                DORMANT STATS ARE ABSENT FROM THE SNAPSHOT ENTIRELY. They are therefore not
--                computed, not aggregated, not emitted and not reachable: a routine caller cannot
--                opt into them, because there is nothing to opt into.
--   'inspection' — all three lifecycles, for the authorized inspection door only. Dormant values
--                are still segregated downstream into a `dormant` map marked effective=false.
-- An unrecognised scope RAISES. There is no permissive fallback.
-- stat_lifecycle_in_scope — THE lifecycle rule, in ONE function. Every snapshot, every assert and
-- every future consumer asks this and nothing else, so "is this stat in play?" has one answer and
-- cannot be re-derived differently in a second place. An unknown lifecycle is NOT in any scope: a
-- value the table somehow admitted is treated as absent rather than as active.
create function public.stat_lifecycle_in_scope(p_lifecycle text, p_scope text)
returns boolean
language sql
immutable
as $$
  select case
           when p_scope = 'inspection' then p_lifecycle in ('active','dormant','deprecated')
           when p_scope = 'routine'    then p_lifecycle in ('active','deprecated')
           else false
         end;
$$;

create function public.stat_registry_snapshot(p_lifecycle_scope text default 'routine')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_lifecycle_scope is null or p_lifecycle_scope not in ('routine','inspection') then
    raise exception 'STAT-FOUNDATION stat_registry_snapshot: unknown lifecycle scope % — must be ''routine'' or ''inspection''. There is no permissive fallback.',
      coalesce(p_lifecycle_scope, '(null)');
  end if;
  return (select jsonb_build_object(
    'lifecycle_scope', p_lifecycle_scope,
    'registry_version', coalesce((select max(revision) from public.stat_definitions s
                                   where public.stat_lifecycle_in_scope(s.lifecycle, p_lifecycle_scope)), 0),
    'stat_ids', coalesce((select jsonb_agg(s.stat_id order by s.display_order, s.stat_id)
                            from public.stat_definitions s
                           where public.stat_lifecycle_in_scope(s.lifecycle, p_lifecycle_scope)), '[]'::jsonb),
    'stats', coalesce((
      select jsonb_object_agg(s.stat_id, jsonb_build_object(
               'stat_id',                s.stat_id,
               'catalog_key',            s.catalog_key,
               'display_name',           s.display_name,
               'display_order',          s.display_order,
               'applies_to_scope',       s.applies_to_scope,
               'value_kind',             s.value_kind,
               'unit',                   s.unit,
               'numeric_domain',         s.numeric_domain,
               'round_to',               s.round_to,
               'min_value',              s.min_value,
               'max_value',              s.max_value,
               'ship_base_source',       s.ship_base_source,
               'ship_base_ref',          s.ship_base_ref,
               'combination_class',      s.combination_class,
               'permitted_operations',   to_jsonb(s.permitted_operations),
               'permitted_source_kinds', to_jsonb(s.permitted_source_kinds),
               'fleet_aggregation',      s.fleet_aggregation,
               'fleet_weight_stat',      s.fleet_weight_stat,
               'combat_snapshot',        s.combat_snapshot,
               'engine_consumer',        s.engine_consumer,
               'presentation_consumer',  s.presentation_consumer,
               'deprecated_reason',      s.deprecated_reason,
               'lifecycle',              s.lifecycle,
               'supersedes_stat_id',     s.supersedes_stat_id,
               'unit_conversion',        s.unit_conversion,
               'intended_source_kinds',  to_jsonb(s.intended_source_kinds),
               'revision',               s.revision))
        from public.stat_definitions s
       where public.stat_lifecycle_in_scope(s.lifecycle, p_lifecycle_scope)), '{}'::jsonb)));
end;
$$;

-- stat_assert_provenance_partition — THE provenance law, in ONE executable place.
--
-- It proves, on any resolver result, that the four maps are PAIRWISE DISJOINT and that their union
-- is EXACTLY the provenance key set. That is what makes "a real zero", "unresolved" and "not
-- applicable" mutually distinguishable as a structural property rather than as a convention: a stat
-- that appeared in two maps, or in a map without a provenance entry, or in provenance without a map,
-- is a collapsed distinction, and this function refuses it.
--
-- It RAISES rather than returning false: a violated invariant must not be something a caller can
-- ignore by not reading the boolean.
create function public.stat_assert_provenance_partition(p_result jsonb, p_where text)
returns boolean
language plpgsql
immutable
as $$
declare
  v_map    text;
  v_status text;
  v_k      text;
  v_seen   text[] := array[]::text[];
  v_prov   jsonb;
begin
  if p_result is null or jsonb_typeof(p_result -> 'provenance') <> 'object' then
    raise exception 'STAT-FOUNDATION provenance law (%): result carries no provenance index', coalesce(p_where, '(unknown)');
  end if;
  v_prov := p_result -> 'provenance';

  -- (1) Every map key must carry the matching provenance status, and no key may appear twice.
  foreach v_map in array array['stats','not_applicable','unresolved','dormant'] loop
    v_status := case v_map when 'stats' then 'resolved' else v_map end;
    if jsonb_typeof(p_result -> v_map) <> 'object' then
      raise exception 'STAT-FOUNDATION provenance law (%): map "%" is missing or is not an object', coalesce(p_where, '(unknown)'), v_map;
    end if;
    for v_k in select k from jsonb_object_keys(p_result -> v_map) k loop
      if v_k = any (v_seen) then
        raise exception 'STAT-FOUNDATION provenance law (%): stat % appears in more than one provenance map — a real zero, an unresolved value and a not-applicable must never be collapsed', coalesce(p_where, '(unknown)'), v_k;
      end if;
      v_seen := v_seen || v_k;
      if (v_prov -> v_k ->> 'status') is distinct from v_status then
        raise exception 'STAT-FOUNDATION provenance law (%): stat % sits in map "%" but its provenance says "%"', coalesce(p_where, '(unknown)'), v_k, v_map, coalesce(v_prov -> v_k ->> 'status', '(absent)');
      end if;
    end loop;
  end loop;

  -- (2) ...and nothing may be in provenance without being in exactly one map.
  for v_k in select k from jsonb_object_keys(v_prov) k loop
    if not (v_k = any (v_seen)) then
      raise exception 'STAT-FOUNDATION provenance law (%): stat % has a provenance status but appears in no map', coalesce(p_where, '(unknown)'), v_k;
    end if;
  end loop;

  -- (3) An unresolved entry must never carry a number anywhere in it. This is the structural half of
  --     the ambush ruling: a resolution failure cannot BE a value, so it cannot become one.
  for v_k in select k from jsonb_object_keys(p_result -> 'unresolved') k loop
    if jsonb_typeof(p_result -> 'unresolved' -> v_k) = 'number' then
      raise exception 'STAT-FOUNDATION provenance law (%): unresolved stat % holds a NUMBER — a resolution failure must never be expressible as a value', coalesce(p_where, '(unknown)'), v_k;
    end if;
  end loop;
  return true;
end;
$$;

-- stat_combine — THE pure fold. No table reads. No time. No RNG.
--
-- MODIFIER ORDER (contract §4.1), by declared step, so the breakdown is reproducible and the
-- order-sensitive stages cannot drift:
--     0  base_override        a source replaces the base outright
--    10  base                 hull column / instance column
--    20  flat: hull
--    30  flat: trait
--    40  flat: module
--    50  flat: captain        (already scaled per-source by the gatherer's level x affinity mult)
--    60  flat: buffs and every other source category
--    70  additive %           SUMMED within the rank and applied ONCE: x (1 + SIGMA). Eight +10%
--                             buffs are +80%, not x2.14. This IS the shipped speed semantics.
--    80  multiplicative %     applied IN ORDER, one at a time: x (1 + m) each.
--    90  clamp + round        greatest(min, least(max, x)) then round to round_to decimals
--
-- NUMERICS: everything is Postgres `numeric`. Never double precision, never float8. The deployed
-- fold transits float8 in places and that is exactly how a mis-set "NaN" knob was once able to
-- poison every stat (0198). `numeric` has no NaN-ordering trap and no last-bit surprise. Each stat
-- is rounded ONCE, at the end.
--
-- FAIL CLOSED, with actionable diagnostics: an unknown stat_id, an operation the stat does not
-- permit, a source category the stat does not permit, a non-numeric amount, or a DUPLICATE
-- contribution identity (stat_id, source_kind, source_id, operation) all RAISE, naming the offender.
-- Malformed source data is never converted into a plausible stat.
--
-- THREE-WAY PROVENANCE (owner ruling, 2026-08-04). A structure in which "a real zero", "resolution
-- failed" and "not applicable here" all read `0` is precisely the defect this architecture exists to
-- eliminate, so they are made MUTUALLY DISTINGUISHABLE and are never collapsed into one value. Every
-- result carries a `provenance` index over FOUR DISJOINT maps:
--
--    provenance status   lives in          means
--    ─────────────────   ───────────────   ─────────────────────────────────────────────────────────
--    resolved            stats             a real number was produced. A REAL ZERO IS THIS, with
--                                          value 0 — "this ship's scanner reads zero" is a fact.
--    not_applicable      not_applicable    the stat has no value for this entity at all (no member
--                                          ships, no eligible member, not defined at this scope).
--                                          There is no number, and none is invented.
--    unresolved          unresolved        RESOLUTION FAILED. The value is UNKNOWN. It is not zero,
--                                          not minimum, not maximum, and not safe to substitute.
--                                          Carries a structured diagnostic naming what failed.
--    dormant             dormant           inspection-only: catalogued, no consumer, marked
--                                          effective=false so no client may present it as a number
--                                          that does anything.
--
-- `stats` therefore contains ONLY effective, resolved numbers — at every scope, forever. A consumer
-- that reads `stats` can never accidentally read an unknown or an inapplicable as a zero, because
-- the key is not there. stat_assert_provenance_partition proves the four maps partition the computed
-- key set exactly, and it is executed, not documented.
create function public.stat_combine(
  p_contributions jsonb,
  p_bases         jsonb,
  p_registry      jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_stats     jsonb := '{}'::jsonb;
  v_dormant   jsonb := '{}'::jsonb;
  v_prov      jsonb := '{}'::jsonb;
  v_breakdown jsonb := '[]'::jsonb;
  v_reg       jsonb;
  v_ids       text[];
  v_id        text;
  v_def       jsonb;
  v_c         jsonb;
  v_norm      jsonb := '[]'::jsonb;
  v_running   numeric;
  v_base      numeric;
  v_addpct    numeric;
  v_min       numeric;
  v_max       numeric;
  v_round     integer;
  v_amount    numeric;
  v_op        text;
  v_kind      text;
  v_sid       text;
  v_key       text;
  v_seen      text[] := array[]::text[];
  v_n         integer;
  v_out       jsonb;
  v_result    jsonb;
begin
  if p_registry is null or jsonb_typeof(p_registry -> 'stats') <> 'object' then
    raise exception 'STAT-FOUNDATION stat_combine: p_registry is not a registry snapshot (missing "stats" object)';
  end if;
  v_reg := p_registry -> 'stats';

  if p_contributions is not null and jsonb_typeof(p_contributions) <> 'array' then
    raise exception 'STAT-FOUNDATION stat_combine: p_contributions must be a JSON array, got %', jsonb_typeof(p_contributions);
  end if;
  if p_bases is not null and jsonb_typeof(p_bases) <> 'object' then
    raise exception 'STAT-FOUNDATION stat_combine: p_bases must be a JSON object, got %', jsonb_typeof(p_bases);
  end if;

  -- (A) VALIDATE every contribution, before any arithmetic. A fold that has already added three
  --     numbers before discovering the fourth is malformed has produced a partial lie.
  for v_c in select value from jsonb_array_elements(coalesce(p_contributions, '[]'::jsonb)) loop
    v_id   := v_c ->> 'stat_id';
    v_op   := v_c ->> 'operation';
    v_kind := v_c ->> 'source_kind';
    v_sid  := coalesce(v_c ->> 'source_id', '');

    if v_id is null or not (v_reg ? v_id) then
      raise exception 'STAT-FOUNDATION stat_combine: unknown stat_id % (source_kind=%, source_id=%). A stat must be a registered row before anything may contribute to it.',
        coalesce(v_id, '(null)'), coalesce(v_kind, '(null)'), v_sid;
    end if;
    v_def := v_reg -> v_id;

    if v_op is null or not (v_def -> 'permitted_operations' ? v_op) then
      raise exception 'STAT-FOUNDATION stat_combine: operation % is not permitted for stat % (permitted: %). source_kind=%, source_id=%',
        coalesce(v_op, '(null)'), v_id, (v_def ->> 'permitted_operations'), coalesce(v_kind, '(null)'), v_sid;
    end if;
    if v_kind is null or not (v_def -> 'permitted_source_kinds' ? v_kind) then
      raise exception 'STAT-FOUNDATION stat_combine: source category % may not contribute to stat % (permitted: %). source_id=%',
        coalesce(v_kind, '(null)'), v_id, (v_def ->> 'permitted_source_kinds'), v_sid;
    end if;
    if jsonb_typeof(v_c -> 'amount') <> 'number' then
      raise exception 'STAT-FOUNDATION stat_combine: contribution amount for stat % is % , not a JSON number (source_kind=%, source_id=%). Refusing to fabricate a stat from malformed source data.',
        v_id, coalesce(jsonb_typeof(v_c -> 'amount'), 'absent'), coalesce(v_kind, '(null)'), v_sid;
    end if;

    -- DUPLICATE CONTRIBUTION IDENTITY. Two contributions that claim the same (stat, source
    -- category, source instance, operation) are a double-count, not a stack — a stack is expressed
    -- by distinct source ids or by a stacking policy, never by an ambiguous repeat.
    v_key := v_id || '|' || v_kind || '|' || v_sid || '|' || v_op;
    if v_key = any (v_seen) then
      raise exception 'STAT-FOUNDATION stat_combine: duplicate contribution identity % — the same source may contribute to the same stat with the same operation exactly once.', v_key;
    end if;
    v_seen := v_seen || v_key;

    v_norm := v_norm || jsonb_build_array(jsonb_build_object(
      'stat_id', v_id, 'source_kind', v_kind, 'source_id', v_sid, 'operation', v_op,
      'amount', (v_c -> 'amount'),
      'step', case v_op
                when 'base_override' then 0
                when 'flat' then case v_kind
                                   when 'hull' then 20 when 'trait' then 30
                                   when 'module' then 40 when 'captain' then 50 else 60 end
                when 'additive_pct' then 70
                when 'multiplicative_pct' then 80
                else 90 end));
  end loop;

  -- (B) The stats to emit: EVERY STAT IN THE SUPPLIED SNAPSHOT, in display order.
  --
  --     RECONCILING TWO RULES THAT LOOK OPPOSED. The earlier draft of this slice argued (deviation
  --     5) that the fold must emit EVERY registry stat, not only the ones that happen to carry a
  --     contribution: a ship with no sensor has a scouting of 0, which is a fact about the ship, and
  --     the deployed fold agrees — it emits all its keys on every call with the accumulators
  --     starting at 0 (0205:666-685). That argument is accepted and PRESERVED. The owner's later
  --     ruling says dormant stats must NOT be computed on routine resolution paths. The two are
  --     reconciled at the SNAPSHOT, not here:
  --
  --       · this leaf still emits the WHOLE supplied vocabulary — no "skip the ones that are zero",
  --         so a real zero is still a fact and key-parity with the deployed fold is exact;
  --       · but the ROUTINE snapshot does not contain dormant stats at all, so on every routine
  --         path there is nothing dormant to emit. The dormant stats are not filtered out late —
  --         they were never in scope, and no contribution to them is even gathered.
  --
  --     There is therefore exactly ONE place that decides which stats exist for a call
  --     (stat_lifecycle_in_scope, read through the snapshot), and this leaf has no lifecycle opinion
  --     of its own beyond routing a dormant value away from `stats`.
  --
  --     A base naming an unregistered stat still fails closed below.
  select coalesce(array_agg(k order by (v_reg -> k ->> 'display_order')::integer, k), array[]::text[])
    into v_ids
    from jsonb_object_keys(v_reg) k;

  for v_key in select k from jsonb_object_keys(coalesce(p_bases, '{}'::jsonb)) k loop
    if not (v_reg ? v_key) then
      raise exception 'STAT-FOUNDATION stat_combine: base supplied for unknown stat_id % — a stat must be a registered row before it can have a base.', v_key;
    end if;
  end loop;

  foreach v_id in array v_ids loop
    v_def   := v_reg -> v_id;
    v_round := (v_def ->> 'round_to')::integer;
    v_min   := (v_def ->> 'min_value')::numeric;
    v_max   := (v_def ->> 'max_value')::numeric;

    -- step 0 / 10 — base_override wins over the supplied base; absent base is 0.
    v_base := null;
    for v_c in select value from jsonb_array_elements(v_norm) n(value)
               where value ->> 'stat_id' = v_id and value ->> 'operation' = 'base_override'
               order by value ->> 'source_kind', value ->> 'source_id' loop
      v_base := (v_c ->> 'amount')::numeric;
      v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id, 'step', 0, 'source_kind', v_c ->> 'source_kind',
        'source_id', v_c ->> 'source_id', 'operation', 'base_override',
        'amount', (v_c -> 'amount'), 'running', v_base));
    end loop;
    if v_base is null then
      v_base := coalesce((p_bases ->> v_id)::numeric, 0);
      v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id, 'step', 10, 'source_kind', 'base',
        'source_id', coalesce(v_def ->> 'ship_base_ref', 'implicit_zero'), 'operation', 'base',
        'amount', v_base, 'running', v_base));
    end if;
    v_running := v_base;

    -- steps 20-60 — flat, in declared source order. Additive contributions commute, so this order
    -- cannot change the total; it is fixed anyway because the breakdown must be reproducible.
    for v_c in select value from jsonb_array_elements(v_norm) n(value)
               where value ->> 'stat_id' = v_id and value ->> 'operation' = 'flat'
               order by (value ->> 'step')::integer, value ->> 'source_kind', value ->> 'source_id' loop
      v_amount  := (v_c ->> 'amount')::numeric;
      v_running := v_running + v_amount;
      v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id, 'step', (v_c ->> 'step')::integer, 'source_kind', v_c ->> 'source_kind',
        'source_id', v_c ->> 'source_id', 'operation', 'flat',
        'amount', v_amount, 'running', v_running));
    end loop;

    -- step 70 — additive %, SUMMED then applied ONCE. This reproduces 0205:662 exactly:
    --     v_speed * (1 + v_mod_speed_bonus + v_cap_speed_bonus + v_trait_speed_bonus + v_cmdbuff_speed_bonus)
    v_addpct := 0;
    v_n := 0;
    for v_c in select value from jsonb_array_elements(v_norm) n(value)
               where value ->> 'stat_id' = v_id and value ->> 'operation' = 'additive_pct'
               order by value ->> 'source_kind', value ->> 'source_id' loop
      v_addpct := v_addpct + (v_c ->> 'amount')::numeric;
      v_n := v_n + 1;
      v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id, 'step', 70, 'source_kind', v_c ->> 'source_kind',
        'source_id', v_c ->> 'source_id', 'operation', 'additive_pct',
        'amount', (v_c -> 'amount'), 'running', null));
    end loop;
    if v_n > 0 then
      v_running := v_running * (1 + v_addpct);
      v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id, 'step', 70, 'source_kind', 'additive_pct_total',
        'source_id', 'sum_of_' || v_n::text, 'operation', 'additive_pct_apply',
        'amount', v_addpct, 'running', v_running));
    end if;

    -- step 80 — multiplicative %, applied IN ORDER, one at a time. Exact numeric multiplication:
    -- never exp(sum(ln(x))), which would put a floating-point coincidence on the critical path.
    for v_c in select value from jsonb_array_elements(v_norm) n(value)
               where value ->> 'stat_id' = v_id and value ->> 'operation' = 'multiplicative_pct'
               order by value ->> 'source_kind', value ->> 'source_id' loop
      v_running := v_running * (1 + (v_c ->> 'amount')::numeric);
      v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id, 'step', 80, 'source_kind', v_c ->> 'source_kind',
        'source_id', v_c ->> 'source_id', 'operation', 'multiplicative_pct',
        'amount', (v_c -> 'amount'), 'running', v_running));
    end loop;

    -- step 90 — per-contribution clamps, then the registry clamp, then ONE rounding.
    for v_c in select value from jsonb_array_elements(v_norm) n(value)
               where value ->> 'stat_id' = v_id and value ->> 'operation' in ('clamp_min','clamp_max')
               order by value ->> 'operation', value ->> 'source_kind', value ->> 'source_id' loop
      if v_c ->> 'operation' = 'clamp_min' then
        v_running := greatest(v_running, (v_c ->> 'amount')::numeric);
      else
        v_running := least(v_running, (v_c ->> 'amount')::numeric);
      end if;
      v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id, 'step', 90, 'source_kind', v_c ->> 'source_kind',
        'source_id', v_c ->> 'source_id', 'operation', v_c ->> 'operation',
        'amount', (v_c -> 'amount'), 'running', v_running));
    end loop;
    if v_min is not null then v_running := greatest(v_min, v_running); end if;
    if v_max is not null then v_running := least(v_max, v_running); end if;
    v_running := round(v_running, v_round);
    v_breakdown := v_breakdown || jsonb_build_array(jsonb_build_object(
      'stat_id', v_id, 'step', 90, 'source_kind', 'clamp',
      'source_id', 'stat_definitions.min_value/max_value/round_to', 'operation', 'clamp',
      'amount', 0, 'running', v_running));

    -- An integer-domain stat is emitted as a JSON integer; everything else as a number with exactly
    -- round_to decimals. to_jsonb over numeric preserves the exact value — no float round-trip.
    if (v_def ->> 'numeric_domain') = 'integer' then
      v_out := to_jsonb(v_running::bigint);
    else
      v_out := to_jsonb(v_running);
    end if;

    -- LIFECYCLE ROUTING. A dormant stat NEVER lands in `stats`. It can only be here at all because
    -- the caller asked for an inspection snapshot, and even then it is quarantined into `dormant`
    -- with effective=false, so no client can render it as a number that does something.
    if (v_def ->> 'lifecycle') = 'dormant' then
      v_dormant := v_dormant || jsonb_build_object(v_id, jsonb_build_object(
        'value', v_out, 'effective', false, 'lifecycle', 'dormant',
        'note', 'catalogued with no approved consumer: this number is inspection-only and no gameplay path reads it'));
      v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object(
        'status', 'dormant',
        'reason', 'no approved gameplay or presentation consumer'));
    else
      v_stats := v_stats || jsonb_build_object(v_id, v_out);
      v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object(
        'status', 'resolved', 'lifecycle', (v_def ->> 'lifecycle'),
        -- A REAL ZERO IS A RESOLVED VALUE, and says so. This flag is the difference between "the
        -- scanner reads zero" and "we could not read the scanner".
        'is_real_zero', (v_running = 0)));
    end if;
  end loop;

  v_result := jsonb_build_object(
    'stats',          v_stats,
    'not_applicable', '{}'::jsonb,   -- ship scope: a registered stat always resolves or the fold raises
    'unresolved',     '{}'::jsonb,
    'dormant',        v_dormant,
    'provenance',     v_prov,
    'breakdown',      v_breakdown);
  perform public.stat_assert_provenance_partition(v_result, 'stat_combine');
  return v_result;
end;
$$;

-- stat_aggregate_fleet — THE pure per-stat fleet aggregation. No table reads. No time. No RNG.
--
-- EVERY STAT DECLARES ITS OWN RULE. There is no blanket sum and no default: fleet_aggregation is
-- NOT NULL in the registry, and an unrecognised rule raises here rather than falling through to
-- addition.
--
-- AN EMPTY OR INELIGIBLE FLEET YIELDS AN EXPLICIT NON-APPLICABLE RESULT, NEVER A SILENT 0. A stat
-- appears in exactly one of `stats` (a real number), `not_applicable` (a reason), `unresolved` (a
-- structured failure) or `dormant` (inspection-only) — never in two, and never as a fabricated zero
-- that a consumer would read as "this fleet has no combat power" when the truth is "this fleet has
-- no ships" or "we could not read this fleet".
--
-- A MEMBER WHOSE OWN RESOLUTION FAILED POISONS THE WHOLE AGGREGATE, DELIBERATELY. Every rule here —
-- sum, min, max, average, weighted average, primary ship — is a statement about the WHOLE roster. An
-- aggregate computed over the members that happened to resolve is not a smaller-but-honest answer,
-- it is a confident wrong one: a min over the surviving members can be higher than the true min, a
-- sum lower than the true sum. So a single unresolved member makes every stat `unresolved`, naming
-- the members that failed. That is one rule, applied once, with no per-rule special case to drift.
--
-- Member entries are `{entity_id, status, stats}` for a resolved member and
-- `{entity_id, status:'unresolved', failure:{...}}` for a failed one. `status` is REQUIRED: an entry
-- that does not say whether it resolved is itself a resolution failure, not a resolved empty ship.
--
-- A member's `stats` carries every value it RESOLVED, effective and (under inspection) dormant
-- alike. LIFECYCLE ROUTING HAPPENS HERE, not in the member: the fleet rule for a stat lives in the
-- registry, so this fold must see the member's whole answer or a dormant stat would resolve per ship
-- and then quietly become not_applicable for the fleet.
create function public.stat_aggregate_fleet(
  p_member_stats jsonb,
  p_registry     jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_reg      jsonb;
  v_stats    jsonb := '{}'::jsonb;
  v_na       jsonb := '{}'::jsonb;
  v_unres    jsonb := '{}'::jsonb;
  v_dormant  jsonb := '{}'::jsonb;
  v_prov     jsonb := '{}'::jsonb;
  v_break    jsonb := '[]'::jsonb;
  v_members  jsonb;
  v_count    integer;
  v_ids      text[];
  v_id       text;
  v_def      jsonb;
  v_rule     text;
  v_vals     numeric[];
  v_weights  numeric[];
  v_m        jsonb;
  v_acc      numeric;
  v_wsum     numeric;
  v_i        integer;
  v_round    integer;
  v_failed   jsonb := '[]'::jsonb;
  v_status   text;
  v_result   jsonb;
begin
  if p_registry is null or jsonb_typeof(p_registry -> 'stats') <> 'object' then
    raise exception 'STAT-FOUNDATION stat_aggregate_fleet: p_registry is not a registry snapshot';
  end if;
  v_reg := p_registry -> 'stats';

  v_members := coalesce(p_member_stats, '[]'::jsonb);
  if jsonb_typeof(v_members) <> 'array' then
    raise exception 'STAT-FOUNDATION stat_aggregate_fleet: p_member_stats must be a JSON array, got %', jsonb_typeof(v_members);
  end if;
  v_count := jsonb_array_length(v_members);

  -- THE UNRESOLVED SWEEP, before any arithmetic. Every member must state its status; an entry that
  -- states nothing is treated as a failure, never as an empty-but-fine ship.
  for v_m in select value from jsonb_array_elements(v_members) loop
    v_status := v_m ->> 'status';
    if v_status is null or v_status not in ('resolved','unresolved') then
      v_failed := v_failed || jsonb_build_array(jsonb_build_object(
        'entity_id', v_m -> 'entity_id',
        'failure', jsonb_build_object(
          'reason', 'member_status_missing_or_unknown',
          'detail', 'a member entry must declare status ''resolved'' or ''unresolved''; an entry that declares neither is a resolution failure, not a resolved empty ship',
          'got', coalesce(to_jsonb(v_status), 'null'::jsonb))));
    elsif v_status = 'unresolved' then
      v_failed := v_failed || jsonb_build_array(jsonb_build_object(
        'entity_id', v_m -> 'entity_id',
        'failure', coalesce(v_m -> 'failure', jsonb_build_object('reason', 'unspecified_member_failure'))));
    elsif jsonb_typeof(v_m -> 'stats') <> 'object' then
      v_failed := v_failed || jsonb_build_array(jsonb_build_object(
        'entity_id', v_m -> 'entity_id',
        'failure', jsonb_build_object('reason', 'resolved_member_carries_no_stats_object')));
    end if;
  end loop;

  select coalesce(array_agg(k order by (v_reg -> k ->> 'display_order')::integer, k), array[]::text[])
    into v_ids
    from jsonb_object_keys(v_reg) k;

  -- ANY failed member ⇒ EVERY stat is unresolved. No number is produced, and the diagnostic names
  -- the members that failed so the caller can act on it.
  if jsonb_array_length(v_failed) > 0 then
    foreach v_id in array v_ids loop
      v_unres := v_unres || jsonb_build_object(v_id, jsonb_build_object(
        'reason', 'member_resolution_failed',
        'detail', 'at least one member ship could not be resolved, so no aggregate over this roster is trustworthy. The value is UNKNOWN — it is not zero, not minimum and not maximum.',
        'failed_members', v_failed));
      v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object(
        'status', 'unresolved', 'reason', 'member_resolution_failed'));
    end loop;
    v_result := jsonb_build_object(
      'member_count',   v_count,
      'applicable',     false,
      'stats',          '{}'::jsonb,
      'not_applicable', '{}'::jsonb,
      'unresolved',     v_unres,
      'dormant',        '{}'::jsonb,
      'provenance',     v_prov,
      'breakdown',      '[]'::jsonb);
    perform public.stat_assert_provenance_partition(v_result, 'stat_aggregate_fleet/unresolved');
    return v_result;
  end if;

  foreach v_id in array v_ids loop
    v_def  := v_reg -> v_id;
    v_rule := v_def ->> 'fleet_aggregation';
    if v_rule is null then
      raise exception 'STAT-FOUNDATION stat_aggregate_fleet: stat % declares no fleet aggregation rule', v_id;
    end if;
    v_round := (v_def ->> 'round_to')::integer;

    -- A stat whose rule is 'none' is never aggregated at fleet scope, at any member count. Ranges
    -- are the reason this rule exists.
    if v_rule = 'none' then
      v_na := v_na || jsonb_build_object(v_id, 'aggregation_rule_none: this stat is not defined at fleet scope');
      v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object('status', 'not_applicable', 'reason', 'aggregation_rule_none'));
      continue;
    end if;
    if (v_def ->> 'applies_to_scope') = 'ship' then
      v_na := v_na || jsonb_build_object(v_id, 'ship_scope_only: this stat is not defined at fleet scope');
      v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object('status', 'not_applicable', 'reason', 'ship_scope_only'));
      continue;
    end if;

    -- Collect the eligible member values. A member that does not report the stat is NOT counted as
    -- zero — it simply does not participate, which is the difference between "no scanner" and
    -- "a scanner reading zero".
    v_vals := array[]::numeric[];
    v_weights := array[]::numeric[];
    for v_m in select value from jsonb_array_elements(v_members) loop
      if jsonb_typeof(v_m -> 'stats' -> v_id) = 'number' then
        v_vals := v_vals || ((v_m -> 'stats' ->> v_id)::numeric);
        if v_rule = 'weighted_average' then
          v_weights := v_weights ||
            coalesce((v_m -> 'stats' ->> (v_def ->> 'fleet_weight_stat'))::numeric, 0);
        end if;
      end if;
    end loop;

    if array_length(v_vals, 1) is null then
      v_na := v_na || jsonb_build_object(v_id,
        case when v_count = 0
             then 'empty_fleet: no member ships, so this stat has no value (it is NOT zero)'
             else 'no_eligible_member: no participating ship reports this stat (it is NOT zero)' end);
      v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object('status', 'not_applicable',
        'reason', case when v_count = 0 then 'empty_fleet' else 'no_eligible_member' end));
      continue;
    end if;

    v_acc := null;
    case v_rule
      when 'sum' then
        select sum(x) into v_acc from unnest(v_vals) x;
      when 'min' then
        select min(x) into v_acc from unnest(v_vals) x;
      when 'max' then
        select max(x) into v_acc from unnest(v_vals) x;
      when 'average' then
        select sum(x) / count(*) into v_acc from unnest(v_vals) x;
      when 'weighted_average' then
        select sum(w) into v_wsum from unnest(v_weights) w;
        if v_wsum is null or v_wsum = 0 then
          v_na := v_na || jsonb_build_object(v_id, 'zero_total_weight: the weighting stat sums to zero, so a weighted average is undefined (it is NOT zero)');
          v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object('status', 'not_applicable', 'reason', 'zero_total_weight'));
          continue;
        end if;
        v_acc := 0;
        for v_i in 1 .. array_length(v_vals, 1) loop
          v_acc := v_acc + v_vals[v_i] * v_weights[v_i];
        end loop;
        v_acc := v_acc / v_wsum;
      when 'primary_ship' then
        -- The lead is the FIRST member; the gatherer is the one authority for member order.
        v_acc := v_vals[1];
      else
        raise exception 'STAT-FOUNDATION stat_aggregate_fleet: stat % declares unknown fleet aggregation rule %', v_id, v_rule;
    end case;

    v_acc := round(v_acc, v_round);
    -- LIFECYCLE ROUTING, identical in law to the ship-scope routing and expressed once per scope:
    -- a dormant stat can only be present because an inspection snapshot was supplied, and it never
    -- reaches `stats`.
    if (v_def ->> 'lifecycle') = 'dormant' then
      v_dormant := v_dormant || jsonb_build_object(v_id, jsonb_build_object(
        'value', case when (v_def ->> 'numeric_domain') = 'integer'
                      then to_jsonb(v_acc::bigint) else to_jsonb(v_acc) end,
        'effective', false, 'lifecycle', 'dormant', 'rule', v_rule,
        'note', 'catalogued with no approved consumer: this number is inspection-only and no gameplay path reads it'));
      v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object(
        'status', 'dormant', 'reason', 'no approved gameplay or presentation consumer'));
      continue;
    end if;
    if (v_def ->> 'numeric_domain') = 'integer' then
      v_stats := v_stats || jsonb_build_object(v_id, to_jsonb(v_acc::bigint));
    else
      v_stats := v_stats || jsonb_build_object(v_id, to_jsonb(v_acc));
    end if;
    v_prov := v_prov || jsonb_build_object(v_id, jsonb_build_object(
      'status', 'resolved', 'lifecycle', (v_def ->> 'lifecycle'), 'rule', v_rule,
      'member_values_used', array_length(v_vals, 1),
      'is_real_zero', (v_acc = 0)));
    v_break := v_break || jsonb_build_array(jsonb_build_object(
      'stat_id', v_id, 'rule', v_rule, 'member_values_used', array_length(v_vals, 1),
      'result', v_acc));
  end loop;

  v_result := jsonb_build_object(
    'member_count',   v_count,
    'applicable',     (v_count > 0),
    'stats',          v_stats,
    'not_applicable', v_na,
    'unresolved',     v_unres,
    'dormant',        v_dormant,
    'provenance',     v_prov,
    'breakdown',      v_break);
  perform public.stat_assert_provenance_partition(v_result, 'stat_aggregate_fleet');
  return v_result;
end;
$$;

-- ── 5b. THE CONSUMER CONTRACT — how a gameplay path is allowed to turn stats into a decision ──────
--
-- WHY THIS EXISTS, with the live evidence. pirate_intercept_plan_leg
-- (20260618000301_intercept_fires_at_zone_entry.sql:484, the fold call at :542) sums
-- `combat_power + survival` and FAILS OPEN:
--
--     exception when others then
--       v_combined := 0;                                   -- 0301:545-547
--
-- and that zero is fed to pirate_intercept_compute_risk (0233:345-354), whose stat term is
--
--     stat_reference / (stat_reference + greatest(combined, 0))
--
-- a strictly decreasing function of `combined` whose supremum, 1.0, is reached at exactly
-- combined = 0. So a malformed stat graph produces THE HIGHEST RISK THE SYSTEM CAN GENERATE, and a
-- genuinely weak fleet produces the same gameplay value as a broken one. The comment there calls it
-- "the conservative choice"; it is the opposite. A `pirate_intercepts` row is then written
-- (0301:590-602) off a risk the engine had no basis to compute.
--
-- THIS SLICE DOES NOT TOUCH THAT FUNCTION. Repairing a live consumer is the bounded
-- consumer-retirement sequence, not a foundation slice, and a self-assert below proves the
-- fail-open body is still byte-for-byte where it was. What this slice ships is the CONTRACT its
-- replacement must satisfy, executable and pinned:
--
--   1. SUCCESS AND STAT-RESOLUTION-FAILURE ARE DIFFERENT ANSWERS. There is exactly one way to get a
--      number out of a resolution (stat_required_sum), and it REFUSES any envelope that is not ok.
--      A failure therefore cannot become a numeric risk input by any route — not maximum risk, not
--      minimum risk, not a default, not a clamp.
--   2. ON FAILURE: no safe passage and no ambush roll. The caller receives ok=false and MUST NOT
--      write an intercept row, must not advance a leg and must not mutate movement state.
--   3. REJECT OR DEFER AT THE NEAREST ATOMIC BOUNDARY, PRESERVING PRIOR VALID STATE. For the
--      interactive path that boundary is the whole command_ship_group_go statement
--      (20260618000330_the_mover_is_in_the_repo.sql:226, intercept call at :866): reject the command
--      and leave the fleet exactly as it was. For the scheduled path it is the per-fleet block
--      inside process_pirate_route_legs (0301:2376): skip that fleet and retry next tick — and,
--      unlike the deployed handler at 0301:2386-2397, DO NOT delete the fleet's remaining route,
--      because "we could not read the stats" is not evidence about the route.
--   4. EMIT A STRUCTURED DIAGNOSTIC: fleet, failing resolver, the stat and source where known, and
--      the resolver version. That is what the failure envelope carries.
--   5. RETURN AN ACTIONABLE ERROR — a named reason a caller can branch on, never a bare zero.
--
-- stat_require_resolved — the gate. Given a resolver result and the stats a consumer needs, it
-- either hands back exactly those values, or it hands back a refusal. It NEVER hands back a number
-- in the refusal case: the failure envelope has no `values` key at all, so there is nothing to read
-- optimistically.
create function public.stat_require_resolved(
  p_resolution jsonb,
  p_required   text[],
  p_consumer   text)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_id     text;
  v_status text;
  v_vals   jsonb := '{}'::jsonb;
  v_bad    jsonb := '[]'::jsonb;
begin
  if p_consumer is null or p_consumer = '' then
    raise exception 'STAT-FOUNDATION stat_require_resolved: a consumer name is required — an unattributed refusal is not actionable';
  end if;
  if p_required is null or array_length(p_required, 1) is null then
    raise exception 'STAT-FOUNDATION stat_require_resolved: % asked for no stats — a consumer must state what it needs', p_consumer;
  end if;
  if p_resolution is null or jsonb_typeof(p_resolution -> 'provenance') <> 'object' then
    -- A result with no provenance index is not a resolution this contract can reason about. It is a
    -- failure, and it is reported as one rather than being probed for a usable number.
    return jsonb_build_object(
      'ok', false, 'error', 'stat_resolution_failed', 'reason', 'no_provenance_index',
      'diagnostic', jsonb_build_object(
        'consumer', p_consumer, 'required', to_jsonb(p_required),
        'detail', 'the supplied resolution carries no provenance index, so no stat in it can be confirmed resolved'));
  end if;

  foreach v_id in array p_required loop
    v_status := p_resolution -> 'provenance' -> v_id ->> 'status';
    if v_status = 'resolved' and jsonb_typeof(p_resolution -> 'stats' -> v_id) = 'number' then
      v_vals := v_vals || jsonb_build_object(v_id, p_resolution -> 'stats' -> v_id);
    else
      v_bad := v_bad || jsonb_build_array(jsonb_build_object(
        'stat_id', v_id,
        'status',  coalesce(v_status, 'absent_from_resolution'),
        'detail',  coalesce(
                     p_resolution -> 'unresolved' -> v_id,
                     p_resolution -> 'not_applicable' -> v_id,
                     to_jsonb(coalesce(p_resolution -> 'provenance' -> v_id ->> 'reason',
                                       'the stat is not present in this resolution'))),
        'source',  coalesce(p_resolution -> 'provenance' -> v_id -> 'source', 'null'::jsonb)));
    end if;
  end loop;

  if jsonb_array_length(v_bad) > 0 then
    return jsonb_build_object(
      'ok', false, 'error', 'stat_resolution_failed', 'reason', 'required_stat_not_resolved',
      'diagnostic', jsonb_build_object(
        'consumer',         p_consumer,
        'scope',            p_resolution -> 'scope',
        'entity_id',        p_resolution -> 'entity_id',
        'resolver_version', p_resolution -> 'resolver_version',
        'registry_version', p_resolution -> 'registry_version',
        'failed_stats',     v_bad,
        'required',         to_jsonb(p_required),
        'action',           'reject or defer at the nearest atomic boundary, preserve prior valid state, do not roll, do not mutate movement or intercept state'));
  end if;

  return jsonb_build_object(
    'ok', true, 'values', v_vals,
    'scope',            p_resolution -> 'scope',
    'entity_id',        p_resolution -> 'entity_id',
    'resolver_version', p_resolution -> 'resolver_version',
    'registry_version', p_resolution -> 'registry_version');
end;
$$;

-- stat_required_sum — THE ONLY numeric extractor, and therefore the whole impossibility proof. A
-- consumer that wants the `combat_power + survival` number the ambush path wants must come through
-- here, and this function refuses anything that is not an ok envelope. There is no second door, no
-- coalesce, no default and no zero.
create function public.stat_required_sum(p_envelope jsonb, p_stats text[] default null)
returns numeric
language plpgsql
immutable
as $$
declare
  v_total numeric := 0;
  v_id    text;
  v_ids   text[];
begin
  if p_envelope is null or (p_envelope ->> 'ok') is distinct from 'true' then
    raise exception 'STAT-FOUNDATION stat_required_sum: refusing to produce a number from a failed stat resolution (%). A resolution failure is not a value — it is not zero, not a minimum and not a maximum.',
      coalesce(p_envelope ->> 'reason', p_envelope ->> 'error', 'no envelope');
  end if;
  -- coalesce, not a bare comparison: jsonb_typeof(NULL) is NULL, and `NULL <> 'object'` is NULL, so
  -- an envelope with NO `values` key at all would fall THROUGH this guard and be refused later by a
  -- vaguer message. A three-valued comparison used as a two-valued guard is how a fail-closed check
  -- quietly stops being one. Caught by the disposable full-chain apply.
  if coalesce(jsonb_typeof(p_envelope -> 'values'), 'absent') <> 'object' then
    raise exception 'STAT-FOUNDATION stat_required_sum: envelope claims ok but carries no values object (got %)',
      coalesce(jsonb_typeof(p_envelope -> 'values'), 'absent');
  end if;
  v_ids := coalesce(p_stats, (select coalesce(array_agg(k order by k), array[]::text[])
                                from jsonb_object_keys(p_envelope -> 'values') k));
  if array_length(v_ids, 1) is null then
    raise exception 'STAT-FOUNDATION stat_required_sum: no stats to sum';
  end if;
  foreach v_id in array v_ids loop
    if jsonb_typeof(p_envelope -> 'values' -> v_id) <> 'number' then
      raise exception 'STAT-FOUNDATION stat_required_sum: stat % is not a resolved number in this envelope', v_id;
    end if;
    v_total := v_total + (p_envelope -> 'values' ->> v_id)::numeric;
  end loop;
  return v_total;
end;
$$;

-- ── 6. PROGRESSION RESOLUTION — the ONE XP authority ──────────────────────────────────────────────
-- progression_level_for_xp and progression_xp_for_level are exact inverses below the cap, asserted
-- at deploy for L in 1..99. No other function may carry an XP table or a level formula.
create function public.progression_level_for_xp(p_track_id text, p_xp numeric)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_coef numeric;
  v_cap  integer;
  v_kind text;
  v_lvl  integer;
begin
  select c.coefficient, c.max_level, c.kind into v_coef, v_cap, v_kind
    from public.progression_tracks t
    join public.progression_curves c on c.curve_id = t.curve_id
   where t.track_id = p_track_id and t.is_active;
  if v_coef is null then
    raise exception 'STAT-FOUNDATION progression_level_for_xp: unknown or inactive progression track %', coalesce(p_track_id, '(null)');
  end if;
  if p_xp is null or p_xp < 0 then
    raise exception 'STAT-FOUNDATION progression_level_for_xp: xp must be a non-negative number for track % (got %)', p_track_id, coalesce(p_xp::text, '(null)');
  end if;
  if v_kind <> 'quadratic' then
    raise exception 'STAT-FOUNDATION progression_level_for_xp: track % has unsupported curve kind %', p_track_id, v_kind;
  end if;

  -- THE DEPLOYED CURVE, character for character (0177:270): 1 + floor(sqrt(xp / 100.0)).
  v_lvl := 1 + floor(sqrt(p_xp / v_coef))::integer;

  -- THE CAP lives here and ONLY here. A consumer never writes 99.
  if v_cap is not null and v_lvl > v_cap then
    v_lvl := v_cap;
  end if;
  return v_lvl;
end;
$$;

create function public.progression_xp_for_level(p_track_id text, p_level integer)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_coef numeric;
  v_cap  integer;
  v_lvl  integer;
begin
  select c.coefficient, c.max_level into v_coef, v_cap
    from public.progression_tracks t
    join public.progression_curves c on c.curve_id = t.curve_id
   where t.track_id = p_track_id and t.is_active;
  if v_coef is null then
    raise exception 'STAT-FOUNDATION progression_xp_for_level: unknown or inactive progression track %', coalesce(p_track_id, '(null)');
  end if;
  if p_level is null or p_level < 1 then
    raise exception 'STAT-FOUNDATION progression_xp_for_level: level must be >= 1 for track % (got %)', p_track_id, coalesce(p_level::text, '(null)');
  end if;
  v_lvl := p_level;
  -- Above the cap the threshold is the cap's threshold: there is no further level to reach.
  if v_cap is not null and v_lvl > v_cap then
    v_lvl := v_cap;
  end if;
  return (v_lvl - 1)::numeric * (v_lvl - 1)::numeric * v_coef;
end;
$$;

create function public.resolve_progression(
  p_track_id    text,
  p_entity_id   uuid,
  p_resolved_at timestamptz default now())
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_scope text;
  v_store text;
  v_cap   integer;
  v_post  text;
  v_xp    numeric;
  v_lvl   integer;
  v_floor numeric;
  v_next  numeric;
  v_atcap boolean;
begin
  select t.entity_scope, t.xp_store, c.max_level, c.post_cap_behaviour
    into v_scope, v_store, v_cap, v_post
    from public.progression_tracks t
    join public.progression_curves c on c.curve_id = t.curve_id
   where t.track_id = p_track_id and t.is_active;
  if v_store is null then
    raise exception 'STAT-FOUNDATION resolve_progression: unknown or inactive progression track %', coalesce(p_track_id, '(null)');
  end if;
  if p_entity_id is null then
    raise exception 'STAT-FOUNDATION resolve_progression: entity id is required for track %', p_track_id;
  end if;

  -- xp_store is a closed enum, so this dispatch is exhaustive by construction and can never be
  -- pointed at an arbitrary table by a catalog row.
  if v_store = 'captain_instances' then
    select ci.xp into v_xp from public.captain_instances ci where ci.id = p_entity_id;
  else
    raise exception 'STAT-FOUNDATION resolve_progression: track % names unsupported xp_store %', p_track_id, v_store;
  end if;

  if v_xp is null then
    raise exception 'STAT-FOUNDATION resolve_progression: no % row for entity % on track %', v_store, p_entity_id, p_track_id;
  end if;

  v_lvl   := public.progression_level_for_xp(p_track_id, v_xp);
  v_atcap := (v_cap is not null and v_lvl >= v_cap);
  v_floor := public.progression_xp_for_level(p_track_id, v_lvl);
  v_next  := case when v_atcap then null else public.progression_xp_for_level(p_track_id, v_lvl + 1) end;

  return jsonb_build_object(
    'resolver_version',   'progression-v1',
    'track_id',           p_track_id,
    'entity_id',          p_entity_id,
    'resolved_at',        p_resolved_at,
    'xp',                 v_xp,
    'level',              v_lvl,
    'xp_floor_of_level',  v_floor,
    'xp_into_level',      v_xp - v_floor,
    'xp_for_next_level',  v_next,
    'xp_to_next_level',   case when v_next is null then null else greatest(0, v_next - v_xp) end,
    'max_level',          v_cap,
    'at_cap',             v_atcap,
    'post_cap_behaviour', v_post);
end;
$$;

-- ── 7. BUFF RESOLUTION — activation, expiry, eligibility, stacking, ordering ──────────────────────
-- buff_apply_stacking is the pure leaf: policy, ordering and the expiry filter, over data supplied
-- by the gatherer. It is `stable` rather than `immutable` for one honest reason: it casts the
-- instances' ISO-8601 timestamp strings back to timestamptz, and text -> timestamptz is STABLE in
-- Postgres. It reads no table, holds no RNG and reads no clock; time enters ONLY as p_resolved_at,
-- so two calls with the same arguments still return byte-identical jsonb.
create function public.buff_apply_stacking(
  p_instances   jsonb,
  p_registry    jsonb,
  p_resolved_at timestamptz)
returns jsonb
language plpgsql
stable
as $$
declare
  v_active     jsonb := '[]'::jsonb;
  v_suppressed jsonb := '[]'::jsonb;
  v_i          jsonb;
  v_reg        jsonb;
  v_group      text;
  v_policy     text;
  v_winner     jsonb;
  v_groups     text[];
  v_members    jsonb;
begin
  if p_registry is null or jsonb_typeof(p_registry -> 'stats') <> 'object' then
    raise exception 'STAT-FOUNDATION buff_apply_stacking: p_registry is not a registry snapshot';
  end if;
  v_reg := p_registry -> 'stats';
  if p_resolved_at is null then
    raise exception 'STAT-FOUNDATION buff_apply_stacking: p_resolved_at is required — a buff window is never evaluated against an implicit clock';
  end if;
  if p_instances is not null and jsonb_typeof(p_instances) <> 'array' then
    raise exception 'STAT-FOUNDATION buff_apply_stacking: p_instances must be a JSON array, got %', jsonb_typeof(p_instances);
  end if;

  -- (A) EXPIRY / ACTIVATION. An instance contributes iff
  --        starts_at <= p_resolved_at  and  (expires_at is null or expires_at > p_resolved_at)
  --     evaluated against the SUPPLIED timestamp only, so replaying a past encounter reproduces the
  --     same answer. An invalid window (expires_at <= starts_at) raises rather than silently
  --     resolving to "never active".
  for v_i in select value from jsonb_array_elements(coalesce(p_instances, '[]'::jsonb)) loop
    if v_i ->> 'starts_at' is null then
      raise exception 'STAT-FOUNDATION buff_apply_stacking: buff instance % has no starts_at — an invalid buff window is never treated as inactive', coalesce(v_i ->> 'buff_instance_id', '(null)');
    end if;
    if v_i ->> 'expires_at' is not null
       and (v_i ->> 'expires_at')::timestamptz <= (v_i ->> 'starts_at')::timestamptz then
      raise exception 'STAT-FOUNDATION buff_apply_stacking: buff instance % has an invalid window (expires_at <= starts_at)', coalesce(v_i ->> 'buff_instance_id', '(null)');
    end if;
    if not (v_reg ? (v_i ->> 'stat_id')) then
      raise exception 'STAT-FOUNDATION buff_apply_stacking: buff instance % targets unknown stat %', coalesce(v_i ->> 'buff_instance_id', '(null)'), coalesce(v_i ->> 'stat_id', '(null)');
    end if;

    if (v_i ->> 'starts_at')::timestamptz > p_resolved_at then
      v_suppressed := v_suppressed || jsonb_build_array(v_i || jsonb_build_object('suppressed_by', 'not_started'));
    elsif v_i ->> 'expires_at' is not null and (v_i ->> 'expires_at')::timestamptz <= p_resolved_at then
      v_suppressed := v_suppressed || jsonb_build_array(v_i || jsonb_build_object('suppressed_by', 'expired'));
    else
      v_active := v_active || jsonb_build_array(v_i);
    end if;
  end loop;

  -- (B) STACKING, per stacking_group, applied BEFORE ordering. Every suppressed instance is returned
  --     with the policy that suppressed it — that is how "why is my buff not working" gets an answer
  --     without reading the combat tick.
  select coalesce(array_agg(distinct value ->> 'stacking_group'), array[]::text[])
    into v_groups from jsonb_array_elements(v_active);

  foreach v_group in array v_groups loop
    select coalesce(jsonb_agg(value), '[]'::jsonb) into v_members
      from jsonb_array_elements(v_active) where value ->> 'stacking_group' = v_group;
    select value ->> 'stacking_policy' into v_policy
      from jsonb_array_elements(v_members) limit 1;

    if v_policy = 'stack_all' then
      continue;
    end if;

    -- Every policy below has a TOTAL, deterministic tiebreak ending in buff_instance_id, so a
    -- winner is never chosen by row order.
    v_winner := null;
    if v_policy = 'highest_magnitude' then
      select value into v_winner from jsonb_array_elements(v_members)
        order by (value ->> 'magnitude')::numeric desc, value ->> 'buff_instance_id' asc limit 1;
    elsif v_policy = 'latest_only' then
      select value into v_winner from jsonb_array_elements(v_members)
        order by (value ->> 'granted_at')::timestamptz desc,
                 (value ->> 'expires_at')::timestamptz desc nulls first,
                 value ->> 'buff_instance_id' asc limit 1;
    elsif v_policy = 'longest_remaining' then
      -- null expires_at sorts LAST here, i.e. it is the longest remaining: it never ends.
      select value into v_winner from jsonb_array_elements(v_members)
        order by (value ->> 'expires_at')::timestamptz desc nulls first,
                 value ->> 'buff_instance_id' asc limit 1;
    elsif v_policy = 'first_only' then
      select value into v_winner from jsonb_array_elements(v_members)
        order by (value ->> 'granted_at')::timestamptz asc, value ->> 'buff_instance_id' asc limit 1;
    else
      raise exception 'STAT-FOUNDATION buff_apply_stacking: unknown stacking policy % in group %', coalesce(v_policy, '(null)'), v_group;
    end if;

    for v_i in select value from jsonb_array_elements(v_members) loop
      if v_i ->> 'buff_instance_id' is distinct from v_winner ->> 'buff_instance_id' then
        v_suppressed := v_suppressed || jsonb_build_array(v_i || jsonb_build_object('suppressed_by', v_policy));
      end if;
    end loop;
    select coalesce(jsonb_agg(value), '[]'::jsonb) into v_active
      from jsonb_array_elements(v_active)
     where value ->> 'stacking_group' <> v_group
        or value ->> 'buff_instance_id' = v_winner ->> 'buff_instance_id';
  end loop;

  -- (C) TOTAL ORDER — operation_rank, then evaluation_order, then buff_def_id, then instance id.
  --     Never a tie, so the emitted contribution list is byte-stable.
  select coalesce(jsonb_agg(value order by
           case value ->> 'operation'
             when 'base_override' then 0 when 'flat' then 100
             when 'additive_pct' then 200 when 'multiplicative_pct' then 300
             else 400 end,
           (value ->> 'evaluation_order')::integer,
           value ->> 'buff_def_id',
           value ->> 'buff_instance_id'), '[]'::jsonb)
    into v_active from jsonb_array_elements(v_active);

  return jsonb_build_object('buffs', v_active, 'suppressed', v_suppressed);
end;
$$;

-- buff_derive_source_instances — condition-sourced buffs. A command buff EXISTS while its source
-- ship is an is_command_ship member of the group carrying a rolled command_buff_id. DERIVING rather
-- than materialising removes an entire class of desync bug: there is no reconciler to fall behind a
-- membership change, and "what is buffing me" has exactly one producer.
create function public.buff_derive_source_instances(
  p_scope       text,
  p_entity_id   uuid,
  p_resolved_at timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_group   uuid;
  v_player  uuid;
  v_out     jsonb := '[]'::jsonb;
begin
  if p_scope not in ('ship','fleet') then
    raise exception 'STAT-FOUNDATION buff_derive_source_instances: scope must be ship or fleet, got %', coalesce(p_scope, '(null)');
  end if;

  -- Command buffs are gated by command_buffs_enabled, exactly as the deployed fold gates them
  -- (0205:465). Dark = zero command-buff reads and an empty derivation.
  if not public.cfg_bool('command_buffs_enabled') then
    return v_out;
  end if;

  if p_scope = 'ship' then
    select msi.group_id, msi.player_id into v_group, v_player
      from public.main_ship_instances msi where msi.main_ship_id = p_entity_id;
    if v_group is null then
      return v_out;   -- an ungrouped ship has no fleet doctrine: an empty derivation, not an error
    end if;
  else
    select g.group_id, g.player_id into v_group, v_player
      from public.ship_groups g where g.group_id = p_entity_id;
    if v_group is null then
      raise exception 'STAT-FOUNDATION buff_derive_source_instances: no ship_groups row for group %', p_entity_id;
    end if;
  end if;

  -- Owner-scoped defence in depth on the self-join (the 0205:463-464 posture): a fleet is one
  -- player's, so this can never derive a foreign ship's buff.
  select coalesce(jsonb_agg(jsonb_build_object(
           'buff_instance_id', 'derived:' || cs.main_ship_id::text || ':' || bd.buff_def_id,
           'buff_def_id',      bd.buff_def_id,
           'source_kind',      'command_ship',
           'source_instance_id', cs.main_ship_id,
           'stat_id',          bd.stat_id,
           'operation',        bd.operation,
           'magnitude',        bd.magnitude,
           'stacking_group',   bd.stacking_group,
           'stacking_policy',  bd.stacking_policy,
           'evaluation_order', bd.evaluation_order,
           'duration_kind',    bd.duration_kind,
           'context_restriction', bd.context_restriction,
           'granted_at',       p_resolved_at,
           'starts_at',        p_resolved_at,
           'expires_at',       null,
           'derived',          true)
         order by cs.main_ship_id, bd.buff_def_id), '[]'::jsonb)
    into v_out
    from public.main_ship_instances cs
    join public.buff_definitions bd
      -- EXACT equality on the composite id, never LIKE: every seeded buff_id contains '_', which is
      -- a LIKE single-character wildcard, so a pattern join would match the wrong doctrine.
      on bd.source_kind = 'command_ship'
     and bd.is_active
     and bd.buff_def_id = cs.command_buff_id || ':' || bd.stat_id
   where cs.group_id = v_group
     and cs.player_id = v_player
     and cs.is_command_ship
     and cs.command_buff_id is not null;

  return v_out;
end;
$$;

-- resolve_active_buffs — THE buff authority. Unions the derived instances with the stored ones and
-- pushes BOTH through the same stacking pipeline: one pipeline, two sources, no fork.
--
-- FORBIDDEN EDGE, asserted at deploy: neither this function nor anything it calls may ever call
-- resolve_effective_stats. A buff magnitude may be a constant, or a constant scaled by a progression
-- LEVEL — never a function of a resolved stat. That single prohibition is what keeps the resolver
-- graph acyclic and terminating.
create function public.resolve_active_buffs(
  p_scope       text,
  p_entity_id   uuid,
  p_context     jsonb       default '{}'::jsonb,
  p_resolved_at timestamptz default now())
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_reg      jsonb;
  v_derived  jsonb;
  v_stored   jsonb;
  v_all      jsonb;
  v_eligible jsonb := '[]'::jsonb;
  v_ctxout   jsonb := '[]'::jsonb;
  v_i        jsonb;
  v_ok       boolean;
  v_k        text;
  v_want     jsonb;
  v_have     jsonb;
  v_res      jsonb;
begin
  if p_scope not in ('ship','fleet') then
    raise exception 'STAT-FOUNDATION resolve_active_buffs: scope must be ship or fleet, got %', coalesce(p_scope, '(null)');
  end if;
  if p_entity_id is null then
    raise exception 'STAT-FOUNDATION resolve_active_buffs: entity id is required';
  end if;
  if p_context is not null and jsonb_typeof(p_context) <> 'object' then
    raise exception 'STAT-FOUNDATION resolve_active_buffs: p_context must be a JSON object, got %', jsonb_typeof(p_context);
  end if;

  v_reg     := public.stat_registry_snapshot();
  v_derived := public.buff_derive_source_instances(p_scope, p_entity_id, p_resolved_at);

  select coalesce(jsonb_agg(jsonb_build_object(
           'buff_instance_id', bi.buff_instance_id::text,
           'buff_def_id',      bd.buff_def_id,
           'source_kind',      bd.source_kind,
           'source_instance_id', bi.source_instance_id,
           'stat_id',          bd.stat_id,
           'operation',        bd.operation,
           -- magnitude_override wins; otherwise the definition's magnitude, optionally scaled by a
           -- progression LEVEL — the ONLY dynamic input a buff may take.
           'magnitude',        coalesce(bi.magnitude_override, bd.magnitude),
           'stacking_group',   bd.stacking_group,
           'stacking_policy',  bd.stacking_policy,
           'evaluation_order', bd.evaluation_order,
           'duration_kind',    bd.duration_kind,
           'context_restriction', bd.context_restriction,
           'granted_at',       bi.granted_at,
           'starts_at',        bi.starts_at,
           'expires_at',       bi.expires_at,
           'derived',          false)
         order by bi.buff_instance_id), '[]'::jsonb)
    into v_stored
    from public.buff_instances bi
    join public.buff_definitions bd on bd.buff_def_id = bi.buff_def_id
   where bi.target_scope = p_scope
     and bi.target_entity_id = p_entity_id
     and bd.is_active;

  v_all := v_derived || v_stored;

  -- CONTEXT ELIGIBILITY — equality matching ONLY. context_restriction is {key: scalar} or
  -- {key: [scalar, ...]}; it is never parsed and never evaluated. A restriction whose key is absent
  -- from the supplied context suppresses the buff (fail closed), it does not pass by default.
  for v_i in select value from jsonb_array_elements(v_all) loop
    v_ok := true;
    for v_k in select k from jsonb_object_keys(coalesce(v_i -> 'context_restriction', '{}'::jsonb)) k loop
      v_want := v_i -> 'context_restriction' -> v_k;
      v_have := coalesce(p_context, '{}'::jsonb) -> v_k;
      if v_have is null then
        v_ok := false;
      elsif jsonb_typeof(v_want) = 'array' then
        if not (v_want @> jsonb_build_array(v_have)) then v_ok := false; end if;
      elsif v_want is distinct from v_have then
        v_ok := false;
      end if;
      exit when not v_ok;
    end loop;
    if v_ok then
      v_eligible := v_eligible || jsonb_build_array(v_i);
    else
      v_ctxout := v_ctxout || jsonb_build_array(v_i || jsonb_build_object('suppressed_by', 'context_restriction'));
    end if;
  end loop;

  v_res := public.buff_apply_stacking(v_eligible, v_reg, p_resolved_at);

  return jsonb_build_object(
    'resolver_version', 'buff-v1',
    'registry_version', (v_reg ->> 'registry_version')::integer,
    'scope',            p_scope,
    'entity_id',        p_entity_id,
    'resolved_at',      p_resolved_at,
    'context',          coalesce(p_context, '{}'::jsonb),
    'buffs',            v_res -> 'buffs',
    'suppressed',       (v_res -> 'suppressed') || v_ctxout);
end;
$$;

-- ── 8. EFFECTIVE-STAT RESOLUTION — ship, then fleet THROUGH resolved member ships ─────────────────
-- p_scope='ship'  -> p_entity_id is main_ship_instances.main_ship_id
-- p_scope='fleet' -> p_entity_id is ship_groups.group_id
--
-- NAMING, decided by the contract and repeated here because it is a live trap: in this codebase
-- `fleets` is the SPATIAL VEHICLE (it carries position) and `ship_groups` is the ROSTER. Membership
-- truth is main_ship_instances.group_id. The owner's word "fleet" means the roster, so
-- p_scope='fleet' takes a group_id. A fleets.id is NEVER a valid p_entity_id.
--
-- This function contains NO stat arithmetic of its own. It GATHERS rows and calls the pure leaves.
--
-- p_lifecycle_scope is the ONLY way dormant stats can enter a resolution, and it defaults to
-- 'routine'. A gameplay caller that writes nothing extra gets no dormant stat, no dormant
-- contribution gathered, and no dormant key in its result — that is the owner's ruling made
-- structural rather than remembered.
create function public.resolve_effective_stats(
  p_scope       text,
  p_entity_id   uuid,
  p_context     jsonb       default '{}'::jsonb,
  p_resolved_at timestamptz default now(),
  p_lifecycle_scope text    default 'routine')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_reg        jsonb;
  v_ship       record;
  v_hull       record;
  v_contrib    jsonb := '[]'::jsonb;
  v_bases      jsonb := '{}'::jsonb;
  v_folded     jsonb;
  v_buffs      jsonb;
  v_b          jsonb;
  v_r          record;
  v_spd_pen    numeric := 0;
  v_growth     boolean;
  v_lvl_raw    double precision;
  v_lvl_bonus  numeric;
  v_aff_raw    double precision;
  v_aff_bonus  numeric;
  v_lvl_mult   numeric;
  v_aff_mult   numeric;
  v_traits_on  boolean;
  v_members    uuid[];
  v_member     uuid;
  v_memberout  jsonb := '[]'::jsonb;
  v_agg        jsonb;
  v_group      uuid;
  v_one        jsonb;
  v_err        text;
  v_errdetail  text;
begin
  if p_scope is null or p_scope not in ('ship','fleet') then
    raise exception 'STAT-FOUNDATION resolve_effective_stats: scope must be ''ship'' or ''fleet'', got %', coalesce(p_scope, '(null)');
  end if;
  if p_lifecycle_scope is null or p_lifecycle_scope not in ('routine','inspection') then
    raise exception 'STAT-FOUNDATION resolve_effective_stats: lifecycle scope must be ''routine'' or ''inspection'', got %', coalesce(p_lifecycle_scope, '(null)');
  end if;
  if p_entity_id is null then
    raise exception 'STAT-FOUNDATION resolve_effective_stats: entity id is required for scope %', p_scope;
  end if;
  if p_context is not null and jsonb_typeof(p_context) <> 'object' then
    raise exception 'STAT-FOUNDATION resolve_effective_stats: p_context must be a JSON object, got %', jsonb_typeof(p_context);
  end if;

  -- THE ONE PLACE THE VOCABULARY IS DECIDED for this call. Everything below — which contributions
  -- are even gathered, which stats are folded, which are aggregated — reads THIS snapshot and never
  -- re-derives the set from the table, so a dormant stat cannot slip in through a second predicate.
  v_reg := public.stat_registry_snapshot(p_lifecycle_scope);

  -- ══ FLEET SCOPE ═══════════════════════════════════════════════════════════════════════════════
  -- Aggregation runs THROUGH canonical ship resolution — this function calls ITSELF for each
  -- member and hands the results to the one pure aggregation leaf. The fold is never duplicated.
  if p_scope = 'fleet' then
    select g.group_id into v_group from public.ship_groups g where g.group_id = p_entity_id;
    if v_group is null then
      raise exception 'STAT-FOUNDATION resolve_effective_stats: no ship_groups row for group % (a fleets.id is never a valid fleet-scope entity id)', p_entity_id;
    end if;

    select coalesce(array_agg(msi.main_ship_id order by msi.created_at, msi.main_ship_id), '{}'::uuid[])
      into v_members
      from public.main_ship_instances msi where msi.group_id = v_group;

    if v_members is not null then
      foreach v_member in array v_members loop
        -- A MEMBER THAT CANNOT BE RESOLVED IS RECORDED AS UNRESOLVED, NOT DROPPED AND NOT ZEROED.
        -- The ship resolver still fails closed (it raises rather than fabricating); this catch turns
        -- that raise into a NAMED, structured member failure so the aggregation can say "unknown"
        -- instead of quietly computing a fleet total over the ships that happened to work. Dropping
        -- the member is exactly how a min becomes too high and a sum becomes too low.
        begin
          v_one := public.resolve_effective_stats('ship', v_member, p_context, p_resolved_at, p_lifecycle_scope);
          -- A member reports its RESOLVED VALUES — effective, plus (under inspection only) dormant.
          -- Lifecycle routing is the AGGREGATOR's job, not the member's: the fleet rule for a stat
          -- lives in the registry, so the fold must see every value the member produced or a dormant
          -- stat would silently become not_applicable at fleet scope while resolving fine per ship.
          -- On a routine call `dormant` is always empty, so this adds exactly nothing.
          v_memberout := v_memberout || jsonb_build_array(jsonb_build_object(
            'entity_id', v_member,
            'status',    'resolved',
            'stats',     (v_one -> 'stats') || coalesce((
                           select jsonb_object_agg(k, v_one -> 'dormant' -> k -> 'value')
                             from jsonb_object_keys(v_one -> 'dormant') k), '{}'::jsonb)));
        exception when others then
          get stacked diagnostics v_err = returned_sqlstate, v_errdetail = message_text;
          v_memberout := v_memberout || jsonb_build_array(jsonb_build_object(
            'entity_id', v_member,
            'status',    'unresolved',
            'failure',   jsonb_build_object(
              'reason',           'ship_resolution_raised',
              'failed_resolver',  'resolve_effective_stats(ship)',
              'sqlstate',         v_err,
              'detail',           v_errdetail,
              'resolver_version', 'stat-v1')));
        end;
      end loop;
    end if;

    v_agg := public.stat_aggregate_fleet(v_memberout, v_reg);

    return jsonb_build_object(
      'resolver_version', 'stat-v1',
      'registry_version', (v_reg ->> 'registry_version')::integer,
      'lifecycle_scope',  p_lifecycle_scope,
      'scope',            'fleet',
      'entity_id',        p_entity_id,
      'resolved_at',      p_resolved_at,
      'context',          coalesce(p_context, '{}'::jsonb),
      'member_count',     v_agg -> 'member_count',
      'applicable',       v_agg -> 'applicable',
      'stats',            v_agg -> 'stats',
      'not_applicable',   v_agg -> 'not_applicable',
      'unresolved',       v_agg -> 'unresolved',
      'dormant',          v_agg -> 'dormant',
      'provenance',       v_agg -> 'provenance',
      'breakdown',        v_agg -> 'breakdown',
      'members',          v_memberout);
  end if;

  -- ══ SHIP SCOPE ════════════════════════════════════════════════════════════════════════════════
  select msi.main_ship_id, msi.player_id, msi.hull_type_id, msi.group_id, msi.cargo_capacity,
         msi.cargo_capacity_m3
    into v_ship
    from public.main_ship_instances msi where msi.main_ship_id = p_entity_id;
  if v_ship.main_ship_id is null then
    raise exception 'STAT-FOUNDATION resolve_effective_stats: no main_ship_instances row for ship %', p_entity_id;
  end if;

  select h.hull_type_id, h.base_speed, coalesce(h.base_stats_json, '{}'::jsonb) as base_stats_json
    into v_hull
    from public.main_ship_hull_types h where h.hull_type_id = v_ship.hull_type_id;
  if v_hull.hull_type_id is null then
    raise exception 'STAT-FOUNDATION resolve_effective_stats: ship % references unknown hull type % — refusing to substitute a fallback hull', p_entity_id, coalesce(v_ship.hull_type_id, '(null)');
  end if;

  -- BASES. A bounded set, from columns already read. speed reads the hull column LIVE (it is never
  -- copied to the instance); cargo_capacity and cargo_volume_m3 read their instance columns.
  --
  -- cargo_volume_m3's base is the ship's REAL volume column (20260618000076), so an inspection
  -- reports the true ship-bound volume instead of a fabricated 0. Reading the base is NOT the
  -- conversion: no module, trait or captain contribution can reach this stat, because the table
  -- leaves its permitted lists empty while unit_conversion is undefined. It is supplied only when
  -- the stat is in scope — stat_combine fails closed on a base for a stat it does not know, and that
  -- check stays exactly as strict as it was.
  v_bases := jsonb_build_object(
    'speed',          coalesce(v_hull.base_speed, 1),
    'cargo_capacity', coalesce(v_ship.cargo_capacity, 0));
  if (v_reg -> 'stats') ? 'cargo_volume_m3' then
    v_bases := v_bases || jsonb_build_object('cargo_volume_m3', coalesce(v_ship.cargo_capacity_m3, 0));
  end if;

  -- The captain multipliers, read ONCE at entry — never per captain: a mid-scan config write must
  -- not split one ship's captains across two regimes (the 0180/0196 posture). The NaN guard is the
  -- WORKING equality test (0198): PG makes NaN = NaN true, so this arm is reachable.
  v_growth    := public.cfg_bool('captain_growth_enabled');
  v_lvl_raw   := coalesce(public.cfg_num('captain_level_bonus_per_level'), 0);
  v_lvl_bonus := greatest(0, case when v_lvl_raw = 'NaN'::double precision then 0 else v_lvl_raw end)::numeric;
  v_aff_raw   := coalesce(public.cfg_num('station_affinity_bonus'), 0);
  v_aff_bonus := greatest(0, case when v_aff_raw = 'NaN'::double precision then 0 else v_aff_raw end)::numeric;
  v_traits_on := public.cfg_bool('ship_traits_enabled');

  -- ── HULL (step 20). Registry-driven: the vocabulary is a JOIN, not a hand-written key list.
  --    A key that is PRESENT but not a JSON number RAISES — it is never coalesced to 0.
  --
  --    EVERY gatherer join below filters on `(v_reg -> 'stats') ? d.stat_id`, i.e. on THE SNAPSHOT,
  --    never on a second lifecycle predicate over the table. That is deliberate: two predicates
  --    answering "is this stat in play?" is how a dormant stat gets gathered by a path that forgot
  --    to be updated. On a routine call a dormant stat is not in the snapshot, so no contribution to
  --    it is ever built — it is not computed and then discarded, it is never reached.
  select v_contrib || coalesce(jsonb_agg(jsonb_build_object(
           'stat_id', d.stat_id, 'source_kind', 'hull', 'source_id', v_hull.hull_type_id,
           'operation', 'flat',
           'amount', case when jsonb_typeof(v_hull.base_stats_json -> d.catalog_key) <> 'number'
                          then public.stat_raise_malformed('hull', v_hull.hull_type_id, d.catalog_key)
                          else (v_hull.base_stats_json ->> d.catalog_key)::numeric end)
         order by d.stat_id), '[]'::jsonb)
    into v_contrib
    from public.stat_definitions d
   where (v_reg -> 'stats') ? d.stat_id
     and v_hull.base_stats_json ? d.catalog_key
     and 'hull' = any (d.permitted_source_kinds);

  -- ── TRAITS (step 30), gated exactly as the deployed fold gates them.
  if v_traits_on then
    select v_contrib || coalesce(jsonb_agg(jsonb_build_object(
             'stat_id', d.stat_id, 'source_kind', 'trait', 'source_id', tt.trait_type_id,
             'operation', case when d.stat_id = 'speed' then 'additive_pct' else 'flat' end,
             'amount', case when jsonb_typeof(tt.stats_json -> d.catalog_key) <> 'number'
                            then public.stat_raise_malformed('trait', tt.trait_type_id, d.catalog_key)
                            else (tt.stats_json ->> d.catalog_key)::numeric end)
           order by tt.trait_type_id, d.stat_id), '[]'::jsonb)
      into v_contrib
      from public.main_ship_traits mt
      join public.ship_trait_types tt on tt.trait_type_id = mt.trait_type_id
      join public.stat_definitions d
        on tt.stats_json ? d.catalog_key
       and (v_reg -> 'stats') ? d.stat_id
       and 'trait' = any (d.permitted_source_kinds)
     where mt.main_ship_id = v_ship.main_ship_id;
  end if;

  -- ── MODULES (step 40) + the module speed PENALTY.
  for v_r in
    -- module_instances' primary key is `id`, NOT `module_instance_id` (0108:43) — only
    -- ship_module_fittings names the column module_instance_id. Aliased here so the contribution's
    -- source_id still reads as the module instance it is.
    select mi.id as module_instance_id, mt.stats_json, mt.slot_type, mt.slot_cost
      from public.ship_module_fittings f
      join public.module_instances mi on mi.id = f.module_instance_id
      join public.module_types mt on mt.id = mi.module_type_id
     where f.main_ship_id = v_ship.main_ship_id
     order by mi.id
  loop
    select v_contrib || coalesce(jsonb_agg(jsonb_build_object(
             'stat_id', d.stat_id, 'source_kind', 'module', 'source_id', v_r.module_instance_id::text,
             'operation', case when d.stat_id = 'speed' then 'additive_pct' else 'flat' end,
             'amount', case when jsonb_typeof(v_r.stats_json -> d.catalog_key) <> 'number'
                            then public.stat_raise_malformed('module', v_r.module_instance_id::text, d.catalog_key)
                            else (v_r.stats_json ->> d.catalog_key)::numeric end)
           order by d.stat_id), '[]'::jsonb)
      into v_contrib
      from public.stat_definitions d
     where (v_reg -> 'stats') ? d.stat_id
       and v_r.stats_json ? d.catalog_key
       and 'module' = any (d.permitted_source_kinds);

    -- pirate_attention DEFAULT (0331 hunk 8): the slot_type CASE is used only when the row does not
    -- state a value. Reproduced exactly, including x slot_cost — but ONLY when pirate_attention is
    -- in scope at all. It is seeded DORMANT, so on every routine call this branch is unreachable and
    -- the fold that 0331 widened across four catalog surfaces is simply not run.
    if (v_reg -> 'stats') ? 'pirate_attention' and not (v_r.stats_json ? 'pirate_attention') then
      v_contrib := v_contrib || jsonb_build_array(jsonb_build_object(
        'stat_id', 'pirate_attention', 'source_kind', 'module',
        'source_id', v_r.module_instance_id::text || ':default', 'operation', 'flat',
        'amount', (case v_r.slot_type when 'weapon' then 2 when 'cargo' then 2 when 'sensor' then 1 else 0 end)::numeric
                  * v_r.slot_cost));
    end if;

    v_spd_pen := v_spd_pen
      + (case v_r.slot_type when 'weapon' then 0.03 when 'cargo' then 0.04 else 0 end)::numeric * v_r.slot_cost;
  end loop;

  -- ── CAPTAINS (step 50). Each captain's stats_json contribution is scaled by the SAME two
  --    multipliers the deployed fold applies, at the same site: x level_mult x affinity_mult. The
  --    attention tradeoff stays level-flat and station-flat on purpose (0331 hunk 9).
  for v_r in
    select ci.id as captain_instance_id, ci.level, ct.specialization, ct.stats_json,
           st.affinity_specialization
      from public.ship_captain_assignments a
      join public.captain_instances ci on ci.id = a.captain_instance_id
      join public.captain_types ct on ct.id = ci.captain_type_id
      left join public.ship_stations st on st.station_id = a.station
     where a.main_ship_id = v_ship.main_ship_id
     order by ci.id
  loop
    v_lvl_mult := case when v_growth then 1 + (v_r.level - 1) * v_lvl_bonus else 1 end;
    v_aff_mult := case when v_r.affinity_specialization = v_r.specialization then 1 + v_aff_bonus else 1 end;

    select v_contrib || coalesce(jsonb_agg(jsonb_build_object(
             'stat_id', d.stat_id, 'source_kind', 'captain', 'source_id', v_r.captain_instance_id::text,
             'operation', case when d.stat_id = 'speed' then 'additive_pct' else 'flat' end,
             'amount', case when jsonb_typeof(v_r.stats_json -> d.catalog_key) <> 'number'
                            then public.stat_raise_malformed('captain', v_r.captain_instance_id::text, d.catalog_key)
                            else (v_r.stats_json ->> d.catalog_key)::numeric * v_lvl_mult * v_aff_mult end)
           order by d.stat_id), '[]'::jsonb)
      into v_contrib
      from public.stat_definitions d
     where (v_reg -> 'stats') ? d.stat_id
       and v_r.stats_json ? d.catalog_key
       and 'captain' = any (d.permitted_source_kinds)
       and d.stat_id <> 'pirate_attention';

    -- Same gate as the module block: dormant means NOT COMPUTED, so on a routine call neither the
    -- stated value nor the specialization default is gathered.
    if (v_reg -> 'stats') ? 'pirate_attention' then
      if v_r.stats_json ? 'pirate_attention' then
        v_contrib := v_contrib || jsonb_build_array(jsonb_build_object(
          'stat_id', 'pirate_attention', 'source_kind', 'captain',
          'source_id', v_r.captain_instance_id::text, 'operation', 'flat',
          'amount', (v_r.stats_json ->> 'pirate_attention')::numeric));
      else
        v_contrib := v_contrib || jsonb_build_array(jsonb_build_object(
          'stat_id', 'pirate_attention', 'source_kind', 'captain',
          'source_id', v_r.captain_instance_id::text || ':default', 'operation', 'flat',
          'amount', (case v_r.specialization when 'combat' then 2 when 'trade' then 1
                          when 'exploration' then 1 when 'mining' then 1 else 0 end)::numeric));
      end if;
    end if;

    v_spd_pen := v_spd_pen
      + (case v_r.specialization when 'combat' then 0.02 when 'trade' then 0.02 when 'mining' then 0.02 else 0 end)::numeric;
  end loop;

  -- ── BUFFS (step 60/70). The buff authority emits NORMALIZED contributions; this resolver consumes
  --    them and re-implements neither timing nor stacking.
  v_buffs := public.resolve_active_buffs('ship', v_ship.main_ship_id, p_context, p_resolved_at);
  for v_b in select value from jsonb_array_elements(v_buffs -> 'buffs') loop
    v_contrib := v_contrib || jsonb_build_array(jsonb_build_object(
      'stat_id',     v_b ->> 'stat_id',
      'source_kind', v_b ->> 'source_kind',
      'source_id',   coalesce(v_b ->> 'source_instance_id', '') || ':' || (v_b ->> 'buff_def_id'),
      'operation',   v_b ->> 'operation',
      'amount',      (v_b -> 'magnitude')));
  end loop;

  -- ── THE SPEED PENALTY (step 80). The deployed fold applies it as ONE factor, (1 - SIGMA), not as a
  --    product of per-source factors — so it is emitted as ONE multiplicative contribution of
  --    -SIGMA. A product of (1 - p_i) would NOT equal (1 - SIGMA p_i), and the difference is a live
  --    travel-speed change. It is emitted only when non-zero, so a penalty-free ship's breakdown
  --    carries no phantom step.
  if v_spd_pen <> 0 then
    v_contrib := v_contrib || jsonb_build_array(jsonb_build_object(
      'stat_id', 'speed', 'source_kind', 'speed_penalty', 'source_id', 'aggregate_slot_and_specialization_penalty',
      'operation', 'multiplicative_pct', 'amount', -v_spd_pen));
  end if;

  v_folded := public.stat_combine(v_contrib, v_bases, v_reg);

  return jsonb_build_object(
    'resolver_version', 'stat-v1',
    'registry_version', (v_reg ->> 'registry_version')::integer,
    'lifecycle_scope',  p_lifecycle_scope,
    'scope',            'ship',
    'entity_id',        p_entity_id,
    'resolved_at',      p_resolved_at,
    'context',          coalesce(p_context, '{}'::jsonb),
    'stats',            v_folded -> 'stats',
    'not_applicable',   v_folded -> 'not_applicable',
    'unresolved',       v_folded -> 'unresolved',
    'dormant',          v_folded -> 'dormant',
    'provenance',       v_folded -> 'provenance',
    'breakdown',        v_folded -> 'breakdown',
    'buffs',            v_buffs -> 'buffs',
    'buffs_suppressed', v_buffs -> 'suppressed');
end;
$$;

-- ── 9. THE ONLY STATE-CHANGING RPCs IN THIS SLICE — sole writers of buff_instances ────────────────
-- Fixed search_path, in-body authorization (service_role only — there is no player-facing buff grant
-- in this slice), narrow EXECUTE grants, referential integrity by FK, and idempotency by the unique
-- (buff_def_id, target_scope, target_entity_id, source_instance_id) key. No player-controlled
-- dynamic SQL exists anywhere: there is no execute, no format-into-execute, and every identifier is
-- a literal in this file.
create function public.buff_grant(
  p_buff_def_id      text,
  p_target_scope     text,
  p_target_entity_id uuid,
  p_source_instance_id uuid    default null,
  p_starts_at        timestamptz default now(),
  p_expires_at       timestamptz default null,
  p_magnitude_override numeric default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_def record;
  v_id  uuid;
begin
  if current_setting('role', true) not in ('service_role') and session_user not in ('postgres','supabase_admin') then
    raise exception 'STAT-FOUNDATION buff_grant: not authorized (service-role only)';
  end if;

  select bd.buff_def_id, bd.target_scope, bd.duration_kind, bd.default_duration_seconds, bd.is_active
    into v_def from public.buff_definitions bd where bd.buff_def_id = p_buff_def_id;
  if v_def.buff_def_id is null then
    raise exception 'STAT-FOUNDATION buff_grant: unknown buff definition %', coalesce(p_buff_def_id, '(null)');
  end if;
  if not v_def.is_active then
    raise exception 'STAT-FOUNDATION buff_grant: buff definition % is inactive', p_buff_def_id;
  end if;
  if p_target_scope is distinct from v_def.target_scope then
    raise exception 'STAT-FOUNDATION buff_grant: definition % targets scope %, got %', p_buff_def_id, v_def.target_scope, coalesce(p_target_scope, '(null)');
  end if;
  if p_target_entity_id is null then
    raise exception 'STAT-FOUNDATION buff_grant: target entity id is required';
  end if;
  if p_expires_at is not null and p_expires_at <= p_starts_at then
    raise exception 'STAT-FOUNDATION buff_grant: invalid buff window (expires_at <= starts_at)';
  end if;
  if v_def.duration_kind = 'timed' and p_expires_at is null then
    raise exception 'STAT-FOUNDATION buff_grant: definition % is timed and requires an expires_at', p_buff_def_id;
  end if;

  -- IDEMPOTENT REFRESH: the same definition from the same source on the same target is ONE row.
  -- A repeated grant refreshes its window rather than creating a duplicate contribution identity.
  insert into public.buff_instances
    (buff_def_id, target_scope, target_entity_id, source_instance_id, starts_at, expires_at, magnitude_override)
  values
    (p_buff_def_id, p_target_scope, p_target_entity_id, p_source_instance_id, p_starts_at, p_expires_at, p_magnitude_override)
  on conflict (buff_def_id, target_scope, target_entity_id, source_instance_id) do update
    set starts_at = excluded.starts_at,
        expires_at = excluded.expires_at,
        magnitude_override = excluded.magnitude_override
  returning buff_instance_id into v_id;

  return jsonb_build_object('ok', true, 'buff_instance_id', v_id);
end;
$$;

create function public.buff_revoke(p_buff_instance_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if current_setting('role', true) not in ('service_role') and session_user not in ('postgres','supabase_admin') then
    raise exception 'STAT-FOUNDATION buff_revoke: not authorized (service-role only)';
  end if;
  if p_buff_instance_id is null then
    raise exception 'STAT-FOUNDATION buff_revoke: buff_instance_id is required';
  end if;
  delete from public.buff_instances where buff_instance_id = p_buff_instance_id;
  get diagnostics v_n = row_count;
  -- Idempotent: revoking an already-revoked instance is a no-op, not an error.
  return jsonb_build_object('ok', true, 'revoked', v_n);
end;
$$;

-- ── 9b. THE INSPECTION SURFACE — how the owner CHECKS this without a database console ─────────────
-- The owner's ruling: a foundation nobody can look at is a foundation nobody can trust. These two
-- read-only RPCs are the door. They change nothing, decide nothing, and are called by no existing
-- game path — they exist so a human can point at any number this architecture produces and walk it
-- back to the catalog row that made it.

-- get_stat_definitions — the whole registry, exactly as the client will eventually consume it (this
-- is the RPC that will later let STAT_LABELS and STAT_KEY_ORDER be deleted from the frontend).
create function public.get_stat_definitions()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return jsonb_build_object('ok', true, 'registry', public.stat_registry_snapshot());
end;
$$;

-- get_my_effective_stats — resolve YOUR OWN ship or fleet, with the full contribution breakdown.
--
-- OWNERSHIP-SCOPED, and that is not optional: prod is a live ~30-player game, so "inspectable" must
-- never become "every player can read every other player's fleet". auth.uid() must own the entity.
-- Envelope-wrapped in the house idiom (0159:188-189): a resolver raise degrades to a visible
-- {ok:false,error} instead of a 500, so a defect here is loud and harmless.
--
-- THE AUTHORIZED INSPECTION PATH, and the only one. p_options may carry {"include_dormant": true},
-- which is the ONLY way a dormant stat is ever computed anywhere in this system. It is:
--   · EXPLICITLY REQUESTED — a caller that does not ask gets the routine set;
--   · AUTHORIZED — this function has already established that auth.uid() OWNS the entity;
--   · AND STILL NOT EFFECTIVE — dormant values come back in a separate `dormant` map, each marked
--     effective=false, never in `stats`. A client cannot describe them as effective without
--     deliberately reading a field that says they are not.
create function public.get_my_effective_stats(
  p_scope     text,
  p_entity_id uuid,
  p_context   jsonb default '{}'::jsonb,
  p_options   jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_player uuid := auth.uid();
  v_owner  uuid;
  v_life   text := 'routine';
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_options is not null and jsonb_typeof(p_options) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_options',
      'detail', 'p_options must be a JSON object');
  end if;
  if coalesce(p_options -> 'include_dormant', 'false'::jsonb) = 'true'::jsonb then
    v_life := 'inspection';
  end if;
  if p_scope is null or p_scope not in ('ship','fleet') then
    return jsonb_build_object('ok', false, 'error', 'invalid_scope',
      'detail', 'scope must be ''ship'' or ''fleet''');
  end if;
  if p_entity_id is null then
    return jsonb_build_object('ok', false, 'error', 'entity_required');
  end if;

  if p_scope = 'ship' then
    select msi.player_id into v_owner
      from public.main_ship_instances msi where msi.main_ship_id = p_entity_id;
  else
    select g.player_id into v_owner
      from public.ship_groups g where g.group_id = p_entity_id;
  end if;
  if v_owner is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_owner is distinct from v_player then
    -- Deliberately the SAME answer as not_found: a probe must not be able to tell "exists but is
    -- someone else's" from "does not exist".
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true)
       || public.resolve_effective_stats(p_scope, p_entity_id, coalesce(p_context, '{}'::jsonb),
                                         now(), v_life);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'resolve_failed', 'detail', sqlerrm);
end;
$$;

comment on function public.get_my_effective_stats(text, uuid, jsonb, jsonb) is
  'STAT FOUNDATION (0340): the owner-facing INSPECTION door. Resolves the caller''s OWN ship '
  '(main_ship_id) or fleet (ship_groups.group_id) through the canonical resolver and returns the '
  'stats WITH the full ordered contribution breakdown, so every number can be traced to the row '
  'that produced it. Read-only. Calls nothing in the live gameplay path and is called by nothing.';

-- ── 10. ACL — the engine internals stay server-only; the two INSPECTION RPCs are client-callable ──
-- Strip the PostgreSQL default EXECUTE-to-PUBLIC first (that default is exactly how a "revoked"
-- function stays reachable), then grant service_role only.
revoke all on function public.stat_raise_malformed(text, text, text) from public, anon, authenticated;
revoke all on function public.stat_lifecycle_in_scope(text, text) from public, anon, authenticated;
revoke all on function public.stat_assert_provenance_partition(jsonb, text) from public, anon, authenticated;
revoke all on function public.stat_require_resolved(jsonb, text[], text) from public, anon, authenticated;
revoke all on function public.stat_required_sum(jsonb, text[]) from public, anon, authenticated;
revoke all on function public.stat_registry_snapshot(text) from public, anon, authenticated;
revoke all on function public.stat_combine(jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.stat_aggregate_fleet(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.progression_level_for_xp(text, numeric) from public, anon, authenticated;
revoke all on function public.progression_xp_for_level(text, integer) from public, anon, authenticated;
revoke all on function public.resolve_progression(text, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.buff_apply_stacking(jsonb, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function public.buff_derive_source_instances(text, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.resolve_active_buffs(text, uuid, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function public.resolve_effective_stats(text, uuid, jsonb, timestamptz, text) from public, anon, authenticated;
revoke all on function public.buff_grant(text, text, uuid, uuid, timestamptz, timestamptz, numeric) from public, anon, authenticated;
revoke all on function public.buff_revoke(uuid) from public, anon, authenticated;

grant execute on function public.stat_raise_malformed(text, text, text) to service_role;
grant execute on function public.stat_lifecycle_in_scope(text, text) to service_role;
grant execute on function public.stat_assert_provenance_partition(jsonb, text) to service_role;
grant execute on function public.stat_require_resolved(jsonb, text[], text) to service_role;
grant execute on function public.stat_required_sum(jsonb, text[]) to service_role;
grant execute on function public.stat_registry_snapshot(text) to service_role;
grant execute on function public.stat_combine(jsonb, jsonb, jsonb) to service_role;
grant execute on function public.stat_aggregate_fleet(jsonb, jsonb) to service_role;
grant execute on function public.progression_level_for_xp(text, numeric) to service_role;
grant execute on function public.progression_xp_for_level(text, integer) to service_role;
grant execute on function public.resolve_progression(text, uuid, timestamptz) to service_role;
grant execute on function public.buff_apply_stacking(jsonb, jsonb, timestamptz) to service_role;
grant execute on function public.buff_derive_source_instances(text, uuid, timestamptz) to service_role;
grant execute on function public.resolve_active_buffs(text, uuid, jsonb, timestamptz) to service_role;
grant execute on function public.resolve_effective_stats(text, uuid, jsonb, timestamptz, text) to service_role;
grant execute on function public.buff_grant(text, text, uuid, uuid, timestamptz, timestamptz, numeric) to service_role;
grant execute on function public.buff_revoke(uuid) to service_role;

-- THE TWO INSPECTION RPCs — client-callable ON PURPOSE. Strip the PUBLIC default first, then grant
-- exactly `authenticated`. anon is NOT granted: an unauthenticated caller has no ships to inspect,
-- and get_my_effective_stats would only ever answer not_authenticated.
revoke all on function public.get_stat_definitions() from public, anon, authenticated;
revoke all on function public.get_my_effective_stats(text, uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.get_stat_definitions() to authenticated, service_role;
grant execute on function public.get_my_effective_stats(text, uuid, jsonb, jsonb) to authenticated, service_role;

-- ── 11. SELF-ASSERTS — the migration proves its own grounding or refuses to land ──────────────────
-- NON-VACUITY IS THE DESIGN GOAL, not a nice-to-have. Three vacuity shapes have already shipped in
-- this repository (0300:153-191 missing-key-passes, 0331:770-779 early-return-on-empty-chain,
-- 0333:451-475 loop-over-empty-query). Each is closed here by construction:
--   · every existence check states an EXACT expected cardinality derived from the seed in this same
--     file, so absence FAILS instead of passing;
--   · the algebraic equivalence checks read NO game row — they call the pure leaves with hard-coded
--     input and compare against the deployed expression transcribed inline, so they run identically
--     on an empty disposable chain and on production;
--   · no loop is ever the assertion.
do $sfassert$
declare
  v_n     integer;
  v_out   jsonb;
  v_agg   jsonb;
  v_reg   jsonb;
  v_regi  jsonb;
  v_env   jsonb;
  v_num   numeric;
  v_plan  text;
  v_part  text;
  v_stk   jsonb;
  v_ces   text;
  v_cges  text;
  v_ccge  text;
  v_tick  text;
  v_rfms  text;
  v_comb  text;
  v_aggf  text;
  v_stack text;
  v_buf   text;
  v_res   text;
  v_bad   integer;
  v_x     numeric;
  v_role  text;
  v_priv  text;
  v_fn    text;
begin
  -- (1) NO FLAG IS INTRODUCED BY THIS SLICE. Asserted, because "we removed the inert flag" must be
  --     a fact the migration can prove, not a claim in a comment that a later edit could quietly
  --     falsify.
  if exists (select 1 from public.game_config where key = 'stat_resolver_enabled') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: stat_resolver_enabled exists — this slice introduces NO feature flag; a flag that gates nothing is a lie about a safety device';
  end if;

  -- (2) EXACT SEED CARDINALITIES. A deleted seed row fails here; it cannot pass by not existing.
  select count(*) into v_n from public.stat_definitions;
  if v_n <> 10 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: stat_definitions has % row(s), want exactly 10', v_n; end if;
  -- EXACT LIFECYCLE CARDINALITIES. If a later edit promotes a dormant stat without an owner ruling,
  -- this line is what fails.
  select count(*) into v_n from public.stat_definitions where lifecycle = 'active';
  if v_n <> 3 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % ACTIVE stat_definitions, want exactly 3 (combat_power, survival, speed)', v_n; end if;
  if (select count(*) from public.stat_definitions
       where lifecycle = 'active' and stat_id in ('combat_power','survival','speed')) <> 3 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the three active stats are not combat_power/survival/speed'; end if;
  select count(*) into v_n from public.stat_definitions where lifecycle = 'deprecated';
  if v_n <> 1 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % DEPRECATED stat_definitions, want exactly 1 (cargo_capacity)', v_n; end if;
  select count(*) into v_n from public.stat_definitions where lifecycle = 'dormant';
  if v_n <> 6 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % DORMANT stat_definitions, want exactly 6 (cargo_volume_m3 + the five confirmed-dead outputs)', v_n; end if;
  -- THE FIVE CONFIRMED-DEAD OUTPUTS ARE DORMANT, BY NAME. The owner's ruling is that prior
  -- implementation effort does not create gameplay semantics; this is that ruling, executed.
  if (select count(*) from public.stat_definitions
       where lifecycle = 'dormant'
         and stat_id in ('retreat_safety','scouting','mining_yield','repair','pirate_attention')) <> 5 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the five confirmed-dead outputs are not all dormant'; end if;
  -- ...and NO dormant stat carries a consumer of any kind (the CHECK guarantees it; this proves the
  -- CHECK is the one actually on the table).
  if exists (select 1 from public.stat_definitions
              where lifecycle = 'dormant'
                and (engine_consumer is not null or presentation_consumer is not null)) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a dormant stat carries a consumer'; end if;
  -- ...and every ACTIVE stat names one.
  if exists (select 1 from public.stat_definitions
              where lifecycle = 'active'
                and engine_consumer is null and presentation_consumer is null) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an active stat names no consumer — active means something DECIDES with it'; end if;
  select count(*) into v_n from public.progression_curves;
  if v_n <> 1 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: progression_curves has % row(s), want exactly 1', v_n; end if;
  select count(*) into v_n from public.progression_tracks;
  if v_n <> 1 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: progression_tracks has % row(s), want exactly 1 (ship/fleet/player XP is deliberately NOT stubbed)', v_n; end if;
  select count(*) into v_n from public.buff_instances;
  if v_n <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: buff_instances is non-empty at migration time (% row(s), want 0)', v_n; end if;

  -- buff_definitions is seeded FROM command_buff_types, so its expected cardinality is derived from
  -- the catalog rather than hard-coded: exactly one row per (buff, numeric stat key) pair.
  select count(*) into v_n
    from public.command_buff_types cbt
    join public.stat_definitions d on cbt.stats_json ? d.catalog_key
   where jsonb_typeof(cbt.stats_json -> d.catalog_key) = 'number'
     and d.lifecycle = 'active' and 'command_ship' = any (d.permitted_source_kinds);
  select count(*) into v_bad from public.buff_definitions;
  if v_bad <> v_n then
    raise exception 'STAT-FOUNDATION self-assert FAIL: buff_definitions has % row(s), want % (one per (command buff, ACTIVE stat) pair)', v_bad, v_n; end if;
  if v_n < 1 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % (buff, active stat) pair(s) derived from command_buff_types — the catalog is missing or unreadable', v_n; end if;
  -- NO BUFF DEFINITION MAY NAME A NON-ACTIVE STAT. A stored contribution aimed at a stat that is
  -- absent from the routine snapshot would make stat_combine raise on an ordinary ship, so this is a
  -- correctness gate, not only a hygiene one.
  if exists (select 1 from public.buff_definitions b
               join public.stat_definitions d on d.stat_id = b.stat_id
              where d.lifecycle <> 'active') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a buff_definitions row targets a non-active stat'; end if;

  -- (3) THE OWNER'S DECIDED RULINGS ARE THE ONES ACTUALLY SEEDED.
  if (select fleet_aggregation from public.stat_definitions where stat_id = 'scouting') <> 'max' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: scouting is not registered max'; end if;
  if (select fleet_aggregation from public.stat_definitions where stat_id = 'retreat_safety') <> 'min' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: retreat_safety is not registered min'; end if;
  if (select fleet_aggregation from public.stat_definitions where stat_id = 'speed') <> 'min' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: speed is not registered min (a fleet travels at its slowest ship)'; end if;
  if (select min_value from public.stat_definitions where stat_id = 'speed') <> 0.2 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: speed floor is not the deployed 0.2 (0205:662)'; end if;
  -- CARGO, AFTER THE RE-RULING. The legacy integer is DEPRECATED and non-authoritative: no source
  -- may contribute, no operation is permitted, no engine consumer, and a reason is recorded.
  if (select array_length(permitted_source_kinds, 1) from public.stat_definitions where stat_id = 'cargo_capacity') is not null
     or (select array_length(permitted_operations, 1) from public.stat_definitions where stat_id = 'cargo_capacity') is not null
     or (select engine_consumer from public.stat_definitions where stat_id = 'cargo_capacity') is not null
     or (select lifecycle from public.stat_definitions where stat_id = 'cargo_capacity') <> 'deprecated'
     or (select deprecated_reason from public.stat_definitions where stat_id = 'cargo_capacity') is null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: cargo_capacity is not registered as deprecated, non-authoritative legacy'; end if;
  -- ...and the CANONICAL TARGET is modelled, in m3, superseding it, with the conversion NOT
  -- activated. Every clause here is a thing the owner ruled and a thing the table now enforces.
  if (select unit from public.stat_definitions where stat_id = 'cargo_volume_m3') <> 'm3'
     or (select supersedes_stat_id from public.stat_definitions where stat_id = 'cargo_volume_m3') <> 'cargo_capacity'
     or (select unit_conversion from public.stat_definitions where stat_id = 'cargo_volume_m3') is not null
     or (select lifecycle from public.stat_definitions where stat_id = 'cargo_volume_m3') <> 'dormant'
     or (select ship_base_ref from public.stat_definitions where stat_id = 'cargo_volume_m3') <> 'cargo_capacity_m3' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: cargo_volume_m3 is not the dormant canonical m3 target superseding cargo_capacity with an UNDEFINED conversion'; end if;
  -- THE CONVERSION IS NOT ACTIVATED: with unit_conversion NULL the table forbids the volume stat
  -- from accepting anything at all, so the deployed `+25` cargo module cannot reach it by any route.
  if (select array_length(permitted_source_kinds, 1) from public.stat_definitions where stat_id = 'cargo_volume_m3') is not null
     or (select array_length(permitted_operations, 1) from public.stat_definitions where stat_id = 'cargo_volume_m3') is not null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: cargo_volume_m3 accepts a contribution while its unit conversion is undefined'; end if;
  -- ...while the INTENT is recorded, because the owner ruled that modules, captains and traits ARE
  -- meant to affect real volume once a conversion exists. Intent declares; it does not permit.
  if not ((select intended_source_kinds from public.stat_definitions where stat_id = 'cargo_volume_m3')
          @> array['module','captain','trait']::text[]) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: cargo_volume_m3 does not record module/captain/trait as its intended sources'; end if;
  -- The two cargo representations must never share a catalog key: a shared key is exactly how the
  -- legacy integer would silently become the volume number.
  if (select catalog_key from public.stat_definitions where stat_id = 'cargo_volume_m3')
     = (select catalog_key from public.stat_definitions where stat_id = 'cargo_capacity') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the m3 authority and the legacy integer share a catalog key'; end if;
  -- THE CAP LIVES IN THE TRACK DEFINITION, and it is 99.
  if (select c.max_level from public.progression_tracks t join public.progression_curves c on c.curve_id = t.curve_id
       where t.track_id = 'captain_v1') <> 99 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: captain_v1 is not capped at 99'; end if;
  if (select c.post_cap_behaviour from public.progression_tracks t join public.progression_curves c on c.curve_id = t.curve_id
       where t.track_id = 'captain_v1') <> 'accumulate_xp_no_level' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: captain_v1 post-cap behaviour is not accumulate_xp_no_level'; end if;
  -- NO BLANKET SUM: the CHECK that makes it unrepresentable actually exists.
  if not exists (select 1 from pg_constraint where conname = 'stat_definitions_no_blanket_sum') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the no_blanket_sum CHECK is missing'; end if;
  if not exists (select 1 from pg_constraint where conname = 'stat_definitions_live_reader_coherent') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the live-reader coherence CHECK is missing'; end if;
  -- SNAPSHOT POLICY: exactly the two frozen combat stats today, and no stat claims `live` without
  -- naming its re-reader (the CHECK guarantees the second half; this pins the first).
  -- THREE, not two. combat_power and survival freeze as attack_snapshot / defense_snapshot
  -- (0301:742-744), and `speed` freezes as move_speed (0301:754, scaled by
  -- combat_player_speed_scale). An earlier draft of this assert said two and was caught by the
  -- disposable full-chain apply — the seed was right and the assertion was wrong, which is exactly
  -- the direction a deploy-time assert is supposed to fail in.
  select count(*) into v_n from public.stat_definitions where combat_snapshot = 'frozen';
  if v_n <> 3 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % stat(s) registered frozen, want exactly 3 (combat_power, survival, speed)', v_n; end if;
  if (select count(*) from public.stat_definitions
       where combat_snapshot = 'frozen' and stat_id in ('combat_power','survival','speed')) <> 3 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the three frozen stats are not combat_power/survival/speed'; end if;
  select count(*) into v_n from public.stat_definitions where combat_snapshot = 'live';
  if v_n <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % stat(s) registered live — this slice introduces NO new live re-read', v_n; end if;

  -- (4) FAIL-CLOSED REGISTRY LAW, proven by attempting the illegal thing. A CHECK that is never
  --     exercised is a CHECK nobody has confirmed works.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, registered_in)
    values ('__sf_probe_blanket_sum__', '__sf_probe_bs__', 'probe', 999001, 'both', 'multiplier', 'fraction',
            'numeric', 2, 'none', null, 'multiplier_bonus',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'dormant', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: a multiplier stat with fleet_aggregation=sum was ACCEPTED — blanket summing is not actually unrepresentable';
  exception when check_violation then null;
  end;
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, registered_in)
    values ('__sf_probe_bad_op__', '__sf_probe_bo__', 'probe', 999002, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat','evaluate_sql']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'dormant', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: an unknown operation was ACCEPTED into permitted_operations';
  exception when check_violation then null;
  end;
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, registered_in)
    values ('__sf_probe_bad_scope__', '__sf_probe_bsc__', 'probe', 999003, 'galaxy', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'dormant', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: an invalid scope was ACCEPTED';
  exception when check_violation then null;
  end;
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, registered_in)
    values ('__sf_probe_bad_agg__', '__sf_probe_ba__', 'probe', 999004, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'median', 'not_applicable', 'dormant', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: an invalid fleet aggregation rule was ACCEPTED';
  exception when check_violation then null;
  end;
  -- LIFECYCLE FAIL-CLOSED, PROBE 0: an OMITTED lifecycle is refused. There is no default, so a row
  -- that forgets to state its standing cannot be silently promoted to a live gameplay stat. This is
  -- the probe the disposable full-chain apply discovered was needed: the four registry probes above
  -- predate this column and were aborting on exactly this violation instead of the CHECK each meant
  -- to exercise. It is now a probe in its own right rather than an accident.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, registered_in)
    values ('__sf_probe_no_life__', '__sf_probe_nl__', 'probe', 999000, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: a stat with NO lifecycle was ACCEPTED — the column has a default it must not have';
  exception when not_null_violation then null;
  end;
  -- LIFECYCLE FAIL-CLOSED, PROBE 1: an UNKNOWN lifecycle value is refused by the table. This is the
  -- owner's "fail closed on anything else", executed rather than asserted in prose.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, engine_consumer, registered_in)
    values ('__sf_probe_bad_life__', '__sf_probe_bl__', 'probe', 999005, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'experimental', 'nobody', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: lifecycle ''experimental'' was ACCEPTED — the lifecycle vocabulary does not fail closed';
  exception when check_violation then null;
  end;
  -- LIFECYCLE FAIL-CLOSED, PROBE 2: an ACTIVE stat with no consumer of any kind is refused. "Active
  -- because a catalog mentions it" is the exact error the owner ruled against.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, registered_in)
    values ('__sf_probe_no_consumer__', '__sf_probe_nc__', 'probe', 999006, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'active', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: an ACTIVE stat with no gameplay and no presentation consumer was ACCEPTED';
  exception when check_violation then null;
  end;
  -- LIFECYCLE FAIL-CLOSED, PROBE 3: a DORMANT stat may not smuggle in a consumer.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, engine_consumer, registered_in)
    values ('__sf_probe_dormant_consumer__', '__sf_probe_dc__', 'probe', 999007, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'dormant', 'some_function', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: a DORMANT stat with an engine consumer was ACCEPTED';
  exception when check_violation then null;
  end;
  -- LIFECYCLE FAIL-CLOSED, PROBE 4: a DEPRECATED stat may not hold a gameplay consumer.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, engine_consumer, deprecated_reason, registered_in)
    values ('__sf_probe_dep_consumer__', '__sf_probe_pc__', 'probe', 999008, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'deprecated', 'some_function', 'legacy', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: a DEPRECATED stat with a gameplay consumer was ACCEPTED — deprecated means forbidden to new gameplay consumers';
  exception when check_violation then null;
  end;
  -- THE CARGO GUARD, PROBED: a stat that supersedes another with an UNDEFINED conversion may not
  -- accept a contribution. This is what makes "do not copy the +25 into the volume field"
  -- impossible rather than merely forbidden.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, supersedes_stat_id, registered_in)
    values ('__sf_probe_cargo_conv__', '__sf_probe_cc__', 'probe', 999009, 'both', 'flat', 'm3',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module']::text[], array['module']::text[],
            'sum', 'not_applicable', 'dormant', 'cargo_capacity', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: a superseding stat with an UNDEFINED unit conversion ACCEPTED a module contribution — the cargo conversion is not structurally inert';
  exception when check_violation then null;
  end;
  -- ...and intent must precede permission: nothing may be permitted that was not declared intended.
  begin
    insert into public.stat_definitions (
      stat_id, catalog_key, display_name, display_order, applies_to_scope, value_kind, unit,
      numeric_domain, round_to, ship_base_source, ship_base_ref, combination_class,
      permitted_operations, permitted_source_kinds, intended_source_kinds,
      fleet_aggregation, combat_snapshot, lifecycle, engine_consumer, registered_in)
    values ('__sf_probe_unintended__', '__sf_probe_ui__', 'probe', 999010, 'both', 'flat', 'points',
            'numeric', 2, 'none', null, 'additive',
            array['flat']::text[], array['module','captain']::text[], array['module']::text[],
            'sum', 'not_applicable', 'active', 'x', '0340-probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: a source category was PERMITTED without being declared INTENDED';
  exception when check_violation then null;
  end;

  select count(*) into v_n from public.stat_definitions where stat_id like '\_\_sf\_probe\_%';
  if v_n <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % probe row(s) survived — a fail-closed probe actually inserted', v_n; end if;

  -- (5) DETERMINISM. Exact TOKEN COUNTS in the new bodies (the 0260:1246-1254 counting idiom, not a
  --     boolean absence test). Time enters the resolvers only as p_resolved_at.
  select prosrc into v_comb  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public' and p.proname='stat_combine';
  select prosrc into v_aggf  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public' and p.proname='stat_aggregate_fleet';
  select prosrc into v_stack from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public' and p.proname='buff_apply_stacking';
  select prosrc into v_buf   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public' and p.proname='resolve_active_buffs';
  select prosrc into v_res   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public' and p.proname='resolve_effective_stats';
  if v_comb is null or v_aggf is null or v_stack is null or v_buf is null or v_res is null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a new resolver body is missing from pg_proc'; end if;

  v_n := (length(v_comb)  - length(replace(v_comb,  'random(', ''))) / length('random(')
       + (length(v_aggf)  - length(replace(v_aggf,  'random(', ''))) / length('random(')
       + (length(v_stack) - length(replace(v_stack, 'random(', ''))) / length('random(');
  if v_n <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the pure leaves carry % random( call(s), want 0', v_n; end if;
  v_n := (length(v_comb)  - length(replace(v_comb,  'now(', ''))) / length('now(')
       + (length(v_aggf)  - length(replace(v_aggf,  'now(', ''))) / length('now(')
       + (length(v_stack) - length(replace(v_stack, 'now(', ''))) / length('now(');
  if v_n <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the pure leaves carry % clock-reading token(s), want 0', v_n; end if;
  if strpos(v_comb, 'setseed') > 0 or strpos(v_aggf, 'setseed') > 0 or strpos(v_stack, 'setseed') > 0
     or strpos(v_comb, 'clock_timestamp') > 0 or strpos(v_aggf, 'clock_timestamp') > 0 or strpos(v_stack, 'clock_timestamp') > 0
     or strpos(v_comb, 'current_timestamp') > 0 or strpos(v_aggf, 'current_timestamp') > 0 or strpos(v_stack, 'current_timestamp') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a pure leaf carries a session-clock or session-RNG token'; end if;

  -- The pure leaves really are table-free: no FROM over a public table, no write.
  --
  -- ONE schema-qualified call is permitted, and only one: stat_assert_provenance_partition. The
  -- provenance law must hold at BOTH scopes, and inlining it into both leaves would be two copies
  -- of one rule — the exact spaghetti this architecture exists to end. So the allowance is
  -- explicit, narrow, and paid for: the callee is itself proven table-free and write-free
  -- immediately below, so "provable on an empty database" survives the composition.
  select prosrc into v_part from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'stat_assert_provenance_partition';
  if v_part is null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: stat_assert_provenance_partition is missing — the provenance law has no implementation'; end if;
  if strpos(v_part, 'public.') > 0 or strpos(v_part, 'insert into') > 0
     or strpos(v_part, 'update ') > 0 or strpos(v_part, 'delete from') > 0
     or strpos(v_part, 'random(') > 0 or strpos(v_part, 'now(') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the provenance law reads a table, writes, or is non-deterministic — the pure leaves may not call it'; end if;
  if strpos(replace(v_comb, 'public.stat_assert_provenance_partition', ''), 'public.') > 0
     or strpos(replace(v_aggf, 'public.stat_assert_provenance_partition', ''), 'public.') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a pure fold leaf references a table — it is no longer provable on an empty database'; end if;
  -- ...and both leaves DO enforce the law, so the allowance is not merely tolerated, it is used.
  if strpos(v_comb, 'stat_assert_provenance_partition') = 0
     or strpos(v_aggf, 'stat_assert_provenance_partition') = 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a fold leaf returns a result without enforcing the provenance partition law'; end if;
  if strpos(v_comb, 'insert into') > 0 or strpos(v_comb, 'update ') > 0 or strpos(v_comb, 'delete from') > 0
     or strpos(v_aggf, 'insert into') > 0 or strpos(v_aggf, 'update ') > 0 or strpos(v_aggf, 'delete from') > 0
     or strpos(v_res, 'insert into') > 0 or strpos(v_res, 'delete from') > 0
     or strpos(v_buf, 'insert into') > 0 or strpos(v_buf, 'delete from') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a READ resolver carries a write statement'; end if;

  -- (6) THE ACYCLICITY PROHIBITION, asserted on the live bodies: the buff family may never call the
  --     stat resolver. This is what makes the graph terminate.
  if strpos(v_buf, 'resolve_effective_stats') > 0 or strpos(v_stack, 'resolve_effective_stats') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the buff family calls resolve_effective_stats — the resolver graph is cyclic'; end if;
  if strpos((select prosrc from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
              where ns.nspname='public' and p.proname='buff_derive_source_instances'), 'resolve_effective_stats') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: buff_derive_source_instances calls resolve_effective_stats — the resolver graph is cyclic'; end if;
  -- NO DYNAMIC SQL anywhere in the new surface.
  if strpos(v_buf, 'execute ') > 0 or strpos(v_stack, 'execute ') > 0 or strpos(v_res, 'execute ') > 0
     or strpos(v_comb, 'execute ') > 0 or strpos(v_aggf, 'execute ') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a resolver carries dynamic SQL (execute)'; end if;

  -- (7) THE LIVE ALGEBRAIC-EQUIVALENCE CHECKS, EXECUTED AT DEPLOY, READING NO GAME ROW.
  --     These call the real leaves on synthetic input and compare against the DEPLOYED expressions
  --     transcribed inline from 0205:662 and 0205:677. If either deployed expression ever changes,
  --     this assert fails at deploy. Identical on an empty chain and on production.
  v_reg := public.stat_registry_snapshot();

  v_out := public.stat_combine(
    $j$[ {"stat_id":"combat_power","source_kind":"hull",   "source_id":"h1","operation":"flat","amount":15},
         {"stat_id":"combat_power","source_kind":"module", "source_id":"m1","operation":"flat","amount":4},
         {"stat_id":"combat_power","source_kind":"captain","source_id":"c1","operation":"flat","amount":6},
         {"stat_id":"speed",       "source_kind":"module", "source_id":"m1","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed",       "source_kind":"trait",  "source_id":"t1","operation":"additive_pct","amount":0.08} ]$j$::jsonb,
    '{"speed":1.0,"cargo_capacity":50}'::jsonb,
    v_reg);

  -- the deployed 0205:677 shape: greatest(0, round(a_combat, 2))
  if (v_out -> 'stats' ->> 'combat_power')::numeric
     is distinct from greatest(0, round((15 + 4 + 6)::numeric, 2)) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: combat_power is not the deployed additive fold (got %)', (v_out -> 'stats' ->> 'combat_power'); end if;
  -- the deployed 0205:662 shape:
  --   round(greatest(0.2, v_speed * (1 + mod + cap + trait + cmdbuff) * (1 - a_spd_pen)), 3)
  if (v_out -> 'stats' ->> 'speed')::numeric
     is distinct from round(greatest(0.2, 1.0 * (1 + 0.1 + 0.08) * (1 - 0)), 3) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: speed is not the deployed 0205:662 expression (got %)', (v_out -> 'stats' ->> 'speed'); end if;
  -- the deployed 0205:676 shape: greatest(0, v_ship.cargo_capacity + round(a_cargo)::integer). With
  -- the cargo quarantine there are no contributions, so it is the base, integer-emitted.
  if (v_out -> 'stats' ->> 'cargo_capacity')::numeric is distinct from 50 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: cargo_capacity is not the ship base (got %)', (v_out -> 'stats' ->> 'cargo_capacity'); end if;

  -- MODIFIER ORDER IS LOAD-BEARING, so it is proven, not asserted in prose. flat -> additive_pct ->
  -- multiplicative_pct -> clamp. base 10, +10 flat, +50% additive, then x(1-0.5):
  --   correct   ((10 + 10) * 1.5) * 0.5 = 15
  --   wrong (multiplicative before additive) ((10+10)*0.5)*1.5 = 15  -- commutes, so use a clamp to
  --   distinguish: clamp_max 18 applied at step 90 must bind AFTER the multiplications.
  v_out := public.stat_combine(
    $j$[ {"stat_id":"combat_power","source_kind":"hull",  "source_id":"h1","operation":"flat","amount":10},
         {"stat_id":"combat_power","source_kind":"module","source_id":"m1","operation":"additive_pct","amount":0.5},
         {"stat_id":"combat_power","source_kind":"module","source_id":"m2","operation":"multiplicative_pct","amount":-0.5},
         {"stat_id":"combat_power","source_kind":"module","source_id":"m3","operation":"clamp_max","amount":18} ]$j$::jsonb,
    '{"combat_power":10}'::jsonb, v_reg);
  -- ((10 + 10) * 1.5) * 0.5 = 15, then clamp_max 18 does not bind -> 15.
  if (v_out -> 'stats' ->> 'combat_power')::numeric is distinct from 15.00 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: modifier ORDER is wrong (want 15.00, got %)', (v_out -> 'stats' ->> 'combat_power'); end if;

  -- ADDITIVE-PCT SUMMING: eight +10% are +80%, never x2.14. This is the shipped speed semantics and
  -- getting it wrong is a live travel-speed change.
  v_out := public.stat_combine(
    $j$[ {"stat_id":"speed","source_kind":"module","source_id":"a","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed","source_kind":"module","source_id":"b","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed","source_kind":"module","source_id":"c","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed","source_kind":"module","source_id":"d","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed","source_kind":"module","source_id":"e","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed","source_kind":"module","source_id":"f","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed","source_kind":"module","source_id":"g","operation":"additive_pct","amount":0.1},
         {"stat_id":"speed","source_kind":"module","source_id":"h","operation":"additive_pct","amount":0.1} ]$j$::jsonb,
    '{"speed":1.0}'::jsonb, v_reg);
  if (v_out -> 'stats' ->> 'speed')::numeric is distinct from round(1.0 * (1 + 0.8), 3) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: additive_pct is not summed-then-applied-once (want 1.800, got %)', (v_out -> 'stats' ->> 'speed'); end if;

  -- THE BREAKDOWN RECONCILES EXACTLY TO THE FINAL RESULT. Provenance that does not add up is worse
  -- than no provenance: the last `running` value for a stat IS its emitted value.
  select (b.value ->> 'running')::numeric into v_x
    from jsonb_array_elements(v_out -> 'breakdown') with ordinality as b(value, ord)
   where b.value ->> 'stat_id' = 'speed' and b.value ->> 'running' is not null
   order by b.ord desc limit 1;
  if v_x is distinct from (v_out -> 'stats' ->> 'speed')::numeric then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the breakdown does not reconcile to the emitted stat (breakdown % vs stat %)', v_x, (v_out -> 'stats' ->> 'speed'); end if;

  -- JSON ROUND-TRIP STABILITY. 0339 was made red by a double precision value whose last bit moved
  -- crossing JSONB, flipping a boundary. numeric does not do that, and this proves it rather than
  -- assuming it: the value survives a jsonb round trip byte-identically.
  if (v_out -> 'stats') is distinct from ((v_out -> 'stats')::text::jsonb) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the stats object is not stable across a JSONB round trip'; end if;
  -- and resolving twice is byte-identical.
  if public.stat_combine('[{"stat_id":"combat_power","source_kind":"hull","source_id":"h","operation":"flat","amount":3.5}]'::jsonb, '{}'::jsonb, v_reg)
     is distinct from
     public.stat_combine('[{"stat_id":"combat_power","source_kind":"hull","source_id":"h","operation":"flat","amount":3.5}]'::jsonb, '{}'::jsonb, v_reg) then
    raise exception 'STAT-FOUNDATION self-assert FAIL: stat_combine is not deterministic across two identical calls'; end if;

  -- (8) THE FOLD FAILS CLOSED. Each of these MUST raise; if any returns, the fold is fabricating.
  begin
    v_out := public.stat_combine('[{"stat_id":"__no_such_stat__","source_kind":"hull","source_id":"h","operation":"flat","amount":1}]'::jsonb, '{}'::jsonb, v_reg);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an UNKNOWN stat_id was accepted by stat_combine';
  exception when others then
    if strpos(sqlerrm, 'unknown stat_id') = 0 then raise; end if;
  end;
  begin
    v_out := public.stat_combine('[{"stat_id":"combat_power","source_kind":"hull","source_id":"h","operation":"base_override","amount":1}]'::jsonb, '{}'::jsonb, v_reg);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an unpermitted OPERATION was accepted by stat_combine';
  exception when others then
    if strpos(sqlerrm, 'is not permitted for stat') = 0 then raise; end if;
  end;
  begin
    v_out := public.stat_combine('[{"stat_id":"cargo_capacity","source_kind":"module","source_id":"m","operation":"flat","amount":5}]'::jsonb, '{}'::jsonb, v_reg);
    raise exception 'STAT-FOUNDATION self-assert FAIL: a contribution reached the QUARANTINED cargo_capacity';
  exception when others then
    if strpos(sqlerrm, 'may not contribute') = 0 and strpos(sqlerrm, 'is not permitted for stat') = 0 then raise; end if;
  end;
  begin
    v_out := public.stat_combine('[{"stat_id":"combat_power","source_kind":"hull","source_id":"h","operation":"flat","amount":"12"}]'::jsonb, '{}'::jsonb, v_reg);
    raise exception 'STAT-FOUNDATION self-assert FAIL: a NON-NUMERIC amount was accepted by stat_combine';
  exception when others then
    if strpos(sqlerrm, 'not a JSON number') = 0 then raise; end if;
  end;
  begin
    v_out := public.stat_combine(
      '[{"stat_id":"combat_power","source_kind":"module","source_id":"m1","operation":"flat","amount":1},
        {"stat_id":"combat_power","source_kind":"module","source_id":"m1","operation":"flat","amount":1}]'::jsonb,
      '{}'::jsonb, v_reg);
    raise exception 'STAT-FOUNDATION self-assert FAIL: a DUPLICATE contribution identity was accepted by stat_combine';
  exception when others then
    if strpos(sqlerrm, 'duplicate contribution identity') = 0 then raise; end if;
  end;
  begin
    perform public.stat_raise_malformed('hull','starter_frigate','attack');
    raise exception 'STAT-FOUNDATION self-assert FAIL: stat_raise_malformed did not raise';
  exception when others then
    if strpos(sqlerrm, 'malformed contribution') = 0 then raise; end if;
  end;

  -- (9) FLEET AGGREGATION: every rule, and the explicit non-applicable result.
  --     EMPTY FLEET -> not_applicable, NEVER a silent 0.
  v_agg := public.stat_aggregate_fleet('[]'::jsonb, v_reg);
  if (v_agg ->> 'member_count')::integer <> 0 or (v_agg ->> 'applicable')::boolean then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an empty fleet did not report member_count 0 / applicable false'; end if;
  if v_agg -> 'stats' <> '{}'::jsonb then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an empty fleet produced stat VALUES (want none — an empty fleet is not a fleet of zeroes)'; end if;
  if v_agg -> 'not_applicable' -> 'combat_power' is null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an empty fleet did not report combat_power as explicitly not applicable'; end if;
  if (v_agg -> 'stats' ->> 'combat_power') is not null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an empty fleet reported a combat_power VALUE'; end if;
  if (v_agg -> 'provenance' -> 'combat_power' ->> 'status') <> 'not_applicable'
     or (v_agg -> 'provenance' -> 'combat_power' ->> 'reason') <> 'empty_fleet' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an empty fleet did not record combat_power provenance as not_applicable/empty_fleet'; end if;

  -- SINGLE-SHIP FLEET: every rule collapses to the member's own value.
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"resolved","stats":{"combat_power":12.00,"survival":3.00,"speed":1.500}}]'::jsonb, v_reg);
  if (v_agg -> 'stats' ->> 'combat_power')::numeric <> 12.00
     or (v_agg -> 'stats' ->> 'survival')::numeric <> 3.00
     or (v_agg -> 'stats' ->> 'speed')::numeric <> 1.500 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a single-ship fleet did not collapse to the member value'; end if;

  -- MULTI-SHIP FLEET, ROUTINE SCOPE: sum / sum / min, each per the stat's own declared rule.
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"resolved","stats":{"combat_power":10.00,"survival":9.00,"speed":2.000}},
      {"entity_id":"s2","status":"resolved","stats":{"combat_power":5.00, "survival":1.00,"speed":1.000}},
      {"entity_id":"s3","status":"resolved","stats":{"combat_power":2.00, "survival":4.00,"speed":3.000}}]'::jsonb, v_reg);
  if (v_agg -> 'stats' ->> 'combat_power')::numeric <> 17.00 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: combat_power did not SUM across the fleet (want 17.00, got %)', (v_agg -> 'stats' ->> 'combat_power'); end if;
  if (v_agg -> 'stats' ->> 'survival')::numeric <> 14.00 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: survival did not SUM across the fleet (want 14.00, got %)', (v_agg -> 'stats' ->> 'survival'); end if;
  if (v_agg -> 'stats' ->> 'speed')::numeric <> 1.000 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: fleet speed is not the MINIMUM effective speed (want 1.000, got %)', (v_agg -> 'stats' ->> 'speed'); end if;

  -- THE OWNER'S TWO AGGREGATION CORRECTIONS still hold — proven on the INSPECTION registry, because
  -- scouting and retreat_safety are dormant and are therefore not in the routine one at all. That is
  -- the point: the rules are preserved for the day they are promoted, and are unreachable until then.
  v_regi := public.stat_registry_snapshot('inspection');
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"resolved","stats":{"scouting":9.00,"retreat_safety":8.00}},
      {"entity_id":"s2","status":"resolved","stats":{"scouting":1.00,"retreat_safety":3.00}},
      {"entity_id":"s3","status":"resolved","stats":{"scouting":4.00,"retreat_safety":6.00}}]'::jsonb, v_regi);
  if (v_agg -> 'dormant' -> 'scouting' ->> 'value')::numeric <> 9.00 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: scouting did not take the MAX (want 9.00, got %)', (v_agg -> 'dormant' -> 'scouting' ->> 'value'); end if;
  if (v_agg -> 'dormant' -> 'retreat_safety' ->> 'value')::numeric <> 3.00 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: retreat_safety did not take the MIN (want 3.00, got %)', (v_agg -> 'dormant' -> 'retreat_safety' ->> 'value'); end if;
  -- ...and even under inspection they are NOT effective and NOT in `stats`.
  if (v_agg -> 'stats' ? 'scouting') or (v_agg -> 'stats' ? 'retreat_safety') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a dormant stat reached `stats` under inspection — dormant values must never be presentable as effective'; end if;
  if (v_agg -> 'dormant' -> 'scouting' ->> 'effective') <> 'false' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an inspected dormant stat is not marked effective=false'; end if;

  -- A fleet whose members report nothing is not a fleet of zeroes either.
  v_agg := public.stat_aggregate_fleet('[{"entity_id":"s1","status":"resolved","stats":{}},{"entity_id":"s2","status":"resolved","stats":{}}]'::jsonb, v_reg);
  if (v_agg -> 'stats' ->> 'combat_power') is not null
     or v_agg -> 'not_applicable' -> 'combat_power' is null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an ineligible fleet produced a value instead of an explicit non-applicable result'; end if;
  if (v_agg -> 'provenance' -> 'combat_power' ->> 'reason') <> 'no_eligible_member' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an ineligible fleet did not distinguish no_eligible_member from empty_fleet'; end if;

  -- (10) PROGRESSION: the deployed curve, its exact boundaries, its inverse, and the cap.
  --      The right-hand side is 0177:270 transcribed. If the deployed curve ever changes, this fails.
  foreach v_n in array array[0, 99, 100, 101, 399, 400, 401, 899, 900, 1000000] loop
    if public.progression_level_for_xp('captain_v1', v_n::numeric)
       is distinct from least(99, 1 + floor(sqrt(v_n::numeric / 100.0))::integer) then
      raise exception 'STAT-FOUNDATION self-assert FAIL: progression_level_for_xp(%) is not the deployed 0177:270 curve (got %, want %)',
        v_n, public.progression_level_for_xp('captain_v1', v_n::numeric), least(99, 1 + floor(sqrt(v_n::numeric / 100.0))::integer); end if;
  end loop;
  -- EXACT THRESHOLD BOUNDARIES: level L begins at (L-1)^2 * 100, and one xp below it is L-1.
  for v_n in 2 .. 99 loop
    if public.progression_level_for_xp('captain_v1', ((v_n - 1) * (v_n - 1) * 100)::numeric) <> v_n then
      raise exception 'STAT-FOUNDATION self-assert FAIL: level % does not begin exactly at its threshold', v_n; end if;
    if public.progression_level_for_xp('captain_v1', ((v_n - 1) * (v_n - 1) * 100 - 1)::numeric) <> v_n - 1 then
      raise exception 'STAT-FOUNDATION self-assert FAIL: one xp below level %''s threshold is not level %', v_n, v_n - 1; end if;
    -- and the two functions are exact inverses.
    if public.progression_xp_for_level('captain_v1', v_n) <> ((v_n - 1) * (v_n - 1) * 100)::numeric then
      raise exception 'STAT-FOUNDATION self-assert FAIL: progression_xp_for_level(%) is not (L-1)^2 * 100', v_n; end if;
  end loop;
  -- THE CAP: level 99 is reached exactly at its threshold and NEVER exceeded, however much xp
  -- accumulates. XP stays authoritative; the LEVEL stops.
  if public.progression_level_for_xp('captain_v1', 960400::numeric) <> 99 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: 960400 xp is not exactly level 99'; end if;
  if public.progression_level_for_xp('captain_v1', 960399::numeric) <> 98 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: one xp below the level-99 threshold is not level 98'; end if;
  if public.progression_level_for_xp('captain_v1', 99999999::numeric) <> 99 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: post-cap XP produced a level above the cap'; end if;
  begin
    v_n := public.progression_level_for_xp('__no_such_track__', 100);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an unknown progression track was accepted';
  exception when others then
    if strpos(sqlerrm, 'unknown or inactive progression track') = 0 then raise; end if;
  end;
  begin
    v_n := public.progression_level_for_xp('captain_v1', -1);
    raise exception 'STAT-FOUNDATION self-assert FAIL: negative xp was accepted';
  exception when others then
    if strpos(sqlerrm, 'non-negative') = 0 then raise; end if;
  end;

  -- (11) BUFF STACKING: expiry, and EVERY registered policy, on synthetic instances. Reads no table.
  v_stk := public.buff_apply_stacking(
    $b$[{"buff_instance_id":"i1","buff_def_id":"d1","stat_id":"combat_power","operation":"flat",
         "magnitude":3,"stacking_group":"g1","stacking_policy":"stack_all","evaluation_order":100,
         "granted_at":"2026-01-01T00:00:00+00:00","starts_at":"2026-01-01T00:00:00+00:00","expires_at":"2026-01-02T00:00:00+00:00"},
        {"buff_instance_id":"i2","buff_def_id":"d1","stat_id":"combat_power","operation":"flat",
         "magnitude":5,"stacking_group":"g1","stacking_policy":"stack_all","evaluation_order":100,
         "granted_at":"2026-01-01T00:00:00+00:00","starts_at":"2026-01-01T00:00:00+00:00","expires_at":null}]$b$::jsonb,
    v_reg, '2026-06-01T00:00:00+00:00'::timestamptz);
  -- i1 EXPIRED long before the resolution time and must be suppressed with its reason.
  if jsonb_array_length(v_stk -> 'buffs') <> 1
     or (v_stk -> 'buffs' -> 0 ->> 'buff_instance_id') <> 'i2' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an EXPIRED buff was not filtered out'; end if;
  if jsonb_array_length(v_stk -> 'suppressed') <> 1
     or (v_stk -> 'suppressed' -> 0 ->> 'suppressed_by') <> 'expired' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the expired buff was not reported with its reason'; end if;

  -- stack_all keeps both; highest_magnitude / latest_only / longest_remaining / first_only keep one.
  foreach v_role in array array['stack_all','highest_magnitude','latest_only','longest_remaining','first_only'] loop
    v_stk := public.buff_apply_stacking(
      replace($b$[{"buff_instance_id":"i1","buff_def_id":"d1","stat_id":"combat_power","operation":"flat",
           "magnitude":3,"stacking_group":"g1","stacking_policy":"POLICY","evaluation_order":100,
           "granted_at":"2026-01-01T00:00:00+00:00","starts_at":"2026-01-01T00:00:00+00:00","expires_at":"2026-12-01T00:00:00+00:00"},
          {"buff_instance_id":"i2","buff_def_id":"d2","stat_id":"combat_power","operation":"flat",
           "magnitude":9,"stacking_group":"g1","stacking_policy":"POLICY","evaluation_order":100,
           "granted_at":"2026-02-01T00:00:00+00:00","starts_at":"2026-02-01T00:00:00+00:00","expires_at":null}]$b$, 'POLICY', v_role)::jsonb,
      v_reg, '2026-06-01T00:00:00+00:00'::timestamptz);
    if v_role = 'stack_all' then
      if jsonb_array_length(v_stk -> 'buffs') <> 2 then
        raise exception 'STAT-FOUNDATION self-assert FAIL: stack_all did not keep both instances'; end if;
    else
      if jsonb_array_length(v_stk -> 'buffs') <> 1 then
        raise exception 'STAT-FOUNDATION self-assert FAIL: stacking policy % did not reduce the group to one instance', v_role; end if;
      if (v_stk -> 'suppressed' -> 0 ->> 'suppressed_by') <> v_role then
        raise exception 'STAT-FOUNDATION self-assert FAIL: stacking policy % did not report itself as the suppression reason', v_role; end if;
    end if;
    -- the specific winner each policy must pick
    if v_role = 'highest_magnitude' and (v_stk -> 'buffs' -> 0 ->> 'buff_instance_id') <> 'i2' then
      raise exception 'STAT-FOUNDATION self-assert FAIL: highest_magnitude picked the smaller magnitude'; end if;
    if v_role = 'latest_only' and (v_stk -> 'buffs' -> 0 ->> 'buff_instance_id') <> 'i2' then
      raise exception 'STAT-FOUNDATION self-assert FAIL: latest_only did not pick the latest granted_at'; end if;
    if v_role = 'longest_remaining' and (v_stk -> 'buffs' -> 0 ->> 'buff_instance_id') <> 'i2' then
      raise exception 'STAT-FOUNDATION self-assert FAIL: longest_remaining did not treat a null expiry as the longest'; end if;
    if v_role = 'first_only' and (v_stk -> 'buffs' -> 0 ->> 'buff_instance_id') <> 'i1' then
      raise exception 'STAT-FOUNDATION self-assert FAIL: first_only did not pick the earliest granted_at'; end if;
  end loop;

  -- SAME-SOURCE REPLACEMENT: two instances of the SAME definition from the SAME source cannot both
  -- exist (the unique key), and where they can (different sources) a non-stack_all policy replaces.
  if not exists (select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
                  where t.relname = 'buff_instances' and c.contype = 'u') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: buff_instances has no unique (def, scope, target, source) key — the same source could grant twice'; end if;

  -- AN INVALID BUFF WINDOW RAISES rather than resolving to "never active".
  begin
    v_stk := public.buff_apply_stacking(
      $b$[{"buff_instance_id":"i9","buff_def_id":"d1","stat_id":"combat_power","operation":"flat","magnitude":1,
           "stacking_group":"g","stacking_policy":"stack_all","evaluation_order":1,
           "granted_at":"2026-01-01T00:00:00+00:00","starts_at":"2026-05-01T00:00:00+00:00","expires_at":"2026-01-01T00:00:00+00:00"}]$b$::jsonb,
      v_reg, '2026-06-01T00:00:00+00:00'::timestamptz);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an INVALID buff window was accepted';
  exception when others then
    if strpos(sqlerrm, 'invalid window') = 0 then raise; end if;
  end;
  -- AN UNKNOWN STAT on a buff instance raises.
  begin
    v_stk := public.buff_apply_stacking(
      $b$[{"buff_instance_id":"i9","buff_def_id":"d1","stat_id":"__no_such_stat__","operation":"flat","magnitude":1,
           "stacking_group":"g","stacking_policy":"stack_all","evaluation_order":1,
           "granted_at":"2026-01-01T00:00:00+00:00","starts_at":"2026-01-01T00:00:00+00:00","expires_at":null}]$b$::jsonb,
      v_reg, '2026-06-01T00:00:00+00:00'::timestamptz);
    raise exception 'STAT-FOUNDATION self-assert FAIL: a buff targeting an UNKNOWN stat was accepted';
  exception when others then
    if strpos(sqlerrm, 'unknown stat') = 0 then raise; end if;
  end;

  -- (12) NO STORED EXPRESSION. Every seeded context_restriction value is a scalar or an array of
  --      scalars — walked row by row, with a cardinality guard so an empty walk cannot pass.
  -- The guard is DERIVED from the catalog, never a hard-coded floor. The seed is now filtered to
  -- ACTIVE stats, so a literal "at least 20" was a stale number that failed the moment the lifecycle
  -- ruling landed — caught by the disposable full-chain apply, which is the only layer that has
  -- rows to count. What must hold is: the catalog exists, the seed matches what the catalog implies,
  -- and the walk is not empty.
  select count(*) into v_bad from public.command_buff_types;
  if v_bad < 1 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: command_buff_types is empty — the buff seed and this walk would both be vacuous'; end if;
  select count(*) into v_bad
    from public.command_buff_types cbt
    join public.stat_definitions d on cbt.stats_json ? d.catalog_key
   where jsonb_typeof(cbt.stats_json -> d.catalog_key) = 'number'
     and d.lifecycle = 'active' and 'command_ship' = any (d.permitted_source_kinds);
  select count(*) into v_n from public.buff_definitions;
  if v_n <> v_bad or v_n < 1 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: buff_definitions holds % row(s) but the catalog implies % (buff, ACTIVE stat) pair(s) — the walk would be vacuous or the seed has drifted', v_n, v_bad; end if;
  -- ...and the LIFECYCLE FILTER really filtered: the catalog carries (buff, stat) pairs on non-active
  -- stats, and none of them was seeded. Without this, "11 = 11" would also pass if the filter were
  -- removed and the registry happened to hold no dormant stat.
  select count(*) into v_bad
    from public.command_buff_types cbt
    join public.stat_definitions d on cbt.stats_json ? d.catalog_key
   where jsonb_typeof(cbt.stats_json -> d.catalog_key) = 'number'
     and d.lifecycle <> 'active';
  if v_bad < 1 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the catalog names no non-active stat, so the buff seed''s lifecycle filter is unexercised and this proof is vacuous'; end if;
  if exists (select 1 from public.buff_definitions b
               join public.stat_definitions d on d.stat_id = b.stat_id
              where d.lifecycle <> 'active') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a command buff on a non-active stat was seeded anyway'; end if;
  select count(*) into v_bad
    from public.buff_definitions bd,
         lateral jsonb_each(bd.context_restriction) e(k, v)
   where jsonb_typeof(e.v) not in ('string','number','boolean')
     and not (jsonb_typeof(e.v) = 'array'
              and not exists (select 1 from jsonb_array_elements(e.v) x
                               where jsonb_typeof(x) not in ('string','number','boolean')));
  if v_bad <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % buff_definitions context_restriction value(s) are not scalar-or-array-of-scalars', v_bad; end if;
  -- and every seeded buff magnitude matches the catalog row it was derived from.
  select count(*) into v_bad
    from public.buff_definitions bd
    join public.stat_definitions d on d.stat_id = bd.stat_id
    join public.command_buff_types cbt on bd.buff_def_id = cbt.buff_id || ':' || d.stat_id
   where bd.magnitude is distinct from (cbt.stats_json ->> d.catalog_key)::numeric;
  if v_bad <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % seeded buff definition(s) disagree with command_buff_types', v_bad; end if;
  -- the speed buffs map to additive_pct (the 0205:662 semantics), everything else to flat.
  select count(*) into v_bad from public.buff_definitions
   where (stat_id = 'speed' and operation <> 'additive_pct')
      or (stat_id <> 'speed' and operation <> 'flat');
  if v_bad <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % buff definition(s) carry the wrong operation mapping', v_bad; end if;

  -- (12b) LIFECYCLE, EXECUTED: A DORMANT STAT IS NOT COMPUTED ON THE ROUTINE PATH.
  --       Not "is filtered from the output" — NOT COMPUTED. The routine snapshot does not contain
  --       it, so the fold has no vocabulary entry to fold, the gatherers' snapshot-membership joins
  --       match nothing, and a contribution aimed at it is REJECTED as an unknown stat.
  v_regi := public.stat_registry_snapshot('inspection');
  if (v_reg -> 'stats') ? 'pirate_attention' or (v_reg -> 'stats') ? 'scouting'
     or (v_reg -> 'stats') ? 'mining_yield' or (v_reg -> 'stats') ? 'retreat_safety'
     or (v_reg -> 'stats') ? 'repair' or (v_reg -> 'stats') ? 'cargo_volume_m3' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a DORMANT stat is present in the ROUTINE registry snapshot'; end if;
  select count(*) into v_n from jsonb_object_keys(v_reg -> 'stats');
  if v_n <> 4 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the routine snapshot holds % stat(s), want exactly 4 (combat_power, survival, speed, cargo_capacity)', v_n; end if;
  select count(*) into v_n from jsonb_object_keys(v_regi -> 'stats');
  if v_n <> 10 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the inspection snapshot holds % stat(s), want exactly 10', v_n; end if;
  -- The routine fold EMITS no dormant key at all...
  v_out := public.stat_combine('[]'::jsonb, '{}'::jsonb, v_reg);
  if (v_out -> 'stats') ? 'pirate_attention' or (v_out -> 'dormant') <> '{}'::jsonb then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a routine fold produced a dormant key'; end if;
  -- ...and REFUSES a contribution aimed at one, rather than silently ignoring it. Silently ignoring
  -- would let a caller believe a dormant stat was applied.
  begin
    v_out := public.stat_combine(
      '[{"stat_id":"pirate_attention","source_kind":"module","source_id":"m","operation":"flat","amount":5}]'::jsonb,
      '{}'::jsonb, v_reg);
    raise exception 'STAT-FOUNDATION self-assert FAIL: a contribution to a DORMANT stat was accepted on the routine path';
  exception when others then
    if position('unknown stat_id' in sqlerrm) = 0 then raise; end if;
  end;
  -- An unknown lifecycle scope is refused; there is no permissive fallback.
  begin
    v_out := public.stat_registry_snapshot('everything');
    raise exception 'STAT-FOUNDATION self-assert FAIL: an unknown lifecycle scope was accepted';
  exception when others then
    if position('unknown lifecycle scope' in sqlerrm) = 0 then raise; end if;
  end;
  -- The lifecycle rule itself, at every combination, in the one function that owns it.
  if public.stat_lifecycle_in_scope('dormant','routine')
     or not public.stat_lifecycle_in_scope('dormant','inspection')
     or not public.stat_lifecycle_in_scope('active','routine')
     or not public.stat_lifecycle_in_scope('deprecated','routine')
     or public.stat_lifecycle_in_scope('active','nonsense')
     or public.stat_lifecycle_in_scope('made_up','inspection') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: stat_lifecycle_in_scope does not implement the lifecycle rule (an unknown lifecycle must be in NO scope)'; end if;

  -- (12c) THREE-WAY PROVENANCE, EXECUTED: a REAL ZERO, a RESOLUTION FAILURE and a NOT-APPLICABLE are
  --       mutually distinguishable in ONE result. A structure in which all three read `0` is the
  --       defect being eliminated, so all three are produced here and compared.
  --
  --       s1 resolves with combat_power = 0 (a real zero) and reports no speed (not applicable),
  --       and there is no failed member, so `unresolved` is empty. Then the same roster WITH a
  --       failed member is aggregated, and the same stat that was a real zero becomes unresolved.
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"resolved","stats":{"combat_power":0.00,"survival":4.00}}]'::jsonb, v_reg);
  -- (i) A REAL ZERO is a RESOLVED value: it is in `stats`, it IS 0, and it says it is a real zero.
  if (v_agg -> 'stats' ->> 'combat_power')::numeric <> 0
     or (v_agg -> 'provenance' -> 'combat_power' ->> 'status') <> 'resolved'
     or (v_agg -> 'provenance' -> 'combat_power' ->> 'is_real_zero') <> 'true' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a real zero is not recorded as a RESOLVED value'; end if;
  -- (ii) NOT APPLICABLE is not a zero: no key in `stats`, a reason in `not_applicable`.
  if (v_agg -> 'stats' ? 'speed')
     or (v_agg -> 'provenance' -> 'speed' ->> 'status') <> 'not_applicable' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a not-applicable stat leaked a value'; end if;
  if v_agg -> 'unresolved' <> '{}'::jsonb then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a clean aggregation reported unresolved stats'; end if;
  -- (iii) A RESOLUTION FAILURE is neither: no value, a NAMED failure, and the failing member listed.
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"resolved","stats":{"combat_power":0.00,"survival":4.00}},
      {"entity_id":"s2","status":"unresolved","failure":{"reason":"ship_resolution_raised","failed_resolver":"resolve_effective_stats(ship)","detail":"malformed module stats_json"}}]'::jsonb,
    v_reg);
  if (v_agg -> 'stats' ? 'combat_power') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an aggregate was produced over a roster containing an UNRESOLVED member'; end if;
  if (v_agg -> 'provenance' -> 'combat_power' ->> 'status') <> 'unresolved'
     or (v_agg -> 'unresolved' -> 'combat_power' ->> 'reason') <> 'member_resolution_failed' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a member resolution failure did not become an UNRESOLVED stat'; end if;
  if (v_agg -> 'unresolved' -> 'combat_power' -> 'failed_members' -> 0 -> 'failure' ->> 'failed_resolver')
       is distinct from 'resolve_effective_stats(ship)' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the unresolved diagnostic does not name the failing resolver'; end if;
  -- THE THREE ARE DIFFERENT SHAPES, not three spellings of 0. Proven by asking for the number: only
  -- the real zero yields one.
  if jsonb_typeof(v_agg -> 'unresolved' -> 'combat_power') = 'number' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an unresolved stat is expressible as a number'; end if;
  -- A member that does not declare its status is a FAILURE, never a resolved empty ship.
  v_agg := public.stat_aggregate_fleet('[{"entity_id":"s9","stats":{"combat_power":3}}]'::jsonb, v_reg);
  if (v_agg -> 'provenance' -> 'combat_power' ->> 'status') <> 'unresolved' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a member with no status was treated as resolved'; end if;
  -- And the partition law itself refuses a collapsed result. This is the assert that would catch a
  -- future edit putting a stat in two maps.
  begin
    perform public.stat_assert_provenance_partition(
      '{"stats":{"a":1},"not_applicable":{"a":"x"},"unresolved":{},"dormant":{},"provenance":{"a":{"status":"resolved"}}}'::jsonb,
      'probe');
    raise exception 'STAT-FOUNDATION self-assert FAIL: the provenance partition law accepted a stat that is in TWO maps';
  exception when others then
    if position('more than one provenance map' in sqlerrm) = 0 then raise; end if;
  end;

  -- (12d) THE AMBUSH IMPOSSIBILITY PIN. A stat-resolution failure CANNOT become a numeric risk value.
  --       Live evidence this replaces: pirate_intercept_plan_leg sets v_combined := 0 on any raise
  --       (0301:545-547) and 0233:345-354 turns 0 into the system's MAXIMUM risk, so a broken stat
  --       graph and a genuinely weak fleet produce the same gameplay value.
  --
  --       SUCCESS PATH: the required stats resolve, and the number comes out.
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"resolved","stats":{"combat_power":40.00,"survival":20.00}}]'::jsonb, v_reg);
  v_env := public.stat_require_resolved(v_agg, array['combat_power','survival'], 'pirate_intercept_plan_leg');
  if (v_env ->> 'ok') <> 'true' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a fully resolved fleet was refused by the consumer contract'; end if;
  if public.stat_required_sum(v_env) <> 60.00 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the consumer contract did not sum combat_power + survival (want 60.00)'; end if;
  --       A GENUINELY WEAK FLEET still produces a NUMBER — zero. That is the distinction the live
  --       consumer cannot make, and it is made here.
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"resolved","stats":{"combat_power":0.00,"survival":0.00}}]'::jsonb, v_reg);
  v_env := public.stat_require_resolved(v_agg, array['combat_power','survival'], 'pirate_intercept_plan_leg');
  if (v_env ->> 'ok') <> 'true' or public.stat_required_sum(v_env) <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a genuinely weak (real zero) fleet was not resolvable to 0'; end if;
  --       FAILURE PATH, SHAPE 1 — a member could not be resolved.
  v_agg := public.stat_aggregate_fleet(
    '[{"entity_id":"s1","status":"unresolved","failure":{"reason":"ship_resolution_raised"}}]'::jsonb, v_reg);
  v_env := public.stat_require_resolved(v_agg, array['combat_power','survival'], 'pirate_intercept_plan_leg');
  if (v_env ->> 'ok') <> 'false' or (v_env ->> 'error') <> 'stat_resolution_failed' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an unresolved fleet did not produce an actionable refusal'; end if;
  if v_env ? 'values' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a REFUSAL carried a values object — there must be nothing to read optimistically'; end if;
  select count(*) into v_n from jsonb_each(v_env) e where jsonb_typeof(e.value) = 'number';
  if v_n <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: a stat-resolution refusal carries % top-level number(s) — a failure must not be expressible as a value', v_n; end if;
  if (v_env -> 'diagnostic' ->> 'consumer') <> 'pirate_intercept_plan_leg'
     or jsonb_array_length(v_env -> 'diagnostic' -> 'failed_stats') <> 2 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the refusal diagnostic does not name the consumer and the failing stats'; end if;
  -- THE IMPOSSIBILITY ITSELF: the ONLY numeric extractor REFUSES the failure envelope. There is no
  -- second door, so no failure can reach the risk formula as a number — not as 0, not as anything.
  begin
    v_num := public.stat_required_sum(v_env);
    raise exception 'STAT-FOUNDATION self-assert FAIL: a stat-resolution FAILURE produced the numeric value % — this is exactly the 0301:545-547 fail-open defect', v_num;
  exception when others then
    if position('refusing to produce a number from a failed stat resolution' in sqlerrm) = 0 then raise; end if;
  end;
  --       FAILURE PATH, SHAPE 2 — the fleet is empty, so the stats are NOT APPLICABLE. Also a
  --       refusal, and a DIFFERENT one: "no ships" is not "we could not read the ships".
  v_agg := public.stat_aggregate_fleet('[]'::jsonb, v_reg);
  v_env := public.stat_require_resolved(v_agg, array['combat_power','survival'], 'pirate_intercept_plan_leg');
  if (v_env ->> 'ok') <> 'false' or v_env ? 'values' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an empty fleet was not refused by the consumer contract'; end if;
  if (v_env -> 'diagnostic' -> 'failed_stats' -> 0 ->> 'status') <> 'not_applicable' then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the refusal collapsed not_applicable into unresolved — the two must stay distinguishable'; end if;
  begin
    v_num := public.stat_required_sum(v_env);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an empty fleet produced the numeric risk input %', v_num;
  exception when others then
    if position('refusing to produce a number from a failed stat resolution' in sqlerrm) = 0 then raise; end if;
  end;
  --       FAILURE PATH, SHAPE 3 — a hand-made envelope claiming ok with no values is still refused.
  --       Both shapes: values ABSENT, and values present but not an object.
  begin
    v_num := public.stat_required_sum('{"ok":true}'::jsonb);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an envelope claiming ok with no values produced %', v_num;
  exception when others then
    if position('carries no values object' in sqlerrm) = 0 then raise; end if;
  end;
  begin
    v_num := public.stat_required_sum('{"ok":true,"values":7}'::jsonb);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an envelope whose values is a NUMBER produced %', v_num;
  exception when others then
    if position('carries no values object' in sqlerrm) = 0 then raise; end if;
  end;
  begin
    v_num := public.stat_required_sum('{"ok":true,"values":{}}'::jsonb);
    raise exception 'STAT-FOUNDATION self-assert FAIL: an EMPTY values object produced %', v_num;
  exception when others then
    if position('no stats to sum' in sqlerrm) = 0 then raise; end if;
  end;
  --       AND THE LIVE CONSUMER IS UNTOUCHED. This slice designs the replacement; it does not repair
  --       pirate_intercept_plan_leg. If a later edit "helpfully" fixes it here, this fails.
  select prosrc into v_plan from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'pirate_intercept_plan_leg';
  if v_plan is null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: pirate_intercept_plan_leg is missing — this slice asserts it is UNCHANGED, not absent'; end if;
  if strpos(v_plan, 'v_combined := 0;') = 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the 0301:545-547 fail-open handler is gone — repairing the live ambush consumer is OUT OF SCOPE for this slice'; end if;
  if strpos(v_plan, 'stat_require_resolved') > 0 or strpos(v_plan, 'resolve_effective_stats') > 0
     or strpos(v_plan, 'stat_required_sum') > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: pirate_intercept_plan_leg carries a 0340 token — the consumer cutover is a separate, bounded sequence'; end if;

  -- (13) BLAST RADIUS. The out-of-scope engine bodies EXIST and carry ZERO token from this slice.
  --      This is the proof that the slice is dark: nothing calls it because nothing mentions it.
  select prosrc into v_ces  from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='calculate_expedition_stats';
  select prosrc into v_cges from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='calculate_group_expedition_stats';
  select prosrc into v_ccge from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='combat_create_group_encounter';
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='process_combat_ticks';
  select prosrc into v_rfms from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='resolve_fleet_movement_speed';
  if v_ces is null or v_cges is null or v_ccge is null or v_tick is null then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an out-of-scope engine function is missing'; end if;
  if strpos(v_ces, 'resolve_effective_stats') > 0 or strpos(v_ces, 'stat_definitions') > 0
     or strpos(v_cges, 'resolve_effective_stats') > 0 or strpos(v_cges, 'stat_aggregate_fleet') > 0
     or strpos(v_ccge, 'resolve_effective_stats') > 0 or strpos(v_ccge, 'stat_definitions') > 0
     or strpos(v_tick, 'resolve_effective_stats') > 0 or strpos(v_tick, 'stat_definitions') > 0
     or strpos(v_tick, 'buff_instances') > 0
     or coalesce(strpos(v_rfms, 'resolve_effective_stats'), 0) > 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: an out-of-scope engine function carries a 0340 token — this slice is NOT dark'; end if;
  -- The deployed fold's byte-identity anchors survive: this migration did not slice them.
  if strpos(v_ces, 'v_final_speed := round(greatest(0.2, v_speed * (1 + v_mod_speed_bonus + v_cap_speed_bonus + v_trait_speed_bonus + v_cmdbuff_speed_bonus) * (1 - a_spd_pen)), 3);') = 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the deployed 0205:662 speed expression is gone (byte-identity breach)'; end if;
  if strpos(v_cges, 'v_min_speed := least(v_min_speed, (v_stats->>''speed'')::numeric);') = 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the deployed fleet min-speed line is gone (byte-identity breach)'; end if;
  -- The malformed-ship concealment handler at 0301:804-806 is EXPLICITLY out of scope and must
  -- still be exactly where it was: this slice does not get to quietly change combat's failure mode.
  if strpos(v_ccge, 'v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;') = 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: the 0301 malformed-ship handler changed — it is out of scope for this slice'; end if;

  -- (14) ACL / GRANT POSTURE. Establish-then-verify: the grants were REVOKED above (never merely
  --      asserted absent — a Supabase project-default GRANT ALL aborted migration 0254 on exactly
  --      this), and here we prove the result.
  foreach v_role in array array['anon','authenticated'] loop
    foreach v_fn in array array['stat_definitions','progression_curves','progression_tracks','buff_definitions','buff_instances'] loop
      foreach v_priv in array array['INSERT','UPDATE','DELETE'] loop
        if has_table_privilege(v_role, 'public.' || v_fn, v_priv) then
          raise exception 'STAT-FOUNDATION self-assert FAIL: % holds % on % (every new table is read-only to clients)', v_role, v_priv, v_fn; end if;
      end loop;
      if not has_table_privilege(v_role, 'public.' || v_fn, 'SELECT') then
        raise exception 'STAT-FOUNDATION self-assert FAIL: % cannot SELECT % (the registry must be readable)', v_role, v_fn; end if;
    end loop;
    if not (select relrowsecurity from pg_class where oid = ('public.' || 'stat_definitions')::regclass) then
      raise exception 'STAT-FOUNDATION self-assert FAIL: RLS is not enabled on stat_definitions'; end if;
  end loop;
  foreach v_role in array array['anon','authenticated','public'] loop
    if has_function_privilege(v_role, 'public.resolve_effective_stats(text,uuid,jsonb,timestamptz,text)', 'execute')
       or has_function_privilege(v_role, 'public.resolve_active_buffs(text,uuid,jsonb,timestamptz)', 'execute')
       or has_function_privilege(v_role, 'public.resolve_progression(text,uuid,timestamptz)', 'execute')
       or has_function_privilege(v_role, 'public.stat_combine(jsonb,jsonb,jsonb)', 'execute')
       or has_function_privilege(v_role, 'public.stat_aggregate_fleet(jsonb,jsonb)', 'execute')
       or has_function_privilege(v_role, 'public.buff_apply_stacking(jsonb,jsonb,timestamptz)', 'execute')
       or has_function_privilege(v_role, 'public.progression_level_for_xp(text,numeric)', 'execute')
       or has_function_privilege(v_role, 'public.progression_xp_for_level(text,integer)', 'execute')
       or has_function_privilege(v_role, 'public.buff_grant(text,text,uuid,uuid,timestamptz,timestamptz,numeric)', 'execute')
       or has_function_privilege(v_role, 'public.stat_require_resolved(jsonb,text[],text)', 'execute')
       or has_function_privilege(v_role, 'public.stat_required_sum(jsonb,text[])', 'execute')
       or has_function_privilege(v_role, 'public.stat_registry_snapshot(text)', 'execute')
       or has_function_privilege(v_role, 'public.buff_revoke(uuid)', 'execute') then
      raise exception 'STAT-FOUNDATION self-assert FAIL: role % can EXECUTE a 0340 ENGINE function — the arithmetic leaves and the buff writers are server-only', v_role; end if;
  end loop;
  -- THE INSPECTION RPCs MUST BE REACHABLE. This is the assert that would have caught the earlier
  -- draft's mistake: a foundation the owner cannot call is a foundation the owner cannot check.
  if not has_function_privilege('authenticated', 'public.get_stat_definitions()', 'execute') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: authenticated cannot EXECUTE get_stat_definitions — the registry must be inspectable'; end if;
  if not has_function_privilege('authenticated', 'public.get_my_effective_stats(text,uuid,jsonb,jsonb)', 'execute') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: authenticated cannot EXECUTE get_my_effective_stats — the resolver must be inspectable by its owner'; end if;
  -- ...but not by anon, and the ownership scope must actually be in the body.
  if has_function_privilege('anon', 'public.get_my_effective_stats(text,uuid,jsonb,jsonb)', 'execute') then
    raise exception 'STAT-FOUNDATION self-assert FAIL: anon can EXECUTE get_my_effective_stats'; end if;
  if strpos((select prosrc from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
              where ns.nspname='public' and p.proname='get_my_effective_stats'), 'auth.uid()') = 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: get_my_effective_stats does not scope on auth.uid() — inspectable must never mean readable across players'; end if;
  -- Every read resolver is stable, never volatile; the two writers are the ONLY volatile functions.
  select count(*) into v_bad from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public'
     and p.proname in ('resolve_effective_stats','resolve_active_buffs','resolve_progression',
                       'buff_derive_source_instances','stat_registry_snapshot','buff_apply_stacking')
     and p.provolatile = 'v';
  if v_bad <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % read resolver(s) are VOLATILE — a read resolver must be stable', v_bad; end if;
  select count(*) into v_bad from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public'
     and p.proname in ('resolve_effective_stats','resolve_active_buffs','resolve_progression',
                       'buff_derive_source_instances','stat_registry_snapshot','buff_grant','buff_revoke',
                       'get_stat_definitions','get_my_effective_stats')
     and p.proconfig is null;
  if v_bad <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % security-definer function(s) have no fixed search_path', v_bad; end if;

  -- (15) THE PROGRESSION AUTHORITY AGREES WITH EVERY LIVE ROW. Data-dependent, so it is NOT the
  --      load-bearing check (checks 10 above are, and they are synthetic and non-vacuous). This one
  --      adds a production integrity statement without which the later column retirement is blind.
  select count(*) into v_bad from public.captain_instances ci
   where ci.level is distinct from least(99, 1 + floor(sqrt(ci.xp / 100.0))::integer);
  if v_bad <> 0 then
    raise exception 'STAT-FOUNDATION self-assert FAIL: % captain_instances row(s) have a cached level that disagrees with the curve', v_bad; end if;

  raise notice 'STAT-FOUNDATION self-assert ok: NO feature flag introduced (asserted absent — an inert gate is not a safety device); the two inspection RPCs get_stat_definitions / get_my_effective_stats are executable by authenticated, NOT by anon, and get_my_effective_stats scopes on auth.uid(); 10 stat_definitions (3 active / 1 deprecated / 6 dormant) / 1 progression_curve / 1 progression_track / % buff_definitions seeded, buff_instances empty; the five confirmed-dead outputs (retreat_safety, scouting, mining_yield, repair, pirate_attention) are DORMANT and absent from the routine snapshot, so they are not computed on any routine path and a contribution to one is REJECTED; the routine snapshot holds exactly 4 stats and the inspection snapshot exactly 10; three-way provenance proven — a real zero, a member-resolution failure and a not-applicable are three different shapes and the four maps partition the key set; the ambush impossibility pin holds — stat_required_sum REFUSES every failure envelope, so no stat-resolution failure can become a numeric risk value, and pirate_intercept_plan_leg is asserted UNCHANGED (its 0301:545-547 fail-open handler still present, zero 0340 tokens); cargo re-ruled — cargo_capacity is DEPRECATED and non-authoritative, cargo_volume_m3 is the DORMANT canonical m3 target superseding it with an UNDEFINED conversion that the table makes structurally inert; scouting=max, retreat_safety=min, fleet speed=min, speed floor 0.2; captain_v1 capped at 99 with accumulate_xp_no_level; ELEVEN fail-closed registry probes were REJECTED by the table (including an OMITTED lifecycle, an unknown lifecycle value, an active stat with no consumer, a dormant stat with a consumer, a deprecated stat with a gameplay consumer, a superseding stat accepting a contribution while its unit conversion is undefined, and a permitted source that was never declared intended); the pure leaves carry zero RNG/clock tokens, no table reference, no write and no dynamic SQL, and the buff family never calls the stat resolver (acyclic); the deploy-time equivalence checks reproduce 0205:662 / :676 / :677 and 0177:270 on synthetic input reading no game row; modifier ORDER, additive-pct summing, breakdown reconciliation, JSONB round-trip stability and repeat determinism all proven; unknown stat / unpermitted operation / quarantined stat / non-numeric amount / duplicate contribution identity / unknown track / negative xp / invalid buff window / unknown buff stat ALL rejected; empty, single-ship, multi-ship and ineligible fleets aggregate per declared rule with an explicit non-applicable result and never a silent 0; all five stacking policies proven with their reasons; every 0340 table is RLS-on and read-only to clients and every 0340 function is server-only; calculate_expedition_stats / calculate_group_expedition_stats / combat_create_group_encounter / process_combat_ticks carry ZERO 0340 token and their byte-identity anchors (incl. the out-of-scope 0301 malformed-ship handler) survive',
    (select count(*) from public.buff_definitions);
end $sfassert$;
