-- Byeharu — M4: Fleet extensions for combat. Combat reads fleet stats and applies
-- losses ONLY through these functions (Fleet stays the sole writer of fleet_units).

-- Aggregate combat stats for a fleet (read-only). Combat uses this instead of
-- touching fleet_units directly.
create or replace function public.fleet_combat_stats(p_fleet uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'attack',  coalesce(sum(ut.attack      * fu.quantity), 0),
    'defense', coalesce(sum(ut.defense     * fu.quantity), 0),
    'hull',    coalesce(sum(ut.hull        * fu.quantity), 0),
    'power',   coalesce(sum(ut.power_score * fu.quantity), 0)
  )
  from fleet_units fu
  join unit_types ut on ut.id = fu.unit_type_id
  where fu.fleet_id = p_fleet and fu.quantity > 0;
$$;

-- Apply proportional losses to every unit type in the fleet. Returns the losses
-- as jsonb { unit_type_id: lost_qty, ... } for logging. Ratio is clamped to [0,1].
create or replace function public.fleet_apply_losses(p_fleet uuid, p_loss_ratio double precision)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ratio  double precision := least(greatest(coalesce(p_loss_ratio, 0), 0), 1);
  u        record;
  v_lost   integer;
  v_losses jsonb := '{}'::jsonb;
begin
  for u in select * from fleet_units where fleet_id = p_fleet and quantity > 0 for update loop
    v_lost := floor(u.quantity * v_ratio)::integer;
    -- guarantee progress at full wipe so a doomed fleet can't survive on rounding
    if v_ratio >= 1 then
      v_lost := u.quantity;
    end if;
    if v_lost > 0 then
      update fleet_units set quantity = quantity - v_lost, updated_at = now() where id = u.id;
      v_losses := v_losses || jsonb_build_object(u.unit_type_id, v_lost);
    end if;
  end loop;
  return v_losses;
end;
$$;
