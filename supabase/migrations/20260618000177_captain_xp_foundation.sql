-- Byeharu — CAPXP-0/1: the captain-XP foundation (additive xp/level columns + flag + the
-- commit-safe accrual ledger + the cron accrual writer; everything DARK).
--
-- Queue slice #13 of the full-capacity plan (master plan §C P5): captain progression. THIS slice is
-- C2-0 (additive `captain_instances.xp/level` + `captain_growth_enabled` seeded 'false') + C2-1 (XP
-- accrual as a downward reader of FINALIZED `reward_grants` — the exact commit-safe 0144/0145
-- anti-join idiom with a `captain_counted_grants` ledger). The level-curve adapter parity delta
-- (C2-2: `stats × (1 + level_bonus)`, byte-inert at level 1), the TeamMemberCaptains XP bars
-- (C2-3), and the 6→8 slot raise (C2-4) are LATER slices — the xp/level columns are READ BY
-- NOTHING yet: no adapter, no RPC, no client code touches them until C2-2/C2-3 ship.
--
-- ── THE SHIP-LINKAGE FINDING (what per-grant captain attribution is DERIVABLE) ───────────────────
-- `reward_grants` (0015) carries NO ship column — (source_type, source_id, player_id, rewards).
-- The linkage is source-specific, via source_id:
--   · combat      — source_id = the combat_encounters id (0030/0046/0096: movement_attach_cargo
--                   carries e.id home; reward_grant('combat', encounter, …) on settle). Encounter →
--                   fleet_id → the sortie MANIFEST `group_sortie_members` (0168 — the frozen
--                   at-send membership snapshot, the charter's "sorties whose manifest included the
--                   captain's ship") for team sorties, UNION the `fleets.main_ship_id` tag (0050)
--                   for solo main-ship sorties. Legacy unit fleets (no tag, no manifest) and
--                   retention-cleaned encounters (0047 — the encounter row can predecease the
--                   grant) yield NO ship: consumed as a sentinel (below), never credited.
--   · exploration — source_id = the exploration_discoveries id (0100); the discovery row records
--                   the scanning ship in `main_ship_id` (0146/0172 securing link; NULLABLE — a
--                   null-scanner legacy row yields no ship → sentinel).
--   · mining      — source_id = the mining_extractions id (0105); `main_ship_id` is NOT NULL
--                   (NULLABLE per 0103's ON DELETE SET NULL — a destroyed-ship extraction consumes as a sentinel).
--   · trade       — NO reward_grants producer exists today (trade pays through Wallet, not
--                   reward_grant; the 0096 `reward_source_type` domain merely reserves 'trade').
--                   If one ever appears its grants are consumed as sentinels (0 xp) until a
--                   linkage + knob are defined in their own slice.
--
-- ── THE ACCRUAL SEMANTIC — CURRENT ASSIGNMENT, documented honestly ───────────────────────────────
-- XP is credited to the captains assigned to the linked ship AT ACCRUAL TIME
-- (`ship_captain_assignments`, 0119) — NOT the captains aboard at sortie time. The manifest
-- (0168) freezes at-send SHIP membership, but captain-at-sortie-time is recorded NOWHERE (no
-- table snapshots the roster at send), so current-assignment is the only derivable semantic.
-- Practical skew is one cron window (≤5 min): a captain reassigned between settle and accrual
-- credits its NEW ship's history slot, and a captain assigned just after a settle inherits that
-- grant. A future D-family manifest extension (per-member captain snapshot columns on
-- group_sortie_members, written by send_ship_group_hunt) would enable true at-sortie attribution —
-- noted as a possible refinement, deliberately NOT built here (no schema change to a live
-- manifest in a dark XP slice).
--
-- ── THE LEDGER — consume-exactly-once, commit-safe (the 0144/0145 idiom, captain-shaped) ─────────
-- `captain_counted_grants` mirrors `ranking_counted_grants` (0144): a per-row CONSUMPTION MARKER,
-- visibility-based, never a timestamp cursor (the 0145 commit-safety lesson — a late-committing
-- grant is simply absent from the ledger and picked up next run). Two deliberate deviations, both
-- forced by the captain domain:
--   (1) KEYED PER (grant, captain), not per (season, grant): one grant can feed MULTIPLE captains
--       on one manifest (several captains per ship, several ships per sortie) — each credit is its
--       own exactly-once row, `unique nulls not distinct (grant_id, captain_instance_id)`.
--   (2) A SENTINEL ROW (captain_instance_id NULL) marks a grant CONSUMED WITH NO CREDIT — no
--       derivable ship, or a derivable ship with no assigned captains. The accrual's anti-join is
--       per-GRANT ("no ledger row at all"), so every grant is examined EXACTLY ONCE, ever:
--       without the sentinel, uncreditable grants would be rescanned forever (unbounded scans)
--       and captains assigned later would retroactively harvest all history (an XP-backfill
--       exploit). Decided: no retroactive credit — a grant's captain set is fixed the first time
--       the accrual sees it. (Corollary for the future ACT-CAPXP flip: grants accumulated while
--       DARK are all unconsumed, so the FIRST lit run folds that whole backlog into
--       currently-assigned captains. The activation script must either accept that one-time
--       backfill or pre-seed sentinels for pre-flip grants — an explicit flip-time decision.)
--
-- ── THE XP FORMULA (proposed; [D] OWNER-TUNABLE knobs — a retune is one set_game_config) ─────────
-- FLAT XP PER GRANT PER SOURCE — deliberately the simplest grounded rule: a grant IS the finalized
-- unit of "a sortie that came home with something" (UNIQUE (source_type, source_id)), so xp per
-- grant = xp per secured sortie outcome. No danger/waves scaling in v1 (rewards jsonb shapes vary
-- per source; a magnitude-scaled formula is a C2-x refinement once the curve is felt in play):
--     captain_xp_per_combat_grant      = 10   (a won/escaped hunt that deposited rewards)
--     captain_xp_per_exploration_grant = 6    (a secured discovery)
--     captain_xp_per_mining_grant      = 4    (a secured extraction)
-- Every assigned captain on a linked ship gets the FULL amount (no split — a full roster should
-- never be an XP tax). LEVEL is maintained inline as level = 1 + floor(sqrt(xp / 100))
-- [D proposed curve: 100 xp → 2, 400 → 3, 900 → 4, … — quadratic spacing, coherent from day one]
-- so the column is never stale; NOTHING reads it until the C2-2 adapter delta.
--
-- ── OWNERSHIP (SYSTEM_BOUNDARIES rows land in THIS PR — the §E law) ──────────────────────────────
--   · captain_counted_grants     = Captain: sole writer = `captain_xp_accrue()` (this migration);
--                                  server-only (the 0144 securing-table posture — RLS on, no
--                                  client policy/grant).
--   · captain_instances.xp/level = written ONLY by `captain_xp_accrue()` — the mint leaf (0118)
--                                  and the assignment writer (0119) NEVER touch xp/level (they
--                                  ride the column defaults). Same table, disjoint writers by
--                                  column: mint owns row creation, the accrual owns progression.
-- Edges all DOWNWARD, acyclic: Captain → Reward (`reward_grants` read — the Ranking 0130
-- precedent) · Combat (`combat_encounters` read) · Movement (`fleets` tag read) · Team Command
-- (`group_sortie_members` manifest read) · Exploration/Mining (discovery/extraction ship links) ·
-- Reference/Config (cfg reads). Nothing new calls into Captain; combat never writes captain XP
-- mid-tick (the charter guard) — XP moves ONLY in this cron fold over FINALIZED grants.
--
-- Forward-only: 0001–0176 unedited. No client code in this slice.

-- ── 1) captain_instances gains xp/level — additive, read by NOTHING until C2-2 ───────────────────
alter table public.captain_instances
  add column if not exists xp    numeric not null default 0 check (xp >= 0),
  add column if not exists level integer not null default 1 check (level >= 1);

comment on column public.captain_instances.xp is
  'CAPXP (0177): lifetime experience — accrued ONLY by captain_xp_accrue() from FINALIZED '
  'reward_grants linked to ships this captain is assigned to at accrual time (flat xp per grant '
  'per source_type — the captain_xp_per_*_grant knobs). Monotonic non-negative. The mint (0118) '
  'and assignment (0119) writers never touch it. Read by NOTHING until the C2-2 adapter delta.';
comment on column public.captain_instances.level is
  'CAPXP (0177): derived level, maintained inline by captain_xp_accrue() as '
  '1 + floor(sqrt(xp / 100)) [D proposed curve] so the column is never stale. IGNORED by the '
  'stats adapter until the C2-2 parity delta (stats × (1 + level_bonus), byte-inert at level 1).';

-- ── 2) captain_counted_grants — the per-(grant, captain) consumption ledger (Captain; SERVER-ONLY) ─
-- The 0144 shape, captain-keyed (header deviations (1)/(2)): captain_instance_id NULL = the
-- sentinel "consumed, no credit". `granted_at` is an informational snapshot (NOT a cursor — the
-- 0144 law); main_ship_id records WHICH linked ship carried the credit (audit; sentinel rows NULL).
create table if not exists public.captain_counted_grants (
  id                  uuid primary key default gen_random_uuid(),
  grant_id            uuid not null references public.reward_grants (id) on delete cascade,
  captain_instance_id uuid references public.captain_instances (id) on delete cascade,  -- NULL = sentinel
  main_ship_id        uuid references public.main_ship_instances (main_ship_id) on delete set null,
  player_id           uuid not null references auth.users (id) on delete cascade,
  source_type         text not null,
  xp                  numeric not null default 0 check (xp >= 0),
  granted_at          timestamptz not null,
  counted_at          timestamptz not null default now(),
  -- EXACTLY-ONCE key: one credit row per (grant, captain) AND at most one NULL-captain sentinel
  -- per grant (PG15+ NULLS NOT DISTINCT — the sentinel is a real key member, not an escape hatch).
  -- The accrual anti-joins per GRANT (no ledger row at all) and inserts under this key, so a
  -- retry / racing run can never double-count and a late-committing grant is picked up next run.
  unique nulls not distinct (grant_id, captain_instance_id)
);
-- per-captain audit/debug path (the anti-join's grant_id lookup rides the unique index above).
create index if not exists captain_counted_grants_captain_idx
  on public.captain_counted_grants (captain_instance_id, counted_at desc)
  where captain_instance_id is not null;

alter table public.captain_counted_grants enable row level security;
-- SERVER-ONLY (the 0144 securing-table posture verbatim): RLS on, NO policy, NO client grant —
-- internal accrual bookkeeping, never client display data (C2-3 reads xp off captain_instances).
revoke all on table public.captain_counted_grants from public, anon, authenticated;

comment on table public.captain_counted_grants is
  'CAPXP (0177): per-(grant_id, captain_instance_id) CONSUMPTION LEDGER making captain-XP accrual '
  'commit-safe + exactly-once — the ranking_counted_grants (0144) idiom, keyed per (grant, '
  'captain) because one grant can feed multiple captains on one sortie manifest. '
  'captain_instance_id NULL = the SENTINEL: the grant was consumed with NO credit (no derivable '
  'ship, or no assigned captains) — every grant is examined exactly once, no retroactive backfill '
  'to later-assigned captains, bounded scans. Sole writer = captain_xp_accrue() (SECURITY '
  'DEFINER, service-role-only, cron). SERVER-ONLY: RLS on, no client policy/grant. DARK behind '
  'captain_growth_enabled. PERMANENT correctness structure, not a shim.';
comment on column public.captain_counted_grants.granted_at is
  'CAPXP (0177): informational snapshot of reward_grants.granted_at at fold time — NOT a cursor '
  '(the 0144 law: the ledger anti-join IS the cursor); audit/debug only.';

-- ── 3) the dark gate + the per-source XP knobs (all seeded; the 0176 idiom) ───────────────────────
insert into public.game_config (key, value, description) values
  ('captain_growth_enabled', 'false',
   'CAPXP (0177): server-authoritative dark gate for captain progression (C2). OFF until the '
   'owner flips it (a later ACT-CAPXP script — which must decide the dark-backlog question, see '
   'the 0177 header). captain_xp_accrue() checks this FIRST and returns a no-op envelope (never '
   'raises) while false — the 5-min cron is a zero-effect no-op while dark.'),
  ('captain_xp_per_combat_grant', '10',
   'CAPXP (0177): flat XP credited to each assigned captain on a linked ship per finalized '
   'COMBAT reward grant. Owner-tunable.'),
  ('captain_xp_per_exploration_grant', '6',
   'CAPXP (0177): flat XP per finalized EXPLORATION reward grant (secured discovery). '
   'Owner-tunable.'),
  ('captain_xp_per_mining_grant', '4',
   'CAPXP (0177): flat XP per finalized MINING reward grant (secured extraction). Owner-tunable.')
on conflict (key) do nothing;

-- ── 4) captain_xp_accrue() — THE accrual writer (SECURITY DEFINER, service-role/cron only) ────────
-- Gate-first (cfg_bool → return early while dark — a cron-safe no-op, NEVER a raise; the D2/0145
-- lesson), then ONE statement (the 0145 data-modifying-CTE shape — every CTE runs to completion):
--   unconsumed — every reward_grants row with NO ledger row at all (the per-grant anti-join);
--   ships      — the derivable ship set per grant (header linkage: combat manifest ∪ fleet tag,
--                exploration scanner, mining extractor);
--   credits    — the captains CURRENTLY assigned to those ships (the documented semantic), each
--                valued at its source's flat knob;
--   marked     — ledger insert: all credits, PLUS one NULL-captain sentinel per creditless grant
--                (`on conflict do nothing` = belt-and-braces under the advisory lock);
--   folded/bumped — per-captain Σxp folded into captain_instances.xp, level recomputed inline
--                (one UPDATE per captain — multi-grant credits are pre-summed).
create or replace function public.captain_xp_accrue()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grants   integer;
  v_credits  integer;
  v_captains integer;
  v_xp       numeric;
begin
  -- 1) DARK GATE FIRST (0127 law / 0145 idiom): while captain_growth_enabled is false, fold
  --    NOTHING and write NOTHING — return before any read, never raise (cron-safe).
  if not public.cfg_bool('captain_growth_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- 2) serialize concurrent accruals (the 0130/0145 global-lock idiom, captain domain).
  perform pg_advisory_xact_lock(hashtext('captain_xp_accrue'), 0);

  -- 3) the ONE commit-safe fold (header anatomy).
  with unconsumed as (
    select rg.id as grant_id, rg.source_id, rg.source_type, rg.player_id, rg.granted_at
    from reward_grants rg
    where not exists (select 1 from captain_counted_grants c where c.grant_id = rg.id)
  ),
  ships as (
    -- combat: encounter → fleet → the sortie manifest (team) ∪ the fleet's main-ship tag (solo).
    select u.grant_id, gsm.main_ship_id
      from unconsumed u
      join combat_encounters ce on u.source_type = 'combat' and ce.id = u.source_id
      join group_sortie_members gsm on gsm.fleet_id = ce.fleet_id
    union
    select u.grant_id, f.main_ship_id
      from unconsumed u
      join combat_encounters ce on u.source_type = 'combat' and ce.id = u.source_id
      join fleets f on f.id = ce.fleet_id
     where f.main_ship_id is not null
    union
    -- exploration: the discovery's recorded scanner (nullable — legacy rows yield no ship).
    select u.grant_id, d.main_ship_id
      from unconsumed u
      join exploration_discoveries d on u.source_type = 'exploration' and d.id = u.source_id
     where d.main_ship_id is not null
    union
    -- mining: the extraction's ship. NULLABLE (0103's ON DELETE SET NULL — a destroyed ship nulls
    -- its extractions), so filter like the exploration branch: a NULL-ship extraction consumes as
    -- a sentinel. (Review M1 2026-07-12: the earlier 'NOT NULL by schema' claim was wrong.)
    select u.grant_id, e.main_ship_id
      from unconsumed u
      join mining_extractions e on u.source_type = 'mining' and e.id = u.source_id
     where e.main_ship_id is not null
  ),
  credits as (
    -- captains assigned NOW to a linked ship (the current-assignment semantic, header-documented);
    -- flat per-source knob, defensively floored at 0 (a mis-set negative knob must never drain xp).
    select u.grant_id, u.source_type, u.player_id, u.granted_at,
           s.main_ship_id, sca.captain_instance_id,
           greatest(0, coalesce(case u.source_type
             when 'combat'      then public.cfg_num('captain_xp_per_combat_grant')
             when 'exploration' then public.cfg_num('captain_xp_per_exploration_grant')
             when 'mining'      then public.cfg_num('captain_xp_per_mining_grant')
             else 0 end, 0))::numeric as xp
      from unconsumed u
      join ships s on s.grant_id = u.grant_id
      join ship_captain_assignments sca on sca.main_ship_id = s.main_ship_id
  ),
  marked as (
    insert into captain_counted_grants
      (grant_id, captain_instance_id, main_ship_id, player_id, source_type, xp, granted_at)
    select grant_id, captain_instance_id, main_ship_id, player_id, source_type, xp, granted_at
      from credits
    union all
    -- the SENTINEL: consumed with no credit — examined exactly once, never rescanned (header (2)).
    select u.grant_id, null, null, u.player_id, u.source_type, 0, u.granted_at
      from unconsumed u
     where not exists (select 1 from credits c where c.grant_id = u.grant_id)
    on conflict do nothing
    returning grant_id, captain_instance_id, xp
  ),
  folded as (
    select captain_instance_id, sum(xp) as xp
      from marked
     where captain_instance_id is not null
     group by captain_instance_id
  ),
  bumped as (
    update captain_instances ci
       set xp    = ci.xp + f.xp,
           level = 1 + floor(sqrt((ci.xp + f.xp) / 100.0))::integer   -- [D] the proposed curve
      from folded f
     where ci.id = f.captain_instance_id
    returning ci.id
  )
  select count(distinct m.grant_id),
         count(*) filter (where m.captain_instance_id is not null),
         count(distinct m.captain_instance_id) filter (where m.captain_instance_id is not null),
         coalesce(sum(m.xp) filter (where m.captain_instance_id is not null), 0)
    into v_grants, v_credits, v_captains, v_xp
    from marked m;

  return jsonb_build_object('ok', true,
    'grants_consumed',   coalesce(v_grants, 0),
    'credits_inserted',  coalesce(v_credits, 0),
    'captains_credited', coalesce(v_captains, 0),
    'xp_awarded',        coalesce(v_xp, 0));
end;
$$;

-- ACL (the 0145 private-writer posture): a server/cron op, not a player command — no public wrapper.
revoke execute on function public.captain_xp_accrue() from public, anon, authenticated;
grant  execute on function public.captain_xp_accrue() to service_role;

-- ── 5) Cron: every 5 minutes (the 0147 cadence rationale verbatim — freshness only, never
--       correctness: the ledger anti-join folds any backlog on the next firing) ───────────────────
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'captain-xp-accrue';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

select cron.schedule(
  'captain-xp-accrue',
  '*/5 * * * *',
  $$select public.captain_xp_accrue();$$
);

-- ── 6) Self-assert: columns defaulted; ledger server-only; accrual ACL; cron once; flag dark +
--       knobs seeded; dark dry-run = clean no-op, zero writes ─────────────────────────────────────
do $$
declare v_n integer; v_r jsonb;
begin
  -- 1. The additive columns exist, NOT NULL, defaulted 0/1 — and every pre-existing instance rides
  --    the defaults (nothing may ship this migration with nonzero xp).
  select count(*) into v_n from information_schema.columns
    where table_schema = 'public' and table_name = 'captain_instances'
      and ((column_name = 'xp'    and is_nullable = 'NO' and column_default in ('0', '0::numeric'))
        or (column_name = 'level' and is_nullable = 'NO' and column_default = '1'));
  if v_n <> 2 then
    raise exception 'CAPXP-0 self-assert FAIL: xp/level columns missing or mis-defaulted (matched %)', v_n;
  end if;
  select count(*) into v_n from public.captain_instances where xp <> 0 or level <> 1;
  if v_n <> 0 then
    raise exception 'CAPXP-0 self-assert FAIL: % captain instance(s) off the additive defaults at migration time', v_n;
  end if;

  -- 2. The ledger exists and is SERVER-ONLY (no client read or write — the 0144 posture).
  if to_regclass('public.captain_counted_grants') is null then
    raise exception 'CAPXP-1 self-assert FAIL: captain_counted_grants missing';
  end if;
  if has_table_privilege('authenticated', 'public.captain_counted_grants', 'select')
     or has_table_privilege('anon', 'public.captain_counted_grants', 'select') then
    raise exception 'CAPXP-1 self-assert FAIL: captain_counted_grants is client-readable (must be server-only)';
  end if;

  -- 3. The accrual writer exists, service-role-only (never a client RPC).
  if to_regprocedure('public.captain_xp_accrue()') is null then
    raise exception 'CAPXP-1 self-assert FAIL: captain_xp_accrue() missing';
  end if;
  if has_function_privilege('authenticated', 'public.captain_xp_accrue()', 'execute')
     or has_function_privilege('anon', 'public.captain_xp_accrue()', 'execute') then
    raise exception 'CAPXP-1 self-assert FAIL: captain_xp_accrue() is client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.captain_xp_accrue()', 'execute') then
    raise exception 'CAPXP-1 self-assert FAIL: captain_xp_accrue() not granted to service_role';
  end if;

  -- 4. Cron scheduled EXACTLY once (guarded like the 0147 unschedule).
  begin
    select count(*) into v_n from cron.job where jobname = 'captain-xp-accrue';
    if v_n <> 1 then
      raise exception 'CAPXP-1 self-assert FAIL: expected exactly 1 captain-xp-accrue cron job, got %', v_n;
    end if;
  exception
    when undefined_table then
      raise notice 'CAPXP-1 self-assert: cron.job absent (shadow db) — cron count check skipped';
  end;

  -- 5. Flag DARK + the three knobs seeded at the proposed values.
  if public.cfg_bool('captain_growth_enabled') then
    raise exception 'CAPXP-0 self-assert FAIL: captain_growth_enabled is not false at seed time';
  end if;
  if coalesce(public.cfg_num('captain_xp_per_combat_grant'), -1) <> 10
     or coalesce(public.cfg_num('captain_xp_per_exploration_grant'), -1) <> 6
     or coalesce(public.cfg_num('captain_xp_per_mining_grant'), -1) <> 4 then
    raise exception 'CAPXP-1 self-assert FAIL: xp knobs not seeded 10/6/4';
  end if;

  -- 6. THE CRON-SAFETY PIN: a dry-run WHILE DARK is a clean no-op envelope — no raise, zero ledger
  --    rows (the table was just created, so any row = a leak), zero xp movement.
  v_r := public.captain_xp_accrue();
  if (v_r->>'ok')::boolean is not false or (v_r->>'code') is distinct from 'feature_disabled' then
    raise exception 'CAPXP-1 self-assert FAIL: dark dry-run did not no-op cleanly: %', v_r;
  end if;
  select count(*) into v_n from public.captain_counted_grants;
  if v_n <> 0 then
    raise exception 'CAPXP-1 self-assert FAIL: dark dry-run left % ledger row(s)', v_n;
  end if;
  select count(*) into v_n from public.captain_instances where xp <> 0 or level <> 1;
  if v_n <> 0 then
    raise exception 'CAPXP-1 self-assert FAIL: dark dry-run moved xp/level on % instance(s)', v_n;
  end if;

  raise notice 'CAPXP-0/1 self-assert ok: xp/level additive-defaulted (read by nothing until C2-2); ledger server-only; accrual service-role-only; cron scheduled once; flag dark + knobs 10/6/4; dark dry-run = clean no-op, zero writes';
end $$;
