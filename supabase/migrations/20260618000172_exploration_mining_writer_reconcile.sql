-- Byeharu — EXPLORATION/MINING WRITER RECONCILE: repair two stale-body re-creates found by the
-- activation-slice adversarial review. BOTH writers are re-created from their TRUE current heads
-- with the dropped features merged back. No flag flipped (exploration_enabled / mining_enabled /
-- world_balance_enabled all stay 'false' — both writers reject at their first line today, so these
-- re-creates are not live-risky); no new table/RPC; forward-only; 0001–0171 unedited.
--
-- THE TWO REGRESSIONS (same failure class: a "verbatim" re-create copied a STALE body, silently
-- reverting a later migration's changes):
--
--   H1 (exploration, launch-blocker for the flip). 0146 said "reproduced VERBATIM from 0099" — but
--   0100 had already re-created exploration_scan with the discoveries insert recording
--   main_ship_id (0100:170). The deployed (0146) head therefore inserts WITHOUT main_ship_id, so
--   every new discovery falls to the process_exploration_securing NULL-ship fallback
--   mainship_resolve_owned_ship(player, null) — which by design resolves ONLY when the player owns
--   EXACTLY one ship (0081:47-51) and returns null otherwise, making the processor `continue`
--   (0100:223-228) FOREVER. Multi-ship commissioning is LIVE (the 2026-07-12 team flip), so the
--   day exploration flips, any player with 2+ ships would strand every discovery's rewards
--   permanently. Fixed here: the 0146 head body with ONE marked hunk — the insert records
--   main_ship_id again (the exact 0100:170 column set), KEEPING the 0146 unique_violation handler.
--
--   H2 (mining, kills P19 field depletion at activation). 0143 said "reproduced VERBATIM from
--   0104" — but 0137 (WORLD-BALANCE-P19 slice 3) had already re-created mining_extract with the
--   field-depletion integration: the reserve-scaled bundle (step 11.5: worldstate_field_remaining
--   → per-item greatest(1, round(qty*reserve))) and the exactly-once deplete call (step 12.5:
--   worldstate_deplete_field). The deployed (0143) head has ZERO depletion hooks and
--   worldstate_deplete_field has NO caller — latent only while world_balance_enabled='false', but
--   it silently kills the P19 depletion subsystem the day world balance lights. Fixed here: the
--   0143 head body (advisory lock kept) with the 0137 hunks re-merged verbatim.
--
-- THE SYSTEMIC LESSON (recorded so it stops recurring — both regressions came from the same
-- mistake): a CREATE OR REPLACE re-create MUST start from the TRUE head body — grep ALL later
-- migrations for the function name before copying a body (the parity-re-create law exists for
-- exactly this). 0146 copied 0099 over 0100; 0143 copied 0104 over 0137.
--
-- PROSRC-ASSERT COUPLING (deliberate; do not "clean up" these literals): the human activation
-- scripts (scripts/activate-exploration.sql / scripts/activate-mining.sql) gate the flips on
-- pg_proc.prosrc of the DEPLOYED writers containing these exact tokens:
--   exploration_scan: 'unique_violation' + 'already_discovered'  (the 0146 guard) AND
--                     'pending_bundle_json, main_ship_id'         (this H1 fix — the discoveries
--                      insert column list; 'main_ship_id' alone is NOT discriminating, it appears
--                      in the receipt columns of every body including the broken 0146 one)
--   mining_extract:   'pg_advisory_xact_lock'                     (the 0143 guard) AND
--                     'worldstate_deplete_field'                  (this H2 fix)
-- Any future re-create of either writer must keep those tokens (or update the activation scripts
-- in the same change).
--
-- SCOPE: CREATE OR REPLACE of public.exploration_scan and public.mining_extract ONLY, each
-- reproduced from its head (0146 / 0143) with ONLY the marked RESTORE hunks changed (diff-verified
-- against the head bodies in the shipping slice). Signatures, gates, lock orders, receipts,
-- selection rules, ACLs (re-asserted below per precedent) all unchanged.

-- ═══════════ 1) exploration_scan — the 0146 head body + the marked 0100 main_ship_id restore ═══════
-- PRIVATE writer; SOLE writer of exploration_discoveries. Everything below is byte-identical to
-- 0146 except the single ── H1 RESTORE ── hunk at step 11.
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
  --     ── H1 RESTORE (this migration's ONLY exploration change) ──: the insert records
  --     main_ship_id again — the exact 0100:170 column set that 0146's stale-body re-create
  --     dropped. Without it every discovery relies on the NULL-ship securing fallback, which
  --     resolves only for single-ship owners (0081) — multi-ship players' rewards would strand
  --     forever. The 0146 unique_violation handler is KEPT verbatim. PROSRC-ASSERT COUPLING:
  --     scripts/activate-exploration.sql asserts this body contains the unique_violation handler
  --     and the restored insert column list (the pending-bundle column immediately followed by the
  --     ship column — deliberately NOT spelled out here so a comment can never satisfy the assert;
  --     see the 0172 file header for the exact token).
  v_now := clock_timestamp();
  begin
    insert into exploration_discoveries (player_id, site_id, discovered_at, pending_bundle_json, main_ship_id)
      values (p_player, v_site.id, v_now, v_site.reward_bundle_json, p_main_ship_id);
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

-- ACL re-asserted exactly as 0099/0100 (CREATE OR REPLACE preserves it; defense-in-depth re-assert):
revoke execute on function public.exploration_scan(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.exploration_scan(uuid, uuid, uuid) to service_role;

-- ═══════════ 2) mining_extract — the 0143 head body + the marked 0137 depletion re-merge ═══════════
-- PRIVATE writer; SOLE insert path of mining_extractions. Everything below is byte-identical to
-- 0143 except the ── H2 RESTORE ── hunks (the 0137 depletion locals, step 11.5, the v_bundle swap
-- in step 12 + the result envelope, and step 12.5). The 0143 step-10b advisory lock is KEPT
-- verbatim (prosrc-assert coupling: scripts/activate-mining.sql requires the literals
-- 'pg_advisory_xact_lock' and 'worldstate_deplete_field' in this body).
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
  -- ── H2 RESTORE ── WORLD-BALANCE-P19 (field depletion, 0137) locals — used ONLY inside the
  -- flag-gated blocks below; dropped by 0143's stale-body re-create, re-merged here.
  v_wb       boolean;
  v_reserve  numeric;
  v_bundle   jsonb;
  v_items    jsonb;
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

  -- 10b) SERIALIZE same-player extractions on the SAME field (0143 correctness guard — KEPT
  --      verbatim). The S2 ship lock (step 3) locks the caller's OWN ship row, so two DIFFERENT
  --      ships of the same player at the same field never contend there — leaving a
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

  -- 11.5) ── H2 RESTORE ── WORLD-BALANCE-P19 FIELD DEPLETION (0137, re-merged verbatim; dark unless
  --       world_balance_enabled). ENTIRELY gated so mining is byte-identical while dark: v_bundle
  --       defaults to the field bundle VERBATIM; only when the flag is on do we scale each item qty
  --       by the current reserve (diminishing returns, per-item floor of 1). reserve is READ
  --       (DOWNWARD) BEFORE this extraction's depletion, so the bundle reflects the pre-extraction
  --       reserve. worldstate_field_remaining is itself flag-gated (returns 1.0 while dark) —
  --       defense in depth.
  v_bundle := v_field.reward_bundle_json;
  v_wb := coalesce(public.cfg_bool('world_balance_enabled'), false);
  if v_wb then
    v_reserve := public.worldstate_field_remaining(v_field.id);
    select coalesce(jsonb_agg(
             jsonb_build_object('item_id',  it->>'item_id',
                                'quantity', greatest(1, round((it->>'quantity')::numeric * v_reserve)))
             order by ord), '[]'::jsonb)
      into v_items
      from jsonb_array_elements(v_field.reward_bundle_json->'items') with ordinality as t(it, ord);
    v_bundle := v_field.reward_bundle_json || jsonb_build_object('items', v_items);
  end if;

  -- 12) ACCRUE (never deposit): ONE extraction row per extraction (repeatable — no unique pair,
  --     no ON CONFLICT), snapshotting the (── H2 RESTORE ── depletion-scaled) v_bundle onto the
  --     activity's own state. secured_at stays NULL — the slice-D securing processor alone sets it.
  insert into mining_extractions (player_id, field_id, main_ship_id, pending_bundle_json, created_at)
    values (p_player, v_field.id, p_main_ship_id, v_bundle, v_now)
    returning id into v_ext_id;

  -- 12.5) ── H2 RESTORE ── WORLD-BALANCE-P19 (0137): deplete the field EXACTLY ONCE per REAL
  --        extraction. Placed in the success path right after the row insert (unreachable on
  --        replay — a replay returned at step 6), so no double-deplete. The deplete leaf is itself
  --        flag-gated (no-op while dark), and this call is additionally inside `if v_wb` so mining
  --        is byte-identical while dark. PROSRC-ASSERT COUPLING: scripts/activate-mining.sql
  --        asserts this body contains the deplete-leaf call below (the comment above deliberately
  --        avoids naming it, so a comment can never satisfy the assert).
  if v_wb then
    perform public.worldstate_deplete_field(v_field.id);
  end if;

  v_result := jsonb_build_object('ok', true,
    'extraction_id', v_ext_id,
    'field_id', v_field.id, 'name', v_field.name,
    'space_x', v_field.space_x, 'space_y', v_field.space_y,
    'pending_bundle', v_bundle,
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

-- Re-assert the private writer ACL (CREATE OR REPLACE keeps it; restated per the 0104/0137/0143
-- precedent).
revoke execute on function public.mining_extract(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.mining_extract(uuid, uuid, uuid) to service_role;
