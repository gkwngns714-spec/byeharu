-- Byeharu — MINING-P12 SLICE D: the dark securing/deposit path — pending extractions →
-- reward_grant('mining', …) when the extracting ship next settles SAFE, via Mining's OWN cron
-- processor (the docs/ACTIVITIES.md "own cron per activity" template; mirrors the exploration
-- securing processor 0100 exactly — mining's as-built extraction rows already model the lifecycle
-- the same way (secured_at NULL = pending, 0103), so the processor shape carries over verbatim).
--
-- ENGINE CONTRACT (the 0100 re-decision, reused as-is): OSN-native activities never traverse
-- fleet_movements, so the fleet carrier (movement_attach_cargo) can never fire for them. The
-- contract Mining reuses is one level down: **reward_grant is THE sole secured-deposit owner and
-- idempotency owner (reward_grants UNIQUE (source_type, source_id)), and the activity accrues
-- pending value on its own state until a safe arrival.** Mining's own processor therefore calls
-- reward_grant('mining', extraction_id, …) directly — exactly as process_exploration_securing
-- calls it for discoveries. Dependencies stay acyclic and DOWNWARD: Mining → {OSN state (read),
-- Main Ship (read), Bases (read: deposit target), Reward (grant)}; OSN and the arrival processors
-- are NOT edited and never call into Mining.
--
-- IN-FLIGHT SAFETY (the 0064/0100 precedent): process_mining_securing does NOT check
-- mining_enabled — accrued pending value must never be stranded by an emergency flag-off. It is
-- naturally inert today: no extraction rows can exist while the command is dark (the 0104 writer's
-- first check rejects), so the processor sweeps an empty set. Idempotency is DOUBLE-guarded: the
-- secured_at NULL filter (fast path) + the reward_grants UNIQUE (source_type, source_id) (the law —
-- a re-secured extraction can never double-deposit even if secured_at were lost).
--
-- SLICE-C REVIEW NOTE (recorded here so it is not lost): the 0104 cooldown is serialized per SHIP
-- via the S2 lock, not per player — two ships owned by one player could theoretically interleave
-- cooldown checks. Acceptable today: the canonical model is one main ship per player (multi-ship
-- stays DARK behind mainship_additional_commission_enabled=false), and no double-deposit is
-- possible regardless (receipts + the reward_grants unique key). Revisit if multi-main-ship ever
-- activates.
--
-- NO FORFEITURE in this slice: a pending extraction simply WAITS (destroyed ships secure after
-- recovery lands them home). Destruction semantics for pending mining yield are a future product
-- decision — deliberately not invented here (the 0100 posture, recon decision 4).

-- ── 1) process_mining_securing — Mining's OWN cron processor ─────────────────────────────────────
-- Secures pending extraction bundles once the extracting ship is settled SAFE. "Settled safe" per
-- the 0055 state model: spatial_state IN ('home','at_location') — the constraints tie these to
-- status='home' / status='stationary' (0055:151–153 / 0055:145–147) — NEVER in_transit, in_space,
-- destroyed, or legacy NULL. FOR UPDATE SKIP LOCKED + idempotent, like every processor.
create or replace function public.process_mining_securing()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  e         record;
  v_ship    uuid;
  v_safe    boolean;
  v_base_id uuid;
  v_count   integer := 0;
begin
  for e in
    select * from mining_extractions
    where secured_at is null
    for update skip locked
  loop
    -- carrying ship: the recorded extractor, else the player's canonical main ship (0081 resolver;
    -- NULL is only possible for deleted-ship rows — the FK orphans on ship deletion).
    v_ship := e.main_ship_id;
    if v_ship is null then
      v_ship := public.mainship_resolve_owned_ship(e.player_id, null);
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
    -- reward_grant would silently skip a scalar half of the bundle; the row waits instead. (Mining
    -- bundles are items-only by decision 3, but the guard is kept verbatim from 0100 — one
    -- pattern, not two, and it also shields against a malformed future seed.)
    select id into v_base_id
      from bases where player_id = e.player_id and status = 'active'
      order by created_at limit 1;
    if v_base_id is null then
      continue;
    end if;

    -- SECURE: the one sole depositor, exactly as the fleet return branch and the exploration
    -- processor call it. Idempotent by reward_grants UNIQUE (source_type, source_id) — this
    -- extraction can never double-deposit.
    perform reward_grant('mining', e.id, e.player_id, v_base_id, e.pending_bundle_json);
    update mining_extractions set secured_at = now() where id = e.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Lock to server/cron (0033 idiom, via 0100). Granted to service_role for the integration test
-- runner; never to clients.
revoke execute on function public.process_mining_securing() from public, anon, authenticated;
grant  execute on function public.process_mining_securing() to service_role;

-- ── 2) schedule every 60 seconds (0033/0100 idiom; idempotent re-run) ─────────────────────────────
-- Securing is not latency-sensitive; 60s matches the exploration securing cadence.
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'process-mining-securing';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

-- pg_cron's "N seconds" form only accepts 1–59s; 60s = standard cron '* * * * *' (every minute).
select cron.schedule(
  'process-mining-securing',
  '* * * * *',
  $$select public.process_mining_securing();$$
);
