-- Byeharu — PIRATE INTERCEPT + DANGER ZONES (prototype slice; DARK by default).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE FEATURE (owner's words): "pirate territory intercept + waypoint routing. I want there to be a
-- danger zone, and ships with lower stats should be aware of this and go around the spot. When
-- entering a zone there is always a risk of pirate spawn and being attacked." Owner follow-up:
-- danger zones must be ARBITRARY SHAPES (owner-drawable, "slime-like"), not just circles.
--
-- ONE FLAG GOVERNS THE WHOLE SLICE: pirate_intercept_enabled (seeded false below). Every new server
-- arm below gates on it FIRST — reject/no-op before any read — so while dark this migration is
-- ADDITIVE DATA + INERT CODE ONLY: zero behavior change to any existing table, function, or cron.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- GEOMETRY CHOICE: PostGIS (path A over hand-rolled ray-casting), because the zone shape requirement
-- is "arbitrary polygon, owner-drawable, slime-like blobs" — PostGIS gives exact ST_Intersects /
-- ST_Length / ST_Buffer / ST_MakePolygon for ANY polygon (convex, concave, with holes) essentially
-- for free, where hand-rolled plpgsql ray-casting would be slower AND a second geometry engine to
-- maintain and get subtly wrong. Confirmed available in this project's pg_available_extensions
-- (not yet installed) — installed here via the SAME idiom every existing migration uses for pg_cron
-- (`create extension if not exists <ext>;`, no schema qualifier — 0011/0037/0050/0058/0100/0105/
-- 0147/0176/0177). Geometries carry NO SRID (this is a flat game-world grid, not a geographic CRS) —
-- ST_Length/ST_Intersects/ST_Distance operate in plain Cartesian world-units, matching osn_distance.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ZONE MODEL: `danger_zones` — an INDEPENDENT geometry table, decoupled from `locations`:
--   • source='circle' — ONE row auto-seeded per existing pirate_hunt/pirate_den location that carries
--     a territory_radius (0217/0220): boundary = ST_Buffer(location point, radius, 32 segments). This
--     is the "keep the circle as one possible zone source" requirement — every existing hostile site
--     gets an equivalent polygon with ZERO behavior change to locations.territory_radius itself (that
--     column, get_world_map, fleet_in_territory, and the client territoryAt ring are all UNTOUCHED —
--     this migration adds a PARALLEL polygon read, it does not re-create or repoint any of them).
--   • source='drawn' — an owner-authored polygon (pirate_zone_create below), EITHER attached to an
--     existing active pirate_hunt location (location_id set — the shape REPLACES/supplements that
--     site's circle for intercept purposes; the circle row and the drawn row both exist and are both
--     checked, a documented minor overlap-in-rendering seam) OR fully standalone (location_id NULL —
--     "paint danger anywhere, any shape", satisfied at the DATA MODEL level unconditionally).
--   STUB, NAMED EXPLICITLY: presence/combat are LOCATION-centric (a real locations row with zone_id/
--   sector_id is required to open an encounter). A standalone zone (location_id NULL) therefore
--   cannot open a live combat encounter — see pirate_intercept_evaluate_leg's standalone branch. The
--   crossing WARNING and the intercept ROLL/LOG still fire for a standalone zone (pure geometry, no
--   location needed); only the "spawn a fight" step is stubbed there, and the fleet is still forced
--   to a stop (fleet_set_in_space) so a standalone hit is not silently a no-op. Auto-minting a new
--   locations row for a from-scratch drawn zone (so it too gets a live encounter) is the follow-up.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- INTERCEPT GEOMETRY: a movement LEG is the segment (origin_x,origin_y)→(target_x,target_y). A leg
-- "crosses" a zone iff ST_Intersects(zone.boundary, leg_linestring). Exposure (how much of the trip
-- cuts through the zone, used to scale risk) = ST_Length(ST_Intersection(zone.boundary, leg)) /
-- ST_Length(leg) — a fraction in [0,1], floored at a configurable minimum so even a tangential clip
-- carries nonzero risk. The "ambush point" (where the fleet is pulled out of transit) is
-- ST_ClosestPoint(leg, ST_Centroid(zone.boundary)) — the point on the fleet's own path nearest the
-- zone's core, a single deterministic point regardless of how many times a concave zone's boundary
-- the leg crosses.
--
-- RISK FORMULA (composes the group's ALREADY-COMPUTED expedition stats — no new stat source):
--   combined = totals.combat_power + totals.survival  (the D0 group-stats authority, 0166 — the
--     closest existing analogs to the owner's "hp/shield/power": this codebase's per-ship adapter
--     (0122, latest head 0205) does not expose a literal "shield" or "power" field at the group-stats
--     level — combat_power is the offense fold, survival is the defense/hp-derived fold. Documented
--     substitution, not a guess: grep-verified, see the file-header note on calculate_expedition_stats.)
--   risk = clamp(base_risk * stat_reference / (stat_reference + combined), min_risk, max_risk)
--          * clamp(exposure_fraction, exposure_floor, 1.0)
--   Lower combined stats → risk climbs toward base_risk (weak fleets can't cross safely); higher
--   combined stats asymptotically drive risk toward (but never below) min_risk (strong fleets cross
--   MORE safely, never with absolute certainty — "there is ALWAYS a risk", the owner's own words).
--   "Tougher spawn" is NOT a second knob: the intercepted zone's linked pirate_hunt location carries
--   its OWN base_difficulty/reward_tier, which the EXISTING process_combat_ticks danger scaling
--   already reads — crossing near a harder territory is already a harder fight, by the existing data
--   model, with zero new toughness code.
--
-- COMBAT REUSE (the "don't fork combat" law): on a hit, the ambush freezes a group_sortie_members
-- manifest for the fleet's LIVE group members — the EXACT insert shape send_ship_group_hunt (0168)
-- uses to hand a unified group fleet's roster to combat — then calls the frozen presence_create,
-- which calls the frozen activity_start, which calls the frozen combat_create_encounter, which (now
-- that a manifest exists for this fleet_id) routes to the frozen combat_create_group_encounter. NONE
-- of those four functions are re-created here. This mirrors the manifest-wins law verbatim: routing
-- and stats key on the frozen manifest snapshot, never on live membership.
--
-- WAYPOINT ROUTING: a `fleet_route_legs` queue (NOT a widened fleet_movements — the spine's
-- one-active-movement-per-fleet unique index, 0007, means only ONE leg can ever be 'moving'; a queue
-- of the REMAINING legs is the simplest model that composes with process_fleet_movements settling
-- one leg at a time). command_ship_group_go_route (client RPC) composes the EXISTING
-- command_ship_group_go for leg 1 (zero duplicated origin-resolution logic — bootstrap/redirect/
-- space/port/anchor stays ONE authority) and queues the rest. A NEW, SEPARATE cron function
-- (process_pirate_route_legs) advances the queue — process_fleet_movements (the hottest live cron in
-- the game, per 0206's own CRON-GUARD post-mortem) is NOT touched, NOT re-created, and carries zero
-- new code; the queue advance runs as its OWN pg_cron job so a bug in this prototype's queue logic
-- can never wedge the real 30s settle loop for every player.
--
-- DARK-FIRST PROOF: pirate_intercept_evaluate_leg's FIRST statement is the flag gate (before any
-- table read) and command_ship_group_go's one new hunk is a single `perform` of that leaf placed
-- AFTER the existing head's writes — while dark, the leaf immediately returns {hit:false,
-- reason:'dark'} and touches NOTHING, so the mover's pre-existing behavior (every read/write above
-- the hunk) is byte-identical to the 0219 head. The in-migration self-assert at the bottom calls the
-- leaf with a random movement id while the flag is (freshly seeded) false and pins the no-op answer.
--
-- SCOPE / STUBS (explicit, for the prototype report):
--   • intercept is rolled ONCE, at leg departure/creation — NOT re-rolled as the fleet visibly
--     crosses mid-flight on the 30s cron (the task's "and/or" — the departure roll was chosen as the
--     lower-risk surface: a synchronous per-request RPC, never the hot shared settle cron).
--   • combat only opens for a zone with a linked pirate_hunt location; a fully standalone zone forces
--     a stop but does not fight (see header above).
--   • the client waypoint UI (1-3 taps) + the polygon draw editor + the smooth "slime" rendering are
--     built in the companion client changes; the draw/create RPC below has NO admin-role gate (any
--     authenticated caller may draw a zone while the flag is lit) — acceptable ONLY because the whole
--     surface is dark by default; a real admin role is a follow-up, not this prototype's job.
--   • a manual, un-routed command_ship_group_go issued while a route is queued does NOT auto-cancel
--     the queue (fleet_set_moving is a frozen shared primitive, deliberately not touched to hook
--     this) — command_ship_group_cancel_route is provided as an explicit clear, and the client calls
--     it before a plain go whenever a route might be pending. Documented rough edge, not silently
--     hidden.

-- ── 0. dependency + extension gate ──────────────────────────────────────────────────────────────
do $pi0$
begin
  if to_regprocedure('public.command_ship_group_go(uuid, uuid, double precision, double precision)') is null then
    raise exception 'PIRATE-INTERCEPT: public.command_ship_group_go is missing — this slice re-creates its TRUE head (0219)';
  end if;
  if to_regprocedure('public.calculate_group_expedition_stats(uuid, uuid, text)') is null then
    raise exception 'PIRATE-INTERCEPT: public.calculate_group_expedition_stats (0166) is missing — the risk formula composes it';
  end if;
  if to_regprocedure('public.presence_create(uuid, uuid, uuid, uuid, uuid, text)') is null then
    raise exception 'PIRATE-INTERCEPT: public.presence_create (0008) is missing — the ambush composes it, never a second combat entry';
  end if;
  if to_regclass('public.group_sortie_members') is null then
    raise exception 'PIRATE-INTERCEPT: public.group_sortie_members (0168) is missing — the ambush manifest freeze composes its shape';
  end if;
end $pi0$;

create extension if not exists postgis;

-- ── 1. config: the ONE flag + the risk-tuning knobs (all seeded, all dark-safe defaults) ─────────
insert into public.game_config (key, value, description)
values
  (
    'pirate_intercept_enabled',
    'false'::jsonb,
    'PIRATE INTERCEPT (prototype): governs the WHOLE slice — danger-zone intercept rolls, waypoint '
    'route advancing, and the zone draw/read RPCs. DARK. Every server arm below rejects/no-ops on '
    'this gate BEFORE any other read; flag off = today''s movement/combat byte-identical.'
  ),
  (
    'pirate_intercept_base_risk',
    '0.35'::jsonb,
    'PIRATE INTERCEPT: the intercept probability for a fleet with ZERO combined combat_power+survival '
    'crossing a danger zone at full exposure (before the min/max clamp). Tunable without redeploy.'
  ),
  (
    'pirate_intercept_stat_reference',
    '120'::jsonb,
    'PIRATE INTERCEPT: the combined (combat_power+survival) stat value at which risk falls to half of '
    'pirate_intercept_base_risk (a simple hyperbolic falloff: risk ∝ reference/(reference+combined)).'
  ),
  (
    'pirate_intercept_min_risk',
    '0.02'::jsonb,
    'PIRATE INTERCEPT: the floor — even an overwhelmingly strong fleet always carries SOME risk '
    'crossing a danger zone ("there is always a risk", the owner''s own words).'
  ),
  (
    'pirate_intercept_max_risk',
    '0.9'::jsonb,
    'PIRATE INTERCEPT: the ceiling — a zero-stat fleet at maximum exposure is very likely, never '
    'certain, to be intercepted.'
  ),
  (
    'pirate_intercept_exposure_floor',
    '0.15'::jsonb,
    'PIRATE INTERCEPT: the minimum exposure-fraction multiplier — even a tangential graze of a zone '
    '(a tiny ST_Intersection length vs. the whole leg) still carries at least this fraction of the '
    'stat-scaled risk, so a razor-thin clip is never risk-free.'
  ),
  (
    'pirate_route_max_waypoints',
    '3'::jsonb,
    'PIRATE INTERCEPT / waypoint routing: the maximum number of intermediate waypoints a player may '
    'plot before the final destination on one command_ship_group_go_route call.'
  )
on conflict (key) do nothing;

-- ── 2. danger_zones — the independent polygon geometry table ─────────────────────────────────────
create table public.danger_zones (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default 'Danger Zone' check (char_length(btrim(name)) between 1 and 60),
  zone_kind   text not null default 'pirate' check (zone_kind in ('pirate')),
  source      text not null check (source in ('circle', 'drawn')),
  location_id uuid references public.locations (id) on delete cascade,
  boundary    geometry(Polygon) not null,
  status      text not null default 'active' check (status in ('active', 'inactive')),
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- coherence: a 'circle' zone is ALWAYS location-backed (it IS that location's circle); a 'drawn'
  -- zone may or may not be (the standalone case — see header).
  check (source <> 'circle' or location_id is not null)
);
create index danger_zones_boundary_gix on public.danger_zones using gist (boundary);
create index danger_zones_location_idx on public.danger_zones (location_id) where location_id is not null;

alter table public.danger_zones enable row level security;
-- Belt-and-suspenders dark gate AT THE ROW LEVEL (not just in RPC bodies): while the flag is false,
-- NO row is selectable by anon/authenticated regardless of client code — a stronger guarantee than
-- "the RPC checks the flag", because it also covers a hypothetical direct table read.
create policy "danger_zones_select_when_lit" on public.danger_zones
  for select using (status = 'active' and public.cfg_bool('pirate_intercept_enabled'));
grant select on public.danger_zones to anon, authenticated;

comment on table public.danger_zones is
  'PIRATE INTERCEPT (prototype): independent polygon danger-zone geometry. source=''circle'' mirrors '
  'an existing pirate location''s territory_radius (auto-seeded, untouched original column); '
  'source=''drawn'' is an owner-authored polygon, optionally linked to a pirate_hunt location for '
  'live combat or standalone (location_id NULL) for a geometry-only warning + forced-stop stub.';

-- ── 3. seed: one 'circle' zone per existing hostile territory (ZERO change to locations/get_world_map) ──
insert into public.danger_zones (name, zone_kind, source, location_id, boundary)
select l.name, 'pirate', 'circle', l.id,
       ST_Buffer(ST_MakePoint(l.x, l.y), l.territory_radius, 32)
  from public.locations l
 where l.location_type in ('pirate_hunt', 'pirate_den')
   and l.territory_radius is not null
   and l.status = 'active';

-- ── 4. pirate_intercepts — the audit/demo log (every roll, hit or miss) ──────────────────────────
create table public.pirate_intercepts (
  id               uuid primary key default gen_random_uuid(),
  movement_id      uuid references public.fleet_movements (id) on delete set null,
  fleet_id         uuid not null references public.fleets (id) on delete cascade,
  player_id        uuid not null references auth.users (id) on delete cascade,
  zone_id          uuid references public.danger_zones (id) on delete set null,
  location_id      uuid references public.locations (id) on delete set null,
  origin_x         double precision not null,
  origin_y         double precision not null,
  target_x         double precision not null,
  target_y         double precision not null,
  exposure_fraction double precision not null,
  combined_stats   double precision not null,
  risk             double precision not null,
  roll             double precision not null,
  hit              boolean not null,
  presence_id      uuid,
  encounter_id     uuid references public.combat_encounters (id) on delete set null,
  note             text,
  created_at       timestamptz not null default now()
);
create index pirate_intercepts_fleet_idx on public.pirate_intercepts (fleet_id);
create index pirate_intercepts_player_idx on public.pirate_intercepts (player_id);

alter table public.pirate_intercepts enable row level security;
create policy "pirate_intercepts_select_own" on public.pirate_intercepts
  for select using (player_id = auth.uid());
grant select on public.pirate_intercepts to authenticated;

comment on table public.pirate_intercepts is
  'PIRATE INTERCEPT (prototype): one row per leg-departure risk roll (hit or miss) — the audit trail '
  'used by the self-assert + the demo. Sole writer: pirate_intercept_evaluate_leg.';

-- ── 5. fleet_route_legs — the waypoint QUEUE (the remaining legs of a plotted route) ─────────────
create table public.fleet_route_legs (
  id                 uuid primary key default gen_random_uuid(),
  fleet_id           uuid not null references public.fleets (id) on delete cascade,
  player_id          uuid not null references auth.users (id) on delete cascade,
  seq                integer not null check (seq > 0),
  target_type        text not null check (target_type in ('space', 'location')),
  target_location_id uuid references public.locations (id),
  target_x           double precision,
  target_y           double precision,
  created_at         timestamptz not null default now(),
  unique (fleet_id, seq),
  check (
    (target_type = 'location' and target_location_id is not null and target_x is null and target_y is null)
    or
    (target_type = 'space' and target_location_id is null and target_x is not null and target_y is not null)
  )
);
create index fleet_route_legs_fleet_idx on public.fleet_route_legs (fleet_id, seq);

alter table public.fleet_route_legs enable row level security;
create policy "fleet_route_legs_select_own" on public.fleet_route_legs
  for select using (player_id = auth.uid());
grant select on public.fleet_route_legs to authenticated;

comment on table public.fleet_route_legs is
  'PIRATE INTERCEPT / waypoint routing (prototype): the QUEUE of remaining legs for a plotted route. '
  'fleet_movements keeps its one-active-leg-per-fleet invariant (0007) untouched — this table holds '
  'what comes NEXT. Sole writer: command_ship_group_go_route (inserts) + process_pirate_route_legs '
  '(consumes) + command_ship_group_cancel_route (clears).';

-- ── 6. pirate_intercept_leg_zone_hits — the ONE segment-vs-polygon geometry leaf ─────────────────
-- Pure read, no gate (composed by BOTH the internal ambush trigger and the read-only client preview,
-- each of which gates on the flag at ITS OWN boundary — the geometry test itself has no side effects
-- to guard). Internal posture: no client grant (the osn_distance/movement_position_at idiom).
create or replace function public.pirate_intercept_leg_zone_hits(
  p_ox double precision, p_oy double precision,
  p_tx double precision, p_ty double precision
)
returns table (
  zone_id           uuid,
  location_id       uuid,
  exposure_fraction double precision,
  ambush_x          double precision,
  ambush_y          double precision
)
language sql
stable
security definer
set search_path = public
as $$
  with leg as (
    select ST_MakeLine(ST_MakePoint(p_ox, p_oy), ST_MakePoint(p_tx, p_ty)) as geom
  )
  select
    z.id,
    z.location_id,
    case when ST_Length(leg.geom) > 0
      then least(1.0, ST_Length(ST_Intersection(z.boundary, leg.geom)) / ST_Length(leg.geom))
      else 1.0
    end as exposure_fraction,
    ST_X(ST_ClosestPoint(leg.geom, ST_Centroid(z.boundary))) as ambush_x,
    ST_Y(ST_ClosestPoint(leg.geom, ST_Centroid(z.boundary))) as ambush_y
  from public.danger_zones z, leg
  where z.status = 'active'
    and ST_Intersects(z.boundary, leg.geom)
$$;

revoke execute on function public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision) from public, anon, authenticated;
grant execute on function public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision) to service_role;

comment on function public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision) is
  'PIRATE INTERCEPT: the ONE segment-vs-polygon crossing test. Returns one row per active danger_zone '
  'the leg (origin)->(target) intersects, with exposure_fraction = (length of the crossing)/(leg '
  'length), floored/capped by the caller, and the ambush point (closest point on the leg to the '
  'zone''s centroid). Composed by the ambush trigger AND the read-only route preview — never forked.';

-- ── 7. pirate_intercept_compute_risk — the ONE risk-formula leaf ─────────────────────────────────
create or replace function public.pirate_intercept_compute_risk(
  p_combined_stats double precision,
  p_exposure_fraction double precision
)
returns double precision
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    coalesce(public.cfg_num('pirate_intercept_min_risk'), 0.02),
    least(
      coalesce(public.cfg_num('pirate_intercept_max_risk'), 0.9),
      coalesce(public.cfg_num('pirate_intercept_base_risk'), 0.35)
        * (coalesce(public.cfg_num('pirate_intercept_stat_reference'), 120)
           / (coalesce(public.cfg_num('pirate_intercept_stat_reference'), 120) + greatest(coalesce(p_combined_stats, 0), 0)))
        * least(1.0, greatest(coalesce(public.cfg_num('pirate_intercept_exposure_floor'), 0.15), coalesce(p_exposure_fraction, 1.0)))
    )
  )
$$;

revoke execute on function public.pirate_intercept_compute_risk(double precision, double precision) from public, anon, authenticated;
grant execute on function public.pirate_intercept_compute_risk(double precision, double precision) to service_role;

comment on function public.pirate_intercept_compute_risk(double precision, double precision) is
  'PIRATE INTERCEPT: risk = clamp(base_risk * ref/(ref+combined), min_risk, max_risk) * '
  'clamp(exposure_fraction, exposure_floor, 1.0). Lower combined stats -> risk climbs toward '
  'base_risk; higher combined stats -> risk falls toward (never below) min_risk. Tunable via '
  'game_config, no redeploy required.';

-- ── 8. pirate_intercept_evaluate_leg — the ambush ORCHESTRATOR (internal; the ONE trigger site) ──
-- DARK-FIRST: the gate is the literal first statement — false -> zero reads, zero writes. Composes
-- ONLY frozen/existing primitives for the ambush itself (fleet_set_present, presence_create,
-- fleet_set_in_space, group_sortie_members' own insert shape) — combat_create_encounter /
-- combat_create_group_encounter / process_combat_ticks are NEVER re-created or forked.
-- RAISE-FREE TOWARD THE CALLER (the combat_create_group_encounter law, mirrored): this runs inside a
-- live player-facing RPC's transaction (command_ship_group_go / the route advance), never the hot
-- settle cron — but an uncaught raise here would still fail the player's "go" outright. The outer
-- exception handler fails OPEN: on any unexpected error the whole ambush (including the movement
-- cancel) rolls back to the plpgsql block's implicit savepoint, so the leg proceeds UNINTERRUPTED,
-- exactly as if the leaf had never been called.
create or replace function public.pirate_intercept_evaluate_leg(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv       record;
  v_fleet    record;
  v_hit      record;
  v_group    uuid;
  v_stats    jsonb;
  v_combined double precision;
  v_risk     double precision;
  v_roll     double precision;
  v_hitbool  boolean;
  v_now      timestamptz := now();
  v_loc      record;
  v_presence uuid;
  v_enc      uuid;
  v_log_id   uuid;
begin
  -- DARK GATE FIRST — before any read at all.
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('hit', false, 'reason', 'dark');
  end if;

  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status
    into v_mv
    from public.fleet_movements
   where id = p_movement_id;
  if not found or v_mv.status <> 'moving' then
    return jsonb_build_object('hit', false, 'reason', 'not_moving');
  end if;

  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id;
  -- This hook only ever fires from the unified GROUP mover / route advance — the ONLY shapes that
  -- mint main_ship_id NULL + group_id SET fleets. Anything else (a legacy per-ship or unit fleet) is
  -- simply not this feature's concern for the prototype — skip cleanly, never guess.
  if not found or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    return jsonb_build_object('hit', false, 'reason', 'not_group_fleet');
  end if;
  v_group := v_fleet.group_id;

  -- deepest crossing wins (highest exposure_fraction); stable tie-break isn't load-bearing for a
  -- prototype demo, but `limit 1` needs SOME order to be deterministic.
  select * into v_hit
    from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y)
   order by exposure_fraction desc, zone_id asc
   limit 1;
  if not found then
    return jsonb_build_object('hit', false, 'reason', 'no_crossing');
  end if;

  -- combined stats: reuse the SAME group-stats adapter the mover already calls for speed (D0, 0166).
  -- Fail OPEN on any adapter raise (an illegal member state etc.) — treat as unknown/weak (combined=0,
  -- the conservative choice) rather than let a stats bug break a player's movement command.
  begin
    v_stats := public.calculate_group_expedition_stats(v_fleet.player_id, v_group, 'none');
    v_combined := coalesce((v_stats->'totals'->>'combat_power')::double precision, 0)
                + coalesce((v_stats->'totals'->>'survival')::double precision, 0);
  exception when others then
    v_combined := 0;
  end;

  v_risk    := public.pirate_intercept_compute_risk(v_combined, v_hit.exposure_fraction);
  v_roll    := random();
  v_hitbool := v_roll < v_risk;

  insert into public.pirate_intercepts (
    movement_id, fleet_id, player_id, zone_id, location_id,
    origin_x, origin_y, target_x, target_y, exposure_fraction,
    combined_stats, risk, roll, hit)
  values (
    p_movement_id, v_fleet.id, v_fleet.player_id, v_hit.zone_id, v_hit.location_id,
    v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, v_hit.exposure_fraction,
    v_combined, v_risk, v_roll, v_hitbool)
  returning id into v_log_id;

  if not v_hitbool then
    return jsonb_build_object('hit', false, 'risk', v_risk, 'roll', v_roll, 'zone_id', v_hit.zone_id);
  end if;

  -- ── THE AMBUSH ───────────────────────────────────────────────────────────────────────────────
  -- Re-lock + re-check: a concurrent brake/redirect may have resolved this movement between the
  -- first (unlocked) read above and here. Never double-trigger a settled/cancelled leg.
  perform 1 from public.fleet_movements where id = p_movement_id and status = 'moving' for update;
  if not found then
    update public.pirate_intercepts set hit = false, note = 'race_lost' where id = v_log_id;
    return jsonb_build_object('hit', false, 'reason', 'race_lost');
  end if;

  update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;

  if v_hit.location_id is null then
    -- STANDALONE drawn zone (no linked pirate_hunt location): the documented combat stub. No
    -- location means no presence/encounter is possible without inventing one — instead the ambush
    -- is made TANGIBLE by forcing the fleet to a stop at the ambush point, the SAME leaf the brake
    -- (command_ship_group_stop, 0215/0218) uses to park a fleet mid-flight. Not a no-op.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'standalone_zone_stub_forced_stop' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'standalone_zone_stub', 'risk', v_risk, 'roll', v_roll);
  end if;

  select l.id, l.zone_id, z.sector_id
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = v_hit.location_id and l.status = 'active';
  if v_loc.id is null then
    -- the linked location vanished/deactivated since the zone was drawn/seeded — fail open: park,
    -- no combat, rather than reference a location that can no longer host a presence.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'location_missing' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'location_missing', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- fleet_set_present demands status='moving' (0006) — true here: the mover just called
  -- fleet_set_moving and nothing since has changed the fleet's status.
  perform public.fleet_set_present(v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id);

  -- Freeze the sortie MANIFEST — byte-identical INSERT shape to send_ship_group_hunt's sole-writer
  -- freeze (0168:304-306), so combat_create_encounter's manifest-gated branch (0168) routes this
  -- fleet into combat_create_group_encounter exactly as a deliberate hunt does. ON CONFLICT DO
  -- NOTHING: idempotent against a (should-be-impossible) re-entry.
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;

  -- presence_create -> activity_start('hunt_pirates') -> combat_create_encounter -> (manifest exists)
  -- -> combat_create_group_encounter. FOUR frozen functions composed, ZERO re-created.
  v_presence := public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'hunt_pirates');

  select id into v_enc from public.combat_encounters where presence_id = v_presence order by created_at desc limit 1;
  update public.pirate_intercepts set encounter_id = v_enc, presence_id = v_presence where id = v_log_id;

  return jsonb_build_object(
    'hit', true, 'risk', v_risk, 'roll', v_roll,
    'location_id', v_loc.id, 'presence_id', v_presence, 'encounter_id', v_enc);
exception
  when others then
    raise warning 'pirate_intercept_evaluate_leg: unexpected error for movement % (leg left UNINTERRUPTED): %',
      p_movement_id, sqlerrm;
    return jsonb_build_object('hit', false, 'reason', 'internal_error');
end;
$$;

revoke execute on function public.pirate_intercept_evaluate_leg(uuid) from public, anon, authenticated;
grant execute on function public.pirate_intercept_evaluate_leg(uuid) to service_role;

comment on function public.pirate_intercept_evaluate_leg(uuid) is
  'PIRATE INTERCEPT: the ONE trigger site. DARK-FIRST (flag gate is the first statement). Rolls the '
  'stat-scaled risk for a just-created movement leg against every crossed danger_zone; on a hit, '
  'cancels the leg and routes the fleet into the EXISTING combat path via the EXISTING manifest-freeze '
  '+ presence_create + activity_start + combat_create_encounter chain (or a forced stop for a '
  'standalone zone). Fails OPEN (leg proceeds untouched) on any internal error.';

-- ── 9. command_ship_group_cancel_route — explicit queue clear (mitigates the manual-go seam) ─────
create or replace function public.command_ship_group_cancel_route(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_group  uuid;
  v_fleet  uuid;
  v_n      integer;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'pirate_intercept_disabled');
  end if;
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  select id into v_fleet from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_fleet is null then
    return jsonb_build_object('ok', true, 'cleared', 0);
  end if;
  delete from public.fleet_route_legs where fleet_id = v_fleet and player_id = v_player;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'cleared', v_n);
end;
$$;

revoke all on function public.command_ship_group_cancel_route(uuid) from public;
grant execute on function public.command_ship_group_cancel_route(uuid) to authenticated;

comment on function public.command_ship_group_cancel_route(uuid) is
  'PIRATE INTERCEPT / waypoint routing: clears any queued fleet_route_legs for the group''s unified '
  'fleet. The client calls this before a plain (non-routed) go whenever a route might be pending — '
  'see the file header''s documented manual-go seam.';

-- ── 10. command_ship_group_go — PARITY re-create of the 0219 TRUE HEAD, ONE new marked hunk ──────
-- Byte-copied from 20260618000219_timed_docking.sql:312-744 (the current TRUE head — confirmed by
-- grep: nothing re-creates command_ship_group_go after 0219). The ONLY delta: ONE `perform`-style
-- call to the dark-gated intercept leaf, placed AFTER fleet_set_moving (the leg is fully committed)
-- and folded into the return envelope as `intercepted`. Every other line — the dark gate, target
-- shape, the S4 dock-translate hunk, both guards, the whole origin chain, the dissolve, the S4 flat
-- clock note (this file changes nothing about it) — is the head, verbatim.
create or replace function public.command_ship_group_go(
  p_group_id    uuid,
  p_location_id uuid default null,
  p_target_x    double precision default null,
  p_target_y    double precision default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player     uuid := auth.uid();
  v_group      uuid;
  v_members    uuid[];
  v_member_n   integer;
  v_loc        record;
  v_fleet      uuid;
  v_fleet_row  record;
  v_unified_n  integer;
  v_busy       integer;
  v_hunting    integer;
  v_mv         record;
  v_old_mv     uuid;
  v_o_type     text;
  v_o_base     uuid;
  v_o_zone     uuid;
  v_o_loc      uuid;
  v_o_x        double precision;
  v_o_y        double precision;
  v_t_type     text;
  v_t_loc      uuid;
  v_t_x        double precision;
  v_t_y        double precision;
  v_stats      jsonb;
  v_speed      double precision;
  v_movement   uuid;
  v_arrive     timestamptz;
  v_redirected boolean := false;
  v_max        integer;
  v_active     integer;
  v_base       record;
  v_dock_n     integer;
  v_dock       record;
  v_now        timestamptz := now();
  -- PIRATE-INTERCEPT: the leaf's dark-gated jsonb envelope ({hit:false,...} while dark — no writes).
  v_intercept  jsonb;
  -- The navigable square. COPIED from mainship_space_begin_move_core (0067:133-134) so a fleet and a
  -- ship agree on the world's edges; it is NOT a second authority. Step 4 retires 0067 — fold these
  -- into one shared bound then rather than leaving two copies.
  c_lo constant double precision := -10000;
  c_hi constant double precision :=  10000;
begin
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- 2) DARK gate — reject before ANY read, lock, or write (the 0161/0178 reject-before-read posture).
  if not public.cfg_bool('fleet_movement_unified_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'unified_movement_disabled');
  end if;

  -- 3) TARGET SHAPE — exactly one of {port} or {coordinate}. Validated BEFORE any read, so a
  --    malformed command never costs a lock (and never leaks whether a group exists).
  --    The 0067 rule, reused: client coordinates are NEVER accepted alongside a location target —
  --    a port's position is the server's to know, not the caller's to assert.
  if p_location_id is not null then
    if p_target_x is not null or p_target_y is not null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
    end if;
    v_t_type := 'location';
  elsif p_target_x is not null and p_target_y is not null then
    v_t_type := 'space';
    if p_target_x = 'NaN'::double precision or p_target_x = 'Infinity'::double precision or p_target_x = '-Infinity'::double precision
       or p_target_y = 'NaN'::double precision or p_target_y = 'Infinity'::double precision or p_target_y = '-Infinity'::double precision then
      return jsonb_build_object('ok', false, 'reason', 'invalid_coordinate');
    end if;
    if p_target_x < c_lo or p_target_x > c_hi or p_target_y < c_lo or p_target_y > c_hi then
      return jsonb_build_object('ok', false, 'reason', 'target_out_of_bounds');
    end if;
    -- canonicalize to the integer world grid (the 0178 rule) BEFORE anything reads it.
    v_t_x := round(p_target_x::numeric)::double precision;
    v_t_y := round(p_target_y::numeric)::double precision;
  else
    -- neither, or a half-specified coordinate.
    return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
  end if;

  -- 4) resolve + LOCK the group. FOR UPDATE (not FOR SHARE): two concurrent go's on the SAME group
  --    must serialize, or both could create a fleet / both redirect. This is the first lock taken;
  --    every other group RPC also takes ship_groups first, so the order is consistent.
  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  perform 1 from public.ship_groups where group_id = v_group and player_id = v_player for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- 5) members. Read-only: the members are the fleet's manifest, never movement subjects.
  select coalesce(array_agg(main_ship_id order by created_at), '{}')
    into v_members
    from public.main_ship_instances
   where group_id = v_group and player_id = v_player;
  v_member_n := coalesce(array_length(v_members, 1), 0);
  if v_member_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_group');
  end if;

  -- 6) destination: a port must exist, be active, and be NON-COMBAT.
  --    The activity_type check is the SAME rule the legacy per-ship move enforces (0156: active +
  --    non-combat) — composed, not invented. It is a TARGET-legality check, not a readiness branch (§4):
  --    it asks what the destination IS, never where the fleet is.
  --    WHY IT IS LOAD-BEARING: the settle creates a presence carrying the target's activity_type
  --    (0153/this file's location branch), and an activity='hunt_pirates' presence is what
  --    combat_create_encounter routes on. A unified fleet has NO combat_units — it is not a sortie, it
  --    has no group_sortie_members manifest — so it would snapshot zero units and the tick's defeat
  --    branch would DESTROY it on arrival. A move is not a hunt: hunts go through
  --    send_ship_group_hunt (0168/0204), which builds the manifest. Found by the step-3c/4 recon; the
  --    3a/3b proofs never flew to a hunt site so they never saw it.
  if v_t_type = 'location' then
    select l.id, l.x, l.y, l.status, l.zone_id, l.activity_type, z.sector_id
      into v_loc
      from public.locations l
      join public.zones z on z.id = l.zone_id
     where l.id = p_location_id;
    if v_loc.id is null or v_loc.status <> 'active' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_location');
    end if;
    if v_loc.activity_type is distinct from 'none' then
      return jsonb_build_object('ok', false, 'reason', 'combat_destination');
    end if;
    v_t_loc := v_loc.id; v_t_x := v_loc.x; v_t_y := v_loc.y;
    -- ── ★ THE S4 TRANSLATE HUNK (0219, unchanged by this file) — TIMED DOCKING: a DOCKABLE port  ★ ──
    -- ── ★ target becomes its COORDINATE. The fleet parks in orbit inside the port's territory   ★ ──
    -- ── ★ and DOCK is the separate 45s verb (command_ship_group_dock). Dark -> this if is       ★ ──
    -- ── ★ skipped -> byte-identical instant dock.                                                ★ ──
    if public.cfg_bool('timed_docking_enabled')
       and (public.mainship_space_location_target_legal(v_loc.id)->>'ok')::boolean is true then
      v_t_type := 'space'; v_t_loc := null;   -- v_t_x/v_t_y already carry the port's coordinate
    end if;
    -- ── ★ END OF THE S4 TRANSLATE HUNK — the head continues verbatim from here ★ ────────────────
  end if;

  -- 7) TRANSITION GUARD (delete me at step 4, not before).
  --    While the per-ship movers still exist and are flag-ON, a member could be flying its OWN
  --    per-ship fleet. If the group also flew, that ship would be in two places at once — the exact
  --    duality §2 kills. So: no member may hold a live per-ship fleet.
  --    This is NOT the "per-command readiness branch" §4 forbids: it does not gate on where the
  --    fleet IS (there is deliberately no home/docked precondition below). It rejects a state that
  --    only exists because the OLD layer is still alive, and it becomes unreachable — and must be
  --    removed — the moment step 4 retires the per-ship movers.
  select count(*) into v_busy
    from public.fleets f
   where f.player_id = v_player
     and f.main_ship_id = any(v_members)
     and f.status in ('moving', 'returning');
  if v_busy > 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_busy');
  end if;

  -- 8) the group must not be mid-sortie: a hunt fleet is a group fleet already committed to combat.
  --    Redirecting it is out of scope (the escape/settle mechanics own it) — fail closed rather than
  --    quietly steer a fleet out of an encounter.
  select count(*) into v_hunting
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = v_player
     and f.group_id = v_group
     and f.status in ('moving', 'present', 'returning');
  if v_hunting > 0 then
    return jsonb_build_object('ok', false, 'reason', 'group_on_sortie');
  end if;

  -- 9) THE MOVER: the group's ONE unified fleet.
  --    Keyed group_id + main_ship_id IS NULL — NOT group_id alone: the legacy expedition send TAGS
  --    group_id onto PER-MEMBER fleets (0204:316, display-only, "routing never reads it"), so
  --    group_id alone would match N member envelopes and pick one at random.
  select count(*) into v_unified_n
    from public.fleets
   where group_id = v_group and player_id = v_player and main_ship_id is null
     and status in ('idle', 'moving', 'present', 'returning');
  if v_unified_n > 1 then
    -- Never silently pick one. Two live unified fleets for one group is a broken invariant.
    return jsonb_build_object('ok', false, 'reason', 'fleet_ambiguous');
  end if;

  if v_unified_n = 1 then
    select * into v_fleet_row
      from public.fleets
     where group_id = v_group and player_id = v_player and main_ship_id is null
       and status in ('idle', 'moving', 'present', 'returning')
     for update;
    v_fleet := v_fleet_row.id;
  end if;

  -- 10) ORIGIN — "the fleet moves from wherever it is" (§2). No home/docked precondition.
  --    STRUCTURE NOTE: the `v_fleet is null` bootstrap MUST be the first branch, so the later branches
  --    only ever touch v_fleet_row once it is assigned. Do NOT rewrite this as
  --    `if v_fleet is not null and v_fleet_row.status = ...` — SQL's AND does not guarantee
  --    left-to-right short-circuit, and reading a field of an unassigned RECORD raises
  --    "record is not assigned yet" regardless of the guard. (The CI proof caught exactly that.)
  if v_fleet is null then
    -- ── BOOTSTRAP (transition-only): the group has no fleet yet, so its position must be derived
    --    ONCE from its members' per-ship state — the only place this function reads ship state as a
    --    position, and only to create the group's first fleet. After step 4 ships have no position
    --    and a group's fleet is created with the group, so this branch disappears.
    select count(distinct lp.location_id) into v_dock_n
      from public.main_ship_instances s
      join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
      join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
     where s.main_ship_id = any(v_members);

    if v_dock_n = 1 then
      select lp.location_id, lp.zone_id, l.x, l.y into v_dock
        from public.main_ship_instances s
        join public.fleets f on f.main_ship_id = s.main_ship_id and f.player_id = v_player and f.status = 'present'
        join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
        join public.locations l on l.id = lp.location_id
       where s.main_ship_id = any(v_members)
       limit 1;
      v_o_type := 'location'; v_o_base := null; v_o_zone := v_dock.zone_id; v_o_loc := v_dock.location_id;
      v_o_x := v_dock.x; v_o_y := v_dock.y;
    elsif v_dock_n = 0 then
      select b.id, b.x, b.y, b.sector_id into v_base
        from public.bases b where b.player_id = v_player and b.status = 'active'
        order by b.created_at limit 1;
      if v_base.id is null then
        return jsonb_build_object('ok', false, 'reason', 'no_origin');
      end if;
      v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
      v_o_x := v_base.x; v_o_y := v_base.y;
    else
      -- Members split across ports: the group has no single position to depart from. BOOTSTRAP-only
      -- (the old world let ships scatter); once the fleet exists it always has exactly one position.
      return jsonb_build_object('ok', false, 'reason', 'group_scattered');
    end if;

  elsif v_fleet_row.active_movement_id is not null then
    -- ── REDIRECT: cancel the live leg at its INTERPOLATED point, then depart from there. ─────────
    select * into v_mv
      from public.fleet_movements
     where id = v_fleet_row.active_movement_id
     for update;
    if v_mv.id is null or v_mv.status <> 'moving' then
      -- The settle cron took it between our reads; the fleet is no longer where we thought.
      -- Fail closed and let the caller re-issue against fresh state rather than guess.
      return jsonb_build_object('ok', false, 'reason', 'movement_settled_retry');
    end if;
    -- ── ★ THE S3 FOLD HUNK — the inline lerp is a compose of movement_position_at, the ONE      ★ ──
    -- ── ★ interpolation authority. Output-identical by construction; the self-assert re-proves  ★ ──
    -- ── ★ it at deploy time — so NO new flag.                                                    ★ ──
    select o_x, o_y into v_o_x, v_o_y
      from public.movement_position_at(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y,
                                       v_mv.depart_at, v_mv.arrive_at, v_now);
    -- ── ★ END OF THE S3 FOLD HUNK — the head continues verbatim from here ★ ────────────────────
    v_o_type := 'space';   -- allowed by fleet_movements_origin_type_check since 0156
    v_o_base := null; v_o_zone := null; v_o_loc := null;
    v_old_mv := v_mv.id;
    v_redirected := true;

  elsif v_fleet_row.location_mode = 'space' then
    -- ── FLEET-GO 3b: the fleet is PARKED in open space at its own coordinate. Depart from there.
    --    This is the branch that makes the model closed: a coordinate arrival (the settle's new
    --    'space' branch) leaves the fleet here, and it can set off again without ever touching a port.
    v_o_type := 'space'; v_o_base := null; v_o_zone := null; v_o_loc := null;
    v_o_x := v_fleet_row.space_x; v_o_y := v_fleet_row.space_y;

  elsif v_fleet_row.status = 'present' and v_fleet_row.current_location_id is not null then
    -- Parked at a port: depart from that port.
    select l.id, l.x, l.y, l.zone_id into v_dock
      from public.locations l where l.id = v_fleet_row.current_location_id;
    if v_dock.id is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_origin');
    end if;
    v_o_type := 'location'; v_o_base := null; v_o_zone := v_dock.zone_id; v_o_loc := v_dock.id;
    v_o_x := v_dock.x; v_o_y := v_dock.y;

  else
    -- The group's fleet exists but is neither in flight, in space, nor docked (idle / returning with
    -- no leg). Its anchor is its origin base — the same anchor the hunt uses for return mechanics.
    -- Not a rejection: §2 says the fleet moves from wherever it is, and "at its anchor" is a place.
    select b.id, b.x, b.y, b.sector_id into v_base
      from public.bases b
     where b.player_id = v_player and b.status = 'active'
       and (v_fleet_row.origin_base_id is null or b.id = v_fleet_row.origin_base_id)
     order by b.created_at limit 1;
    if v_base.id is null then
      return jsonb_build_object('ok', false, 'reason', 'no_origin');
    end if;
    v_o_type := 'base'; v_o_base := v_base.id; v_o_zone := null; v_o_loc := null;
    v_o_x := v_base.x; v_o_y := v_base.y;
  end if;

  -- 11) SPEED — D0's authoritative group stats (0166): delegates per-member to 0122, sums additive
  --     keys, takes speed = MIN over members, and raises rather than clamping. Reused, not re-folded.
  begin
    v_stats := public.calculate_group_expedition_stats(v_player, v_group, 'none');
  exception when others then
    -- 0166 is STRICT by design (refuse-don't-clamp): a member's bad stats raise and refuse the whole
    -- team context. Caught here and returned as an envelope — this RPC never raises at its boundary.
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end;
  -- NOTE: 0166 nests the folds under 'totals' — `v_stats->>'speed'` is NULL at the top level and
  -- silently degrades to stats_invalid. (The CI proof caught exactly that.)
  v_speed := (v_stats->'totals'->>'speed')::double precision;
  if v_speed is null or not (v_speed > 0) then
    -- fleet_movements_speed_used_check demands > 0; reject rather than feed the spine a bad row.
    return jsonb_build_object('ok', false, 'reason', 'stats_invalid');
  end if;

  -- 12) fleet budget — only when this call would CREATE a fleet. A redirect/re-launch of the group's
  --     existing fleet consumes no new slot.
  if v_fleet is null then
    v_max := coalesce(public.cfg_num('max_active_fleets'), 3);
    select count(*) into v_active
      from public.fleets
     where player_id = v_player and status in ('moving', 'present', 'returning');
    if v_active >= v_max then
      return jsonb_build_object('ok', false, 'reason', 'fleet_limit_reached');
    end if;
  end if;

  -- ── WRITES ─────────────────────────────────────────────────────────────────────────────────────
  -- NOTE FOR EVERY FUTURE READER: there is deliberately NO `update main_ship_instances` below.
  -- That absence is the charter's §2. If you are here to add one, re-read §2 and §0 first.

  -- ★ DISSOLVE THE MEMBERS' OWN DOCKS — the ships leave the port to fly with the fleet. ★
  -- This is send_ship_group_hunt's block (0204:664-676), composed verbatim rather than re-invented.
  perform public.presence_complete(lp.id)
    from public.fleets f
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active'
   where f.player_id = v_player and f.main_ship_id = any(v_members) and f.status = 'present';
  update public.fleets
     set status = 'completed', location_mode = 'movement', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = v_now
   where player_id = v_player and main_ship_id = any(v_members) and status = 'present';

  if v_redirected then
    -- Retire the cancelled leg BEFORE the fleet is re-pointed (fleets_movement_pointers_exclusive).
    update public.fleet_movements
       set status = 'cancelled', resolved_at = v_now
     where id = v_old_mv and status = 'moving';
  end if;

  if v_fleet is null then
    -- The group's ONE fleet: the hunt's proven shape (main_ship_id NULL + group_id set).
    -- origin_base_id anchors the existing return-to-base mechanics, exactly as the hunt does.
    -- Born 'idle' — which is precisely what fleet_set_moving demands below.
    select b.id into v_base
      from public.bases b where b.player_id = v_player and b.status = 'active'
      order by b.created_at limit 1;
    insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, group_id)
      values (v_player, v_base.id, 'idle', 'base', v_base.id, v_group)
      returning id into v_fleet;
  else
    -- Return the group's EXISTING fleet to 'idle' so fleet_set_moving's frozen precondition holds.
    perform public.presence_complete(lp.id)
      from public.location_presence lp
     where lp.fleet_id = v_fleet and lp.status = 'active';
    update public.fleets
       set status = 'idle', location_mode = 'movement', active_movement_id = null,
           space_x = null, space_y = null,
           current_location_id = null, current_zone_id = null, current_sector_id = null,
           updated_at = v_now
     where id = v_fleet;
  end if;

  -- ONE movement for the ONE fleet. mission 'rally' = the spine's generic reposition
  -- (fleet_movements_mission_type_check). For a 'space' target the location id is NULL and the
  -- coordinate carries the destination; for a port it is the reverse (0067's target-shape rule).
  v_movement := public.movement_create(
    v_player, v_fleet,
    v_o_type, v_o_base, v_o_zone, v_o_loc, v_o_x, v_o_y,
    v_t_type, null, null, v_t_loc, v_t_x, v_t_y,
    'rally', v_speed);

  perform public.fleet_set_moving(v_fleet, v_movement);

  -- ── ★ THE PIRATE-INTERCEPT HUNK (pirate_intercept_enabled) — the ONLY delta this migration adds  ★
  -- ── ★ to the mover. The leaf's OWN first statement is the flag gate, so this call is a TRUE     ★
  -- ── ★ no-op while dark: zero reads, zero writes, `v_intercept = {hit:false,reason:'dark'}`. On  ★
  -- ── ★ a hit the leg this RPC just minted is cancelled and the fleet is routed into the existing ★
  -- ── ★ combat path (see pirate_intercept_evaluate_leg) — all within this SAME transaction.       ★
  v_intercept := public.pirate_intercept_evaluate_leg(v_movement);
  -- ── ★ END OF THE PIRATE-INTERCEPT HUNK ★ ─────────────────────────────────────────────────────

  select arrive_at into v_arrive from public.fleet_movements where id = v_movement;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group,
    'fleet_id', v_fleet,
    'movement_id', v_movement,
    'arrive_at', v_arrive,
    'member_count', v_member_n,
    'redirected', v_redirected,
    'origin_type', v_o_type,
    'target_type', v_t_type,
    'target_x', v_t_x,
    'target_y', v_t_y,
    'intercepted', coalesce((v_intercept->>'hit')::boolean, false),
    'intercept_encounter_id', v_intercept->>'encounter_id');
end;
$function$;

comment on function public.command_ship_group_go(uuid, uuid, double precision, double precision) is
  'FLEET-GO (charter §2): the ONE fleet-level mover. Moves a ship_group as a single atomic fleet to a '
  'port OR a world coordinate, from wherever it is (port, open space, anchor, or mid-flight); re-issue '
  'to redirect. Writes NO per-ship movement state — that omission is the point. DARK behind '
  'fleet_movement_unified_enabled. S4 TIMED DOCKING (0219): under timed_docking_enabled a DOCKABLE '
  'port target is translated to its coordinate. PIRATE INTERCEPT (this file): under '
  'pirate_intercept_enabled the newly-minted leg is rolled against every crossed danger zone; a hit '
  'cancels the leg and routes the fleet into combat (or a forced stop). Both additions are dark-safe '
  'no-ops while their flags are false.';

revoke all on function public.command_ship_group_go(uuid, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go(uuid, uuid, double precision, double precision) to authenticated;

-- ── 11. command_ship_group_go_route — the waypoint client RPC (composes the mover for leg 1) ─────
create or replace function public.command_ship_group_go_route(
  p_group_id          uuid,
  p_waypoints         jsonb,
  p_target_location_id uuid default null,
  p_target_x          double precision default null,
  p_target_y          double precision default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_max_wp  integer;
  v_n       integer;
  v_i       integer;
  v_wx      double precision;
  v_wy      double precision;
  v_first   jsonb;
  v_fleet   uuid;
  v_seq     integer;
  c_lo constant double precision := -10000;
  c_hi constant double precision :=  10000;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK gate FIRST — before any read (the reject-before-read posture this whole slice follows).
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'pirate_intercept_disabled');
  end if;

  -- waypoints: a jsonb array of {"x":..,"y":..}, length 1..max (config, default 3), every point
  -- finite and within the SAME navigable square command_ship_group_go bound-checks.
  if p_waypoints is null or jsonb_typeof(p_waypoints) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_waypoints');
  end if;
  v_n := jsonb_array_length(p_waypoints);
  v_max_wp := coalesce(public.cfg_num('pirate_route_max_waypoints'), 3)::integer;
  if v_n < 1 or v_n > v_max_wp then
    return jsonb_build_object('ok', false, 'reason', 'invalid_waypoint_count');
  end if;
  for v_i in 0 .. v_n - 1 loop
    v_wx := (p_waypoints->v_i->>'x')::double precision;
    v_wy := (p_waypoints->v_i->>'y')::double precision;
    if v_wx is null or v_wy is null
       or v_wx = 'NaN'::double precision or v_wx = 'Infinity'::double precision or v_wx = '-Infinity'::double precision
       or v_wy = 'NaN'::double precision or v_wy = 'Infinity'::double precision or v_wy = '-Infinity'::double precision
       or v_wx < c_lo or v_wx > c_hi or v_wy < c_lo or v_wy > c_hi then
      return jsonb_build_object('ok', false, 'reason', 'invalid_waypoint_point');
    end if;
  end loop;

  -- final target shape — the SAME exclusive-or rule as command_ship_group_go.
  if p_target_location_id is not null then
    if p_target_x is not null or p_target_y is not null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
    end if;
  elsif p_target_x is null or p_target_y is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
  end if;

  -- LEG 1: compose the EXISTING mover, unmodified call shape, toward waypoint[0]. Every dark gate,
  -- ownership check, origin-resolution branch, and the intercept roll itself all come along for free.
  v_first := public.command_ship_group_go(
    p_group_id, null,
    (p_waypoints->0->>'x')::double precision,
    (p_waypoints->0->>'y')::double precision);
  if coalesce((v_first->>'ok')::boolean, false) is not true then
    return v_first;
  end if;
  v_fleet := (v_first->>'fleet_id')::uuid;

  -- If leg 1 was itself intercepted, the fleet is now mid-combat (or forced to a stop) — abandon the
  -- rest of the plotted route rather than silently resume it later from an unplanned position.
  if coalesce((v_first->>'intercepted')::boolean, false) then
    return v_first || jsonb_build_object('route_abandoned', true, 'reason_route', 'intercepted_on_first_leg');
  end if;

  -- Queue the REMAINING legs (waypoints[1..] as space legs, then the real final target last).
  -- Clear any stale queue first (re-issuing a route is safe / idempotent for the fleet).
  delete from public.fleet_route_legs where fleet_id = v_fleet and player_id = v_player;

  v_seq := 1;
  for v_i in 1 .. v_n - 1 loop
    insert into public.fleet_route_legs (fleet_id, player_id, seq, target_type, target_x, target_y)
    values (v_fleet, v_player, v_seq,
            'space',
            (p_waypoints->v_i->>'x')::double precision,
            (p_waypoints->v_i->>'y')::double precision);
    v_seq := v_seq + 1;
  end loop;

  if p_target_location_id is not null then
    insert into public.fleet_route_legs (fleet_id, player_id, seq, target_type, target_location_id)
    values (v_fleet, v_player, v_seq, 'location', p_target_location_id);
  else
    insert into public.fleet_route_legs (fleet_id, player_id, seq, target_type, target_x, target_y)
    values (v_fleet, v_player, v_seq, 'space', p_target_x, p_target_y);
  end if;

  return v_first || jsonb_build_object('leg_count', v_n + 1, 'queued_legs', v_seq);
end;
$$;

revoke all on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) from public;
grant execute on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) to authenticated;

comment on function public.command_ship_group_go_route(uuid, jsonb, uuid, double precision, double precision) is
  'PIRATE INTERCEPT / waypoint routing (prototype): plots a multi-leg route (1-3 intermediate space '
  'waypoints + a final port-or-coordinate target). Leg 1 composes the UNMODIFIED command_ship_group_go '
  '(zero duplicated origin logic); the remaining legs queue into fleet_route_legs and are advanced '
  'leg-by-leg by process_pirate_route_legs. DARK behind pirate_intercept_enabled.';

-- ── 12. process_pirate_route_legs — the NEW, SEPARATE advance cron (process_fleet_movements is ────
-- ──     NOT touched, NOT re-created, and carries zero new code or risk). ─────────────────────────
create or replace function public.process_pirate_route_legs()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r          record;
  v_next     record;
  v_stats    jsonb;
  v_speed    double precision;
  v_movement uuid;
  v_loc      record;
  v_count    integer := 0;
begin
  -- DARK GATE FIRST — no-op, zero reads, while the flag is false.
  if not public.cfg_bool('pirate_intercept_enabled') then
    return 0;
  end if;

  for r in
    select f.id as fleet_id, f.player_id, f.group_id, f.space_x, f.space_y
      from public.fleets f
     where f.status = 'idle' and f.location_mode = 'space'
       and f.active_movement_id is null
       and f.group_id is not null and f.main_ship_id is null
       and exists (select 1 from public.fleet_route_legs rl where rl.fleet_id = f.id)
     for update of f skip locked
  loop
    begin
      select * into v_next from public.fleet_route_legs
       where fleet_id = r.fleet_id
       order by seq asc
       limit 1
       for update skip locked;
      if not found then
        continue;
      end if;

      begin
        v_stats := public.calculate_group_expedition_stats(r.player_id, r.group_id, 'none');
        v_speed := (v_stats->'totals'->>'speed')::double precision;
      exception when others then
        v_speed := null;
      end;
      if v_speed is null or not (v_speed > 0) then
        -- The team can no longer be validly folded (a member left the group / an illegal state
        -- since the route was plotted) — abandon the WHOLE remaining route rather than spin forever
        -- retrying a leg that can never mint. The fleet itself is untouched (still parked, idle).
        delete from public.fleet_route_legs where fleet_id = r.fleet_id;
        continue;
      end if;

      if v_next.target_type = 'location' then
        select l.id, l.x, l.y, l.zone_id into v_loc
          from public.locations l
         where l.id = v_next.target_location_id and l.status = 'active';
        if v_loc.id is null then
          -- destination went inactive/vanished since the route was plotted — drop just this leg,
          -- not the whole queue (a location leg is always the LAST queued leg, so nothing follows it).
          delete from public.fleet_route_legs where id = v_next.id;
          continue;
        end if;
        v_movement := public.movement_create(
          r.player_id, r.fleet_id,
          'space', null, null, null, r.space_x, r.space_y,
          'location', null, null, v_loc.id, v_loc.x, v_loc.y,
          'rally', v_speed);
      else
        v_movement := public.movement_create(
          r.player_id, r.fleet_id,
          'space', null, null, null, r.space_x, r.space_y,
          'space', null, null, null, v_next.target_x, v_next.target_y,
          'rally', v_speed);
      end if;

      perform public.fleet_set_moving(r.fleet_id, v_movement);
      delete from public.fleet_route_legs where id = v_next.id;

      -- EVERY leg gets the SAME roll — one authority, called from every leg-minting site (the mover
      -- above via its own hunk, and here for legs 2..N).
      perform public.pirate_intercept_evaluate_leg(v_movement);

      v_count := v_count + 1;
    exception
      when query_canceled then raise;
      when others then
        raise warning 'process_pirate_route_legs: advance failed for fleet % (left queued; retries next tick): %',
          r.fleet_id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.process_pirate_route_legs() from public, anon, authenticated;

comment on function public.process_pirate_route_legs() is
  'PIRATE INTERCEPT / waypoint routing: the queue-advance tick. A NEW, SEPARATE pg_cron job — NOT a '
  'change to process_fleet_movements (the hottest live cron in the game). DARK-FIRST no-op while '
  'pirate_intercept_enabled is false. Per-fleet subtransaction isolation (the 0206 CRON-GUARD lesson '
  'applied proactively): a failing fleet''s advance cannot wedge another fleet''s.';

-- ── register the new cron job (SEPARATE schedule; process_fleet_movements' OWN 0011 job is untouched) ──
-- Byte-mirror of the 0011 idiom: unschedule-if-exists then (re)schedule, idempotent/re-runnable.
create extension if not exists pg_cron;
do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'pirate-route-advance';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

select cron.schedule(
  'pirate-route-advance',
  '30 seconds',
  $$select public.process_pirate_route_legs();$$
);

-- ── 13. pirate_intercept_preview_route — read-only advisory for the client's route warning ────────
create or replace function public.pirate_intercept_preview_route(
  p_group_id           uuid,
  p_waypoints          jsonb,
  p_target_location_id uuid default null,
  p_target_x           double precision default null,
  p_target_y           double precision default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_group    uuid;
  v_stats    jsonb;
  v_combined double precision;
  v_n        integer;
  v_i        integer;
  v_ox       double precision;
  v_oy       double precision;
  v_tx       double precision;
  v_ty       double precision;
  v_loc      record;
  v_legs     jsonb := '[]'::jsonb;
  v_hit      record;
  v_any      boolean := false;
  v_weak     boolean := false;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'pirate_intercept_disabled');
  end if;

  v_group := public.mainship_resolve_owned_group(v_player, p_group_id);
  if v_group is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;

  -- read-only stats fold, for the "weak fleet" stronger-warning flavor. A raise here degrades to
  -- combined=0 (the strongest-warning, most-conservative reading) rather than refusing the preview.
  begin
    v_stats := public.calculate_group_expedition_stats(v_player, v_group, 'none');
    v_combined := coalesce((v_stats->'totals'->>'combat_power')::double precision, 0)
                + coalesce((v_stats->'totals'->>'survival')::double precision, 0);
  exception when others then
    v_combined := 0;
  end;
  v_weak := v_combined < coalesce(public.cfg_num('pirate_intercept_stat_reference'), 120);

  -- Need a current fleet position for leg 1's origin — the SAME fleet_current_position leaf every
  -- reader composes (S3, 0218); NULL (no fleet yet / not resolvable) makes leg 1 unpreviewable and
  -- the preview degrades to "unknown", never a guess.
  v_ox := null; v_oy := null;
  select o_x, o_y into v_ox, v_oy
    from public.fleets f, public.fleet_current_position(f.id)
   where f.group_id = v_group and f.player_id = v_player and f.main_ship_id is null
     and f.status in ('idle', 'moving', 'present', 'returning')
   limit 1;

  if p_waypoints is not null and jsonb_typeof(p_waypoints) = 'array' then
    v_n := jsonb_array_length(p_waypoints);
  else
    v_n := 0;
  end if;

  -- walk the plotted legs: waypoints in order, then the final target.
  for v_i in 0 .. v_n loop
    if v_ox is null or v_oy is null then
      exit; -- unknown origin: stop previewing rather than guess a leg.
    end if;
    if v_i < v_n then
      v_tx := (p_waypoints->v_i->>'x')::double precision;
      v_ty := (p_waypoints->v_i->>'y')::double precision;
    else
      if p_target_location_id is not null then
        select l.x, l.y into v_tx, v_ty from public.locations l where l.id = p_target_location_id;
      else
        v_tx := p_target_x; v_ty := p_target_y;
      end if;
    end if;
    if v_tx is null or v_ty is null then
      exit;
    end if;

    select * into v_hit
      from public.pirate_intercept_leg_zone_hits(v_ox, v_oy, v_tx, v_ty)
     order by exposure_fraction desc, zone_id asc
     limit 1;

    if found then
      v_any := true;
      v_legs := v_legs || jsonb_build_array(jsonb_build_object(
        'leg_index', v_i, 'crosses', true, 'zone_id', v_hit.zone_id, 'location_id', v_hit.location_id,
        'exposure_fraction', v_hit.exposure_fraction,
        'risk', public.pirate_intercept_compute_risk(v_combined, v_hit.exposure_fraction)));
    else
      v_legs := v_legs || jsonb_build_array(jsonb_build_object('leg_index', v_i, 'crosses', false));
    end if;

    v_ox := v_tx; v_oy := v_ty;
  end loop;

  return jsonb_build_object(
    'ok', true, 'group_id', v_group, 'crosses_danger', v_any, 'weak_fleet', v_weak,
    'combined_stats', v_combined, 'legs', v_legs);
end;
$$;

revoke all on function public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision) from public;
grant execute on function public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision) to authenticated;

comment on function public.pirate_intercept_preview_route(uuid, jsonb, uuid, double precision, double precision) is
  'PIRATE INTERCEPT: read-only advisory — walks a proposed route (waypoints + final target) and '
  'reports, per leg, whether it crosses an active danger_zone and the stat-scaled risk, plus '
  'weak_fleet (combined stats below the reference) for a stronger client warning. DARK behind '
  'pirate_intercept_enabled. NO writes, no lock — MVCC read only.';

-- ── 14. get_danger_zones — read RPC for client rendering (vertex rings, not raw PostGIS binary) ──
create or replace function public.get_danger_zones()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', z.id, 'name', z.name, 'source', z.source, 'location_id', z.location_id,
    'ring', (
      select jsonb_agg(jsonb_build_array(ST_X(pt.geom), ST_Y(pt.geom)) order by pt.path[1])
        from ST_DumpPoints(ST_ExteriorRing(z.boundary)) as pt
    )
  )), '[]'::jsonb)
  from public.danger_zones z
  where z.status = 'active' and public.cfg_bool('pirate_intercept_enabled')
$$;

revoke all on function public.get_danger_zones() from public;
grant execute on function public.get_danger_zones() to anon, authenticated;

comment on function public.get_danger_zones() is
  'PIRATE INTERCEPT: read-only zone boundaries as plain [x,y] vertex rings (never a PostGIS wire '
  'type) for client rendering. DARK-FIRST: returns [] while pirate_intercept_enabled is false.';

-- ── 15. pirate_zone_create — the owner draw-editor''s save RPC (prototype: no admin-role gate) ───
create or replace function public.pirate_zone_create(
  p_name        text,
  p_vertices    jsonb,
  p_location_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_n      integer;
  v_i      integer;
  v_x      double precision;
  v_y      double precision;
  v_pts    geometry[];
  v_poly   geometry;
  v_loc    record;
  v_id     uuid;
  c_lo constant double precision := -10000;
  c_hi constant double precision :=  10000;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'pirate_intercept_disabled');
  end if;
  if p_name is null or char_length(btrim(p_name)) < 1 or char_length(btrim(p_name)) > 60 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;
  if p_vertices is null or jsonb_typeof(p_vertices) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_vertices');
  end if;
  v_n := jsonb_array_length(p_vertices);
  if v_n < 3 or v_n > 64 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_vertex_count');
  end if;

  v_pts := array[]::geometry[];
  for v_i in 0 .. v_n - 1 loop
    v_x := (p_vertices->v_i->>0)::double precision;
    v_y := (p_vertices->v_i->>1)::double precision;
    if v_x is null or v_y is null
       or v_x = 'NaN'::double precision or v_x = 'Infinity'::double precision or v_x = '-Infinity'::double precision
       or v_y = 'NaN'::double precision or v_y = 'Infinity'::double precision or v_y = '-Infinity'::double precision
       or v_x < c_lo or v_x > c_hi or v_y < c_lo or v_y > c_hi then
      return jsonb_build_object('ok', false, 'reason', 'invalid_vertex_point');
    end if;
    v_pts := v_pts || ST_MakePoint(v_x, v_y);
  end loop;
  v_pts := v_pts || v_pts[1]; -- close the ring

  v_poly := ST_MakePolygon(ST_MakeLine(v_pts));
  if v_poly is null or not ST_IsValid(v_poly) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_polygon');
  end if;

  if p_location_id is not null then
    select l.id into v_loc from public.locations l
     where l.id = p_location_id and l.status = 'active' and l.location_type in ('pirate_hunt', 'pirate_den');
    if v_loc.id is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_location');
    end if;
  end if;

  insert into public.danger_zones (name, zone_kind, source, location_id, boundary, created_by)
  values (btrim(p_name), 'pirate', 'drawn', p_location_id, v_poly::geometry(Polygon), v_player)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'zone_id', v_id, 'standalone', p_location_id is null);
end;
$$;

revoke all on function public.pirate_zone_create(text, jsonb, uuid) from public;
grant execute on function public.pirate_zone_create(text, jsonb, uuid) to authenticated;

comment on function public.pirate_zone_create(text, jsonb, uuid) is
  'PIRATE INTERCEPT: the draw-editor''s save RPC. p_vertices is an ordered [[x,y],...] ring (3-64 '
  'points); optionally attaches to an existing active pirate_hunt/pirate_den location for live combat, '
  'or stands alone (location_id NULL — geometry/warning only, see the file header stub). PROTOTYPE: no '
  'admin-role gate — any authenticated caller may draw while the flag is lit.';

-- ── 16. pirate_zone_delete — owner cleanup (created_by-scoped; drawn zones only) ──────────────────
create or replace function public.pirate_zone_delete(p_zone_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_n      integer;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'pirate_intercept_disabled');
  end if;
  delete from public.danger_zones
   where id = p_zone_id and source = 'drawn' and created_by = v_player;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'zone_not_found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.pirate_zone_delete(uuid) from public;
grant execute on function public.pirate_zone_delete(uuid) to authenticated;

comment on function public.pirate_zone_delete(uuid) is
  'PIRATE INTERCEPT: deletes a caller-drawn zone (source=''drawn'' AND created_by=caller only — a '
  'seeded ''circle'' zone can never be deleted through this RPC).';

-- ── 17. self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ────────
do $piassert$
declare
  v_mover text;
  v_n     integer;
  v_probe jsonb;
begin
  -- (a) the flag + knobs are seeded, and the flag's value is FALSE (a fresh seed — not asserting the
  --     literal value on a re-run, only that the row exists, mirroring the house 0219 idiom).
  if (select count(*) from public.game_config where key in (
        'pirate_intercept_enabled', 'pirate_intercept_base_risk', 'pirate_intercept_stat_reference',
        'pirate_intercept_min_risk', 'pirate_intercept_max_risk', 'pirate_intercept_exposure_floor',
        'pirate_route_max_waypoints')) <> 7 then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: a config seed is missing';
  end if;

  -- (b) every new function exists with the right client-callable / internal-only ACL split.
  if to_regprocedure('public.pirate_intercept_leg_zone_hits(double precision,double precision,double precision,double precision)') is null
     or to_regprocedure('public.pirate_intercept_compute_risk(double precision,double precision)') is null
     or to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null
     or to_regprocedure('public.command_ship_group_go_route(uuid,jsonb,uuid,double precision,double precision)') is null
     or to_regprocedure('public.process_pirate_route_legs()') is null
     or to_regprocedure('public.pirate_intercept_preview_route(uuid,jsonb,uuid,double precision,double precision)') is null
     or to_regprocedure('public.get_danger_zones()') is null
     or to_regprocedure('public.pirate_zone_create(text,jsonb,uuid)') is null
     or to_regprocedure('public.pirate_zone_delete(uuid)') is null
     or to_regprocedure('public.command_ship_group_cancel_route(uuid)') is null then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: a new function did not land';
  end if;
  if has_function_privilege('authenticated', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute')
     or has_function_privilege('anon', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_intercept_leg_zone_hits(double precision,double precision,double precision,double precision)', 'execute') then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: an internal leaf leaked onto the client surface';
  end if;
  if not has_function_privilege('authenticated', 'public.command_ship_group_go_route(uuid,jsonb,uuid,double precision,double precision)', 'execute')
     or not has_function_privilege('authenticated', 'public.pirate_intercept_preview_route(uuid,jsonb,uuid,double precision,double precision)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_danger_zones()', 'execute')
     or not has_function_privilege('authenticated', 'public.pirate_zone_create(text,jsonb,uuid)', 'execute') then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: a client-facing RPC lost its authenticated execute grant';
  end if;

  -- (c) DARK-FIRST PROOF: with the flag freshly seeded false, the trigger leaf is a hard no-op even
  --     against a movement id that does not exist — proving the gate is the FIRST statement (no read
  --     happens before it; a real read would return not_moving/not found some OTHER way, not 'dark').
  v_probe := public.pirate_intercept_evaluate_leg('00000000-0000-0000-0000-000000000000'::uuid);
  if (v_probe->>'hit')::boolean is not false or v_probe->>'reason' <> 'dark' then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: the trigger leaf is not a true no-op while dark (got %)', v_probe;
  end if;
  if (select count(*) from public.pirate_intercepts) <> 0 then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: the dark-world probe above wrote an audit row — it must gate before ANY write';
  end if;
  -- process_pirate_route_legs returns an integer (a row count), not jsonb.
  if (select public.process_pirate_route_legs()) <> 0 then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: process_pirate_route_legs is not a 0-row no-op while dark';
  end if;
  if public.get_danger_zones() <> '[]'::jsonb then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: get_danger_zones is not empty while dark';
  end if;

  -- (d) command_ship_group_go PARITY: every 0219-head token survives the re-create (a spot-check,
  --     not the house's full order-pin — proportionate to a prototype slice touching an already
  --     heavily-guarded function) + the ONE new hunk is present and placed AFTER fleet_set_moving.
  select prosrc into v_mover from pg_proc
   where oid = 'public.command_ship_group_go(uuid,uuid,double precision,double precision)'::regprocedure;
  if position('unified_movement_disabled' in v_mover) = 0
     or position('combat_destination' in v_mover) = 0
     or position('timed_docking_enabled' in v_mover) = 0
     or position('movement_position_at' in v_mover) = 0
     or position('member_busy' in v_mover) = 0
     or position('group_on_sortie' in v_mover) = 0
     or position('fleet_ambiguous' in v_mover) = 0
     or position('movement_create(' in v_mover) = 0 then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: a pre-existing command_ship_group_go token vanished — the re-create broke parity';
  end if;
  if position('pirate_intercept_evaluate_leg(v_movement)' in v_mover) = 0 then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: the intercept hunk did not land in command_ship_group_go';
  end if;
  if position('fleet_set_moving(v_fleet, v_movement)' in v_mover) > position('pirate_intercept_evaluate_leg(v_movement)' in v_mover) then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: the intercept hunk fires BEFORE fleet_set_moving — it must roll against a COMMITTED leg';
  end if;

  -- (e) danger_zones seeded class-complete (vacuity: the probed class must exist).
  select count(*) into v_n from public.locations where location_type in ('pirate_hunt', 'pirate_den') and territory_radius is not null;
  if v_n = 0 then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: no territory-bearing hostile rows — the circle-zone seed sweep would be vacuous';
  end if;
  select count(*) into v_n from public.danger_zones where source = 'circle';
  if v_n <> (select count(*) from public.locations where location_type in ('pirate_hunt', 'pirate_den') and territory_radius is not null and status = 'active') then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: circle-zone seed count does not match the territory-bearing active hostile rows';
  end if;
  -- every seeded circle zone must actually be a valid, non-empty polygon (ST_Buffer of a real point).
  if exists (select 1 from public.danger_zones where source = 'circle' and (not ST_IsValid(boundary) or ST_Area(boundary) <= 0)) then
    raise exception 'PIRATE-INTERCEPT self-assert FAIL: a seeded circle zone is not a valid, positive-area polygon';
  end if;

  raise notice 'PIRATE-INTERCEPT self-assert ok: flag+knobs seeded, ACL split correct, dark-first no-op proven (leaf/cron/zones-read/audit-log), command_ship_group_go parity + hunk placement pinned, circle-zone seed class-complete and geometrically valid';
end $piassert$;
