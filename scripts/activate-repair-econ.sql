-- REPAIR-ECON ACTIVATION — the paid hull-repair flip (docs/FULL_CAPACITY_PLAN.md §C P9 "REPAIR-ECON";
-- gap G8; the ACT-REPAIR closer). The repair economy is FULLY BUILT DARK: migration 0201 seeds the
-- repair_economy_enabled flag + the repair_credits_per_hp knob + repair_receipts + the paid RPC
-- repair_ship_hull_at_port, and this slice's client PR mounts the RepairPanel dark on the Port screen
-- (it reads repair_economy_enabled from public game_config and renders NOTHING until it is jsonb true).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT CI; nothing flips at
-- build/deploy time. Each run of this file IS the recorded human go decision.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (no write until these hold):
--     • migration head >= 20260618000201 AND 0201 recorded in supabase_migrations.schema_migrations;
--     • the repair_receipts table exists;
--     • the function surface exists via to_regprocedure — the REAL signatures: the NEW paid RPC, the
--       FREE safelock, and the leaves the paid RPC fans out to (wallet_debit / the resolvers / cfg);
--     • the DEPLOYED paid-RPC body is the 0201 head, prosrc-pinned: it carries the gate reject
--       (repair_economy_disabled) AND the safelock seam (ship_destroyed);
--     • ██ THE SAFELOCK PRECONDITION (the G8 mandate — the free recovery must stay free + UNGATED):
--       the DEPLOYED repair_main_ship body does NOT reference repair_economy_enabled (recovery is
--       never gated) and still carries its destroyed-only guard — so flipping the economy flag cannot
--       change the free path in any way;
--     • the knob exists + is sane (repair_credits_per_hp > 0) — a repair can never heal for free;
--     • the 'repair_economy_enabled' key exists (0201 seeds it false). Its VALUE is not asserted
--       false — a RE-RUN after success is a supported no-op;
--     • ACL posture: the paid RPC is authenticated-only, never anon.
--   STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer):
--     repair_economy_enabled → true. The paid RPC dark-gates on cfg_bool('repair_economy_enabled')
--     FIRST and rejects repair_economy_disabled while false — it physically cannot repair/charge dark.
--   SMOKE (read-only + a zero-write gate probe): flag committed (raw + cfg_bool); knob still sane; the
--     paid RPC no longer gate-rejects — called under a TRANSACTION-LOCAL fake JWT (the proofs'
--     set_config technique) whose random subject owns NO ship, so it returns ship_not_found (NOT
--     repair_economy_disabled), proving the gate opened while writing nothing; repair_receipts
--     selectable; the free safelock still recovers ungated (re-pinned); ACL intact.
--   Emits ACTIVATE_REPAIR_PASS_* markers per stage and one final PASS line; any failed assert
--   RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing activation).
--
-- RE-RUN SEMANTICS (decided, documented): safe no-op success. The flag write is a set_game_config
-- upsert to the same value; no other state is touched. No path double-applies.
--
-- ── NO SEPARATE CLIENT PR IS NEEDED ──────────────────────────────────────────────────────────────
--   The RepairPanel ships (dark) in THIS slice's client PR, already mounted on the Port screen main
--   rail (PortScreen.tsx, the SalvageMarketPanel neighbour) and gated on the SAME server flag it reads
--   from public game_config — flag false → it renders null (production byte-unchanged). The moment
--   this script commits, the panel's next docked-Port read sees repair_economy_enabled=true and the
--   Repair desk appears. There is NO compile constant to flip (no REPAIR_* in osnReleaseGates.ts).
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ──────────────────────────────────────────────────────────
--   • repair_receipts / main_ship_instances rows — NEVER written by this script (its only direct
--     write is the ONE set_game_config upsert).
--   • repair_main_ship / dev_set_main_ship_destroyed — the free safelock is asserted intact, never
--     edited. The knob (repair_credits_per_hp) — asserted sane, never rewritten (a retune is a
--     deliberate separate set_game_config write). Every other window's flag. Any DDL. Any migration.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ─────────────
--   psql "<prod session-pooler conn (pinned CA, sslmode=verify-full)>" -X -v ON_ERROR_STOP=1 \
--        -f scripts/activate-repair-econ.sql
--   Or paste this whole file into the Supabase Dashboard SQL editor / management-API runner, or:
--     bash scripts/activate-repair-econ.sh run ACTIVATE_REPAIR      # DB_URL required
--   AFTER a green run: manual smoke — dock a DAMAGED ship at a port → the Repair desk shows the hull
--   bar + cost → Repair (full or partial) → wallet debits by exactly hp_restored × repair_credits_per_hp
--   and the hull mends; a destroyed ship instead shows the FREE recovery (unchanged).
--
-- ── ROLLBACK ─────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). FLAG-ONLY: repair_economy_enabled
--   → false. The paid RPC rejects gate-first again and the RepairPanel fails closed to null on its
--   next read. No receipts/hp are reverted (past repairs stand); the free safelock is unaffected
--   either way (it never read the flag).

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head text; v_missing text; fn text; v_src text; v_per numeric;
begin
  -- migration 0201 deployed AND recorded (head alone is not enough).
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000201' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000201 (REPAIR-ECON) — deploy the repair stack first', coalesce(v_head, '(none)');
  end if;
  if not exists (select 1 from supabase_migrations.schema_migrations s where s.version = '20260618000201') then
    raise exception 'PRECONDITION FAIL: migration 20260618000201 not recorded as deployed';
  end if;

  -- the receipts table exists.
  if to_regclass('public.repair_receipts') is null then
    raise exception 'PRECONDITION FAIL: table public.repair_receipts missing';
  end if;

  -- the function surface — the REAL signatures: the NEW paid RPC, the FREE safelock, and the leaves.
  foreach fn in array array[
    'public.repair_ship_hull_at_port(uuid, numeric, uuid)',
    'public.repair_main_ship(uuid)',
    'public.wallet_debit(uuid, numeric)',
    'public.mainship_resolve_owned_ship(uuid, uuid)',
    'public.mainship_resolve_docked_location(uuid)',
    'public.cfg_bool(text)',
    'public.cfg_num(text)',
    'public.set_game_config(text, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception 'PRECONDITION FAIL: function % does not exist', fn;
    end if;
  end loop;

  -- the DEPLOYED paid-RPC body is the 0201 head: gate reject + the safelock seam.
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.repair_ship_hull_at_port(uuid, numeric, uuid)')::oid;
  if position('repair_economy_disabled' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed repair_ship_hull_at_port body lacks the dark gate reject (0201)';
  end if;
  if position('ship_destroyed' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed repair_ship_hull_at_port body lacks the destroyed-safelock seam reject (0201)';
  end if;

  -- ██ THE SAFELOCK PRECONDITION ██ — the FREE recovery stays free + UNGATED (the G8 mandate): the
  -- deployed repair_main_ship body must NOT reference repair_economy_enabled and must keep its
  -- destroyed-only guard, so flipping the economy flag cannot alter the free path.
  select prosrc into v_src from pg_proc
   where oid = to_regprocedure('public.repair_main_ship(uuid)')::oid;
  if position('repair_economy_enabled' in v_src) <> 0 then
    raise exception 'PRECONDITION FAIL: repair_main_ship references repair_economy_enabled — the free safelock must stay UNGATED';
  end if;
  if position('ship is not disabled' in v_src) = 0 then
    raise exception 'PRECONDITION FAIL: repair_main_ship lost its destroyed-only guard — the free safelock changed';
  end if;

  -- the knob exists + sane (> 0): a repair can never heal for free via a missing/zero knob.
  v_per := public.cfg_num('repair_credits_per_hp');
  if v_per is null or v_per <= 0 then
    raise exception 'PRECONDITION FAIL: repair_credits_per_hp % is not sane (want > 0; 0201 seeds 0.5)', v_per;
  end if;

  -- the ONE key this script writes must already exist (refuse to invent config rows via a typo). Its
  -- VALUE is deliberately NOT asserted false: a re-run after success is a supported no-op.
  if not exists (select 1 from public.game_config where key = 'repair_economy_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key repair_economy_enabled missing (0201 seeds it false)';
  end if;

  -- ACL posture: the paid RPC is authenticated-only, never anon.
  if not has_function_privilege('authenticated', 'public.repair_ship_hull_at_port(uuid,numeric,uuid)', 'execute')
     or has_function_privilege('anon', 'public.repair_ship_hull_at_port(uuid,numeric,uuid)', 'execute') then
    raise exception 'PRECONDITION FAIL: repair_ship_hull_at_port ACL drifted (want authenticated-only, never anon)';
  end if;

  raise notice 'ACTIVATE_REPAIR_PASS_PRECONDITIONS ok: head %, 0201 recorded, repair_receipts present, 8 functions present (real signatures), paid-RPC body 0201 head (gate + ship_destroyed seam), free safelock repair_main_ship UNGATED + destroyed-only (unaffected by the flip), repair_credits_per_hp % sane (untouched), key present, ACL authenticated-only', v_head, v_per;
end $$;

-- ══════════ STAGE 1 — the switch (the ONE flag write, via the owned set_game_config writer) ══════════
do $$
declare v_before text;
begin
  select value::text into v_before from public.game_config where key = 'repair_economy_enabled';
  perform public.set_game_config('repair_economy_enabled', 'true'::jsonb);
  raise notice 'stage 1: repair_economy_enabled % -> true', v_before;
  raise notice 'ACTIVATE_REPAIR_PASS_STAGE1 ok: repair_economy_enabled=true (uncommitted until smoke passes — one all-or-nothing txn)';
end $$;

-- ══════════ SMOKE — read-only + a zero-write gate probe ══════════
do $$
declare v_res jsonb; n int; v_src text;
begin
  -- (a) the committed flag value is exactly the activation state (raw + through the reader).
  if (select value #>> '{}' from public.game_config where key = 'repair_economy_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: repair_economy_enabled is % (want true)',
      (select value #>> '{}' from public.game_config where key = 'repair_economy_enabled');
  end if;
  if not public.cfg_bool('repair_economy_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(repair_economy_enabled) still false'; end if;

  -- (b) the knob is still sane after the flip (untouched).
  if public.cfg_num('repair_credits_per_hp') is null or public.cfg_num('repair_credits_per_hp') <= 0 then
    raise exception 'SMOKE FAIL: repair_credits_per_hp went non-sane'; end if;

  -- (c) THE GATE OPENED (zero-write probe): the paid RPC no longer rejects repair_economy_disabled.
  --     Called under a TRANSACTION-LOCAL fake JWT (the proofs' set_config technique) whose random
  --     subject owns NO ship, so the reject advances past the gate to ship_not_found — proving the
  --     gate is open WITHOUT writing anything (the reject path is read-only, and the subject owns
  --     nothing). Claims cleared after (and the txn-local setting evaporates at COMMIT regardless).
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  v_res := public.repair_ship_hull_at_port(gen_random_uuid(), 10, gen_random_uuid());
  if (v_res ->> 'reason') is distinct from 'ship_not_found' then
    raise exception 'SMOKE FAIL: the paid RPC did not advance past the gate to ship_not_found (got %) — the flip did not open the gate', v_res;
  end if;
  perform set_config('request.jwt.claims', '', true);

  -- (d) the receipts table is selectable (count FYI — 0 at flip time; it fills as players repair).
  select count(*) into n from public.repair_receipts;
  raise notice 'smoke: repair_receipts rows = % (0 expected at flip time)', n;

  -- (e) re-pin the free safelock stays ungated after the flip (the G8 guarantee).
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.repair_main_ship(uuid)')::oid;
  if position('repair_economy_enabled' in v_src) <> 0 then
    raise exception 'SMOKE FAIL: repair_main_ship somehow references the economy flag (must stay ungated)'; end if;

  raise notice 'ACTIVATE_REPAIR_PASS_SMOKE ok: flag committed true, knob sane, paid RPC gate OPEN (advances to ship_not_found for a no-ship subject, zero writes), receipts selectable, free safelock still ungated';
end $$;

select 'REPAIR ACTIVATION PASS — the paid hull-repair economy is LIVE server-side (repair_ship_hull_at_port no longer gate-rejects). NO separate client PR is needed: the RepairPanel ships dark in this slice and mounts on the Port screen main rail gated on repair_economy_enabled (read from public game_config); it appears the moment this commits, on the next docked-Port render. The FREE destroyed-ship safelock (repair_main_ship) is UNCHANGED and ungated. Players dock a DAMAGED ship, see the hull bar + cost, and pay hp_restored × repair_credits_per_hp (0.5) to mend the hull (full or partial); destroyed ships still recover free.' as result;

commit;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- To dark the paid-repair surface again, run the reverse write below (uncomment, run once). Notes:
--   • FLAG-ONLY: repair_economy_enabled → false. The paid RPC rejects gate-first again
--     (repair_economy_disabled) and the RepairPanel fails closed to null on its next read.
--   • Past repairs STAND: repair_receipts rows and healed hp are never reverted (they were paid for).
--   • The FREE safelock (repair_main_ship) is unaffected either way — it never read the flag.
--
-- begin;
-- select public.set_game_config('repair_economy_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'repair_economy_enabled';
-- commit;
