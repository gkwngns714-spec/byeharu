-- HAUL — disposable REAL-CHAIN proof (runs on the actual chain 0001..0181 in a throwaway Supabase).
-- Proves HAUL-0/1 (the dark cron-safe no-op, the deterministic per-(day, port) offer generator — exact
-- N×ports count, template/qty bounds, LIVE-market reward math, the worth-taking economics — same-day
-- idempotency + pure-function determinism re-derived from the hash technique, the offered-only expiry
-- pass, and the RLS/ACL shape) AND HAUL-2 (the accept/deliver RPCs: dark rejects, the origin-port
-- accept claim with deliver_by = accepted_at + duration, idempotent replays, the accept guards —
-- already_accepted/already_accepted_other/wrong-port/stale-offer/too_many_active — the deliver path:
-- wrong_port, not-yours, insufficient_cargo, then Trade-Cargo consume + Wallet credit EXACT, and the
-- deadline: deadline_passed reject + the generator's (a2) accepted-past-deliver_by → 'cancelled' pass
-- freeing the cap slot, while within-deadline accepted rows stay untouched by EVERY pass) AND the
-- HAUL-3 read surface (0181 get_port_contracts: the dark gate-first reject — reject-before-read, no
-- bulletin readable pre-flip — and the lit board reflection after an accept). Fixture
-- users carry the 'hl1.' email prefix. The ENTIRE proof runs inside ONE transaction that ROLLBACKs —
-- it persists NO contract, receipt, wallet, ship, template, config, or flag flip. No production
-- access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables haul_contracts_enabled ONLY inside this rolled-back transaction (AFTER proving
-- the dark no-op + the dark RPC rejects); the ROLLBACK reverts it, so the committed/production flag
-- value stays false. It transiently mirrors production config a fresh chain lacks
-- (reveal_starter_ports — ports must be ACTIVE for the generator's port filter — and
-- mainship_space_movement_enabled for the port-to-port travel) — reverted by ROLLBACK. ALL
-- haul_contracts rows are minted by the REAL generator and transitioned by the REAL HAUL-2 RPCs; the
-- harness never INSERTs into haul_contracts or haul_contract_templates and never writes
-- haul_receipts at all. Its direct haul_contracts writes are marked FIXTURES only: aging an offered
-- row's expires_at / an accepted row's deliver_by (time travel) and the P4 accepted stand-in — all
-- rolled back. Delivery cargo is granted through the REAL Trade-Cargo leaf `trade_cargo_add_lot`
-- (the market_buy path's own sole lot inserter, 0089) — never a direct ship_cargo_lots insert.
-- Wallets are pre-set to a known balance by direct owner insert (the tm1/sv1 funding precedent;
-- rolled back) so every credit assert is an EXACT delta.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table hl1(k text primary key, v uuid) on commit preserve rows;
insert into hl1 values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven Reach (city/consumer)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002'),     -- Slagworks Anchorage (industrial)
  ('drift','b1a00003-0066-4a00-8a00-000000000003');     -- Driftmarch Waypost (frontier importer)

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- travel helper: issue the REAL move command, rewind the movement (sanctioned clock surgery — the
-- team-command idiom; depart_at rewound too so arrive_at > depart_at holds), settle through the REAL
-- arrival processor, then assert docked via the ONE resolver.
create or replace function pg_temp.goto_port(p_user uuid, p_ship uuid, p_dest uuid) returns void language plpgsql as $$
declare r jsonb; v_loc uuid;
begin
  r := pg_temp.call_as(p_user, format('public.command_main_ship_space_move_to_location(%L::uuid, %L::uuid, %L::uuid)',
                                      p_dest, gen_random_uuid(), p_ship));
  if (r->>'ok')::boolean is not true then raise exception 'goto_port FAIL move: %', r; end if;
  update public.main_ship_space_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where main_ship_id = p_ship and status = 'moving';
  perform public.process_mainship_space_arrivals();
  v_loc := public.mainship_resolve_docked_location(p_ship);
  if v_loc is distinct from p_dest then raise exception 'goto_port FAIL: ship % docked at % (want %)', p_ship, v_loc, p_dest; end if;
end $$;

-- three fixture players: uA (the P4 shipless accepted-row owner), uH (the hauler), uO (the other player).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uA','uH','uO'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'hl1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into hl1 values (sk, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (reverted by ROLLBACK): reveal the starter
-- ports (the generator only posts at ACTIVE ports) + enable port-to-port movement (for goto_port).
-- haul_contracts_enabled stays OFF here (P0 proves the dark posture first).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'hl1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
end $$;

-- commission uH's and uO's first ships (real RPC) → docked at Haven; pre-set wallets at a KNOWN 100
-- by direct owner insert (the tm1/sv1 funding precedent; rolled back) so credit asserts are EXACT.
do $$
declare r jsonb; sk text; u uuid; s uuid;
begin
  foreach sk in array array['uH','uO'] loop
    u := (select v from hl1 where hl1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', sk, r; end if;
    select main_ship_id into s from public.main_ship_instances where player_id = u;
    insert into hl1 values ('ship'||sk, s);
  end loop;
  insert into public.player_wallet (player_id, balance) values
    ((select v from hl1 where k='uH'), 100),
    ((select v from hl1 where k='uO'), 100)
  on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- ════════ P0 — DARK cron-safety + DARK RPC rejects: the generator is a clean no-op envelope while dark — zero rows, NEVER a raise; accept/deliver gate-first reject before ANY read, zero receipts. ════════
do $$
declare r jsonb; n int;
  uH uuid := (select v from hl1 where k='uH'); shipH uuid := (select v from hl1 where k='shipuH');
begin
  -- the cron fires this exact call today in production; while dark it must return (never raise)
  -- with the feature_disabled envelope and write NOTHING.
  r := public.haul_generate_offers();
  if (r->>'ok')::boolean is not false or (r->>'code') is distinct from 'feature_disabled' then
    raise exception 'P0 FAIL: dark generator did not no-op with feature_disabled: %', r;
  end if;
  select count(*) into n from public.haul_contracts;
  if n <> 0 then raise exception 'P0 FAIL: dark generator created % row(s)', n; end if;

  -- the HAUL-2 RPCs gate-first reject while dark (before any ship/contract read) and write nothing.
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, gen_random_uuid(), gen_random_uuid()));
  if (r->>'reason') is distinct from 'haul_contracts_disabled' then raise exception 'P0 FAIL dark accept: %', r; end if;
  r := pg_temp.call_as(uH, format('public.haul_deliver_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, gen_random_uuid(), gen_random_uuid()));
  if (r->>'reason') is distinct from 'haul_contracts_disabled' then raise exception 'P0 FAIL dark deliver: %', r; end if;
  select count(*) into n from public.haul_receipts;
  if n <> 0 then raise exception 'P0 FAIL: dark RPCs wrote % receipt(s)', n; end if;

  -- the HAUL-3 read RPC (0181) gate-first rejects while dark too (reject-before-read house law:
  -- no bulletin is readable before the flip); unauthenticated → not_authenticated envelope-first.
  r := pg_temp.call_as(uH, format('public.get_port_contracts(%L::uuid)', (select v from hl1 where k='haven')));
  if (r->>'reason') is distinct from 'haul_contracts_disabled' then raise exception 'P0 FAIL dark read: %', r; end if;
  perform set_config('request.jwt.claims', '', true);
  r := public.get_port_contracts((select v from hl1 where k='haven'));
  if (r->>'reason') is distinct from 'not_authenticated' then raise exception 'P0 FAIL unauthenticated read: %', r; end if;

  -- enable the dark haul capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='haul_contracts_enabled';
  raise notice 'HAUL_PASS_DARK_GATE ok: dark run -> feature_disabled envelope (no raise), zero rows written; dark accept/deliver/read -> haul_contracts_disabled, zero receipts';
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
       or c.expires_at <> c.offered_at + make_interval(secs => t.duration_seconds)
       or c.deliver_by is not null;   -- an OFFERED row carries no delivery deadline (accept sets it)
  if v_bad <> 0 then raise exception 'P1 FAIL: % offer(s) violate template bounds / live reward math / expiry anchor', v_bad; end if;
  raise notice 'HAUL_PASS_GENERATE ok: exactly % offers (N x ports), all offered, slots 1..N per port, reward = round(base + qty x (live dest.buy + premium)) exact, deliver_by null pre-accept', v_n * 3;
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

-- ════════ P4 — EXPIRY: a past-deadline 'offered' row flips 'expired'; a past-OFFER-deadline 'accepted' row (deliver_by still ahead) is NEVER touched by EITHER pass. ════════
do $$
declare r jsonb; n int; v_day date := (now() at time zone 'utc')::date;
  v_slag uuid := (select v from hl1 where k='slag');
  v_drift uuid := (select v from hl1 where k='drift');
  v_uA uuid := (select v from hl1 where k='uA');
begin
  -- FIXTURE (time travel; rolled back): age the Slagworks slot-1 OFFER past its deadline.
  update public.haul_contracts set expires_at = now() - interval '1 hour'
    where origin_location_id = v_slag and offer_day = v_day and slot = 1;
  -- FIXTURE (accepted stand-in; rolled back): the Driftmarch slot-1 offer becomes an ACCEPTED
  -- contract whose OFFER deadline is past but whose DELIVERY deadline (deliver_by — the 0179
  -- accepted-row CHECK requires it) is still ahead: the offer-expiry pass must never touch it
  -- (predicate status='offered' ONLY) and the (a2) cancel pass must spare it (within deliver_by).
  update public.haul_contracts
     set status = 'accepted', accepted_by = v_uA, accepted_at = now(),
         expires_at = now() - interval '1 hour',
         deliver_by = now() + interval '6 hours'
    where origin_location_id = v_drift and offer_day = v_day and slot = 1;

  r := public.haul_generate_offers();
  if (r->>'ok')::boolean is not true then raise exception 'P4 FAIL: expiry run errored: %', r; end if;
  if (r->>'offers_expired')::int <> 1 then
    raise exception 'P4 FAIL: expected exactly 1 expiry (the aged offered row), got %', (r->>'offers_expired')::int;
  end if;
  if (r->>'accepted_cancelled')::int <> 0 then
    raise exception 'P4 FAIL: the (a2) pass cancelled % within-deadline accepted row(s) (must be 0)', (r->>'accepted_cancelled')::int;
  end if;
  if (r->>'offers_created')::int <> 0 then
    raise exception 'P4 FAIL: expiry run minted % new offer(s) (slots stay consumed)', (r->>'offers_created')::int;
  end if;
  select count(*) into n from public.haul_contracts
    where origin_location_id = v_slag and offer_day = v_day and slot = 1 and status = 'expired';
  if n <> 1 then raise exception 'P4 FAIL: the aged offered row did not flip to expired'; end if;
  -- the accepted row is NEVER expired by the generator (its offer-expiry predicate is status=offered
  -- ONLY) and NEVER cancelled while deliver_by is ahead.
  select count(*) into n from public.haul_contracts
    where origin_location_id = v_drift and offer_day = v_day and slot = 1
      and status = 'accepted' and accepted_by = v_uA;
  if n <> 1 then raise exception 'P4 FAIL: the generator touched the within-deadline ACCEPTED row'; end if;
  select count(*) into n from public.haul_contracts;
  if n <> 6 then raise exception 'P4 FAIL: expiry run changed the row count to %', n; end if;
  raise notice 'HAUL_PASS_EXPIRY ok: offered+past -> expired (exactly 1); the accepted row (offer deadline past, deliver_by ahead) NEVER touched by either pass; zero new mints, zero cancels';
end $$;

-- ════════ P5 — RLS/ACL shape: bulletin-public + owner-only policies, read-only tables, service-role-only generator, one cron; haul_receipts owner-read SELECT-only; RPCs authenticated-only. ════════
do $$
declare n int;
begin
  -- RLS enabled on all three haul tables.
  if not (select relrowsecurity from pg_class where oid = 'public.haul_contracts'::regclass) then
    raise exception 'P5 FAIL: RLS not enabled on haul_contracts'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.haul_contract_templates'::regclass) then
    raise exception 'P5 FAIL: RLS not enabled on haul_contract_templates'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.haul_receipts'::regclass) then
    raise exception 'P5 FAIL: RLS not enabled on haul_receipts'; end if;

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

  -- haul_receipts (0179): exactly one owner-read SELECT policy; authenticated SELECT only, anon never.
  select count(*) into n from pg_policies where schemaname='public' and tablename='haul_receipts';
  if n <> 1 then raise exception 'P5 FAIL: haul_receipts has % policies (want exactly 1)', n; end if;
  select count(*) into n from pg_policies where schemaname='public' and tablename='haul_receipts' and cmd <> 'SELECT';
  if n <> 0 then raise exception 'P5 FAIL: haul_receipts carries a non-SELECT policy'; end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='haul_receipts'
                   and policyname='haul_receipts_select_own'
                   and qual like '%main_ship_instances%' and qual like '%auth.uid()%') then
    raise exception 'P5 FAIL: haul_receipts owner policy missing/misshapen'; end if;

  -- grants: SELECT yes, any write NO, for the client roles across the haul tables.
  if not has_table_privilege('anon', 'public.haul_contracts', 'SELECT')
     or not has_table_privilege('authenticated', 'public.haul_contracts', 'SELECT')
     or not has_table_privilege('anon', 'public.haul_contract_templates', 'SELECT')
     or not has_table_privilege('authenticated', 'public.haul_contract_templates', 'SELECT')
     or not has_table_privilege('authenticated', 'public.haul_receipts', 'SELECT') then
    raise exception 'P5 FAIL: client SELECT grant missing'; end if;
  if has_table_privilege('anon', 'public.haul_receipts', 'SELECT') then
    raise exception 'P5 FAIL: haul_receipts is anon-readable (owner-only table)'; end if;
  if has_table_privilege('anon', 'public.haul_contracts', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('authenticated', 'public.haul_contracts', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('anon', 'public.haul_contract_templates', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('authenticated', 'public.haul_contract_templates', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('anon', 'public.haul_receipts', 'INSERT, UPDATE, DELETE')
     or has_table_privilege('authenticated', 'public.haul_receipts', 'INSERT, UPDATE, DELETE') then
    raise exception 'P5 FAIL: a client role holds a WRITE grant'; end if;

  -- the generator is service-role-only (cron/server op — never a client RPC).
  if has_function_privilege('authenticated', 'public.haul_generate_offers()', 'execute')
     or has_function_privilege('anon', 'public.haul_generate_offers()', 'execute') then
    raise exception 'P5 FAIL: haul_generate_offers is client-executable'; end if;
  if not has_function_privilege('service_role', 'public.haul_generate_offers()', 'execute') then
    raise exception 'P5 FAIL: haul_generate_offers not granted to service_role'; end if;

  -- the HAUL-2 RPCs are authenticated client commands; anon never. The internals they fan out to
  -- (Trade-Cargo consume/add-lot, Wallet credit, the docked resolver) stay client-revoked.
  if not has_function_privilege('authenticated', 'public.haul_accept_contract(uuid,uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.haul_deliver_contract(uuid,uuid,uuid)', 'execute') then
    raise exception 'P5 FAIL: a HAUL-2 RPC is not authenticated-executable'; end if;
  if has_function_privilege('anon', 'public.haul_accept_contract(uuid,uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.haul_deliver_contract(uuid,uuid,uuid)', 'execute') then
    raise exception 'P5 FAIL: a HAUL-2 RPC is anon-executable'; end if;
  if has_function_privilege('authenticated', 'public.trade_cargo_consume(uuid,text,numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.trade_cargo_add_lot(uuid,text,numeric,numeric,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.wallet_credit(uuid,numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.mainship_resolve_docked_location(uuid)', 'execute') then
    raise exception 'P5 FAIL: an internal leaf is client-executable'; end if;

  -- the cron exists EXACTLY once and invokes the generator.
  select count(*) into n from cron.job where jobname = 'haul-generate-offers' and command like '%haul_generate_offers%';
  if n <> 1 then raise exception 'P5 FAIL: expected exactly 1 haul-generate-offers cron job invoking the generator, got %', n; end if;

  raise notice 'HAUL_PASS_RLS_SHAPE ok: 2 SELECT-only policies (offered-public + accepted-owner), templates public-read, haul_receipts owner-read SELECT-only (anon never), zero client write grants, generator service-role-only, RPCs authenticated-only with private internals, cron scheduled once';
end $$;

-- ════════ P6 — ACCEPT happy path: docked at the ORIGIN port, offered -> accepted; deliver_by = accepted_at + template duration EXACT; receipt; idempotent replay. ════════
do $$
declare r jsonb; n int; v_day date := (now() at time zone 'utc')::date;
  uH uuid := (select v from hl1 where k='uH'); shipH uuid := (select v from hl1 where k='shipuH');
  v_haven uuid := (select v from hl1 where k='haven');
  v_c1 uuid; v_req uuid := gen_random_uuid(); c record;
begin
  -- the Haven slot-1 offer (untouched by P4) — uH's ship is docked at Haven (commissioned there).
  select * into c from public.haul_contracts
    where origin_location_id = v_haven and offer_day = v_day and slot = 1 and status = 'offered';
  if not found then raise exception 'P6 FAIL: no offered Haven slot-1 contract'; end if;
  v_c1 := c.id;
  insert into hl1 values ('c1', v_c1), ('acceptreq', v_req);

  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P6 FAIL accept: %', r; end if;
  if (r->>'action') is distinct from 'accept' or (r->>'reward_credits')::numeric <> 0
     or (r->>'contract_reward_credits')::numeric <> c.reward_credits
     or (r->>'dest_location_id')::uuid is distinct from c.dest_location_id
     or (r->>'location_id')::uuid is distinct from v_haven then
    raise exception 'P6 FAIL accept envelope: %', r; end if;

  -- row state: offered -> accepted; accepted_by/ship/at set; deliver_by = accepted_at + the
  -- template's duration_seconds EXACT (the HAUL-2 tempo reconciliation); NO cargo/credits moved.
  select count(*) into n from public.haul_contracts c2
    join public.haul_contract_templates t on t.template_id = c2.template_id
    where c2.id = v_c1 and c2.status = 'accepted'
      and c2.accepted_by = uH and c2.accepted_ship = shipH and c2.accepted_at is not null
      and c2.deliver_by = c2.accepted_at + make_interval(secs => t.duration_seconds);
  if n <> 1 then raise exception 'P6 FAIL: accepted row state/deliver_by anchor wrong'; end if;
  if (select balance from public.player_wallet where player_id = uH) <> 100 then
    raise exception 'P6 FAIL: accept moved the wallet (a claim moves NO credits)'; end if;
  select count(*) into n from public.ship_cargo_lots where main_ship_id = shipH;
  if n <> 0 then raise exception 'P6 FAIL: accept moved cargo (a claim moves NO cargo)'; end if;

  -- exactly ONE receipt with the exact fields (action accept, credits moved = 0).
  select count(*) into n from public.haul_receipts where main_ship_id = shipH;
  if n <> 1 then raise exception 'P6 FAIL: % receipts after accept', n; end if;
  if not exists (select 1 from public.haul_receipts
                   where main_ship_id = shipH and request_id = v_req and contract_id = v_c1
                     and action = 'accept' and good_id = c.good_id and quantity = c.quantity
                     and reward_credits = 0 and location_id = v_haven) then
    raise exception 'P6 FAIL: accept receipt fields wrong'; end if;

  -- idempotent replay: same (ship, request_id) -> replayed verbatim, no second receipt, row untouched.
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true
     or (r->>'action') is distinct from 'accept' or (r->>'contract_id')::uuid is distinct from v_c1 then
    raise exception 'P6 FAIL accept replay: %', r; end if;
  select count(*) into n from public.haul_receipts where main_ship_id = shipH;
  if n <> 1 then raise exception 'P6 FAIL: replay wrote a receipt'; end if;

  -- HAUL-3 (0181): the lit read surface reflects the board — the accepted contract left the
  -- 'offered' tab, 'mine' carries it (deliver_by + dest), the offered tab lists exactly the
  -- port's remaining FRESH offered rows, and max_active surfaces the seeded cap.
  r := pg_temp.call_as(uH, format('public.get_port_contracts(%L::uuid)', v_haven));
  if (r->>'ok')::boolean is not true then raise exception 'P6 FAIL lit read: %', r; end if;
  if (r->>'max_active')::int <> 3 then raise exception 'P6 FAIL lit read: max_active % (want the seeded 3)', r->>'max_active'; end if;
  select count(*) into n from jsonb_array_elements(r->'offered') e where (e->>'contract_id')::uuid = v_c1;
  if n <> 0 then raise exception 'P6 FAIL lit read: the accepted contract is still on the offered tab'; end if;
  select count(*) into n from jsonb_array_elements(r->'mine') e
    where (e->>'contract_id')::uuid = v_c1 and (e->>'deliver_by') is not null
      and (e->>'dest_location_id')::uuid = c.dest_location_id;
  if n <> 1 then raise exception 'P6 FAIL lit read: mine does not carry the accepted contract with its deliver_by/dest'; end if;
  select count(*) into n from jsonb_array_elements(r->'offered') e;
  if n <> (select count(*) from public.haul_contracts
             where origin_location_id = v_haven and status = 'offered' and expires_at > now()) then
    raise exception 'P6 FAIL lit read: offered tab does not match the port''s fresh offered rows'; end if;
  raise notice 'HAUL_PASS_ACCEPT ok: offered -> accepted at the origin port; deliver_by = accepted_at + duration exact; zero cargo/credit movement; 1 receipt; replay verbatim; lit read reflects the board (mine + fresh offered + max_active)';
end $$;

-- ════════ P6b — ACCEPT guards: already_accepted (self, fresh request) · already_accepted_other · wrong port · stale offer (fail-closed) · too_many_active (replay still works at the cap). ════════
do $$
declare r jsonb; n int; v_day date := (now() at time zone 'utc')::date;
  uH uuid := (select v from hl1 where k='uH'); shipH uuid := (select v from hl1 where k='shipuH');
  uO uuid := (select v from hl1 where k='uO'); shipO uuid := (select v from hl1 where k='shipuO');
  v_haven uuid := (select v from hl1 where k='haven');
  v_slag uuid := (select v from hl1 where k='slag');
  v_c1 uuid := (select v from hl1 where k='c1');
  v_req uuid := (select v from hl1 where k='acceptreq');
  v_h2 uuid; v_h2_exp timestamptz; v_s2 uuid;
begin
  select id into v_h2 from public.haul_contracts
    where origin_location_id = v_haven and offer_day = v_day and slot = 2;
  select id into v_s2 from public.haul_contracts
    where origin_location_id = v_slag and offer_day = v_day and slot = 2;

  -- already_accepted (self, FRESH request id — a double-tap with a regenerated request): no write.
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'already_accepted' then raise exception 'P6b FAIL self re-accept: %', r; end if;

  -- already_accepted_other: uO (docked at Haven) tries the contract uH holds.
  r := pg_temp.call_as(uO, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipO, v_c1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'already_accepted_other' then raise exception 'P6b FAIL foreign accept: %', r; end if;

  -- wrong port: a Slagworks contract is not on Haven's bulletin (origin-port accept, fail-closed fold).
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_s2, gen_random_uuid()));
  if (r->>'reason') is distinct from 'contract_not_found' then raise exception 'P6b FAIL wrong-port accept: %', r; end if;

  -- stale offer, fail-closed: an 'offered' row past expires_at rejects at accept EVEN BEFORE the
  -- hourly cron flips it. FIXTURE (time travel; restored below): age Haven slot-2.
  select expires_at into v_h2_exp from public.haul_contracts where id = v_h2;
  update public.haul_contracts set expires_at = now() - interval '1 minute' where id = v_h2;
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_h2, gen_random_uuid()));
  if (r->>'reason') is distinct from 'contract_not_found' then raise exception 'P6b FAIL stale-offer accept: %', r; end if;
  update public.haul_contracts set expires_at = v_h2_exp where id = v_h2;   -- restore the fixture

  -- too_many_active: lower the cap knob to 1 (transient; restored) — uH already holds 1 active.
  update public.game_config set value='1'::jsonb where key='haul_max_active_per_player';
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_h2, gen_random_uuid()));
  if (r->>'reason') is distinct from 'too_many_active' or (r->>'active')::int <> 1 or (r->>'max')::int <> 1 then
    raise exception 'P6b FAIL cap: %', r; end if;
  -- AT the cap, the ORIGINAL accept still replays (the count excludes the contract being re-accepted).
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then
    raise exception 'P6b FAIL replay-at-cap: %', r; end if;
  update public.game_config set value='3'::jsonb where key='haul_max_active_per_player';   -- restore

  -- ALL guards wrote nothing: Haven slot-2 still offered, receipts unchanged, wallet unchanged.
  select count(*) into n from public.haul_contracts where id = v_h2 and status = 'offered';
  if n <> 1 then raise exception 'P6b FAIL: a guard mutated the Haven slot-2 offer'; end if;
  select count(*) into n from public.haul_receipts;
  if n <> 1 then raise exception 'P6b FAIL: a guard wrote a receipt (% total)', n; end if;
  if (select balance from public.player_wallet where player_id = uH) <> 100 then
    raise exception 'P6b FAIL: a guard moved the wallet'; end if;
  raise notice 'HAUL_PASS_ACCEPT_GUARDS ok: already_accepted (self), already_accepted_other, wrong-port + stale-offer contract_not_found (fail-closed), too_many_active at cap 1 with replay-at-cap intact — all zero-write';
end $$;

-- ════════ P7 — DELIVER guards then happy path: wrong_port at the origin · not-yours · insufficient_cargo at the dest; then Trade-Cargo consume + Wallet credit EXACT + receipt + replay. ════════
do $$
declare r jsonb; n int;
  uH uuid := (select v from hl1 where k='uH'); shipH uuid := (select v from hl1 where k='shipuH');
  uO uuid := (select v from hl1 where k='uO'); shipO uuid := (select v from hl1 where k='shipuO');
  v_haven uuid := (select v from hl1 where k='haven');
  v_c1 uuid := (select v from hl1 where k='c1');
  c record; v_basis numeric; v_req uuid := gen_random_uuid(); v_avail numeric;
begin
  select * into c from public.haul_contracts where id = v_c1;   -- accepted by uH; dest is data-driven

  -- wrong_port: uH is still docked at the ORIGIN (Haven) — delivery needs the DEST port.
  r := pg_temp.call_as(uH, format('public.haul_deliver_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'wrong_port'
     or (r->>'dest_location_id')::uuid is distinct from c.dest_location_id then
    raise exception 'P7 FAIL wrong-port deliver: %', r; end if;

  -- not-yours: uO (docked at Haven) cannot deliver uH's contract — fail-closed contract_not_found.
  r := pg_temp.call_as(uO, format('public.haul_deliver_contract(%L::uuid, %L::uuid, %L::uuid)', shipO, v_c1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'contract_not_found' then raise exception 'P7 FAIL foreign deliver: %', r; end if;

  -- travel to the contract's destination (real move command + the REAL arrival processor).
  perform pg_temp.goto_port(uH, shipH, c.dest_location_id);

  -- insufficient_cargo: docked at the dest with an EMPTY hold.
  r := pg_temp.call_as(uH, format('public.haul_deliver_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_cargo'
     or (r->>'available')::numeric <> 0 or (r->>'need')::int <> c.quantity then
    raise exception 'P7 FAIL insufficient cargo: %', r; end if;
  raise notice 'HAUL_PASS_DELIVER_GUARDS ok: wrong_port at the origin, foreign deliver contract_not_found, empty-hold insufficient_cargo (available/need exact) — all zero-write';

  -- FIXTURE cargo through the REAL Trade-Cargo leaf (the market_buy path's own sole lot inserter,
  -- 0089 — never a direct ship_cargo_lots insert): qty+2 units at the origin's live sell price, so
  -- the consume assert below is an exact remainder AND an exact cost basis.
  select coalesce((select o.sell_price from public.market_offers o
                     where o.location_id = c.origin_location_id and o.good_id = c.good_id and o.active), 1)
    into v_basis;
  perform public.trade_cargo_add_lot(shipH, c.good_id, c.quantity + 2, v_basis, c.origin_location_id);

  -- happy path: wallet 100 (known) -> +reward EXACT; cargo -qty EXACT (remainder 2); FIFO cost
  -- basis consumed = qty x basis EXACT; accepted -> delivered; one deliver receipt.
  r := pg_temp.call_as(uH, format('public.haul_deliver_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P7 FAIL deliver: %', r; end if;
  if (r->>'action') is distinct from 'deliver'
     or (r->>'reward_credits')::numeric <> c.reward_credits
     or (r->>'quantity')::int <> c.quantity
     or (r->>'location_id')::uuid is distinct from c.dest_location_id
     or (r->>'cost_basis_consumed')::numeric <> c.quantity * v_basis then
    raise exception 'P7 FAIL deliver envelope: %', r; end if;
  if (select balance from public.player_wallet where player_id = uH) <> 100 + c.reward_credits then
    raise exception 'P7 FAIL: wallet % (want exactly 100 + the reward %)',
      (select balance from public.player_wallet where player_id = uH), c.reward_credits; end if;
  select coalesce(sum(qty), 0) into v_avail from public.ship_cargo_lots
    where main_ship_id = shipH and good_id = c.good_id;
  if v_avail <> 2 then raise exception 'P7 FAIL: cargo remainder % (want exactly 2 — consume must debit exactly qty)', v_avail; end if;
  select count(*) into n from public.haul_contracts
    where id = v_c1 and status = 'delivered' and delivered_at is not null;
  if n <> 1 then raise exception 'P7 FAIL: contract not delivered'; end if;
  if not exists (select 1 from public.haul_receipts
                   where main_ship_id = shipH and request_id = v_req and contract_id = v_c1
                     and action = 'deliver' and good_id = c.good_id and quantity = c.quantity
                     and reward_credits = c.reward_credits and location_id = c.dest_location_id) then
    raise exception 'P7 FAIL: deliver receipt fields wrong'; end if;
  select count(*) into n from public.haul_receipts where main_ship_id = shipH;
  if n <> 2 then raise exception 'P7 FAIL: % receipts (want accept + deliver = 2)', n; end if;

  -- idempotent replay: verbatim envelope (no cost-basis field — the trade replay posture), no
  -- double credit, no double consume, no third receipt.
  r := pg_temp.call_as(uH, format('public.haul_deliver_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, v_c1, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true
     or (r->>'reward_credits')::numeric <> c.reward_credits or (r ? 'cost_basis_consumed') then
    raise exception 'P7 FAIL deliver replay: %', r; end if;
  if (select balance from public.player_wallet where player_id = uH) <> 100 + c.reward_credits then
    raise exception 'P7 FAIL: replay re-credited'; end if;
  select coalesce(sum(qty), 0) into v_avail from public.ship_cargo_lots
    where main_ship_id = shipH and good_id = c.good_id;
  if v_avail <> 2 then raise exception 'P7 FAIL: replay re-consumed'; end if;
  select count(*) into n from public.haul_receipts where main_ship_id = shipH;
  if n <> 2 then raise exception 'P7 FAIL: replay wrote a receipt'; end if;
  raise notice 'HAUL_PASS_DELIVER ok: consume via trade_cargo_consume (-qty exact, remainder 2, FIFO cost basis qty x origin.sell exact) + wallet_credit (+reward exact on the known 100) + delivered flip + receipt; replay verbatim with no double credit/consume';
end $$;

-- ════════ P8 — DEADLINE + CANCEL: past-deliver_by delivery rejects deadline_passed (zero-write); the generator (a2) pass flips it 'cancelled' and FREES the active-cap slot; the within-deadline accepted row still untouched. ════════
do $$
declare r jsonb; n int; v_day date := (now() at time zone 'utc')::date;
  uH uuid := (select v from hl1 where k='uH'); shipH uuid := (select v from hl1 where k='shipuH');
  uA uuid := (select v from hl1 where k='uA');
  v_drift uuid := (select v from hl1 where k='drift');
  v_px uuid; c2 record; v_bal numeric;
begin
  -- uH is docked at contract-1's destination (data-driven). That port's slot-2 offer is still on
  -- its bulletin (P4 consumed only the two slot-1 rows) — accept it there, at its origin.
  v_px := public.mainship_resolve_docked_location(shipH);
  select * into c2 from public.haul_contracts
    where origin_location_id = v_px and offer_day = v_day and slot = 2 and status = 'offered';
  if not found then raise exception 'P8 FAIL: no offered slot-2 contract at uH''s port'; end if;
  r := pg_temp.call_as(uH, format('public.haul_accept_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, c2.id, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P8 FAIL accept c2: %', r; end if;
  select count(*) into n from public.haul_contracts where accepted_by = uH and status = 'accepted';
  if n <> 1 then raise exception 'P8 FAIL: active count % after accept (want 1)', n; end if;

  -- FIXTURE (time travel; rolled back): age the DELIVERY deadline past.
  update public.haul_contracts set deliver_by = now() - interval '1 hour' where id = c2.id;

  -- travel to c2's destination and attempt the delivery: past deliver_by -> deadline_passed, zero
  -- writes (the RPC never flips the row — the cancel transition stays the generator's alone).
  perform pg_temp.goto_port(uH, shipH, c2.dest_location_id);
  select balance into v_bal from public.player_wallet where player_id = uH;
  r := pg_temp.call_as(uH, format('public.haul_deliver_contract(%L::uuid, %L::uuid, %L::uuid)', shipH, c2.id, gen_random_uuid()));
  if (r->>'reason') is distinct from 'deadline_passed' then raise exception 'P8 FAIL past-deadline deliver: %', r; end if;
  select count(*) into n from public.haul_contracts where id = c2.id and status = 'accepted';
  if n <> 1 then raise exception 'P8 FAIL: the deliver RPC mutated the overdue row'; end if;
  if (select balance from public.player_wallet where player_id = uH) <> v_bal then
    raise exception 'P8 FAIL: past-deadline deliver moved the wallet'; end if;

  -- the generator's (a2) pass: overdue accepted -> 'cancelled' (exactly 1), freeing the cap slot;
  -- uA's within-deadline ACCEPTED row still untouched; no new mints, no offer expiries.
  r := public.haul_generate_offers();
  if (r->>'ok')::boolean is not true then raise exception 'P8 FAIL: cancel run errored: %', r; end if;
  if (r->>'accepted_cancelled')::int <> 1 then
    raise exception 'P8 FAIL: accepted_cancelled % (want exactly 1 — the overdue row)', (r->>'accepted_cancelled')::int; end if;
  if (r->>'offers_expired')::int <> 0 or (r->>'offers_created')::int <> 0 then
    raise exception 'P8 FAIL: cancel run expired/minted (%/%)', (r->>'offers_expired')::int, (r->>'offers_created')::int; end if;
  select count(*) into n from public.haul_contracts where id = c2.id and status = 'cancelled';
  if n <> 1 then raise exception 'P8 FAIL: the overdue accepted row did not flip to cancelled'; end if;
  -- the slot is FREE: the cap counts status='accepted' only, and uH now holds zero.
  select count(*) into n from public.haul_contracts where accepted_by = uH and status = 'accepted';
  if n <> 0 then raise exception 'P8 FAIL: cancel did not free the active slot (count %)', n; end if;
  -- the within-deadline ACCEPTED row (uA, Drift slot-1 — deliver_by still ahead) survives again.
  select count(*) into n from public.haul_contracts
    where origin_location_id = v_drift and offer_day = v_day and slot = 1
      and status = 'accepted' and accepted_by = uA;
  if n <> 1 then raise exception 'P8 FAIL: the cancel pass touched the within-deadline ACCEPTED row'; end if;
  select count(*) into n from public.haul_contracts;
  if n <> 6 then raise exception 'P8 FAIL: cancel run changed the row count to %', n; end if;
  raise notice 'HAUL_PASS_DEADLINE_CANCEL ok: past-deliver_by deliver -> deadline_passed (zero-write, reject-only); generator (a2) flipped exactly 1 overdue accepted -> cancelled freeing the cap slot; within-deadline accepted row untouched; zero expiries/mints';
end $$;

select 'HAUL PROOF PASSED (dark cron-safe no-op + dark RPC/read rejects; N x ports deterministic offers with live-market reward math; worth-taking vs self-trade; same-day idempotency + hash re-derivation; offered-only expiry sparing accepted; RLS/ACL shape incl. haul_receipts + RPC ACLs; origin-port accept with deliver_by anchor + guards + replay-at-cap + the lit board reflection; deliver = Trade-Cargo consume + Wallet credit exact with guards + replay; deadline_passed + the (a2) cancel freeing the slot)' as result;

rollback;   -- leave ZERO persisted state: no contract, receipt, wallet, ship, fixture user, or flag flip.
