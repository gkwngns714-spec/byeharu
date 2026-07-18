-- Byeharu — COMBAT SLICE 1: per-ship damage + command-ship protection. Migration 0228. DARK behind
-- the new flag `per_ship_targeting_enabled` (seeded false).
--
-- ── THE OWNER'S BUG (the #1 fix) ─────────────────────────────────────────────────────────────────
-- "A fleet takes damage and every ship is damaged EQUALLY; that must end; the command ship takes
-- less damage, screened by escorts." combat_units is ALREADY per-ship for a group hunt (one row per
-- member main_ship_id, D1 0167 + SHIELD-1 0195's own attack/defense/shield snapshots and live
-- hp/alive_count). THE BUG is ONE line in the tick — 20260618000206:357 —
--   v_d_group := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
-- the enemy's per-tick attack (v_final_player, a fleet-wide aggregate over summed defense) is split
-- EQUALLY across every alive row regardless of hp, defense, or role. is_command_ship (0204,
-- fleetctrl_command_ship.sql:64-65) is grep-verified UNREAD by process_combat_ticks or
-- combat_create_group_encounter today — zero command-ship combat protection exists.
--
-- ── THE BUILD (structural protection, NOT a flat multiplier — the architect's recommended default) ─
-- 1. combat_units.aggro_priority integer, nullable/no-default (additive, like the SHIELD-0 NULL-
--    until-lit column pattern — safe to add unconditionally). combat_create_group_encounter's roster
--    loop (0195's TRUE head) snapshots it per member: is_command_ship=true → HIGH (100, hit LAST);
--    false (an escort) → LOW (0, hit FIRST). Read in the SAME manifest pass that already takes
--    msi.hp/shield/max_shield (the 0195 one-read law — no second pass, no drift window).
-- 2. process_combat_ticks (TRUE head 20260618000206, CRON-GUARD): when per_ship_targeting_enabled is
--    LIT and the encounter has at least one row carrying a non-NULL aggro_priority (i.e. it is a
--    group/member encounter — a catalog-only legacy encounter never gets aggro data and stays on the
--    equal-split arm regardless of the flag, so this slice cannot touch legacy fleet-vs-catalog
--    combat), the tick selects ONE alive target per encounter per tick — the alive row with the
--    LOWEST aggro_priority (escorts before the command ship; ties broken by id for determinism, no
--    random()) — and routes the WHOLE incoming hit (v_final_player) onto that one row; every other
--    row takes zero from this attack. This is single-target "focused fire": while any escort
--    survives, it (the lowest aggro alive row) absorbs 100% of the incoming damage; the command ship
--    (aggro 100) is hit ONLY once every escort in front of it (aggro 0) is dead. That is the
--    structural protection — "screened by escorts" — with no separate damage-reduction knob.
--    DARK (flag off, OR no aggro data on the encounter): v_target_unit stays NULL → the tick falls
--    through to the EXACT original equal-split expression, BYTE-IDENTICAL to the 0206 head. The
--    SHIELD-1 per-target absorption (v_absorb/v_shield, 0206:356-364) is UNCHANGED and still runs
--    per-row on whatever v_d_group each row ends up with (0 for an unhit row, v_final_player for the
--    hit row, or the equal share when dark) — one absorb point, reused, not duplicated.
-- 3. BOUNDED: group size is already capped at 8 (fleetctrl_command_ship.sql:186-202) and the target
--    select is one indexed-free scan of ≤8 alive rows per encounter per tick — no new O(n²) surface.
--
-- ── GROUNDING (grep-verified TRUE heads) ─────────────────────────────────────────────────────────
--   combat_create_group_encounter — 20260618000195 (SHIELD-1; only 0168 → 0195 create it; nothing
--     later re-creates it — re-verified this slice).
--   process_combat_ticks          — 20260618000206 (CRON-GUARD; the per-encounter subtransaction
--     head; nothing later re-creates it — re-verified this slice).
--
-- ── PARITY DISCIPLINE (ABSOLUTE — both are LIVE hot combat functions) ────────────────────────────
-- Each is re-created from its grep-verified TRUE head with marked `COMBAT-S1 (0228)` hunks ONLY.
-- Extract-and-diff: every accumulated hunk (D1 legacy-key idiom, SHIELD-1 regen/absorb/pool/gated
-- leaf, CRON-GUARD's per-row subtransaction, the reward pipeline, hull-only integrity/defeat) is
-- byte-identical. The self-assert strips `--` comments before probing prosrc (the 0221/0222 house
-- lesson — a marker living only in a comment is not a body change) and pins the flag-off arm as the
-- EXACT original formula string, so DARK really is byte-parity by construction, not by inspection.
--
-- ── SELF-ASSERT DISCIPLINE (no local Postgres — CI's `supabase start` is the real net) ──────────
-- This migration cannot build a live combat_units fixture in its own self-assert: every prior combat
-- migration in this chain (0167/0191/0195/0206) proves parity by prosrc token-pinning, NEVER by
-- inserting fixture rows inside the migration itself (main_ship_instances.player_id is a hard FK to
-- auth.users — no migration in this codebase fakes an auth.users row; that fixture idiom belongs
-- ONLY to the standalone proof scripts, e.g. scripts/team-command-proof.sql, run against a live
-- `supabase start`). This migration follows the SAME house convention: prosrc/structural pinning for
-- the deployed functions, PLUS a genuinely executable (table-free, FK-free) algorithmic proof of the
-- targeting SELECT's shape over a synthetic VALUES set — proving in real SQL, not just by string
-- match, that (a) with an escort alive the escort is selected (the command ship is screened) and (b)
-- once the escort is dead the command ship becomes the selected target (screening ends when the
-- escorts are gone), plus the flag-off equal-split arithmetic on a 2-ship fixture.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this slice): combat_units.aggro_priority is
-- Combat-owned, sole writer combat_create_group_encounter (frozen at encounter creation, like every
-- other snapshot column). process_combat_ticks gains the single-target read of it, gated on
-- per_ship_targeting_enabled. No client surface change (server-only, no new RPC).
--
-- Forward-only: 0001–0222 unedited (0223–0227 are claimed by in-flight branches). This file takes 0228.

-- ── 1) combat_units.aggro_priority — additive, nullable, no default (safe to add unconditionally) ──
alter table public.combat_units
  add column if not exists aggro_priority integer;

comment on column public.combat_units.aggro_priority is
  'COMBAT-S1 (0228): the member ship''s targeting priority, frozen at encounter creation by '
  'combat_create_group_encounter — LOWER is hit FIRST. Escort (is_command_ship=false) = 0; command '
  'ship (is_command_ship=true) = 100. NULL on every catalog row (unit_type_id identity) and on any '
  'encounter created before this slice. Consumed ONLY by process_combat_ticks''s single-target select '
  'when per_ship_targeting_enabled is lit AND the encounter carries at least one non-NULL value — '
  'otherwise the tick falls through to the original equal-split arm untouched.';

-- ── 2) NEW flag per_ship_targeting_enabled (game_config bool, seeded FALSE) ─────────────────────────
-- The 0204/0205 dark-seed idiom: on conflict do nothing so a re-apply never un-flips a live
-- activation. OFF on live — dark until a human flips it.
insert into public.game_config (key, value, description) values
  ('per_ship_targeting_enabled', 'false',
   'COMBAT-S1 (0228): server gate for per-ship aggro-weighted single-target damage. When true, an '
   'encounter carrying combat_units.aggro_priority data (a group/member encounter) routes each tick''s '
   'whole incoming hit onto the ONE alive row with the lowest aggro_priority (escorts before the '
   'command ship) instead of splitting it equally across every alive row. A catalog-only legacy '
   'encounter (no aggro data) and every encounter when this flag is dark stay on the original '
   'equal-split formula, byte-identical to the pre-0228 tick. OFF on live — dark until a human flips it.');

-- ── 3) combat_create_group_encounter — 0195 body VERBATIM + the marked COMBAT-S1 aggro-snapshot hunk ─
create or replace function public.combat_create_group_encounter(p_presence uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pr        location_presence%rowtype;
  m         record;
  v_stats   jsonb;
  v_roster  jsonb := '[]'::jsonb;
  v_power   double precision := 0;
  v_attack  double precision;
  v_defense double precision;
  v_hp      double precision;
  v_alive   integer;
  -- SHIELD-1 (0195): the member shield snapshot pair. NULL = "no shield machinery" (shieldless or
  -- degraded member — see the marked hunks below); non-NULL only when max_shield > 0.
  v_shield_max double precision;
  v_shield_cur double precision;
  -- COMBAT-S1 (0228): the member's frozen targeting priority — a STRUCTURAL fleet-role property
  -- (who is this fleet's command ship), independent of combat readiness/degradation, so it is
  -- computed ONCE per member, unconditionally, from the SAME manifest read as the shield pair.
  -- Command ship (is_command_ship) = 100 (hit LAST); escort = 0 (hit FIRST).
  v_aggro_priority integer;
  v_hull    double precision;
  v_enc     uuid;
begin
  select * into pr from location_presence where id = p_presence;
  if not found then
    raise exception 'combat_create_group_encounter: presence % not found', p_presence;
  end if;

  -- ONE pass over the MANIFEST (never live group membership — the manifest-wins law): each member's
  -- adapter stats + REAL CURRENT hp are read together, BEFORE the encounter insert, so power_start
  -- and the per-member snapshots come from the same reads (no two-pass drift window).
  for m in
    -- SHIELD-1 (0195): msi.shield/msi.max_shield ride the SAME read that takes msi.hp (the 0168
    -- one-read law: power_start, hp snapshots, and shield snapshots come from ONE manifest pass —
    -- no two-pass drift window).
    -- COMBAT-S1 (0228): msi.is_command_ship joins the SAME read (the identical one-read law) — the
    -- fleet-role fact behind the aggro snapshot comes from this pass too, no second query.
    select gsm.main_ship_id, gsm.player_id, msi.hp, msi.shield, msi.max_shield, msi.is_command_ship
      from group_sortie_members gsm
      join main_ship_instances msi on msi.main_ship_id = gsm.main_ship_id
     where gsm.fleet_id = pr.fleet_id
     order by gsm.main_ship_id
  loop
    -- DEGRADE, NEVER RAISE (header law — this runs inside the settle cron's one-txn scan). A member
    -- with hp <= 0, or whose adapter refuses its state (0122's refuse-don't-clamp raises), still gets
    -- a row — but a dead-on-arrival one: alive_count 0, zero snapshots, zero hp. Inert in every tick
    -- read (alive-filtered loops; ×alive_count sums) and settled by the existing defeat machinery if
    -- the whole roster is degraded. Never skipped (an absent row would orphan the ship's 'hunting'
    -- state) and never alive with ship_hp=0 (the tick's ceil(hp/ship_hp) would divide by zero).
    v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
    v_shield_max := null; v_shield_cur := null;   -- SHIELD-1 (0195): degraded default — NO snapshot (see the live branch)
    -- COMBAT-S1 (0228): the aggro snapshot — a fleet-ROLE fact, not a combat-readiness fact, so it is
    -- set unconditionally (before the hp>0 branch) and never reset by the degraded/exception paths.
    -- A degraded member's alive_count is 0, so it never reaches the tick's alive-filtered target
    -- select anyway; the value is still stored honestly (it IS the ship's fleet role).
    v_aggro_priority := case when m.is_command_ship then 100 else 0 end;
    if m.hp > 0 then
      begin
        -- The ONE per-ship stat adapter (0122), empty loadout — exactly what the D0 authority
        -- delegates with. attack := combat_power, defense := survival (the D1 snapshot semantics).
        v_stats   := public.calculate_expedition_stats(m.player_id, m.main_ship_id, '[]'::jsonb, 'pirate_hunt');
        v_attack  := coalesce((v_stats->>'combat_power')::double precision, 0);
        v_defense := coalesce((v_stats->>'survival')::double precision, 0);
        v_hp      := m.hp;
        v_alive   := 1;
        -- SHIELD-1 (0195): the shield snapshot — max FROZEN, CURRENT pool carried (pre-existing
        -- shield drain enters the encounter exactly as pre-existing hull damage does above). A
        -- shieldless ship (max_shield = 0 — EVERY ship until the human ACT-SHIELD flip) snapshots
        -- NULL/NULL, deliberately NOT 0/0: NULL is the shape the tick treats as "no shield
        -- machinery at all" (its regen least() stays NULL, its absorb coalesces to 0, and its
        -- shield-leaf gate never fires → per-tick write counts stay byte-identical to the
        -- pre-SHIELD1 tick). NULL/NULL satisfies the 0191 pairing CHECK (paired-together,
        -- member-row-only); the 0191 header's optional IFF tightening is DECLINED by design — a
        -- shieldless member's honest snapshot is "none", so member rows stay NULL-legal.
        if m.max_shield > 0 then
          v_shield_max := m.max_shield;
          v_shield_cur := m.shield;
        end if;
      exception when others then
        -- adapter refused (illegal member state) → the degraded shape above.
        v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
        v_shield_max := null; v_shield_cur := null;   -- SHIELD-1 (0195): degraded members carry NO shield —
                                                      -- coherent with their all-zero inert shape (they
                                                      -- never reach the tick's alive-filtered loop anyway)
      end;
    end if;
    v_power  := v_power + v_attack;   -- a degraded member contributes zero fighting power.
    v_roster := v_roster || jsonb_build_array(jsonb_build_object(
      'main_ship_id', m.main_ship_id, 'player_id', m.player_id, 'hp', v_hp,
      'alive', v_alive, 'attack', v_attack, 'defense', v_defense,
      'shield_max', v_shield_max, 'shield_cur', v_shield_cur,   -- SHIELD-1 (0195): SQL NULL → json null → NULL column below
      'aggro_priority', v_aggro_priority));   -- COMBAT-S1 (0228): SQL integer → json number → NULL-safe below
  end loop;
  -- NO empty-roster raise (header law): unreachable behind the caller's exists() gate — the manifest
  -- is read in the same txn that just proved it non-empty — and if it somehow fired it would be
  -- another cron-poisoning raise. An empty roster would simply produce a zero-unit encounter the
  -- tick's (A) defeat pass settles on its first look.

  -- Encounter row — the head 0023:87-95 insert shape mirrored semantically: same columns, same
  -- 'active'/danger-1/wave-0 initial state; player_power_start/current := Σ member combat_power
  -- (the member analogue of fleet_get_power; == D0 totals.combat_power over the manifest set).
  insert into combat_encounters (
    player_id, fleet_id, presence_id, location_id, status, danger_level,
    player_power_start, player_power_current, enemy_power_current,
    player_integrity_max, player_integrity_current, enemy_integrity_max, enemy_integrity_current,
    wave_number, last_resolved_at)
  values (
    pr.player_id, pr.fleet_id, p_presence, pr.location_id, 'active', 1,
    v_power, v_power, 0, 0, 0, 0, 0, 0, now())
  returning id into v_enc;

  -- One member combat row per manifest member — the D1-widened shape, satisfying all three D1
  -- invariants: exactly-one-identity (unit_type_id NULL ⊕ main_ship_id), snapshot-pairing (BOTH
  -- snapshots set on a member row — a degraded member's are 0, which is non-null),
  -- one-member-row-per-encounter (the manifest PK guarantees distinct ships). For a LIVE member:
  -- hp_max/hp_current := the ship's REAL CURRENT main_ship_instances.hp — pre-existing damage
  -- carries into the encounter (never max_hp); ship_hp := the same (one hull, alive_count 1 — the
  -- tick's ceil(hp/ship_hp) keeps the single hull alive until 0). For a DEGRADED member: alive 0,
  -- all-zero stats/hp (header law; ship_hp=0 is safe ONLY because alive_count=0 rows never reach the
  -- tick's division).
  insert into combat_units (
    encounter_id, player_id, unit_type_id, main_ship_id, attack_snapshot, defense_snapshot,
    ship_hp, initial_count, alive_count, hp_max, hp_current,
    shield_max, shield_current,   -- SHIELD-1 (0195): the frozen member shield pair (json null → NULL)
    aggro_priority)   -- COMBAT-S1 (0228): the frozen member targeting priority
  select v_enc, (e->>'player_id')::uuid, null, (e->>'main_ship_id')::uuid,
         (e->>'attack')::double precision, (e->>'defense')::double precision,
         (e->>'hp')::double precision, 1, (e->>'alive')::integer,
         (e->>'hp')::double precision, (e->>'hp')::double precision,
         (e->>'shield_max')::double precision, (e->>'shield_cur')::double precision,
         (e->>'aggro_priority')::integer
  from jsonb_array_elements(v_roster) as e;

  -- Integrity := Σ member hp — the head 0023:103-104 statement pair verbatim (hp_max is per-member
  -- real hp here, so the sum IS the team's current hull integrity).
  select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;
  update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;

  -- The head 0023:106-107 opening event verbatim (the tick spawns the real wave on its first pass).
  insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
    values (v_enc, pr.player_id, 0, 0, 'wave_spawned', 'pirate', 'player', jsonb_build_object('wave', 1, 'danger', 1));
  return v_enc;
end;
$$;

-- ── 4) process_combat_ticks — 0206 CRON-GUARD body VERBATIM + the marked COMBAT-S1 targeting hunk ──
create or replace function public.process_combat_ticks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  e               combat_encounters%rowtype;
  pr              location_presence%rowtype;
  loc             record;
  cu              record;
  v_tick          integer;
  v_tick_secs     double precision;
  v_retreat_delay double precision;
  v_trans_secs    double precision;
  v_var_pct       double precision;
  v_def_base      double precision;
  v_secs_inside   double precision;
  v_max_secs      double precision;
  v_forced        boolean;
  v_retreat_done  boolean;
  v_danger        integer;
  v_variance      double precision;
  v_attack        double precision;
  v_defense       double precision;
  v_hp_total      double precision;
  v_alive_total   integer;
  v_wave_num      integer;
  v_enemy_hp      double precision;
  v_e_before      double precision;
  v_e_after       double precision;
  v_enemy_attack  double precision;
  v_player_damage double precision;
  v_final_player  double precision;
  v_cleared       boolean;
  v_offense       boolean;
  v_d_group       double precision;
  v_new_hp        double precision;
  v_new_alive     integer;
  v_destroyed     integer;
  v_losses        jsonb;
  v_counts        jsonb;
  v_snapshot      jsonb;
  v_hp_after      double precision;
  v_reward_metal  double precision;
  v_reward_delta  jsonb;
  v_loot_items    jsonb;
  v_seq           integer;
  v_end           text;
  v_base_id       uuid;
  v_base_x        double precision;
  v_base_y        double precision;
  v_loc_x         double precision;
  v_loc_y         double precision;
  v_speed         double precision;
  v_mv            uuid;
  v_count         integer := 0;
  v_log_ticks     boolean;   -- PHASE A: per-tick combat_ticks logging
  v_log_events    boolean;   -- PHASE A: meaningful combat_events logging
  v_log_debug     boolean;   -- PHASE A: verbose per-unit hull_damage events
  v_shield_regen  double precision;  -- SHIELD-1 (0195): in-combat regen fraction — read ONCE per invocation
  v_shield        double precision;  -- SHIELD-1 (0195): a row's shield pool through regen → absorb (NULL = shieldless)
  v_absorb        double precision;  -- SHIELD-1 (0195): the shield-absorbed slice of a row's damage
  -- COMBAT-S1 (0228): the gate + the per-tick chosen target, read/selected ONCE per invocation /
  -- per encounter respectively (never inside the per-row loop — the same one-read discipline as
  -- v_shield_regen above).
  v_per_ship_targeting boolean;  -- read ONCE per invocation, alongside the other one-read knobs
  v_target_unit        uuid;     -- the ONE alive row this attack hits this tick; NULL = equal-split arm
begin
  v_tick_secs     := coalesce(cfg_num('combat_tick_seconds'), 3);
  v_retreat_delay := coalesce(cfg_num('retreat_delay_seconds'), 8);
  v_trans_secs    := coalesce(cfg_num('wave_transition_seconds'), 3);
  v_var_pct       := coalesce(cfg_num('combat_damage_variance_pct'), 0.10);
  v_def_base      := coalesce(cfg_num('defense_curve_base'), 100);
  v_log_ticks     := cfg_bool('combat_tick_logging');
  v_log_events    := cfg_bool('combat_event_logging');
  v_log_debug     := cfg_bool('combat_debug_logging');
  -- SHIELD-1 (0195): the regen knob joins the one-read-per-invocation block above (never read
  -- inside the per-encounter/per-row loops). Committed seed '0' (0191) → the regen term is
  -- arithmetically zero on every row until the human ACT-SHIELD flip raises it.
  v_shield_regen  := coalesce(cfg_num('shield_regen_combat_pct'), 0);
  -- COMBAT-S1 (0228): the per-ship-targeting gate joins the SAME one-read block. Committed seed
  -- 'false' → v_per_ship_targeting is false on every invocation until a human flips it.
  v_per_ship_targeting := cfg_bool('per_ship_targeting_enabled');

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
    -- ── CRON-GUARD (0206) HUNK: the per-encounter subtransaction (the 0194 per-order guard, mirrored).
    --    Any raise in the per-encounter body (a composed writer — fleet_destroy / fleet_set_returning /
    --    presence_complete / movement_create / report_create — or a degenerate per-unit divide) must
    --    NOT abort the whole 3s tick for ALL encounters and re-raise forever. On failure THIS
    --    encounter's tick rolls back (the subtransaction), a WARNING logs it, the encounter is left in
    --    its pre-tick state to retry next tick, and the loop CONTINUES — other encounters tick.
    --    query_canceled re-raised (never swallow a statement-timeout cancel — the 0194/0182 posture).
    --    v_count sits INSIDE the guard (its last body line), so a failed tick is UNCOUNTED. ──────────
    begin
    v_tick := e.tick_number + 1;
    select * into pr from location_presence where id = e.presence_id;
    select base_difficulty, reward_tier, max_presence_seconds into loc from locations where id = e.location_id;

    -- SLICE D1: member rows have no unit_types match → LEFT JOIN + snapshot-first stat reads. Every
    -- legacy row matches (FK) and has NULL snapshots, so coalesce resolves to the same catalog stats.
    select coalesce(sum(coalesce(cu2.attack_snapshot, ut.attack) * cu2.alive_count), 0),
           coalesce(sum(coalesce(cu2.defense_snapshot, ut.defense) * cu2.alive_count), 0),
           coalesce(sum(cu2.hp_current), 0),
           coalesce(sum(cu2.alive_count), 0)
      into v_attack, v_defense, v_hp_total, v_alive_total
      from combat_units cu2 left join unit_types ut on ut.id = cu2.unit_type_id
      where cu2.encounter_id = e.id;

    -- (A) Already destroyed → defeat, NO rewards.
    if v_hp_total <= 0 or v_alive_total <= 0 then
      perform fleet_destroy(e.fleet_id);
      -- SLICE D1: member ships share the destroyed fleet's fate (the 0059 terminal shape, via the
      -- one-leaf writer). No member rows exist until D2 → zero iterations for every legacy encounter.
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), player_integrity_current=0, player_power_current=0,
             total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, 0, 0,
                  e.enemy_integrity_current, e.enemy_integrity_current, 'defeat');
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      end if;
      perform report_create(e.id);
      v_count := v_count + 1; continue;
    end if;

    -- (B) End: retreat delay elapsed or forced auto-extract.
    v_secs_inside  := extract(epoch from (now() - e.started_at));
    v_max_secs     := coalesce(loc.max_presence_seconds, cfg_num('max_presence_seconds_default'), 1800);
    v_forced       := v_secs_inside >= v_max_secs;
    v_retreat_done := e.status='retreating' and e.retreat_started_at is not null
                      and now() - e.retreat_started_at >= make_interval(secs => v_retreat_delay);
    if v_retreat_done or v_forced then
      v_end := case when v_forced and e.status <> 'retreating' then 'completed' else 'escaped' end;
      select origin_base_id into v_base_id from fleets where id = e.fleet_id;
      select x, y into v_base_x, v_base_y from bases where id = v_base_id;
      select x, y into v_loc_x, v_loc_y from locations where id = e.location_id;
      -- SLICE D1: a member fleet has no fleet_units → fleet_speed is NULL; fall back to the member
      -- hull return speed. Legacy fleets always carry units → fleet_speed non-null → coalesce no-op.
      v_speed := coalesce(fleet_speed(e.fleet_id), combat_fleet_return_speed(e.fleet_id));
      update combat_encounters set status=v_end, tick_number=v_tick, ended_at=now(),
             last_resolved_at=now(), updated_at=now() where id=e.id;
      perform report_create(e.id);
      perform presence_complete(e.presence_id);
      v_mv := movement_create(e.player_id, e.fleet_id, 'location', null, pr.zone_id, e.location_id, v_loc_x, v_loc_y,
                              'base', v_base_id, null, null, v_base_x, v_base_y, 'return_home', v_speed);
      perform fleet_set_returning(e.fleet_id, v_mv);
      -- SLICE D3: surviving member ships head home WITH their fleet — 'returning' via the ONE 0152
      -- legacy in-flight leaf ('returning' is inside its hard domain; pair-write status +
      -- spatial_state NULL + coords NULL). alive_count > 0 is the survival predicate: a member the
      -- tick killed (alive_count floored to 0) or a D2-degraded member (born alive_count=0) is NOT
      -- flying anything — it stays 'hunting' hp=0 until the reconciler re-homes it at fleet
      -- completion. Mirrors the defeat branches' member loop after fleet_destroy. No member rows
      -- exist for a legacy encounter → zero iterations (the D1 parity law).
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null and alive_count > 0 loop
        perform mainship_mark_legacy_in_flight(cu.main_ship_id, 'returning');
      end loop;
      if e.total_rewards_json is not null and e.total_rewards_json <> '{}'::jsonb then
        perform movement_attach_cargo(v_mv, e.id, e.total_rewards_json);
      end if;
      if v_log_ticks then
        insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
               player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, reward_delta_json, result)
          values (e.id, e.player_id, v_tick, e.wave_number, e.danger_level, v_hp_total, v_hp_total,
                  e.enemy_integrity_current, e.enemy_integrity_current, e.total_rewards_json, v_end);
      end if;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, 0, 'retreat_completed', 'player', 'player', jsonb_build_object('forced', v_forced));
      end if;
      v_count := v_count + 1; continue;
    end if;

    -- (C) Combat step.
    v_danger       := 1 + e.waves_cleared + floor(v_secs_inside / coalesce(cfg_num('danger_time_divisor_seconds'), 180))::integer;
    v_variance     := (1 - v_var_pct) + random() * (2 * v_var_pct);
    v_enemy_attack := loc.base_difficulty * coalesce(cfg_num('enemy_attack_base'),1.0)
                      * (1 + v_danger * coalesce(cfg_num('enemy_attack_danger_scale'),0.25));
    v_seq          := 0;
    v_offense      := (e.status = 'active');
    v_wave_num     := e.wave_number;

    if e.enemy_integrity_current <= 0 then
      if e.next_wave_at is not null and now() < e.next_wave_at then
        if v_log_ticks then
          insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
                 player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after, result)
            values (e.id, e.player_id, v_tick, v_wave_num, v_danger, v_hp_total, v_hp_total, 0, 0, 'next_wave_incoming');
        end if;
        update combat_encounters set tick_number=v_tick, danger_level=v_danger, last_resolved_at=now(), updated_at=now() where id=e.id;
        v_count := v_count + 1; continue;
      end if;
      v_wave_num := e.waves_cleared + 1;
      v_enemy_hp := loc.base_difficulty * coalesce(cfg_num('enemy_hp_base'),14)
                    * (1 + v_danger * coalesce(cfg_num('enemy_hp_danger_scale'),0.6)) * v_variance;
      v_e_before := v_enemy_hp;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'wave_spawned', 'pirate', 'player',
                  jsonb_build_object('wave', v_wave_num, 'danger', v_danger, 'hp', round(v_enemy_hp)));
      end if;
      v_seq := v_seq + 1;
    else
      v_enemy_hp := e.enemy_integrity_max;
      v_e_before := e.enemy_integrity_current;
    end if;

    if v_offense then
      v_player_damage := v_attack * v_variance;
      v_e_after := v_e_before - v_player_damage;
      v_cleared := v_e_after <= 0;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'missile_salvo', 'player', 'pirate', 'missile', greatest(1, round(v_attack/50)::integer), 400,
                  jsonb_build_object('damage', round(v_player_damage), 'wave', v_wave_num));
      end if;
      v_seq := v_seq + 1;
    else
      v_player_damage := 0; v_e_after := v_e_before; v_cleared := false;
    end if;

    if v_log_events then
      insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, projectile_type, projectile_count, impact_delay_ms)
        values (e.id, e.player_id, v_tick, v_seq, 'laser_burst', 'pirate', 'player', 'laser', greatest(1, v_danger), 600);
    end if;
    v_seq := v_seq + 1;
    v_final_player := v_enemy_attack * v_def_base / (v_def_base + v_defense) * v_variance;

    -- COMBAT-S1 (0228): THE TARGET SELECT — chosen ONCE per encounter per tick, BEFORE the per-row
    -- loop (never inside it — one selection, not re-derived per row). DARK (flag off) or a
    -- catalog-only/legacy encounter (no row carries aggro_priority) → v_target_unit stays NULL and
    -- the per-row loop below falls through to the ORIGINAL equal-split expression, byte-identical to
    -- the 0206 head. LIT with aggro data present → the alive row with the LOWEST aggro_priority is
    -- picked (ties broken by id — deterministic, no random()); that row alone takes the whole hit
    -- this tick. Escorts (aggro 0) are always picked over the command ship (aggro 100) while any
    -- escort is alive — the command ship is hit only once every escort ahead of it is dead.
    v_target_unit := null;
    if v_per_ship_targeting then
      select id into v_target_unit
        from combat_units
       where encounter_id = e.id and alive_count > 0 and aggro_priority is not null
       order by aggro_priority asc, id asc
       limit 1;
    end if;

    v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
    for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
      -- SHIELD-1 (0195): in-combat regen at the top of the per-row loop — the D1 coalesce-NULL
      -- parity idiom (0167:12-14). The 0191 pairing CHECK guarantees shield_max/shield_current are
      -- NULL together (non-NULL only on member rows), so this least() sees either two NULLs
      -- (→ stays NULL: every legacy/catalog row and every shieldless member is UNTOUCHED) or two
      -- values (→ climb by max_shield × knob, capped at max_shield; knob '0' → byte-inert).
      v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);
      -- COMBAT-S1 (0228): the ONE marked delta — single-target when a target was chosen above,
      -- ELSE the ORIGINAL equal-split expression VERBATIM (the exact 0206:357 token, byte-identical
      -- — this IS the flag-off/no-aggro-data byte-parity arm, not a re-derivation of it).
      if v_target_unit is not null then
        v_d_group := case when cu.id = v_target_unit then v_final_player else 0 end;
      else
        v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
      end if;
      -- SHIELD-1 (0195): THE ONE ABSORB POINT — the shield soaks min(pool, damage); ONLY the
      -- overflow reaches the hull. A NULL/zero pool → v_absorb = 0 → the hull expression collapses
      -- to the head's exact arithmetic (cu.hp_current - v_d_group) and a NULL pool stays NULL
      -- (NULL - 0). No second damage path exists: every downstream statement consumes v_new_hp
      -- unchanged.
      v_absorb    := least(coalesce(v_shield, 0), v_d_group);
      v_shield    := v_shield - v_absorb;
      v_new_hp    := cu.hp_current - (v_d_group - v_absorb);
      v_new_alive := greatest(0, least(cu.alive_count, ceil(v_new_hp / cu.ship_hp)::integer));
      v_destroyed := cu.alive_count - v_new_alive;
      update combat_units set hp_current = greatest(0, v_new_hp), alive_count = v_new_alive,
             shield_current = v_shield,   -- SHIELD-1 (0195): NULL stays NULL; shield_max stays FROZEN
             updated_at = now()
        where id = cu.id;
      -- SLICE D1: survivor sync splits by identity — ONLY catalog-keyed counts feed
      -- fleet_sync_quantities below; a member row syncs its damage to the ship row (hp ONLY) via the
      -- one-leaf writer. Legacy rows always take the first branch, executing the identical statement.
      if cu.unit_type_id is not null then
        v_counts := v_counts || jsonb_build_object(cu.unit_type_id, v_new_alive);
      else
        perform mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer);
        -- SHIELD-1 (0195): the shield sibling of the hp sync above — mainship_sync_combat_shield
        -- (0191) is the ONE ship-row shield writer, called EXACTLY as its hp sibling is (both
        -- leaves SECURITY DEFINER + service-role-only; this SECURITY DEFINER tick invokes them as
        -- owner — the 0167:559-564 ACL precedent). Gated on a non-NULL pool: a shieldless/legacy
        -- member row fires NO shield write at all, so per-tick write counts stay byte-identical
        -- to the pre-SHIELD1 tick (v_shield is never negative here — absorb ≤ pool — and the
        -- leaf's own least/greatest clamps guard the integer domain regardless).
        if v_shield is not null then
          perform mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer);
        end if;
      end if;
      -- SLICE D1: jsonb keys/payloads use coalesce(unit_type_id, main_ship_id::text) — jsonb_build_object
      -- raises on a NULL key; legacy rows keep their exact unit_type_id keys byte-identically.
      v_snapshot := v_snapshot || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text),
                       jsonb_build_object('alive', v_new_alive, 'hp', round(greatest(0, v_new_hp))));
      -- Verbose per-unit damage event: debug-only (the worst per-tick volume driver).
      if v_log_debug then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'hull_damage', 'pirate', 'player',
                  jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'damage', round(v_d_group)));  -- SLICE D1: NULL-safe key
      end if;
      v_seq := v_seq + 1;
      if v_destroyed > 0 then
        v_losses := v_losses || jsonb_build_object(coalesce(cu.unit_type_id, cu.main_ship_id::text), v_destroyed);  -- SLICE D1: NULL-safe key
        if v_log_events then
          insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
            values (e.id, e.player_id, v_tick, v_seq, 'unit_destroyed', 'pirate', 'player',
                    jsonb_build_object('group', coalesce(cu.unit_type_id, cu.main_ship_id::text), 'count', v_destroyed));  -- SLICE D1: NULL-safe key
        end if;
        v_seq := v_seq + 1;
      end if;
    end loop;

    perform fleet_sync_quantities(e.fleet_id, v_counts);
    select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;

    v_reward_metal := 0; v_reward_delta := '{}'::jsonb; v_loot_items := '[]'::jsonb;
    if v_cleared and v_offense then
      v_reward_metal := round(coalesce(cfg_num('reward_metal_base'),10) * greatest(loc.reward_tier,1)
                              * (1 + coalesce(cfg_num('reward_danger_scale'),0.25) * v_danger) * coalesce(cfg_num('reward_multiplier'),1.0));
      v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);
      v_reward_delta := jsonb_build_object('metal', v_reward_metal, 'items', v_loot_items);
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'player', 'pirate',
                  jsonb_build_object('wave_cleared', true, 'wave', v_wave_num, 'reward_metal', v_reward_metal, 'reward_items', v_loot_items));
      end if;
      v_seq := v_seq + 1;
    end if;

    if v_log_ticks then
      insert into combat_ticks (encounter_id, player_id, tick_number, wave_number, danger_level,
             player_power_before, enemy_power, player_damage, enemy_damage,
             player_integrity_before, player_integrity_after, enemy_integrity_before, enemy_integrity_after,
             player_losses_json, reward_delta_json, unit_snapshot_json, result)
        values (e.id, e.player_id, v_tick, v_wave_num, v_danger,
                v_hp_total, v_e_before, v_player_damage, v_final_player,
                v_hp_total, greatest(0, v_hp_after), v_e_before, greatest(0, v_e_after),
                v_losses, v_reward_delta, v_snapshot,
                case when v_cleared then 'wave_cleared' else 'ongoing' end);
    end if;

    update combat_encounters set
      tick_number              = v_tick,
      danger_level             = v_danger,
      wave_number              = v_wave_num,
      waves_cleared            = waves_cleared + (case when v_cleared then 1 else 0 end),
      player_integrity_current = greatest(0, v_hp_after),
      enemy_integrity_max      = v_enemy_hp,
      enemy_integrity_current  = case when v_cleared then 0 else greatest(0, v_e_after) end,
      enemy_power_current      = case when v_cleared then 0 else greatest(0, v_e_after) end,
      next_wave_at             = case when v_cleared then now() + make_interval(secs => v_trans_secs) else e.next_wave_at end,
      player_power_current     = fleet_get_power(e.fleet_id),
      total_rewards_json       = case when v_cleared and v_offense
                                   then total_rewards_json
                                        || jsonb_build_object('metal', coalesce((total_rewards_json->>'metal')::double precision,0) + v_reward_metal)
                                        || jsonb_build_object('items', loot_merge_items(total_rewards_json->'items', v_loot_items))
                                   else total_rewards_json end,
      last_resolved_at         = now(),
      updated_at               = now()
    where id = e.id;

    if v_hp_after <= 0 then
      perform fleet_destroy(e.fleet_id);
      -- SLICE D1: member ships share the destroyed fleet's fate (the 0059 terminal shape, via the
      -- one-leaf writer). No member rows exist until D2 → zero iterations for every legacy encounter.
      for cu in select * from combat_units where encounter_id = e.id and main_ship_id is not null loop
        perform mainship_mark_combat_destroyed(cu.main_ship_id);
      end loop;
      perform presence_complete(e.presence_id);
      update combat_encounters set status='defeat', ended_at=now(), total_rewards_json='{}'::jsonb, updated_at=now() where id=e.id;
      if v_log_events then
        insert into combat_events (encounter_id, player_id, tick_number, seq, event_type, source, target, payload_json)
          values (e.id, e.player_id, v_tick, v_seq, 'explosion', 'pirate', 'player', jsonb_build_object('reason','fleet_lost'));
      end if;
      perform report_create(e.id);
    end if;

    v_count := v_count + 1;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_combat_ticks: tick failed for encounter % (left in-place; retries next tick): %',
          e.id, sqlerrm;
    end;
    -- ── END CRON-GUARD (0206) HUNK ───────────────────────────────────────────────────────────────
  end loop;

  return v_count;
end;
$$;

-- ── 5) Execute surface ────────────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on both EXISTING functions PRESERVES their owner + grants (both internal
-- engine/cron functions with no client grant, the 0195/0206 posture) — no blanket re-lock is emitted
-- (the D1 §7 rationale: that idiom belongs to migrations adding NEW client RPCs).

-- ── 6) SELF-ASSERTS — the migration proves its own parity/inertness or refuses to land ─────────────
do $$
declare
  v_creator text;
  v_tick    text;
  v_n       integer;
  v_tok     text;
  v_role    text;
begin
  select prosrc into v_creator from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_creator is null or v_tick is null then
    raise exception 'COMBAT-S1 self-assert FAIL: a re-created combat function is missing';
  end if;

  -- PROSRC-ASSERT COUPLING (the 0221/0222 house lesson): strip `--` line comments before probing, so
  -- a marker/token living ONLY in a comment can never be mistaken for a body change.
  v_creator := regexp_replace(v_creator, '--[^\n]*', '', 'g');
  v_tick    := regexp_replace(v_tick,    '--[^\n]*', '', 'g');

  -- (1) the flag is committed DARK (seeded by THIS migration — nothing can have flipped it yet).
  if coalesce((select value #>> '{}' from public.game_config where key = 'per_ship_targeting_enabled'), 'false') <> 'false' then
    raise exception 'COMBAT-S1 self-assert FAIL: per_ship_targeting_enabled is not seeded false';
  end if;

  -- (2) the additive column exists, nullable, integer, no default (a default would be meaningless —
  --     the creator is the sole writer and always supplies an explicit value or NULL via the roster).
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'combat_units' and column_name = 'aggro_priority'
      and data_type = 'integer' and is_nullable = 'YES') then
    raise exception 'COMBAT-S1 self-assert FAIL: combat_units.aggro_priority missing / wrong type / not nullable';
  end if;
  -- every pre-existing row (created before this slice) stays NULL — the additive-column law.
  select count(*) into v_n from public.combat_units where aggro_priority is not null;
  if v_n <> 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: % combat_units row(s) already carry aggro_priority at migration time (want 0)', v_n;
  end if;

  -- (3) CREATOR — the one-read law: is_command_ship rides the SAME manifest select as msi.hp/shield.
  if strpos(v_creator, 'msi.hp, msi.shield, msi.max_shield, msi.is_command_ship') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: creator does not take is_command_ship in the SAME read as msi.hp/shield (one-read law)';
  end if;
  -- the aggro constant assignment (command=100 hit-last, escort=0 hit-first) is present and
  -- UNCONDITIONAL (assigned before the `if m.hp > 0` branch, never reset inside it).
  if strpos(v_creator, 'v_aggro_priority := case when m.is_command_ship then 100 else 0 end;') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: creator is missing the unconditional aggro-priority assignment';
  end if;
  if strpos(v_creator, 'v_aggro_priority := case when m.is_command_ship then 100 else 0 end;')
       > strpos(v_creator, 'if m.hp > 0 then') then
    raise exception 'COMBAT-S1 self-assert FAIL: aggro-priority assignment is not unconditional (placed after the hp>0 branch)';
  end if;
  if strpos(v_creator, '''aggro_priority'', v_aggro_priority') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: creator roster does not carry the aggro_priority snapshot';
  end if;
  if strpos(v_creator, 'shield_current,') = 0 or strpos(v_creator, 'aggro_priority)') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: creator insert does not write the aggro_priority column';
  end if;
  -- the SHIELD-1 / D1 hull-only integrity contract is byte-unchanged (this slice adds no new sum).
  if strpos(v_creator, 'select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: the creator''s hull-only integrity statement changed';
  end if;
  if strpos(v_creator, 'random(') <> 0 or strpos(v_creator, 'setseed') <> 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: creator body carries session RNG (0041 determinism breach — aggro must be deterministic)';
  end if;

  -- (4) TICK — the gate is HOISTED: read exactly ONCE, alongside the other one-read knobs, BEFORE
  --     the encounter loop (the SHIELD-1 v_shield_regen placement law, mirrored).
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_bool(''per_ship_targeting_enabled'')', '')))
         / length('cfg_bool(''per_ship_targeting_enabled'')');
  if v_n <> 1 then
    raise exception 'COMBAT-S1 self-assert FAIL: per_ship_targeting_enabled read % times (want exactly 1 — hoisted)', v_n;
  end if;
  if strpos(v_tick, 'v_per_ship_targeting := public.cfg_bool(''per_ship_targeting_enabled'');') = 0
     and strpos(v_tick, 'v_per_ship_targeting := cfg_bool(''per_ship_targeting_enabled'');') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: the gate read assignment is missing/malformed';
  end if;
  if strpos(v_tick, 'per_ship_targeting_enabled') > strpos(v_tick, 'for e in') then
    raise exception 'COMBAT-S1 self-assert FAIL: the gate read is not in the pre-loop one-read block (hoist placement)';
  end if;

  -- (5) the target-select is scoped PER ENCOUNTER (inside `for e in`) but BEFORE the per-row loop,
  --     filters alive+non-NULL aggro, orders lowest-aggro-first with a deterministic id tiebreak,
  --     and resets to NULL every encounter (no stale target leaking across encounters/ticks).
  if strpos(v_tick, 'v_target_unit := null;') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: tick does not reset v_target_unit before selecting (would leak across encounters)';
  end if;
  if strpos(v_tick, 'where encounter_id = e.id and alive_count > 0 and aggro_priority is not null') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: tick is missing the alive+aggro-present target filter';
  end if;
  if strpos(v_tick, 'order by aggro_priority asc, id asc') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: tick is missing the lowest-aggro-first deterministic order';
  end if;
  if strpos(v_tick, 'v_target_unit := null;') > strpos(v_tick, 'for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop') then
    raise exception 'COMBAT-S1 self-assert FAIL: the target select runs AFTER the per-row loop starts (must precede it)';
  end if;

  -- (6) THE FLAG-OFF / NO-AGGRO-DATA ARM: the ORIGINAL equal-split expression survives BYTE-IDENTICAL
  --     (the 0206:357 token, verbatim) as the `else` arm of the new branch — this IS the byte-parity
  --     proof for the dark path, by construction, not by re-derivation.
  if strpos(v_tick, 'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: the original equal-split expression is gone (byte-parity breach)';
  end if;
  if strpos(v_tick, 'if v_target_unit is not null then') = 0
     or strpos(v_tick, 'v_d_group := case when cu.id = v_target_unit then v_final_player else 0 end;') = 0 then
    raise exception 'COMBAT-S1 self-assert FAIL: tick is missing the single-target branch';
  end if;
  -- the branch must WRAP the assignment (equal-split reachable only in the else arm).
  if strpos(v_tick, 'if v_target_unit is not null then') > strpos(v_tick, 'v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);') then
    raise exception 'COMBAT-S1 self-assert FAIL: the equal-split line precedes its own guarding branch (structure broken)';
  end if;

  -- (7) every accumulated 0206/0195/0167 hunk survives — re-pinned verbatim (the SHIELD-1/CRON-GUARD
  --     token list): the per-encounter subtransaction, the absorb point, the persisted pool, the
  --     gated leaf + its hp sibling, hull-only integrity/defeat, the D1 legacy-key idiom, the reward
  --     pipeline, and the exact due-encounter scan.
  foreach v_tok in array array[
    'where status in (''active'',''retreating'')',
    'v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);',
    'v_absorb    := least(coalesce(v_shield, 0), v_d_group);',
    'v_new_hp    := cu.hp_current - (v_d_group - v_absorb);',
    'shield_current = v_shield',
    'if v_shield is not null then',
    'mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer)',
    'mainship_sync_combat_hp(cu.main_ship_id, round(greatest(0, v_new_hp))::integer)',
    'if v_hp_total <= 0 or v_alive_total <= 0 then',
    'if v_hp_after <= 0 then',
    'coalesce(sum(cu2.hp_current), 0)',
    'select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;',
    'player_integrity_current = greatest(0, v_hp_after)',
    'coalesce(cu.unit_type_id, cu.main_ship_id::text)',
    'v_loot_items   := pirate_loot_for_wave(v_wave_num, v_danger);',
    'perform fleet_destroy(e.fleet_id);',
    'perform fleet_set_returning(e.fleet_id, v_mv);',
    'perform presence_complete(e.presence_id);',
    'perform report_create(e.id);',
    'mainship_mark_combat_destroyed(cu.main_ship_id)',
    'mainship_mark_legacy_in_flight(cu.main_ship_id, ''returning'')',
    'perform fleet_sync_quantities(e.fleet_id, v_counts);',
    'when query_canceled then raise;',
    'raise warning ''process_combat_ticks: tick failed for encounter %'
    ] loop
    if strpos(v_tick, v_tok) = 0 then
      raise exception 'COMBAT-S1 self-assert FAIL: process_combat_ticks lost an accumulated head hunk (token ''%'')', v_tok;
    end if;
  end loop;

  -- (8) the CRON-GUARD's ONE query_canceled re-raise survives exactly once (this slice adds no new
  --     exception handler — the whole targeting hunk lives INSIDE the existing per-encounter guard).
  v_n := (length(v_tick) - length(replace(v_tick, 'when query_canceled then raise', ''))) / length('when query_canceled then raise');
  if v_n <> 1 then raise exception 'COMBAT-S1 self-assert FAIL: process_combat_ticks has % query_canceled re-raise(s) (want exactly 1)', v_n; end if;

  -- (9) DETERMINISM (0041): the targeting hunk added NO randomness — the head's ONE variance call is
  --     still the only random( in the body (id-tiebreak is deterministic, not random).
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 1 then raise exception 'COMBAT-S1 self-assert FAIL: process_combat_ticks carries % random( call(s) (want exactly the head''s 1)', v_n; end if;

  -- (10) ACL preserved by CREATE OR REPLACE: neither engine function is client-executable.
  if has_function_privilege('authenticated', 'public.combat_create_group_encounter(uuid)', 'execute')
     or has_function_privilege('anon', 'public.combat_create_group_encounter(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception 'COMBAT-S1 self-assert FAIL: a re-created engine function is client-executable';
  end if;

  -- ══ ALGORITHMIC PROOF (genuinely executable SQL, no fixture rows, no auth FK — the targeting
  --    SELECT'S EXACT shape: same filter/order/limit, applied to a synthetic VALUES set) ═══════════
  -- (11) flag-off arithmetic: 2 ships (alive_count=1 each), one incoming hit of 100 — the ORIGINAL
  --      equal-split formula (reproduced verbatim) gives each ship the SAME 50/50 share.
  declare
    v_final double precision := 100;
    v_alive_tot integer := 2;
    v_d1 double precision;
    v_d2 double precision;
  begin
    v_d1 := v_final * 1 / greatest(v_alive_tot, 1);
    v_d2 := v_final * 1 / greatest(v_alive_tot, 1);
    if v_d1 <> 50 or v_d2 <> 50 or v_d1 <> v_d2 then
      raise exception 'COMBAT-S1 self-assert FAIL: flag-off 2-ship equal split is not 50/50 (got % / %)', v_d1, v_d2;
    end if;
  end;

  -- (12) flag-on selection while the escort is ALIVE: the escort (aggro 0) is picked over the
  --      command ship (aggro 100) — the command ship is screened, taking ZERO of this hit.
  select role into v_role
    from (values ('escort', 0, 1), ('command', 100, 1)) as t(role, aggro_priority, alive_count)
   where alive_count > 0 and aggro_priority is not null
   order by aggro_priority asc
   limit 1;
  if v_role is distinct from 'escort' then
    raise exception 'COMBAT-S1 self-assert FAIL: aggro selection with the escort alive picked % (want escort — the command ship must be screened)', v_role;
  end if;

  -- (13) flag-on selection once the escort is DEAD (alive_count 0): the command ship becomes the
  --      selected target — screening ends when the escorts are gone, exactly the owner's directive.
  select role into v_role
    from (values ('escort', 0, 0), ('command', 100, 1)) as t(role, aggro_priority, alive_count)
   where alive_count > 0 and aggro_priority is not null
   order by aggro_priority asc
   limit 1;
  if v_role is distinct from 'command' then
    raise exception 'COMBAT-S1 self-assert FAIL: aggro selection with the escort dead picked % (want command — screening must end when escorts are gone)', v_role;
  end if;

  raise notice 'COMBAT-S1 self-assert ok: per_ship_targeting_enabled seeded dark; combat_units.aggro_priority additive/nullable/all-NULL-at-deploy; creator takes is_command_ship in the one-read manifest pass and snapshots aggro_priority (100 command / 0 escort) unconditionally + writes it; tick hoists the gate once, resets+selects the lowest-aggro alive target per encounter before the per-row loop, and falls through to the BYTE-IDENTICAL original equal-split expression when dark or aggro-less; every accumulated 0206/0195/0167 hunk pinned; RNG unchanged (creator 0, tick 1); ACL closed; algorithmic proof: flag-off 2-ship split is exactly 50/50, escort-alive targeting screens the command ship, escort-dead targeting exposes it';
end $$;
