-- Byeharu — SHIELD-0 (the SHIELD charter, slice 0 of SHIELD-0..2 + ACT-SHIELD): the shield
-- system's SCHEMA FOUNDATION — columns + the one sync leaf + the two regen knobs, DEPLOY-INERT.
-- OWNER DIRECTIVE: ships get a SHIELD that regenerates during and outside combat. This slice is
-- schema + the leaf + knobs ONLY — NO engine change of any kind (SHIELD-1 owns the tick/creator
-- parity re-creates that make combat consume shields; SHIELD-2 owns the regen home + UI).
--
-- ── THE GATING STORY (data-gated, deliberately NO shield_enabled flag) ───────────────────────────
-- The system is gated by its DATA, the 0170 hull-stats posture: every hull's base_shield is 0,
-- every instance is 0/0, and both regen knobs are seeded '0' (the 0170/0180/0185 seeded-zero
-- idiom = double-inert). A shield of 0 over max 0 participates in nothing; a regen pct of 0 moves
-- nothing even after SHIELD-1/2 wire consumers. Activation is the human's ACT-SHIELD script
-- (knobs + the monotonic per-hull base_shield backfill + the instance 0→base copy), never a
-- migration — rollback = knobs/data back to 0, the flags-never-data law's data-knob analogue.
--
-- ── THE hp MODEL, MIRRORED (0043) ────────────────────────────────────────────────────────────────
-- hp: main_ship_hull_types.base_hp → instance hp/max_hp copied at commission (0043:80-84; heads
-- today: port_entry_commission_build 0184, ensure_main_ship_for_player 0078). shield mirrors the
-- SHAPE with one deliberate difference: 0043's `max_hp > 0` becomes `max_shield >= 0` — a
-- shieldless ship (max_shield 0) is a legal permanent state, an hp-less ship is not.
--
-- ── THE COMMISSION DECISION (verified, the reason this slice re-creates NOTHING) ─────────────────
-- Every live insert into main_ship_instances ENUMERATES its columns (grep-verified: 0184:64-66 the
-- commission build core's TRUE head; 0078:45-46 the legacy ensure helper's TRUE head; nothing
-- later re-creates either). An enumerated insert takes column DEFAULTS for the columns it omits —
-- so with `default 0 not null`, every newly commissioned ship is born shield 0 / max_shield 0
-- with NO commission re-create, which is EXACTLY this slice's inert posture. The base_shield →
-- max_shield commission copy (the 0043:81 base_hp analogue) lands with SHIELD-1/2's engine
-- re-creates, where it is behavior it can prove; ACT-SHIELD's flip script does the monotonic
-- backfill for ships that exist before the flip. Zero function re-creates this slice.
--
-- ── combat_units SNAPSHOT COLUMNS (the 0167 member-widening posture) ─────────────────────────────
-- shield_max/shield_current double precision NULL — the member shield frozen/tracked per
-- encounter, the attack_snapshot/defense_snapshot 0167:69-70 shape (double precision like the
-- combat hp columns; NULL on every catalog row). PAIRING CHECK — the 0167:85-88 snapshot-pairing
-- law ADAPTED, one deliberate weakening, stated honestly: 0167 could demand the strict IFF
-- (member row ⇔ snapshots present) because D1 landed BEFORE any member-row writer existed, so the
-- writer (D2's send_ship_group_hunt → combat_create_encounter member branch) was BORN writing
-- snapshots. SHIELD-0 lands AFTER that writer went LIVE (the 2026-07-12 team-command activation)
-- and the writer does not write shields until SHIELD-1 — a strict IFF would make every live
-- member-encounter insert fail the CHECK and break team hunts on deploy. So the pairing here is:
-- the two shield columns are NULL/NOT-NULL TOGETHER, and may be non-NULL ONLY on a member row —
-- catalog rows can never carry a stray shield (the half of the 0167 law that guards the engine's
-- future coalesce reads), member rows stay NULL-legal until SHIELD-1's writer re-create populates
-- them (which may then tighten to the full IFF under its own parity proof).
--
-- ── THE ONE SYNC LEAF: mainship_sync_combat_shield (the 0167:129-145 sibling posture) ────────────
-- The member mirror of mainship_sync_combat_hp, one deliberate addition: BOTH clamps. The hp
-- sibling clamps only at 0 (greatest) because combat only ever LOWERS hp; shield REGENERATES, so
-- the future regen/tick callers can overshoot upward and the leaf owns the ceiling too —
-- least(max_shield, greatest(0, p_shield)), integer, the 0043 instance domain. THE ONE-LEAF LAW
-- (0167 restated): one leaf, one concern — this function writes main_ship_instances.shield ONLY
-- (never hp, never max_shield, never status/spatial state/fleets); missing p_main_ship_id updates
-- zero rows (the 0153/0167 missing-row semantics); SECURITY DEFINER, service_role-only (the
-- 0167:559-564 ACL posture verbatim). NO CALLER EXISTS THIS SLICE — SHIELD-1 wires it into the
-- tick exactly as mainship_sync_combat_hp is wired (0167/0169:325); until then it is dark, inert,
-- and unreachable by any client.
--
-- ── THE REGEN KNOBS + THE FUTURE REGEN INDEX ─────────────────────────────────────────────────────
-- game_config shield_regen_combat_pct / shield_regen_idle_pct, both seeded '0' (fraction of
-- max_shield per tick/pass; 0 = OFF). [D — owner-tunable at ACT-SHIELD; the charter's proposals:
-- 0.02 combat, 0.10 idle; base_shield at flip: Sparrow 100 / Mule 130 / Talon 85.] The partial
-- index main_ship_instances (main_ship_id) WHERE shield < max_shield is SHIELD-2's regen-pass
-- scan surface (only damaged shields are candidates); while every instance is 0/0 the predicate
-- `0 < 0` is false on every row, so the index matches ZERO rows today — asserted below.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this slice): main_ship_instances gains the
-- disjoint-writer-by-column posture (the captain_instances xp/level precedent) — `shield`'s sole
-- runtime writer is this leaf (callers arrive in SHIELD-1's 0169-head re-creates); `max_shield`
-- has NO runtime writer this slice (migration/ACT-SHIELD data, then SHIELD-1/2 commission
-- re-creates). combat_units.shield_max/shield_current stay Combat-owned, writer = SHIELD-1's tick
-- re-creates, NULL on every row today. Docs synced: FULL_CAPACITY_PLAN (the SHIELD charter, new
-- §C phase), DEV_LOG.
--
-- Forward-only: 0001–0187 unedited (0188–0190 are claimed by in-flight slices).

-- ── (a) the hull template column (Reference/Config; the 0043 base_hp shape, 0-legal) ─────────────
alter table public.main_ship_hull_types
  add column base_shield integer not null default 0,
  add constraint main_ship_hull_types_base_shield_nonneg check (base_shield >= 0);

comment on column public.main_ship_hull_types.base_shield is
  'SHIELD-0 (0191): the hull''s shield template (the base_hp analogue). 0 on every hull until the '
  'human ACT-SHIELD flip sets the owner-tunable values — 0 = shieldless, a legal permanent state.';

-- ── (b) the instance columns (the 0043:53-54 hp/max_hp CHECK shape; max_shield 0-legal) ──────────
alter table public.main_ship_instances
  add column shield     integer not null default 0,
  add column max_shield integer not null default 0,
  add constraint main_ship_instances_shield_nonneg     check (shield >= 0),
  add constraint main_ship_instances_max_shield_nonneg check (max_shield >= 0),
  add constraint main_ship_instances_shield_le_max     check (shield <= max_shield);

comment on column public.main_ship_instances.shield is
  'SHIELD-0 (0191): current shield. Sole runtime writer = mainship_sync_combat_shield (no caller '
  'until SHIELD-1 wires the tick). 0/0 on every ship until ACT-SHIELD.';
comment on column public.main_ship_instances.max_shield is
  'SHIELD-0 (0191): shield capacity (the max_hp analogue, but 0-legal = shieldless). No runtime '
  'writer this slice; ACT-SHIELD backfills existing ships, SHIELD-1/2 own the commission copy.';

-- ── (c) the combat snapshot columns + the adapted pairing CHECK (see the header honesty note) ────
alter table public.combat_units
  add column shield_max     double precision,
  add column shield_current double precision,
  add constraint combat_units_member_shield_pairing
  check (((shield_max is null) = (shield_current is null))
     and (main_ship_id is not null or shield_max is null));

comment on column public.combat_units.shield_max is
  'SHIELD-0 (0191): member shield capacity frozen at encounter creation. NO writer until '
  'SHIELD-1''s tick/creator re-creates — NULL on every row today; never non-NULL on a catalog row.';
comment on column public.combat_units.shield_current is
  'SHIELD-0 (0191): member shield tracked across waves (the hp_current analogue). NO writer until '
  'SHIELD-1 — NULL on every row today; paired with shield_max by CHECK.';

-- ── (d) the ONE sync leaf — the mainship_sync_combat_hp (0167:134-145) sibling, both clamps ──────
-- One leaf, one concern (the 0167 law): writes main_ship_instances.shield ONLY. Missing row =
-- zero rows updated. No caller exists this slice (SHIELD-1 wires the tick). NOTE: the body is
-- deliberately kept free of the 'hp' token (it does name max_shield/updated_at/main_ship_id —
-- the clamp ceiling and the write's own bookkeeping), which is exactly what the self-assert and
-- the proof pin against pg_proc.prosrc: the leaf never touches the hull-points pair.
create or replace function public.mainship_sync_combat_shield(p_main_ship_id uuid, p_shield integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.main_ship_instances
    set shield = least(max_shield, greatest(0, p_shield)), updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;

-- ACL — the 0167:559-564 posture verbatim: revoked from every client role, service_role only
-- (the SECURITY DEFINER tick will invoke it as owner in SHIELD-1; service_role keeps CI access).
revoke execute on function public.mainship_sync_combat_shield(uuid, integer) from public, anon, authenticated;
grant  execute on function public.mainship_sync_combat_shield(uuid, integer) to service_role;

-- ── (e) the two regen knobs, seeded ZERO (the 0170/0180/0185 double-inert knob idiom) ────────────
insert into public.game_config (key, value, description) values
  ('shield_regen_combat_pct', '0',
   'SHIELD-0 (0191): fraction of max_shield a member ship regenerates per combat tick (0..1). '
   '0 = OFF (the dark seed). Consumed by NOTHING until SHIELD-1 wires the tick; raised only by '
   'the human ACT-SHIELD activation script; tunable any time via set_game_config.'),
  ('shield_regen_idle_pct', '0',
   'SHIELD-0 (0191): fraction of max_shield a ship regenerates per out-of-combat regen pass '
   '(0..1). 0 = OFF (the dark seed). Consumed by NOTHING until SHIELD-2 builds the regen home; '
   'raised only by the human ACT-SHIELD activation script; tunable via set_game_config.')
on conflict (key) do nothing;

-- ── (f) the future regen pass's scan surface — matches NO row while every ship is 0/0 ────────────
create index main_ship_instances_shield_regen_idx
  on public.main_ship_instances (main_ship_id)
  where shield < max_shield;

-- ── (g) SELF-ASSERTS — the migration proves its own inertness or refuses to land ─────────────────
do $$
declare
  v_n   integer;
  v_txt text;
begin
  -- (1) the three instance/hull columns landed with the EXACT shape: integer, NOT NULL, default 0.
  select count(*) into v_n from information_schema.columns
    where table_schema = 'public'
      and ((table_name = 'main_ship_hull_types' and column_name = 'base_shield')
        or (table_name = 'main_ship_instances'  and column_name in ('shield', 'max_shield')))
      and data_type = 'integer' and is_nullable = 'NO' and column_default = '0';
  if v_n <> 3 then
    raise exception 'SHIELD-0 self-assert FAIL: % of 3 shield columns carry integer/not-null/default-0', v_n;
  end if;

  -- (2) the combat snapshot columns landed NULLABLE double precision with NO default (the 0167
  --     snapshot shape — a default would silently violate the pairing CHECK on catalog inserts).
  select count(*) into v_n from information_schema.columns
    where table_schema = 'public' and table_name = 'combat_units'
      and column_name in ('shield_max', 'shield_current')
      and data_type = 'double precision' and is_nullable = 'YES' and column_default is null;
  if v_n <> 2 then
    raise exception 'SHIELD-0 self-assert FAIL: % of 2 combat_units shield columns are nullable double precision, no default', v_n;
  end if;

  -- (3) all four CHECKs exist by name (three range CHECKs + the pairing CHECK).
  select count(*) into v_n from pg_constraint
    where conname in ('main_ship_hull_types_base_shield_nonneg',
                      'main_ship_instances_shield_nonneg',
                      'main_ship_instances_max_shield_nonneg',
                      'main_ship_instances_shield_le_max',
                      'combat_units_member_shield_pairing')
      and contype = 'c';
  if v_n <> 5 then
    raise exception 'SHIELD-0 self-assert FAIL: % of 5 shield CHECK constraints present', v_n;
  end if;

  -- (4) the leaf exists, service_role-only (the 0167 ACL posture), and its body pins the one-leaf
  --     law: both clamps present, writes shield only (the body never names another writable
  --     column — pinned by the absence of the two-letter hull-points token), no session RNG.
  select prosrc into v_txt from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'mainship_sync_combat_shield';
  if v_txt is null then
    raise exception 'SHIELD-0 self-assert FAIL: mainship_sync_combat_shield not found';
  end if;
  if strpos(v_txt, 'greatest(0, p_shield)') = 0 or strpos(v_txt, 'least(max_shield') = 0 then
    raise exception 'SHIELD-0 self-assert FAIL: the leaf is missing a clamp (want greatest(0,...) + least(max_shield,...))';
  end if;
  if strpos(v_txt, 'set shield') = 0 then
    raise exception 'SHIELD-0 self-assert FAIL: the leaf does not write shield';
  end if;
  if strpos(v_txt, 'hp') <> 0 then
    raise exception 'SHIELD-0 self-assert FAIL: the leaf body mentions hp (one leaf one concern breach)';
  end if;
  if strpos(v_txt, 'random(') <> 0 or strpos(v_txt, 'setseed') <> 0 then
    raise exception 'SHIELD-0 self-assert FAIL: the leaf body carries session RNG (0041 determinism breach)';
  end if;
  if not has_function_privilege('service_role', 'public.mainship_sync_combat_shield(uuid, integer)', 'execute') then
    raise exception 'SHIELD-0 self-assert FAIL: service_role cannot execute the leaf';
  end if;
  if has_function_privilege('authenticated', 'public.mainship_sync_combat_shield(uuid, integer)', 'execute')
     or has_function_privilege('anon', 'public.mainship_sync_combat_shield(uuid, integer)', 'execute') then
    raise exception 'SHIELD-0 self-assert FAIL: a client role can execute the leaf (must be service_role-only)';
  end if;

  -- (5) both knobs seeded '0' (double-inert: no consumer exists AND the value is OFF).
  select count(*) into v_n from public.game_config
    where key in ('shield_regen_combat_pct', 'shield_regen_idle_pct') and value #>> '{}' = '0';
  if v_n <> 2 then
    raise exception 'SHIELD-0 self-assert FAIL: % of 2 regen knobs seeded ''0'' (this slice must land inert)', v_n;
  end if;

  -- (6) TOTAL INERTNESS: every hull base_shield 0; every instance 0/0; every combat row NULL/NULL;
  --     and the missing-row leaf semantics (a random uuid updates zero rows and changes nothing —
  --     safe on any database, including an empty CI chain).
  select count(*) into v_n from public.main_ship_hull_types where base_shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-0 self-assert FAIL: % hull row(s) carry base_shield <> 0 at seed time', v_n;
  end if;
  select count(*) into v_n from public.main_ship_instances where shield <> 0 or max_shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-0 self-assert FAIL: % instance row(s) not at 0/0 at seed time', v_n;
  end if;
  select count(*) into v_n from public.combat_units where shield_max is not null or shield_current is not null;
  if v_n <> 0 then
    raise exception 'SHIELD-0 self-assert FAIL: % combat_units row(s) carry a shield snapshot at seed time', v_n;
  end if;
  perform public.mainship_sync_combat_shield(gen_random_uuid(), 5);
  select count(*) into v_n from public.main_ship_instances where shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-0 self-assert FAIL: the missing-row leaf call moved % row(s) (want zero-rows semantics)', v_n;
  end if;

  -- (7) the regen partial index exists AND its predicate matches zero rows while everything is 0/0.
  select count(*) into v_n from pg_indexes
    where schemaname = 'public' and tablename = 'main_ship_instances'
      and indexname = 'main_ship_instances_shield_regen_idx';
  if v_n <> 1 then
    raise exception 'SHIELD-0 self-assert FAIL: the shield regen partial index is missing';
  end if;
  select count(*) into v_n from public.main_ship_instances where shield < max_shield;
  if v_n <> 0 then
    raise exception 'SHIELD-0 self-assert FAIL: the regen predicate matches % row(s) (want 0 — nothing to regenerate while 0/0)', v_n;
  end if;

  raise notice 'SHIELD-0 self-assert ok: 3 integer default-0 columns + 2 nullable snapshot columns + 5 CHECKs; leaf service-only with both clamps, shield-only body, no RNG, zero-rows on a missing ship; both regen knobs ''0''; every hull 0, every instance 0/0, every combat row NULL/NULL; regen index present matching 0 rows — deploy-inert';
end $$;
