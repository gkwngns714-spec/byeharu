-- Byeharu — TRADE-FLEET-0C: trade_goods commodity catalog (metadata foundation ONLY).
--
-- The smallest self-contained foundation of Trading V1: a pure Reference/Config catalog
-- of tradable commodities — like support_craft_types (Phase 6) and item_types (Phase 3).
-- It adds NOTHING to combat, production, fleets, movement, or the main-ship instance/hull
-- schema. This table is DARK: nothing reads or writes it yet. Its only future consumer is
-- the `ship_cargo_lots.good_id` FK (added in the next TRADE-FLEET-0C step); market
-- reads/writes land in TRADE-MARKET-1.
--
-- DESIGN LAW (TRADE-FLEET-0B §1c, §2.2): capacity is VOLUME-ONLY, canonical m³. Each
-- commodity resolves to a fixed canonical `unit_volume_m3` per its denomination; capacity
-- math is `unit_volume_m3 * qty` only — no mass/density/dual-cap. `base_value` balance is
-- deferred to TRADE-MARKET-1 (seeded 0 for now). No fuel commodity (future-only).
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): trade_goods = Reference/Config (admin/migration writes;
-- public read-only). No client write path — no insert/update/delete policy, no write
-- grant, no SECURITY DEFINER client write RPC.

create table if not exists public.trade_goods (
  good_id        text primary key,
  name           text    not null,
  description    text,
  denomination   text    not null check (denomination in ('bundle','crate','tank','pallet','container')),
  unit_volume_m3 numeric not null check (unit_volume_m3 > 0),   -- = the denomination's fixed canonical m³ (§1c)
  base_value     numeric not null default 0 check (base_value >= 0),
  active         boolean not null default true
);

alter table public.trade_goods enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot
-- mutate. Only migrations / service_role (admin) write.
create policy "trade_goods_public_read" on public.trade_goods for select using (true);
grant select on public.trade_goods to anon, authenticated;

-- ── Seed the six starter commodities (TRADE-FLEET-0B §1c) ────────────────────────
-- unit_volume_m3 EQUALS the denomination's fixed canonical volume:
--   bundle 0.25 · crate 1.0 · tank 2.0 · pallet 4.0 · container 8.0.
-- base_value stays 0 (default) — market balance is a TRADE-MARKET-1 concern.
insert into public.trade_goods
  (good_id, name, description, denomination, unit_volume_m3) values
  ('textiles',     'Textiles',     'Bundled cloth and fibres — light, compact trade staple.',      'bundle',    0.25),
  ('ore',          'Raw Ore',      'Crated unrefined metal ore — the baseline bulk commodity.',    'crate',     1.0),
  ('provisions',   'Provisions',   'Crated food and consumables — steady demand at every port.',   'crate',     1.0),
  ('reagents',     'Reagents',     'Tanked industrial reagents — denser, higher-value cargo.',      'tank',      2.0),
  ('machinery',    'Machinery',    'Palletised mechanical parts — bulky manufactured goods.',       'pallet',    4.0),
  ('luxury_goods', 'Luxury Goods', 'Containerised luxuries — the largest, most valuable haul.',     'container', 8.0)
on conflict (good_id) do nothing;
