-- Byeharu — MINING-P12 POST-AUDIT FIX: close the double-extract race in the mining_extract writer.
--
-- THE RACE (item 1 of the post-audit punch list). The per-(player, field) cooldown at 0104 step 11
-- is a read-then-insert: the writer reads the latest mining_extractions.created_at for (player,
-- field) and, if older than the cooldown, inserts a new extraction. The S2 canonical ship lock
-- (mainship_space_lock_context) serializes commands on the SAME ship only — it locks the caller's
-- OWN ship row. So two DIFFERENT ships owned by the SAME player, both settled within extractor range
-- of the SAME field, take locks on distinct ship rows and never contend. Both could therefore read
-- an empty (or equally-stale) cooldown history and both insert — a double extraction, i.e. a
-- double-reward window once the slice-D securing processor deposits both pending bundles.
--
-- THE FIX (exactly ONE change vs 0104). Add a transaction-scoped advisory lock keyed on
-- (player, field), acquired AFTER the field is resolved into v_field (and after the dark-flag,
-- ship-lock, ownership, settled/in-space, and cross-domain checks) but IMMEDIATELY BEFORE the
-- cooldown read. Two commands for the same (player, field) now serialize here: the second blocks
-- until the first COMMITS, then reads the first's now-committed extraction row at step 11 and is
-- correctly 'cooldown'-rejected. The double-extract window is closed.
--
-- IDIOM REUSED (not re-invented): the established two-arg advisory-lock pattern
--   pg_advisory_xact_lock(hashtext('<domain>'), hashtext('<scope>'))
-- already used across the codebase (0078, 0113, 0126, 0133). Domain = 'mining_extract', scope =
-- the combined (player, field) key. Xact-scoped ⇒ auto-released at commit/rollback (no cleanup path,
-- no softlock risk) and reentrant within the transaction (harmless alongside the existing S2 row
-- locks). This is a PERMANENT correctness guard — NOT a shim, with no retirement condition.
--
-- SCOPE: CREATE OR REPLACE of public.mining_extract ONLY, its body reproduced VERBATIM from 0104
-- with the single lock line inserted. The signature, dark-flag gate, ship-lock/ownership order,
-- receipt/idempotency logic, cooldown math, selection rule, accrual/reward math, the public wrapper
-- command_mining_extract, and all grants are UNCHANGED (CREATE OR REPLACE preserves the 0104 ACL).
-- No flag flipped — mining_enabled stays 'false' (dark); 0001–0142 unedited; no new RPC or table.

-- ── mining_extract — PRIVATE writer; SOLE insert path of mining_extractions (0104 body, +1 lock) ──
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

  -- 10b) SERIALIZE same-player extractions on the SAME field (0143 correctness guard — the ONLY
  --      change vs 0104). The S2 ship lock (step 3) locks the caller's OWN ship row, so two
  --      DIFFERENT ships of the same player at the same field never contend there — leaving a
  --      read-then-insert double-extract window at step 11. This xact-scoped advisory lock keyed on
  --      (player, field) closes it: the second command blocks here until the first COMMITS, then
  --      reads the first's now-committed extraction below and is correctly 'cooldown'-rejected.
  --      Reuses the codebase idiom hashtext(<domain>), hashtext(<scope>) (0078/0113/0126/0133);
  --      xact-scoped ⇒ auto-released at commit/rollback (no cleanup, no softlock) and reentrant
  --      alongside the existing row locks. PERMANENT guard — not a shim, no retirement condition.
  perform pg_advisory_xact_lock(hashtext('mining_extract'), hashtext(p_player::text || ':' || v_field.id::text));

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
