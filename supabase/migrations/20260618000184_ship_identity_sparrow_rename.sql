-- Byeharu — SHIP-IDENTITY: ships stop being named after the game ("what is byeharu? is that a
-- ship name?? WTF" — owner). Every commissioned ship was literally named 'Byeharu' (the 0043
-- column default, and the explicit literal in the commission build core since 0072).
--
-- ── DESIGN DECISIONS (owner-directed: EVE-style class names, personalizable) ─────────────────────
-- 1) HULL CLASSES get evocative names ("like EVE — Scorpion, Golem"). The starter frigate's
--    display name becomes 'Sparrow-class Frigate' — small, quick, starter-register. Future
--    SHIPYARD tier-1 hulls follow the same register (e.g. hauler → "Mule", corvette → "Talon";
--    not seeded yet — noted here so the register stays coherent when they land).
-- 2) DEFAULT SHIP NAMES = the class name + a per-player roman numeral, EVE-flavor: first ship
--    'Sparrow', second 'Sparrow II', third 'Sparrow III' — computed at commission time in the
--    shared build core ('Sparrow' is correct there because build hardcodes hull_type_id =
--    'starter_frigate'; when multi-hull commissioning lands, the class name should ride the hull
--    row). Race-safe WITHOUT a new lock: EVERY caller of port_entry_commission_build already
--    holds the per-player commission advisory lock (port_entry_commission_writer 0080 §B;
--    commission_additional_main_ship 0091) before build runs, so count-then-insert cannot
--    interleave for one player. Roman numerals via to_char(n, 'FMRN') (built-in).
-- 3) COLUMN DEFAULT becomes 'Sparrow' — a safety net only (no code path rides it except the
--    legacy service_role/CI helper ensure_main_ship_for_player, 0078 head). Never the game's name.
-- 4) BACKFILL renames every existing ship still carrying the old default ('Byeharu') to its
--    per-player class+numeral by created_at order. Player-visible rename — sanctioned by the
--    owner's explicit complaint; the ordinal counts ALL of the player's ships (custom-renamed
--    ships keep their name but still occupy their ordinal, so the numeral mirrors commission
--    order, exactly what the new build core would have produced).
-- 5) RENAME becomes PLAYER-REACHABLE ("I should be able to rename them, personalize them").
--    The 0043 rename_main_ship(p_player, p_name) is service_role-only AND single-ship era (its
--    `where player_id = …` would rename ALL of a multi-ship player's ships), so it is left as the
--    untouched server-side legacy and a NEW authenticated, ship-addressed thin wrapper is added:
--    rename_main_ship_self(p_name, p_main_ship_id default null) — auth.uid()-scoped, resolves via
--    the shared mainship_resolve_owned_ship (0081: explicit-id ownership assert / sole-ship shim),
--    validates exactly like 0043 (btrim, non-empty, ≤ 40), returns the jsonb ok/reason envelope.
-- 6) NOTHING else is redefined: commission_first_main_ship (0072 head), the writer (0080 head),
--    and commission_additional_main_ship (0091 head) all delegate the insert to build — one
--    re-creation fixes both the first-ship and additional-ship paths. ACLs are preserved by
--    `create or replace` (build keeps its 0080 service_role-only grant).

-- ── A. Hull class display name → the evocative register (reference/config row update). ──────────
update public.main_ship_hull_types
   set name = 'Sparrow-class Frigate'
 where hull_type_id = 'starter_frigate';

-- ── B. Column default → 'Sparrow' (safety net; no insert path should ride it with a real name). ──
alter table public.main_ship_instances alter column name set default 'Sparrow';

-- ── C. port_entry_commission_build — copied VERBATIM from its TRUE head, migration 0080
--      (grep-verified sole later definition); the ONLY change is the marked NAME hunk. ───────────
create or replace function public.port_entry_commission_build(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_haven  constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  v_ship   uuid;
  v_zone   uuid;
  v_sector uuid;
  v_base   uuid;
  v_fleet  uuid;
begin
  -- Insert the ship DIRECTLY in canonical at_location shape (status='stationary',
  -- spatial_state='at_location', x/y NULL) so there is never a committed intermediate bare
  -- home/legacy_home row. No on-conflict: the CALLER already serialized + checked existence/cap.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, space_x, space_y,
     hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id,
         -- [0184 NAME HUNK — the ONLY change vs the 0080 head] EVE-style default: the class name
         -- ('Sparrow' — correct here because this function hardcodes the starter_frigate hull),
         -- plus a per-player roman numeral from the SECOND ship on ('Sparrow', 'Sparrow II', …).
         -- Safe: every caller holds the per-player commission advisory lock before build.
         'Sparrow' || (select case when count(*) = 0 then ''
                                   else ' ' || to_char(count(*) + 1, 'FMRN') end
                         from public.main_ship_instances m where m.player_id = p_player),
         'stationary', 'at_location', null, null,
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3, h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from public.main_ship_hull_types h
    where h.hull_type_id = 'starter_frigate'
  returning main_ship_id into v_ship;

  if v_ship is null then
    return jsonb_build_object('created', false);     -- hull row missing / nothing inserted
  end if;

  -- ── Phase B: lock the Haven Reach target hierarchy in the canonical order (sector → zone → location →
  --    anchor → docking service, FOR SHARE — conflicts with a status disable/retire) and REVALIDATE legality
  --    through the single canonical rule AFTER the locks are held, immediately before the fleet/presence write.
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id
    where l.id = c_haven;
  if v_zone is null then
    raise exception 'port_entry_commission: Haven Reach location not found';
  end if;
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = c_haven  for share;
  perform 1 from public.space_anchors     where location_id = c_haven and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = c_haven and service = 'docking' and status = 'active' for share;

  if (public.mainship_space_location_target_legal(c_haven)->>'ok')::boolean is not true then
    raise exception 'port_entry_commission: Haven Reach is not dockable';   -- rolls back the ship insert (atomic)
  end if;

  -- exactly ONE present/location fleet at Haven (origin_base_id = the player's base if one exists, else NULL —
  -- NOT a home-port assignment; current_base_id stays NULL, matching a docked OSN fleet).
  select id into v_base from public.bases where player_id = p_player and status = 'active' order by created_at limit 1;
  v_fleet := gen_random_uuid();
  insert into public.fleets
    (id, player_id, origin_base_id, status, location_mode, current_base_id,
     current_location_id, current_zone_id, current_sector_id, main_ship_id)
  values (v_fleet, p_player, v_base, 'present', 'location', null,
          c_haven, v_zone, v_sector, v_ship);

  -- exactly ONE active presence through the established presence path (activity 'none', like the dock writer).
  perform public.presence_create(p_player, v_fleet, v_sector, v_zone, c_haven, 'none');

  -- final coherence gate: the ship MUST now be canonical at_location, else abort the whole transaction.
  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'port_entry_commission: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('created', true, 'main_ship_id', v_ship, 'location_id', c_haven);
end;
$$;

-- ── D. Backfill: rename every ship still carrying the old default. The ordinal is the ship's
--      commission order among ALL of that player's ships (created_at, id tiebreak), so a player
--      whose FIRST ship was custom-renamed still gets 'Sparrow II' for their second — the numeral
--      mirrors commission order, exactly what the new build core would have produced. ────────────
with seq as (
  select main_ship_id,
         row_number() over (partition by player_id order by created_at, main_ship_id) as n
    from public.main_ship_instances
)
update public.main_ship_instances s
   set name = 'Sparrow' || case when seq.n = 1 then '' else ' ' || to_char(seq.n, 'FMRN') end,
       updated_at = now()
  from seq
 where seq.main_ship_id = s.main_ship_id
   and s.name = 'Byeharu';

-- ── E. rename_main_ship_self — the player-reachable rename (thin wrapper; §2.5 ship addressing). ─
--      Owner-scoped (auth.uid(); no player input), ship-addressed via the shared resolver (0081:
--      explicit id → ownership assert; null → sole-ship shim; ambiguous → fail closed), validated
--      exactly like the 0043 server-side rename (btrim, non-empty, ≤ 40 chars). jsonb ok/reason
--      envelope (the commission/trade RPC idiom) — never a raw raise for a player-caused input.
create or replace function public.rename_main_ship_self(p_name text, p_main_ship_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_clean  text;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  v_clean := btrim(coalesce(p_name, ''));
  if length(v_clean) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'name_empty');
  end if;
  if length(v_clean) > 40 then
    return jsonb_build_object('ok', false, 'reason', 'name_too_long');
  end if;

  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');   -- not owned / ambiguous / none
  end if;

  update public.main_ship_instances
     set name = v_clean, updated_at = now()
   where main_ship_id = v_ship;

  return jsonb_build_object('ok', true, 'main_ship_id', v_ship, 'name', v_clean);
end;
$$;
-- ACL: new functions default-grant to PUBLIC on create → explicit revoke/grant (the 0072 pattern).
revoke execute on function public.rename_main_ship_self(text, uuid) from public, anon;
grant  execute on function public.rename_main_ship_self(text, uuid) to authenticated;

-- ── F. Self-asserts (fail the migration loudly rather than ship a half-fix). ─────────────────────
do $$
declare
  v_default text;
  v_hull    text;
  v_bad     text;
begin
  -- 1) No ship named after the game remains.
  if exists (select 1 from public.main_ship_instances where name = 'Byeharu') then
    raise exception 'ship-identity 0184: a ship named ''Byeharu'' survived the backfill';
  end if;

  -- 2) The hull class carries the evocative register.
  select name into v_hull from public.main_ship_hull_types where hull_type_id = 'starter_frigate';
  if v_hull is distinct from 'Sparrow-class Frigate' then
    raise exception 'ship-identity 0184: starter hull display name is %', coalesce(v_hull, '<missing>');
  end if;

  -- 3) The column default is the 'Sparrow' safety net (never the game''s name).
  select column_default into v_default
    from information_schema.columns
    where table_schema = 'public' and table_name = 'main_ship_instances' and column_name = 'name';
  if v_default is distinct from '''Sparrow''::text' then
    raise exception 'ship-identity 0184: unexpected name column default %', coalesce(v_default, '<null>');
  end if;

  -- 4) The re-created build core names by class+numeral and NO commission-surface function
  --    (build/writer/first/additional/ensure) still carries the old literal.
  if position('''Sparrow''' in pg_get_functiondef('public.port_entry_commission_build(uuid)'::regprocedure)) = 0 then
    raise exception 'ship-identity 0184: build core lacks the Sparrow naming expression';
  end if;
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('port_entry_commission_build', 'port_entry_commission_writer',
                        'commission_first_main_ship', 'commission_additional_main_ship',
                        'ensure_main_ship_for_player')
      and pg_get_functiondef(p.oid) like '%''Byeharu''%';
  if v_bad is not null then
    raise exception 'ship-identity 0184: commission surface still names ships ''Byeharu'': %', v_bad;
  end if;

  -- 5) The player-reachable rename exists and ONLY authenticated may execute it.
  if not has_function_privilege('authenticated', 'public.rename_main_ship_self(text, uuid)', 'execute') then
    raise exception 'ship-identity 0184: rename_main_ship_self is not client-callable';
  end if;
  if has_function_privilege('anon', 'public.rename_main_ship_self(text, uuid)', 'execute') then
    raise exception 'ship-identity 0184: rename_main_ship_self must not be anon-callable';
  end if;
end;
$$;
