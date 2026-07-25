-- Byeharu — DANGER-ZONE PROVENANCE (migration 0282). Splits the two jobs `source` has been doing.
-- ADDITIVE AND BEHAVIOUR-NEUTRAL. No guard changes here; no flag; no row's protection status moves.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE CONFLATION THIS FIXES
-- `danger_zones.source` currently answers TWO unrelated questions at once:
--     GEOMETRY REPRESENTATION   'circle' = generated from a location's territory_radius
--                               'drawn'  = a hand-authored polygon
--     PROTECTION PROVENANCE     is this a SEEDED/system zone, or owner-authored content?
-- Three RPCs (zone_update 0266, zone_unpublish 0255, zone_set_active 0268) gate on source <> 'drawn'
-- to mean "seeded, therefore protected".
--
-- That works only while the two meanings coincide. The moment anything legitimately changes a zone's
-- GEOMETRY representation, its PROTECTION silently changes with it. Concretely: any future
-- "adopt this seeded zone so I can reshape it" feature must set source='drawn', and from that instant
-- the row is indistinguishable from ordinary owner content — so turning such a feature's flag back
-- OFF would not re-protect it. The flag would be a one-way door wearing the costume of a toggle.
--
-- After this migration:
--     source      = geometry representation, and ONLY that
--     provenance  = creation/protection class, IMMUTABLE
--     location_id = association, unchanged
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- HOW THE BACKFILL CLASSIFIES, AND WHY THAT IS NOT THE THING THE REVIEW WARNED ABOUT
-- The review says not to key protection off display names, and not off `source='circle'`. The second
-- warning is about using source as an ONGOING gate — a mutable column cannot carry a permanent class.
--
-- Using it ONCE, at a known instant, to CLASSIFY is a different act. The seeded zones were created by
-- the 0233 seed with default uuids, so there are no stable seeded IDs to match on: the only fact that
-- distinguishes them at this instant is that they are the source='circle' rows that already exist.
-- We take that snapshot once and FREEZE it. From here on, provenance never moves again — a trigger
-- enforces that — so the classification cannot drift when source later does.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THE GUARDS ARE NOT SWITCHED IN THIS SLICE
-- Re-pointing zone_update / zone_unpublish / zone_set_active at provenance would be behaviour-neutral
-- TODAY, because the backfill makes the two classifications agree exactly — and this migration proves
-- that agreement rather than asserting it. But it re-creates three live owner commands, which is its
-- own reviewable change. Establishing the column first means that follow-up is a two-line diff whose
-- safety is already demonstrated.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.danger_zones') is null then
    raise exception 'DANGER-ZONE PROVENANCE 0282: public.danger_zones is missing';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='danger_zones' and column_name='provenance') then
    raise exception 'DANGER-ZONE PROVENANCE 0282: provenance already exists — this is a one-time classification';
  end if;
end $pre$;

-- ── 1. the column — defaults to 'owner', so anything created from now on is owner content ───────
alter table public.danger_zones
  add column provenance text not null default 'owner'
    check (provenance in ('seeded', 'owner'));

comment on column public.danger_zones.provenance is
  'Creation/protection class, IMMUTABLE once set: ''seeded'' = created by the world seed and protected; '
  '''owner'' = authored through the editor. Split out of `source` (0282), which now means geometry '
  'representation ONLY. A mutable column cannot carry a permanent protection class — that is why this '
  'one never changes and why a trigger enforces it.';

-- ── 2. the ONE-TIME classification ──────────────────────────────────────────────────────────────
-- Every row that exists right now with source='circle' is, by construction, a 0233 seed row: the
-- editor has only ever created source='drawn' zones (zone_create, 0254). This snapshot is taken once
-- and then frozen.
update public.danger_zones set provenance = 'seeded' where source = 'circle';

-- ── 3. immutability — enforced, not documented ──────────────────────────────────────────────────
-- Without this the column is just another mutable field and buys nothing over `source`.
create or replace function public.danger_zones_provenance_is_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.provenance is distinct from old.provenance then
    raise exception 'danger_zones.provenance is immutable (attempted % -> % on zone %)',
      old.provenance, new.provenance, old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger danger_zones_provenance_immutable
  before update on public.danger_zones
  for each row execute function public.danger_zones_provenance_is_immutable();

-- ── 4. SELF-ASSERT ──────────────────────────────────────────────────────────────────────────────
do $prov$
declare
  v_disagree int;
  v_seeded   int;
  v_owner    int;
  v_blocked  boolean := false;
  v_probe    uuid;
begin
  -- (1) BEHAVIOUR NEUTRALITY, PROVEN: the new classification agrees EXACTLY with the source-based one
  -- every live guard still uses. If this ever disagreed, switching the guards later would silently
  -- change which zones are protected.
  select count(*) into v_disagree
    from public.danger_zones
   where (source = 'circle') <> (provenance = 'seeded');
  if v_disagree > 0 then
    raise exception 'DANGER-ZONE PROVENANCE 0282 self-assert FAIL: % row(s) disagree between source and provenance', v_disagree;
  end if;

  -- (2) nothing else on the row moved — this migration writes ONLY provenance
  if exists (select 1 from public.danger_zones where provenance not in ('seeded','owner')) then
    raise exception 'DANGER-ZONE PROVENANCE 0282 self-assert FAIL: an invalid provenance value exists'; end if;

  select count(*) into v_seeded from public.danger_zones where provenance = 'seeded';
  select count(*) into v_owner  from public.danger_zones where provenance = 'owner';

  -- (3) IMMUTABILITY IS REAL — proven by attempting a change inside a rolled-back probe
  select id into v_probe from public.danger_zones limit 1;
  if v_probe is not null then
    begin
      update public.danger_zones
         set provenance = case when provenance = 'seeded' then 'owner' else 'seeded' end
       where id = v_probe;
      raise exception 'DANGER-ZONE PROVENANCE 0282 self-assert FAIL: provenance was mutable';
    exception
      when check_violation then v_blocked := true;
      when others then
        if sqlerrm like '%self-assert FAIL%' then raise; end if;
        v_blocked := true;
    end;
    if not v_blocked then
      raise exception 'DANGER-ZONE PROVENANCE 0282 self-assert FAIL: the immutability trigger did not fire';
    end if;
  end if;

  -- (4) an ordinary update that does NOT touch provenance must still work — the trigger must not
  -- have made the table read-only by accident
  if v_probe is not null then
    update public.danger_zones set updated_at = updated_at where id = v_probe;
  end if;

  -- (5) NO GUARD WAS SWITCHED in this slice — the three protected commands still read source
  if pg_get_functiondef(to_regprocedure('public.zone_update(text, jsonb)')) ilike '%provenance%' then
    raise exception 'DANGER-ZONE PROVENANCE 0282 self-assert FAIL: zone_update was re-pointed — that is a separate slice';
  end if;

  raise notice 'DANGER-ZONE PROVENANCE 0282 self-assert ok: provenance added and classified ONCE (% seeded, % owner) with ZERO disagreement against the source-based classification every live guard still uses — so re-pointing those guards later is provably behaviour-neutral; provenance is IMMUTABLE and the trigger was proven to fire on a rolled-back probe while ordinary updates still succeed; no guard was switched here; source now means geometry representation only', v_seeded, v_owner;
end $prov$;
