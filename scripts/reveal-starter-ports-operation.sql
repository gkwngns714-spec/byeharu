-- PORT-LAUNCH-2C — the ONE controlled starter-port reveal operation.
--
-- This is the EXACT transaction the gated production workflow runs, and the same transaction the disposable
-- proof exercises. It is HARD-CODED: it accepts NO operator-supplied SQL, port list, flag name, environment,
-- host, or ref. It targets only the three canonical starter-port ids that reveal_starter_ports() itself owns,
-- and calls only the canonical public.reveal_starter_ports() function — exactly once, with no retry.
--
-- One session, one transaction:
--   (1) conservative lock/statement timeouts;
--   (2) lock the three canonical port rows (id order) so the snapshot→reveal→postcondition window is atomic;
--   (3) snapshot the canonical starter-port state, the total active-location count, and both feature flags;
--   (4) ASSERT the untouched pre-reveal baseline (exactly 3 canonical ports, all hidden, none active;
--       send=true; space=false) — reveal is NOT called unless every precondition holds;
--   (5) call reveal_starter_ports() EXACTLY ONCE;
--   (6) ASSERT the postconditions: the same 3 canonical ports are now active; the transition is exactly
--       3 × hidden→active (net active-location change = +3, nothing else moved); no canonical port is in an
--       unexpected state; both flags are byte-for-byte unchanged from the pre-op snapshot;
--   (7) emit machine-readable success markers ONLY after all assertions pass;
--   (8) COMMIT only if every assertion passed.
--
-- Any failed assertion / SQL error / lock or statement timeout aborts the DO block; with ON_ERROR_STOP the
-- session stops before COMMIT, so the open transaction is ROLLED BACK (fail-closed, no partial write, no
-- retry). A rerun after a successful reveal fails closed at the precondition (a canonical port is already
-- active) and NEVER calls reveal_starter_ports() a second time.

\set ON_ERROR_STOP on
\timing off

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '30s';

do $$
declare
  -- The fixed canonical starter-port set OWNED BY reveal_starter_ports() (migration 0066/0068). NOT
  -- operator-supplied. Kept identical to the function's internal constants by contract.
  c_p1 constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';  -- Haven (city)
  c_p2 constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';  -- Slagworks (port)
  c_p3 constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';  -- Driftmarch (port)
  v_ports uuid[] := array[c_p1, c_p2, c_p3];
  v_count_canonical   int;
  v_hidden_before     int;
  v_active_before     int;
  v_total_active_before int;
  v_total_active_after  int;
  v_active_after      int;
  -- identity-level digest of EVERY non-canonical location's (id,status). Compared before/after so the
  -- postcondition proves the ONLY rows that changed are the three canonical ports — an offsetting change
  -- (one location going inactive while another goes active, keeping the net count at +3) flips this digest.
  v_other_digest_before text;
  v_other_digest_after  text;
  v_send_before  jsonb;
  v_space_before jsonb;
  v_send_after   jsonb;
  v_space_after  jsonb;
  v_reveal jsonb;
begin
  -- (2) serialize the operation against any concurrent change to the three canonical port rows.
  perform 1 from public.locations where id = any(v_ports) order by id for update;

  -- (3) snapshot
  select count(*),
         count(*) filter (where status = 'hidden'),
         count(*) filter (where status = 'active')
    into v_count_canonical, v_hidden_before, v_active_before
    from public.locations where id = any(v_ports);
  select count(*) into v_total_active_before from public.locations where status = 'active';
  select md5(coalesce(string_agg(id::text || '=' || status, ',' order by id), ''))
    into v_other_digest_before from public.locations where id <> all(v_ports);
  select value into v_send_before  from public.game_config where key = 'mainship_send_enabled';
  select value into v_space_before from public.game_config where key = 'mainship_space_movement_enabled';

  -- (4) PRECONDITIONS — fail closed; reveal_starter_ports() is NOT called unless all hold.
  if v_count_canonical <> 3 then
    raise exception 'PRECOND FAIL: canonical starter-port set is not exactly 3 rows (got %)', v_count_canonical;
  end if;
  if v_active_before <> 0 then
    raise exception 'PRECOND FAIL: a canonical starter port is already ACTIVE (active=%) — not the all-hidden pre-reveal baseline; reveal NOT called (already revealed / rerun)', v_active_before;
  end if;
  if v_hidden_before <> 3 then
    raise exception 'PRECOND FAIL: expected exactly 3 HIDDEN canonical starter ports (hidden=%, active=%)', v_hidden_before, v_active_before;
  end if;
  if coalesce(public.cfg_bool('mainship_send_enabled'), false) <> true then
    raise exception 'PRECOND FAIL: mainship_send_enabled is not true';
  end if;
  if coalesce(public.cfg_bool('mainship_space_movement_enabled'), false) <> false then
    raise exception 'PRECOND FAIL: mainship_space_movement_enabled is not false';
  end if;
  raise notice 'PRECONDITIONS_PASS=true';
  raise notice 'STARTER_PORTS_EXPECTED=3';
  raise notice 'STARTER_PORTS_HIDDEN_BEFORE=%', v_hidden_before;

  -- (5) the ONE reveal call — exactly once, no loop, no retry.
  v_reveal := public.reveal_starter_ports();
  raise notice 'REVEAL_FUNCTION_CALLS=1';
  if (v_reveal->>'ok')::boolean is not true
     or (v_reveal->>'revealed')::int <> 3
     or (v_reveal->>'already_active')::boolean <> false then
    raise exception 'REVEAL FAIL: unexpected reveal result %', v_reveal;
  end if;

  -- (6) POSTCONDITIONS
  select count(*) into v_active_after from public.locations where id = any(v_ports) and status = 'active';
  if v_active_after <> 3 then
    raise exception 'POSTCOND FAIL: canonical ports active after = % (expected 3)', v_active_after;
  end if;
  raise notice 'STARTER_PORTS_ACTIVE_AFTER=%', v_active_after;

  -- IDENTITY-LEVEL transition: each of the three canonical ports was hidden before (guaranteed by the
  -- precondition: count=3, active=0 ⇒ all 3 hidden) and is active now (v_active_after=3 over the fixed set),
  -- and NO canonical port is left in an unexpected (non-active) state.
  if v_hidden_before <> 3 or v_active_after <> 3 then
    raise exception 'POSTCOND FAIL: transition is not exactly 3 hidden->active';
  end if;
  if (select count(*) from public.locations where id = any(v_ports) and status <> 'active') <> 0 then
    raise exception 'POSTCOND FAIL: a canonical starter port is not active after reveal';
  end if;
  -- OFFSETTING-PROOF: every NON-canonical location is byte-identical to the pre-op snapshot. This is the
  -- authoritative "nothing else changed" guarantee — the net +3 below is only a supplemental cross-check and
  -- could not, on its own, distinguish an offsetting mutation (one inactive + one active) from a clean reveal.
  select md5(coalesce(string_agg(id::text || '=' || status, ',' order by id), ''))
    into v_other_digest_after from public.locations where id <> all(v_ports);
  if v_other_digest_after is distinct from v_other_digest_before then
    raise exception 'POSTCOND FAIL: a non-canonical location changed status (identity-level invariance broken) — unexpected/offsetting mutation';
  end if;
  -- supplemental cross-check: net active-location change is exactly +3.
  select count(*) into v_total_active_after from public.locations where status = 'active';
  if v_total_active_after <> v_total_active_before + 3 then
    raise exception 'POSTCOND FAIL: net active-location change = % (expected exactly +3) — unexpected mutation', v_total_active_after - v_total_active_before;
  end if;

  -- both flags byte-for-byte unchanged from the pre-op snapshot.
  select value into v_send_after  from public.game_config where key = 'mainship_send_enabled';
  select value into v_space_after from public.game_config where key = 'mainship_space_movement_enabled';
  if v_send_after is distinct from v_send_before or v_space_after is distinct from v_space_before then
    raise exception 'POSTCOND FAIL: a feature flag changed during the operation (send % -> %, space % -> %)',
      v_send_before, v_send_after, v_space_before, v_space_after;
  end if;
  if coalesce(public.cfg_bool('mainship_space_movement_enabled'), false) <> false then
    raise exception 'POSTCOND FAIL: mainship_space_movement_enabled is not false after the operation';
  end if;
  raise notice 'FLAGS_UNCHANGED=true';

  raise notice 'REVEAL_OPERATION_PASS=true';
end $$;

commit;
