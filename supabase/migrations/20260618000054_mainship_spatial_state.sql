-- Byeharu — OSN-2a: durable open-space position model (SCHEMA ONLY — no behavior).
--
-- Adds the storage + invariants for a future "stopped in open space" main-ship position onto
-- main_ship_instances (the persistent, per-ship, owner-read row chosen as the single authoritative
-- owner of a durable open-space coordinate). This pass adds NO reader, resolver, RPC, UI, flag, or
-- gameplay behavior. The OSN-1 marker resolver does NOT yet read these columns.
--
-- MIGRATION SAFETY — nullable legacy approach (do NOT back-fill):
--   spatial_state is NULLABLE with NO default. Existing ships are deliberately NOT back-filled to
--   'home' — that would write FALSE spatial data for any ship currently traveling / returning /
--   present at a location / destroyed. Existing rows therefore stay:
--       spatial_state = NULL, space_x = NULL, space_y = NULL
--   meaning "legacy: spatial state not yet explicitly normalized; current position remains governed
--   ENTIRELY by the existing verified base / fleet / movement / presence model." A later, explicit
--   reconciliation/migration MAY normalize legacy rows and add NOT NULL — that is NOT part of OSN-2a.
--
-- WRITE OWNERSHIP: these columns are writable only by FUTURE OSN-3/4 SECURITY DEFINER server RPCs,
--   which must always set a truthful non-null spatial_state. OSN-2a adds no write path. No functions
--   are created here, so NO execute-surface relock is needed (the relock pattern only applies when a
--   new function default-grants to PUBLIC). RLS / grants on main_ship_instances are UNCHANGED
--   (owner-read SELECT only; no client write).
--
-- INVARIANTS encoded (NULL-safe):
--   • space_x and space_y are BOTH null or BOTH non-null;
--   • non-null coordinates exist IFF spatial_state = 'in_space';
--   • spatial_state = 'in_space' REQUIRES both coordinates (no in_space without a point);
--   • spatial_state IS NULL (legacy) REQUIRES both coordinates null;
--   • every other state (home / at_location / in_transit / destroyed) has null coordinates
--     → destroyed retains NO coordinate; no activity meaning is attached to in_space;
--   • when coordinates are present, both must be FINITE — NaN and ±Infinity are rejected
--     (double precision can represent them). No world min/max bounds are imposed in this pass.

alter table public.main_ship_instances
  add column spatial_state text,
  add column space_x       double precision,
  add column space_y       double precision;

-- Domain: NULL (legacy) OR exactly one of the five explicit spatial modes.
alter table public.main_ship_instances
  add constraint main_ship_instances_spatial_state_domain
  check (
    spatial_state is null
    or spatial_state in ('home', 'at_location', 'in_transit', 'in_space', 'destroyed')
  );

-- Coordinate pairing + gating + finiteness. Written with `is [not] distinct from` so a NULL
-- spatial_state evaluates to a concrete TRUE/FALSE (never an unknown that a CHECK would silently
-- pass):
--   1) pairing            : (space_x is null) = (space_y is null)
--   2) coords ⇒ in_space  : space_x is null OR spatial_state IS NOT DISTINCT FROM 'in_space'
--   3) in_space ⇒ coords  : spatial_state IS DISTINCT FROM 'in_space' OR space_x is not null
--   4) finite-only        : when present, each coordinate is neither NaN nor ±Infinity.
-- Together: coordinates are present exactly when spatial_state = 'in_space'; in every other state
-- (incl. NULL legacy) both coordinates must be null; and a present coordinate must be a real finite
-- number. (No world min/max bounds in this pass — that is a future writer's concern.)
--
-- Finiteness uses `<>` against the typed special-value literals. In PostgreSQL, `'NaN'::double
-- precision = 'NaN'::double precision` is TRUE (NaN is not IEEE-unordered here), so `x <> 'NaN'`
-- returns FALSE for a NaN value → the CHECK fails → NaN is rejected; ±Infinity reject via ordinary
-- inequality. (`'NaN'::double precision` is the cast form; the `double precision 'NaN'` typed-literal
-- form is NOT valid for multi-word type names, so the cast form is used.)
alter table public.main_ship_instances
  add constraint main_ship_instances_space_coords
  check (
        (space_x is null) = (space_y is null)
    and (space_x is null or spatial_state is not distinct from 'in_space')
    and (spatial_state is distinct from 'in_space' or space_x is not null)
    and (space_x is null or (space_x <> 'NaN'::double precision
                             and space_x <> 'Infinity'::double precision
                             and space_x <> '-Infinity'::double precision))
    and (space_y is null or (space_y <> 'NaN'::double precision
                             and space_y <> 'Infinity'::double precision
                             and space_y <> '-Infinity'::double precision))
  );

comment on column public.main_ship_instances.spatial_state is
  'OSN-2 spatial-mode SELECTOR (separate axis from status). NULL = legacy / not-yet-normalized: '
  'position is governed by the existing base/fleet/movement/presence model. Non-null: '
  'home|at_location|in_transit|in_space|destroyed. Raw space_x/space_y are stored ONLY when '
  'in_space. Writable only by future OSN-3/4 server RPCs; no client write path.';
comment on column public.main_ship_instances.space_x is
  'OSN-2 open-space X (world coords, double precision). Non-null IFF spatial_state = ''in_space''.';
comment on column public.main_ship_instances.space_y is
  'OSN-2 open-space Y (world coords, double precision). Non-null IFF spatial_state = ''in_space''.';
