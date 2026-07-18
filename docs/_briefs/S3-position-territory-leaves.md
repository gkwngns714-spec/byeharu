# S3 POSITION + TERRITORY leaves — grounded brief (banked 2026-07-18)

Lands at migration ≥0218 (after S2's 0217). Serializes behind S2 (needs
`locations.territory_radius`). One migration: 3 new leaves + PARITY re-create of the mover + brake.

## The census (the "3x" is really 2 live copies to fold)
FOLD TARGET — byte-identical math, both live-relevant:
- Mover redirect TRUE HEAD `supabase/migrations/20260618000208_fleetgo_coordinate_targets.sql:420-424`
  (lvalues v_o_x/v_o_y, 4-space indent).
- Brake TRUE HEAD `20260618000215_fleetgo_brake_sortie.sql:155-159` (lvalues v_x/v_y). Verified
  byte-identical expression to the mover — same denom, nullif, clamp, coalesce(v_t,0). No drift.
DO NOT FOLD / DO NOT TOUCH (different formula, dark post-flip, retire at step 4):
- Legacy per-ship stop family divides by `travel_seconds` NOT (arrive-depart): 0149:109-111,
  0152:390-392, 0155:116-118.
- OSN space-stop family (different spine, unguarded one-line clamp): 0064:303-306, 0067:790-793.
- Superseded ancestors (shipped history, never edit): 0207:251-255, 0209:111-115.

## The 3 leaves (two-layer: pure math + state dispatch)
1. `movement_position_at(origin_x,origin_y,target_x,target_y,depart_at,arrive_at,p_at) OUT o_x,o_y`
   — `language sql IMMUTABLE STRICT` (must NOT read tables), the ONE interpolation authority,
   mirrors client `interpolateMovementPoint`. Body:
   `t = clamp01(coalesce(extract(epoch from (p_at-p_depart))/nullif(extract(epoch from
   (p_arrive-p_depart)),0),0)); o = origin + t*(target-origin)`. Grant: revoke public/anon/authed,
   grant service_role (osn_distance idiom 0099:305-306). Scalar args (callers hold `v_mv record`).
2. `fleet_current_position(p_fleet_id, p_at default now()) OUT o_x,o_y` — `plpgsql STABLE SECURITY
   DEFINER`, both NULL = fail closed. Dispatch (mirror mover 0208:409-461): (1) active_movement_id +
   fleet_movements.status='moving' → movement_position_at; (2) location_mode='space' → space_x/space_y;
   (3) status='present' + current_location_id → locations.x/y; (4) current_base_id (location_mode
   'base') → bases.x/y; (5) else NULL. No lock (read leaf). service_role grant.
3. `fleet_in_territory(p_fleet_id, p_at default now()) returns uuid` (containing location id, NULL=open)
   — `sql STABLE SECURITY DEFINER`. Composes fleet_current_position + osn_distance + territory_radius;
   `where pos.o_x is not null and osn_distance(pos, l) <= l.territory_radius and l.status='active' and
   l.territory_radius is not null order by l.territory_radius asc, l.id asc limit 1`. Tiebreak MUST
   mirror client `territoryAt` (S2 brief:43-45). THE authority S4 dock guard + enemy-spawn compose.

## Parity re-creates (2 marked hunks each)
- `command_ship_group_go` TRUE HEAD 0208:180-586 (0208:178 dropped the 0207 2-arg form; no later
  re-create). Hunks: delete `v_t double precision;` declare (0208:213); replace 0208:420-424 with
  `select o_x,o_y into v_o_x,v_o_y from movement_position_at(v_mv...., v_now)`. Everything else verbatim.
- `command_ship_group_stop` TRUE HEAD 0215:44-193. Hunks: delete v_t declare (0215:58); replace
  0215:155-159 with leaf into v_x,v_y. SORTIE GUARD hunk 0215:104-112 + its scope
  `f.status in ('moving','present','returning')` + ORDER must survive verbatim (fleetgo-proof.sh:168-184
  perl-parses gate→group-lock→gsm-join→group_on_sortie→fleet_ambiguous; activate script:152-157 pins
  group_sortie_members in prosrc).
- The mover/brake in-body gate on `fleet_movement_unified_enabled` (0208:237, 0215:73) survives the
  byte-copy untouched → dark envs stay inert. Since the fold is output-identical, NO new flag needed.
- POINTER DISCIPLINE (0211 lesson): S3 files become new true heads. Repoint fleetgo-proof.sh
  MIGRATION_STOP (:18) to new brake head, add MIGRATION_S3 for mover head, add `TRUE-HEAD DECLARATION`
  markers. New self-assert: pin movement_position_at PRESENT + inline `origin_x + (` lerp ABSENT in both.

## osn_distance (compose, never a 3rd formula)
`20260618000099_...:45-54` — `osn_distance(ax,ay,bx,by) returns double precision sql immutable strict`,
`sqrt(power(bx-ax,2)+power(by-ay,2))`. Grant 0099:305-306 = service_role only → fleet_in_territory
must be SECURITY DEFINER (definer-composition precedent 0104:154, 0172:332).

## Client parity (reviewer's diff, NO client code change in S3)
`src/features/map/movementInterpolation.ts:39-49`: `t=clamp01((nowMs-dep)/(arr-dep)); p=origin+t*(target-
origin)`. Server leaf ≡ this exactly. Edge notes (harmless, don't fix): client returns null when
arr<=dep (server-impossible: check arrive_at>depart_at 0007:45); client fails closed on non-finite.

## fleetgo-proof.* additions
Seed in-flight: go, then `update fleet_movements set depart_at=now()-'30s', arrive_at=now()+'30s'` →
t=0.5 exact (pattern fleetgo-proof.sql:443-450). New markers (+ MARKERS list sh:32 + selftest greps):
- S3_PASS_POSLEAF_MIDPOINT — leaf ≡ (origin+target)/2, exact `is distinct from`, for both
  fleet_current_position + movement_position_at. Vacuity: raise if leg not status='moving'.
- S3_PASS_POSLEAF_AGREEMENT — brake returns space_x/space_y ≡ leaf; redirect new-leg origin ≡ leaf
  (extends sql:778-791; keeps sh:186 grep satisfied).
- S3_PASS_POSLEAF_PARKED/DOCKED — after brake leaf ≡ space_x/space_y; after settled port-go leaf ≡
  locations.x/y.
- S3_PASS_TERRITORY_IN/OUT — go to (l.x+d, l.y) for slag (radius 25); d=10 → fleet_in_territory=l.id,
  d=100 → NULL. Vacuity: RAISE if l.territory_radius NULL (S2 not merged → proof refuses, not greens).
- Static (sh selftest): new-head file exists; movement_position_at composed in BOTH bodies; inline lerp
  absent (use sql_code() stripper sh:30); brake-head order check retargeted.

## Spaghetti verdict
Fold is behaviour-identical (no flag for the fold). fleet_in_territory is new + uncalled = dark by
construction; its consumer (S4) carries the flag — do NOT pre-gate the leaf. Keep the 2-layer split so
movement_position_at stays IMMUTABLE. Don't key on group_id alone (0204:316 trap); don't reuse
zones.radius; readers compose fleet_current_position (no locks), writers keep their own FOR UPDATE +
compose the pure math leaf.
