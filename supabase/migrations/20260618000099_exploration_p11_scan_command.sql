-- Byeharu — EXPLORATION-P11 SLICE D: the dark command_exploration_scan write path — OSN-proximity
-- scan → per-player discovery with a PENDING (not yet deposited) reward bundle.
--
-- THE ENTIRE SURFACE IS DARK TODAY: exploration_enabled = 'false' (0097), and the private writer
-- rejects 'feature_disabled' BEFORE any other read, lock, or write (the 0097 reject-before-any-read
-- law; 0070 idiom), with a defense-in-depth + anti-probe gate in the public wrapper too (0083 idiom —
-- a dark feature answers identically regardless of input, so no hidden-site existence can be probed).
-- Deposit wiring is deliberately NOT in this slice: scanning only ACCRUES.
--
-- (1) GEOMETRY IS OSN'S CONCERN; Exploration depends on it DOWNWARD. One new pure IMMUTABLE leaf
--     osn_distance(ax,ay,bx,by) — the exact euclidean formula the movement writers already use
--     inline (`sqrt(power(bx-ax,2)+power(by-ay,2))` — 0007:105, 0057:179, 0067:319). The shipped
--     movement-writer bodies are NOT re-created just to swap their one-line inline sqrt: a single
--     arithmetic expression is below the duplication bar, and re-creating proven critical writers
--     for a cosmetic swap adds regression risk with zero behavior gain. Future re-definitions of
--     those writers should adopt this helper when next touched for real changes.
-- (2) ACCRUAL LAW (docs/ACTIVITIES.md): the activity accrues pending rewards on ITS OWN state. The
--     discovery row snapshots the site's bundle at scan time (pending_bundle_json; secured_at NULL =
--     pending). NOTHING deposits here — no inventory/base/reward write. The deposit-on-arrival
--     wiring through the Slice-A activity-agnostic carrier comes in the NEXT slice.
-- (3) SCAN PRECONDITIONS: the ship must be OSN in-space — SETTLED (validate_context state
--     = 'in_space', which the 0055 constraints tie to status='stationary'), not in transit, not
--     docked, and not claimed by another domain (the 0064 cross-domain-exclusion posture, reused,
--     not re-derived) — and within cfg_num('exploration_scan_radius') (default 750; same order as
--     the world's port/proximity scales; tunable without redeploy per the game_config philosophy)
--     of an is_active site the player has not discovered.
--
-- REUSED MECHANISMS (copied, not re-invented — 0064 end-to-end idiom):
--   · idempotency  = main_ship_space_command_receipts (0055; UNIQUE (main_ship_id, request_id) +
--     canonical payload hash; replay returns the first committed result_json; a same-request_id,
--     different-payload call returns request_id_payload_conflict). NO new receipt system.
--   · lock order   = the S2 canonical lock context ONLY (mainship_space_lock_context, blocking:
--     ship → fleet → coordinate movement → presence); receipt lookup AFTER ship lock + ownership
--     (the 0064 order); ownership read from the LOCKED snapshot, never from the client.
--   · settled/not-otherwise-owned = mainship_space_validate_context + the same
--     mainship_space_assert_cross_domain_exclusion the arrival processor uses.
--
-- WRITER = SOLE WRITER of exploration_discoveries (docs/SYSTEM_BOUNDARIES.md synced this same step).
-- Reads exploration_sites DOWNWARD (server-only hidden data — revealed to the caller only at the
-- moment of discovery). No flag flipped; 0001–0098 unedited.

-- ── 1) osn_distance — the OSN geometry leaf (pure, IMMUTABLE, owns no table) ──────────────────────
-- Consumed DOWNWARD by activities (Exploration now, Mining later). Internal posture: no client
-- execute grant (service_role for CI parity with the other OSN helpers).
create or replace function public.osn_distance(
  ax double precision, ay double precision, bx double precision, by double precision)
returns double precision
language sql
immutable
strict
set search_path = public
as $$
  select sqrt(power(bx - ax, 2) + power(by - ay, 2));
$$;

-- ── 2) exploration_discoveries: the pending-bundle accrual state ──────────────────────────────────
-- The '{}'::jsonb column default is a MIGRATION-VALIDITY SHIM only (lets the ALTER apply against any
-- pre-existing rows); its retirement is behavioral, not schema: the sole writer below ALWAYS
-- snapshots a real site bundle, so no new row ever relies on the default.
alter table public.exploration_discoveries
  add column pending_bundle_json jsonb not null default '{}'::jsonb,
  add column secured_at timestamptz;

alter table public.exploration_discoveries
  add constraint exploration_discoveries_pending_bundle_object
  check (jsonb_typeof(pending_bundle_json) = 'object');

comment on column public.exploration_discoveries.pending_bundle_json is
  'Snapshot of the site''s reward bundle ({metal?, items[]}) taken at scan time — PENDING, not '
  'deposited. Secured through the engine carrier on home arrival by the deposit slice.';
comment on column public.exploration_discoveries.secured_at is
  'NULL = pending. Set ONLY by the deposit slice''s securing path (never by the scan writer).';

-- ── 3) tunable scan radius (game_config philosophy: balance without redeploy) ─────────────────────
insert into public.game_config (key, value, description) values
  ('exploration_scan_radius', '750',
   'EXPLORATION-P11: maximum osn_distance (world units) between a settled in-space main ship and an '
   'undiscovered active exploration_sites row for command_exploration_scan to discover it.')
on conflict (key) do nothing;

-- ── 4) exploration_scan — PRIVATE writer; SOLE writer of exploration_discoveries ──────────────────
create or replace function public.exploration_scan(
  p_player       uuid,
  p_main_ship_id uuid,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cmd    constant text := 'exploration_scan';
  v_lock   jsonb;
  v_status text;
  v_owner  uuid;
  v_hash   text;
  v_rcpt   main_ship_space_command_receipts%rowtype;
  v_val    jsonb;
  v_state  text;
  v_excl   jsonb;
  v_x      double precision;
  v_y      double precision;
  v_radius double precision;
  v_site   exploration_sites%rowtype;
  v_now    timestamptz;
  v_result jsonb;
begin
  -- 1) DARK GATE FIRST (0097 law / 0070 idiom): while exploration_enabled is false, reject
  --    deterministically BEFORE any other read, lock, or write — no ship read, no receipt read,
  --    no site read, no discovery row.
  if not public.cfg_bool('exploration_enabled') then
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

  -- 5) canonical immutable command payload + hash (scan carries NO coordinate body — 0064 stop idiom)
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

  -- 7) coherent-state validation under the locks; scanning requires a SETTLED in-space ship
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

  -- 10) nearest undiscovered ACTIVE site within the tunable radius; deterministic tie-break:
  --     distance, then name. Inactive sites are treated as nonexistent (0098 is_active law).
  v_radius := coalesce(public.cfg_num('exploration_scan_radius'), 750);
  select s.* into v_site
    from exploration_sites s
    where s.is_active
      and public.osn_distance(v_x, v_y, s.space_x, s.space_y) <= v_radius
      and not exists (select 1 from exploration_discoveries d
                      where d.player_id = p_player and d.site_id = s.id)
    order by public.osn_distance(v_x, v_y, s.space_x, s.space_y) asc, s.name asc
    limit 1;
  if not found then
    -- simplest truthful reason set: an in-range active site exists but every one is already
    -- this player's discovery → already_discovered; otherwise → no_site_in_range. Neither leaks
    -- undiscovered-site existence beyond what the player has legitimately learned.
    if exists (select 1 from exploration_sites s
               where s.is_active
                 and public.osn_distance(v_x, v_y, s.space_x, s.space_y) <= v_radius) then
      return jsonb_build_object('ok', false, 'reason', 'already_discovered');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_site_in_range');
  end if;

  -- 11) ACCRUE (never deposit): record the discovery with the PENDING bundle snapshot on the
  --     activity's own state. secured_at stays NULL — the deposit slice's securing path alone
  --     sets it. No inventory/base/reward/movement write happens here.
  v_now := clock_timestamp();
  insert into exploration_discoveries (player_id, site_id, discovered_at, pending_bundle_json)
    values (p_player, v_site.id, v_now, v_site.reward_bundle_json);

  v_result := jsonb_build_object('ok', true,
    'site_id', v_site.id, 'name', v_site.name,
    'space_x', v_site.space_x, 'space_y', v_site.space_y,
    'pending_bundle', v_site.reward_bundle_json,
    'discovered_at', v_now, 'request_id', p_request_id);

  -- 12) finalise the idempotency receipt atomically with the discovery (0064 idiom; scan creates
  --     no movement, so movement_id stays null)
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, completed_at)
  values (p_main_ship_id, p_player, p_request_id, c_cmd, v_hash, 'success', v_result, v_now);

  return v_result;
end;
$$;

-- ── 5) command_exploration_scan — authenticated public wrapper (0083 wrapper idiom) ───────────────
-- DARK TODAY: exploration_enabled = 'false', so both the gate below and the writer's first check
-- reject every call — the entire surface ships server-rejected with no client UI.
create or replace function public.command_exploration_scan(
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
  -- regardless of input — no hidden-site or ship info can be inferred. The writer re-checks first
  -- and is the final authority.
  if not public.cfg_bool('exploration_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Exploration is not available yet.');
  end if;

  -- resolve the SELECTED owned ship (explicit id, ownership asserted) or the sole ship (shim);
  -- UI selection is never trusted (0081 shared resolver).
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'no_ship', 'message', 'You do not have a main ship.');
  end if;

  -- Delegate. The writer is the final authority on flag/ownership/state/exclusion/radius/idempotency.
  v_res := public.exploration_scan(v_player, v_ship, p_request_id);

  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'site_id', v_res->'site_id',
      'name', v_res->'name',
      'space_x', v_res->'space_x',
      'space_y', v_res->'space_y',
      'pending_bundle', v_res->'pending_bundle',
      'discovered_at', v_res->'discovered_at');
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
      when 'no_site_in_range'            then 'no_site_in_range'
      when 'already_discovered'          then 'already_discovered'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'feature_disabled'            then 'Exploration is not available yet.'
      when 'invalid_request_id'          then 'Invalid command request.'
      when 'request_id_payload_conflict' then 'This command was already used.'
      when 'missing_ship'                then 'You do not have a main ship.'
      when 'not_owned'                   then 'You do not have a main ship.'
      when 'destroyed'                   then 'The ship must be repaired first.'
      when 'not_in_space'                then 'The ship must be stopped in open space to scan.'
      when 'active_legacy_movement'      then 'Finish the current expedition first.'
      when 'no_site_in_range'            then 'No signal detected within scanner range.'
      when 'already_discovered'          then 'Every signal in range has already been discovered.'
      else 'The ship cannot scan right now.'
    end);
end;
$$;

-- ── 6) ACL (anti-cheat; targeted 0083/0095 idiom — the 0064-era default-privileges revoke already
--       denies new functions, these re-assert explicitly). No existing grant is touched.
-- the geometry leaf + private writer stay OFF the client surface:
revoke execute on function public.osn_distance(double precision, double precision, double precision, double precision) from public, anon, authenticated;
grant  execute on function public.osn_distance(double precision, double precision, double precision, double precision) to service_role;
revoke execute on function public.exploration_scan(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.exploration_scan(uuid, uuid, uuid) to service_role;
-- the ONE new client command (dark: both its gate and the writer's first check reject today):
revoke execute on function public.command_exploration_scan(uuid, uuid) from public, anon;
grant  execute on function public.command_exploration_scan(uuid, uuid) to authenticated;
