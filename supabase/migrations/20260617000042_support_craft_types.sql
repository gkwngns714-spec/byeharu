-- Byeharu — Phase 6: Support Craft Reframe (metadata foundation ONLY).
--
-- Reframes "build ships" toward the future "build support craft / expedition equipment"
-- model WITHOUT touching the proven Expedition Engine. This migration is pure
-- Reference/Config metadata — like item_types (Phase 3). It adds NOTHING to combat,
-- production, fleets, or movement.
--
-- DESIGN LAW: support craft are CAPACITY-LIMITED loadout choices, not unlimited additive
-- power. Each carries a `capacity_cost`; a future main ship will expose a finite
-- `support_capacity`, so you can never bring every best craft at once. This table just
-- DEFINES them — no instances, no expedition attachment, no calculate_expedition_stats,
-- no capacity enforcement yet (those are Phases 7–8+). Current combat is unchanged and
-- still uses unit_types (scout/corvette/frigate); support_craft_types is a separate
-- namespace and is consumed by NOTHING yet.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): support_craft_types = Reference/Config (admin/migration
-- writes; public read-only). No client write path.

create table public.support_craft_types (
  support_craft_type_id text primary key,
  name                  text not null,
  role                  text not null,
  capacity_cost         integer not null check (capacity_cost > 0),
  stackable             boolean not null default true,
  buildable             boolean not null default true,
  activity_tags         jsonb not null default '[]'::jsonb,
  tradeoffs_json        jsonb not null default '{}'::jsonb,
  base_stats_json       jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now()
);

alter table public.support_craft_types enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot
-- mutate. Only migrations / service_role (admin) write.
create policy "support_craft_types_public_read" on public.support_craft_types for select using (true);
grant select on public.support_craft_types to anon, authenticated;

-- ── Seed the 8 starter support craft (capacity-limited; tradeoffs are real) ──────
-- base_stats_json is ILLUSTRATIVE only — nothing consumes it until
-- calculate_expedition_stats (Phase 8). Roles & capacity costs are the contract.
insert into public.support_craft_types
  (support_craft_type_id, name, role, capacity_cost, activity_tags, tradeoffs_json, base_stats_json) values
  ('scout_escort', 'Scout Escort', 'light_escort', 1,
   '["pirate_hunt","exploration","trade_run"]'::jsonb,
   '{"pros":["cheap protection","flexible"],"cons":["low power"]}'::jsonb,
   '{"attack":2,"defense":3,"cargo":0}'::jsonb),

  ('missile_boat', 'Missile Boat', 'combat_damage', 3,
   '["pirate_hunt"]'::jsonb,
   '{"pros":["strong combat"],"cons":["no cargo","slows expedition (later)"]}'::jsonb,
   '{"attack":12,"defense":2,"cargo":0}'::jsonb),

  ('repair_drone', 'Repair Drone', 'repair', 2,
   '["pirate_hunt","mining"]'::jsonb,
   '{"pros":["survivability/repair"],"cons":["no attack","consumes capacity"]}'::jsonb,
   '{"attack":0,"defense":2,"repair":5}'::jsonb),

  ('cargo_drone', 'Cargo Drone', 'cargo', 2,
   '["trade_run","mining","pirate_hunt"]'::jsonb,
   '{"pros":["more loot/cargo capacity"],"cons":["fragile","increases pirate attention (later)"]}'::jsonb,
   '{"attack":0,"defense":1,"cargo":20}'::jsonb),

  ('survey_drone', 'Survey Drone', 'scanning', 2,
   '["exploration","trade_run","mining"]'::jsonb,
   '{"pros":["intel/scanning"],"cons":["weak combat value"]}'::jsonb,
   '{"attack":1,"defense":1,"scan":8}'::jsonb),

  ('decoy_drone', 'Decoy Drone', 'retreat_safety', 1,
   '["pirate_hunt","exploration","trade_run","mining"]'::jsonb,
   '{"pros":["safer retreat on risky expeditions"],"cons":["likely consumed (later)","no direct profit"]}'::jsonb,
   '{"attack":0,"defense":1,"evasion":6}'::jsonb),

  ('mining_drone', 'Mining Drone', 'extraction', 2,
   '["mining"]'::jsonb,
   '{"pros":["resource extraction"],"cons":["weak combat","uses capacity"]}'::jsonb,
   '{"attack":0,"defense":1,"mining":8}'::jsonb),

  ('trade_barge', 'Trade Barge', 'heavy_cargo', 5,
   '["trade_run"]'::jsonb,
   '{"pros":["heavy cargo throughput"],"cons":["slow","high pirate attention (later)","needs escorts"]}'::jsonb,
   '{"attack":0,"defense":3,"cargo":80,"speed":0.6}'::jsonb)
on conflict (support_craft_type_id) do nothing;
