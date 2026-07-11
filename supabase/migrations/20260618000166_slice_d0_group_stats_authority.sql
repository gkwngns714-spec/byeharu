-- Byeharu — TEAM-COMMAND Slice D0: AUTHORITATIVE group expedition stats (DARK; RPC-ONLY; ZERO data change).
--
-- First combat-facing team sub-slice of Slice D (docs/TEAM_COMMAND.md). ONE thing: the server-side
-- source of truth for a TEAM's expedition stats — the context 0165 explicitly deferred ("AUTHORITATIVE
-- team stats arrive in Slice D beside the combat consumer, never here"). Two functions:
--   (1) calculate_group_expedition_stats — the internal, service_role-only authority. Per member ship
--       it delegates to the UNMODIFIED calculate_expedition_stats (0122 — which already folds support
--       craft + modules + captain skills behind their hard caps) and performs TEAM-LEVEL FOLDING ONLY:
--       additive stat keys summed, speed = min(member speed). ZERO re-implemented per-ship stat
--       arithmetic — no accumulator reads a catalog row, a stats_json, or a tradeoff rule here.
--   (2) get_my_group_expedition_totals — the thin, gated, client-facing wrapper exposing the same
--       truth (the 0165 envelope idiom), so the future combat consumer and the client read ONE number.
--
-- ── STRICT, NOT PREVIEW (the deliberate divergence from 0165, documented) ─────────────────────────
--   get_my_group_expedition_preview (0165) is the FRIENDLY surface: each member runs in its own
--   exception scope and a member's validation raise becomes {valid:false, error}. That is the right
--   posture for a preview a player is browsing. THIS slice is the AUTHORITATIVE context: a team whose
--   member is in an illegal state (over-capacity — 0122's refuse-don't-clamp law) has NO defined team
--   stats, so calculate_group_expedition_stats RAISES whole (no per-member envelope, no clamping,
--   no partial totals) and the wrapper folds any such raise into ONE opaque {ok:false,
--   reason:'stats_invalid'} — the member-level detail stays on the preview surface where it belongs.
--
-- ── ADDITIVE KEY SET (pinned to what 0122 actually emits) ─────────────────────────────────────────
--   0122's numeric STAT keys are exactly: combat_power, survival, repair, retreat_safety, scouting,
--   mining_yield, cargo_capacity, pirate_attention — those are SUMMED. speed is deliberately NOT
--   additive: members travel individually, so a team moves at its slowest member's pace — min(),
--   matching the client's display-only slowestSpeed (src/features/command/teamSkillset.ts). 0122's
--   remaining keys (support_capacity/module_slots/captain_slots used+limit pairs, warnings) are
--   per-ship capacity BOOKKEEPING, not team stats — they stay on the per-member stats objects the
--   members[] array carries verbatim and are NOT folded into totals.
--
-- ── ANTI-SPAGHETTI (audited) ──────────────────────────────────────────────────────────────────────
--   Touches NO fleets / fleet_units / combat_units, NO movement path, NO combat engine, NO captain
--   table or writer, NO client code. calculate_expedition_stats (0122) is NOT re-created — it stays
--   byte-identical, THE one per-ship stat source. 0165's preview is NOT re-created either. Group
--   membership is read from the ONE link (main_ship_instances.group_id, 0160) exactly as 0163/0165 do.
--
-- ── DARK / GATE ───────────────────────────────────────────────────────────────────────────────────
--   The wrapper rejects-before-read on cfg_bool('team_command_enabled') (seeded FALSE in 0160) BEFORE
--   any group/ship read — the 0161/0163/0164/0165 posture (identical answer regardless of input; no
--   existence oracle). No flag is flipped; no game_config row is written. In prod every call returns
--   team_command_disabled. The internal function has no client grant at all.
--
-- ── READ-ONLY, NO LOCKS (the 0165 MVCC posture) ──────────────────────────────────────────────────
--   Both functions write NOTHING — the statement's MVCC snapshot is the consistency guarantee, so no
--   FOR SHARE / FOR UPDATE anywhere (deliberate, documented divergence from the writing B-send/B-stop).
--
-- Touches NO existing signature, NO frozen verifier, NO game_config, NO data. New-function-only ACL idiom.

-- ── 1. calculate_group_expedition_stats: the authoritative team-stats context (service_role-only) ──
-- Delegation + team-level folding ONLY. Raises (never envelopes — this is the internal authority,
-- mirroring 0122's own exception posture):
--   unknown activity_type   — the exact 0122 set, checked first with 0122's message idiom;
--   group_not_found         — p_group_id null / nonexistent / not owned by p_player
--                             (mainship_resolve_owned_group, 0161 — explicit-only, fail closed);
--   empty_group             — the group has zero member ships;
--   any member raise        — 0122's refuse-don't-clamp raises (over-capacity etc.) propagate WHOLE.
create or replace function public.calculate_group_expedition_stats(
  p_player        uuid,
  p_group_id      uuid,
  p_activity_type text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_group       uuid;
  v_members     uuid[];
  v_ship        uuid;
  v_stats       jsonb;
  v_members_out jsonb := '[]'::jsonb;
  -- team-level folds ONLY (sums of 0122 outputs + min speed) — no per-ship arithmetic exists here.
  t_combat    numeric := 0;
  t_survival  numeric := 0;
  t_repair    numeric := 0;
  t_retreat   numeric := 0;
  t_scout     numeric := 0;
  t_mining    numeric := 0;
  t_cargo     numeric := 0;
  t_attention numeric := 0;
  v_min_speed numeric := null;
begin
  -- (0) Activity must be a known type — the exact 0122 set, its message idiom, checked before any
  --     row read (a bad activity never costs a membership read or a member loop of raises).
  if coalesce(p_activity_type, '') not in ('pirate_hunt','trade_run','exploration','mining','none') then
    raise exception 'calculate_group_expedition_stats: unknown activity_type %', p_activity_type;
  end if;

  -- (1) Resolve the owned group (explicit-only; null/non-owned/nonexistent → null → raise, the 0122
  --     nonexistent-input posture: a clear exception, not an envelope, in this internal context).
  v_group := public.mainship_resolve_owned_group(p_player, p_group_id);
  if v_group is null then
    raise exception 'calculate_group_expedition_stats: group_not_found (group % for player %)', p_group_id, p_player;
  end if;

  -- (2) Gather the team's ships (owner- AND group-scoped), deterministic order — the 0163/0165
  --     member query, UNLOCKED (read-only; MVCC is the consistency guarantee — header note).
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = p_player;
  if array_length(v_members, 1) is null then
    raise exception 'calculate_group_expedition_stats: empty_group (group % has no member ships)', v_group;
  end if;

  -- (3) Per-member DELEGATION to the ONE stat adapter (empty loadout — support craft is deprecated
  --     on this path; captains/modules are read from the ship's own state by 0122), then TEAM-LEVEL
  --     folding of the returned jsonb. STRICT: no per-member exception scope — a member's
  --     refuse-don't-clamp raise (0122's law) propagates and refuses the WHOLE team context
  --     (deliberate divergence from 0165's preview idiom; header note).
  foreach v_ship in array v_members loop
    v_stats := public.calculate_expedition_stats(p_player, v_ship, '[]'::jsonb, p_activity_type);
    v_members_out := v_members_out || jsonb_build_array(jsonb_build_object(
      'main_ship_id', v_ship, 'stats', v_stats));

    -- additive folds — the pinned 0122 stat-key set (header note), coalesced so a total is never null.
    t_combat    := t_combat    + coalesce((v_stats->>'combat_power')::numeric, 0);
    t_survival  := t_survival  + coalesce((v_stats->>'survival')::numeric, 0);
    t_repair    := t_repair    + coalesce((v_stats->>'repair')::numeric, 0);
    t_retreat   := t_retreat   + coalesce((v_stats->>'retreat_safety')::numeric, 0);
    t_scout     := t_scout     + coalesce((v_stats->>'scouting')::numeric, 0);
    t_mining    := t_mining    + coalesce((v_stats->>'mining_yield')::numeric, 0);
    t_cargo     := t_cargo     + coalesce((v_stats->>'cargo_capacity')::numeric, 0);
    t_attention := t_attention + coalesce((v_stats->>'pirate_attention')::numeric, 0);

    -- speed = min(member speed): members travel individually — the team is as fast as its slowest
    -- ship (the client slowestSpeed semantics, src/features/command/teamSkillset.ts).
    if v_min_speed is null then
      v_min_speed := (v_stats->>'speed')::numeric;
    else
      v_min_speed := least(v_min_speed, (v_stats->>'speed')::numeric);
    end if;
  end loop;

  return jsonb_build_object(
    'group_id',      v_group,
    'activity_type', p_activity_type,
    'member_count',  array_length(v_members, 1),
    'members',       v_members_out,
    'totals',        jsonb_build_object(
      'speed',            v_min_speed,
      'cargo_capacity',   t_cargo,
      'combat_power',     t_combat,
      'survival',         t_survival,
      'retreat_safety',   t_retreat,
      'scouting',         t_scout,
      'mining_yield',     t_mining,
      'repair',           t_repair,
      'pirate_attention', t_attention));
end;
$$;

-- ── 2. get_my_group_expedition_totals: the thin, DARK, gated client wrapper over the same truth ────
-- Reject order (the 0165 structure verbatim, gate FIRST before any read):
--   not_authenticated → team_command_disabled → invalid_activity → group_not_found → empty_group
--   → stats_invalid (any authority raise, folded opaque) → ok
create or replace function public.get_my_group_expedition_totals(
  p_group_id uuid, p_activity_type text default 'none')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_group  uuid;
  v_res    jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any group/ship read (identical answer regardless of input; no
  -- existence oracle). The 0161/0163/0164/0165 posture verbatim.
  if not public.cfg_bool('team_command_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'team_command_disabled');
  end if;

  -- Activity validation BEFORE any row read — EXACTLY the set calculate_expedition_stats (0122)
  -- accepts, envelope-rejected here (the 0165 posture) so a bad activity never reads a row.
  if coalesce(p_activity_type, '') not in ('pirate_hunt','trade_run','exploration','mining','none') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_activity');
  end if;

  -- Resolve the owned group (explicit-only; null/non-owned/nonexistent → null → fail closed).
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- Memberless team → its own token (the 0165 vocabulary), never a generic failure.
  perform 1 from public.main_ship_instances
    where group_id = v_group and player_id = v_player limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- Delegate to the AUTHORITATIVE team-stats context. STRICT-vs-PREVIEW (migration header): any
  -- raise inside it (a member's 0122 refuse-don't-clamp raise, a raced group delete) folds into ONE
  -- opaque stats_invalid — NO member detail leaks here; 0165's preview is the friendly per-member
  -- surface for diagnosing WHICH member is invalid.
  begin
    v_res := public.calculate_group_expedition_stats(v_player, p_group_id, p_activity_type);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;

  return jsonb_build_object('ok', true) || v_res;
end;
$$;

-- ── ACL ────────────────────────────────────────────────────────────────────────────────────────────
-- calculate_group_expedition_stats: the exact 0122 posture — server-only, service_role, NEVER
-- clients; only the gated wrapper below (which calls it as the function owner — the 0049/0159/0165
-- SECURITY DEFINER idiom) exposes it. The TARGETED idiom; no other function's grants touched.
revoke execute on function public.calculate_group_expedition_stats(uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.calculate_group_expedition_stats(uuid, uuid, text) to service_role;

-- get_my_group_expedition_totals (0163/0164/0165 new-function-only idiom): authenticated-only; the
-- in-body gate rejects every call while team_command_enabled is false.
revoke execute on function public.get_my_group_expedition_totals(uuid, text) from public, anon;
grant  execute on function public.get_my_group_expedition_totals(uuid, text) to authenticated;
