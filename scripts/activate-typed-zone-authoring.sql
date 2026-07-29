-- Byeharu — TYPED-ZONE ACTIVATION. Owner-run. Requires migrations 0273-0285 to be DEPLOYED first.
--
--   psql "$PROD_DB_URL" -v ON_ERROR_STOP=1 -f scripts/activate-typed-zone-authoring.sql
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THERE ARE TWO KINDS OF FLAG HERE AND THEY ARE NOT THE SAME DECISION
--
--   AUTHORING flags  — let the OWNER use the editor. They change what YOU can do.
--                      No player sees anything different. This is what "I want to be able to
--                      actually build zones" means.
--
--   RUNTIME flags    — change what PLAYERS experience: which zone decides an interception, whether
--                      a combat zone spawns, whether mining/exploration read zones instead of points.
--                      These are the ones the shadow comparison (0275) exists to de-risk.
--
-- SECTION A turns on authoring. SECTION B is left COMMENTED OUT deliberately — not to be
-- precious, but because flipping a runtime flag is the moment player outcomes change, and it should
-- be a separate, deliberate act with the shadow diff read first. Uncomment when you mean it.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ── 0. refuse to run against a database that has not been migrated ──────────────────────────────
do $guard$
begin
  if to_regclass('public.zone_effect_pirate_intercept') is null
     or to_regclass('public.zone_kind_permitted_effects') is null then
    raise exception 'ACTIVATION REFUSED: migrations 0273-0285 are not deployed here. Deploy first.';
  end if;
  if not exists (select 1 from public.game_config where key = 'seeded_zone_edit_enabled') then
    raise exception 'ACTIVATION REFUSED: 0283 is not deployed here.';
  end if;
end $guard$;

begin;

-- ── A. AUTHORING — this is the set that makes the editor fully usable ───────────────────────────
update public.game_config set value = 'true'::jsonb, updated_at = now()
 where key in (
   -- create/edit effects on any zone, and change a zone's kind
   'typed_zone_authoring_enabled',
   -- reshape and rename the three SEEDED zones (Reaver, Snare, Blackden)
   'seeded_zone_edit_enabled',
   -- unpublish a seeded zone from the live map, or restore one
   'seeded_zone_lifecycle_enabled'
 );

-- ── B. RUNTIME — COMMENTED OUT ON PURPOSE. These change PLAYER outcomes. ────────────────────────
-- Read the shadow diff (typed_zone_pirate_shadow_compare_v1) over real legs BEFORE lighting the
-- pirate one: it tells you whether the new planner picks the same zone and the same risk as the
-- deployed 0233 path. Light them one at a time, not as a set.
--
-- update public.game_config set value = 'true'::jsonb, updated_at = now()
--  where key = 'typed_zone_pirate_intercept_runtime_enabled';   -- typed planner decides interception
--
-- update public.game_config set value = 'true'::jsonb, updated_at = now()
--  where key = 'typed_zone_combat_runtime_enabled';             -- ALSO needs encounter_resolver_enabled
--
-- update public.game_config set value = 'true'::jsonb, updated_at = now()
--  where key = 'typed_zone_mining_runtime_enabled';             -- zones serve mining instead of points
--
-- update public.game_config set value = 'true'::jsonb, updated_at = now()
--  where key = 'typed_zone_exploration_runtime_enabled';

-- ── C. VERIFY BEFORE COMMITTING ─────────────────────────────────────────────────────────────────
do $verify$
declare v_off text[];
begin
  select coalesce(array_agg(key order by key), array[]::text[]) into v_off
    from public.game_config
   where key in ('typed_zone_authoring_enabled','seeded_zone_edit_enabled','seeded_zone_lifecycle_enabled')
     and coalesce((value)::text, 'false') <> 'true';
  if array_length(v_off, 1) is not null then
    raise exception 'ACTIVATION INCOMPLETE: still off -> %', array_to_string(v_off, ', ');
  end if;

  -- the runtime flags must NOT have been lit as a side effect of this script
  if coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false)
     or coalesce(public.cfg_bool('typed_zone_mining_runtime_enabled'), false)
     or coalesce(public.cfg_bool('typed_zone_exploration_runtime_enabled'), false) then
    raise exception 'ACTIVATION ABORTED: a RUNTIME flag is lit. This script must change authoring only.';
  end if;

  raise notice 'TYPED-ZONE AUTHORING ACTIVE: you can now create zones, set effects, change kinds, and edit/unpublish the three seeded zones. NO runtime flag was lit, so nothing changed for players.';
end $verify$;

commit;

-- ── ROLLBACK, if you want it dark again ─────────────────────────────────────────────────────────
-- update public.game_config set value = 'false'::jsonb, updated_at = now()
--  where key in ('typed_zone_authoring_enabled','seeded_zone_edit_enabled','seeded_zone_lifecycle_enabled');
--
-- This is a REAL rollback for the seeded zones: provenance is immutable (0282), so turning
-- seeded_zone_edit_enabled off re-protects them exactly. Zones you CREATED stay yours — they are
-- provenance='owner' and were never gated by these flags.
