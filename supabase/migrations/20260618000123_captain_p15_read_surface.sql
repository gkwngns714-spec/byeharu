-- Byeharu — CAPTAIN-P15 SLICE G: the dark read surface — get_my_captain_instances() +
-- get_my_ship_captains(ship). Read-only; no write anywhere; dark-gated like every
-- captain-assignment surface. Each RPC mirrors its own analogue's idiom precisely:
-- get_my_captain_instances ↔ 0110 (get_my_module_instances), get_my_ship_captains ↔ 0116
-- (get_my_ship_fittings) — both read first, per the slice spec.
--
-- (1) get_my_captain_instances() — THE 0110 SHAPE, check ordering copied exactly (auth check →
--     dark gate → query; 0110:44–52): jsonb envelope · stable · security definer · dark gate on
--     captain_assignment_enabled BEFORE any row read, returning the identical
--     {ok:false, reason:'captain_assignment_disabled'} for every caller (no probing while dark;
--     the same literal envelope the 0120 wrappers emit — ONE visibility signal) · the caller's
--     OWN captain_instances rows (query-scoped player_id = auth.uid(), defense in depth over
--     RLS) joined to their captain_types catalog display identity (name / specialization /
--     stats_json) · jsonb_agg ordered created_at desc (the 0110 newest-first idiom) ·
--     {ok:true, captains:[…]}. PLUS an assignment indicator per row — the assigned main_ship_id
--     or null via LEFT JOIN to ship_captain_assignments — so the client renders roster state
--     from one call. LOCKED DECISION (recorded per the slice spec): this left join is read-only
--     display data and creates NO new writer and NO new dependency direction — a Captain-owned
--     function reading Captain-owned tables (captain_instances, ship_captain_assignments) plus
--     the public catalog; the §1 sole writers are untouched.
-- (2) get_my_ship_captains(p_main_ship_id) — THE 0116 SHAPE including its exact gate/auth
--     ORDERING (0116:23–26 records the deliberate divergence from 0110: the dark gate runs
--     FIRST, then auth — while dark the answer is identical for EVERY caller; copied verbatim):
--     dark-rejects {ok:false, reason:'captain_assignment_disabled'} identically → auth →
--     validate the ship by the (main_ship_id, player_id) PAIR (never "the player's ship"
--     singular — the 0079 multi-ship posture; a foreign/missing ship answers ship_not_owned) →
--     that ship's roster joined via captain_instances to captain_types, ordered assigned_at desc
--     then captain_instance_id (the 0116:9–10 determinism idiom with the uuid tiebreak) →
--     {ok:true, captains:[…]}.
-- (3) NO COUNTS in (2) — 0116 returns NO fitting counts, so none are added here (the slice
--     spec's mirror rule; no speculative surface). The 0116:18–22 deliberate-omission rationale
--     transfers verbatim: the slot LIMIT belongs to the ship, not the assignment rows — the
--     client reads its own main_ship_instances rows (the 0043 own-row select grant covers
--     captain_slots) or get_my_expedition_preview (whose stats carry
--     captain_slots_used/captain_slots_limit since 0122) for limits. These surfaces stay dumb.
-- (4) NO CATALOG RPC — the 0110:9–15 stance restated and followed: captain_types is a
--     public-read Reference/Config catalog exactly like item_types/support_craft_types/
--     module_types (0117 posture), which the client reads by DIRECT table select (the shipped
--     convention). A get-catalog RPC would duplicate an already-public surface — NOT added.
--
-- Note (the 0106/0110/0116 header nuance, mirrored): while captain_instances and
-- ship_captain_assignments also carry own-row select policies (0118/0119), the CLIENT CONVENTION
-- for player activity/progression state is these gated RPCs — while
-- captain_assignment_enabled='false' they reject identically regardless of caller state, so
-- nothing about a player's captains can be probed while dark; the frontend gets its
-- server-driven visibility signal from the 'captain_assignment_disabled' reason.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): read-only functions — NO new
-- writer, NO new table, so the §1 matrix is unchanged (the 0101/0106/0110/0116 precedent: read
-- surfaces are recorded in the §2 system row, not the matrix). The §2 Captain row gains both
-- functions. No flag flipped; 0001–0122 unedited.

-- ── 1) get_my_captain_instances — the caller's roster, with per-row assignment state ─────────────
create or replace function public.get_my_captain_instances()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_captains jsonb;
  c_empty    constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject FIRST (0117 law; the 0087/0101/0106/0110 read idiom): before any
  -- instance read, and the identical envelope regardless of the caller's captains — no probing
  -- while dark.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;

  -- read-only: ONLY the caller's own instances (query-scoped — defense in depth over RLS),
  -- joined to their public catalog identity, LEFT-joined to the assignment row for the per-row
  -- roster indicator (header (1) locked decision: display data only). Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'instance_id',     i.id,
           'captain_type_id', i.captain_type_id,
           'name',            t.name,
           'specialization',  t.specialization,
           'stats_json',      t.stats_json,
           'main_ship_id',    a.main_ship_id,
           'created_at',      i.created_at) order by i.created_at desc),
         c_empty)
    into v_captains
    from public.captain_instances i
    join public.captain_types t on t.id = i.captain_type_id
    left join public.ship_captain_assignments a on a.captain_instance_id = i.id
    where i.player_id = v_player;

  return jsonb_build_object('ok', true, 'captains', coalesce(v_captains, c_empty));
end;
$$;

-- ── 2) get_my_ship_captains — one owned ship's roster (the 0116 gate-first shape) ────────────────
create or replace function public.get_my_ship_captains(p_main_ship_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player   uuid;
  v_captains jsonb;
  c_empty    constant jsonb := '[]'::jsonb;
begin
  -- DARK server-reject FIRST (0117 law; the 0116:51–56 gate-before-auth ordering verbatim):
  -- before any row read, and the identical envelope regardless of the caller — no probing while
  -- dark.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;

  v_player := auth.uid();
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- the ship must exist AND belong to the caller — read by the (main_ship_id, player_id) PAIR
  -- (the 0079 multi-ship posture; one reason for both cases, so a foreign ship answers exactly
  -- like a nonexistent one).
  if not exists (select 1 from public.main_ship_instances
                   where main_ship_id = p_main_ship_id and player_id = v_player) then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_owned');
  end if;

  -- read-only: that ship's roster (query-scoped by ship AND player — defense in depth over
  -- RLS), joined downward to instance + public catalog identity. Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'captain_instance_id', a.captain_instance_id,
           'assigned_at',         a.assigned_at,
           'captain_type_id',     i.captain_type_id,
           'name',                t.name,
           'specialization',      t.specialization,
           'stats_json',          t.stats_json) order by a.assigned_at desc, a.captain_instance_id),
         c_empty)
    into v_captains
    from public.ship_captain_assignments a
    join public.captain_instances i on i.id = a.captain_instance_id
    join public.captain_types t     on t.id = i.captain_type_id
    where a.main_ship_id = p_main_ship_id and a.player_id = v_player;

  return jsonb_build_object('ok', true, 'captains', coalesce(v_captains, c_empty));
end;
$$;

-- ── 3) ACL (the 0110:72–75 / 0116:84–87 idiom verbatim): revoke the default PUBLIC grant, then
--       authenticated only. Dark today: the gates above reject every call while
--       captain_assignment_enabled = 'false'.
revoke execute on function public.get_my_captain_instances() from public, anon;
grant  execute on function public.get_my_captain_instances() to authenticated;
revoke execute on function public.get_my_ship_captains(uuid) from public, anon;
grant  execute on function public.get_my_ship_captains(uuid) to authenticated;
