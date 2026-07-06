-- Byeharu — EXPLORATION-P11 SLICE E: the dark securing/deposit path — pending discoveries →
-- reward_grant('exploration', …) when the scanning ship next settles SAFE, via Exploration's OWN
-- cron processor (the docs/ACTIVITIES.md "own cron per activity" template).
--
-- DESIGN RE-DECISION (corrects the Slice-C carrier law; SYSTEM_BOUNDARIES + DEV_LOG synced this same
-- step): Slice C said exploration deposits ride movement_attach_cargo(…, 'exploration'). That is
-- UNREACHABLE for OSN-native scanning: an OSN in-space ship never traverses fleet_movements (the S2
-- posture never locks legacy movements; cross-domain exclusion rejects a ship claimed by one; OSN has
-- no HOME leg — origin_not_anchored fails closed), so the fleet carrier can never fire for it. The
-- engine contract Exploration actually reuses is one level down: **reward_grant is THE sole
-- secured-deposit owner and idempotency owner (reward_grants UNIQUE (source_type, source_id)), and
-- the activity accrues pending value on its own state until a safe arrival.** Exploration's own
-- processor therefore calls reward_grant('exploration', discovery_id, …) directly — exactly as
-- process_fleet_movements calls it for fleet returns. movement_attach_cargo remains the carrier for
-- fleet_movements-domain activities ONLY (Slice A stays correct; combat uses it today). Dependencies
-- stay acyclic and DOWNWARD: Exploration → {OSN geometry/locks (read), Main Ship (read), Bases
-- (read: deposit target), Reward (grant)}; OSN and the arrival processors are NOT edited and never
-- call into Exploration.
--
-- IN-FLIGHT SAFETY (the 0064 precedent): process_exploration_securing does NOT check
-- exploration_enabled — accrued pending value must never be stranded by an emergency flag-off. It is
-- naturally inert today: no discovery rows can exist while scan is dark (the writer's first check
-- rejects), so the processor scans an empty set. Idempotency is DOUBLE-guarded: the secured_at NULL
-- filter (fast path) + the reward_grants UNIQUE (source_type, source_id) (the law — a re-secured
-- discovery can never double-deposit even if secured_at were lost).
--
-- NO FORFEITURE in this slice: a pending discovery simply WAITS (destroyed ships secure after
-- recovery lands them home). Destruction semantics for pending exploration data are a future product
-- decision — deliberately not invented here.

-- ── 1) which ship holds the unsecured scan data ───────────────────────────────────────────────────
-- NULL is only possible for legacy/deleted-ship rows (the FK orphans on ship deletion); securing
-- falls back to the player's canonical main ship (the 0081 shared resolver) when null.
alter table public.exploration_discoveries
  add column if not exists main_ship_id uuid
  references public.main_ship_instances (main_ship_id) on delete set null;

comment on column public.exploration_discoveries.main_ship_id is
  'The ship that performed the scan and carries the unsecured data. NULL only for legacy/'
  'deleted-ship rows; process_exploration_securing falls back to the player''s canonical main ship.';

-- ── 2) exploration_scan — re-created from the 0099 body with EXACTLY TWO changes ─────────────────
--   (a) the discovery insert records main_ship_id;
--   (b) race guard: ON CONFLICT (player_id, site_id) DO NOTHING + 0 rows → 'already_discovered', so
--       a same-player concurrent scan maps to a truthful reason instead of a raw unique violation
--       (failure reasons never write a receipt — the 0064 posture — so a retry stays deterministic).
-- Everything else — dark-gate-first, S2 lock order, ownership-from-locked-snapshot, receipts
-- idempotency, validate/exclusion, nearest-site selection — is byte-identical to 0099.
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
  --     activity's own state. secured_at stays NULL — the securing processor alone sets it. No
  --     inventory/base/reward/movement write happens here. SLICE-E CHANGES: the row records the
  --     scanning ship, and the insert is race-guarded — a same-player concurrent scan of the same
  --     site resolves to a truthful 'already_discovered', never a raw unique violation.
  v_now := clock_timestamp();
  insert into exploration_discoveries (player_id, site_id, discovered_at, pending_bundle_json, main_ship_id)
    values (p_player, v_site.id, v_now, v_site.reward_bundle_json, p_main_ship_id)
    on conflict (player_id, site_id) do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'already_discovered');
  end if;

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

-- ACL re-asserted exactly as 0099 (CREATE OR REPLACE preserves it; defense-in-depth re-assert):
revoke execute on function public.exploration_scan(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.exploration_scan(uuid, uuid, uuid) to service_role;

-- ── 3) process_exploration_securing — Exploration's OWN cron processor ───────────────────────────
-- Secures pending discovery bundles once the carrying ship is settled SAFE. "Settled safe" per the
-- 0055 state model: spatial_state IN ('home','at_location') — the constraints tie these to
-- status='home' / status='stationary' (0055:151–153 / 0055:145–147) — NEVER in_transit, in_space,
-- destroyed, or legacy NULL. FOR UPDATE SKIP LOCKED + idempotent, like every processor.
create or replace function public.process_exploration_securing()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  d         record;
  v_ship    uuid;
  v_safe    boolean;
  v_base_id uuid;
  v_count   integer := 0;
begin
  for d in
    select * from exploration_discoveries
    where secured_at is null
    for update skip locked
  loop
    -- carrying ship: the recorded scanner, else the player's canonical main ship (0081 resolver).
    v_ship := d.main_ship_id;
    if v_ship is null then
      v_ship := public.mainship_resolve_owned_ship(d.player_id, null);
    end if;
    if v_ship is null then
      continue;  -- no resolvable ship: the row stays pending (never forfeited by this processor)
    end if;

    -- settled SAFE (0055 state model): docked at a location or home. Anything else waits.
    select (spatial_state in ('home', 'at_location')) into v_safe
      from main_ship_instances where main_ship_id = v_ship;
    if v_safe is not true then
      continue;
    end if;

    -- deposit target: the player's active home base (0050 idiom). NEVER grant with a null base —
    -- reward_grant would silently skip the metal half of the bundle; the row waits instead.
    select id into v_base_id
      from bases where player_id = d.player_id and status = 'active'
      order by created_at limit 1;
    if v_base_id is null then
      continue;
    end if;

    -- SECURE: the one sole depositor, exactly as the fleet return branch calls it. Idempotent by
    -- reward_grants UNIQUE (source_type, source_id) — this discovery can never double-deposit.
    perform reward_grant('exploration', d.id, d.player_id, v_base_id, d.pending_bundle_json);
    update exploration_discoveries set secured_at = now() where id = d.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Lock to server/cron (0033 idiom). Granted to service_role for the integration test runner;
-- never to clients.
revoke execute on function public.process_exploration_securing() from public, anon, authenticated;
grant  execute on function public.process_exploration_securing() to service_role;

-- ── 4) schedule every 60 seconds (0033 idiom; idempotent re-run) ─────────────────────────────────
-- Securing is not latency-sensitive; 60s matches the location-state tick's order of magnitude.
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'process-exploration-securing';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

-- pg_cron's "N seconds" form only accepts 1–59s; 60s = standard cron '* * * * *' (every minute).
select cron.schedule(
  'process-exploration-securing',
  '* * * * *',
  $$select public.process_exploration_securing();$$
);
