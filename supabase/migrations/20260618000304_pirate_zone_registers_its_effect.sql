-- 0304 — A PIRATE ZONE REGISTERS ITS OWN TYPED EFFECT, SO IT CAN ACTUALLY AMBUSH.
--
-- THE GAP, found while proving 0303 and then confirmed against production source and data:
--
-- 0276 cut ambush planning over to the typed-zone planner, and 0300 lit
-- typed_zone_pirate_intercept_runtime_enabled (verified true in production today, along with the
-- other four typed-zone runtime flags). On that path, pirate_intercept_plan_leg is deliberately
-- FAIL CLOSED — 0301's own words: "a zone carrying no pirate_intercept effect row is simply not
-- planned ... a planner that cannot answer leaves the leg alone rather than falling back and hiding
-- the fault." The zone hit is found, then `if v_risk is null then continue; end if` skips it.
--
-- 0273 created zone_effect_pirate_intercept and BACKFILLED one row per pirate zone that existed at
-- that moment. Production shows exactly that: Blackden, Reaver and Snare all carry effect rows, all
-- created 2026-07-25T12:09:44Z by the backfill. That is why the owner's live ambushes still fire.
--
-- But NOTHING creates that row for a pirate zone made AFTER 0273. Both live creation paths insert
-- into danger_zones and stop:
--     0233:1464  pirate_zone_create  (legacy, service-role only)
--     0254:352   zone_create         (the World Editor's owner-gated publish verb)
-- Only the owner authoring RPC (0277) ever writes an effect row, and only when someone deliberately
-- edits overrides for a zone.
--
-- So: every pirate zone drawn since 0273 is INERT. It renders on the map, it is "active", players
-- can fly through it, and it can never ambush anyone. The World Editor's zone-drawing feature
-- produces decoration. This is also why the danger-combat proof has been red since 2026-07-19 — it
-- draws a fresh zone and then waits for an ambush that the fail-closed planner will never schedule.
--
-- ── THE FIX, AND WHY IT IS A TRIGGER RATHER THAN TWO PATCHED RPCs ───────────────────────────────────
-- Patching pirate_zone_create and zone_create means the same rule written twice, and a third creation
-- path added later silently reopens the hole — exactly the duplication that produced this class of
-- bug. One trigger on danger_zones is the single authority: every present and future writer inherits
-- it, and it mirrors 0273's backfill semantics precisely (bare row, ALL overrides NULL ⇒ the global
-- risk curve, byte-for-byte the behaviour of a zone that was never typed).
--
-- It also fires on a kind CONVERSION (0285 can turn a zone into 'pirate'), because a zone that
-- becomes a pirate zone needs its effect row for the same reason a new one does.
--
-- What this does NOT do: it sets no override, changes no risk, and touches no existing row. A zone
-- that already has an effect row is left exactly as it is (ON CONFLICT DO NOTHING). Ambush RISK for
-- newly created zones therefore equals the global curve — the same answer the pre-0276 legacy path
-- gave them. Tuning a zone remains the owner's deliberate act through 0277.
--
-- ── ROLLBACK ────────────────────────────────────────────────────────────────────────────────────────
-- drop trigger danger_zones_register_pirate_effect on public.danger_zones;
-- drop function public.danger_zone_register_pirate_effect();
-- The backfilled rows this migration adds are behaviour-neutral; deleting them would re-inert those
-- zones, so rollback deliberately leaves them.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- ══════════ PRECONDITIONS ═══════════════════════════════════════════════════════════════════════════
do $pre$
begin
  if to_regclass('public.zone_effect_pirate_intercept') is null then
    raise exception '0304: zone_effect_pirate_intercept is missing — 0273 must be deployed first';
  end if;
  if to_regclass('public.danger_zones') is null then
    raise exception '0304: danger_zones is missing';
  end if;
  -- The fail-closed planner is what makes a missing row fatal. If that branch ever goes away this
  -- migration is still harmless, but the assertion records WHY it exists.
  if position('typed_zone_pirate_intercept_runtime_enabled' in
        coalesce((select prosrc from pg_proc
                   where oid = 'public.pirate_intercept_plan_leg(uuid)'::regprocedure), '')) = 0 then
    raise exception '0304: pirate_intercept_plan_leg does not consult the typed-zone runtime flag — re-derive this fix against the current planner';
  end if;
end
$pre$;

-- ══════════ 1. THE SINGLE AUTHORITY ═════════════════════════════════════════════════════════════════
create or replace function public.danger_zone_register_pirate_effect()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Bare row, every override NULL: "this zone carries the pirate effect", nothing more. Identical in
  -- shape and meaning to 0273's backfill, so a newly drawn zone behaves exactly like a seeded one.
  if new.zone_kind = 'pirate' then
    insert into public.zone_effect_pirate_intercept (zone_id)
    values (new.id)
    on conflict (zone_id) do nothing;
  end if;
  return null;  -- AFTER trigger; the return value is ignored
end;
$$;

comment on function public.danger_zone_register_pirate_effect() is
  'AFTER INSERT/UPDATE-OF-zone_kind on danger_zones: guarantees a pirate zone owns a '
  'zone_effect_pirate_intercept row. The typed planner (0276+) is fail-closed, so a pirate zone '
  'without that row can never be planned for an ambush and is inert. Added by 0304 after every zone '
  'created since 0273 was found to be inert. Overrides are left NULL = the global risk curve; tuning '
  'stays the owner deliberate act via 0277.';

drop trigger if exists danger_zones_register_pirate_effect on public.danger_zones;
create trigger danger_zones_register_pirate_effect
  after insert or update of zone_kind on public.danger_zones
  for each row
  execute function public.danger_zone_register_pirate_effect();

-- ══════════ 2. BACKFILL THE ZONES THE GAP ALREADY STRANDED ══════════════════════════════════════════
-- Same statement 0273 ran, run again for anything created since. Behaviour-neutral and idempotent.
insert into public.zone_effect_pirate_intercept (zone_id)
  select z.id from public.danger_zones z where z.zone_kind = 'pirate'
on conflict (zone_id) do nothing;

-- ══════════ 3. SELF-ASSERT — the rule holds, and it holds for NEW rows, proven by exercising it ═════
do $post$
declare
  v_missing int;
  v_zone    uuid;
  v_has     int;
begin
  -- (a) no pirate zone is left without its effect row.
  select count(*) into v_missing
    from public.danger_zones z
    left join public.zone_effect_pirate_intercept e on e.zone_id = z.id
   where z.zone_kind = 'pirate' and e.zone_id is null;
  if v_missing <> 0 then
    raise exception '0304 FAIL: % pirate zone(s) still carry no effect row after the backfill', v_missing;
  end if;

  -- (b) the trigger exists and is enabled on the right events.
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.danger_zones'::regclass
       and t.tgname = 'danger_zones_register_pirate_effect'
       and t.tgenabled <> 'D') then
    raise exception '0304 FAIL: the registration trigger is absent or disabled';
  end if;

  -- (c) NON-VACUOUS: actually insert a pirate zone and prove the row appears, then remove both.
  --     A trigger that exists but does not fire is the failure this catches. Rolled back in-place so
  --     the migration leaves no zone behind.
  -- source='drawn' with a NULL location is explicitly legal (0233's coherence check only binds
  -- 'circle' zones to a location), so the probe needs no fixture location and cannot collide with one.
  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, status)
  values ('0304 self-assert probe', 'pirate', 'drawn', null,
          ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 0), 'inactive')
  returning id into v_zone;

  select count(*) into v_has from public.zone_effect_pirate_intercept where zone_id = v_zone;
  if v_has <> 1 then
    raise exception '0304 FAIL: inserting a pirate zone did NOT register its effect row — the trigger does not fire';
  end if;

  delete from public.danger_zones where id = v_zone;   -- cascades the effect row
  if exists (select 1 from public.zone_effect_pirate_intercept where zone_id = v_zone) then
    raise exception '0304 FAIL: the probe effect row outlived its zone';
  end if;

  raise notice '0304 self-assert ok: every pirate zone owns an effect row, the trigger is live, and a freshly inserted pirate zone provably registers one (probe created and removed)';
end
$post$;

commit;
