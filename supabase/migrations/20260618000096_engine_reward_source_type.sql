-- Byeharu — EXPLORATION-P11 SLICE A: activity-agnostic deposit-on-arrival carrier (prerequisite
-- refactor; NO new feature, NO behavior change; nothing activated).
--
-- reward_grant(source_type, …) has been generic since 0015/0040 — the ONLY combat coupling in the
-- pending-bundle → attach → deposit-on-arrival path (docs/ACTIVITIES.md §2) is at the CARRIER layer:
--   • fleet_movements has no source-type column, and
--   • process_fleet_movements' return branch (latest shipped body: 0030:36) hard-codes
--     reward_grant('combat', …).
-- Exploration (and later Mining/Trade expeditions) must reuse the EXACT same engine path — one shared
-- carrier, never a parallel deposit system — so the movement row now transports its reward source type.
--
-- What changes (and what does not):
--   1) fleet_movements.reward_source_type text NOT NULL DEFAULT 'combat' + closed domain CHECK
--      ('combat','exploration','mining','trade' — the docs/ACTIVITIES.md §3 activity ownership set;
--      closed set now, additive later). Existing rows backfill to 'combat' — every payload-carrying
--      return in flight today IS combat's.
--   2) movement_attach_cargo gains p_source_type text DEFAULT 'combat' and writes the column. The old
--      3-arg signature is DROPPED first (the 0038/0081–0084 signature-evolution idiom — otherwise the
--      3-arg and 4-arg overloads would make existing calls ambiguous). Every existing caller
--      (process_combat_ticks, latest 0046:185, 3-arg call) keeps working verbatim via the default.
--   3) process_fleet_movements is re-created from its latest shipped body (0030:36) byte-identical
--      EXCEPT the deposit call — reward_grant(m.reward_source_type, …) instead of the literal
--      'combat' — and that call's two-line comment, which claimed combat-specificity and would
--      otherwise contradict the code it annotates.
-- Combat behavior is UNCHANGED: same column default, same attach default, same deposit semantics,
-- same idempotency (reward_grants UNIQUE (source_type, source_id), 0040). No flag is added, read,
-- or flipped; no activity is enabled — exploration stays entirely unbuilt/dark after this slice.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): Movement remains the SOLE writer of
-- fleet_movements (movement_attach_cargo is Movement-owned; Combat still never writes the table
-- directly); process_fleet_movements remains the only return-branch writer; reward_grant remains the
-- only depositor. No new cross-system edge; the call graph is unchanged and acyclic.

-- ── 1) carrier column: which activity's pending bundle this movement transports ──────────────────
alter table public.fleet_movements
  add column if not exists reward_source_type text not null default 'combat';

-- Closed activity-source domain (matches the docs/ACTIVITIES.md §3 ownership table; a future
-- activity type is an additive constraint change in a new forward-only migration).
alter table public.fleet_movements
  add constraint fleet_movements_reward_source_type_domain
  check (reward_source_type in ('combat', 'exploration', 'mining', 'trade'));

comment on column public.fleet_movements.reward_source_type is
  'Activity source of the carried pending-reward bundle (reward_payload_json); passed through to '
  'reward_grant(source_type, …) on home arrival. Always ''combat'' today; exploration/mining/trade '
  'reuse the same carrier additively. Written only by movement_attach_cargo (Movement-owned).';

-- ── 2) movement_attach_cargo: transport the source type (old 3-arg call sites keep working) ──────
-- Drop the old signature first (0038 idiom): keeping both would make every existing 3-arg call
-- ambiguous against the new defaulted 4-arg form. plpgsql callers bind by name at runtime, so the
-- latest process_combat_ticks (0046) resolves to this new function with p_source_type = 'combat'.
drop function if exists public.movement_attach_cargo(uuid, uuid, jsonb);

create or replace function public.movement_attach_cargo(
  p_movement uuid, p_source_id uuid, p_rewards jsonb, p_source_type text default 'combat')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update fleet_movements set reward_grant_source = p_source_id,
                             reward_payload_json = coalesce(p_rewards, '{}'::jsonb),
                             reward_source_type  = p_source_type
    where id = p_movement;
end;
$$;

-- ── 3) process_fleet_movements: deposit under the carried source type ────────────────────────────
-- Body copied verbatim from the latest shipped definition (0030:36). The ONLY differences are the
-- reward_grant deposit call (literal 'combat' → m.reward_source_type) and its two-line comment.
create or replace function public.process_fleet_movements()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  m         record;
  v_loc     record;
  v_units   jsonb;
  v_count   integer := 0;
begin
  for m in
    select * from fleet_movements
    where status = 'moving' and arrive_at <= now()
    for update skip locked
  loop
    if m.target_type = 'location' then
      select l.activity_type as activity, l.zone_id as zone_id, z.sector_id as sector_id
        into v_loc from locations l join zones z on z.id = l.zone_id where l.id = m.target_location_id;
      update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
      perform fleet_set_present(m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id);
      perform presence_create(m.player_id, m.fleet_id, v_loc.sector_id, v_loc.zone_id, m.target_location_id, v_loc.activity);

    elsif m.target_type = 'base' then
      select jsonb_agg(jsonb_build_object('unit_type_id', unit_type_id, 'quantity', quantity))
        into v_units from fleet_units where fleet_id = m.fleet_id and quantity > 0;
      update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
      if v_units is not null then
        perform base_merge_units(m.target_base_id, v_units);
      end if;
      perform fleet_complete(m.fleet_id);
      -- Deposit carried rewards now that the fleet is safely home (idempotent via
      -- reward_grants unique source), under the movement's activity source type.
      if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
        perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, m.target_base_id, m.reward_payload_json);
      end if;

    else
      update fleet_movements set status = 'failed', resolved_at = now() where id = m.id;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ── 4) ACL (anti-cheat): both functions stay internal — NO client execute grant ──────────────────
-- movement_attach_cargo was re-created under a new signature (the DROP discards the old ACL); the
-- 0030 default-privileges revoke already denies new functions to clients, but re-assert explicitly
-- (0093 internal-function idiom). process_fleet_movements keeps its ACL through CREATE OR REPLACE;
-- re-assert as defense-in-depth (0070 idiom). Neither had — nor gains — any client or service_role
-- grant; cron and SECURITY DEFINER orchestrators invoke them as owner.
revoke execute on function public.movement_attach_cargo(uuid, uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function public.process_fleet_movements() from public, anon, authenticated;
