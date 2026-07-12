-- Byeharu — HAUL-3 read surface + C2-3 projection delta (one UI-slice migration; everything DARK).
--
-- Two read-side deltas for the combined HAUL-3 + C2-3 UI slice — no writer, no new table, no flag
-- write; both features stay dark behind their 0176/0177 gates:
--
-- ── 1) get_port_contracts(p_location) — the HAUL-3 bulletin read RPC (NEW) ───────────────────────
-- THE DECISION (RPC vs direct table select, recorded): 0176 shipped RLS public-read on 'offered'
-- rows, so supabase-js COULD select haul_contracts directly — and while dark that select would
-- return [] BY DATA (the generator is a gate-first no-op while dark → zero offered rows can exist;
-- fail-closed by construction, and the policy exposes no player data). But the HOUSE LAW for player
-- activity surfaces is the gated read RPC that rejects BEFORE any read (0087/0101/0106/0110/0123 —
-- the same reason get_my_captain_instances exists although captain_instances carries own-row RLS:
-- ONE server-driven visibility signal, no residual-data leak on an emergency lit→dark flip, where
-- the 0176 header notes stale 'offered' rows would stay publicly readable until re-lit). THE RPC
-- WINS: gate-first `haul_contracts_disabled`, identical for every caller while dark — the client
-- panel keys isServerLit off it and renders NOTHING today.
--   Shape: auth → gate (before ANY row read — the 0179 haul-family order) → invalid_location →
--   {ok:true, location_id, max_active, offered:[…], mine:[…]} — the two bulletin tabs:
--   · offered — THIS port's fresh bulletin (status='offered' AND expires_at > now(): the same
--     fail-closed stale-offer posture the accept RPC enforces (0179 §3) — the board never shows a
--     row accept would bounce), ordered by slot; carries the dest display name (locations names are
--     public catalog display data — a read-only downward join, no new writer/edge).
--   · mine — the caller's status='accepted' contracts (ALL ports: deadlines matter wherever the
--     ship is; delivery happens at the dest), with deliver_by, ordered soonest-deadline-first.
--   · max_active — the cfg cap surfaced so the client can mirror too_many_active without a probe
--     (game_config itself is not client-readable; mine's length IS the active count).
--   Read-only; SECURITY DEFINER + query-scoped like 0123 (mine is auth.uid()-scoped in the query —
--   defense in depth over RLS); STABLE; authenticated-only ACL (mine is caller-scoped, so no anon).
--
-- ── 2) get_my_captain_instances — 0123-head parity re-create + the C2-3 projection hunk ──────────
-- FINDING (grep-verified): the ONLY create site of get_my_captain_instances is 0123 — nothing in
-- 0124..0180 re-creates it — so 0123 is its TRUE head, and its projection PREDATES the 0177
-- xp/level columns: the client cannot see captain progression at all today. PARITY DISCIPLINE
-- (the D1/D3/0170/0179/0180 re-create law): the body below is copied VERBATIM from 0123 except the
-- ONE marked hunk — two additive keys ('xp', i.xp / 'level', i.level) in the jsonb_build_object
-- projection. No gate change (still captain_assignment_enabled — the surface's own visibility
-- flag), no ordering change, no new join: the 0177 columns ride the existing captain_instances i.
-- DARK STORY: while captain_growth_enabled is false the accrual (its sole writer) has never moved
-- xp/level, so every row projects xp=0/level=1 — the C2-3 client renders NOTHING new for a
-- level-1 0-xp captain, byte-identical UI today. (get_my_ship_captains (0123 §2) projects the
-- CATALOG identity only — no instance progression column belongs there; untouched.)
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md): read-only functions — NO new writer, NO new table, the §1
-- matrix unchanged (the 0101/0106/0110/0116/0123 precedent: read surfaces live in the §2 rows).
-- Forward-only: 0001–0180 unedited. No flag flipped: haul_contracts_enabled and
-- captain_growth_enabled both stay 'false'.

-- ── 1) get_port_contracts — the gated HAUL-3 bulletin read (reject-before-read house law) ────────
create or replace function public.get_port_contracts(p_location uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_offered jsonb;
  v_mine    jsonb;
  v_cap     integer;
  c_empty   constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject FIRST (the 0179 haul-family order; reject before ANY row read): identical
  -- envelope for every caller while haul_contracts_enabled is false — no probing while dark.
  if not public.cfg_bool('haul_contracts_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'haul_contracts_disabled');
  end if;

  if p_location is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_location');
  end if;

  -- the fresh bulletin at THIS port: status='offered' AND expires_at > now() — the accept RPC's
  -- own fail-closed stale-offer posture (0179 §3), so the board never lists a row accept bounces.
  select coalesce(jsonb_agg(jsonb_build_object(
           'contract_id',      c.id,
           'good_id',          c.good_id,
           'quantity',         c.quantity,
           'reward_credits',   c.reward_credits,
           'offered_at',       c.offered_at,
           'expires_at',       c.expires_at,
           'dest_location_id', c.dest_location_id,
           'dest_name',        ld.name) order by c.slot, c.id),
         c_empty)
    into v_offered
    from public.haul_contracts c
    left join public.locations ld on ld.id = c.dest_location_id
    where c.origin_location_id = p_location
      and c.status = 'offered'
      and c.expires_at > now();

  -- the caller's active contracts (ALL ports — deadlines matter wherever the ship is), scoped in
  -- the query to accepted_by = v_player (defense in depth over the 0176 owner-read policy).
  select coalesce(jsonb_agg(jsonb_build_object(
           'contract_id',        c.id,
           'good_id',            c.good_id,
           'quantity',           c.quantity,
           'reward_credits',     c.reward_credits,
           'origin_location_id', c.origin_location_id,
           'origin_name',        lo.name,
           'dest_location_id',   c.dest_location_id,
           'dest_name',          ld.name,
           'accepted_at',        c.accepted_at,
           'deliver_by',         c.deliver_by) order by c.deliver_by, c.id),
         c_empty)
    into v_mine
    from public.haul_contracts c
    left join public.locations lo on lo.id = c.origin_location_id
    left join public.locations ld on ld.id = c.dest_location_id
    where c.accepted_by = v_player
      and c.status = 'accepted';

  v_cap := coalesce(public.cfg_num('haul_max_active_per_player'), 3)::integer;

  return jsonb_build_object('ok', true, 'location_id', p_location,
    'max_active', v_cap,
    'offered', coalesce(v_offered, c_empty),
    'mine', coalesce(v_mine, c_empty));
end;
$$;
-- ACL (the 0123/0179 idiom): authenticated only — mine is caller-scoped, so no anon read surface.
revoke execute on function public.get_port_contracts(uuid) from public, anon;
grant  execute on function public.get_port_contracts(uuid) to authenticated;

-- ── 2) get_my_captain_instances — 0123 head re-created with the marked C2-3 projection hunk ──────
-- PARITY DISCIPLINE: body byte-identical to 0123 EXCEPT the one marked [C2-3 hunk] line pair —
-- the two additive projection keys. Gate/ordering/joins/ACL unchanged.
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
           'xp',              i.xp,     -- [C2-3 hunk] the 0177 progression columns, additive:
           'level',           i.level,  -- [C2-3 hunk] xp=0/level=1 everywhere while growth is dark
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
-- ACL re-asserted on the re-created identity (the 0123 §3 idiom verbatim; create-or-replace
-- preserves grants — re-emitted for an explicit posture, the 0092/0179 idiom).
revoke execute on function public.get_my_captain_instances() from public, anon;
grant  execute on function public.get_my_captain_instances() to authenticated;

-- ── 3) Self-assert: RPC identities + ACLs; gate-first dark rejects; parity prosrc pins; flags dark ─
do $$
declare
  v_r   jsonb;
  v_src text;
begin
  -- 1. get_port_contracts exists, authenticated-only (never anon/public).
  if to_regprocedure('public.get_port_contracts(uuid)') is null then
    raise exception 'HAUL-3 self-assert FAIL: get_port_contracts(uuid) missing';
  end if;
  if not has_function_privilege('authenticated', 'public.get_port_contracts(uuid)', 'execute') then
    raise exception 'HAUL-3 self-assert FAIL: get_port_contracts not authenticated-executable';
  end if;
  if has_function_privilege('anon', 'public.get_port_contracts(uuid)', 'execute') then
    raise exception 'HAUL-3 self-assert FAIL: get_port_contracts is anon-executable';
  end if;

  -- 2. get_port_contracts prosrc pins: the gate reject + the fail-closed fresh-offer predicate +
  --    the caller-scoped mine read (the bulletin RPC's load-bearing clauses).
  select prosrc into v_src from pg_proc where oid = 'public.get_port_contracts(uuid)'::regprocedure;
  if v_src not like '%haul_contracts_disabled%' then
    raise exception 'HAUL-3 self-assert FAIL: get_port_contracts lacks the dark gate reject';
  end if;
  if v_src not like '%status = ''offered''%' or v_src not like '%expires_at > now()%' then
    raise exception 'HAUL-3 self-assert FAIL: get_port_contracts lacks the fresh-offered predicate';
  end if;
  if v_src not like '%accepted_by = v_player%' or v_src not like '%status = ''accepted''%' then
    raise exception 'HAUL-3 self-assert FAIL: get_port_contracts mine read is not caller-scoped';
  end if;

  -- 3. DARK dry-runs (the 0179 §7 technique): no auth subject → not_authenticated (envelope-first);
  --    a transient fake subject → haul_contracts_disabled BEFORE any read (even a null location —
  --    the gate precedes invalid_location). Transaction-local claims; reset after.
  perform set_config('request.jwt.claims', '', true);
  v_r := public.get_port_contracts(null);
  if (v_r->>'reason') is distinct from 'not_authenticated' then
    raise exception 'HAUL-3 self-assert FAIL: unauthenticated read did not envelope-reject: %', v_r;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  v_r := public.get_port_contracts(null);
  if (v_r->>'reason') is distinct from 'haul_contracts_disabled' then
    raise exception 'HAUL-3 self-assert FAIL: dark read did not gate-first reject: %', v_r;
  end if;
  -- 3b. get_my_captain_instances still auth-first (the 0110/0123 shape): no subject → not_authenticated.
  perform set_config('request.jwt.claims', '', true);
  v_r := public.get_my_captain_instances();
  if (v_r->>'reason') is distinct from 'not_authenticated' then
    raise exception 'C2-3 self-assert FAIL: unauthenticated roster read did not envelope-reject: %', v_r;
  end if;

  -- 4. get_my_captain_instances parity + hunk: the re-created body carries the two additive
  --    projection keys AND still the 0123 spot-pins (gate reject, newest-first order, the
  --    assignment left join, query-scoped player read). ACL authenticated-only.
  select prosrc into v_src from pg_proc where oid = 'public.get_my_captain_instances()'::regprocedure;
  if v_src not like '%''xp'',%' or v_src not like '%''level'',%' then
    raise exception 'C2-3 self-assert FAIL: projection lacks the xp/level hunk';
  end if;
  if v_src not like '%captain_assignment_disabled%'
     or v_src not like '%order by i.created_at desc%'
     or v_src not like '%left join public.ship_captain_assignments a%'
     or v_src not like '%i.player_id = v_player%' then
    raise exception 'C2-3 self-assert FAIL: 0123 parity spot-pins missing (head drifted)';
  end if;
  if not has_function_privilege('authenticated', 'public.get_my_captain_instances()', 'execute')
     or has_function_privilege('anon', 'public.get_my_captain_instances()', 'execute') then
    raise exception 'C2-3 self-assert FAIL: get_my_captain_instances ACL drifted';
  end if;

  -- 5. Both feature gates STILL dark (this migration writes no flag). captain_assignment_enabled
  --    is the roster surface's own (possibly-lit) flag — deliberately NOT asserted.
  if public.cfg_bool('haul_contracts_enabled') then
    raise exception 'HAUL-3 self-assert FAIL: haul_contracts_enabled is not false after this migration';
  end if;
  if public.cfg_bool('captain_growth_enabled') then
    raise exception 'C2-3 self-assert FAIL: captain_growth_enabled is not false after this migration';
  end if;

  raise notice 'HAUL-3/C2-3 self-assert ok: get_port_contracts gated read (auth -> gate-first -> fresh-offered + caller-scoped mine; authenticated-only); get_my_captain_instances 0123-parity re-create with the xp/level hunk (gate/order/join pins intact); dark dry-runs clean; both feature flags still dark';
end $$;
