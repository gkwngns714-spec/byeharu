-- Byeharu — M7: ship metal costs + training-queue config (Reference/Config).
--
-- Adds a per-unit metal cost to the catalog (co-located with build_time_seconds) and
-- the global training tunables. unit_types is Reference data (public read, admin/
-- migration write only) — adding a column keeps cost where the unit is defined.

alter table public.unit_types
  add column if not exists metal_cost integer not null default 0 check (metal_cost >= 0);

-- Starter costs (∝ unit power; a hunt yields ~30–100 metal, so a frigate ≈ several hunts).
update public.unit_types set metal_cost = 50  where id = 'scout';
update public.unit_types set metal_cost = 150 where id = 'corvette';
update public.unit_types set metal_cost = 400 where id = 'frigate';

-- Training tunables (build time uses the existing unit_types.build_time_seconds).
insert into public.game_config (key, value, description) values
  ('build_time_scale',  '1.0', 'global multiplier on ship training time (× unit_types.build_time_seconds × qty)'),
  ('min_build_seconds', '5',   'floor on a training order''s duration'),
  ('max_build_orders',  '5',   'max concurrent queued training orders per player')
on conflict (key) do nothing;
