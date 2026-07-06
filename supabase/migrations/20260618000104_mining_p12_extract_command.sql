-- Byeharu — MINING-P12 SLICE C: the dark command_mining_extract write path — OSN-proximity
-- extraction → a pending mining_extractions row (bundle NOT yet deposited).
--
-- THE ENTIRE SURFACE IS DARK TODAY: mining_enabled = 'false' (0102), and the private writer
-- rejects 'feature_disabled' BEFORE any other read, lock, or write (the 0097 reject-before-any-read
-- law; 0070 idiom), with a defense-in-depth + anti-probe gate in the public wrapper too (0083 idiom —
-- a dark feature answers identically regardless of input, so no hidden-field existence can be
-- probed). Deposit wiring is deliberately NOT in this slice: extracting only ACCRUES — the securing
-- processor arrives in slice D, so a successful extraction would sit pending (unreachable today:
-- the gate rejects every call).
--
-- Mirrors the exploration scan command in its AS-BUILT form (0099 body + the 0100 changes),
-- deviating ONLY where the recon decisions require (MINING_P12_RECON.local.md §8):
--
-- (1) REPEATABILITY + COOLDOWN — THE deviation from 0099/0100: mining_extractions has no
--     unique (player_id, field_id) (0103), so there is no undiscovered-only filter and no
--     ON CONFLICT race guard (concurrent commands on the same ship are serialized by the S2 ship
--     lock; request replays are deduped by the receipt). Instead, pacing is server-enforced: the
--     latest mining_extractions.created_at for (player, field) — via the 0103
--     (player_id, field_id, created_at desc) index — must be older than
--     cfg_num('mining_extract_cooldown_seconds') (0102), else a 'cooldown' failure envelope that
--     includes the seconds remaining. Failure reasons never write a receipt (the 0064 posture), so
--     a post-cooldown retry with the same request_id succeeds deterministically.
-- (2) SELECTION RULE: the NEAREST is_active mining_fields row within
--     cfg_num('mining_extract_radius') (0102; default 750) of the ship's live space_x/space_y —
--     deterministic tie-break: distance, then name (the 0099 rule minus the discovered-filter).
--     None in range → 'no_field_in_range' (the 0099 no-target envelope shape).
-- (3) ACCRUAL LAW (docs/ACTIVITIES.md): the activity accrues pending rewards on ITS OWN state. The
--     extraction row snapshots the field's bundle verbatim (pending_bundle_json; secured_at NULL =
--     pending — deterministic composition, recon decision 4). NOTHING deposits here — no
--     inventory/base/reward write; slice D secures via reward_grant('mining', extraction_id, …).
--
-- REUSED MECHANISMS (copied from 0099/0100, not re-invented — 0064 end-to-end idiom):
--   · idempotency  = main_ship_space_command_receipts (0055; UNIQUE (main_ship_id, request_id) +
--     canonical payload hash; replay returns the first committed result_json; a same-request_id,
--     different-payload call returns request_id_payload_conflict). NO new receipt system.
--   · lock order   = the S2 canonical lock context ONLY (mainship_space_lock_context, blocking:
--     ship → fleet → coordinate movement → presence); receipt lookup AFTER ship lock + ownership
--     (the 0064 order); ownership read from the LOCKED snapshot, never from the client.
--   · settled/not-otherwise-owned = mainship_space_validate_context + the same
--     mainship_space_assert_cross_domain_exclusion the arrival processor uses.
--   · geometry     = the osn_distance leaf (0099 — "Mining later", now consumed DOWNWARD).
--
-- WRITER = the SOLE insert path of mining_extractions (docs/SYSTEM_BOUNDARIES.md synced this same
-- step; the slice-D processor will be the sole secured_at writer). Reads mining_fields DOWNWARD
-- (server-only hidden data — revealed to the caller only at the moment of extraction). No flag
-- flipped; 0001–0103 unedited.

-- ── 1) mining_extract — PRIVATE writer; SOLE insert path of mining_extractions ────────────────────
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
  v_radius := coalesce(public.cfg_num('mining_extract_radius'), 750);
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

-- ── 2) command_mining_extract — authenticated public wrapper (0083 wrapper idiom, via 0099) ───────
-- DARK TODAY: mining_enabled = 'false', so both the gate below and the writer's first check
-- reject every call — the entire surface ships server-rejected with no client UI.
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

-- ── 3) ACL (anti-cheat; targeted 0083/0095 idiom, verbatim from 0099 — the 0064-era
--       default-privileges revoke already denies new functions, these re-assert explicitly).
--       No existing grant is touched.
-- the private writer stays OFF the client surface:
revoke execute on function public.mining_extract(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.mining_extract(uuid, uuid, uuid) to service_role;
-- the ONE new client command (dark: both its gate and the writer's first check reject today):
revoke execute on function public.command_mining_extract(uuid, uuid) from public, anon;
grant  execute on function public.command_mining_extract(uuid, uuid) to authenticated;
