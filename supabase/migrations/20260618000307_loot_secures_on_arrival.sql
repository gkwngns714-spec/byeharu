-- 0307 — LOOT SECURES ON ARRIVAL: the 'space' settle arm deposits the reward it carries.
--
-- THE DEFECT. A fleet that survives a fight and retreats to a destination the player CHOSE received
-- NOTHING. The tick's retreat-completion branch (head 0299:602-618) mints the leg with
-- target_type='space' for EVERY ordered destination — a port resolves to its own coordinate
-- (0299:609-610) and a bare point is used as stored — and only the no-destination fallback mints
-- 'base' (0299:616-617). The earned bundle rides the leg either way (movement_attach_cargo,
-- 0299:625-627). But movement_settle_arrival (sole definition 0208:90-173) deposits ONLY in its
-- 'base' arm (0208:153-155); the 'space' arm (0208:163-166) settles the fleet and returns without
-- ever reading m.reward_payload_json. Its own comment said "no rewards (that is the base branch's
-- job) … unreachable in production until the gate is lit" — 0300 lit the gate, 0292/0298 made the
-- chosen-destination exit the one the design steers players to, and nobody revisited the arm. The
-- NO-HOME law says ports are the only base, so the exact exit the game makes the goal paid zero.
--
-- THE FIX — compose, never fork. The 'space' arm now runs the SAME deposit the 'base' arm runs:
-- the same payload/source guard, the same sole depositor (reward_grant), the same idempotency
-- (reward_grants UNIQUE (source_type, source_id)). The only new question is WHICH store, and both
-- answers are existing authorities, composed:
--   (a) arrival coordinate = an active dockable port's own coordinate (every port-destination
--       retreat, by construction) → the player's store AT that port via get_or_create_store (0157),
--       with dockability judged by its own is_home_port_eligible — NO-HOME-correct, and the same
--       store surface mining/exploration securing already deposits toward;
--   (b) anywhere else in open space → the player's oldest active base, the proven securing-
--       processor idiom verbatim (0221:1031-1036 / :1073-1078).
-- No third resolver. No new reward path. No flag (dark-first is suspended by owner order — this
-- ships LIT; the arm is reached only by legs that already exist and already carry cargo).
--
-- THE 'location' ARM IS A DELIBERATE, REASONED NON-GOAL. It still grants nothing, because no
-- cargo-carrying 'location' leg can exist: movement_attach_cargo's ONLY live call site is
-- process_combat_ticks' retreat-completion branch (head 0299:308 — 0301:115-117 records that 0301
-- deliberately did not re-emit it), which attaches at 0299:626 to the leg minted at 0299:608-618 —
-- always target_type 'space' or 'base'. combat_flee_pending (0230:205-211) mints a 'base' leg and
-- attaches nothing; movement_create seeds reward_payload_json '{}' (0030:20). A granter in the
-- 'location' arm would be dead code guarding a state no writer produces.
--
-- HOW THE TWO BODIES ARE REWRITTEN — the 0303/0305/0306 method, never retyped: each site is located
-- by its EXACT deployed text (sliced out of the defining migration by
-- scripts/gen-0307-loot-secures-on-arrival.mjs), asserted to occur EXACTLY ONCE in
-- pg_get_functiondef, replaced, re-executed; the length must move by exactly the hunk delta. The
-- second site is COMMENT-ONLY: command_ship_group_go's retreat arm told the next author that naming
-- a destination forfeits the deposit — true before this migration, a lie after it, and comments in
-- this codebase get copied into code. Its code is untouched (the self-asserts pin that).
--
-- CLIENT HALF (same slice, per the half-a-slice law): teamMove.ts's "rewards are lost" copy and its
-- retreatCarriesLoot helper are DELETED (they documented this defect as a rule of the game and
-- named a "base" the NO-HOME law deleted); ActiveCombatPanel's "returns to base" reward footer says
-- what is now true; and the raw-Postgres-text leak on double-pressed Retreat / raced Flee is mapped
-- to player copy (combatReasonMessage.ts).
--
-- RUNTIME PROOF: scripts/fleetgo-proof.sql BLOCK LOOT-SECURES — a real fight earns a bundle, the
-- player orders the retreat to a chosen port mid-combat, the leg arrives, and the bundle lands in
-- the player's store at that port (lazily minted by the settle); an open-space destination lands it
-- at the oldest store; a no-destination retreat still lands through the untouched 'base' arm; a
-- replayed settle does not double-credit. A migration cannot mint fleets (auth.users FKs), so the
-- behavioural proof lives there, against CI's disposable Postgres.
--
-- ROLLBACK: re-run 0208's movement_settle_arrival definition and 0301's command_ship_group_go
-- definition (with the 0305/0306 rewrites re-applied on top). Nothing else here writes state.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ── 1. PRECONDITIONS (read-only; nothing is written unless all pass) ─────────────────────────────
do $pre$
declare
  v_missing text;
begin
  select string_agg(f, ', ') into v_missing
    from unnest(array[
      'public.movement_settle_arrival',
      'public.command_ship_group_go',
      'public.reward_grant',
      'public.get_or_create_store',
      'public.is_home_port_eligible',
      'public.fleet_set_in_space'
    ]) as f
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname || '.' || p.proname = f);
  if v_missing is not null then
    raise exception '0307 PRECONDITION FAIL: missing function(s): %', v_missing;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleet_movements'
                    and column_name = 'reward_payload_json')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fleet_movements'
                    and column_name = 'reward_source_type')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'locations'
                    and column_name = 'x')
     or not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'bases'
                    and column_name = 'location_id') then
    raise exception '0307 PRECONDITION FAIL: a column the deposit resolver reads is absent';
  end if;

  -- Capture the settle's ACL posture NOW; asserted UNCHANGED after the rewrite (derived, never
  -- hard-coded — the proofs-never-assert-ambient-defaults rule).
  create temp table _0307_acl on commit drop as
    select has_function_privilege('authenticated', 'public.movement_settle_arrival(uuid)', 'execute') as can_exec;
end $pre$;

-- ── 2. REWRITE THE TWO SITES (located by exact deployed text, never retyped) ─────────────────────
do $rewrite$
declare
  r      record;
  v_oid  oid;
  v_n    integer;
  v_src  text;
  v_new  text;
  v_done integer := 0;
begin
  for r in
    select * from (values
    (0, 'movement_settle_arrival',
     $s0o$  -- ★ THE ONLY DELTA vs the 0153 head ★ — FLEET-GO 3b: a coordinate arrival parks the fleet in open
  -- space at the target. No presence (open space has no location), no units merge (nothing to come
  -- home to), no rewards (that is the base branch's job), and — as everywhere in this charter — NO
  -- ship write. Only the unified mover can create a 'space' target, and it is dark, so this branch is
  -- unreachable in production until the gate is lit.
  elsif m.target_type = 'space' then
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform public.fleet_set_in_space(m.fleet_id, m.target_x, m.target_y);
    return jsonb_build_object('settled', true, 'outcome', 'in_space', 'movement_id', m.id);$s0o$,
     $s0n$  -- ★ FLEET-GO 3b (0208), REWRITTEN BY 0307: LOOT SECURES ON ARRIVAL ★ — a coordinate arrival
  -- parks the fleet in open space at the target. No presence (open space has no location), no
  -- units merge, and — as everywhere in the charter — NO ship write. The 0208 text also said
  -- "no rewards" and called this branch unreachable while the mover was dark; 0300 lit the gate,
  -- and the chosen-destination retreat (0292/0298) made this the arrival every surviving fight
  -- is steered to — and it paid nothing. 0307 retires that: the bundle this movement carries
  -- (attached by the tick's retreat-completion branch, 0299:626) is deposited HERE, by the same
  -- sole depositor the 'base' arm calls, under the same guard, idempotent the same way
  -- (reward_grants UNIQUE (source_type, source_id)); a replayed settle cannot even re-enter this
  -- arm, because the guarded locked re-read above only admits status='moving'.
  elsif m.target_type = 'space' then
    update fleet_movements set status = 'arrived', resolved_at = now() where id = m.id;
    perform public.fleet_set_in_space(m.fleet_id, m.target_x, m.target_y);
    if m.reward_payload_json is not null and m.reward_payload_json <> '{}'::jsonb and m.reward_grant_source is not null then
      declare
        v_port    uuid;
        v_deposit uuid;
      begin
        -- Deposit target (NO-HOME): a port-destination retreat resolves the ordered port to its
        -- own l.x/l.y and mints the leg with exactly those values (0299:608-614), so an arrival
        -- coordinate that IS an active dockable port's coordinate deposits into the player's
        -- store AT that port — get_or_create_store, the one store authority (0157); dockability
        -- is judged by ITS own predicate (is_home_port_eligible), called here only to pick the
        -- candidate, never re-implemented. Anywhere else in open space: the proven securing-
        -- processor idiom, the player's oldest active base (0221:1031-1036, verbatim). Never
        -- grant against NULL — that would burn the one idempotency key on a half deposit; with
        -- no reward_grants row written, the bundle stays grantable by a future repair.
        select l.id into v_port
          from locations l
         where l.status = 'active' and l.x = m.target_x and l.y = m.target_y
           and public.is_home_port_eligible(l.id)
         order by l.created_at, l.id
         limit 1;
        if v_port is not null then
          v_deposit := public.get_or_create_store(m.player_id, v_port);
        else
          select b.id into v_deposit
            from bases b
           where b.player_id = m.player_id and b.status = 'active'
           order by b.created_at
           limit 1;
        end if;
        if v_deposit is not null then
          perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, v_deposit, m.reward_payload_json);
        end if;
      end;
    end if;
    return jsonb_build_object('settled', true, 'outcome', 'in_space', 'movement_id', m.id);$s0n$),
    (1, 'command_ship_group_go',
     $s1o$          -- Loot earned BEFORE the order rides the leg as cargo but is only ever DEPOSITED by a BASE
          -- arrival (the settle's base branch, untouched here), so naming a destination forfeits the
          -- deposit until the fleet later returns to a base. Surfaced, never hidden.$s1o$,
     $s1n$          -- Loot earned BEFORE the order rides the leg as cargo and is DEPOSITED ON ARRIVAL
          -- (0307): a port destination banks it in the player's store at that port; an open-space
          -- destination banks it at the oldest active store. Choosing a destination costs nothing.$s1n$)
    ) as t(idx, fname, old_t, new_t)
    order by idx
  loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_oid is null then
      raise exception '0307 REWRITE FAIL [%]: function public.% not found', r.idx, r.fname;
    end if;
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = r.fname) <> 1 then
      raise exception '0307 REWRITE FAIL [%]: public.% is overloaded — refusing to guess', r.idx, r.fname;
    end if;

    v_src := pg_get_functiondef(v_oid);
    v_n := (length(v_src) - length(replace(v_src, r.old_t, ''))) / length(r.old_t);
    if v_n <> 1 then
      raise exception '0307 REWRITE FAIL [%]: hunk text occurs % time(s) in public.%, expected exactly 1 — the deployed body is not what this migration was generated against',
        r.idx, v_n, r.fname;
    end if;

    v_new := replace(v_src, r.old_t, r.new_t);
    -- Length must move by exactly the hunk delta: proof that replace() touched nothing else.
    if length(v_new) <> length(v_src) - length(r.old_t) + length(r.new_t) then
      raise exception '0307 REWRITE FAIL [%]: unexpected length delta rewriting public.%', r.idx, r.fname;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_done <> 2 then
    raise exception '0307 REWRITE FAIL: rewrote % site(s), expected 2', v_done;
  end if;
  raise notice '0307: rewrote % site(s) — the space arrival deposits, the mover comment stops lying', v_done;
end $rewrite$;

-- ── 3. SELF-ASSERT (deploy-time; raises and rolls the whole deploy back on failure) ──────────────
-- ONE DO BLOCK PER CHECK (the 0305 house shape): the Supabase CLI reports only "At statement: N",
-- so the statement number must BE the diagnosis. Probes that must NOT find a token strip SQL line
-- comments first (pg_get_functiondef keeps comments, and the new banner deliberately names the
-- retired words — probe CODE, never prose; the 0303 lesson).

-- (a) the settle now has exactly TWO depositor calls — the 'base' arm's and the 'space' arm's —
--     and exactly ONE store resolution. Zero or one grant = the defect survives; three = a fork.
do $assert_a$
declare
  v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'movement_settle_arrival';
  if (length(v_code) - length(replace(v_code, 'perform reward_grant(', ''))) / length('perform reward_grant(') <> 2 then
    raise exception '0307 SELF-ASSERT (a) FAIL: movement_settle_arrival must call reward_grant exactly twice (base arm + space arm)';
  end if;
  if (length(v_code) - length(replace(v_code, 'get_or_create_store', ''))) / length('get_or_create_store') <> 1 then
    raise exception '0307 SELF-ASSERT (a) FAIL: movement_settle_arrival must resolve the port store exactly once';
  end if;
end $assert_a$;

-- (b) the space arm still PARKS first and deposits after: fleet_set_in_space precedes the store
--     resolution in code, and the arm still answers outcome 'in_space'.
do $assert_b$
declare
  v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'movement_settle_arrival';
  if position('fleet_set_in_space' in v_code) = 0
     or position('get_or_create_store' in v_code) = 0
     or position('fleet_set_in_space' in v_code) > position('get_or_create_store' in v_code) then
    raise exception '0307 SELF-ASSERT (b) FAIL: the space arm must park the fleet BEFORE it deposits';
  end if;
  if position('''outcome'', ''in_space''' in v_code) = 0 then
    raise exception '0307 SELF-ASSERT (b) FAIL: the space arm no longer answers outcome in_space — parity broke';
  end if;
end $assert_b$;

-- (c) the base arm is UNTOUCHED and the space arm uses the IDENTICAL guard: the base arm's exact
--     deposit call survives, and the payload/source guard line appears exactly twice.
do $assert_c$
declare
  v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'movement_settle_arrival';
  if position('perform reward_grant(m.reward_source_type, m.reward_grant_source, m.player_id, m.target_base_id, m.reward_payload_json);' in v_code) = 0 then
    raise exception '0307 SELF-ASSERT (c) FAIL: the base arm''s deposit call changed — parity broke';
  end if;
  if (length(v_code) - length(replace(v_code, 'if m.reward_payload_json is not null and m.reward_payload_json <> ''{}''::jsonb and m.reward_grant_source is not null then', '')))
     / length('if m.reward_payload_json is not null and m.reward_payload_json <> ''{}''::jsonb and m.reward_grant_source is not null then') <> 2 then
    raise exception '0307 SELF-ASSERT (c) FAIL: the payload/source guard must appear exactly twice (base arm + space arm, identical)';
  end if;
end $assert_c$;

-- (d) NEVER grant against NULL (the 0221 securing-processor rule: a null deposit target must not
--     burn the idempotency key on a half deposit).
do $assert_d$
declare
  v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'movement_settle_arrival';
  if position('if v_deposit is not null then' in v_code) = 0 then
    raise exception '0307 SELF-ASSERT (d) FAIL: the null-deposit guard is missing — a base-less player would burn the grant key';
  end if;
end $assert_d$;

-- (e) dockability is COMPOSED, not re-implemented: the arm calls is_home_port_eligible and never
--     reads the predicate''s internals (docking services / anchors) itself.
do $assert_e$
declare
  v_code text;
begin
  select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') into v_code
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'movement_settle_arrival';
  if (length(v_code) - length(replace(v_code, 'is_home_port_eligible', ''))) / length('is_home_port_eligible') <> 1 then
    raise exception '0307 SELF-ASSERT (e) FAIL: the settle must consult the one dockability predicate exactly once';
  end if;
  if position('docking_service' in v_code) > 0 or position('space_anchors' in v_code) > 0 then
    raise exception '0307 SELF-ASSERT (e) FAIL: the settle re-implements the dockability predicate''s internals — one authority';
  end if;
end $assert_e$;

-- (f) the mover''s comment hunk landed and its CODE did not move: the retired sentence is gone from
--     the whole body, and both retreat envelopes still carry carried_rewards.
do $assert_f$
declare
  v_src  text;
  v_code text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'command_ship_group_go';
  if position('forfeits the deposit' in v_src) > 0 then
    raise exception '0307 SELF-ASSERT (f) FAIL: command_ship_group_go still documents the retired defect';
  end if;
  v_code := regexp_replace(v_src, '--[^' || chr(10) || ']*', '', 'g');
  if (length(v_code) - length(replace(v_code, '''carried_rewards''', ''))) / length('''carried_rewards''') <> 2 then
    raise exception '0307 SELF-ASSERT (f) FAIL: a comment-only hunk changed the mover''s code — both retreat envelopes must still carry carried_rewards';
  end if;
end $assert_f$;

-- (g) ACL posture UNCHANGED (derived in the precondition block, never hard-coded).
do $assert_g$
declare
  v_before boolean;
begin
  select can_exec into v_before from _0307_acl;
  if has_function_privilege('authenticated', 'public.movement_settle_arrival(uuid)', 'execute')
     is distinct from v_before then
    raise exception '0307 SELF-ASSERT (g) FAIL: the rewrite changed movement_settle_arrival''s ACL posture';
  end if;
end $assert_g$;

-- (h) SMOKE, and labelled as one: the rewritten settle is callable and still answers the guarded
--     not_settleable envelope for a movement that does not exist. Deliberately NOT the behavioural
--     proof — a migration cannot mint fleets (auth.users FKs). The deposit itself (chosen port →
--     that port''s store; open space → oldest store; base arm unchanged; replay-safe) is proven by
--     scripts/fleetgo-proof.sql BLOCK LOOT-SECURES against a disposable Postgres in CI.
do $assert_h$
declare
  v jsonb;
begin
  v := public.movement_settle_arrival(gen_random_uuid());
  if (v->>'settled')::boolean is not false or (v->>'reason') is distinct from 'not_settleable' then
    raise exception '0307 SELF-ASSERT (h) FAIL: the rewritten settle answered % for a nonexistent movement', v;
  end if;
  raise notice '0307 SELF-ASSERT PASS: the space arrival deposits through the one depositor; the base arm is byte-retained';
end $assert_h$;

commit;
