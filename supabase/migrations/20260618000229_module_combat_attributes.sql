-- Byeharu — COMBAT SLICE 0: the MODULE-ATTRIBUTE FOUNDATION (range / projectile_speed / power /
-- ammo per module) + migrate mining's radius onto the fitted mining module. A PURE FOUNDATION
-- slice — additive columns, a backfill, ONE new read-leaf, and a byte-parity-except-one-hunk
-- re-create of `mining_extract` gated behind a NEW dark flag. NO frontend, NO new RPC surface
-- beyond the one read-leaf, NO change to any OTHER engine function.
--
-- OWNER INTENT (verbatim): "each module (mining laser, missile launcher) has its own range,
-- ammo speed, power — shown on map as a radius; the range concept is used in combat AND mining."
-- This slice lays the CATALOG foundation both future consumers (S3 spatial combat, the client map
-- radius) will read; it does NOT add combat itself (S1 runs that in parallel on different files).
--
-- ── (1) module_types += range / projectile_speed / power / ammo_type / ammo_per_shot / ──────────
-- ──     cooldown_seconds — additive, ALL NULLABLE except the two integer/rate columns (which ────
-- ──     default to the existing "this module has none of that" shape) ──────────────────────────
-- Exactly the 0111 (slot_cost/stats_json) precedent: Reference/Config catalog columns on an
-- existing public-read table. The table's posture is UNCHANGED — "module_types_public_read"
-- (0107) + the existing select grants already cover new columns; no new policy, no new grant.
-- NULL is the honest "this module has no spatial/combat reach" answer (utility/cargo/sensor/
-- engine/defense modules), so every column but the two rate integers is nullable — always safe
-- to read pre-flag, and untouched rows stay NULL after this migration with zero behavior change
-- (nothing reads these columns until the flag lights AND a future consumer is built — see (4)).
--   · range             numeric — world units of reach (map radius). NULL = no spatial reach.
--   · projectile_speed  numeric — units/sec a fired projectile travels. NULL = hitscan/laser/
--     non-combat (a mining beam or an instant-hit weapon has no travel time to model).
--   · power             numeric — weapon damage OR mining extraction rate, per shot/tick. NULL =
--     this module deals no damage and extracts nothing (every non-weapon, non-mining archetype).
--   · ammo_type         text references item_types(item_id) — the inventory item this module's
--     shots consume. NULL = energy/unlimited (every module seeded this slice: no ammo item exists
--     in the catalog yet — see the backfill note below; a future missile launcher with a tracked
--     ammo item is exactly what this column is FOR, forward-only).
--   · ammo_per_shot     integer NOT NULL DEFAULT 0 — units of ammo_type consumed per shot/tick.
--     0 is the truthful "consumes nothing" default when ammo_type is NULL, and is itself
--     inert without a companion ammo_type (a future combat consumer must treat ammo_per_shot > 0
--     with ammo_type NULL as a data error, not spend from nowhere — noted, not enforced by a CHECK
--     here: cross-column CHECKs on Reference/Config catalogs are not this table's convention).
--   · cooldown_seconds  numeric NOT NULL DEFAULT 0 — seconds between shots/ticks. 0 is the
--     truthful default for every module seeded this slice (no combat tick engine exists yet to
--     consume it — S1/S3's job).
-- CHECKs (nonneg, additive, satisfied by every existing + backfilled row): range/power/
-- projectile_speed are NULL or strictly positive (a zero-range or zero-power module is
-- meaningless — NULL is the "none" sentinel, not 0); ammo_per_shot/cooldown_seconds are >= 0.
alter table public.module_types
  add column range             numeric,
  add column projectile_speed  numeric,
  add column power             numeric,
  add column ammo_type         text references public.item_types (item_id),
  add column ammo_per_shot     integer not null default 0,
  add column cooldown_seconds  numeric not null default 0,
  add constraint module_types_range_nonneg            check (range is null or range > 0),
  add constraint module_types_power_nonneg             check (power is null or power >= 0),
  add constraint module_types_projectile_speed_nonneg  check (projectile_speed is null or projectile_speed > 0),
  add constraint module_types_ammo_per_shot_nonneg     check (ammo_per_shot >= 0),
  add constraint module_types_cooldown_seconds_nonneg  check (cooldown_seconds >= 0);

comment on column public.module_types.range is
  'COMBAT-S0: world-unit spatial reach (the map radius this module projects). NULL = no spatial '
  'reach (utility/cargo/sensor/engine/defense archetypes). Weapon modules and the mining module '
  'carry a positive value; S3 (spatial combat) and the client map radius are its consumers.';
comment on column public.module_types.projectile_speed is
  'COMBAT-S0: units/sec a fired projectile travels. NULL = hitscan/laser/non-combat (this '
  'module''s range check, if any, is instant — the mining laser and every non-weapon module).';
comment on column public.module_types.power is
  'COMBAT-S0: weapon damage OR mining extraction rate per shot/tick (shared numeric — the '
  'archetype, via slot_type, decides which). NULL = this module deals no damage and extracts '
  'nothing.';
comment on column public.module_types.ammo_type is
  'COMBAT-S0: the item_types(item_id) this module''s shots consume, if any. NULL = energy/'
  'unlimited — every module seeded through this migration, since no ammo item exists in the '
  'catalog yet. A future ammo-tracked weapon (e.g. a missile launcher) sets this forward-only.';
comment on column public.module_types.ammo_per_shot is
  'COMBAT-S0: units of ammo_type consumed per shot/tick. 0 (the default) means "consumes nothing" '
  '— truthful when ammo_type is NULL, and every module seeded this slice.';
comment on column public.module_types.cooldown_seconds is
  'COMBAT-S0: seconds between shots/ticks. 0 (the default) is truthful today — no combat tick '
  'engine consumes it yet (S1/S3''s job); weapon modules seed a positive value this slice.';

-- ── (2) BACKFILL — sane values for every seeded module type (write-once; guarded like the 0111 ──
-- ──     `stats_json = '{}'` UPDATE idiom, here guarded on `range is null and power is null and ──
-- ──     projectile_speed is null` so a re-run or a later owner rebalance is never clobbered) ────
--
-- SCALE NOTE: a world-rebalance (branch-parallel, migration 0227, NOT yet in this branch's
-- history) is uniformly 3x-ing populated-map distances — locations move from ~34–85 units out to
-- ~100–255, and territory rings from 8–30 to 24–90. Ranges below are chosen in the SAME
-- low-hundreds band so a rendered range circle reads sanely against that (soon-to-be) scale
-- without depending on it landing first — this slice reads none of that geometry, it only picks
-- numbers that will still look right once it does.
--
-- WEAPON LINE (autocannon_battery / _mk2) — range and power scale WITH the existing attack stat
-- (10 → 18, 0111/0202), so "bigger gun, bigger reach, bigger hit" is one coherent story:
--   · autocannon_battery     (attack 10): range 150, projectile_speed 300, power 10, cooldown 2s.
--   · autocannon_battery_mk2 (attack 18): range 180, projectile_speed 320, power 18, cooldown 2.5s
--     — the Mk-II fires slightly SLOWER (the 0202 "bigger guns draw more heat" narrative extended
--     to rate of fire, not just pirate attention).
--   Neither seeds ammo_type/ammo_per_shot: no ammo item exists in item_types yet (grep-verified —
--   scrap/ore/crystal/pirate_alloy/weapon_parts/engine_parts/repair_parts/captain_memory_shard/
--   blueprint_fragment/artifact_core/scan_data/anomaly_shard, 0039/0097 — none is an ammunition
--   item), so these autocannons are energy-classed today (ammo_type NULL, ammo_per_shot 0) — the
--   column exists for a FUTURE ammo-tracked weapon (a missile launcher), not retrofitted here.
--
-- MINING LINE — mining_rig_extension is the ONE existing mining-archetype module (slot_type
-- 'mining', 0183); NO new "Mining Laser" module is seeded (the recon step 2 fallback: "if NO
-- mining module type exists yet, seed one" does not apply — one already ships). range 120 (a
-- tighter reach than either weapon — a mining laser works up close, not at gunnery range) and
-- power 8 mirrors its OWN existing stats_json mining=8 (0183) — the extraction-rate number this
-- slice exposes is the SAME number the stats adapter already folds, not a second invented value.
-- projectile_speed stays NULL (a mining beam is a hitscan, not a travelling shot); cooldown 0 (no
-- per-shot pacing modeled — extraction ticks are the mining command's own cooldown, 0104/0102).
--
-- EVERYTHING ELSE (engine / cargo / sensor / defense archetypes) gets NULL range/projectile_speed/
-- power — no spatial or combat reach: vector_thruster_kit (keeps its existing evasion/
-- speed_mult_bonus in stats_json, untouched), expanded_cargo_lattice, deep_scan_sensor_array,
-- shield_lattice, shield_lattice_mk2. This UPDATE is a no-op for them (columns already default
-- NULL/0) but is written explicitly so every seeded module_type has an EXPLICIT, self-documenting
-- row in this migration — no silent "whatever the column default happens to be" module.

update public.module_types
   set range = 150, projectile_speed = 300, power = 10, cooldown_seconds = 2
 where id = 'autocannon_battery'
   and range is null and projectile_speed is null and power is null;

update public.module_types
   set range = 180, projectile_speed = 320, power = 18, cooldown_seconds = 2.5
 where id = 'autocannon_battery_mk2'
   and range is null and projectile_speed is null and power is null;

update public.module_types
   set range = 120, power = 8, cooldown_seconds = 0
 where id = 'mining_rig_extension'
   and range is null and projectile_speed is null and power is null;

-- explicit no-op rows (self-documenting; guarded identically — inert if already NULL/0)
update public.module_types
   set range = null, projectile_speed = null, power = null
 where id in ('vector_thruster_kit', 'expanded_cargo_lattice', 'deep_scan_sensor_array',
              'shield_lattice', 'shield_lattice_mk2')
   and range is null and projectile_speed is null and power is null;

-- ── (3) the dark capability flag ──────────────────────────────────────────────────────────────────
-- Server-authoritative dark gate (the 0070/0097/0102/0107/0111 idiom). Seeded 'false': every
-- consumer of these new columns (the mining_extract radius hunk below; any future S3 combat read)
-- MUST check this flag and fall back to the pre-existing byte-identical behavior while it is dark.
insert into public.game_config (key, value, description) values
  ('module_range_attributes_enabled', 'false',
   'COMBAT-S0: server-authoritative dark gate for module range/projectile_speed/power/ammo '
   'attributes actually being CONSUMED (mining_extract''s ship-module radius source; any future '
   'S3 spatial-combat read). The catalog columns themselves are always safe to read — this flag '
   'gates BEHAVIOR change only. OFF until the owner explicitly enables it; mining_extract falls '
   'back to the exact flat-750 pre-existing behavior while dark.')
on conflict (key) do nothing;

-- ── (4) ship_weapon_modules — THE read-leaf: a ship's fitted modules that carry a range ─────────
-- Composes the EXISTING fitting join verbatim (ship_module_fittings → module_instances →
-- module_types — the exact join calculate_expedition_stats already performs, 0205:539-548), owner-
-- scoped (the get_my_fleet_positions/get_my_docked_store idiom: SECURITY DEFINER + an explicit
-- `player_id = auth.uid()` filter — fail-closed to an EMPTY result for a ship you don't own, never
-- an error that could probe ship existence). This is the SINGLE query S3 (spatial combat) and the
-- client map-radius layer will both reuse — its shape is the whole point of this slice, so it
-- returns EVERY new attribute column, not just range.
create or replace function public.ship_weapon_modules(p_main_ship_id uuid)
returns table (
  module_type_id    text,
  range             numeric,
  projectile_speed  numeric,
  power             numeric,
  ammo_type         text,
  ammo_per_shot     integer,
  cooldown_seconds  numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select t.id, t.range, t.projectile_speed, t.power, t.ammo_type, t.ammo_per_shot, t.cooldown_seconds
    from public.ship_module_fittings f
    join public.module_instances i     on i.id = f.module_instance_id
    join public.module_types t         on t.id = i.module_type_id
    join public.main_ship_instances m  on m.main_ship_id = f.main_ship_id
   where f.main_ship_id = p_main_ship_id
     and m.player_id = auth.uid()
     and t.range is not null;
$$;

comment on function public.ship_weapon_modules(uuid) is
  'COMBAT-S0: a ship''s fitted modules that carry a spatial range (weapon OR mining) — the exact '
  'fitting join calculate_expedition_stats already performs, filtered to range IS NOT NULL. '
  'Owner-scoped (player_id = auth.uid()); a ship you do not own returns EMPTY, never an error. '
  'Reused by S3 (spatial combat) and the client map-radius layer — this is the ONE shape both read.';

-- house ACL idiom (0200 get_my_fleet_positions, verbatim): strip the default PUBLIC grant a new
-- function receives on create, then grant execute to authenticated only.
revoke all on function public.ship_weapon_modules(uuid) from public;
grant execute on function public.ship_weapon_modules(uuid) to authenticated;

-- ── (5) mining_extract — re-created BYTE-PARITY from the 0104 head, ONE marked hunk: the radius ──
-- ──     source. Dark (flag false): EXACT pre-existing flat-750 behavior, byte for byte. Lit: the ──
-- ──     ship's own fitted mining-module range, falling back to the flat radius if none is fitted ──
-- ──     (mining is NEVER hard-blocked for lacking a module — the recon law: additive, never a ────
-- ──     regression). Mining-module identification: slot_type = 'mining' OR a 'mining' stats_json ─
-- ──     key (either identification the recon step 4 names), so a weapon's range can NEVER leak ──
-- ──     into the mining radius even though both now carry a `range` value. ─────────────────────────
create or replace function public.mining_extract(
  p_player       uuid,
  p_main_ship_id uuid,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cmd      constant text := 'mining_extract';
  v_lock     jsonb;
  v_status   text;
  v_owner    uuid;
  v_hash     text;
  v_rcpt     main_ship_space_command_receipts%rowtype;
  v_val      jsonb;
  v_state    text;
  v_excl     jsonb;
  v_x        double precision;
  v_y        double precision;
  v_radius   double precision;
  v_field    mining_fields%rowtype;
  v_cooldown double precision;
  v_last     timestamptz;
  v_retry    integer;
  v_now      timestamptz;
  v_ext_id   uuid;
  v_result   jsonb;
begin
  -- 1) DARK GATE FIRST (0097 law / 0070 idiom): while mining_enabled is false, reject
  --    deterministically BEFORE any other read, lock, or write — no ship read, no receipt read,
  --    no field read, no extraction row.
  if not public.cfg_bool('mining_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) S2 canonical lock context (blocking; ship → fleet → coordinate movement → presence)
  v_lock := public.mainship_space_lock_context(p_main_ship_id, false);
  v_status := v_lock->>'status';
  if v_status = 'not_found' then
    return jsonb_build_object('ok', false, 'reason', 'missing_ship');
  elsif v_status <> 'locked' then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_status, 'lock_failed'));
  end if;

  -- 4) ownership from the LOCKED snapshot (never from the client)
  v_owner := (v_lock->'ship'->>'player_id')::uuid;
  if v_owner is distinct from p_player then
    return jsonb_build_object('ok', false, 'reason', 'not_owned');
  end if;

  -- 5) canonical immutable command payload + hash (extract carries NO coordinate body — 0064 stop
  --    idiom, via 0099)
  v_hash := md5(jsonb_build_object('command_type', c_cmd)::text);

  -- 6) idempotency receipt lookup AFTER the ship lock + ownership check (0064 order; reused
  --    mechanism — replay returns the FIRST committed result verbatim)
  select * into v_rcpt from main_ship_space_command_receipts
    where main_ship_id = p_main_ship_id and request_id = p_request_id;
  if found then
    if v_rcpt.command_type = c_cmd and v_rcpt.canonical_payload_hash = v_hash then
      return v_rcpt.result_json;
    else
      return jsonb_build_object('ok', false, 'reason', 'request_id_payload_conflict');
    end if;
  end if;

  -- 7) coherent-state validation under the locks; extracting requires a SETTLED in-space ship
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';
  if v_state = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'destroyed');
  elsif v_state <> 'in_space' then
    -- in_transit / at_location / home / legacy_* — one truthful reason: not settled in open space
    return jsonb_build_object('ok', false, 'reason', 'not_in_space');
  end if;

  -- 8) cross-domain exclusion (0064 arrival-processor posture, reused): the ship must not be
  --    claimed by a legacy movement / pointer conflict / location presence.
  v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id);
  if (v_excl->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_excl->>'reason', 'cross_domain_conflict'));
  end if;

  -- 9) ship position under lock (state = in_space ⇒ coordinates non-null, 0054 invariant)
  select space_x, space_y into v_x, v_y
    from main_ship_instances where main_ship_id = p_main_ship_id;

  -- 10) nearest ACTIVE field within the tunable radius; deterministic tie-break: distance, then
  --     name (0099 rule; NO discovered-filter — extraction is repeatable). Inactive fields are
  --     treated as nonexistent (0103 is_active law).
  --     ██ COMBAT-S0 HUNK (the ONLY change from the 0104 head): while
  --     module_range_attributes_enabled is dark, this is BYTE-IDENTICAL to the original single-line
  --     coalesce (the else arm below). Lit, the radius source becomes the ship's OWN best-fitted
  --     mining-module range (max over fitted modules identified by slot_type='mining' OR a
  --     'mining' stats_json key — never a weapon's range, even though both now carry a `range`
  --     value), falling back to the SAME flat cfg/750 default when no mining module is fitted —
  --     mining is NEVER hard-blocked for lacking a module. ██
  if public.cfg_bool('module_range_attributes_enabled') then
    v_radius := coalesce(
      (select max(mt.range)
         from public.ship_module_fittings smf
         join public.module_instances mi on mi.id = smf.module_instance_id
         join public.module_types mt     on mt.id = mi.module_type_id
        where smf.main_ship_id = p_main_ship_id
          and mt.range is not null
          and (mt.slot_type = 'mining' or mt.stats_json ? 'mining')),
      coalesce(public.cfg_num('mining_extract_radius'), 750));
  else
    v_radius := coalesce(public.cfg_num('mining_extract_radius'), 750);
  end if;
  select f.* into v_field
    from mining_fields f
    where f.is_active
      and public.osn_distance(v_x, v_y, f.space_x, f.space_y) <= v_radius
    order by public.osn_distance(v_x, v_y, f.space_x, f.space_y) asc, f.name asc
    limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_field_in_range');
  end if;

  -- 11) COOLDOWN (the slice-C deviation; recon decision 2): the latest extraction by this player
  --     from this field must be older than the tunable cooldown. Served by the 0103
  --     (player_id, field_id, created_at desc) index. Failure writes NO receipt (0064 posture),
  --     so retrying the same request_id after the cooldown succeeds.
  v_now := clock_timestamp();
  v_cooldown := coalesce(public.cfg_num('mining_extract_cooldown_seconds'), 300);
  select e.created_at into v_last
    from mining_extractions e
    where e.player_id = p_player and e.field_id = v_field.id
    order by e.created_at desc
    limit 1;
  if found and v_last + make_interval(secs => v_cooldown) > v_now then
    v_retry := ceil(extract(epoch from (v_last + make_interval(secs => v_cooldown) - v_now)))::integer;
    return jsonb_build_object('ok', false, 'reason', 'cooldown',
                              'retry_after_seconds', greatest(v_retry, 1));
  end if;

  -- 12) ACCRUE (never deposit): ONE extraction row per extraction (repeatable — no unique pair,
  --     no ON CONFLICT), snapshotting the field's deterministic bundle verbatim onto the
  --     activity's own state. secured_at stays NULL — the slice-D securing processor alone sets
  --     it. No inventory/base/reward/movement write happens here.
  insert into mining_extractions (player_id, field_id, main_ship_id, pending_bundle_json, created_at)
    values (p_player, v_field.id, p_main_ship_id, v_field.reward_bundle_json, v_now)
    returning id into v_ext_id;

  v_result := jsonb_build_object('ok', true,
    'extraction_id', v_ext_id,
    'field_id', v_field.id, 'name', v_field.name,
    'space_x', v_field.space_x, 'space_y', v_field.space_y,
    'pending_bundle', v_field.reward_bundle_json,
    'extracted_at', v_now, 'request_id', p_request_id);

  -- 13) finalise the idempotency receipt atomically with the extraction (0064 idiom; extract
  --     creates no movement, so movement_id stays null)
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, completed_at)
  values (p_main_ship_id, p_player, p_request_id, c_cmd, v_hash, 'success', v_result, v_now);

  return v_result;
end;
$$;

-- ── (6) command_mining_extract — HEAD-VERBATIM, unchanged (reproduced only because 0104 defines ──
-- ──     both functions in the same file and `create or replace` requires it be re-stated; the ────
-- ──     wrapper delegates every reason to mining_extract, so ITS body needs no hunk at all) ────────
create or replace function public.command_mining_extract(
  p_main_ship_id uuid,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_res    jsonb;
  v_reason text;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;

  -- flag gate FIRST (defense-in-depth + anti-probe, 0083 idiom): while dark, the answer is identical
  -- regardless of input — no hidden-field or ship info can be inferred. The writer re-checks first
  -- and is the final authority.
  if not public.cfg_bool('mining_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Mining is not available yet.');
  end if;

  -- resolve the SELECTED owned ship (explicit id, ownership asserted) or the sole ship (shim);
  -- UI selection is never trusted (0081 shared resolver).
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'no_ship', 'message', 'You do not have a main ship.');
  end if;

  -- Delegate. The writer is the final authority on flag/ownership/state/exclusion/radius/cooldown/
  -- idempotency.
  v_res := public.mining_extract(v_player, v_ship, p_request_id);

  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'extraction_id', v_res->'extraction_id',
      'field_id', v_res->'field_id',
      'name', v_res->'name',
      'space_x', v_res->'space_x',
      'space_y', v_res->'space_y',
      'pending_bundle', v_res->'pending_bundle',
      'extracted_at', v_res->'extracted_at');
  end if;

  v_reason := coalesce(v_res->>'reason', 'unavailable');
  return jsonb_build_object(
    'ok', false,
    'code', case v_reason
      when 'feature_disabled'            then 'feature_disabled'
      when 'invalid_request_id'          then 'invalid_request'
      when 'request_id_payload_conflict' then 'request_conflict'
      when 'missing_ship'                then 'no_ship'
      when 'not_owned'                   then 'no_ship'
      when 'destroyed'                   then 'ship_destroyed'
      when 'not_in_space'                then 'not_in_space'
      when 'active_legacy_movement'      then 'busy_legacy'
      when 'no_field_in_range'           then 'no_field_in_range'
      when 'cooldown'                    then 'cooldown'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'feature_disabled'            then 'Mining is not available yet.'
      when 'invalid_request_id'          then 'Invalid command request.'
      when 'request_id_payload_conflict' then 'This command was already used.'
      when 'missing_ship'                then 'You do not have a main ship.'
      when 'not_owned'                   then 'You do not have a main ship.'
      when 'destroyed'                   then 'The ship must be repaired first.'
      when 'not_in_space'                then 'The ship must be stopped in open space to extract.'
      when 'active_legacy_movement'      then 'Finish the current expedition first.'
      when 'no_field_in_range'           then 'No mineable field within extractor range.'
      when 'cooldown'                    then 'This field was mined too recently. Try again shortly.'
      else 'The ship cannot extract right now.'
    end)
    -- cooldown carries its one extra, truthful datum: seconds until the field is mineable again
    || case when v_reason = 'cooldown'
            then jsonb_build_object('retry_after_seconds', v_res->'retry_after_seconds')
            else '{}'::jsonb end;
end;
$$;

-- ── (7) ACL — HEAD-VERBATIM (0104 §3, unchanged: re-created functions lose their grants in ────────
-- ──     Postgres, so these MUST be re-stated even though nothing about them changed) ────────────────
revoke execute on function public.mining_extract(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.mining_extract(uuid, uuid, uuid) to service_role;
revoke execute on function public.command_mining_extract(uuid, uuid) from public, anon;
grant  execute on function public.command_mining_extract(uuid, uuid) to authenticated;

-- ── (8) SELF-ASSERTS — deploy-time; the migration proves its own grounding or refuses to land ──────
do $$
declare
  v_n      integer;
  v_src    text;
  v_count  integer;
begin
  -- (a) the six new columns exist with the right nullability/defaults, and the FK target is right.
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'module_types'
     and ((column_name = 'range'            and is_nullable = 'YES')
       or (column_name = 'projectile_speed' and is_nullable = 'YES')
       or (column_name = 'power'            and is_nullable = 'YES')
       or (column_name = 'ammo_type'        and is_nullable = 'YES')
       or (column_name = 'ammo_per_shot'    and is_nullable = 'NO' and column_default is not null)
       or (column_name = 'cooldown_seconds' and is_nullable = 'NO' and column_default is not null));
  if v_n <> 6 then
    raise exception 'COMBAT-S0 self-assert FAIL: % of 6 new module_types columns carry the exact expected nullability/default shape', v_n;
  end if;
  if not exists (
    select 1 from information_schema.constraint_column_usage ccu
    join information_schema.table_constraints tc
      on tc.constraint_name = ccu.constraint_name and tc.constraint_schema = ccu.constraint_schema
    where tc.table_schema = 'public' and tc.table_name = 'module_types'
      and tc.constraint_type = 'FOREIGN KEY' and ccu.table_name = 'item_types' and ccu.column_name = 'item_id'
  ) then
    raise exception 'COMBAT-S0 self-assert FAIL: module_types.ammo_type is not FK''d to item_types(item_id)';
  end if;
  -- the five nonneg CHECKs exist (by name — additive, never dropped by a future migration silently)
  select count(*) into v_n from pg_constraint
   where conrelid = 'public.module_types'::regclass
     and conname in ('module_types_range_nonneg', 'module_types_power_nonneg',
                      'module_types_projectile_speed_nonneg', 'module_types_ammo_per_shot_nonneg',
                      'module_types_cooldown_seconds_nonneg');
  if v_n <> 5 then
    raise exception 'COMBAT-S0 self-assert FAIL: % of 5 nonneg CHECK constraints present on module_types', v_n;
  end if;

  -- (b) the backfill landed EXACTLY as chosen — every seeded module_type, no strays, no drift.
  select count(*) into v_n from public.module_types
   where (id = 'autocannon_battery'     and range = 150 and projectile_speed = 300 and power = 10
          and cooldown_seconds = 2      and ammo_type is null and ammo_per_shot = 0)
      or (id = 'autocannon_battery_mk2' and range = 180 and projectile_speed = 320 and power = 18
          and cooldown_seconds = 2.5    and ammo_type is null and ammo_per_shot = 0)
      or (id = 'mining_rig_extension'   and range = 120 and projectile_speed is null and power = 8
          and cooldown_seconds = 0      and ammo_type is null and ammo_per_shot = 0);
  if v_n <> 3 then
    raise exception 'COMBAT-S0 self-assert FAIL: % of 3 combat/mining module backfills carry the exact chosen shape', v_n;
  end if;
  select count(*) into v_n from public.module_types
   where id in ('vector_thruster_kit', 'expanded_cargo_lattice', 'deep_scan_sensor_array',
                'shield_lattice', 'shield_lattice_mk2')
     and range is null and projectile_speed is null and power is null;
  if v_n <> 5 then
    raise exception 'COMBAT-S0 self-assert FAIL: % of 5 non-combat/non-mining modules kept NULL range/projectile_speed/power', v_n;
  end if;
  -- vector_thruster_kit's stats_json (speed_mult_bonus) survives UNTOUCHED (this slice never
  -- rewrites stats_json — only the new columns).
  select count(*) into v_n from public.module_types
   where id = 'vector_thruster_kit' and stats_json = '{"evasion": 3, "speed_mult_bonus": 0.1}'::jsonb;
  if v_n <> 1 then
    raise exception 'COMBAT-S0 self-assert FAIL: vector_thruster_kit stats_json was disturbed (must survive verbatim from 0111)';
  end if;

  -- (c) the flag exists, seeded dark.
  if not exists (select 1 from public.game_config
                  where key = 'module_range_attributes_enabled' and value = 'false') then
    raise exception 'COMBAT-S0 self-assert FAIL: module_range_attributes_enabled is not seeded false';
  end if;

  -- (d) the read-leaf exists, right shape, right ACL (authenticated only — never anon/public).
  if to_regprocedure('public.ship_weapon_modules(uuid)') is null then
    raise exception 'COMBAT-S0 self-assert FAIL: ship_weapon_modules(uuid) not deployed';
  end if;
  if not has_function_privilege('authenticated', 'public.ship_weapon_modules(uuid)', 'execute') then
    raise exception 'COMBAT-S0 self-assert FAIL: ship_weapon_modules not authenticated-executable';
  end if;
  if has_function_privilege('anon', 'public.ship_weapon_modules(uuid)', 'execute') then
    raise exception 'COMBAT-S0 self-assert FAIL: ship_weapon_modules is anon-executable (must not be)';
  end if;
  select prosrc into v_src from pg_proc where oid = 'public.ship_weapon_modules(uuid)'::regprocedure;
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  if position('player_id = auth.uid()' in v_src) = 0 or position('t.range is not null' in v_src) = 0 then
    raise exception 'COMBAT-S0 self-assert FAIL: ship_weapon_modules lost its owner-scope filter or the range-not-null filter';
  end if;

  -- (e) mining_extract survives BYTE-PARITY from the 0104 head except the ONE marked radius hunk.
  select prosrc into v_src from pg_proc where oid = 'public.mining_extract(uuid, uuid, uuid)'::regprocedure;
  if v_src is null then
    raise exception 'COMBAT-S0 self-assert FAIL: mining_extract(uuid,uuid,uuid) not deployed';
  end if;
  -- PROSRC-ASSERT COUPLING (0221's lesson): strip `--` line comments before probing, so a hunk
  -- comment that NAMES a retired/added literal can never trip its own ban or its own pass.
  v_src := regexp_replace(v_src, '--[^\n]*', '', 'g');
  -- every OTHER numbered step survives verbatim (anchors from steps 1,3,6,7,8,9,11,12,13):
  if position('if not public.cfg_bool(''mining_enabled'') then' in v_src) = 0
     or position('v_lock := public.mainship_space_lock_context(p_main_ship_id, false)' in v_src) = 0
     or position('v_hash := md5(jsonb_build_object(''command_type'', c_cmd)::text)' in v_src) = 0
     or position('select * into v_rcpt from main_ship_space_command_receipts' in v_src) = 0
     or position('v_val := public.mainship_space_validate_context(p_main_ship_id)' in v_src) = 0
     or position('v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id)' in v_src) = 0
     or position('select space_x, space_y into v_x, v_y' in v_src) = 0
     or position('v_cooldown := coalesce(public.cfg_num(''mining_extract_cooldown_seconds''), 300)' in v_src) = 0
     or position('insert into mining_extractions (player_id, field_id, main_ship_id, pending_bundle_json, created_at)' in v_src) = 0
     or position('insert into main_ship_space_command_receipts' in v_src) = 0 then
    raise exception 'COMBAT-S0 self-assert FAIL: mining_extract lost a surviving 0104 step outside the marked radius hunk';
  end if;
  -- the field-selection query itself (immediately around the hunk) survives verbatim too:
  if position('from mining_fields f' in v_src) = 0
     or position('where f.is_active' in v_src) = 0
     or position('public.osn_distance(v_x, v_y, f.space_x, f.space_y) <= v_radius' in v_src) = 0
     or position('order by public.osn_distance(v_x, v_y, f.space_x, f.space_y) asc, f.name asc' in v_src) = 0 then
    raise exception 'COMBAT-S0 self-assert FAIL: mining_extract''s field-selection query changed outside the marked radius hunk';
  end if;
  -- THE HUNK ITSELF: both arms present — the dark else-arm is the EXACT original one-liner, and
  -- the lit arm derives from the ship's fitted mining module with the flat radius as its fallback.
  if position('if public.cfg_bool(''module_range_attributes_enabled'') then' in v_src) = 0 then
    raise exception 'COMBAT-S0 self-assert FAIL: mining_extract does not branch on module_range_attributes_enabled';
  end if;
  -- the literal `coalesce(public.cfg_num('mining_extract_radius'), 750)` tail must appear EXACTLY
  -- twice: once as the dark else-arm (byte-identical to the 0104 head), once as the lit arm's
  -- fallback tail (same coalesce, with the module-range subquery prepended as arg 1).
  v_count := (length(v_src) - length(replace(v_src, 'coalesce(public.cfg_num(''mining_extract_radius''), 750)', '')))
             / length('coalesce(public.cfg_num(''mining_extract_radius''), 750)');
  if v_count <> 2 then
    raise exception 'COMBAT-S0 self-assert FAIL: expected the flat-750 coalesce tail exactly twice (dark else-arm + lit fallback), found %', v_count;
  end if;
  if position('mt.slot_type = ''mining'' or mt.stats_json ? ''mining''' in v_src) = 0 then
    raise exception 'COMBAT-S0 self-assert FAIL: mining_extract''s lit-arm mining-module identification (slot_type OR stats_json key) is missing';
  end if;
  if position('mt.range is not null' in v_src) = 0 then
    raise exception 'COMBAT-S0 self-assert FAIL: mining_extract''s lit-arm module subquery no longer filters to range IS NOT NULL';
  end if;
  -- a weapon module could never leak into the mining radius: neither seeded weapon carries a
  -- 'mining' stats_json key or a 'mining' slot_type — proven directly against the deployed catalog,
  -- not just trusted from the query predicate above.
  if exists (select 1 from public.module_types
              where slot_type = 'weapon' and (slot_type = 'mining' or stats_json ? 'mining')) then
    raise exception 'COMBAT-S0 self-assert FAIL: a weapon module_type carries a mining identification key — it would leak into the mining radius';
  end if;

  -- (f) ACL on mining_extract/command_mining_extract is EXACTLY the 0104 shape (never drifted by
  --     the re-create).
  if has_function_privilege('authenticated', 'public.mining_extract(uuid, uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public.mining_extract(uuid, uuid, uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.mining_extract(uuid, uuid, uuid)', 'execute') then
    raise exception 'COMBAT-S0 self-assert FAIL: mining_extract ACL drifted (must stay service_role-only)';
  end if;
  if not has_function_privilege('authenticated', 'public.command_mining_extract(uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public.command_mining_extract(uuid, uuid)', 'execute') then
    raise exception 'COMBAT-S0 self-assert FAIL: command_mining_extract ACL drifted (must stay authenticated-only)';
  end if;

  raise notice 'COMBAT-S0 self-assert ok: 6 new module_types columns (nullable range/projectile_speed/power/ammo_type, defaulted ammo_per_shot/cooldown_seconds) + 5 nonneg CHECKs + the item_types(item_id) FK; backfill exact for all 8 seeded module types (weapon line range/power scaling with attack, mining_rig_extension range 120/power 8 mirroring its own mining=8 stat, 5 others explicitly NULL); module_range_attributes_enabled seeded false; ship_weapon_modules deployed authenticated-only (never anon) composing the exact fitting join filtered to range IS NOT NULL, owner-scoped; mining_extract survives BYTE-PARITY from the 0104 head with exactly ONE marked hunk (the radius source, dark-identical / lit ship-mining-module-range-with-flat-fallback, mining-module identification by slot_type OR stats_json key) and unchanged ACL';
end $$;
