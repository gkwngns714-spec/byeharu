-- Byeharu — TEAMMAP-1: tag team-expedition member fleets with their group id (the map's team-marker read).
--
-- OWNER DIRECTIVE (TEAMMAP): "The team should have a marker of its own and be shown on map." The engine
-- already sends a team as N parallel member fleets through the UNCHANGED live single send (0163 → 0169),
-- but those fleets carry NO team tag — the map cannot label them. Slice D2 (0168) already added the
-- INFORMATIONAL `fleets.group_id` column and tags the ONE hunt-sortie fleet; this migration extends the
-- SAME tag to the N expedition member fleets, so every in-flight team movement is display-labelable.
--
-- ── HEAD PROVENANCE ─────────────────────────────────────────────────────────────────────────────────
-- send_ship_group_expedition is re-created from its TRUE head, 20260618000163 (created there; grep over
-- ALL migrations shows no later re-create — 0163 is the only definition). The body below is the 0163
-- body VERBATIM plus ONE marked hunk (-- TEAMMAP-1): after the all-or-nothing member loop succeeds, the
-- just-created member fleets are tagged with the resolved group id. The fleet ids are read from the
-- envelope the head already collects (`v_sent`, one live-send response per member — each carries
-- 'fleet_id' per the live send's return, 0169:628-630). No other line changes; reviewers can
-- extract-and-diff against 0163:35-103.
--
-- ── THE DISPLAY-ONLY LAW (restated from 0168) ───────────────────────────────────────────────────────
-- fleets.group_id is an INFORMATIONAL team tag (display only; ROUTING NEVER reads it). Every consumer
-- that must know "is this a team sortie / who is in it" keys on group_sortie_members (hunts) or live
-- membership (main_ship_instances.group_id); this column exists ONLY so displays can label a fleet with
-- its team. ON DELETE SET NULL (0168): deleting a team mid-flight merely unlabels the fleets — every
-- member keeps flying and settling exactly as before this migration.
--
-- ── PARITY / GATE / GRANTS ──────────────────────────────────────────────────────────────────────────
-- Behavior parity outside the hunk: the reject vocabulary, lock order (GROUP FOR SHARE → SHIPS FOR
-- UPDATE), the all-or-nothing subtransaction, and the success envelope are byte-identical to 0163. The
-- hunk runs AFTER the subtransaction succeeds and inside the same function transaction — a (practically
-- impossible: the group row is held FOR SHARE, so delete's FOR UPDATE blocks) tag failure raises and
-- rolls back the whole send, never a half-tagged team. The RPC stays gated by the existing
-- team_command_enabled reject-before-read gate — no new flag; the column is informational-only, so no
-- dark-leak surface. CREATE OR REPLACE preserves owner and the 0163 grants (authenticated EXECUTE), so
-- no grant/revoke is re-emitted.

create or replace function public.send_ship_group_expedition(p_group_id uuid, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_group   uuid;
  v_members uuid[];
  v_ship    uuid;
  v_res     jsonb;
  v_sent    jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any group/ship read (identical answer regardless of input; no existence oracle).
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Resolve the owned group (explicit-only; null/non-owned/nonexistent → null → fail closed).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Lock the group row FOR SHARE, then revalidate under the lock (serializes vs delete's FOR UPDATE; if a
  -- delete won the resolve→lock window we lock zero rows and fail closed).
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for share;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Gather the team's ships (owner- AND group-scoped), deterministic order.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  if array_length(v_members, 1) is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- Lock the member ship rows FOR UPDATE (ships AFTER group → same lock order as assign/delete, no deadlock)
  -- so a concurrent TEAM-send of overlapping members blocks, then re-reads them as already 'traveling' and its
  -- inner send raises → that whole send rolls back. NB this serializes team-send vs team-send ONLY: FOR UPDATE
  -- blocks lockers/writers, not MVCC readers, and the live single-ship send reads the ship with a plain
  -- unlocked SELECT — so a DIRECT single-ship send racing a team-send is unaffected here (closed only by the
  -- live status='home' re-check; a pre-existing single-ship TOCTOU, not newly introduced by this wrapper).
  perform 1 from public.main_ship_instances
    where main_ship_id = any(v_members) and player_id = v_player for update;

  -- ALL-OR-NOTHING: one subtransaction around the WHOLE loop. Reuse the LIVE send unchanged, once per member.
  -- Any member raise (not home, active-fleet cap, bad destination, …) rolls back every prior member's send.
  begin
    foreach v_ship in array v_members loop
      select public.send_main_ship_expedition(jsonb_build_array(v_ship), p_location) into v_res;
      v_sent := v_sent || jsonb_build_array(v_res);
    end loop;
  exception
    when others then
      return jsonb_build_object('ok', false, 'reason', 'member_send_failed', 'detail', sqlerrm);
  end;

  -- TEAMMAP-1 (the ONE marked hunk; everything else is the 0163 body verbatim): the member loop
  -- succeeded — tag the just-created member fleets with the team's group id, read straight from the
  -- envelope the loop collected (each live-send response carries 'fleet_id'). INFORMATIONAL / display
  -- only (the 0168 law verbatim): ROUTING NEVER reads fleets.group_id — this update changes no
  -- movement, settle, or combat behavior; it exists so the map can label the team's fleets. Owner-
  -- scoped defense-in-depth (the loop only ever created fleets for v_player). Runs INSIDE the same
  -- function transaction but AFTER the subtransaction: an (unreachable — the group row is held FOR
  -- SHARE) failure here raises and rolls back the whole send, never a half-tagged team.
  update public.fleets
     set group_id = v_group
   where player_id = v_player
     and id in (select (e->>'fleet_id')::uuid from jsonb_array_elements(v_sent) e);
  -- TEAMMAP-1 hunk end.

  return jsonb_build_object('ok', true, 'group_id', v_group, 'sent', v_sent);
end;
$$;

-- ── Self-asserts: the deployed body is the 0163 head + the marked hunk (never the untagged OLD body). ──
do $teammap$
declare v_src text; v_cnt int;
begin
  select count(*), min(p.prosrc) into v_cnt, v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_ship_group_expedition';
  if v_cnt <> 1 then
    raise exception 'TEAMMAP-1 self-assert: % definitions of send_ship_group_expedition (want exactly 1)', v_cnt;
  end if;
  -- the marked hunk is present…
  if position('TEAMMAP-1' in v_src) = 0 then
    raise exception 'TEAMMAP-1 self-assert: marked hunk comment missing from prosrc';
  end if;
  if position($chk$id in (select (e->>'fleet_id')::uuid from jsonb_array_elements(v_sent) e)$chk$ in v_src) = 0
     or position('set group_id = v_group' in v_src) = 0 then
    raise exception 'TEAMMAP-1 self-assert: the group-tag update is not in the deployed body';
  end if;
  -- …and the OLD (0163) body shape is absent: the old body returned the success envelope with NO
  -- fleets write at all — pin that the tag update sits BEFORE the success return (tag-then-return).
  if position('set group_id = v_group' in v_src) > position($chk$'sent', v_sent)$chk$ in v_src) then
    raise exception 'TEAMMAP-1 self-assert: the hunk does not precede the success return (old 0163 body shape)';
  end if;
  raise notice 'TEAMMAP-1 self-assert ok: one definition; marked group-tag hunk deployed before the success return';
end $teammap$;
