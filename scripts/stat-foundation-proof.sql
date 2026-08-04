-- ══════════════════════════════════════════════════════════════════════════════════════════════
-- STAT FOUNDATION (0340) — PARITY / DIFFERENCE HARNESS, on a disposable chain, self-rolling-back.
--
-- The migration's own self-asserts prove the pure arithmetic on SYNTHETIC input (they read no game
-- row, so they are non-vacuous on an empty chain). This script proves the thing a self-assert
-- structurally cannot: that the canonical resolver, run over REAL constructed ships, agrees with
-- the deployed authority everywhere it is supposed to — and differs in EXACTLY the places the
-- owner decided it should, and nowhere else.
--
-- It builds its OWN fixtures (users, hulls, module types, module instances, fittings, captains,
-- a ship group). It depends on NO production data and NO seeded content it did not insert itself.
-- Everything runs inside ONE transaction that ends in ROLLBACK.
--
-- THE PREDECESSOR: calculate_group_expedition_stats(p_player, p_group_id, p_activity_type)
-- (0166:58, never redefined). Six live callers, three key-shapes — enumerated in migration 0340's
-- section 4. This slice does NOT change it, does NOT call it from the new resolver, and is NOT
-- called by it. The two coexist precisely because the new foundation drives nothing.
-- ══════════════════════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

begin;

-- ── SETUP ────────────────────────────────────────────────────────────────────────────────────────
create temporary table sf_ctx (k text primary key, v uuid) on commit drop;
create temporary table sf_out (k text primary key, v jsonb) on commit drop;

do $setup$
declare
  u1 uuid;
  g1 uuid;
  s1 uuid; s2 uuid; s3 uuid;
  m1 uuid; m2 uuid;
  mt_scan text := 'sf_mod_scanner';
  mt_lite text := 'sf_mod_scanner_lite';
begin
  -- a fixture player
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
                          created_at,updated_at,confirmation_token,recovery_token,
                          email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'sf.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into u1;
  insert into sf_ctx values ('u1', u1);

  -- THREE OWN hull types, so every aggregation rule is distinguishable (a fleet of identical ships
  -- cannot tell sum from max from min).
  insert into public.main_ship_hull_types
    (hull_type_id, name, description, base_hp, base_speed, base_cargo_capacity,
     base_cargo_capacity_m3, base_support_capacity, base_captain_slots, base_module_slots,
     base_stats_json)
  values
    ('sf_hull_a','SF A','proof hull A', 100, 1.000, 50, 50.0, 10, 2, 3, '{"attack": 15, "defense": 10}'::jsonb),
    ('sf_hull_b','SF B','proof hull B', 100, 2.000, 50, 50.0, 10, 2, 3, '{"attack": 5,  "defense": 15}'::jsonb),
    ('sf_hull_c','SF C','proof hull C', 100, 3.000, 50, 50.0, 10, 2, 3, '{"attack": 30, "defense": 10}'::jsonb)
  on conflict (hull_type_id) do nothing;

  insert into public.ship_groups (player_id, group_index, name)
    values (u1, 1, 'SF Team') returning group_id into g1;
  insert into sf_ctx values ('g1', g1);

  -- three ships, one group. Inserted DIRECTLY (never via the commission path) so no traits are
  -- rolled and the fixture is exactly what this script says it is.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, hp, max_hp, cargo_capacity,
     cargo_capacity_m3, support_capacity, captain_slots, module_slots, group_id)
  select u1, h.hull_type_id, 'SF '||h.hull_type_id, 'stationary', 'at_location',
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
         h.base_support_capacity, h.base_captain_slots, h.base_module_slots, g1
    from public.main_ship_hull_types h where h.hull_type_id = 'sf_hull_a'
  returning main_ship_id into s1;
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, hp, max_hp, cargo_capacity,
     cargo_capacity_m3, support_capacity, captain_slots, module_slots, group_id)
  select u1, h.hull_type_id, 'SF '||h.hull_type_id, 'stationary', 'at_location',
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
         h.base_support_capacity, h.base_captain_slots, h.base_module_slots, g1
    from public.main_ship_hull_types h where h.hull_type_id = 'sf_hull_b'
  returning main_ship_id into s2;
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, hp, max_hp, cargo_capacity,
     cargo_capacity_m3, support_capacity, captain_slots, module_slots, group_id)
  select u1, h.hull_type_id, 'SF '||h.hull_type_id, 'stationary', 'at_location',
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
         h.base_support_capacity, h.base_captain_slots, h.base_module_slots, g1
    from public.main_ship_hull_types h where h.hull_type_id = 'sf_hull_c'
  returning main_ship_id into s3;
  insert into sf_ctx values ('s1', s1), ('s2', s2), ('s3', s3);

  -- OWN module types (module_types.id is TEXT). The scan/evasion pair is what makes the two
  -- owner-decided aggregation corrections visible; the cargo key is what makes the QUARANTINE
  -- visible. slot_type 'sensor' is chosen deliberately: its speed-penalty arm is 0, so the fleet
  -- speed stays exactly the hull minimum and the speed assertion cannot be confounded.
  insert into public.module_types (id, name, description, slot_type, slot_cost, stats_json)
    values (mt_scan, 'SF Scanner', 'proof scan module', 'sensor', 1,
            '{"scan": 6, "evasion": 4, "cargo": 25}'::jsonb),
           (mt_lite, 'SF Scanner Lite', 'proof scan module 2', 'sensor', 1,
            '{"scan": 2, "evasion": 1}'::jsonb);

  insert into public.module_instances (player_id, module_type_id, mint_key)
    values (u1, mt_scan, 'sf_mint_'||replace(gen_random_uuid()::text,'-','')) returning id into m1;
  insert into public.module_instances (player_id, module_type_id, mint_key)
    values (u1, mt_lite, 'sf_mint_'||replace(gen_random_uuid()::text,'-','')) returning id into m2;
  insert into public.ship_module_fittings (main_ship_id, module_instance_id, player_id)
    values (s1, m1, u1), (s2, m2, u1);
end $setup$;

-- ── BLOCK 1 — SHIP-SCOPE PARITY vs the deployed fold ─────────────────────────────────────────────
do $b1$
declare
  u1 uuid := (select v from sf_ctx where k='u1');
  s  uuid;
  n  integer;
  legacy jsonb;
  canon  jsonb;
  key    text;
  lv numeric; cv numeric;
begin
  select count(*) into n from sf_ctx where k in ('s1','s2','s3');
  if n <> 3 then raise exception 'SF-PROOF: fixture guard — expected 3 ships, got %', n; end if;

  for s in select v from sf_ctx where k in ('s1','s2','s3') order by k loop
    legacy := public.calculate_expedition_stats(u1, s, '[]'::jsonb, 'pirate_hunt');
    canon  := public.resolve_effective_stats('ship', s);

    -- Every stat EXCEPT the quarantined cargo_capacity must agree exactly.
    foreach key in array array['combat_power','survival','speed','repair','scouting',
                               'mining_yield','retreat_safety','pirate_attention'] loop
      lv := (legacy ->> key)::numeric;
      cv := (canon -> 'stats' ->> key)::numeric;
      if lv is distinct from cv then
        raise exception 'SF-PROOF FAIL: ship % stat % — deployed fold says %, canonical resolver says %', s, key, lv, cv;
      end if;
    end loop;
  end loop;
  raise notice 'SF_PASS_SHIP_PARITY';
end $b1$;

-- ── BLOCK 2 — THE CARGO QUARANTINE IS VISIBLE AND INTENDED ───────────────────────────────────────
-- Ship 1 carries a module declaring {"cargo": 25}. The deployed fold ADDS it to the unitless
-- integer; the canonical resolver does NOT, because the volume authority (fleet_hold_capacity_m3,
-- 0333) is the real cargo authority and the unitless number expands no hold. This difference is
-- the whole point of the quarantine, so it is asserted to EXIST, not merely tolerated.
do $b2$
declare
  u1 uuid := (select v from sf_ctx where k='u1');
  s1 uuid := (select v from sf_ctx where k='s1');
  legacy jsonb; canon jsonb;
begin
  legacy := public.calculate_expedition_stats(u1, s1, '[]'::jsonb, 'pirate_hunt');
  canon  := public.resolve_effective_stats('ship', s1);
  if (legacy ->> 'cargo_capacity')::numeric <> 75 then
    raise exception 'SF-PROOF FAIL: the deployed fold no longer adds the module cargo key (want 50+25=75, got %)',
      (legacy ->> 'cargo_capacity'); end if;
  if (canon -> 'stats' ->> 'cargo_capacity')::numeric <> 50 then
    raise exception 'SF-PROOF FAIL: a cargo contribution reached the QUARANTINED canonical cargo_capacity (want the bare base 50, got %)',
      (canon -> 'stats' ->> 'cargo_capacity'); end if;
  raise notice 'SF_PASS_CARGO_QUARANTINE';
end $b2$;

-- ── BLOCK 3 — FLEET PARITY AND THE TWO INTENDED DIFFERENCES ──────────────────────────────────────
do $b3$
declare
  u1 uuid := (select v from sf_ctx where k='u1');
  g1 uuid := (select v from sf_ctx where k='g1');
  legacy jsonb; canon jsonb; t jsonb;
  key text; lv numeric; cv numeric;
begin
  legacy := public.calculate_group_expedition_stats(u1, g1, 'pirate_hunt');
  t := legacy -> 'totals';
  canon := public.resolve_effective_stats('fleet', g1);
  insert into sf_out values ('legacy_totals', t), ('canon_fleet', canon -> 'stats');

  if (canon ->> 'member_count')::integer <> 3 then
    raise exception 'SF-PROOF FAIL: canonical fleet resolution saw % member(s), want 3', (canon ->> 'member_count'); end if;

  -- (a) THE SHAPES THE SIX LIVE CALLERS ACTUALLY READ MUST NOT MOVE.
  --     A1/A2/A4 read totals.speed (min). A3/A5 read combat_power + survival (both sum).
  foreach key in array array['speed','combat_power','survival','repair','mining_yield','pirate_attention'] loop
    lv := (t ->> key)::numeric;
    cv := (canon -> 'stats' ->> key)::numeric;
    if lv is distinct from cv then
      raise exception 'SF-PROOF FAIL: fleet stat % moved — deployed authority %, canonical %. This shape is read by a LIVE caller.', key, lv, cv;
    end if;
  end loop;
  -- the exact values, spelled out, so a silent double-change cannot cancel out
  if (canon -> 'stats' ->> 'combat_power')::numeric <> 50 then
    raise exception 'SF-PROOF FAIL: fleet combat_power want 15+5+30=50, got %', (canon -> 'stats' ->> 'combat_power'); end if;
  if (canon -> 'stats' ->> 'survival')::numeric <> 35 then
    raise exception 'SF-PROOF FAIL: fleet survival want 10+15+10=35, got %', (canon -> 'stats' ->> 'survival'); end if;
  if (canon -> 'stats' ->> 'speed')::numeric <> 1.000 then
    raise exception 'SF-PROOF FAIL: fleet speed is not the MINIMUM member speed (want 1.000, got %)', (canon -> 'stats' ->> 'speed'); end if;
  raise notice 'SF_PASS_FLEET_LIVE_SHAPES_UNCHANGED';

  -- (b) THE TWO INTENDED DIFFERENCES — asserted to EXIST, with their exact before/after.
  --     scouting: legacy SUM 6+2+0 = 8 ; canonical MAX = 6
  if (t ->> 'scouting')::numeric <> 8 then
    raise exception 'SF-PROOF FAIL: the deployed authority no longer SUMS scouting (want 8, got %)', (t ->> 'scouting'); end if;
  if (canon -> 'stats' ->> 'scouting')::numeric <> 6 then
    raise exception 'SF-PROOF FAIL: canonical scouting is not the MAX (want 6, got %)', (canon -> 'stats' ->> 'scouting'); end if;
  --     retreat_safety: legacy SUM 4+1+0 = 5 ; canonical MIN = 0 (the ship with no evasion module)
  if (t ->> 'retreat_safety')::numeric <> 5 then
    raise exception 'SF-PROOF FAIL: the deployed authority no longer SUMS retreat_safety (want 5, got %)', (t ->> 'retreat_safety'); end if;
  if (canon -> 'stats' ->> 'retreat_safety')::numeric <> 0 then
    raise exception 'SF-PROOF FAIL: canonical retreat_safety is not the MIN (want 0, got %)', (canon -> 'stats' ->> 'retreat_safety'); end if;
  raise notice 'SF_PASS_INTENDED_DIFFERENCES';

  -- (c) NO OTHER DIFFERENCE EXISTS. Every key of the deployed totals is compared; only the two
  --     decided ones and the quarantined cargo may differ, and a NEW difference fails here.
  for key in select k from jsonb_object_keys(t) k loop
    if key in ('scouting','retreat_safety','cargo_capacity') then continue; end if;
    lv := (t ->> key)::numeric;
    cv := (canon -> 'stats' ->> key)::numeric;
    if lv is distinct from cv then
      raise exception 'SF-PROOF FAIL: UNDECLARED fleet difference on % — deployed %, canonical %', key, lv, cv;
    end if;
  end loop;
  raise notice 'SF_PASS_NO_UNDECLARED_DIFFERENCE';
end $b3$;

-- ── BLOCK 4 — THE EMPTY FLEET: the one behavioural difference that is a FIX ──────────────────────
-- The deployed authority RAISES empty_group (0166:105). The canonical aggregation returns an
-- explicit not-applicable result. Neither returns 0, and that is the point.
do $b4$
declare
  u1 uuid := (select v from sf_ctx where k='u1');
  g2 uuid;
  canon jsonb;
  raised boolean := false;
begin
  insert into public.ship_groups (player_id, group_index, name)
    values (u1, 2, 'SF Empty') returning group_id into g2;

  begin
    perform public.calculate_group_expedition_stats(u1, g2, 'pirate_hunt');
  exception when others then
    raised := true;
    if strpos(sqlerrm, 'empty_group') = 0 then
      raise exception 'SF-PROOF FAIL: the deployed authority raised something other than empty_group: %', sqlerrm; end if;
  end;
  if not raised then
    raise exception 'SF-PROOF FAIL: the deployed authority did NOT raise on an empty group'; end if;

  canon := public.resolve_effective_stats('fleet', g2);
  if (canon ->> 'member_count')::integer <> 0 or (canon ->> 'applicable')::boolean then
    raise exception 'SF-PROOF FAIL: an empty fleet did not resolve to member_count 0 / applicable false'; end if;
  if canon -> 'stats' <> '{}'::jsonb then
    raise exception 'SF-PROOF FAIL: an empty fleet produced stat VALUES — an empty fleet is not a fleet of zeroes'; end if;
  if canon -> 'not_applicable' -> 'combat_power' is null then
    raise exception 'SF-PROOF FAIL: an empty fleet did not report combat_power as explicitly not applicable'; end if;
  raise notice 'SF_PASS_EMPTY_FLEET_EXPLICIT';
end $b4$;

-- ── BLOCK 5 — SINGLE-SHIP FLEET: aggregation collapses to the member ─────────────────────────────
do $b5$
declare
  u1 uuid := (select v from sf_ctx where k='u1');
  s1 uuid := (select v from sf_ctx where k='s1');
  g3 uuid;
  ship jsonb; fleet jsonb; key text;
begin
  insert into public.ship_groups (player_id, group_index, name)
    values (u1, 3, 'SF Solo') returning group_id into g3;
  update public.main_ship_instances set group_id = g3 where main_ship_id = s1;

  ship  := public.resolve_effective_stats('ship', s1);
  fleet := public.resolve_effective_stats('fleet', g3);
  if (fleet ->> 'member_count')::integer <> 1 then
    raise exception 'SF-PROOF FAIL: single-ship fleet reported % members', (fleet ->> 'member_count'); end if;
  foreach key in array array['combat_power','survival','speed','scouting','retreat_safety',
                             'repair','mining_yield','pirate_attention'] loop
    if (ship -> 'stats' ->> key)::numeric is distinct from (fleet -> 'stats' ->> key)::numeric then
      raise exception 'SF-PROOF FAIL: single-ship fleet % (%) does not equal its member (%)',
        key, (fleet -> 'stats' ->> key), (ship -> 'stats' ->> key); end if;
  end loop;
  update public.main_ship_instances set group_id = (select v from sf_ctx where k='g1') where main_ship_id = s1;
  raise notice 'SF_PASS_SINGLE_SHIP_FLEET';
end $b5$;

-- ── BLOCK 6 — PROVENANCE RECONCILES EXACTLY TO THE RESULT ────────────────────────────────────────
do $b6$
declare
  s1 uuid := (select v from sf_ctx where k='s1');
  canon jsonb; key text; n integer; last_running numeric; emitted numeric;
begin
  canon := public.resolve_effective_stats('ship', s1);
  select count(*) into n from jsonb_array_elements(canon -> 'breakdown');
  if n < 9 then
    raise exception 'SF-PROOF FAIL: breakdown has only % entries — provenance guard would be vacuous', n; end if;

  foreach key in array array['combat_power','survival','speed','scouting','retreat_safety',
                             'repair','mining_yield','pirate_attention','cargo_capacity'] loop
    select (b.value ->> 'running')::numeric into last_running
      from jsonb_array_elements(canon -> 'breakdown') with ordinality as b(value, ord)
     where b.value ->> 'stat_id' = key and b.value ->> 'running' is not null
     order by b.ord desc limit 1;
    emitted := (canon -> 'stats' ->> key)::numeric;
    if last_running is distinct from emitted then
      raise exception 'SF-PROOF FAIL: breakdown for % ends at % but the emitted stat is % — provenance that does not add up is worse than none',
        key, last_running, emitted; end if;
  end loop;
  raise notice 'SF_PASS_BREAKDOWN_RECONCILES';
end $b6$;

-- ── BLOCK 7 — DETERMINISM OVER REAL ROWS ─────────────────────────────────────────────────────────
do $b7$
declare
  s1 uuid := (select v from sf_ctx where k='s1');
  g1 uuid := (select v from sf_ctx where k='g1');
  ts timestamptz := '2026-08-04T12:00:00+00:00';
  a jsonb; b jsonb;
begin
  a := public.resolve_effective_stats('ship', s1, '{}'::jsonb, ts);
  b := public.resolve_effective_stats('ship', s1, '{}'::jsonb, ts);
  if a is distinct from b then
    raise exception 'SF-PROOF FAIL: two identical ship resolutions are not byte-identical'; end if;
  if a is distinct from a::text::jsonb then
    raise exception 'SF-PROOF FAIL: a ship resolution is not stable across a JSONB round trip'; end if;
  a := public.resolve_effective_stats('fleet', g1, '{}'::jsonb, ts);
  b := public.resolve_effective_stats('fleet', g1, '{}'::jsonb, ts);
  if a is distinct from b then
    raise exception 'SF-PROOF FAIL: two identical fleet resolutions are not byte-identical'; end if;
  raise notice 'SF_PASS_DETERMINISM_ON_REAL_ROWS';
end $b7$;

-- ── BLOCK 8 — THE FOLD REFUSES MALFORMED SOURCE DATA (no silent fallback hull) ───────────────────
do $b8$
declare
  s1 uuid := (select v from sf_ctx where k='s1');
  ok boolean := false;
begin
  update public.main_ship_hull_types
     set base_stats_json = '{"attack": "fifteen", "defense": 10}'::jsonb
   where hull_type_id = 'sf_hull_a';
  begin
    perform public.resolve_effective_stats('ship', s1);
  exception when others then
    ok := true;
    if strpos(sqlerrm, 'malformed contribution') = 0 then
      raise exception 'SF-PROOF FAIL: a malformed hull raised the wrong error: %', sqlerrm; end if;
  end;
  if not ok then
    raise exception 'SF-PROOF FAIL: a malformed hull stat was silently folded — the resolver fabricated a stat'; end if;
  update public.main_ship_hull_types
     set base_stats_json = '{"attack": 15, "defense": 10}'::jsonb
   where hull_type_id = 'sf_hull_a';

  -- and it resolves cleanly again once the source is well-formed: the refusal was about the DATA,
  -- not a permanently broken resolver.
  if (public.resolve_effective_stats('ship', s1) -> 'stats' ->> 'combat_power')::numeric <> 15 then
    raise exception 'SF-PROOF FAIL: the resolver did not recover after the malformed source was corrected'; end if;
  raise notice 'SF_PASS_MALFORMED_REFUSED';
end $b8$;

-- ── BLOCK 9 — THE INSPECTION SURFACE: it works, and it does not leak ─────────────────────────────
do $b9$
declare
  g1 uuid := (select v from sf_ctx where k='g1');
  reg jsonb;
begin
  reg := public.get_stat_definitions();
  if not (reg ->> 'ok')::boolean then
    raise exception 'SF-PROOF FAIL: get_stat_definitions did not return ok'; end if;
  if jsonb_array_length(reg -> 'registry' -> 'stat_ids') <> 9 then
    raise exception 'SF-PROOF FAIL: the inspectable registry does not expose 9 stats (got %)',
      jsonb_array_length(reg -> 'registry' -> 'stat_ids'); end if;

  -- Unauthenticated (auth.uid() is null in this context) must be refused, not served.
  if (public.get_my_effective_stats('fleet', g1) ->> 'error') is distinct from 'not_authenticated' then
    raise exception 'SF-PROOF FAIL: get_my_effective_stats served a caller with no auth.uid() — the ownership scope is not enforced'; end if;
  raise notice 'SF_PASS_INSPECTION_SURFACE';
end $b9$;

-- ── BLOCK 10 — THE SLICE IS STILL INERT: the live engine carries no 0340 token ───────────────────
do $b10$
declare
  n integer := 0;
  r record;
begin
  for r in
    select p.proname, p.prosrc from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname in ('calculate_expedition_stats','calculate_group_expedition_stats',
                         'combat_create_group_encounter','process_combat_ticks',
                         'command_ship_group_go','command_ship_group_dock',
                         'pirate_intercept_plan_leg','process_pirate_route_legs',
                         'get_my_group_expedition_totals')
  loop
    n := n + 1;
    if strpos(r.prosrc, 'resolve_effective_stats') > 0
       or strpos(r.prosrc, 'stat_definitions') > 0
       or strpos(r.prosrc, 'stat_aggregate_fleet') > 0
       or strpos(r.prosrc, 'buff_instances') > 0 then
      raise exception 'SF-PROOF FAIL: live engine function % carries a 0340 token — the slice is NOT unused', r.proname;
    end if;
  end loop;
  if n < 9 then
    raise exception 'SF-PROOF: inertness guard would be vacuous — only % of 9 engine functions found', n; end if;
  raise notice 'SF_PASS_ENGINE_STILL_INERT';
end $b10$;

rollback;
