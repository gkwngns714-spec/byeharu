-- Byeharu — M4: Base extension. base_add_resources() is the ONLY way resources are
-- added to a base; it is called solely by the Reward system (reward_grant). Base
-- remains the sole writer of base_resources.

create or replace function public.base_add_resources(p_base uuid, p_rewards jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_amount double precision;
begin
  if p_rewards is null then
    return;
  end if;
  for r in select key, value from jsonb_each(p_rewards) loop
    v_amount := (r.value #>> '{}')::double precision;
    if v_amount is null or v_amount = 0 then
      continue;
    end if;
    insert into base_resources (base_id, resource_code, amount)
      values (p_base, r.key, v_amount)
      on conflict (base_id, resource_code)
      do update set amount = base_resources.amount + excluded.amount, updated_at = now();
  end loop;
end;
$$;
