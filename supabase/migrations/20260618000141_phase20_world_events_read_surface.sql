-- Byeharu — PHASE20-POLISH SLICE 3: the World Events READ surface — get_world_events(...) — the ONLY
-- client path to world_events (the RLS-locked, client-revoked table from 0139). Read-only; no write
-- anywhere; flag-gated fail-closed like every dark read surface. This is the CONSUMER; the producer
-- (world_events_publish / world_events_set_active, 0140) shipped first (the 0133→0134, 0099→0101 order).
--
-- Mirrors the exploration/mining read surfaces (0101 / 0106) and get_market_offers (0087) for the
-- SECURITY DEFINER + flag-gate-first + jsonb `{ok, events:[...]}` envelope idiom — the SAME return
-- convention those surfaces use; no new convention invented.
--
-- SELF-APPROVED LOCKED DESIGN DECISION (owner-directed, STEP 3; recorded in docs/DEV_LOG.md +
-- docs/SYSTEM_BOUNDARIES.md this SAME step): the DISPLAY CONTEXT (`p_location_id` / `p_zone_id`) is
-- PASSED BY THE CLIENT — the coordinates it already holds from the map — rather than resolved from the
-- player's ship position server-side. World events are PUBLIC presentational world info (no per-player
-- secret, no cheat vector — unlike the hidden exploration_sites/mining_fields, which MUST resolve
-- server-side), so a parameterized read keeps World Events a PURE downward LEAF: it reads ONLY its own
-- `world_events` table + the `phase20_polish_enabled` master flag, adding NO cross-system call-edge to
-- Main-Ship / Presence. The server stays authoritative over WHAT IS SHOWN — the flag gate + `is_active`
-- + the active-time-window — which is the only authority that matters for presentational info.
--
-- FAIL-CLOSED: while `phase20_polish_enabled` is false the RPC returns an EMPTY events array WITHOUT
-- reading the table — the "server-rejected while dark" proof, and the read-side consumer of the master
-- flag (0139). The frontend renders nothing while dark; no special-casing needed.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): §2 World Events gains `get_world_events`
-- under "exposes" (read-only, flag-gated → empty while dark; reads ONLY `world_events` + the master
-- flag; the client passes display context, so NO new cross-system call-edge). Still a downward leaf —
-- writes nothing, grants nothing. Leaves `0001–0140` unedited; forward-only.

create or replace function public.get_world_events(
  p_location_id uuid default null,
  p_zone_id     uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_events jsonb;
  c_empty  constant jsonb := '[]'::jsonb;
begin
  -- DARK server fail-closed FIRST (0097 reject-before-any-read law; 0087/0101/0106 idiom): while
  -- phase20_polish_enabled is false, return an EMPTY result BEFORE any table read — nothing is shown,
  -- and the world_events table is not even touched. World events are public presentational info, so the
  -- dark answer is an empty list (ok:true, events:[]), not a reject envelope — the frontend renders
  -- nothing while dark.
  if not coalesce(public.cfg_bool('phase20_polish_enabled'), false) then
    return jsonb_build_object('ok', true, 'events', c_empty);
  end if;

  -- read-only: only events that are BOTH currently LIVE (is_active + within the active time window)
  -- AND IN SCOPE for the client's display context (global always; zone/location only when the caller
  -- passed the matching id). Presentational columns only. Deterministic order: severity rank
  -- (critical → warning → info) then newest first. Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',          w.id,
           'event_type',  w.event_type,
           'scope',       w.scope,
           'zone_id',     w.zone_id,
           'location_id', w.location_id,
           'title',       w.title,
           'body',        w.body,
           'severity',    w.severity,
           'starts_at',   w.starts_at,
           'ends_at',     w.ends_at)
           order by case w.severity
                      when 'critical' then 0
                      when 'warning'  then 1
                      else 2
                    end,
                    w.starts_at desc),
         c_empty)
    into v_events
    from public.world_events w
    where w.is_active
      and w.starts_at <= now()
      and (w.ends_at is null or w.ends_at > now())
      and (
        w.scope = 'global'
        or (w.scope = 'zone'     and w.zone_id     = p_zone_id)
        or (w.scope = 'location' and w.location_id = p_location_id)
      );

  return jsonb_build_object('ok', true, 'events', coalesce(v_events, c_empty));
end;
$$;

-- ACL (0087/0101/0106 idiom): revoke the default PUBLIC grant + anon, then authenticated only — the
-- map/dashboard are behind auth. NO write path is exposed (this is a read RPC). Dark today: the gate
-- above returns an empty list for every call while phase20_polish_enabled = 'false'.
revoke execute on function public.get_world_events(uuid, uuid) from public, anon;
grant  execute on function public.get_world_events(uuid, uuid) to authenticated;
