-- HAUL — disposable REAL-CHAIN proof (runs on the actual chain 0001..0176 in a throwaway Supabase).
-- Proves HAUL-0/1: the dark cron-safe no-op, the deterministic per-(day, port) offer generator (exact
-- N×ports count, template/qty bounds, LIVE-market reward math, the worth-taking economics), same-day
-- idempotency + pure-function determinism (re-derived from the hash technique), the offered-only expiry
-- pass (accepted rows NEVER touched), and the RLS/ACL shape. Fixture users carry the 'hl1.' email
-- prefix. The ENTIRE proof runs inside ONE transaction that ROLLBACKs — it persists NO contract,
-- template, config, or flag flip. No production access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables haul_contracts_enabled ONLY inside this rolled-back transaction (AFTER proving
-- the dark no-op); the ROLLBACK reverts it, so the committed/production flag value stays false. It
-- transiently mirrors production config a fresh chain lacks (reveal_starter_ports — ports must be
-- ACTIVE for the generator's port filter) — reverted by ROLLBACK. ALL haul_contracts rows are minted
-- by the REAL generator; the harness never INSERTs into haul_contracts or haul_contract_templates.
-- Its only direct haul_contracts writes are two marked FIXTURES: aging one offered row's expires_at
-- (time travel) and flipping one row to 'accepted' (a stand-in for the not-yet-built HAUL-2 accept
-- RPC) — both exist purely so the expiry pins have something to bite on, both rolled back.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table hl1(k text primary key, v uuid) on commit preserve rows;
insert into hl1 values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven Reach (city/consumer)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002'),     -- Slagworks Anchorage (industrial)
  ('drift','b1a00003-0066-4a00-8a00-000000000003');     -- Driftmarch Waypost (frontier importer)

-- one fixture player (the accepted-row owner for the expiry/RLS pins; no ship needed this slice).
do $$
declare u uuid;
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
            'hl1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id into u;
  insert into hl1 values ('uA', u);
end $$;

-- mirror production config a fresh disposable chain lacks (reverted by ROLLBACK): reveal the starter
-- ports — the generator only posts at ACTIVE ports. haul_contracts_enabled stays OFF here (P0 first).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
end $$;

-- ════════ P0 — DARK cron-safety: the generator is a clean no-op envelope while dark — zero rows, NEVER a raise. ════════
do $$
declare r jsonb; n int;
begin
  -- the cron fires this exact call today in production; while dark it must return (never raise)
  -- with the feature_disabled envelope and write NOTHING.
  r := public.haul_generate_offers();
  if (r->>'ok')::boolean is not false or (r->>'code') is distinct from 'feature_disabled' then
    raise exception 'P0 FAIL: dark generator did not no-op with feature_disabled: %', r;
  end if;
  select count(*) into n from public.haul_contracts;
  if n <> 0 then raise exception 'P0 FAIL: dark generator created % row(s)', n; end if;

  -- enable the dark haul capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='haul_contracts_enabled';
  raise notice 'HAUL_PASS_DARK_GATE ok: dark run -> feature_disabled envelope (no raise), zero rows written';
end $$;

-- ════════ P1 — GENERATE: exactly N x ports offers, all 'offered', template-bounded, LIVE-market reward math exact. ════════
do $$
declare r jsonb; n int; v_n int; v_bad int;
begin
  v_n := coalesce(public.cfg_num('haul_offers_per_port'), -1)::int;
  if v_n <> 2 then raise exception 'P1 FAIL: haul_offers_per_port knob % (want the seeded 2)', v_n; end if;

  r := public.haul_generate_offers();
  if (r->>'ok')::boolean is not true then raise exception 'P1 FAIL: lit generator errored: %', r; end if;
  if (r->>'ports')::int <> 3 then raise exception 'P1 FAIL: generator saw % active ports (want 3)', (r->>'ports')::int; end if;
  if (r->>'offers_created')::int <> v_n * 3 then
    raise exception 'P1 FAIL: expected exactly % offers (N x ports), got % created', v_n * 3, (r->>'offers_created')::int;
  end if;
  select count(*) into n from public.haul_contracts;
  if n <> v_n * 3 then raise exception 'P1 FAIL: table holds % rows, expected exactly % offers (N x ports)', n, v_n * 3; end if;

  -- every port carries exactly N offers, slots 1..N on the UTC offer_day (the generator's boundary).
  select count(*) into v_bad from (select k, v from hl1 where k in ('haven','slag','drift')) p
    where (select count(*) from public.haul_contracts c
             where c.origin_location_id = p.v
               and c.offer_day = (now() at time zone 'utc')::date
               and c.slot between 1 and v_n) <> v_n;
  if v_bad <> 0 then raise exception 'P1 FAIL: % port(s) missing their N deterministic slots', v_bad; end if;

  -- per-row shape + EXACT reward recompute off the LIVE market_offers rows (the migration formula):
  -- reward = round(base + qty x (dest.buy + premium)); expiry anchored offered_at + duration.
  select count(*) into n
    from public.haul_contracts c
    join public.haul_contract_templates t on t.template_id = c.template_id
    join public.market_offers od on od.location_id = c.dest_location_id and od.good_id = c.good_id and od.active;
  if n <> v_n * 3 then raise exception 'P1 FAIL: only % row(s) joined template + live dest market', n; end if;
  select count(*) into v_bad
    from public.haul_contracts c
    join public.haul_contract_templates t on t.template_id = c.template_id
    join public.market_offers od on od.location_id = c.dest_location_id and od.good_id = c.good_id and od.active
    where c.status <> 'offered'
       or c.good_id <> t.good_id
       or c.quantity < t.qty_min or c.quantity > t.qty_max
       or (t.origin_location_id is not null and c.origin_location_id <> t.origin_location_id)
       or (t.dest_location_id   is not null and c.dest_location_id   <> t.dest_location_id)
       or c.origin_location_id = c.dest_location_id
       or c.reward_credits <> round(t.reward_base + c.quantity * (od.buy_price + t.reward_premium_per_unit))
       or c.expires_at <> c.offered_at + make_interval(secs => t.duration_seconds);
  if v_bad <> 0 then raise exception 'P1 FAIL: % offer(s) violate template bounds / live reward math / expiry anchor', v_bad; end if;
  raise notice 'HAUL_PASS_GENERATE ok: exactly % offers (N x ports), all offered, slots 1..N per port, reward = round(base + qty x (live dest.buy + premium)) exact', v_n * 3;
end $$;

-- ════════ P2 — WORTH TAKING: every offer beats the same-haul self-trade AND is an absolute profit (live recompute). ════════
do $$
declare v_bad int; n int;
begin
  -- contract profit = reward - qty x origin.sell (buy the haul at the origin market, deliver for the
  -- reward); the best same-haul self-trade nets qty x (dest.buy - origin.sell). The contract must beat
  -- it (structurally, by base + qty x premium) AND clear an absolute profit (covers the market-dead
  -- Drift backhauls, where self-trade is a loss).
  select count(*) into n
    from public.haul_contracts c
    join public.market_offers oo on oo.location_id = c.origin_location_id and oo.good_id = c.good_id and oo.active
    join public.market_offers od on od.location_id = c.dest_location_id   and od.good_id = c.good_id and od.active;
  if n <> (select count(*) from public.haul_contracts) then
    raise exception 'P2 FAIL: only % offer(s) joined both live market sides', n;
  end if;
  select count(*) into v_bad
    from public.haul_contracts c
    join public.market_offers oo on oo.location_id = c.origin_location_id and oo.good_id = c.good_id and oo.active
    join public.market_offers od on od.location_id = c.dest_location_id   and od.good_id = c.good_id and od.active
    where not ( c.reward_credits - c.quantity * oo.sell_price > c.quantity * (od.buy_price - oo.sell_price)
            and c.reward_credits - c.quantity * oo.sell_price > 0 );
  if v_bad <> 0 then raise exception 'P2 FAIL: % offer(s) not worth taking vs the same-haul self-trade', v_bad; end if;
  raise notice 'HAUL_PASS_WORTH_TAKING ok: every offer''s profit (reward - qty x origin.sell) beats the self-trade qty x (dest.buy - origin.sell) and is > 0';
end $$;

-- ════════ P3 — DETERMINISM: a second same-day run creates NOTHING; the offer set is a pure function of (day, port, slot) — one offer re-derived from the raw hash technique. ════════
do $$
declare r jsonb; n int; v_sig0 text; v_sig1 text;
  v_day date; v_haven uuid := (select v from hl1 where k='haven');
  v_h bigint; v_u numeric; v_hq bigint; v_tid text; v_qexp int;
begin
  v_day := (now() at time zone 'utc')::date;   -- the generator's GUC-stable UTC day boundary
  select md5(string_agg(format('%s|%s|%s|%s|%s|%s', origin_location_id, slot, template_id, good_id, quantity, reward_credits), ';'
                        order by origin_location_id, slot))
    into v_sig0 from public.haul_contracts;

  -- second run, same day: the natural key (origin, offer_day, slot) makes it a no-op.
  r := public.haul_generate_offers();
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL: second run errored: %', r; end if;
  if (r->>'offers_created')::int <> 0 then
    raise exception 'P3 FAIL: second run created % new offer(s) (must be 0 — idempotent within the day)', (r->>'offers_created')::int;
  end if;
  select count(*) into n from public.haul_contracts;
  if n <> 6 then raise exception 'P3 FAIL: row count % after re-run (want the same 6)', n; end if;
  select md5(string_agg(format('%s|%s|%s|%s|%s|%s', origin_location_id, slot, template_id, good_id, quantity, reward_credits), ';'
                        order by origin_location_id, slot))
    into v_sig1 from public.haul_contracts;
  if v_sig0 is distinct from v_sig1 then raise exception 'P3 FAIL: re-run mutated the offer set (signature changed)'; end if;

  -- RE-DERIVE Haven slot 1 from the RAW seed technique (hashtextextended, the exact 0176 salts —
  -- to_char-rendered day, DateStyle-independent — and uniform map, NOT by calling the generator):
  -- the stored offer must carry exactly this identity.
  v_h := hashtextextended(format('haul:%s:%s:%s', to_char(v_day, 'YYYY-MM-DD'), v_haven, 1), 0);
  v_u := (((v_h % 1000000) + 1000000) % 1000000)::numeric / 1000000.0;
  select x.template_id into v_tid from (
    select tt.template_id,
           sum(tt.weight) over (order by tt.template_id) as w_cum,
           sum(tt.weight) over ()                        as w_total
      from public.haul_contract_templates tt
     where tt.active and (tt.origin_location_id is null or tt.origin_location_id = v_haven)
  ) x where x.w_cum > v_u * x.w_total order by x.template_id limit 1;
  v_hq := hashtextextended(format('haulqty:%s:%s:%s', to_char(v_day, 'YYYY-MM-DD'), v_haven, 1), 0);
  select t.qty_min + (((v_hq % (t.qty_max - t.qty_min + 1)) + (t.qty_max - t.qty_min + 1)) % (t.qty_max - t.qty_min + 1))::int
    into v_qexp from public.haul_contract_templates t where t.template_id = v_tid;
  if not exists (select 1 from public.haul_contracts
                   where origin_location_id = v_haven and offer_day = v_day and slot = 1
                     and template_id = v_tid and quantity = v_qexp) then
    raise exception 'P3 FAIL: Haven slot-1 offer does not match the re-derived identity (template %, qty %)', v_tid, v_qexp;
  end if;
  raise notice 'HAUL_PASS_DETERMINISM ok: same-day re-run created 0 rows, set signature unchanged; Haven slot-1 identity re-derived from the raw hash technique (template %, qty %)', v_tid, v_qexp;
end $$;

-- ════════ P4 — EXPIRY: a past-deadline 'offered' row flips 'expired'; a past-deadline 'accepted' row is NEVER touched. ════════
do $$
declare r jsonb; n int; v_day date := (now() at time zone 'utc')::date;
  v_slag uuid := (select v from hl1 where k='slag');
  v_drift uuid := (select v from hl1 where k='drift');
  v_uA uuid := (select v from hl1 where k='uA');
begin
  -- FIXTURE (time travel; rolled back): age the Slagworks slot-1 OFFER past its deadline.
  update public.haul_contracts set expires_at = now() - interval '1 hour'
    where origin_location_id = v_slag and offer_day = v_day and slot = 1;
  -- FIXTURE (HAUL-2 stand-in; rolled back): the Driftmarch slot-1 offer becomes an ACCEPTED contract
  -- whose deadline is ALSO past — accepted contracts keep their own delivery deadline, handled by the
  -- future HAUL-2 deliver/forfeit path; the generator must never expire them.
  update public.haul_contracts
     set status = 'accepted', accepted_by = v_uA, accepted_at = now(),
         expires_at = now() - interval '1 hour'
    where origin_location_id = v_drift and offer_day = v_day and slot = 1;

  r := public.haul_generate_offers();
  if (r->>'ok')::boolean is not true then raise exception 'P4 FAIL: expiry run errored: %', r; end if;
  if (r->>'offers_expired')::int <> 1 then
    raise exception 'P4 FAIL: expected exactly 1 expiry (the aged offered row), got %', (r->>'offers_expired')::int;
  end if;
  if (r->>'offers_created')::int <> 0 then
    raise exception 'P4 FAIL: expiry run minted % new offer(s) (slots stay consumed)', (r->>'offers_created')::int;
  end if;
  select count(*) into n from public.haul_contracts
    where origin_location_id = v_slag and offer_day = v_day and slot = 1 and status = 'expired';
  if n <> 1 then raise exception 'P4 FAIL: the aged offered row did not flip to expired'; end if;
  -- the accepted row is NEVER expired by the generator (its predicate is status=offered ONLY).
  select count(*) into n from public.haul_contracts
    where origin_location_id = v_drift and offer_day = v_day and slot = 1
      and status = 'accepted' and accepted_by = v_uA;
  if n <> 1 then raise exception 'P4 FAIL: the generator touched the past-deadline ACCEPTED row'; end if;
  select count(*) into n from public.haul_contracts;
  if n <> 6 then raise exception 'P4 FAIL: expiry run changed the row count to %', n; end if;
  raise notice 'HAUL_PASS_EXPIRY ok: offered+past -> expired (exactly 1); the past-deadline accepted row NEVER touched; zero new mints';
end $$;

-- ════════ P5 — RLS/ACL shape: bulletin-public + owner-only policies, read-only tables, service-role-only generator, one cron. ════════
do $$
declare n int;
begin
  -- RLS enabled on both tables.
  if not (select relrowsecurity from pg_class where oid = 'public.haul_contracts'::regclass) then
    raise exception 'P5 FAIL: RLS not enabled on haul_contracts'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.haul_contract_templates'::regclass) then
    raise exception 'P5 FAIL: RLS not enabled on haul_contract_templates'; end if;

  -- haul_contracts: EXACTLY two policies, both SELECT — the offered-public bulletin + the owner read.
  select count(*) into n from pg_policies where schemaname='public' and tablename='haul_contracts';
  if n <> 2 then raise exception 'P5 FAIL: haul_contracts has % policies (want exactly 2)', n; end if;
  select count(*) into n from pg_policies where schemaname='public' and tablename='haul_contracts' and cmd <> 'SELECT';
  if n <> 0 then raise exception 'P5 FAIL: haul_contracts carries a non-SELECT policy'; end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='haul_contracts'
                   and policyname='haul_contracts_offered_public_read' and qual like '%offered%') then
    raise exception 'P5 FAIL: offered-public bulletin policy missing/misshapen'; end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='haul_contracts'
                   and policyname='haul_contracts_accepted_owner_read'
                   and qual like '%accepted_by%' and qual like '%auth.uid()%') then
    raise exception 'P5 FAIL: accepted-owner policy missing/misshapen'; end if;

  -- templates: exactly one public-read SELECT policy (Reference/Config).
  select count(*) into n from pg_policies where schemaname='public' and tablename='haul_contract_templates';
  if n <> 1 then raise exception 'P5 FAIL: templates have % policies (want exactly 1)', n; end if;
  select count(*) into n from pg_policies where schemaname='public' and tablename='haul_contract_templates' and cmd <> 'SELECT';
  if n <> 0 then raise exception 'P5 FAIL: templates carry a non-SELECT policy'; end if;

  -- grants: SELECT yes, any write NO, for both client roles on both tables.
  if not has_table_privilege('anon', 'public.haul_contracts', 'SELECT')
     or not has_table_privilege('authenticated', 'public.haul_contracts', 'SELECT')
     or not has_table_privilege('anon', 'public.haul_contract_templates', 'SELECT')
     or not has_table_privilege('authenticated', 'public.haul_contract_templates', 'SELECT') then
    raise exception 'P5 FAIL: client SELECT grant missing'; end if;
  if has_table_privilege('anon', 'public.haul_contracts', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('authenticated', 'public.haul_contracts', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('anon', 'public.haul_contract_templates', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('authenticated', 'public.haul_contract_templates', 'INSERT, UPDATE, DELETE') then
    raise exception 'P5 FAIL: a client role holds a WRITE grant'; end if;

  -- the generator is service-role-only (cron/server op — never a client RPC).
  if has_function_privilege('authenticated', 'public.haul_generate_offers()', 'execute')
     or has_function_privilege('anon', 'public.haul_generate_offers()', 'execute') then
    raise exception 'P5 FAIL: haul_generate_offers is client-executable'; end if;
  if not has_function_privilege('service_role', 'public.haul_generate_offers()', 'execute') then
    raise exception 'P5 FAIL: haul_generate_offers not granted to service_role'; end if;

  -- the cron exists EXACTLY once and invokes the generator.
  select count(*) into n from cron.job where jobname = 'haul-generate-offers' and command like '%haul_generate_offers%';
  if n <> 1 then raise exception 'P5 FAIL: expected exactly 1 haul-generate-offers cron job invoking the generator, got %', n; end if;

  raise notice 'HAUL_PASS_RLS_SHAPE ok: 2 SELECT-only policies (offered-public + accepted-owner), templates public-read, zero client write grants, generator service-role-only, cron scheduled once';
end $$;

select 'HAUL PROOF PASSED (dark cron-safe no-op; N x ports deterministic offers with live-market reward math; worth-taking vs self-trade; same-day idempotency + hash re-derivation; offered-only expiry sparing accepted; RLS/ACL shape)' as result;

rollback;   -- leave ZERO persisted state: no contract, no fixture user, no flag flip.
