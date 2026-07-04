-- Byeharu — EXPLORATION-P11 POST-AUDIT FIX: convert the racing duplicate-discovery insert into a
-- clean `already_discovered` result. CREATE OR REPLACE of the exploration_scan writer ONLY; the
-- step-11 insert is the ONLY thing that changes (wrapped in a sub-block catching unique_violation).
--
-- THE GAP (post-audit item 3). exploration_scan (0099) picks the nearest UNDISCOVERED site via a
-- `not exists` pre-check (0099:181-182) and then, at step 11, does a BARE insert into
-- exploration_discoveries (0099:200-202) with NO exception handler. The table's `unique (player_id,
-- site_id)` constraint keeps a player's discovery of a site to exactly one row — but if TWO scans of
-- the SAME player race past the step-10 `not exists` pre-check for the SAME site (a TOCTOU window),
-- the second insert raises a raw `unique_violation` that propagates UNCAUGHT to the caller instead of
-- the clean `{ok:false, reason:'already_discovered'}` the pre-check already returns for the settled
-- duplicate case (0099:192).
--
-- THE FIX (exactly ONE change vs 0099). Wrap the step-11 insert in a sub-block that catches
-- `unique_violation` and returns that SAME clean `already_discovered` envelope (and, like the
-- pre-check path, writes NO receipt). The public wrapper command_exploration_scan already maps the
-- `already_discovered` reason → code/message (0099:283/296), so the caught path flows through it
-- UNCHANGED — the wrapper is NOT redefined here.
--
-- CONSERVATION WAS ALREADY PROTECTED. This is POLISH / error-handling hardening, not a
-- double-discovery fix: the `unique (player_id, site_id)` constraint is the sole authority and already
-- guaranteed at-most-one discovery row per (player, site) — the losing insert was always rejected. The
-- only defect was the SHAPE of that rejection (a raw SQL error vs the truthful `already_discovered`).
--
-- HONEST REACHABILITY (defense-in-depth today). The two concurrent scans must be DIFFERENT commands
-- (distinct request_id, so the 0055 receipt replay does not absorb them) on the SAME player at the
-- SAME site. Two in-space ships settled at the same site is what makes that concurrent — and a player
-- holds > 1 main ship only via commission_additional_main_ship (0080), which is DARK behind
-- `mainship_additional_commission_enabled='false'`. So the racing path is LATENT today (defense-in-
-- depth), becoming live only if/when multi-ship-per-player is activated — mirroring the mining 0143
-- posture. PERMANENT guard, not a shim (no retirement; multi-ship activation is its relevance trigger).
--
-- SCOPE: CREATE OR REPLACE of public.exploration_scan ONLY, its body reproduced VERBATIM from 0099
-- with the single insert wrapped. The signature, dark-flag gate, ship-lock/ownership/validation/
-- cross-domain order, receipt lookup, site selection, the pre-check `already_discovered`/
-- `no_site_in_range` branch, the success path (v_result + step-12 receipt insert + return), the
-- osn_distance leaf, the public wrapper, and all grants are UNCHANGED (CREATE OR REPLACE preserves the
-- 0099 ACL). No flag flipped — `exploration_enabled` stays 'false' (dark); 0001–0145 unedited (incl.
-- mining 0143 and ranking 0144/0145); no new table/RPC; forward-only.

-- ── exploration_scan — PRIVATE writer; SOLE writer of exploration_discoveries (0099 body, +1 wrap) ──
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
  begin
    insert into exploration_discoveries (player_id, site_id, discovered_at, pending_bundle_json)
      values (p_player, v_site.id, v_now, v_site.reward_bundle_json);
  exception when unique_violation then
    -- a concurrent scan (a DIFFERENT request_id, a second ship of this same player) already recorded
    -- this player's discovery of this site between the step-10 not-exists pre-check and this insert.
    -- Return the SAME clean 'already_discovered' result the pre-check returns (and, like it, write NO
    -- receipt) instead of surfacing a raw unique_violation. Conservation is unaffected — the row
    -- already exists exactly once (the unique (player_id, site_id) constraint is the sole authority).
    return jsonb_build_object('ok', false, 'reason', 'already_discovered');
  end;

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
