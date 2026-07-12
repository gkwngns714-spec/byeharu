-- Byeharu — HAUL-0/1: delivery-contracts foundation (templates + contracts schema + flag + the
-- deterministic offer generator + cron; everything DARK).
--
-- Queue slice #12 of the full-capacity plan (master plan §C P2): NPC delivery contracts — a per-port
-- bulletin offering "deliver N×good to port B by T for C credits" (the retention loop; closes part of
-- gap G9). THIS slice is HAUL-0 (schema + migration-seeded templates + `haul_contracts_enabled`
-- seeded 'false') + HAUL-1 (the cron-driven, seeded-deterministic offer generator). The accept/deliver
-- RPCs (HAUL-2: docked-verified + cargo debit via Trade-Cargo's own functions + `wallet_credit` with
-- receipts) and the PortScreen bulletin UI (HAUL-3) are LATER slices — no client code here.
--
-- ── OWNERSHIP (SYSTEM_BOUNDARIES rows land in THIS PR — the §E law) ──────────────────────────────
--   · haul_contract_templates = Reference/Config: MIGRATION-SEEDED ONLY, NO runtime writer, ever
--                               (the market_offers 0085/0173 / port_item_demand 0174 posture).
--                               Public read-only.
--   · haul_contracts          = Haul Contracts: sole writer TODAY = `haul_generate_offers()` (this
--                               migration — inserts 'offered' rows + flips stale 'offered'→'expired',
--                               NOTHING else); the ONLY other writers, EVER, are the future HAUL-2
--                               accept/deliver RPCs (offered→accepted→delivered/cancelled). No other
--                               system may write here. The charter guard: Contracts owns ONLY
--                               haul_contracts (+ its future receipts); cargo moves only through
--                               Trade-Cargo functions, credits only through Wallet — and HAUL-0/1
--                               writes NEITHER cargo NOR credits: the generator creates contract
--                               OFFERS only (rows in its own table). Zero cross-system writes.
--
-- ── REWARD MATH (proposed; [D] OWNER-TUNABLE — a retune is a one-migration reseed) ───────────────
-- Price semantics (0085/0173): the player BUYS the haul at the ORIGIN's sell_price and the DEST's
-- market would pay its buy_price — so the best SELF-TRADE for the same haul nets
--     qty × (dest.buy_price − origin.sell_price).
-- A contract pays, priced off the LIVE market_offers rows at generation time (so ECON-SEED feeds it):
--     reward_credits = round(reward_base + qty × (dest.buy_price + reward_premium_per_unit))
-- i.e. the port pays the destination market rate PLUS a per-unit premium PLUS a flat base — the
-- contract beats the same-haul self-trade by exactly (reward_base + qty × premium) > 0, always, and
-- MODESTLY (premiums are ≈15–25% of the route's per-unit market profit on live routes). Grounded in
-- the 0173 price table (origin sell → dest buy; contract profit = reward − qty × origin.sell):
--
--   template                     route          good        qty    market/u  contract/u  base  profit range vs self-trade
--   haul_ore_slag_haven          Slag→Haven     ore         10–30    +4        +5         20    70..170  vs  40..120
--   haul_provisions_haven_slag   Haven→Slag     provisions  10–30    +4        +5         20    70..170  vs  40..120
--   haul_machinery_slag_drift    Slag→Drift     machinery    4–10   +32       +38         30   182..410  vs 128..320
--   haul_luxury_haven_drift      Haven→Drift    luxury       2–6    +50       +60         40   160..400  vs 100..300
--   haul_reagents_haven_drift    Haven→Drift    reagents     5–15   +10       +12         25    85..205  vs  50..150
--   haul_reagents_slag_drift     Slag→Drift     reagents     5–15   +12       +14         25    95..235  vs  60..180
--   haul_luxury_haven_slag       Haven→Slag     luxury       2–6    +30       +36         30   102..246  vs  60..180
--   haul_textiles_haven_drift    Haven→Drift    textiles    20–40    +2        +3         15    75..135  vs  40..80
--   haul_ore_drift_haven         Drift→Haven    ore         10–20    −2        +2         25    45..65   vs market-DEAD
--   haul_textiles_drift_slag     Drift→Slag     textiles    15–30    −4        +1         20    35..50   vs market-DEAD
--
-- The two Drift-origin BACKHAULS are deliberately market-dead routes (0173 makes Drift a pure
-- importer): the port pays ABOVE market to move goods the market won't — contracts create routes raw
-- arbitrage doesn't support, while staying the smallest payouts on the board. Scale check: a full
-- day's board is 2×3 = 6 contracts worth roughly 300–900 credits of profit for the same hauling time
-- the 0173 guaranteed routes (+200/trip, repeatable) already offer — a daily retention garnish, not
-- the dominant faucet. Every qty_max fits the starter frigate: qty_max × unit_volume_m3 ≤ 50 m³
-- (0075's starter base_cargo_capacity_m3) — self-asserted below.
--
-- ── DETERMINISM (the 0041 precedent, reused) ─────────────────────────────────────────────────────
-- `pirate_loot_for_wave` (0041) is deterministic BY CONSTRUCTION — a pure function of its inputs, NO
-- session RNG ("Deterministic (no RNG) so tests are stable"). The generator reuses exactly that
-- technique, extended with a pure hash for the "random" choices: every choice for a slot derives from
--     hashtextextended('haul:'  || day || ':' || port || ':' || slot, 0)   → template (weighted pick)
--     hashtextextended('haulqty:'|| day || ':' || port || ':' || slot, 0)  → quantity (range pick)
-- mapped to a uniform via ((h % 1e6 + 1e6) % 1e6) / 1e6. NO setseed/random(): setseed mutates session
-- RNG state (order-dependent, parallel-unsafe); the pure hash makes the offer SET a pure function of
-- (day, port, slot) — same day, same port ⇒ byte-identical offers, provable by re-derivation.
-- GUC-STABLE by construction: the day is the UTC calendar day `(now() at time zone 'utc')::date`
-- (TimeZone-independent) and it enters the salts via `to_char(day, 'YYYY-MM-DD')` (DateStyle-
-- independent) — no session GUC can shift an offer's identity between the cron, psql, and the proof.
-- IDEMPOTENCY is structural: the natural key unique (origin_location_id, offer_day, slot) +
-- `on conflict do nothing` — a re-run (or a racing double-fire) creates nothing new.
--
-- ── CRON CADENCE (decision): HOURLY ('7 * * * *', jobname 'haul-generate-offers') ────────────────
-- Offers are daily-deterministic, so generation only does work on the first firing after midnight
-- UTC; every other firing is a cheap idempotent no-op — BUT offer durations are 6–12h (sub-day), so
-- the hourly firing is what keeps the bulletin honest: a stale 'offered' row flips 'expired' within
-- ≤1h of its deadline instead of lingering until midnight. Daily would strand dead offers for hours;
-- anything faster than hourly buys nothing (expiry latency is invisible under 1h). Minute 7 keeps it
-- off the top-of-the-hour herd. The cron exists NOW but the generator no-ops while dark (gate-first,
-- return-early, NEVER a raise — the D2/0145 cron-safety lesson): zero live effect until the human
-- flips `haul_contracts_enabled`.
--
-- ── FORWARD NOTES (for HAUL-2/3 + the eventual ACT-HAUL flip script) ─────────────────────────────
--   · PRICE DRIFT: when `world_balance_enabled` lights, the P19 drift multiplier (0136) composes
--     into the PLAYER's actual buy/sell prices at read time but NOT into contract rewards (priced
--     HERE, at generation, from the static market_offers rows — deliberate, see §5). Under drift a
--     contract's EFFECTIVE profit shifts with the origin's live buy cost — HAUL-2's accept/deliver
--     surfaces and the HAUL-3 bulletin must present effective profit, not the static header math.
--   · EMERGENCY DARKENING: a lit→dark flag flip freezes the EXPIRY pass too (the gate returns before
--     it), so any then-stale 'offered' rows persist publicly readable until re-lit. The ACT-HAUL
--     script's rollback section must either run ONE manual expiry pass (the generator's (a) UPDATE,
--     as service role) after darkening, or explicitly accept the frozen bulletin.
--
-- Forward-only: 0001–0175 unedited. No client code in this slice.

-- ── 1) haul_contract_templates — Reference/Config (migration-seeded ONLY; no runtime writer) ─────
-- origin/dest pattern: a fixed port uuid, or NULL = 'any' (origin NULL matches every active port;
-- dest NULL resolves at generation time to the top-paying OTHER active port for the good). The v1
-- seed uses fixed routes only ([D] owner-tunable — the header table); the 'any' capability is schema-
-- supported for later template waves.
create table if not exists public.haul_contract_templates (
  template_id             text    primary key,
  origin_location_id      uuid    references public.locations (id),   -- NULL = any active port
  dest_location_id        uuid    references public.locations (id),   -- NULL = best-paying other port
  good_id                 text    not null references public.trade_goods (good_id),
  qty_min                 integer not null check (qty_min > 0),
  qty_max                 integer not null,
  reward_base             numeric not null check (reward_base >= 0),          -- flat credits on top
  reward_premium_per_unit numeric not null check (reward_premium_per_unit >= 0), -- per-unit margin over dest.buy_price
  duration_seconds        integer not null check (duration_seconds > 0),
  weight                  integer not null check (weight > 0),        -- generation probability weight
  active                  boolean not null default true,
  check (qty_max >= qty_min),
  -- a 0/0 reward template would make the worth-taking invariant a TIE (reward = the self-trade sale)
  -- and could round a sub-0.5 reward to 0 → a lit-cron insert raise on reward_credits > 0. Never.
  check (reward_base + reward_premium_per_unit > 0),
  check (origin_location_id is null or dest_location_id is null
         or origin_location_id <> dest_location_id)
);

alter table public.haul_contract_templates enable row level security;
-- Public read-only (the trade_goods/market_offers posture): NO insert/update/delete policy and NO
-- write grant → clients cannot mutate; migrations/admin are the ONLY writer — no runtime writer
-- exists. The revoke strips the platform's permissive default table grants for the client roles so
-- the grant surface states the truth (RLS already denies writes; belt and braces — proof-pinned).
revoke all on table public.haul_contract_templates from public, anon, authenticated;
create policy "haul_contract_templates_public_read" on public.haul_contract_templates for select using (true);
grant select on public.haul_contract_templates to anon, authenticated;

-- ── 2) Seed the 10 v1 templates (idempotent; converges on re-apply — the 0173/0174 idiom) ────────
insert into public.haul_contract_templates
  (template_id, origin_location_id, dest_location_id, good_id,
   qty_min, qty_max, reward_base, reward_premium_per_unit, duration_seconds, weight) values
  -- the three 0173 guaranteed-route staples (short 6h dailies).
  ('haul_ore_slag_haven',        'b1a00002-0066-4a00-8a00-000000000002', 'b1a00001-0066-4a00-8a00-000000000001', 'ore',          10, 30, 20,  1, 21600, 3),
  ('haul_provisions_haven_slag', 'b1a00001-0066-4a00-8a00-000000000001', 'b1a00002-0066-4a00-8a00-000000000002', 'provisions',   10, 30, 20,  1, 21600, 3),
  ('haul_machinery_slag_drift',  'b1a00002-0066-4a00-8a00-000000000002', 'b1a00003-0066-4a00-8a00-000000000003', 'machinery',     4, 10, 30,  6, 43200, 2),
  -- frontier premium runs (long 12h, high value).
  ('haul_luxury_haven_drift',    'b1a00001-0066-4a00-8a00-000000000001', 'b1a00003-0066-4a00-8a00-000000000003', 'luxury_goods',  2,  6, 40, 10, 43200, 1),
  ('haul_reagents_haven_drift',  'b1a00001-0066-4a00-8a00-000000000001', 'b1a00003-0066-4a00-8a00-000000000003', 'reagents',      5, 15, 25,  2, 43200, 2),
  ('haul_reagents_slag_drift',   'b1a00002-0066-4a00-8a00-000000000002', 'b1a00003-0066-4a00-8a00-000000000003', 'reagents',      5, 15, 25,  2, 43200, 2),
  ('haul_luxury_haven_slag',     'b1a00001-0066-4a00-8a00-000000000001', 'b1a00002-0066-4a00-8a00-000000000002', 'luxury_goods',  2,  6, 30,  6, 43200, 1),
  ('haul_textiles_haven_drift',  'b1a00001-0066-4a00-8a00-000000000001', 'b1a00003-0066-4a00-8a00-000000000003', 'textiles',     20, 40, 15,  1, 21600, 2),
  -- Drift-origin BACKHAULS: market-dead routes the port pays above market to move (header rationale).
  ('haul_ore_drift_haven',       'b1a00003-0066-4a00-8a00-000000000003', 'b1a00001-0066-4a00-8a00-000000000001', 'ore',          10, 20, 25,  4, 28800, 2),
  ('haul_textiles_drift_slag',   'b1a00003-0066-4a00-8a00-000000000003', 'b1a00002-0066-4a00-8a00-000000000002', 'textiles',     15, 30, 20,  5, 28800, 1)
on conflict (template_id) do update
  set origin_location_id      = excluded.origin_location_id,
      dest_location_id        = excluded.dest_location_id,
      good_id                 = excluded.good_id,
      qty_min                 = excluded.qty_min,
      qty_max                 = excluded.qty_max,
      reward_base             = excluded.reward_base,
      reward_premium_per_unit = excluded.reward_premium_per_unit,
      duration_seconds        = excluded.duration_seconds,
      weight                  = excluded.weight,
      active                  = true;

-- ── 3) haul_contracts — the live offer/instance rows (sole writers named in the header) ──────────
create table if not exists public.haul_contracts (
  id                 uuid    primary key default gen_random_uuid(),
  template_id        text    not null references public.haul_contract_templates (template_id),
  origin_location_id uuid    not null references public.locations (id),
  dest_location_id   uuid    not null references public.locations (id),
  good_id            text    not null references public.trade_goods (good_id),
  quantity           integer not null check (quantity > 0),
  reward_credits     numeric not null check (reward_credits > 0),
  status             text    not null default 'offered'
                       check (status in ('offered','accepted','delivered','expired','cancelled')),
  offered_at         timestamptz not null default now(),
  expires_at         timestamptz not null,      -- offer pickup deadline; the ACCEPTED delivery deadline is HAUL-2's business
  offer_day          date    not null,          -- the deterministic generation day (natural-key part)
  slot               integer not null check (slot > 0),
  accepted_by        uuid    references auth.users (id),                        -- player (HAUL-2 writes)
  accepted_ship      uuid    references public.main_ship_instances (main_ship_id),
  accepted_at        timestamptz,
  delivered_at       timestamptz,
  check (origin_location_id <> dest_location_id),
  unique (origin_location_id, offer_day, slot)  -- the idempotency natural key: re-runs create NOTHING new
);
create index if not exists haul_contracts_origin_status_idx on public.haul_contracts (origin_location_id, status);
create index if not exists haul_contracts_status_expires_idx on public.haul_contracts (status, expires_at);

alter table public.haul_contracts enable row level security;
-- Read surfaces (decision): 'offered' rows are per-port PUBLIC BULLETINS — they carry no player data
-- (template/good/qty/reward only) and only ever exist at active ports (the generator's port filter),
-- so a plain status='offered' public read is fine and keeps the policy simple. Rows a player has
-- accepted are OWNER-ONLY (accepted_by = auth.uid() — covers accepted/delivered/cancelled history).
-- Policies OR together: anon sees the bulletin; a player additionally sees their own contracts.
-- NO insert/update/delete policy and NO write grant → clients can never mutate; the generator +
-- future HAUL-2 RPCs (both SECURITY DEFINER) are the only writers.
revoke all on table public.haul_contracts from public, anon, authenticated;   -- strip default grants (see above)
create policy "haul_contracts_offered_public_read" on public.haul_contracts
  for select using (status = 'offered');
create policy "haul_contracts_accepted_owner_read" on public.haul_contracts
  for select using (accepted_by = auth.uid());
grant select on public.haul_contracts to anon, authenticated;

-- ── 4) the dark capability gate + the per-port volume knob (both seeded; 0107/0174 idiom) ────────
insert into public.game_config (key, value, description) values
  ('haul_contracts_enabled', 'false',
   'HAUL (0176): server-authoritative dark gate for the delivery-contracts system. OFF until the '
   'owner flips it (a later ACT-HAUL script, with the HAUL-2 RPCs + HAUL-3 UI). The offer generator '
   'checks this FIRST and returns a no-op envelope (never raises) while false — the hourly cron is '
   'a zero-effect no-op while dark.'),
  ('haul_offers_per_port', '2',
   'HAUL (0176): how many contract offers the generator creates per active port per day (the '
   'deterministic slot count). Owner-tunable; raising it adds slots (existing slots keep their '
   'deterministic identity), lowering it stops minting the higher slots.')
on conflict (key) do nothing;

-- ── 5) haul_generate_offers() — the HAUL-1 deterministic offer generator (service-role internal) ─
-- SECURITY DEFINER, cron-driven. Gate-first (cfg_bool → return early while dark — a cron-safe no-op,
-- NEVER a raise). Then:
--   (a) EXPIRY pass: status 'offered' → 'expired' where expires_at has passed. The predicate is
--       status='offered' ONLY — the generator NEVER touches accepted rows: an accepted contract's
--       delivery deadline belongs to HAUL-2 (design decision, pinned by the proof).
--   (b) GENERATION pass: for each ACTIVE port (status='active' + active docking service + an active
--       market — so a port without an economy never posts contracts) × slot 1..N
--       (N = cfg_num('haul_offers_per_port')), pick a template (hash-weighted), resolve the route,
--       price the reward off the LIVE market_offers rows (header math; the static Reference/Config
--       table — the P19 drift multiplier is a Trade-Market read-time compose, deliberately NOT
--       folded into contract pricing), and insert `on conflict do nothing` on the natural key.
-- Deterministic per (day, port, slot) — the header technique; idempotent within a day by the key.
create or replace function public.haul_generate_offers()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day     date;
  v_n       integer;
  v_port    uuid;
  v_slot    integer;
  v_h       bigint;
  v_u       numeric;
  v_hq      bigint;
  v_span    integer;
  v_qty     integer;
  v_dest    uuid;
  v_buy     numeric;
  v_reward  numeric;
  v_ins     integer;
  v_created integer := 0;
  v_expired integer := 0;
  v_ports   integer := 0;
  r         record;
begin
  -- DARK gate FIRST (the D2/0145 cron-safety lesson): while false, return early — no read, no
  -- write, no raise. Every dark cron firing is an instant no-op.
  if not public.cfg_bool('haul_contracts_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- (a) EXPIRY: only 'offered' rows ever flip; accepted rows are NEVER touched here.
  update public.haul_contracts
     set status = 'expired'
   where status = 'offered'
     and expires_at <= now();
  get diagnostics v_expired = row_count;

  -- (b) GENERATION: deterministic per (day, port, slot). The day is the UTC calendar day —
  -- TimeZone-GUC-independent, so every caller (cron/psql/proof) agrees on the boundary.
  v_day := (now() at time zone 'utc')::date;
  v_n   := greatest(0, coalesce(public.cfg_num('haul_offers_per_port'), 2)::integer);

  for v_port in
    select l.id
      from public.locations l
     where l.status = 'active'
       and exists (select 1 from public.location_services s
                     where s.location_id = l.id and s.service = 'docking' and s.status = 'active')
       and exists (select 1 from public.market_offers o
                     where o.location_id = l.id and o.active)
     order by l.id
  loop
    v_ports := v_ports + 1;
    for v_slot in 1..v_n loop
      v_dest := null; v_buy := null;

      -- deterministic uniform in [0,1) for this (day, port, slot) — the pure-hash technique.
      -- to_char pins the salt's date rendering (DateStyle-GUC-independent).
      v_h := hashtextextended(format('haul:%s:%s:%s', to_char(v_day, 'YYYY-MM-DD'), v_port, v_slot), 0);
      v_u := (((v_h % 1000000) + 1000000) % 1000000)::numeric / 1000000.0;

      -- weighted template pick: cumulative weights in template_id order over the port's pool
      -- (origin fixed to this port, or NULL = 'any'); first bucket past the dart wins.
      select x.* into r from (
        select tt.*,
               sum(tt.weight) over (order by tt.template_id) as w_cum,
               sum(tt.weight) over ()                        as w_total
          from public.haul_contract_templates tt
         where tt.active
           and (tt.origin_location_id is null or tt.origin_location_id = v_port)
      ) x
      where x.w_cum > v_u * x.w_total
      order by x.template_id
      limit 1;
      if not found then continue; end if;   -- no template pool at this port → no offer, no raise

      -- resolve the destination: fixed, or (NULL = 'any') the top-paying OTHER active port.
      if r.dest_location_id is not null then
        v_dest := r.dest_location_id;
      else
        select o.location_id into v_dest
          from public.market_offers o
          join public.locations l2 on l2.id = o.location_id
         where o.good_id = r.good_id and o.active
           and o.location_id <> v_port
           and l2.status = 'active'
           and exists (select 1 from public.location_services s2
                         where s2.location_id = o.location_id
                           and s2.service = 'docking' and s2.status = 'active')
         order by o.buy_price desc, o.location_id
         limit 1;
      end if;
      if v_dest is null or v_dest = v_port then continue; end if;

      -- deterministic quantity in [qty_min, qty_max] (second salt, same technique).
      v_hq   := hashtextextended(format('haulqty:%s:%s:%s', to_char(v_day, 'YYYY-MM-DD'), v_port, v_slot), 0);
      v_span := r.qty_max - r.qty_min + 1;
      v_qty  := r.qty_min + (((v_hq % v_span) + v_span) % v_span)::integer;

      -- price off the LIVE destination market row (header math); no row → no offer, no raise.
      select o.buy_price into v_buy
        from public.market_offers o
       where o.location_id = v_dest and o.good_id = r.good_id and o.active;
      if v_buy is null then continue; end if;
      v_reward := round(r.reward_base + v_qty * (v_buy + r.reward_premium_per_unit));

      -- idempotent mint on the natural key: a re-run/racing double-fire creates NOTHING new.
      insert into public.haul_contracts
        (template_id, origin_location_id, dest_location_id, good_id, quantity, reward_credits,
         status, offered_at, expires_at, offer_day, slot)
      values
        (r.template_id, v_port, v_dest, r.good_id, v_qty, v_reward,
         'offered', now(), now() + make_interval(secs => r.duration_seconds), v_day, v_slot)
      on conflict (origin_location_id, offer_day, slot) do nothing;
      get diagnostics v_ins = row_count;
      v_created := v_created + v_ins;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'day', v_day, 'ports', v_ports,
                            'offers_created', v_created, 'offers_expired', v_expired);
end;
$$;
-- ACL (the 0145 private-writer posture): a server/cron op, not a player command — no public wrapper.
revoke execute on function public.haul_generate_offers() from public, anon, authenticated;
grant  execute on function public.haul_generate_offers() to service_role;

-- ── 6) Cron: hourly, minute 7 (cadence decision in the header) — the 0033/0147 idiom verbatim ────
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'haul-generate-offers';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

select cron.schedule(
  'haul-generate-offers',
  '7 * * * *',
  $$select public.haul_generate_offers();$$
);

-- ── 7) Self-assert: templates seeded + worth taking; generator + cron + flag; dark dry-run = 0 rows ─
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_ids constant text[] := array[
    'haul_ore_slag_haven','haul_provisions_haven_slag','haul_machinery_slag_drift',
    'haul_luxury_haven_drift','haul_reagents_haven_drift','haul_reagents_slag_drift',
    'haul_luxury_haven_slag','haul_textiles_haven_drift','haul_ore_drift_haven',
    'haul_textiles_drift_slag'];
  v_n   integer;
  v_bad integer;
  v_r   jsonb;
begin
  -- 1. Templates: exactly the 10 approved ids, all active, nothing else.
  select count(*) into v_n from public.haul_contract_templates where active;
  if v_n <> 10 then
    raise exception 'HAUL-0 self-assert FAIL: expected 10 active templates, got %', v_n;
  end if;
  select count(*) into v_n from public.haul_contract_templates where template_id <> all(v_ids);
  if v_n <> 0 then
    raise exception 'HAUL-0 self-assert FAIL: % unexpected template row(s)', v_n;
  end if;

  -- 2. Every port has a template pool (origin match), so N offers per port are generatable.
  select count(*) into v_n from unnest(array[c_haven, c_slag, c_drift]) p
    where not exists (select 1 from public.haul_contract_templates t
                        where t.active and (t.origin_location_id is null or t.origin_location_id = p));
  if v_n <> 0 then
    raise exception 'HAUL-0 self-assert FAIL: % starter port(s) have an empty template pool', v_n;
  end if;

  -- 3. Starter-haulable: every template''s qty_max fits the 0075 starter hold (50 m³).
  select count(*) into v_bad
    from public.haul_contract_templates t
    join public.trade_goods g on g.good_id = t.good_id
    where t.qty_max * g.unit_volume_m3 > 50;
  if v_bad <> 0 then
    raise exception 'HAUL-0 self-assert FAIL: % template(s) exceed the 50 m3 starter hold at qty_max', v_bad;
  end if;

  -- 4. WORTH TAKING, recomputed from the LIVE 0173 market rows at BOTH qty endpoints, for every
  --    template: reward(q) = round(base + q×(dest.buy + premium)) must (a) beat the same-haul
  --    self-trade sale (> q×dest.buy — structural: base+premium > 0) and (b) be an absolute profit
  --    after buying the haul at the origin (> q×origin.sell — nontrivial: covers the backhauls).
  select count(*) into v_n
    from public.haul_contract_templates t
    join public.market_offers oo on oo.location_id = t.origin_location_id and oo.good_id = t.good_id and oo.active
    join public.market_offers od on od.location_id = t.dest_location_id   and od.good_id = t.good_id and od.active
    cross join lateral (values (t.qty_min), (t.qty_max)) q(qty);
  if v_n <> 20 then
    raise exception 'HAUL-0 self-assert FAIL: expected 20 (template × endpoint) market joins, got % (missing market row?)', v_n;
  end if;
  select count(*) into v_bad
    from public.haul_contract_templates t
    join public.market_offers oo on oo.location_id = t.origin_location_id and oo.good_id = t.good_id and oo.active
    join public.market_offers od on od.location_id = t.dest_location_id   and od.good_id = t.good_id and od.active
    cross join lateral (values (t.qty_min), (t.qty_max)) q(qty)
    where not ( round(t.reward_base + q.qty * (od.buy_price + t.reward_premium_per_unit)) > q.qty * od.buy_price
            and round(t.reward_base + q.qty * (od.buy_price + t.reward_premium_per_unit)) > q.qty * oo.sell_price );
  if v_bad <> 0 then
    raise exception 'HAUL-0 self-assert FAIL: % (template × endpoint) reward(s) not worth taking vs the live market', v_bad;
  end if;

  -- 5. The generator exists, is service-role-only (never a client RPC).
  if to_regprocedure('public.haul_generate_offers()') is null then
    raise exception 'HAUL-1 self-assert FAIL: haul_generate_offers() missing';
  end if;
  if has_function_privilege('authenticated', 'public.haul_generate_offers()', 'execute')
     or has_function_privilege('anon', 'public.haul_generate_offers()', 'execute') then
    raise exception 'HAUL-1 self-assert FAIL: haul_generate_offers() is client-executable';
  end if;
  if not has_function_privilege('service_role', 'public.haul_generate_offers()', 'execute') then
    raise exception 'HAUL-1 self-assert FAIL: haul_generate_offers() not granted to service_role';
  end if;

  -- 6. Cron scheduled EXACTLY once (guarded like the 0147 unschedule).
  begin
    select count(*) into v_n from cron.job where jobname = 'haul-generate-offers';
    if v_n <> 1 then
      raise exception 'HAUL-1 self-assert FAIL: expected exactly 1 haul-generate-offers cron job, got %', v_n;
    end if;
  exception
    when undefined_table then
      raise notice 'HAUL-1 self-assert: cron.job absent (shadow db) — cron count check skipped';
  end;

  -- 7. Flag DARK + knob seeded.
  if public.cfg_bool('haul_contracts_enabled') then
    raise exception 'HAUL-0 self-assert FAIL: haul_contracts_enabled is not false at seed time';
  end if;
  if coalesce(public.cfg_num('haul_offers_per_port'), -1) <> 2 then
    raise exception 'HAUL-0 self-assert FAIL: haul_offers_per_port not seeded 2';
  end if;

  -- 8. THE CRON-SAFETY PIN: a dry-run of the generator WHILE DARK is a clean no-op envelope —
  --    no raise, zero rows created (the table was just created, so any row = a leak).
  v_r := public.haul_generate_offers();
  if (v_r->>'ok')::boolean is not false or (v_r->>'code') is distinct from 'feature_disabled' then
    raise exception 'HAUL-1 self-assert FAIL: dark dry-run did not no-op cleanly: %', v_r;
  end if;
  select count(*) into v_n from public.haul_contracts;
  if v_n <> 0 then
    raise exception 'HAUL-1 self-assert FAIL: dark dry-run left % contract row(s)', v_n;
  end if;

  raise notice 'HAUL-0/1 self-assert ok: 10 templates seeded (3-port pools, starter-haulable, worth-taking at both endpoints vs live market); generator service-role-only; cron scheduled once; flag dark; dark dry-run = clean no-op, zero rows';
end $$;
