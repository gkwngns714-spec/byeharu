-- Byeharu — SHIELD-1 (the SHIELD charter, slice 1 of SHIELD-0..2 + ACT-SHIELD): the shield enters
-- the LIVE combat engine — encounter-creator + tick PARITY RE-CREATES, provably INERT while every
-- shield pool is 0/NULL and the regen knob is '0' (the 0191 dark seeds, both still committed).
-- OWNER DIRECTIVE: ships get a SHIELD that regenerates during and outside combat. This slice wires
-- the IN-COMBAT half: member encounters snapshot the pool, the tick regenerates it, damage is
-- absorbed shield-first, and the 0191 sync leaf mirrors the pool to the ship row. SHIELD-2 owns the
-- out-of-combat regen home + UI; ACT-SHIELD (human) owns the data flip that makes any of it move.
--
-- ── TRUE HEADS (grep over ALL migrations for each create-or-replace; VERIFIED) ───────────────────
--   • combat_create_group_encounter ← 0168:359 — its ONLY create site (born in D2); nothing later.
--   • process_combat_ticks ← 0169:93 — created 0017, re-created 0022 → 0023 → 0030 → 0032 → 0041 →
--     0046 → 0167 (D1) → 0169 (D3); NOTHING after 0169.
--   Both bodies below are copied VERBATIM from those heads; every delta carries a
--   `-- SHIELD-1 (0195):` marker and the whole re-create is extract-and-diff verified (the D1/D2/D3
--   parity discipline, absolute — everything outside the marked hunks is byte-identical).
--
-- ── THE SOLO CREATOR (verified, deliberately NOT re-created) ─────────────────────────────────────
-- combat_create_encounter (head 0168:481) is NOT touched: its legacy path inserts CATALOG rows only
-- (the fleet_units join, 0168:517-520 — unit_type_id identity, main_ship_id NULL, and the 0191
-- pairing CHECK forbids a shield on a catalog row anyway). Member main-ship combat_units rows have
-- exactly ONE writer (grep over all migrations: the 0168:446 insert inside
-- combat_create_group_encounter is the only combat_units insert carrying main_ship_id); the live
-- single send hard-rejects combat destinations (0152:116, `activity_type <> 'none'` raises), and a
-- 1-ship team still routes through the manifest branch (0168:501) into the group creator. There is
-- no main-ship row on the solo path to snapshot — no hunk, no re-create, no parity risk.
--
-- ── THE SNAPSHOT DECISION (NULL/NULL for a shieldless ship, NOT 0/0 — documented per charter) ────
-- The creator hunk snapshots shield_max := the ship's max_shield and shield_current := the ship's
-- CURRENT shield in the SAME manifest read that takes msi.hp (the 0168 one-read law — no two-pass
-- drift), but ONLY when max_shield > 0. A shieldless ship (max_shield = 0 — EVERY ship until
-- ACT-SHIELD) and a DEGRADED member (the 0168:399-411 dead-on-arrival shape) snapshot NULL/NULL:
--   • the 0191 pairing CHECK is satisfied either way (paired-together, member-row-only), but NULL
--     is what keeps the tick BYTE-INERT INCLUDING WRITE COUNTS: the regen least() propagates NULL
--     untouched, the absorb coalesces to 0 (hull arithmetic collapses to the head expression), and
--     the ship-row shield leaf is GATED on a non-NULL pool so it never fires — 0/0 would have fired
--     a per-member-per-tick leaf write that the pre-SHIELD1 tick never made.
--   • it is the honest semantic: "no shield machinery" — mirroring how legacy catalog rows carry
--     NULL snapshots into the same coalesce reads (the D1 0167:12-14 idiom).
--   • CONSEQUENCE: the 0191 header's optional tightening of the pairing CHECK to the strict 0167
--     IFF is DECLINED by design — member rows stay NULL-legal because a shieldless member's
--     snapshot IS "none". Degraded members carry NULL for coherence with their all-zero inert
--     shape (alive_count = 0 rows never reach the tick's per-row loop anyway).
--
-- ── THE TICK DELTAS (all inside the (C) combat step; the D1 coalesce-NULL parity idiom) ──────────
--   (a) IN-COMBAT REGEN at the top of the per-row damage loop:
--       shield := least(shield_max, shield_current + shield_max × shield_regen_combat_pct).
--       NULL/NULL rows stay NULL (least over two NULLs — the 0191 pairing CHECK guarantees the
--       pair is never mixed); knob '0' makes the term arithmetically zero for lit pools.
--   (b) ONE ABSORB POINT — shield-absorbs-first: v_absorb := least(coalesce(shield,0), v_d_group);
--       the hull takes ONLY the overflow (v_d_group - v_absorb). NO second damage path: every
--       downstream statement (alive math, hp writes, hp sync, jsonb, sums) consumes v_new_hp
--       unchanged. A NULL/zero pool → v_absorb = 0 → the head's exact hull expression.
--   (c) SHIP-ROW SHIELD SYNC — mainship_sync_combat_shield (0191, the ONE ship-row shield writer)
--       called in the SAME member branch as its hp sibling, gated on a non-NULL pool (write-count
--       parity). ACL verified: both leaves SECURITY DEFINER + service-role-only (0167:559-564 /
--       0191); the SECURITY DEFINER tick invokes them as owner — the exact hp-leaf precedent.
--   (d) UNTOUCHED, pinned by the self-asserts below: encounter integrity accounting stays
--       HULL-ONLY (the 0168:455-458 'Σ hp_max IS hull integrity' contract — shields are a buffer,
--       not hull); defeat detection stays hull-only (v_hp_total / v_hp_after <= 0 — a shield never
--       keeps a dead hull alive, and a shielded ship at hull 0 IS dead); reports/tick/event jsonb
--       keys byte-identical (the COMBATPARITY proof pins them — no shield key is emitted anywhere).
--   (e) KNOB HOIST — cfg_num('shield_regen_combat_pct') is read ONCE per tick invocation, in the
--       existing one-read knob block at the top (matching v_tick_secs/v_var_pct/…), never inside
--       the loops. Placement + exactly-one-read are prosrc-pinned below.
--
-- ── SCOPE NOTE: the commission base_shield → max_shield copy is DEFERRED (documented) ────────────
-- The 0191 header assigned the commission copy to "SHIELD-1/2's engine re-creates"; it lands with
-- SHIELD-2 (beside the regen home), NOT here: every hull's base_shield is 0 today, so the copy is a
-- provable no-op, and deferring it keeps this slice's re-create surface exactly the two combat
-- functions above (the highest-parity-discipline slice of the train stays minimal). ACT-SHIELD's
-- flip script backfills ships that exist before the flip either way (the 0191 activation story).
--
-- ── INERTNESS (deploy-time, double) ──────────────────────────────────────────────────────────────
-- Data-gated (the 0191 posture, NO flag): every instance is 0/0 → every new member snapshot is
-- NULL/NULL → regen/absorb/leaf are all provably skipped (write counts included); AND the regen
-- knob is committed '0' → even a hand-lit pool would not regenerate. The existing proofs
-- (COMBATPARITY / TEAMHUNT / TEAMSETTLE) run their exact-damage pins against THIS tick with all
-- shields 0/NULL — their green is the live parity proof; the new TEAMCMD_PASS_SHIELD1 block adds
-- the shield-specific zero-state and the in-txn lit arm (absorb/regen/cap/defeat-hull-only exact).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this slice): the combat tick becomes the ONE
-- in-combat shield consumer/writer — combat_units.shield_current's sole writer is the tick (via
-- the creator's frozen snapshot at birth), and mainship_sync_combat_shield gains its FIRST caller
-- (caller list = process_combat_ticks, exactly). main_ship_instances.shield keeps ONE runtime
-- writer (the leaf). No client surface changes (UI is SHIELD-2).
--
-- Forward-only: 0001–0193 unedited (0193 SOUL-1 merged; 0194 is promised to SHIPYARD-2's
-- renumber — numbering coordinated, this file takes 0195).

-- ── 1) combat_create_group_encounter — 0168:359 body VERBATIM + the marked SHIELD-1 hunks ────────
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
    select gsm.main_ship_id, gsm.player_id, msi.hp, msi.shield, msi.max_shield
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
      'shield_max', v_shield_max, 'shield_cur', v_shield_cur));   -- SHIELD-1 (0195): SQL NULL → json null → NULL column below
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
    shield_max, shield_current)   -- SHIELD-1 (0195): the frozen member shield pair (json null → NULL)
  select v_enc, (e->>'player_id')::uuid, null, (e->>'main_ship_id')::uuid,
         (e->>'attack')::double precision, (e->>'defense')::double precision,
         (e->>'hp')::double precision, 1, (e->>'alive')::integer,
         (e->>'hp')::double precision, (e->>'hp')::double precision,
         (e->>'shield_max')::double precision, (e->>'shield_cur')::double precision
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

-- ── 2) process_combat_ticks — 0169:93 body VERBATIM + the marked SHIELD-1 hunks ──────────────────
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

  for e in
    select * from combat_encounters
    where status in ('active','retreating')
      and (last_resolved_at is null or now() - last_resolved_at >= make_interval(secs => v_tick_secs))
    for update skip locked
  loop
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

    v_losses := '{}'::jsonb; v_counts := '{}'::jsonb; v_snapshot := '{}'::jsonb;
    for cu in select * from combat_units where encounter_id = e.id and alive_count > 0 loop
      -- SHIELD-1 (0195): in-combat regen at the top of the per-row loop — the D1 coalesce-NULL
      -- parity idiom (0167:12-14). The 0191 pairing CHECK guarantees shield_max/shield_current are
      -- NULL together (non-NULL only on member rows), so this least() sees either two NULLs
      -- (→ stays NULL: every legacy/catalog row and every shieldless member is UNTOUCHED) or two
      -- values (→ climb by max_shield × knob, capped at max_shield; knob '0' → byte-inert).
      v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);
      v_d_group   := v_final_player * cu.alive_count / greatest(v_alive_total, 1);
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
  end loop;

  return v_count;
end;
$$;

-- ── 3) Execute surface ────────────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on the two EXISTING functions PRESERVES their owner and grants
-- (combat_create_group_encounter: the 0168 internal-engine ACL — revoked from every client role,
-- service_role only; process_combat_ticks: the internal cron body) — no blanket re-lock is emitted
-- (the D1 §7 rationale verbatim: that idiom belongs to migrations adding NEW client RPCs).

-- ── 4) SELF-ASSERTS — the migration proves its own parity/inertness or refuses to land ───────────
do $$
declare
  v_creator text;
  v_tick    text;
  v_n       integer;
  v_val     text;
begin
  -- (1) both re-created functions exist.
  select prosrc into v_creator from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'combat_create_group_encounter';
  select prosrc into v_tick from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_creator is null or v_tick is null then
    raise exception 'SHIELD-1 self-assert FAIL: a re-created combat function is missing';
  end if;

  -- (2) CREATOR — the marked hunks are present…
  if strpos(v_creator, 'msi.hp, msi.shield, msi.max_shield') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator does not take the shield in the SAME read as msi.hp (one-read law)';
  end if;
  if strpos(v_creator, 'if m.max_shield > 0 then') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator is missing the shieldless NULL/NULL gate (max_shield > 0)';
  end if;
  if strpos(v_creator, '''shield_max'', v_shield_max, ''shield_cur'', v_shield_cur') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator roster does not carry the shield snapshot pair';
  end if;
  if strpos(v_creator, 'shield_max, shield_current)') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator insert does not write the shield snapshot columns';
  end if;
  -- …the OLD-HEAD fingerprints are gone (the 0168 pre-shield select/roster/insert shapes)…
  if strpos(v_creator, e'msi.hp\n') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator still carries the 0168 pre-shield manifest read (old-head fingerprint)';
  end if;
  if strpos(v_creator, '''defense'', v_defense));') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator still carries the 0168 pre-shield roster shape (old-head fingerprint)';
  end if;
  if strpos(v_creator, 'hp_max, hp_current)') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator still carries the 0168 pre-shield insert column list (old-head fingerprint)';
  end if;
  -- …the hull-integrity contract is byte-unchanged (Σ hp_max IS hull integrity — 0168:455-458)…
  if strpos(v_creator, 'select coalesce(sum(hp_max), 0) into v_hull from combat_units where encounter_id = v_enc;') = 0
     or strpos(v_creator, 'update combat_encounters set player_integrity_max = v_hull, player_integrity_current = v_hull where id = v_enc;') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: the creator''s hull-only integrity statement pair changed';
  end if;
  if strpos(v_creator, 'sum(shield') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: a shield term leaked into a creator aggregate (integrity is hull-only)';
  end if;
  -- …and no session RNG entered (0041).
  if strpos(v_creator, 'random(') <> 0 or strpos(v_creator, 'setseed') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: creator body carries session RNG (0041 determinism breach)';
  end if;

  -- (3) TICK — the knob is HOISTED: read exactly ONCE, and BEFORE the encounter loop.
  v_n := (length(v_tick) - length(replace(v_tick, 'cfg_num(''shield_regen_combat_pct'')', '')))
         / length('cfg_num(''shield_regen_combat_pct'')');
  if v_n <> 1 then
    raise exception 'SHIELD-1 self-assert FAIL: shield_regen_combat_pct read % times (want exactly 1 — hoisted)', v_n;
  end if;
  if strpos(v_tick, 'v_shield_regen  := coalesce(cfg_num(''shield_regen_combat_pct''), 0);') = 0
     or strpos(v_tick, 'v_shield_regen  := coalesce(cfg_num(''shield_regen_combat_pct''), 0);') > strpos(v_tick, 'for e in') then
    raise exception 'SHIELD-1 self-assert FAIL: the regen knob read is not in the pre-loop one-read block (hoist placement)';
  end if;
  -- the marked hunks are present: regen, the ONE absorb point, the persisted pool, the gated leaf.
  if strpos(v_tick, 'v_shield    := least(cu.shield_max, cu.shield_current + cu.shield_max * v_shield_regen);') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: tick is missing the in-combat regen hunk';
  end if;
  if strpos(v_tick, 'v_absorb    := least(coalesce(v_shield, 0), v_d_group);') = 0
     or strpos(v_tick, 'v_new_hp    := cu.hp_current - (v_d_group - v_absorb);') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: tick is missing the absorb-first hunk (the ONE absorb point)';
  end if;
  if strpos(v_tick, 'shield_current = v_shield') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: tick does not persist the post-absorb pool to combat_units';
  end if;
  if strpos(v_tick, 'if v_shield is not null then') = 0
     or strpos(v_tick, 'mainship_sync_combat_shield(cu.main_ship_id, round(v_shield)::integer)') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: tick is missing the gated ship-row shield sync (the 0191 leaf call)';
  end if;
  -- the OLD-HEAD fingerprints are gone (the 0169 pre-shield damage/update lines).
  if strpos(v_tick, 'cu.hp_current - v_d_group;') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: tick still carries the 0169 pre-shield hull expression (old-head fingerprint)';
  end if;
  if strpos(v_tick, 'alive_count = v_new_alive, updated_at = now()') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: tick still carries the 0169 pre-shield combat_units update (old-head fingerprint)';
  end if;
  -- integrity + defeat detection stay HULL-ONLY, byte-pinned (a shield never keeps a dead hull
  -- alive; a shielded ship at hull 0 is dead; Σ hp_current drives every integrity write).
  if strpos(v_tick, 'if v_hp_total <= 0 or v_alive_total <= 0 then') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: the (A) defeat predicate changed (must stay hull-only)';
  end if;
  if strpos(v_tick, 'if v_hp_after <= 0 then') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: the post-step defeat predicate changed (must stay hull-only)';
  end if;
  if strpos(v_tick, 'coalesce(sum(cu2.hp_current), 0)') = 0
     or strpos(v_tick, 'select coalesce(sum(hp_current), 0) into v_hp_after from combat_units where encounter_id = e.id;') = 0
     or strpos(v_tick, 'player_integrity_current = greatest(0, v_hp_after)') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: an integrity aggregate changed (must stay hull-only, byte-identical)';
  end if;
  if strpos(v_tick, 'sum(shield') <> 0 or strpos(v_tick, 'jsonb_build_object(''shield') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: a shield term leaked into an aggregate or a report/event jsonb key';
  end if;
  -- the D1 legacy-key idiom is untouched (reports/ticks keep their exact legacy jsonb keys).
  if strpos(v_tick, 'coalesce(cu.unit_type_id, cu.main_ship_id::text)') = 0 then
    raise exception 'SHIELD-1 self-assert FAIL: the D1 jsonb key idiom changed (report keys must stay byte-identical)';
  end if;
  -- RNG discipline: the hunks added NO randomness — the head''s ONE variance call is all there is.
  v_n := (length(v_tick) - length(replace(v_tick, 'random(', ''))) / length('random(');
  if v_n <> 1 then
    raise exception 'SHIELD-1 self-assert FAIL: tick carries % random( call(s) (want exactly the head''s 1)', v_n;
  end if;
  if strpos(v_tick, 'setseed') <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: tick carries setseed (0041 determinism breach)';
  end if;

  -- (4) ACL preserved by CREATE OR REPLACE: no client role can execute either engine function.
  if has_function_privilege('authenticated', 'public.combat_create_group_encounter(uuid)', 'execute')
     or has_function_privilege('anon', 'public.combat_create_group_encounter(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.process_combat_ticks()', 'execute')
     or has_function_privilege('anon', 'public.process_combat_ticks()', 'execute') then
    raise exception 'SHIELD-1 self-assert FAIL: a client role can execute a re-created engine function';
  end if;

  -- (5) DEPLOY-TIME INERTNESS (safe on any database, including an empty CI chain): the knob is
  --     still the committed '0'; no combat row carries a shield; every instance is still 0/0; and
  --     the leaf''s missing-row semantics hold (the 0191 smoke, re-run against the wired engine).
  select value #>> '{}' into v_val from public.game_config where key = 'shield_regen_combat_pct';
  if v_val is distinct from '0' then
    raise exception 'SHIELD-1 self-assert FAIL: shield_regen_combat_pct is % (must land with the dark seed ''0'')', coalesce(v_val, '<missing>');
  end if;
  select count(*) into v_n from public.combat_units where shield_max is not null or shield_current is not null;
  if v_n <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: % combat row(s) carry a shield snapshot at migration time (want 0)', v_n;
  end if;
  select count(*) into v_n from public.main_ship_instances where shield <> 0 or max_shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: % instance row(s) off shield 0/0 at migration time (want 0)', v_n;
  end if;
  perform public.mainship_sync_combat_shield(gen_random_uuid(), 5);
  select count(*) into v_n from public.main_ship_instances where shield <> 0;
  if v_n <> 0 then
    raise exception 'SHIELD-1 self-assert FAIL: the missing-row leaf call moved % row(s) (want zero-rows semantics)', v_n;
  end if;

  raise notice 'SHIELD-1 self-assert ok: both engine re-creates present with every marked hunk (one-read snapshot + NULL/NULL gate; hoisted single knob read before the loop; regen; ONE absorb point; persisted pool; gated leaf call); old-head fingerprints gone; hull-only integrity + defeat byte-pinned; legacy jsonb keys pinned; RNG unchanged (creator 0, tick 1); client ACL closed; knob ''0'', all combat rows shield-NULL, all instances 0/0, missing-row leaf inert — deploy-inert';
end $$;
