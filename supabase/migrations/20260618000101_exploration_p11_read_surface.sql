-- Byeharu — EXPLORATION-P11 SLICE F: the dark read surface — get_my_exploration_discoveries()
-- (reveal-after-discovery). Read-only; no write anywhere; dark-gated like every exploration surface.
--
-- (1) THE CLIENT NEVER READS exploration_sites DIRECTLY. Reveal-after-discovery goes through this ONE
--     server read RPC: it joins the caller's OWN exploration_discoveries rows to the hidden site rows
--     and returns ONLY discovered sites. The 0098 no-client-policy posture on exploration_sites is
--     untouched — an undiscovered site's existence/name/coordinates remain unreadable by construction
--     (the join can only reach a site through one of the caller's own discovery rows). Same spirit as
--     the get_my_current_dock_services read surface (0069): expose already-authoritative player-owned
--     truth, derive everything server-side, accept no trustable client identifiers.
-- (2) DARK-GATED FIRST (0097 reject-before-any-read law), copying the 0087 get_market_offers read
--     idiom exactly (0087:46–50): auth check, then the flag reject BEFORE any discovery/site read,
--     returning the same {ok:false, reason:'exploration_disabled'} envelope regardless of caller
--     state — nothing about the caller's ships/discoveries can be probed while dark.
-- (3) SCOPE DECISION (recorded so nobody "finishes" it by accident): Exploration v1 is OSN-native
--     ONLY. The activity_start / 'explore_derelict' location-presence dispatch is deliberately NOT
--     wired in Phase 11 (ROADMAP: "scan in OSN proximity … where applicable"). activity_start still
--     raises on 'explore_derelict' — that is intended Phase-11 behavior, not an omission.
--
-- Returned bundle field = the discovery row's pending_bundle_json snapshot (0099/0100); secured_at
-- NULL = still pending, non-null = deposited by process_exploration_securing. Discovered-then-
-- disabled sites stay visible: the discovery legitimately happened and is the player's own history.

create or replace function public.get_my_exploration_discoveries()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player      uuid := auth.uid();
  v_discoveries jsonb;
  c_empty       constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject FIRST (0097 law; 0087 read idiom): before any discovery/site read, and the
  -- identical envelope regardless of the caller's ships/discoveries — no probing while dark.
  if not public.cfg_bool('exploration_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'exploration_disabled');
  end if;

  -- read-only: ONLY the caller's own discoveries, joined to the hidden site rows — a site is
  -- reachable exclusively through one of the caller's own discovery rows (reveal-after-discovery).
  -- Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'discovery_id',  d.id,
           'site_name',     s.name,
           'space_x',       s.space_x,
           'space_y',       s.space_y,
           'discovered_at', d.discovered_at,
           'secured_at',    d.secured_at,
           'bundle',        d.pending_bundle_json) order by d.discovered_at desc),
         c_empty)
    into v_discoveries
    from public.exploration_discoveries d
    join public.exploration_sites s on s.id = d.site_id
    where d.player_id = v_player;

  return jsonb_build_object('ok', true, 'discoveries', coalesce(v_discoveries, c_empty));
end;
$$;

-- ACL (0087 idiom): revoke the default PUBLIC grant, then authenticated only. Dark today: the gate
-- above rejects every call while exploration_enabled = 'false'.
revoke execute on function public.get_my_exploration_discoveries() from public, anon;
grant  execute on function public.get_my_exploration_discoveries() to authenticated;
