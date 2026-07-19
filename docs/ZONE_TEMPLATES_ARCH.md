# Zone Framework — Authoritative Architecture

**Status:** AUTHORITATIVE design (read-only audit slice; no game code, no migration in this PR).
**Base:** `origin/main` @ `2518d1f`, plus merged zone slices `0233`–`0238` (verified against code + LIVE prod).
**Supersedes:** `docs/ZONE_TEMPLATES_PLAN.md` (PR #221). That plan's load-bearing claims were re-verified
and are largely correct; this document **incorporates** what holds, **corrects** what the four grounded
audits disproved, and **replaces** its data model with the owner-mandated three-table design + typed
per-kind profiles + the server-authoritative security spine the plan omitted. Where this doc and the plan
disagree, **this doc wins**.

**Non-negotiable laws enforced throughout:** no spaghetti (one authority per concept, compose don't fork,
retire the old), no duplicated map, no client-authoritative gameplay, no hidden-route-as-security, no
arbitrary unvalidated config, no prod activation in this phase.

---

## 0. Executive summary

**What the owner wants:** the dev zone editor becomes a reusable **content-authoring** system. Author a
zone *template* once (a KIND — `pirate_combat` / `mining` / `exploration` — plus a validated per-kind
PROFILE), then *place* it as many polygons across the map, each optionally attached to 0..N locations.
Runtime is fully server-authoritative: position → published+enabled placements → overlap/priority
resolution → template + typed profile → a per-kind handler (explicit registry, no central `if/else`) →
reuse the EXISTING combat/mining/exploration command path → eligibility/cooldown/idempotency → activity
record stamped with zone/template/placement ids.

**Schema (three authorities, plus typed profile tables):** `zone_templates` (WHAT: identity + lifecycle;
`kind` + FK to exactly one typed profile row), `zone_placements` (WHERE: `geometry(Polygon)` SRID 0,
priority, lifecycle, `archived_at`), `zone_placement_locations` (0..N junction). Profiles are **typed
tables per kind** (`zone_profile_pirate_combat`, `zone_profile_mining`, `zone_profile_exploration`) with
a `schema_version` column — **not** an unvalidated jsonb bag. Template reuse (one profile → many polygons)
and location association (one placement → 0..N locations) are DISTINCT relationships (§2).

**Security model (ships FIRST, ahead of features):** owner identity does not exist server-side today —
a dedicated deny-all `app_owners` table + `is_owner()` helper (seeded out-of-git via service_role), every
privileged op behind an owner-gated `SECURITY DEFINER` RPC, RLS SELECT-only on all authoritative tables,
a `zone_authoring_audit` table, and explicit unauthorized-path tests in the `supabase start` apply-proof.
This is UNCONDITIONAL (a guard, never flag-gated) and closes a LIVE prod griefing hole (§7, §8 Slice A).

**Pirate runtime semantics:** trigger = leg departure (`pirate_intercept_evaluate_leg`, the ONE
orchestrator); the ambush handler stamps template overrides onto the just-created `combat_encounters`
row via a single post-create `UPDATE` (both ids already in scope — no threading through frozen
signatures); `process_combat_ticks` reads `coalesce(override, loc.*)` so NULL = byte-identical to today.
No per-zone cooldown/respawn exists today; "respawn" is in-encounter waves; idempotency is one active
encounter per fleet/presence + idempotent `reward_grant` (§5).

**Overlap + priority:** different kinds coexist only if handlers declare compatible; same-kind
highest-priority-enabled wins; equal-priority same-kind **fails validation deterministically**; boundary
inclusion rule is fixed and tested (§6).

**Doability verdict per kind:** `pirate_combat` — HIGH confidence, the engine is already fully
parameterized; the only real work is the override stamp + a co-required fix to a **live latent blocker**
(the `combat_units` unique constraint that stalls any wave with ≥2 pirates today). `mining` — READY, and
NOT dark (prod `mining_enabled=true`, extract path proven live); medium effort (polygon→field seeder +
link + validation). `exploration` — LEAST ready; dark end-to-end and never proven in prod; build LAST,
after lighting and proving the base system.

**Top owner decisions (all with safe defaults, §10):** (1) standalone combat zones — default: require
≥1 hostile location attach for v1 (no auto-mint). (2) `danger_zones` fate — default: rename to
`zone_placements` with a `danger_zones` compat view. (3) tier→difficulty mapping — default: a small
`zone_tier_difficulty` config table. (4) per-placement vs per-template override — default: per-template.
(5) profile carrier — default: typed tables (owner-mandated). (6) same-kind equal-priority — default:
fail validation.

**PR for this document:** branch `docs-zone-arch`, PR opened via `gh` (number recorded at the end of this
file's delivery message). DOC ONLY — no game code, no migration touched.

---

## 1. Code-grounded audit summary (the ground truth)

Everything below is verified against `origin/main` migrations and LIVE prod `game_config`/`SELECT` state.
Two unrelated tables both say "zone" — this collision pervades the subsystem and MUST be respected:

- **`public.zones`** — the WORLD HIERARCHY (sectors → zones → locations), surfaced by `get_world_map`
  (`20260618000217_territory_radius.sql:48-90`, nested `zones` → `locations` with
  `x/y/radius/base_difficulty/reward_tier`). **This table already exists.** A new `zones` view or table
  WOULD COLLIDE — the new "placement" table must NOT be named `zones`.
- **`public.danger_zones`** — the independent PostGIS polygon table (below). A "placement" maps onto this.

The client map merges TWO reads: **locations** from `get_world_map` + **polygons** from `get_danger_zones`.

### 1.1 Map / geometry
`public.danger_zones` (`20260618000233_pirate_intercept_danger_zones.sql:182-198`): `id`, `name`
(btrim 1-60), `zone_kind text default 'pirate' CHECK(in ('pirate'))` — a **single-value domain**,
`source text CHECK(in ('circle','drawn'))`, `location_id uuid FK locations ON DELETE CASCADE` — a
**single nullable** attach, `boundary geometry(Polygon) NOT NULL`, `status text CHECK(in ('active',
'inactive'))`, `created_by uuid`, timestamps, plus `CHECK(source<>'circle' OR location_id is not null)`.
Indexes: `gist(boundary)`, partial btree on `location_id`. RLS: SELECT policy `danger_zones_select_when_lit`
`USING (status='active' AND cfg_bool('pirate_intercept_enabled'))`, grant SELECT to anon+authenticated;
**no write policy, no write grant** — writes are RPC-only (the correct posture).

**CANONICAL GEOMETRY CONTRACT (load-bearing — any new geometry table MUST reproduce it or silently break
the intercept engine and the renderer):** `boundary geometry(Polygon)` with **SRID 0**
(`0233:188`; prod-verified `ST_SRID=0`). SRID 0 is deliberate — this is a flat Cartesian game grid,
world-units, bounds ±10000 (the `c_lo/c_hi` guards at `0233:1417-1418`, `command_ship_group_go`
`0233:638-639`). A geographic SRID (e.g. 4326) would corrupt every `ST_Intersects`/`ST_Length`/`ST_Distance`
exposure calc. Ring idiom: `ST_MakePolygon(ST_MakeLine(pts))` from an ordered `[x,y]` array, closed by
repeating vertex 1, gated on `ST_IsValid` (`0233:1449-1453`; slime `0237:101-113`). Client exchange is
NEVER PostGIS wire binary — always `[[x,y],…]` exterior-ring pairs via `ST_DumpPoints(ST_ExteriorRing(
boundary))` ordered by `path[1]` (`0233:1382-1383`), already-closed. A `gist` index on `boundary` is
required for the scan. **The quartet every placement table must reproduce: `geometry(Polygon)` + SRID 0
+ `ST_IsValid` ring + gist index.**

**PROD (SELECT-verified):** 3 zones Reaver / Snare / Blackden, all `source='circle'`, `zone_kind='pirate'`,
`status='active'`, `created_by=null`, SRID 0, `ST_Polygon`, npoints 13/20/15 (reshaped by slime `0237`,
NOT a 32-seg buffer). Each links to an active `pirate_hunt` location sharing `territory_radius=36` but
`base_difficulty` 15/10/25 and `reward_tier` 2/1/3.

### 1.2 Combat (the pirate kind's runtime)
- Trigger chain: `pirate_intercept_evaluate_leg` (`0233:377-527`) is the **ONE** trigger. On a hit it holds
  `v_hit.zone_id` AND `v_hit.location_id` in one transaction, composes `fleet_set_present(:499)` → freeze
  `group_sortie_members(:505-509)` → `presence_create('hunt_pirates')(:513)` → (down the frozen chain) →
  `combat_create_group_encounter`, then re-reads the created encounter id into `v_enc` at `0233:515`.
- `pirate_intercept_leg_zone_hits` (`0233:292`) is the ONE geometry leaf; returns a SINGLE
  `zone_id`+`location_id`+`exposure_fraction`+ambush `x/y` per hit, `order by exposure_fraction desc,
  zone_id asc limit 1` (`0233:428`) — an emergent geometric tiebreak, **no authorable precedence today**.
- **Difficulty lives on the LOCATION, not the zone:** `process_combat_ticks` (head
  `20260618000234_combat_spatial_tick.sql:433-1142`) reads `loc.base_difficulty`/`reward_tier`/
  `max_presence_seconds` at `0234:566`. Enemy HP `0234:690`, attack `0234:692`, count
  `N=least(enemy_synthetic_max_units[6], greatest(1,danger))` `0234:694`, range `0234:696`, speed
  `0234:698`; aggregate-arm mirror at `0234:964,981`; reward metal `0234:898,1074`. Every stat is a pure,
  fully-parameterized function of `base_difficulty`/`reward_tier` + `game_config` knobs.
- **CORRECTION to PR #221:** `combat_create_group_encounter` (`0234:276-429`) hardcodes `danger_level=1`,
  spawns ONLY player units, reads NEITHER `base_difficulty` NOR `reward_tier`, and spawns NO enemies. So
  the override is **ONE** function edit (`process_combat_ticks`), **not two spawn sites**.
- `0236` is a pure `game_config` risk retune (`[0.98,1.0]`), no structural change.
- **LIVE prod flags:** `spatial_combat_enabled=TRUE`, `pirate_intercept_enabled=TRUE`,
  `dev_zone_editor_enabled=TRUE`.

### 1.3 Mining (NOT dark — corrects PR #221 and the task premise)
Mining is **BUILT and LIVE** end-to-end in prod: `mining_enabled=true`, `mining_extract_radius=60`
(retuned DOWN from the 750 seed), `mining_extract_cooldown_seconds=300`, `world_balance_enabled=false`.
Chain, all proximity-based and completely zone-agnostic:
- `mining_fields` (`20260618000103:73-90`): `id`, `name` unique, `space_x/space_y` (finite, ±10000),
  `reward_bundle_json` (items-only `{"items":[{item_id,quantity}]}`), `is_active` default true. Migration-
  seeded static world data (5 fields), **no runtime writer**, RLS on with no client grant. **The only
  per-field payload is `reward_bundle_json` — there are NO richness/depletion/regen/reward columns.**
- `command_mining_extract` / `mining_extract` (`0104`): dark-gate-first, ship lock, ownership from locked
  snapshot, nearest `is_active` field within `mining_extract_radius` by `osn_distance` tie-broken by name,
  per-(player,field) cooldown, accrues ONE pending `mining_extractions` row — never deposits.
- `process_mining_securing` (`0105`): deposits via `reward_grant('mining', extraction_id, …)` when the
  ship is settled safe; idempotent by `reward_grants UNIQUE(source_type,source_id)`.
- `get_active_mining_fields` (`0226`): the LIVE client map read (name + coords of active fields only).
- Depletion/regen is a SEPARATE dark World-State layer (`0137` `mining_field_state.reserve_fraction`,
  gated on `world_balance_enabled=false` → never run live). The flag `module_range_attributes` claimed by
  the task **does not exist anywhere** in the repo; there is no module-based mining eligibility.

### 1.4 Exploration (genuinely dark)
`exploration_sites` (`20260618000098`): twin of mining (`space_x, space_y, reward_bundle_json, is_active`),
plus `exploration_discoveries UNIQUE(player_id, site_id)` (one-shot). Discovered by `command_scan` (`0099`)
proximity. Flag `exploration_enabled=false` — **dark end-to-end and never proven in prod.** A zone layer on
an unvalidated base is spaghetti-risk; build LAST.

### 1.5 Auth (the security spine — nothing exists)
**Owner identity server-side = NOTHING.** No owner role, no `is_owner`/admin flag, no owner uuid, no
JWT/`app_metadata` claim. `profiles` is exactly `{id, email, display_name, created_at}`
(`20260616000001_init_profiles.sql:5-10`) — **no privilege column**, and it has a player-writable
UPDATE policy `profiles_update_own` `with check (auth.uid()=id)` (`:17-20`). The only privileged principal
is Supabase's `service_role` secret (CI/cron). Server-side, the "owner" is indistinguishable from any
authenticated player.

- The hidden route is NOT authz: `RequireAuth` (`src/app/RequireAuth.tsx:7-33`) only checks a session
  exists; `/dev/zones` (`src/app/App.tsx:46-51`) is wrapped in `RequireAuth` only; `dev_zone_editor_enabled`
  (`0238`) governs the CLIENT SURFACE ONLY (its own header says "no server function reads it").
- **THE REAL, LIVE GAP:** `pirate_zone_create` (`0233:1399+`, `SECURITY DEFINER`, grant execute to
  `authenticated`) gates on ONLY `auth.uid() is not null` + `cfg_bool('pirate_intercept_enabled')`. Its own
  comment: *"PROTOTYPE: no admin-role gate."* `pirate_zone_delete` is `created_by`-scoped. Because
  `pirate_intercept_enabled=TRUE` in prod, **any logged-in player can POST `/rest/v1/rpc/pirate_zone_create`
  and insert arbitrary hostile polygons over other players' routes right now** — and because delete is
  `created_by`-scoped, an attacker's zones persist against everyone (even the owner can't remove them via
  RPC). Exploitable today, not theoretical.

### 1.6 Deploy / apply-proof
- `deploy-migrations.yml` triggers on push to `main` touching `supabase/migrations/**`; the job is attached
  to the PROTECTED `production` GitHub Environment, which HALTS for a required-reviewer approval before
  `supabase db push --include-all`. That environment approval IS the production authorization record and is
  explicitly NOT implied by PR merge. Owner approves via `scripts/approve-deploy.sh --yes` (the assistant is
  blocked by its safety classifier; the owner runs it).
- Apply-proof net (memory *CI apply-proof is the net*): a standalone disposable-matrix workflow
  (`danger-combat-proof.yml` / `combat-spatial-proof.yml` precedent) with NO `environment:` runs
  `supabase start`, applying the WHOLE chain to real local Postgres — executing each migration's self-assert
  against live PG and running scenario tests. Static DB-free selftest misses vacuous asserts and
  constraint-coupling bugs; the apply-proof catches them. **All new self-asserts + unauthorized-path
  scenarios go HERE.**

---

## 2. Final schema (owner-mandated three tables + typed profiles)

Design law: **two concepts kept separate.** A template is *definition* (WHAT gameplay); a placement is
*geometry + lifecycle* (WHERE); the junction is *0..N location edges*. Template reuse and location
association are DISTINCT relationships and never conflated. Profiles are **typed per-kind tables**, not a
generic jsonb bag — the owner spec prefers typed/schema-validated config, and the audits confirm each kind's
knobs are disjoint and finite.

All new tables reproduce the house write posture (§1.5, §7): RLS ON, SELECT-only + dark/owner-scoped
policies, NO client write grant, mutation exclusively through owner-gated `SECURITY DEFINER` RPCs.

### 2.1 `zone_templates` — WHAT (identity + lifecycle + kind)
```
create table public.zone_templates (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,                     -- stable authoring handle, e.g. 'reaver-tier2'
  name         text not null check (btrim(name) <> '' and length(name) <= 80),
  description  text,
  kind         text not null check (kind in ('pirate_combat','mining','exploration')),
  -- lifecycle: draft config is authored freely; publish is an atomic promotion; enable is separate.
  published    boolean not null default false,           -- draft(false) vs published(true) config
  enabled      boolean not null default false,           -- runtime kill-switch (separate from publish)
  revision     integer not null default 1,               -- bumped on each publish (audit/restore key)
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  archived_at  timestamptz                               -- prefer archive over delete
);
create index on public.zone_templates (kind) where archived_at is null;
```
Conventions matched: `text CHECK` domains (like `danger_zones.zone_kind`/`source`), `created_by uuid FK
auth.users ON DELETE SET NULL` (`0233:190`), `timestamptz default now()`. The `kind` CHECK replaces the
single-value `zone_kind CHECK(in ('pirate'))` — `'pirate'` maps to `'pirate_combat'`.

### 2.2 Typed per-kind profiles (one row per template; FK back to it)
Exactly one profile row per template, of the table matching its `kind`. Each carries `schema_version` so a
knob added later is a versioned migration, never a silent reinterpretation of an untyped bag. A DEFERRABLE
guard (self-assert in the migration + the write RPC) enforces "a published template has exactly one profile
row of the matching kind."

```
-- kind = 'pirate_combat'
create table public.zone_profile_pirate_combat (
  template_id      uuid primary key references public.zone_templates(id) on delete cascade,
  schema_version   integer not null default 1,
  difficulty_source text not null default 'location'
                     check (difficulty_source in ('location','template')),  -- 'location' = inherit = today
  tier             integer check (tier >= 1),          -- authoring handle → base_difficulty via config map
  base_difficulty  double precision check (base_difficulty > 0),  -- explicit override (0 = 0-hp pirates → reject)
  reward_tier      integer check (reward_tier >= 1),
  max_units        integer not null default 1 check (max_units between 1 and 6),  -- >1 BLOCKED until §5 fix
  -- future (net-new plumbing, NULL/unused in v1): spawn_probability, cooldown_seconds, loot_pool
  check (difficulty_source = 'location'
         or (base_difficulty is not null or tier is not null))   -- template mode needs a difficulty source
);

-- kind = 'mining'
create table public.zone_profile_mining (
  template_id     uuid primary key references public.zone_templates(id) on delete cascade,
  schema_version  integer not null default 1,
  field_count     integer not null check (field_count between 1 and 64),
  richness        double precision not null default 1.0 check (richness > 0),  -- scales ore_mix quantities
  radius_override integer check (radius_override > 0),   -- optional per-zone extract radius (else global 60)
  created_at      timestamptz not null default now()
);
create table public.zone_profile_mining_ore (   -- ore_mix: item pool for a mining profile (validated vs catalog)
  template_id uuid not null references public.zone_profile_mining(template_id) on delete cascade,
  item_id     text not null,                     -- must exist in the item catalog (0039); RPC-validated
  weight      integer not null check (weight > 0),
  primary key (template_id, item_id)
);

-- kind = 'exploration'  (built LAST; base system must be proven first)
create table public.zone_profile_exploration (
  template_id  uuid primary key references public.zone_templates(id) on delete cascade,
  schema_version integer not null default 1,
  site_count   integer not null check (site_count between 1 and 64),
  metal_min    integer not null default 0 check (metal_min >= 0),
  metal_max    integer not null check (metal_max >= metal_min)
);
create table public.zone_profile_exploration_pool (
  template_id uuid not null references public.zone_profile_exploration(template_id) on delete cascade,
  item_id     text not null,
  weight      integer not null check (weight > 0),
  primary key (template_id, item_id)
);
```
Why typed tables, not jsonb: (1) DB-enforced validation (CHECK + FK-to-catalog) instead of trusting an RPC
to re-validate a bag on every read; (2) `schema_version` makes evolution explicit; (3) disjoint kinds →
no sparse 2/3-NULL row. This directly satisfies the owner mandate "prefer typed tables or strictly-versioned
schema-validated config over an unvalidated generic jsonb bag." `item_id` weight lists are their own child
tables so each row is FK-validatable against the item catalog (`0039`).

### 2.3 `zone_placements` — WHERE (geometry + lifecycle + priority)
This is the generalized successor to `danger_zones`. Recommended path (§10 D2): **rename**
`danger_zones` → `zone_placements` with a `danger_zones` compat view so `0233`'s RLS/reads/`get_danger_zones`
keep working during transition (the "neutral view named `zones`" the plan floated is IMPOSSIBLE — `zones`
is the live world-hierarchy table, §1). The compat path preserves every live row byte-for-byte.
```
create table public.zone_placements (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid references public.zone_templates(id) on delete restrict,  -- WHAT this placement plays
  boundary     geometry(Polygon) not null,               -- SRID 0, ±10000, ST_IsValid — the §1.1 quartet
  source       text not null check (source in ('circle','drawn')),   -- provenance, orthogonal to kind
  priority     integer not null default 0,               -- authorable precedence (§6); higher wins same-kind
  published    boolean not null default false,           -- draft vs published config
  enabled      boolean not null default false,           -- runtime kill-switch, independent of publish
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  archived_at  timestamptz
);
create index on public.zone_placements using gist (boundary);           -- REQUIRED for ST_Intersects
create index on public.zone_placements (template_id) where archived_at is null;
```
`zone_kind`, `location_id`, and the `status`/`CHECK(source<>'circle'…)` coherence constraint of the old
table are RE-HOMED: `kind` derives from `template.kind`; `location_id` moves to the junction (§2.4);
`status='active'` maps to `published AND enabled` (the lifecycle split, §2.5). The old FK
`location_id ON DELETE CASCADE` (`0233:187`) and coherence CHECK (`0233:195`) are re-expressed as a junction
guard (§2.4) so a circle placement can't orphan its backing location.

### 2.4 `zone_placement_locations` — 0..N location junction
```
create table public.zone_placement_locations (
  placement_id uuid not null references public.zone_placements(id) on delete cascade,
  location_id  uuid not null references public.locations(id)       on delete cascade,
  primary key (placement_id, location_id)
);
```
This is the **distinct** relationship from template reuse: one placement → 0..N locations. Combat placements
attach ≥1 hostile (`pirate_hunt`/`pirate_den`) location; mining/exploration placements typically attach 0
(they seed their own fields/sites inside the boundary). The re-homed coherence guard (a circle placement of a
combat template must retain ≥1 location) is enforced by the write RPC + a migration self-assert, replacing
the old `CHECK(source<>'circle' OR location_id is not null)`.

### 2.5 Lifecycle state machine (spec-mandated; ordinary edits must NOT affect players)
Per template AND per placement, five states from three orthogonal flags:

| State | Meaning | Flags |
|---|---|---|
| **Draft** | authored freely, invisible to runtime | `published=false` |
| **Published** | config promoted (atomic replace, `revision`++, audit row for restore) | `published=true, enabled=false` |
| **Runtime enabled** | live to players | `published=true, enabled=true` |
| **Disabled** | fast kill-switch, config retained | `published=true, enabled=false` (re-cleared) |
| **Archived** | soft-retired, prefer over delete | `archived_at is not null` |

Draft→Publish is an **atomic** promotion (single transactional RPC that snapshots the prior published
revision into audit history for restore). Enable/disable is a SEPARATE, fast RPC (per-placement AND
per-template). Runtime resolution (§5, §6) considers ONLY `published=true AND enabled=true AND archived_at
is null` rows on BOTH template and placement — so an ordinary draft edit never reaches a player.

### 2.6 Backfill of the 3 live zones — see §3.

---

## 3. Migration + backward-compatibility strategy (the 3 live zones stay byte-identical)

The 3 live rows are `source='circle'`, `zone_kind='pirate'`, `created_by=null`, each with ONE `location_id`
→ an active `pirate_hunt` whose `base_difficulty`/`reward_tier` (25/t3, 15/t2, 10/t1) drive combat. Compat =
**inherit + single attach reproduces today**, made deterministic and tested:

1. **Rename with compat view.** `alter table danger_zones rename to zone_placements`; add the new columns
   (`template_id`, `priority`, `published`, `enabled`, `archived_at`) with backfilled defaults; create view
   `danger_zones` selecting the compat shape (incl. a `location_id` expression from the junction and a
   `status` expression from `published AND enabled`) so `get_danger_zones` and the `0233` RLS/reads keep
   working untouched during transition. `source`, `created_by`, `boundary` (SRID 0) carry over unchanged.
2. **Seed a system template** `slug='legacy-pirate-territory'`, `kind='pirate_combat'`,
   `published=true`, `enabled=true`, with a `zone_profile_pirate_combat` row `difficulty_source='location'`
   (INHERIT — leaves all overrides NULL = today's behavior).
3. **Backfill `template_id`** = that template on all 3 circle rows; set `published=true, enabled=true`
   (they are live today), `priority=0`.
4. **Backfill the junction** — exactly one `zone_placement_locations` row per non-null `location_id` (3 rows).
5. **Repoint the reads (real plpgsql work, not just a table add):** `pirate_intercept_leg_zone_hits`
   (`0233:311-322`) returns a SINGLE `location_id` per zone and `evaluate_leg` (`0233:484-513`) opens combat
   for that ONE location. To honor N-location attach, BOTH the leaf's `RETURNS TABLE` shape and the
   orchestrator's single-location branch fan out over the junction. During transition (all live zones have
   exactly 1 attach) the fan-out is behavior-preserving.
6. **Generalize/retire the write path:** `get_danger_zones` gains `template_id`/`kind`/
   `attached_location_ids[]`; `pirate_zone_create` (which hardcodes `zone_kind='pirate'`/`source='drawn'`
   at `0233:1464-1465`) is RETIRED in favor of one kind-parameterized, `location_ids[]`-accepting,
   owner-gated `zone_placement_save` RPC (one save authority — NO SPAGHETTI).

**Apply-proof pins (deterministic conversion test in `supabase start`):**
- `count(zone_placement_locations) = count(danger_zones.location_id IS NOT NULL)` before rename (= 3).
- all 3 rows carry the legacy template, `difficulty_source='location'`, overrides NULL.
- re-running an intercept roll on a backfilled zone still fires and opens combat at the SAME location with
  IDENTICAL enemy HP/count/reward (inherit = byte-identical).
- `get_danger_zones` output shape unchanged for existing readers via the compat view.

---

## 4. Shared-map extraction plan (one map, player + editor)

**The duplication today (the "duplicated map" the law forbids):** `GalaxyMap.tsx` renders through the
UNIFIED fixed-coordinate frame — `openSpaceTransform.worldToViewBox` (SRID-0 world ±10000 → `viewBox 0 0
1000 1000`, Y-inverted) + `galaxyCamera` (`{k,tx,ty}` zoom/pan, `MIN_K/MAX_K`, `clampPan`, `focusCamera`) —
and composes layers (`territoryLayer`, `miningFieldRangeLayer`, `dangerZoneLayer`, `spatialCombatLayer`,
`teamMarkers`, `LocationMarker`). `ZoneEditor.tsx` **forks all of it**: its own `makeFit` fit-to-content
transform (a SECOND, incompatible world↔SVG projection), its own hand-rolled polygon rendering (duplicating
`dangerZoneLayer`), its own location/territory-ring markers (duplicating `LocationMarker`/`territoryLayer`),
its own click-inversion. Two projections + two renderers for one map = spaghetti.

**Extraction target: one shared, presentation-only map foundation both surfaces mount.**
1. **Projection authority = `openSpaceTransform` (already the single authority).** Delete `ZoneEditor`'s
   `makeFit`. The editor uses `worldToViewBox`/`screenToWorld` + `galaxyCamera` exactly like the player map.
   (The editor's fit-to-content need is served by `galaxyCamera.focusWorldPoints`, which already frames a
   point set — no second transform.)
2. **Extract a headless `<MapCanvas>` primitive** from `GalaxyMap` — the SVG viewport + camera state
   (pan/zoom/reset, pointer→world) + a declarative layer list — with NO gameplay logic and NO DB writes.
   `GalaxyMap` becomes `MapCanvas` + player layers + command hub; `ZoneEditor` becomes `MapCanvas` + the
   read-only layers + an **owner-only edit overlay** (draft polygon, vertex handles, validation warnings).
3. **Shared read-only layers** consumed by both: `LocationMarker`, `territoryLayer`, `dangerZoneLayer`
   (danger/warning tones already there), `miningFieldLayer`. The editor stops re-drawing these by hand.
4. **The edit overlay is the ONLY editor-specific surface** — it renders on top of the shared canvas and
   emits draft geometry; it holds no projection or marker logic of its own.

**Guardrails:** this slice (roadmap Slice B) changes NO gameplay and NO data — it is a pure client
refactor proven by regression: the player map renders pixel-identical before/after (snapshot/visual test),
and the editor draws/saves via the existing RPC unchanged. `openSpaceTransform` stays pure (no DOM/fetch,
per its own header). No new projection is introduced — the whole point is to DELETE the second one.

---

## 5. Pirate-zone runtime semantics (exact)

**Handler contract (kind = `pirate_combat`), server-authoritative, reusing the existing combat path:**

1. **Trigger event:** leg departure. `pirate_intercept_evaluate_leg` (`0233:377`) is the ONE trigger,
   fired synchronously in the movement transaction when a fleet's route leg is evaluated. No client input
   decides combat — the client only issues the move.
2. **Placement eligibility:** the ambushing placement must attach ≥1 location that is active AND
   `location_type in ('pirate_hunt','pirate_den')` (`0233:474-488,1459`). A standalone / no-hostile-location
   combat placement only forces a STOP, never a fight (the `0233:474-482` stub) — v1 does not auto-mint host
   locations (§10 D1).
3. **Resolution → stamp (the least-invasive seam):** after `v_enc` is read (`0233:515`), the handler
   resolves the ambushing placement → `template_id` → `zone_profile_pirate_combat`, then issues ONE
   statement:
   `update combat_encounters set difficulty_override=…, reward_tier_override=…, max_units_override=…,
   zone_template_id=… where id = v_enc`. Both the encounter id and `v_hit.zone_id` are already in scope —
   this replaces PR #221's proposal to thread an override payload through 4 frozen signatures
   (`presence_create`→`activity`→`combat_create_encounter`→`combat_create_group_encounter`). The stamp is
   synchronous, before any cron tick reads the row.
4. **Read (override-else-location, ONE function edit):** add nullable columns to `combat_encounters`
   (`difficulty_override double precision`, `reward_tier_override integer`, `max_units_override integer`,
   `zone_template_id uuid`) — all NULL by default so every one of the 14 existing encounters is untouched.
   In `process_combat_ticks`, compute effective values ONCE right after the loc read (`0234:566`):
   `v_eff_difficulty := coalesce(e.difficulty_override, loc.base_difficulty)`;
   `v_eff_reward := coalesce(e.reward_tier_override, loc.reward_tier)`;
   `v_eff_maxunits := coalesce(e.max_units_override, cfg_num('enemy_synthetic_max_units'))`. Substitute at
   `0234:690,692,696,698,964,981` (difficulty), `0234:898,1074` (reward), `0234:694` (max-units cap).
   `e` is the loop row — no extra query. Inherit (NULL) = byte-identical to today.
5. **CO-REQUISITE — the LIVE latent blocker that makes `max_units>1` UNBUILDABLE today:** constraint
   `combat_units_encounter_id_unit_type_id_key UNIQUE(encounter_id, unit_type_id)` still exists (verified
   live via `pg_constraint`). The spatial enemy spawn inserts N rows ALL with `unit_type_id='pirate_synthetic'`
   and NO on-conflict (`0234:707-718`). For `danger>=2 → v_enemy_count>=2` (`0234:694`), the 2nd insert throws
   `unique_violation`, caught by the per-encounter handler (`0234:1134-1139`) → the whole tick rolls back and
   "retries next tick" forever. Wave-1 works; wave-2+ multi-pirate waves silently stall — and because
   `spatial_combat_enabled=TRUE`, this is LIVE (prod has ZERO enemy-side `combat_units` rows across 14
   terminal encounters). **Fix (mirror the `0167` partial-unique pattern): replace with a partial unique
   index excluding `side='enemy'`, or give each synthetic row a distinct `unit_type_id` slot.** This is a
   Phase-2 CO-REQUISITE, not deferrable — any profile with `max_units>1` is meaningless until it lands.
6. **Cooldown scope:** NONE per-zone exists today. Present idempotency: one active encounter per fleet AND
   per presence (`combat_encounters` unique partial indexes, `20260616000014:35-38`). A per-zone/per-template
   cooldown is net-new plumbing (new columns read by `evaluate_leg`/`compute_risk`) — deferred, NULL/unused
   in v1.
7. **Respawn meaning:** there is NO zone-level respawn. "Respawn" today is strictly IN-ENCOUNTER waves
   (`next_wave_at` / `combat_wave_transition`); encounter uniqueness is per-fleet/presence. A profile
   `respawn/cooldown_seconds` is future plumbing, not a coalesce point.
8. **Dup-reward protection:** `reward_grant` is idempotent on `(source_type, source_id)` DO NOTHING
   (`20260616000015:40`). Rewards travel home in `total_rewards_json` via `movement_attach_cargo`
   (`0234:643`), secured once on arrival, forfeited on defeat (`total_rewards_json='{}'`). The override
   stamp does not touch this path — it only changes the MAGNITUDE (`v_eff_reward`), never the grant identity.
9. **Edit-while-inside behavior:** ordinary edits don't reach players (draft state, §2.5). An in-flight
   encounter already stamped its overrides at creation (step 3), so re-publishing or disabling the placement
   mid-encounter does NOT retroactively change the live fight — the stamped `combat_encounters` row is the
   frozen truth for that encounter. Disable/archive only stops FUTURE ambushes (resolution skips
   non-`enabled` placements). This is the correct, deterministic behavior: enable/disable is a forward-only
   kill-switch, never a live rewrite of an in-progress combat.

**Invariants (RPC + self-assert):** `difficulty_override > 0`; `max_units_override in [1,cap]` AND requires
the constraint fix for >1; `reward_tier_override` coalesces through `greatest(x,1)`; inherit template
(`difficulty_source='location'`) leaves all overrides NULL. **Apply-proof pins:** a tier-1 vs tier-3 template
placed at the SAME location produces different enemy HP and (post-fix) different N on live Postgres; an
inherit template reproduces today's numbers byte-for-byte.

---

## 6. Overlap + priority rules (deterministic, tested)

Resolution input: the fleet's leg geometry intersected with all `published AND enabled AND archived_at is
null` placements (via `gist` + `ST_Intersects`). Rules:

1. **Boundary inclusion is fixed and tested:** a point/segment is "inside" a placement iff
   `ST_Intersects(boundary, geom)` is true (closed boundary — a point exactly on the edge counts as inside).
   This matches the existing engine (`0233:315-322`) and is pinned by an on-edge test case so it can never
   drift.
2. **Same kind, overlapping:** the **highest-`priority` enabled** placement wins. Ties are resolved by
   `priority desc` then a deterministic key (`placement_id asc`) ONLY as a last-resort — but see rule 4.
3. **Different kinds, overlapping:** they coexist ONLY if their handlers declare mutual compatibility in the
   handler registry (§ below). Compatible kinds each run their own handler (e.g. a mining region overlapping
   a pirate lane can both apply). Incompatible kinds overlapping is a VALIDATION error at placement save
   (warn/reject), never a silent runtime coin-flip.
4. **Same kind, EQUAL priority, overlapping → FAILS VALIDATION deterministically.** The editor rejects (or
   hard-warns) authoring two same-kind placements with equal priority whose boundaries intersect, because
   there is no principled winner. This is enforced at save time (a spatial check in the write RPC), so
   runtime never faces an ambiguous same-kind tie. (This is why rule 2's `placement_id` tiebreak is a
   belt-and-suspenders fallback, not the primary mechanism.)
5. **Determinism:** given a fixed world + placement set, resolution is a pure function — no randomness in
   selection (only enemy stat variance downstream, which is per-encounter and unrelated to WHICH zone wins).
   The current emergent `order by exposure_fraction desc` (`0233:428`) is REPLACED by authorable `priority`
   as the primary key, with `exposure_fraction` retained only as a documented sub-tiebreak within equal
   priority if ever needed.

**Handler registry (NO central conditional block):** an explicit registry maps `kind → handler` sharing one
contract (resolve-eligibility / stamp / record). Each handler declares `compatible_with[]`. Dispatch looks up
the handler — there is NO central `if kind='pirate' … elsif …` block. Adding a kind = adding a registry entry
+ a handler, never editing a god-function.

---

## 7. Owner-only server-authoritative security model

**This slice ships FIRST (roadmap Slice A), UNCONDITIONALLY (a guard is never flag-gated), ahead of all
feature work — because the write surface it protects is LIVE and exploitable in prod today (§1.5).**

1. **Owner identity — ONE authority.** A dedicated table, deny-all to game users:
   ```
   create table public.app_owners (
     user_id  uuid primary key references auth.users(id) on delete cascade,
     added_at timestamptz not null default now()
   );
   alter table public.app_owners enable row level security;   -- NO client grant to anon/authenticated
   create function public.is_owner(p_uid uuid) returns boolean
     language sql stable security definer set search_path=public as
     $$ select exists (select 1 from public.app_owners where user_id = p_uid) $$;
   ```
   `is_owner()` is the single source of truth every zone RPC consults. **DO NOT** use a `profiles.is_owner`
   column: `profiles` has a player-writable UPDATE policy (`init_profiles.sql:17-20`), so such a column would
   be SELF-PROMOTABLE — a privilege-escalation hole. This is the single most important design constraint. A
   `game_config('owner_user_id')` key is an acceptable alternative (config is service_role-written) but a
   deny-all typed table is cleaner.
2. **Owner seed is OUT OF GIT.** A service_role activation script (`scripts/activate-*.sh` precedent, same
   mechanism as `set_game_config` `20260618000046:406`) inserts the owner uuid into `app_owners` AFTER
   deploy. Never hardcode the uuid in a committed migration.
3. **Fail closed.** With no owner seeded, `is_owner()` returns false for everyone — NOBODY can write,
   including the owner, until the seed runs. Deploy order is a documented dependency: (a) deploy the security
   migration (table + helper + gated RPCs), (b) run the seed script, (c) only then rely on the editor.
4. **Protected RPCs only — no direct browser writes.** Every mutation is a `SECURITY DEFINER`,
   `set search_path=public` function that re-checks `auth.uid()` AND `is_owner()` at its own boundary,
   returns `jsonb {ok:false, reason:'not_owner'}` on failure, and KEEPS `grant execute to authenticated`
   (the deny happens IN THE BODY, exactly the house pattern — not an ACL revoke, so the owner's own session
   still reaches it):
   - Guard `pirate_zone_create`/`delete` immediately (before the feature RPCs land) — add
     `if not public.is_owner(auth.uid()) then return jsonb_build_object('ok',false,'reason','not_owner');
     end if;` right after the existing `auth.uid()`-null check. Change delete scope from `created_by=v_player`
     to `is_owner`-only so the owner can remove ANY drawn zone (fixes the attacker-zone persistence gap;
     optionally allow deleting `circle` zones too).
   - Carry the same guard forward into the new `zone_template_save/publish/enable/disable/archive` and
     `zone_placement_save/publish/enable/disable/archive` RPCs — owner-gated from day one. Retire
     `pirate_zone_create` (one save authority).
5. **RLS on every authoritative table:** enable RLS, SELECT-only + scope-narrowed policies (owner-select for
   authoring tables; dark-gated public SELECT only for the render read, mirroring `danger_zones_select_when_lit`
   `0233:200-206`). NO client INSERT/UPDATE/DELETE grant anywhere.
6. **Audit table (create/update/publish/enable/disable/archive):**
   ```
   create table public.zone_authoring_audit (
     id uuid primary key default gen_random_uuid(),
     actor uuid not null,
     action text not null check (action in
       ('create','update','publish','enable','disable','archive','delete')),
     placement_id uuid, template_id uuid,
     payload jsonb, created_at timestamptz not null default now()
   );  -- RLS owner-select-only, NO client write grant; sole writers = the zone RPCs
   ```
   (`pirate_intercepts` is a combat-roll log, a DIFFERENT concern — this is the authoring log.) Records WHO
   authored/promoted/killed WHAT, currently invisible.
7. **Unauthorized-path tests (in `supabase start` apply-proof, where static selftest can't reach):** a SECOND
   authenticated NON-owner session calls each mutation RPC → assert `reason='not_owner'` AND zero rows
   changed; owner session → assert `ok`. Plus deploy-time self-asserts: `is_owner()`/`app_owners` exist; the
   RPCs still carry the `authenticated` execute grant (so the deny is in-body, not an ACL revoke) via
   `has_function_privilege`.
8. **The hidden route (`/dev/zones`, `dev_zone_editor_enabled`) is UX only, never authz.** It stays as a
   client convenience; every privileged op is owner-verified server-side regardless.

NO-SPAGHETTI: one owner authority (`app_owners`), one `is_owner()` helper consulted by all zone RPCs, one
audit writer path — no scattered owner-uuid literals, no per-RPC ad-hoc checks.

---

## 8. Phased PR roadmap (dark-first method slices)

Each slice: coherent + reviewable, NON-OVERLAPPING file ownership, its OWN flag (features only — the security
guard is unflagged), an apply-proof self-assert (`supabase start` against real PG), a SEPARATE prod-migration
approval, read-only prod verification, and an owner-gated enable. Precise state language only
(Designed / Implemented locally / PR open / CI green / Merged / App deployed / Migration deployed /
Production verified / Runtime enabled) — never "done."

| Slice | Name | Flag | Owns (files) | Verification gate | Prod activation |
|---|---|---|---|---|---|
| **A** | **Security spine** (ships FIRST, unconditional) | none (guard) | new `…0239_zone_owner_security.sql`; `app_owners`, `is_owner()`, `zone_authoring_audit`; guard on `pirate_zone_create/delete` | apply-proof: non-owner refused + zero rows; owner ok; ACL-split self-assert | migration deploy + seed script; **closes live hole** |
| **B** | **Shared-map extraction** (client only) | none (refactor) | `src/features/map/*` (`GalaxyMap`→`MapCanvas`), `src/features/dev/ZoneEditor.tsx` | player map pixel-identical (regression/snapshot); editor saves via existing RPC unchanged | none (no data/gameplay change) |
| **C** | **Schema + typed profiles + backfill** (gated off) | `zone_templates_enabled` | new `…0240_zone_schema.sql`; `zone_templates`, 5 profile tables, `zone_placements` (rename+compat view), `zone_placement_locations`; backfill 3 zones | backfill counts pinned; inherit template reproduces today's intercept byte-for-byte; compat view keeps `get_danger_zones` stable | migration deploy; read-only verify; enable stays OFF |
| **D** | **Owner-gated mutation RPCs + audit** | `zone_templates_enabled` (reuse) | new `…0241_zone_rpcs.sql`; `zone_template_save/publish/enable/disable/archive`, `zone_placement_save/…`; retire `pirate_zone_create` | RPC ACL split; owner-only enforced; audit row per action; draft edits invisible to runtime | migration deploy; read-only verify |
| **E** | **Real-map editor (draft-safe)** | `dev_zone_editor_enabled` (reuse) | `src/features/dev/*`, `src/features/map/pirateApi.ts`→zone API | editor on shared `MapCanvas`; validates min-verts/self-intersect/out-of-bounds/invalid-overlap; saves DRAFTs only | app deploy; owner smoke |
| **F** | **Read-only runtime resolution** (NO effects) | `zone_resolution_enabled` | new `…0242_zone_resolution.sql`; point-in-polygon + priority + overlap resolver + handler registry (no dispatch to effects) | apply-proof: PIP/priority/overlap/equal-priority-fails/boundary-edge tests; resolver returns the right placement, applies NOTHING | migration deploy; read-only verify |
| **G** | **Pirate integration** | `zone_pirate_handler_enabled` | new `…0243_zone_pirate_handler.sql`; `combat_encounters` override cols; `evaluate_leg` stamp; `process_combat_ticks` coalesce; **`combat_units` unique fix (co-req)** | apply-proof: tier-1 vs tier-3 at same location differ; inherit reproduces today; wave-2 (N≥2) persists post-fix | ONE template+placement, disabled; separate migration approval; prod verify; **owner-gated enable** |
| **H** | **Mining zones** | `mining_zone_templates_enabled` (+ `mining_enabled`, already lit) | new `…0244_zone_mining_handler.sql`; polygon→`mining_fields` seeder; `zone_placement_fields` link; mining profile validation | apply-proof: N fields ALL inside boundary (`ST_Contains`); reward bundle valid; extract from one works | migration deploy; prod verify; owner-gated enable |
| **I** | **Exploration zones** (LAST) | `exploration_zone_templates_enabled` (+ `exploration_enabled`) | first LIGHT+PROVE exploration; then `…0245_zone_exploration_handler.sql`; site seeder; `zone_placement_sites` link | exploration proven live end-to-end FIRST; then N sites inside boundary; scan→discover→reward | migration deploy; prod verify; owner-gated enable |

**Dependencies:** A → everything (unguarded write surface must be closed first). C → D → E, F. F → G → H → I.
B is independent (pure client refactor) and can land in parallel with A. G carries the `combat_units` fix as
a hard co-requisite. H needs no dark base (mining is lit). I must not start until exploration is proven.

---

## 9. Risks, failure modes, rollback / disable

| # | Risk / failure mode | Detection | Rollback / disable |
|---|---|---|---|
| R1 | **Live griefing via unguarded `pirate_zone_create`** (any player draws hostile zones now) | prod audit of `danger_zones` rows with non-null `created_by` | Slice A guard (unconditional); owner `delete-any`; until then, service_role manual cleanup |
| R2 | **Wrong SRID on a new geometry column** (contributor copies `geometry(Polygon,4326)`) → every exposure/length calc corrupts silently | migration self-assert `ST_SRID(boundary)=0`; apply-proof intercept roll | reject migration in CI; SRID-0 is a pinned self-assert |
| R3 | **`combat_units` unique constraint stalls wave-2+** (LIVE today for N≥2) | prod: zero enemy-side `combat_units` rows; apply-proof wave-2 test | Slice G co-req fix (partial unique excl `side='enemy'`); until then keep `max_units=1` |
| R4 | **N-location fan-out regression** (leaf/orchestrator still single-location) | apply-proof: 2-location placement — assert BOTH fire | keep `danger_zones.location_id` live during transition; revert read repoint |
| R5 | **Draft edit leaks to players** (resolution reads unpublished/disabled) | apply-proof: draft placement never resolves | resolution filters `published AND enabled AND archived_at is null` on BOTH template+placement; disable kill-switch |
| R6 | **Equal-priority same-kind ambiguity** | save-time spatial validation; apply-proof equal-priority-fails test | reject at authoring (fail validation), never at runtime |
| R7 | **Generator non-determinism breaks CI** (random field/site coords) | apply-proof pins INVARIANTS (count, all-inside, valid shape), never coords | slime-migration discipline (`0237`): valid-by-construction, invariant asserts |
| R8 | **`mining_extract` CREATE-OR-REPLACE regression** (the `0143→0172` episode: an edit dropped `0137` depletion hunks) | apply-proof mining extract test; diff review | one-authority-per-function; any edit re-merges BOTH advisory lock + depletion hunks onto head |
| R9 | **Fail-open owner seed** (RPCs live before `app_owners` seeded, or seed mis-ordered) | deploy-order runbook; `is_owner()` fail-closed | fail-closed by design (no owner ⇒ nobody writes); documented deploy order A→seed→editor |
| R10 | **Building on unproven exploration** | flag `exploration_enabled=false` in prod | sequence exploration LAST; do NOT couple mining kind to `world_balance` either |

**Kill-switches:** per-placement `enabled=false` and per-template `enabled=false` are fast, independent, and
retain config (§2.5). Archive (`archived_at`) is the soft-retire; prefer disable/archive over DELETE
everywhere. Every feature slice's flag disables the whole kind at the server boundary. The security guard has
NO disable (a guard is never a feature).

---

## 10. Unresolved OWNER decisions (each with a safe recommended default)

Implementation proceeds on the defaults below without blocking; the owner can override any before its slice.

- **D1 — Standalone combat zones (no host location).** Combat still needs a real `locations` row to open an
  encounter (`0233:474-488` stub). **Default: require ≥1 hostile-location attach for v1** (no auto-mint).
  Multi-attach already covers "reuse Zone A across the map." Auto-minting hidden host locations
  (`0233:44` follow-up) is a later additive option.
- **D2 — Fate of `danger_zones`.** The name is wrong for mining/exploration, and `zones` is taken (world
  hierarchy). **Default: rename to `zone_placements` with a `danger_zones` compat view** so `0233`
  reads/RLS/`get_danger_zones` keep working (plan's option b; plan's option a — a `zones` view — is
  IMPOSSIBLE, §1).
- **D3 — Tier → difficulty mapping.** **Default: a small `zone_tier_difficulty` config table** (tier 1/2/3 →
  `base_difficulty`), one authority, so authoring is "tier N" not raw numbers and there are no scattered
  literals.
- **D4 — Per-template vs per-attachment override granularity.** **Default: per-template** — all attachments
  of a placement share the tier. Per-attachment tuning is an additive later change.
- **D5 — Profile carrier.** **Default: typed per-kind tables** (§2.2) — owner-mandated over an unvalidated
  jsonb bag; DB-enforced validation + `schema_version`.
- **D6 — Same-kind equal-priority overlap.** **Default: FAIL VALIDATION at authoring** (deterministic, §6) —
  reject rather than invent a runtime tiebreak.
- **D7 — Per-zone cooldown / respawn / loot-pool / spawn-probability.** These are GLOBAL today and are
  net-new plumbing, not coalesce points (§5). **Default: OUT of v1** (profile columns reserved, NULL/unused);
  revisit after pirate integration is proven.
- **D8 — Mining extract radius at scale.** `mining_extract_radius=60` (global, prod) makes fields effective
  point-sources — a large mining polygon needs `field_count` high enough that points are reachable.
  **Default: expose `radius_override` on the mining profile (already in §2.2) and warn in the editor** when
  `field_count` is too low for the polygon area; do NOT couple mining to `world_balance` (keep depletion
  optional/dark).
- **D9 — Mining depletion.** **Default: ship mining zones WITHOUT depletion** (`world_balance_enabled=false`
  → fields simply don't deplete — acceptable, not a blocker). Per-zone depletion waits until `world_balance`
  is lit and proven.
- **D10 — Delete `danger_zones.location_id`.** **Default: keep it live during transition (dark), drop it in a
  later cleanup slice** once the junction read repoint is proven — never in the same slice that adds the
  junction.

---

## Appendix — reconciliation with PR #221 (`docs/ZONE_TEMPLATES_PLAN.md`)

**Kept (verified correct):** the coalesce-override combat architecture; "tier lives on
`locations.base_difficulty`, not the zone"; the 3-live-circle-zones-reshaped-by-slime facts; the
mining-needs-no-extract-path-change insight; the dark-first phased spirit; generator determinism via
invariant-pinning (slime discipline).

**Corrected / replaced:**
1. Data model → owner-mandated THREE tables + TYPED profiles (not generalize-danger_zones-in-place, not a
   jsonb bag). Plan §1.2 option (a)'s neutral `zones` view is IMPOSSIBLE (`zones` is the live world table).
2. Combat is ONE function edit (`process_combat_ticks`), not two — `combat_create_group_encounter` reads
   neither field and spawns no enemies.
3. The override stamp is a post-`v_enc` `UPDATE` in `evaluate_leg` (both ids in scope), NOT threading a
   payload through 4 frozen signatures.
4. The LIVE `combat_units UNIQUE(encounter_id,unit_type_id)` blocker (any `max_units>1` wave stalls in prod
   today) — omitted by the plan, made a Slice-G co-requisite here.
5. Mining is NOT dark (`mining_enabled=true`, radius 60 not 750, proven live); no richness/depletion columns
   on `mining_fields`; `module_range_attributes` does not exist.
6. Security spine (owner identity, `app_owners`, `is_owner()`, audit, unauthorized tests, fail-closed) — the
   plan is silent on authz; this doc supplies it and ships it FIRST.
7. N-location fan-out is real plpgsql work (leaf `RETURNS TABLE` + orchestrator branch), not merely a table
   add.
