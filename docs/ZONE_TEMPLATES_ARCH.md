# Zone Framework — Behavior-Module Blueprint Architecture

**Status:** PROPOSED design (read-only audit + design slice; **no game code, no migration, no flag, no grant,
no prod change in this PR**). Everything marked **CURRENT** is verified against `origin/main` + LIVE prod;
everything marked **PROPOSED** is the target design, not yet built.
**Base:** `origin/main` @ `2518d1f`, plus merged zone slices `0233`–`0238` (verified against code + LIVE prod).
**Supersedes:** the rigid single-kind draft of this same document and `docs/ZONE_TEMPLATES_PLAN.md` (PR #221).
The earlier draft made a *template* be **exactly one kind** with one typed profile. The owner has refined the
design to a **BLUEPRINT + BEHAVIOR-MODULE** model with **immutable published revisions** (below). The grounded
audit, the security spine, the combat-override mechanism, the 3-live-zone compat strategy, and the two live
prod prerequisites all carry forward unchanged; the **data model shape**, the **revision/immutability model**,
and the **override locus** are refined. Where this doc and either prior document disagree, **this doc wins**.

**Non-negotiable laws enforced throughout:** no spaghetti (one authority per concept, compose don't fork,
retire the old), no duplicated map, no client-authoritative gameplay, no hidden-route-as-security, no
arbitrary unvalidated config, no prod activation in this phase.

---

## Terminology (used consistently; "template"/"profile" appear ONLY when documenting legacy compat)

| Term | Meaning |
|---|---|
| **Blueprint** | A stable, reusable **content identity** (a `slug` + name). Long-lived; never itself holds gameplay config. |
| **Blueprint revision** | An **immutable-once-published** configuration snapshot of a blueprint: a *draft* revision (mutable) or a *published* revision (frozen) or an *archived* historical revision. All gameplay config lives on a revision, never on the identity. |
| **Behavior instance** | A **typed gameplay module** (pirate / mining / exploration / …) belonging to ONE blueprint revision. At most one behavior of each kind per revision. |
| **Placement** | A **geographic instance** on the real map: a concrete materialized polygon that references ONE specific *published* blueprint revision. |
| **Placement-behavior override** | A **local typed deviation** from a published behavior instance's defaults, scoped to a specific placement AND a specific behavior kind. Typed, validated, never JSON. |
| **Location association** | A contextual link from a placement to 0..N `locations`. **Separate** from blueprint reuse and from geometry generation. |
| **Materialized geometry** | The single canonical `geometry(Polygon)` a placement stores; the ONLY geometry the runtime reads. |

The old draft's words **template** = today's *blueprint*+*revision* split; **profile** = today's *behavior
instance*. They survive in this doc only where §3 documents the `danger_zones` legacy path.

---

## 0. Executive summary

**What the owner wants (PROPOSED):** the dev zone editor becomes a reusable **content-authoring** system built
on **behavior modules with immutable published revisions**. Author a **blueprint** (a stable content identity),
edit its **draft revision** (carrying **1..N typed behavior instances** — pirate / mining / exploration, room
for more), **publish** that revision (freezing it immutably), then **place** it as many concrete polygons
across the map — each placement adopting a **specific published revision**, optionally attaching 0..N
locations, optionally carrying **typed overrides** of the adopted revision's behavior instances. A blueprint is
**NOT a single kind**; a revision is a bag of composable, individually-typed behavior instances. Runtime is
fully server-authoritative: position → published+enabled placements → overlap/priority resolution → the
placement's **adopted published revision** ⊕ its typed **placement overrides** (via ONE explicit server-side
**resolver**, audited) → a per-behavior **handler** (explicit registry, no central `if/else`) → reuse the
EXISTING combat/mining/exploration command path → eligibility/cooldown/idempotency → activity record stamped
with the **exact revision id** + placement id.

**Schema (PROPOSED — identity / immutable revisions / typed behavior instances / geometry / junction / typed
overrides, one authority each):**
- `zone_blueprints` — WHAT identity (slug, name, `created_by`, lifecycle-of-identity, `archived_at`). No config.
- `zone_blueprint_revisions` — immutable config snapshots (`revision_number`, `state` draft|published|archived,
  `published_at`). Placements point HERE, not at the identity.
- `zone_pirate_behaviors` / `zone_mining_behaviors` / `zone_exploration_behaviors` — one **typed,
  DB-CHECK-validated, catalog-FK'd** behavior instance per (revision, kind). A revision has **1..N** (at most
  one of each kind). Room for future kinds (hazard, trade-modifier, visibility, faction, mission-trigger,
  travel-speed, regeneration) — each its own typed table, **never** arbitrary jsonb.
- `zone_placements` — WHERE (concrete materialized `geometry(Polygon)` SRID 0, `geometry_mode`, priority,
  lifecycle, `archived_at`, FK → one *published revision*).
- `zone_placement_locations` — 0..N location junction (kept DISTINCT from blueprint reuse + geometry gen).
- `zone_placement_<kind>_overrides` — TYPED per-behavior-instance override rows (nullable columns + CHECKs).
  **Effective config = published behavior-instance defaults ⊕ placement override**, resolved by ONE explicit
  server-side resolver, audited.

**Immutability + explicit publish (PROPOSED — §2.6, §2.7):** identity is stable; a published revision is
**frozen** (edits fork a NEW draft revision, never mutate a published one); a live placement resolves against a
**specific** published revision, so an ordinary draft edit CANNOT touch live gameplay. **Publish is chosen to
be option (a): it makes a revision AVAILABLE for adoption; it does NOT auto-update any placement.** Repointing
placements to a newer revision is a **separate, explicit, transactional** operation (single placement or an
atomic bulk-roll) — preventing partial propagation. Preview, audit history, revert-to-a-prior-published-
revision, and "exactly which config drove encounter X" are all first-class (§2.7).

**Controlled growth path (PROPOSED, explicit — §6):** **v1** = a revision has exactly **ONE** behavior instance
(pirate) → *no conflict rules needed*, the first implementation slice is limited to this. **v2** = a revision
may carry **MULTIPLE compatible** behaviors → *requires* a **centrally-validated compatibility policy** (not
per-handler `if`s) governing coexistence, priority, overlap, ordering, isolation. **v3** = conditions /
seasonal / faction / hazard / triggers. Nothing beyond v1 is built in the first slice.

**Security model (CURRENT gap; PROPOSED fix ships FIRST as a prerequisite):** owner identity does not exist
server-side today — a dedicated deny-all `app_owners` table + `is_owner()` helper (seeded out-of-git via
service_role), every privileged op behind an owner-gated `SECURITY DEFINER` RPC, RLS SELECT-only on all
authoritative tables, a `zone_authoring_audit` table, and explicit unauthorized-path tests in the
`supabase start` apply-proof. Unconditional (a guard, never flag-gated); closes a **LIVE prod griefing hole**
(§1.5, §7, §8 Slice A). This is **prerequisite #1**.

**Pirate runtime semantics (PROPOSED, reusing the CURRENT authoritative path):** trigger = leg departure
(`pirate_intercept_evaluate_leg`, the ONE orchestrator); the resolver computes effective pirate config
(published defaults ⊕ placement override), the ambush handler stamps it — plus the exact `revision_id` — onto
the just-created `combat_encounters` row via a single post-create `UPDATE` (both ids already in scope);
`process_combat_ticks` reads `coalesce(override, loc.*)` so NULL = byte-identical to today. **Only
single-pirate combat is proven live today; multi-pirate (`max_units>1`) is BLOCKED by a live latent
constraint (prerequisite #2, §5.5) and is NOT claimed verified anywhere in this doc.**

**Doability verdict per behavior:** `pirate` — HIGH confidence, engine fully parameterized; work = resolver +
override stamp + the `combat_units` cardinality fix (prerequisite #2). `mining` — READY, NOT dark
(`mining_enabled=true`, extract proven live); medium effort. `exploration` — LEAST ready; dark end-to-end,
never proven; build LAST.

**Top owner decisions (safe defaults, §10):** (D1) standalone combat — require ≥1 hostile-location attach for
v1. (D2) `danger_zones` fate — rename to `zone_placements` + a **time-boxed** `danger_zones` compat view
(**PROPOSED**, defined lifetime + removal gate, §3.4). (D3) tier→difficulty — a `zone_tier_difficulty` config
table. (D4) publish propagation — **explicit adoption, no auto-update** (§2.7). (D5) behavior + override
carrier — typed tables. (D6) same-behavior equal-priority — fail validation.

**PR for this document:** branch `docs-zone-arch`, PR #222. DOC ONLY.

---

## 1. Code-grounded audit summary (the ground truth — all CURRENT)

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
(`0233:188`; prod-verified `ST_SRID=0`). SRID 0 is deliberate — a flat Cartesian game grid, world-units,
bounds ±10000 (the `c_lo/c_hi` guards at `0233:1417-1418`, `command_ship_group_go` `0233:638-639`). A
geographic SRID (e.g. 4326) would corrupt every `ST_Intersects`/`ST_Length`/`ST_Distance` exposure calc. Ring
idiom: `ST_MakePolygon(ST_MakeLine(pts))` from an ordered `[x,y]` array, closed by repeating vertex 1, gated on
`ST_IsValid` (`0233:1449-1453`; slime `0237:101-113`). Client exchange is NEVER PostGIS wire binary — always
`[[x,y],…]` exterior-ring pairs via `ST_DumpPoints(ST_ExteriorRing(boundary))` ordered by `path[1]`
(`0233:1382-1383`), already-closed. A `gist` index on `boundary` is required for the scan. **The quartet every
placement table must reproduce: `geometry(Polygon)` + SRID 0 + `ST_IsValid` ring + gist index. This is also
why the editor MATERIALIZES all generated shapes into a single stored polygon (§4.5) — one geometry authority,
one scan path.**

**PROD (SELECT-verified):** 3 zones Reaver / Snare / Blackden, all `source='circle'`, `zone_kind='pirate'`,
`status='active'`, `created_by=null`, SRID 0, `ST_Polygon`, npoints 13/20/15 (reshaped by slime `0237`,
NOT a 32-seg buffer). Each links to an active `pirate_hunt` location sharing `territory_radius=36` but
`base_difficulty` 15/10/25 and `reward_tier` 2/1/3.

### 1.2 Combat (the pirate behavior's runtime)
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
  RPC). Exploitable today, not theoretical. **This is prerequisite #1 (§7, §8 Slice A).**

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

## 2. Final schema (PROPOSED — identity + immutable revisions + typed behaviors + placements + typed overrides)

Design law: **concepts kept separate, one authority each** (see Terminology). Behaviors and overrides are
**typed tables with DB CHECKs and catalog FKs**, never a generic jsonb bag — the owner mandate is "prefer
typed/schema-validated config over arbitrary unvalidated JSON," and the audits confirm each behavior's knobs
are disjoint and finite.

All new tables reproduce the house write posture (§1.5, §7): RLS ON, SELECT-only + dark/owner-scoped
policies, NO client write grant, mutation exclusively through owner-gated `SECURITY DEFINER` RPCs.

### 2.1 `zone_blueprints` — stable identity (no config)
```
create table public.zone_blueprints (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,                    -- stable authoring handle, e.g. 'reaver-tier2'
  name          text not null check (btrim(name) <> '' and length(name) <= 80),
  description   text,
  -- the identity carries NO gameplay config and NO kind. It points at revisions:
  draft_revision_id     uuid,                            -- the current editable draft (nullable; FK added post-create)
  published_revision_id uuid,                            -- the current "default" published revision new placements adopt
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  archived_at   timestamptz                              -- prefer archive over delete
);
```
Identity is long-lived and stable. It never holds behavior config or a `kind` — those live on revisions (§2.2)
and behavior instances (§2.3). `published_revision_id` is the *suggested* revision for NEW placements only;
existing placements pin their own adopted revision (§2.5) and are never silently repointed by a publish (§2.7).

### 2.2 `zone_blueprint_revisions` — immutable config snapshots
```
create table public.zone_blueprint_revisions (
  id              uuid primary key default gen_random_uuid(),
  blueprint_id    uuid not null references public.zone_blueprints(id) on delete cascade,
  revision_number integer not null,                      -- 1,2,3… monotonically per blueprint
  state           text not null default 'draft'
                    check (state in ('draft','published','archived')),
  published_at    timestamptz,                           -- set once, at publish; never cleared
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  unique (blueprint_id, revision_number)
);
create index on public.zone_blueprint_revisions (blueprint_id, state);
```
**Immutability rule (enforced by RPC + self-assert, §2.6):** a revision in `state='published'` and its child
behavior-instance rows are **FROZEN** — no UPDATE/DELETE. Editing a published blueprint COPIES its behavior
instances into a NEW `draft` revision (`revision_number`++); the published one is never mutated. `archived` is
a soft-retire of an old published revision (kept for audit/revert). This is what makes "a live placement
resolves against a SPECIFIC published revision" safe: that revision can never change under it.

### 2.3 Typed per-kind behavior instances (1..N per revision; ≤1 of each kind)
Each behavior a revision carries is one row in the matching typed table, keyed by `revision_id`. `revision_id`
PK ⇒ **at most one behavior of each kind per revision** (unless later proven otherwise, §5-caveat). A revision
therefore carries **1..N behaviors total**. Each table is **typed + DB-CHECK-validated + catalog-FK'd** and
carries `schema_version` so a knob added later is a versioned migration, never a silent reinterpretation.

```
-- behavior kind: pirate  (v1 ships ONLY this)
create table public.zone_pirate_behaviors (
  revision_id       uuid primary key references public.zone_blueprint_revisions(id) on delete cascade,
  schema_version    integer not null default 1,
  difficulty_source text not null default 'location'
                      check (difficulty_source in ('location','blueprint')), -- 'location' = inherit = today
  tier              integer check (tier >= 1),          -- authoring handle → base_difficulty via config map
  base_difficulty   double precision check (base_difficulty > 0),  -- explicit default (0 = 0-hp pirates → reject)
  reward_tier       integer check (reward_tier >= 1),
  max_units         integer not null default 1 check (max_units between 1 and 6),  -- >1 BLOCKED until §5 fix
  -- future (net-new plumbing, NULL/unused in v1): spawn_probability, cooldown_seconds, loot_pool
  check (difficulty_source = 'location'
         or (base_difficulty is not null or tier is not null))   -- blueprint mode needs a difficulty source
);

-- behavior kind: mining   (v2+)
create table public.zone_mining_behaviors (
  revision_id     uuid primary key references public.zone_blueprint_revisions(id) on delete cascade,
  schema_version  integer not null default 1,
  field_count     integer not null check (field_count between 1 and 64),
  richness        double precision not null default 1.0 check (richness > 0),  -- scales ore_mix quantities
  radius_override integer check (radius_override > 0)   -- optional per-zone extract radius (else global 60)
);
create table public.zone_mining_behavior_ore (   -- ore_mix pool, FK-validated vs the item catalog (0039)
  revision_id uuid not null references public.zone_mining_behaviors(revision_id) on delete cascade,
  item_id     text not null,
  weight      integer not null check (weight > 0),
  primary key (revision_id, item_id)
);

-- behavior kind: exploration  (built LAST; base system must be proven first)
create table public.zone_exploration_behaviors (
  revision_id    uuid primary key references public.zone_blueprint_revisions(id) on delete cascade,
  schema_version integer not null default 1,
  site_count     integer not null check (site_count between 1 and 64),
  metal_min      integer not null default 0 check (metal_min >= 0),
  metal_max      integer not null check (metal_max >= metal_min)
);
create table public.zone_exploration_behavior_pool (
  revision_id uuid not null references public.zone_exploration_behaviors(revision_id) on delete cascade,
  item_id     text not null,
  weight      integer not null check (weight > 0),
  primary key (revision_id, item_id)
);
```
**Room for future behavior kinds (v3, not built now):** `zone_hazard_behaviors`,
`zone_trade_modifier_behaviors`, `zone_visibility_behaviors`, `zone_faction_behaviors`,
`zone_mission_trigger_behaviors`, `zone_travel_speed_behaviors`, `zone_regeneration_behaviors` — each its own
typed table with CHECKs + catalog FKs, added by additive migration, registered via the handler registry (§6.3)
and gated by the compatibility policy (§6.1). Adding a kind never edits an existing table or a god-function.

Why typed tables, not jsonb: (1) DB-enforced validation (CHECK + FK-to-catalog); (2) `schema_version` makes
evolution explicit; (3) disjoint behaviors → no sparse mega-row. `item_id` weight lists are their own child
tables so each row is FK-validatable against the item catalog (`0039`).

### 2.4 `zone_placements` — WHERE (concrete materialized geometry + adopted revision + lifecycle + priority)
Generalized successor to `danger_zones`. **PROPOSED path (§3, §10 D2): rename** `danger_zones` →
`zone_placements` with a **time-boxed** `danger_zones` compat view (§3.4). A placement adopts a **specific
published revision** — never the mutable identity, never a draft.
```
create table public.zone_placements (
  id             uuid primary key default gen_random_uuid(),
  blueprint_id   uuid not null references public.zone_blueprints(id) on delete restrict,          -- identity
  revision_id    uuid not null references public.zone_blueprint_revisions(id) on delete restrict, -- ADOPTED published rev
  boundary       geometry(Polygon) not null,             -- SRID 0, ±10000, ST_IsValid — §1.1 quartet; canonical runtime geom
  geometry_mode  text not null default 'freeform'
                   check (geometry_mode in ('freeform','generated_circle','generated_corridor')),
  gen_metadata   jsonb,                                   -- editor-generation METADATA only (§4.5); NEVER read at runtime
  priority       integer not null default 0,             -- authorable precedence (§6); higher wins same-behavior
  published      boolean not null default false,         -- placement draft vs published
  enabled        boolean not null default false,         -- runtime kill-switch, independent of publish
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  archived_at    timestamptz,
  check (revision_id is not null)                          -- a placement always pins ONE adopted revision
);
create index on public.zone_placements using gist (boundary);            -- REQUIRED for ST_Intersects
create index on public.zone_placements (revision_id) where archived_at is null;
```
A migration self-assert + the write RPC enforce that `revision_id` belongs to `blueprint_id` and is in
`state='published'` when the placement is `enabled`. `geometry_mode` + `gen_metadata` describe HOW the polygon
was authored; `boundary` is the ONLY thing runtime reads (§4.5). `zone_kind`/`location_id`/`status`/`source`
of the old table are re-homed: kind derives from the adopted revision's behavior instances; `location_id`
moves to the junction (§2.5); `status='active'` maps to `published AND enabled`; `source`→`geometry_mode`.

### 2.5 `zone_placement_locations` — 0..N location association (DISTINCT relationship)
```
create table public.zone_placement_locations (
  placement_id uuid not null references public.zone_placements(id) on delete cascade,
  location_id  uuid not null references public.locations(id)       on delete cascade,
  primary key (placement_id, location_id)
);
```
The **location association** is distinct from blueprint reuse AND from geometry generation. Pirate placements
attach ≥1 hostile (`pirate_hunt`/`pirate_den`) location; mining/exploration placements typically attach 0
(they seed their own fields/sites inside the boundary). The re-homed coherence guard (a circle-around-location
placement whose adopted revision carries a pirate behavior must retain ≥1 hostile location) is enforced by the
write RPC + a self-assert, replacing the old `CHECK(source<>'circle' OR location_id is not null)`.

### 2.6 Typed placement overrides — `zone_placement_<kind>_overrides` (behavior-INSTANCE-scoped)
Overrides attach to a **specific behavior instance** of the placement's adopted revision — matched by KIND —
not to the placement as undifferentiated config. A placement may carry a typed override row PER kind its
adopted revision contains; each row has **nullable** columns (each with the same CHECKs as the default), where
NULL = inherit. No jsonb overrides anywhere.

```
-- override for the pirate behavior instance on a specific placement (v1's ONLY override table)
create table public.zone_placement_pirate_overrides (
  placement_id    uuid primary key references public.zone_placements(id) on delete cascade,
  tier            integer check (tier >= 1),                      -- NULL = inherit published default
  base_difficulty double precision check (base_difficulty > 0),   -- NULL = inherit
  reward_tier     integer check (reward_tier >= 1),               -- NULL = inherit
  max_units       integer check (max_units between 1 and 6)       -- NULL = inherit; >1 needs §5 fix
);
-- mining / exploration override tables follow the same shape when those behaviors ship (v2+):
--   zone_placement_mining_overrides (placement_id pk; richness, radius_override, field_count nullable)
--   zone_placement_exploration_overrides (placement_id pk; site_count, metal_min, metal_max nullable)
```
The write RPC rejects an override whose kind is not present in the placement's adopted revision (no orphan
override). **Overrideable fields are exactly the columns above; anything not listed is not overrideable in
v1.**

### 2.7 Immutable-revision lifecycle, explicit publish, preview, revert, provenance
Three distinct lifecycles, never conflated:

| Layer | States | Transitions |
|---|---|---|
| **Blueprint identity** | active / archived | archive is soft-retire of the whole identity |
| **Blueprint revision** | draft → published → archived | draft is mutable; **publish freezes it immutably**; archive retires an old published revision (kept for audit/revert) |
| **Placement** | draft → published → (enabled/disabled) → archived | `published AND enabled AND archived_at is null` = live; disable = fast forward-only kill-switch |

**Publish is EXPLICIT and is option (a):** publishing a draft revision sets `state='published'`, stamps
`published_at`, freezes it, and sets the blueprint's `published_revision_id` to it — making it **AVAILABLE for
adoption**. **Publish does NOT auto-update any existing placement.** Repointing placements to a newer revision
is a **separate, explicit, transactional** operation:
- `zone_placement_adopt_revision(placement_id, revision_id)` — single placement.
- `zone_blueprint_roll_placements(blueprint_id, revision_id, scope)` — atomic bulk-roll over a chosen scope
  (all / selected / all-currently-on-revision-N). Runs in ONE transaction: **all targeted placements move or
  none do → no partial propagation.**

This gives the owner explicit control and prevents a silent global change. Because a placement pins a frozen
revision, an ordinary draft edit CANNOT alter live gameplay.

**Preview:** the editor calls the SAME server-side resolver (§5.3) in a read-only "what-if" mode against a
draft revision (and optional would-be overrides) to show the effective config BEFORE publish/adopt — never a
separate client-side merge.

**Audit history + revert:** every publish snapshots into `zone_authoring_audit` (§7.6). Revert-to-a-prior-
published-revision is a forward operation: re-point `published_revision_id` and/or roll placements back to an
existing (or re-published) prior revision — it never mutates the frozen old revision.

**Exact provenance of an encounter:** the combat stamp (§5.3) writes `zone_blueprint_revision_id` (and
`placement_id`) onto `combat_encounters`. Given any past encounter, the EXACT immutable revision defaults + any
placement override that produced its numbers are fully recoverable.

### 2.8 V1 INVARIANT (explicit — the first slice is bounded to exactly this)
The v1 slice supports, and the DB/RPC/editor/runtime should eventually **ENFORCE**, exactly:
- **one blueprint revision** (published) per active blueprint in play;
- **exactly one pirate behavior instance** on that revision;
- **1+ geographic placements** adopting that revision;
- **0+ location associations** per placement;
- an **optional typed pirate placement override** per placement;
- **draft / published / disabled** lifecycle;
- **NO** mining, **NO** exploration, **NO** multi-behavior execution, **NO** generic visual scripting, **NO**
  arbitrary configuration JSON.

Enforcement handles (implemented only in the v1 schema/RPC/editor slice, NOT here): a self-assert/CHECK that a
v1-eligible revision has exactly one behavior row and it is pirate; the write RPCs refuse non-pirate behaviors
and jsonb config; the editor exposes only pirate authoring; the runtime registry has only the pirate handler
registered.

### 2.9 Backfill of the 3 live zones — see §3.

---

## 3. Migration + legacy compatibility (PROPOSED — the 3 live zones stay byte-equivalent)

### 3.1 Legacy mapping (danger_zones → the new model)
The 3 live rows are `source='circle'`, `zone_kind='pirate'`, `created_by=null`, each with ONE `location_id`
→ an active `pirate_hunt` whose `base_difficulty`/`reward_tier` (25/t3, 15/t2, 10/t1) drive combat. They map:

| Live `danger_zones` fact | New-model home |
|---|---|
| the shared "these are pirate territory" identity | ONE seeded **blueprint** `slug='legacy-pirate-territory'` |
| today's frozen pirate config (inherit-from-location) | ONE **published blueprint revision** (`revision_number=1`, `state='published'`) |
| `zone_kind='pirate'` behavior | ONE **pirate behavior instance** on that revision, `difficulty_source='location'` (inherit → all defaults NULL = today) |
| each polygon row (`boundary`, SRID 0) | one **placement**, `geometry_mode='generated_circle'` (was `source='circle'`), adopting that revision, `published=true, enabled=true` |
| each `location_id` | one **location association** row (3 total) |
| (no per-zone tuning today) | **NO placement overrides** → full inherit |

**Byte-equivalence:** with the pirate behavior at `difficulty_source='location'` and NO overrides, the resolver
(§5.3) yields all-NULL stamps, and `process_combat_ticks`' `coalesce(override, loc.*)` reads the location
exactly as today. Byte-equivalent existing behavior is preserved iff no overrides are present — asserted in the
apply-proof.

### 3.2 Conversion steps
1. **Rename with compat view (PROPOSED, time-boxed §3.4).** `alter table danger_zones rename to
   zone_placements`; add new columns (`blueprint_id`, `revision_id`, `geometry_mode`, `gen_metadata`,
   `priority`, `published`, `enabled`, `archived_at`) with backfilled defaults; create view `danger_zones`
   projecting the compat shape (incl. `location_id` from the junction and `status` from `published AND
   enabled`) so `get_danger_zones` and the `0233` RLS/reads keep working during transition.
2. **Seed** the legacy blueprint + its one published revision + its one inherit pirate behavior instance.
3. **Backfill** each of the 3 rows: `blueprint_id`+`revision_id` = the legacy pair; `geometry_mode='generated_circle'`;
   `published=true, enabled=true, priority=0`; no override rows.
4. **Backfill the junction** — one row per non-null `location_id` (3 rows).
5. **Repoint the reads (real plpgsql work):** `pirate_intercept_leg_zone_hits` (`0233:311-322`) returns a
   SINGLE `location_id` and `evaluate_leg` (`0233:484-513`) opens combat for that ONE location. To honor
   N-location associations, BOTH the leaf's `RETURNS TABLE` shape and the orchestrator's single-location branch
   fan out over the junction. During transition (all live zones have exactly 1 attach) the fan-out is
   behavior-preserving.
6. **Generalize/retire the write path:** `get_danger_zones` gains revision/behavior/`attached_location_ids[]`;
   `pirate_zone_create` (hardcoding `zone_kind='pirate'`/`source='drawn'` at `0233:1464-1465`) is RETIRED for
   one behavior-agnostic, `location_ids[]`-accepting, owner-gated `zone_placement_save` RPC (one save
   authority — NO SPAGHETTI).

### 3.3 Apply-proof pins
- `count(zone_placement_locations) = count(danger_zones.location_id IS NOT NULL)` before rename (= 3).
- all 3 placements adopt the legacy published revision; its pirate behavior is `difficulty_source='location'`;
  no override rows exist.
- re-running an intercept roll on a backfilled zone fires and opens combat at the SAME location with IDENTICAL
  enemy HP/count/reward (inherit = byte-equivalent).
- `get_danger_zones` output shape unchanged for existing readers via the compat view.

### 3.4 Compat view lifetime + removal gate (no indefinite compat layer)
The `danger_zones` compat view is a **transition shim, not a permanent surface.** It has:
- **Owner:** the same slice that introduces `zone_placements` (Slice C) owns the view and its removal.
- **Removal gate:** the view is DROPPED in a later cleanup slice once ALL of: (a) `get_danger_zones` and every
  `0233` reader are repointed to `zone_placements`/the new read RPC; (b) `pirate_zone_create` is retired; (c)
  the client no longer references the `danger_zones` name; (d) an apply-proof asserts zero remaining references.
- **Deprecation criteria:** tracked as an explicit follow-up slice (§8 note); the view must NOT outlive the
  Slice-D RPC generalization + Slice-E editor cutover. No indefinite dual-name layer.

The rename + compat view are **PROPOSED**, applied only inside their gated migration slice with a separate
prod-migration approval.

---

## 4. Shared-map extraction + editor UX (PROPOSED — one map, player + owner editor)

### 4.1–4.4 One shared, presentation-only map foundation
**The duplication today:** `GalaxyMap.tsx` renders through the UNIFIED fixed-coordinate frame —
`openSpaceTransform.worldToViewBox` (SRID-0 world ±10000 → `viewBox 0 0 1000 1000`, Y-inverted) +
`galaxyCamera` (`{k,tx,ty}` zoom/pan, `MIN_K/MAX_K`, `clampPan`, `focusCamera`) — and composes layers
(`territoryLayer`, `miningFieldRangeLayer`, `dangerZoneLayer`, `spatialCombatLayer`, `teamMarkers`,
`LocationMarker`). `ZoneEditor.tsx` **forks all of it**: its own `makeFit` fit-to-content transform (a SECOND,
incompatible world↔SVG projection), its own hand-rolled polygon rendering, its own markers, its own
click-inversion. Two projections + two renderers for one map = spaghetti.

**Extraction target (both surfaces mount ONE foundation):**
1. **Projection authority = `openSpaceTransform` (already the single authority).** Delete `ZoneEditor`'s
   `makeFit`. The editor uses `worldToViewBox`/`screenToWorld` + `galaxyCamera` exactly like the player map;
   fit-to-content is `galaxyCamera.focusWorldPoints` — no second transform.
2. **Extract a headless `<MapCanvas>` primitive** from `GalaxyMap` — SVG viewport + camera state
   (pan/zoom/reset, pointer→world) + a declarative layer list — NO gameplay logic, NO DB writes. `GalaxyMap`
   becomes `MapCanvas` + player layers + command hub; `ZoneEditor` becomes `MapCanvas` + read-only layers + an
   **owner-only edit overlay**.
3. **Shared read-only layers** for both: `LocationMarker`, `territoryLayer`, the zone-placement layer,
   `miningFieldLayer`. The editor stops re-drawing these by hand.
4. **The edit overlay is the ONLY editor-specific surface** — it renders on top of the shared canvas and emits
   draft geometry; it holds no projection or marker logic of its own.

### 4.5 Editor UX + generated-geometry lifecycle (real game map, owner-only, PROPOSED)
The editor operates on the **actual game map** (the shared `MapCanvas`), owner-only (§7). Placement geometry
has three modes (`zone_placements.geometry_mode`): **freeform | generated_circle | generated_corridor**.

**Generators, all MATERIALIZE into ONE canonical polygon (`boundary`):**
- **freeform (custom polygon)** — click vertices; validated `ST_IsValid`, min-verts, in-bounds, non-self-intersecting.
- **generated_circle** — pick a location + radius; the editor bakes a closed N-gon into `boundary`.
- **generated_corridor** — pick two+ locations + width; the editor bakes a swept capsule/rectangle into `boundary`.

**Generation metadata vs runtime geometry:** generated modes may retain, in `gen_metadata` (jsonb, METADATA
ONLY): source location ids, radius, corridor width, and a **generation version**. The runtime NEVER reads
`gen_metadata` — it reads the materialized `boundary` and nothing else. There is exactly ONE point-in-polygon
authority; no implicit second geometry path.

**Editing a generated polygon — the editor REQUIRES an explicit choice (no implicit second authority):** if the
owner manually edits vertices of a `generated_*` placement, the editor forces one of:
- **Regenerate from the source rule** — re-run the generator from `gen_metadata`, DISCARD the manual edits,
  re-materialize `boundary`. Stays `generated_*`.
- **Detach to freeform** — keep the manual edits, set `geometry_mode='freeform'`, and DROP the now-stale
  `gen_metadata` (its generation rule no longer governs the shape).
- **Cancel** — abandon the edit.

**No silent regeneration:** live materialized geometry is NEVER moved or regenerated just because an associated
location moved or changed. A location change may FLAG a `generated_*` placement as "source drifted" for owner
review, but re-materialization only happens on an explicit owner regenerate. The location association (§2.5) is
a contextual link, not a geometry authority.

**Right-click a zone → context menu:** move / resize / duplicate / change-blueprint (adopt a different
published revision, §2.7) / edit-overrides (typed form, §2.6) / disable / archive / inspect / revision-history.

**Lifecycle from the editor:** **draft → publish (atomic, freezes the revision) → separate enable → fast
disable/kill-switch** (§2.7). Preview uses the server resolver (§5.3), never a client-side merge.

**Explicitly DEFERRED (§10 D11):** paint/heatmap **density layers** (brush-painted intensity fields) and
rule-driven **trigger volumes** (conditional geometry evaluated by rules rather than a stored polygon) are OUT
of scope. v1–v3 use only stored materialized polygons.

**Guardrails:** the shared-map extraction slice (Slice B) changes NO gameplay and NO data — a pure client
refactor proven by regression (player map pixel-identical; editor saves via existing RPC unchanged).
`openSpaceTransform` stays pure. No new projection is introduced — the point is to DELETE the second one.

---

## 5. Pirate-behavior runtime semantics + the effective-config resolver (PROPOSED)

### 5.1–5.2 Trigger + eligibility (reusing the CURRENT path)
1. **Trigger event:** leg departure. `pirate_intercept_evaluate_leg` (`0233:377`) is the ONE trigger, fired
   synchronously in the movement transaction. No client input decides combat — the client only issues the move.
2. **Placement eligibility:** the ambushing placement's adopted revision must carry a pirate behavior instance
   AND the placement must associate ≥1 location that is active AND `location_type in
   ('pirate_hunt','pirate_den')` (`0233:474-488,1459`). A standalone / no-hostile-location placement only forces
   a STOP, never a fight (the `0233:474-482` stub) — v1 does not auto-mint host locations (§10 D1).

### 5.3 THE ONE authoritative effective-config resolver (server/DB is the sole authority)
There is exactly ONE resolver, in the trusted server/DB layer, used by BOTH runtime and editor-preview. It is
NEVER duplicated in the browser or across RPC/combat-runtime.
- **Input:** a placement (→ its adopted `revision_id`) and, per behavior kind on that revision, the placement's
  typed override row (if any).
- **Rule (per kind):** `effective(field) := coalesce(placement_override.field, published_behavior.field)`.
  **NULL means inherit** the published default; a missing override row = full inherit.
- **Overrideable fields (pirate, v1):** `tier`, `base_difficulty`, `reward_tier`, `max_units` (§2.6). Nothing
  else is overrideable.
- **Validation:** identical CHECKs on the override columns as on the defaults (`base_difficulty>0`,
  `max_units∈[1,6]` and >1 requires §5.5, `reward_tier≥1`, `tier≥1`); the write RPC re-validates on save; the
  resolver assumes valid inputs (belt-and-suspenders self-assert in the apply-proof).
- **Config version identity:** the resolver's output is tagged with the exact `revision_id` (immutable, §2.2)
  plus whether an override row was present — this pair uniquely identifies the config that produced any result.
- **Audit:** the resolver's decision is recorded as `{defaults, override, effective, revision_id}` in
  `zone_authoring_audit` on publish/adopt and referenced by the encounter stamp for runtime (§7.6).
- **Editor preview uses the SAME resolver** in read-only what-if mode. The client may DISPLAY a preview but
  never DEFINES the final effective config — the server does.

### 5.4 Stamp + read (least-invasive seam, ONE function edit)
3. **Resolve → stamp:** after `v_enc` is read (`0233:515`), the pirate handler runs the §5.3 resolver → effective
   `{difficulty, reward_tier, max_units}` and issues ONE statement:
   `update combat_encounters set difficulty_override=…, reward_tier_override=…, max_units_override=…,
   zone_blueprint_revision_id=…, zone_placement_id=… where id = v_enc`. Both ids are already in scope — this
   replaces PR #221's proposal to thread an override payload through 4 frozen signatures. Synchronous, before
   any cron tick reads the row. The `zone_blueprint_revision_id` stamp is the provenance key (§2.7).
4. **Read (override-else-location):** add nullable columns to `combat_encounters` (`difficulty_override
   double precision`, `reward_tier_override integer`, `max_units_override integer`, `zone_blueprint_revision_id
   uuid`, `zone_placement_id uuid`) — all NULL by default so every one of the 14 existing encounters is
   untouched. In `process_combat_ticks`, compute effective values ONCE after the loc read (`0234:566`):
   `coalesce(e.difficulty_override, loc.base_difficulty)`; `coalesce(e.reward_tier_override, loc.reward_tier)`;
   `coalesce(e.max_units_override, cfg_num('enemy_synthetic_max_units'))`. Substitute at `0234:690,692,696,698,
   964,981` / `898,1074` / `694`. `e` is the loop row — no extra query. **Two coalesce layers:** the resolver's
   published⊕override (authoring), then this location-inherit (runtime) — both pass NULL through for a pure
   legacy inherit zone → byte-equivalent to today.

### 5.5 CO-REQUISITE / PREREQUISITE #2 — the LIVE latent blocker for `max_units>1`
Constraint `combat_units_encounter_id_unit_type_id_key UNIQUE(encounter_id, unit_type_id)` still exists
(verified live via `pg_constraint`). The spatial enemy spawn inserts N rows ALL with
`unit_type_id='pirate_synthetic'` and NO on-conflict (`0234:707-718`). For `danger>=2 → v_enemy_count>=2`
(`0234:694`), the 2nd insert throws `unique_violation`, caught by the per-encounter handler (`0234:1134-1139`)
→ the whole tick rolls back and "retries next tick" forever. **Wave-1 (single pirate) works; wave-2+
multi-pirate waves silently stall** — and because `spatial_combat_enabled=TRUE`, this is LIVE (prod has ZERO
enemy-side `combat_units` rows across 14 terminal encounters). **Only single-pirate combat is proven; multiple
pirates in one wave is NOT verified and this doc does not claim it works.** Fix (mirror the `0167`
partial-unique pattern): partial unique index excluding `side='enemy'`, or a distinct `unit_type_id` slot per
synthetic row. **This is prerequisite #2, not deferrable** — any pirate config with `max_units>1` is
meaningless until it lands (§8 Slice G, §9 R3).

### 5.6 Cooldown / respawn / dup-reward / edit-while-inside
6. **Cooldown scope:** NONE per-zone today. Present idempotency: one active encounter per fleet AND per presence
   (`combat_encounters` unique partial indexes, `20260616000014:35-38`). A per-zone/per-revision cooldown is
   net-new plumbing — deferred, NULL/unused in v1.
7. **Respawn:** there is NO zone-level respawn. "Respawn" is strictly IN-ENCOUNTER waves (`next_wave_at` /
   `combat_wave_transition`). A behavior `respawn/cooldown_seconds` is future plumbing, not a coalesce point.
8. **Dup-reward:** `reward_grant` is idempotent on `(source_type, source_id)` DO NOTHING (`20260616000015:40`).
   Rewards travel home in `total_rewards_json` (`0234:643`), secured on arrival, forfeited on defeat. The
   override stamp changes only the MAGNITUDE (`v_eff_reward`), never the grant identity.
9. **Edit-while-inside:** ordinary edits don't reach players (draft state + frozen adopted revision, §2.7). An
   in-flight encounter already stamped its resolved config + `revision_id` at creation (step 3), so
   re-publishing/adopting/disabling mid-encounter does NOT retroactively change the live fight — the stamped
   `combat_encounters` row is the frozen truth. Disable/archive only stops FUTURE ambushes. Forward-only
   kill-switch, never a live rewrite.

**Invariants (RPC + self-assert):** `difficulty_override>0`; `max_units_override∈[1,cap]` AND requires the §5.5
fix for >1; `reward_tier_override` coalesces through `greatest(x,1)`; inherit revision + no override ⇒ all
stamps NULL. **Apply-proof pins:** a tier-1 vs tier-3 (published default OR placement override) at the SAME
location produces different enemy HP and (post-§5.5-fix) different N on live Postgres; an inherit revision
reproduces today's numbers byte-for-byte. **The multi-pirate (N≥2) pin is gated on prerequisite #2 landing;
until then the proof asserts single-pirate parity only.**

---

## 6. Growth path, compatibility policy, overlap + priority (PROPOSED — deterministic, tested)

### 6.1 Controlled growth path + the compatibility-policy extension point
- **v1 — one behavior instance per revision (pirate only).** No intra-revision behavior conflict, **no
  compatibility policy needed yet**. The FIRST implementation slice stays here (§2.8 invariant).
- **v2 — multiple compatible behaviors per revision.** A revision MAY carry several behaviors. Before it ships,
  a **centrally-validated COMPATIBILITY POLICY** must exist — a SINGLE policy authority (NOT rules scattered
  inside individual behavior handlers) responsible for:
  - which behavior KINDS may coexist on one revision / overlap in space;
  - whether >1 of the SAME kind is ever permitted (default: no, §2.3);
  - per-behavior **priority**;
  - same-kind **overlap** resolution;
  - cross-kind **interaction** rules;
  - behavior **activation ordering** within a resolution;
  - **failure isolation** (one behavior's handler erroring must not corrupt another's).
  This policy is consulted by the resolver/registry dispatch; handlers declare their needs but never decide
  compatibility themselves. **Documenting it here does NOT expand v1 scope** — v1 registers only the pirate
  handler and the policy trivially permits the single-behavior case.
- **v3 — conditions / seasonal / faction / hazard / triggers** (and the deferred trigger volumes, §4.5) layer
  on top of v2. Out of scope for the first slices.

### 6.2 Cross-placement resolution (applies from v1)
Input: the fleet's leg geometry intersected with all `published AND enabled AND archived_at is null` placements
(via `gist` + `ST_Intersects`). Rules:
1. **Boundary inclusion is fixed and tested:** inside iff `ST_Intersects(boundary, geom)` (closed boundary — a
   point on the edge counts as inside). Matches the existing engine (`0233:315-322`), pinned by an on-edge test.
2. **Same behavior, overlapping placements:** the **highest-`priority` enabled** placement wins; `priority
   desc` then `placement_id asc` as a last-resort tiebreak (but see 4).
3. **Different behaviors, overlapping (v2):** coexist ONLY if the compatibility policy (6.1) permits;
   incompatible overlap is a VALIDATION error at save, never a runtime coin-flip. *(Moot in v1.)*
4. **Same behavior, EQUAL priority, overlapping → FAILS VALIDATION deterministically** at save (a spatial check
   in the write RPC), so runtime never faces an ambiguous same-behavior tie.
5. **Determinism:** given a fixed world + placement set, resolution is pure — no randomness in selection. The
   emergent `order by exposure_fraction desc` (`0233:428`) is REPLACED by authorable `priority` as the primary
   key, `exposure_fraction` retained only as a documented sub-tiebreak if ever needed.

### 6.3 Handler registry (NO central conditional block)
An explicit registry maps `behavior kind → handler`, each conforming to ONE shared contract
(resolve-eligibility / resolve-config-via-the-§5.3-resolver / stamp-or-apply / record). Dispatch looks up the
handler by kind — NO central `if kind='pirate' … elsif …`. **Each handler REUSES its behavior's existing
authoritative system and never duplicates it:** the pirate handler reuses the CURRENT combat/encounter path
(`pirate_intercept_evaluate_leg` → `process_combat_ticks`, §5); the mining handler reuses
`command_mining_extract`/`process_mining_securing` (§1.3); the exploration handler reuses `command_scan`
(§1.4). Compatibility decisions live in the §6.1 policy, not in handlers. Adding a behavior = a registry entry
+ a typed behavior table + a handler + a policy cell — never editing a god-function.

---

## 7. Owner-only server-authoritative security model (PROPOSED fix; PREREQUISITE #1, ships FIRST)

**This slice ships FIRST (Slice A), UNCONDITIONALLY (a guard is never flag-gated), ahead of all feature work —
the write surface it protects is LIVE and exploitable in prod today (§1.5).**

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
   be SELF-PROMOTABLE — a privilege-escalation hole. A `game_config('owner_user_id')` key is an acceptable
   alternative (config is service_role-written) but a deny-all typed table is cleaner.
2. **Owner seed is OUT OF GIT.** A service_role activation script (`scripts/activate-*.sh` precedent,
   `set_game_config` `20260618000046:406`) inserts the owner uuid AFTER deploy. Never hardcode the uuid.
3. **Fail closed.** With no owner seeded, `is_owner()` returns false for everyone — NOBODY can write, including
   the owner, until the seed runs. Deploy order: (a) deploy the security migration, (b) run the seed, (c) then
   rely on the editor.
4. **Protected RPCs only — no direct browser writes.** Every mutation is a `SECURITY DEFINER`,
   `set search_path=public` function that re-checks `auth.uid()` AND `is_owner()` at its own boundary, returns
   `jsonb {ok:false, reason:'not_owner'}` on failure, and KEEPS `grant execute to authenticated` (deny in the
   body, the house pattern — not an ACL revoke):
   - **Guard `pirate_zone_create`/`delete` immediately** (before ANY feature RPC) — add
     `if not public.is_owner(auth.uid()) then return jsonb_build_object('ok',false,'reason','not_owner');
     end if;` right after the existing `auth.uid()`-null check. Change delete scope from `created_by=v_player`
     to `is_owner`-only so the owner can remove ANY drawn zone (fixes attacker-zone persistence).
   - Carry the same guard into the new `zone_blueprint_save/publish/archive`,
     `zone_revision_save_draft/publish/archive`, `zone_placement_save/publish/enable/disable/archive/
     adopt_revision`, `zone_blueprint_roll_placements`, and `zone_placement_override_save` RPCs — owner-gated
     from day one. Retire `pirate_zone_create` (one save authority).
5. **RLS on every authoritative table:** enable RLS, SELECT-only + scope-narrowed policies (owner-select for
   authoring tables; dark-gated public SELECT only for the render read, mirroring `danger_zones_select_when_lit`
   `0233:200-206`). NO client INSERT/UPDATE/DELETE grant anywhere.
6. **Audit table (create/update/publish/enable/disable/archive/adopt/revert):**
   ```
   create table public.zone_authoring_audit (
     id uuid primary key default gen_random_uuid(),
     actor uuid not null,
     action text not null check (action in
       ('create','update','publish','enable','disable','archive','delete','adopt','revert')),
     placement_id uuid, blueprint_id uuid, revision_id uuid,
     payload jsonb, created_at timestamptz not null default now()
   );  -- RLS owner-select-only, NO client write grant; sole writers = the zone RPCs
   ```
   `payload` records the resolver's `{defaults, override, effective, revision_id}` on publish/adopt so audit
   shows defaults + overrides + effective together (§5.3). (`pirate_intercepts` is a combat-roll log, a
   different concern — this is the authoring log.)
7. **Unauthorized-path tests (in `supabase start` apply-proof):** a SECOND authenticated NON-owner session calls
   each mutation RPC → assert `reason='not_owner'` AND zero rows changed; owner → assert `ok`. Plus deploy-time
   self-asserts: `is_owner()`/`app_owners` exist; the RPCs still carry the `authenticated` execute grant via
   `has_function_privilege` (deny is in-body, not an ACL revoke).
8. **The hidden route (`/dev/zones`, `dev_zone_editor_enabled`) is UX only, never authz.**

NO-SPAGHETTI: one owner authority (`app_owners`), one `is_owner()` helper consulted by all zone RPCs, one audit
writer path — no scattered owner-uuid literals, no per-RPC ad-hoc checks.

---

## 8. Phased PR roadmap (PROPOSED — dark-first slices; the two prod prerequisites go FIRST)

Each slice: coherent + reviewable, NON-OVERLAPPING file ownership, its OWN flag (features only — the security
guard is unflagged), an apply-proof self-assert (`supabase start` against real PG), a SEPARATE prod-migration
approval, read-only prod verification, an owner-gated enable. Precise state language only (Designed /
Implemented locally / PR open / CI green / Merged / App deployed / Migration deployed / Production verified /
Runtime enabled) — never "done."

**Two live prod prerequisites land BEFORE any editor/runtime feature work:** (#1) close the unguarded
`pirate_zone_create` security hole (Slice A); (#2) the `combat_units` UNIQUE cardinality fix (§5.5) — a LIVE
latent blocker; carried by Slice G but treated as a hard prerequisite for any `max_units>1`.

| Slice | Name | Flag | Owns (files) | Verification gate | Prod activation |
|---|---|---|---|---|---|
| **A** | **Security spine** (PREREQUISITE #1, ships FIRST, unconditional) | none (guard) | new `…0239_zone_owner_security.sql`; `app_owners`, `is_owner()`, `zone_authoring_audit`; guard on `pirate_zone_create/delete` | apply-proof: non-owner refused + zero rows; owner ok; ACL-split self-assert | migration deploy + seed script; **closes live hole** |
| **B** | **Shared-map extraction** (client only) | none (refactor) | `src/features/map/*` (`GalaxyMap`→`MapCanvas`), `src/features/dev/ZoneEditor.tsx` | player map pixel-identical (regression/snapshot); editor saves via existing RPC unchanged | none (no data/gameplay change) |
| **C** | **Identity + immutable revisions + behavior schema + backfill** (gated off) | `zone_blueprints_enabled` | new `…0240_zone_schema.sql`; `zone_blueprints`, `zone_blueprint_revisions`, `zone_pirate_behaviors` (+ mining/exploration tables & child pools), `zone_placements` (rename+**time-boxed** compat view §3.4), `zone_placement_locations`, `zone_placement_pirate_overrides`; backfill 3 zones; **v1-invariant CHECKs (§2.8)** | backfill counts pinned; legacy revision reproduces today's intercept byte-for-byte; published-revision immutability self-assert; compat view keeps `get_danger_zones` stable | migration deploy; read-only verify; enable stays OFF |
| **D** | **Owner-gated RPCs + audit + the ONE resolver** | `zone_blueprints_enabled` (reuse) | new `…0241_zone_rpcs.sql`; blueprint/revision/placement/override save+publish+enable+disable+archive+**adopt_revision**+**roll_placements**; the §5.3 resolver; retire `pirate_zone_create` | RPC ACL split; owner-only; audit row per action; resolver ⊕ + provenance pinned; publish does NOT auto-update placements; atomic roll = all-or-none | migration deploy; read-only verify |
| **E** | **Real-map editor (draft-safe)** | `dev_zone_editor_enabled` (reuse) | `src/features/dev/*`, `src/features/map/pirateApi.ts`→zone API | editor on shared `MapCanvas`; 3 geometry modes MATERIALIZE; generated-edit explicit choice (regen/detach/cancel); right-click menu; preview via server resolver; saves DRAFTs only | app deploy; owner smoke |
| **F** | **Read-only runtime resolution** (NO effects) | `zone_resolution_enabled` | new `…0242_zone_resolution.sql`; point-in-polygon + priority + overlap resolver + handler registry (no dispatch to effects) | apply-proof: PIP/priority/overlap/equal-priority-fails/boundary-edge; resolver returns the right placement + effective ⊕ config + revision id, applies NOTHING | migration deploy; read-only verify |
| **G** | **Pirate integration** (v1 = one pirate behavior) | `zone_pirate_handler_enabled` | new `…0243_zone_pirate_handler.sql`; `combat_encounters` override + provenance cols; `evaluate_leg` resolve+stamp; `process_combat_ticks` coalesce; **`combat_units` cardinality fix (PREREQUISITE #2)** | apply-proof: tier-1 vs tier-3 (default or override) at same location differ; inherit reproduces today; **single-pirate parity always; N≥2 pin gated on the fix landing** | ONE blueprint+revision+placement, disabled; separate migration approval; prod verify; **owner-gated enable** |
| **H** | **Mining behavior** (v2 — needs compat policy if co-placed) | `mining_zone_blueprints_enabled` (+ `mining_enabled`, lit) | new `…0244_zone_mining_handler.sql`; polygon→`mining_fields` seeder; `zone_placement_fields` link; mining behavior + override tables | apply-proof: N fields ALL inside boundary (`ST_Contains`); reward bundle valid; extract works; compat policy cell asserted if co-placed | migration deploy; prod verify; owner-gated enable |
| **I** | **Exploration behavior** (LAST) | `exploration_zone_blueprints_enabled` (+ `exploration_enabled`) | first LIGHT+PROVE exploration; then `…0245_zone_exploration_handler.sql`; site seeder; `zone_placement_sites` link | exploration proven live end-to-end FIRST; then N sites inside boundary; scan→discover→reward | migration deploy; prod verify; owner-gated enable |
| **J** | **Compat-view removal** (cleanup) | none | drop `danger_zones` compat view; repoint any stragglers | apply-proof: zero remaining `danger_zones` references (§3.4 removal gate) | migration deploy; read-only verify |

**Dependencies:** A → everything. C → D → E, F. F → G → H → I. B is independent (client refactor). G carries the
§5.5 fix as a hard prerequisite. H/I are v2/v3 and must not co-place another behavior until the compatibility
policy (§6.1) covers the cell. J only after the §3.4 removal gate is met.

---

## 9. Risks, failure modes, rollback / disable

| # | Risk / failure mode | Detection | Rollback / disable |
|---|---|---|---|
| R1 | **Live griefing via unguarded `pirate_zone_create`** | prod audit of `danger_zones` rows with non-null `created_by` | Slice A guard (PREREQUISITE #1); owner `delete-any`; until then service_role cleanup |
| R2 | **Wrong SRID on a new geometry column** → every exposure/length calc corrupts silently | migration self-assert `ST_SRID(boundary)=0`; apply-proof intercept roll | reject migration in CI; SRID-0 pinned self-assert |
| R3 | **`combat_units` unique constraint stalls wave-2+** (LIVE today for N≥2; only single-pirate proven) | prod: zero enemy-side `combat_units` rows; apply-proof wave-2 test | Slice G PREREQUISITE #2 fix; until then keep `max_units=1` and DO NOT claim multi-pirate works |
| R4 | **N-location fan-out regression** (leaf/orchestrator still single-location) | apply-proof: 2-location placement — assert BOTH fire | keep `danger_zones.location_id` live during transition; revert read repoint |
| R5 | **Draft edit / republish leaks to players** | apply-proof: draft placement never resolves; live placement pins a frozen revision | resolution filters `published AND enabled AND archived_at is null` on BOTH placement + adopted revision |
| R6 | **Silent global propagation on publish** (all placements change at once) | resolver/RPC test: publish leaves placements' `revision_id` untouched | publish = availability only; adoption is explicit + atomic (§2.7); no auto-update |
| R7 | **Partial propagation on a bulk roll** | apply-proof: interrupt a roll — assert all-or-none | `zone_blueprint_roll_placements` is single-transaction (§2.7) |
| R8 | **Mutating a published revision** (breaks provenance/immutability) | self-assert: published revision + its behavior rows reject UPDATE/DELETE | immutability enforced by RPC + CHECK (§2.2); edits fork a new draft |
| R9 | **Second geometry authority** (circle/corridor math read at runtime) | code review + apply-proof: runtime reads `boundary` only; `gen_metadata` never in a hot path | materialize-on-save (§4.5); explicit regen/detach/cancel; no silent regeneration |
| R10 | **Untyped override/config creep** (a jsonb bag appears) | schema review; no jsonb config/override columns exist | typed tables only (§2.3, §2.6); reject jsonb config in review |
| R11 | **Equal-priority same-behavior ambiguity** | save-time spatial validation; apply-proof equal-priority-fails | reject at authoring, never at runtime |
| R12 | **Generator non-determinism breaks CI** | apply-proof pins INVARIANTS (count, all-inside, valid shape), never coords | slime discipline (`0237`): valid-by-construction, invariant asserts |
| R13 | **`mining_extract` CREATE-OR-REPLACE regression** (`0143→0172` episode) | apply-proof mining extract test; diff review | one-authority-per-function; re-merge advisory-lock + depletion hunks onto head |
| R14 | **Fail-open owner seed** (RPCs live before seed) | deploy-order runbook; `is_owner()` fail-closed | fail-closed by design; documented deploy order A→seed→editor |
| R15 | **v2 behaviors co-placed without a compatibility cell** | policy assert: any behavior overlap requires a policy cell | keep v1 one-behavior-per-revision; no co-placement until §6.1 covers the cell |
| R16 | **Compat view outlives its purpose** | §3.4 removal gate; Slice J | drop in Slice J once all readers repointed |
| R17 | **Building on unproven exploration** | flag `exploration_enabled=false` in prod | sequence exploration LAST; don't couple mining to `world_balance` |

**Kill-switches:** per-placement `enabled=false` and per-blueprint identity archive are fast, independent, and
retain config (§2.7). Archive is the soft-retire; prefer disable/archive over DELETE. Every feature slice's flag
disables the behavior at the server boundary. The security guard has NO disable.

---

## 10. Unresolved OWNER decisions (each with a safe recommended default)

Implementation proceeds on the defaults below without blocking; the owner can override any before its slice.

- **D1 — Standalone combat zones (no host location).** Combat needs a real `locations` row (`0233:474-488`
  stub). **Default: require ≥1 hostile-location association for v1** (no auto-mint). Multi-association covers
  "reuse one blueprint across the map." Auto-minting hidden host locations is a later additive option.
- **D2 — Fate of `danger_zones`.** `zones` is taken (world hierarchy). **Default (PROPOSED): rename to
  `zone_placements` with a TIME-BOXED `danger_zones` compat view** (defined owner + removal gate, §3.4; dropped
  in Slice J). Plan's `zones` view is IMPOSSIBLE (§1).
- **D3 — Tier → difficulty mapping.** **Default: a `zone_tier_difficulty` config table** (tier 1/2/3 →
  `base_difficulty`), one authority, no scattered literals.
- **D4 — Publish propagation semantics.** **Default: publish = make-available-for-adoption ONLY; NO
  auto-update of placements** (§2.7 option a). Repointing is explicit (single or atomic bulk-roll), preventing
  partial/silent propagation.
- **D5 — Behavior + override carrier.** **Default: typed per-kind tables** (§2.3, §2.6) — owner-mandated over
  jsonb; DB validation + catalog FK + `schema_version`. No arbitrary JSON.
- **D6 — Same-behavior equal-priority overlap.** **Default: FAIL VALIDATION at authoring** (§6.2).
- **D7 — Per-zone cooldown / respawn / loot-pool / spawn-probability.** GLOBAL today, net-new plumbing.
  **Default: OUT of v1** (behavior columns reserved, NULL/unused); revisit after pirate integration is proven.
- **D8 — Mining extract radius at scale.** `mining_extract_radius=60` (global) makes fields point-sources.
  **Default: expose `radius_override` on the mining behavior and warn in the editor** when `field_count` is too
  low for the polygon area; do NOT couple mining to `world_balance`.
- **D9 — Mining depletion.** **Default: ship mining zones WITHOUT depletion** (`world_balance_enabled=false`);
  per-zone depletion waits until `world_balance` is lit and proven.
- **D10 — Delete `danger_zones.location_id`.** **Default: keep it live during transition (dark), drop it in a
  later cleanup slice** once the junction read repoint is proven — never in the slice that adds the junction.
- **D11 — Density paint / heatmap layers + rule-driven trigger volumes.** **Default: DEFERRED** to a later
  phase (§4.5). v1–v3 use only stored materialized polygons.
- **D12 — When to introduce multi-behavior revisions (v2).** **Default: NOT in the first slices** — v1 keeps one
  behavior per revision; v2 unlocks only after the centrally-validated compatibility policy + per-behavior
  conflict resolution exist and are apply-proof-tested (§6.1).
- **D13 — Whether >1 behavior of the SAME kind is ever allowed.** **Default: NO** — `revision_id` PK on each
  behavior table enforces ≤1 per kind (§2.3); revisit only if a concrete need is proven.

---

## Appendix — reconciliation with prior documents

**Kept from the rigid single-kind draft (verified correct, carried forward unchanged):** the entire §1 grounded
audit with file:line; the server-authoritative owner-only security spine (`app_owners`/`is_owner()`/audit/
fail-closed/unauthorized-path tests) shipping FIRST as prerequisite #1; the combat coalesce-override mechanism
(`coalesce(override, loc.*)` in `process_combat_ticks`, one function edit); the 3-live-zone byte-equivalent
compat; the `combat_units` cardinality blocker as prerequisite #2; the shared-map extraction; the precise-state-
language + separate-migration-approval discipline; the risk table + open-decisions-with-defaults format.

**Refined (single-kind template → immutable-revision behavior-module blueprint):**
1. `zone_templates` (one `zone_kind`, one profile) → **`zone_blueprints` (stable identity) +
   `zone_blueprint_revisions` (immutable published snapshots)**. Kind is now *which behavior tables reference a
   revision*, not a scalar.
2. One profile-per-kind → **typed per-kind behavior INSTANCES** keyed by `revision_id` (≤1 of each kind),
   each DB-CHECK-validated + catalog-FK'd, never jsonb; room for hazard/trade/visibility/faction/trigger/
   travel/regeneration.
3. **Immutable published revisions**: a live placement adopts a SPECIFIC published revision; edits fork a new
   draft; publish is EXPLICIT (make-available, no auto-update); adoption is separate + atomic; preview/audit/
   revert/exact-provenance are first-class (§2.2, §2.7).
4. Override locus → **behavior-INSTANCE-scoped placement overrides** atop published defaults; `effective =
   published defaults ⊕ validated typed override` via ONE server-side resolver used by runtime AND preview,
   never duplicated client-side (§2.6, §5.3).
5. **Generated-geometry lifecycle**: `geometry_mode` freeform|generated_circle|generated_corridor; metadata vs
   canonical polygon; manual edit forces regen/detach/cancel; no silent regeneration (§4.5).
6. **Compatibility policy** documented as a central v2 extension point (not per-handler) — without expanding v1
   (§6.1).
7. Explicit **v1 invariant** (§2.8) and consistent **terminology** (glossary).
8. Marked **PROPOSED vs CURRENT** throughout; `danger_zones` rename + compat view marked proposed with a
   defined lifetime + removal gate (§3.4, Slice J).

**Corrected / replaced from PR #221 (`docs/ZONE_TEMPLATES_PLAN.md`), still valid:** data model is owner-mandated
typed tables (now the blueprint/revision/behavior shape); combat is ONE function edit; the override stamp is a
post-`v_enc` `UPDATE` not a 4-signature thread; mining is NOT dark and has no richness/depletion columns and
`module_range_attributes` does not exist; the security spine the plan omitted ships first; N-location fan-out is
real plpgsql work.

---

## World Editor — Proposed Architecture (Unified)

**Status:** PROPOSED throughout. Everything in this section is target design, not built. Every **CURRENT**
claim cites real schema at `file:line`; everything else is **PROPOSED**. This section does NOT restructure §0–§10
above — it sits on top of them and cross-references. The blueprint/behavior-module Zone model (§2), the immutable-
published-revision philosophy (§2.2, §2.7), the ONE server-side effective-config resolver (§5.3), the owner-security
spine as prerequisite #1 (§7), and the two live prod prerequisites (§1.5 security hole, §5.5 `combat_units`
cardinality) all carry forward unchanged and are the foundation this section builds on.

### WE.0 Core thesis (stated unambiguously)

The long-term product is **ONE owner-only World Editor on the REAL game map.** Locations are only **ONE layer**
within it. Mining, exploration, and zones are **ALSO layers in the SAME editor.** They are **NOT separate editors,
NOT separate maps, NOT separate product experiences** — mining and exploration are later **MODULES of the same
editor**, reached by toggling a layer, never by navigating to a different tool.

The separate tables that exist today — `locations` (`20260616000002_world_map.sql:48-72`), `mining_fields`
(`20260618000103_mining_p12_fields_schema.sql:50-70`), `exploration_sites`
(`20260618000098_exploration_p11_sites_schema.sql:38-58`), and `danger_zones`
(`20260618000233_pirate_intercept_danger_zones.sql:182-198`) — are **migration/integration facts, NOT desired
product boundaries.** The DB keeps them distinct for correct domain integrity; the editor unifies how they are
**authored and visualized.**

**The model is: ONE World Editor shell + multiple typed content-layer ADAPTERS.** An **adapter** is the typed bridge
between the shared shell and a domain's authoritative model/commands — it is **NOT a separate editor**. The shell
knows nothing domain-specific; each adapter teaches the shell how to read, draw, inspect, and command one domain's
real tables. Adding a domain = adding an adapter, never forking the editor (NO SPAGHETTI: one editor authority,
compose don't fork).

### WE.1 Layer tree

```
World Editor
├── Locations   (ports, pirate sites, stations, other point locations)
├── Mining      (mining sites, resource fields, mining zone profiles)
├── Exploration (exploration sites, discoveries, anomalies, exploration regions)
├── Zones       (pirate zones, mining zones, exploration zones, future behavior zones)
└── Future layers (trade routes, faction territories, missions, hazards, events)
```

Every layer renders through the **same** real map, the same camera/pan/zoom, the same world-coordinate system, the
same selection/inspection patterns, the same owner authorization, the same draft/publish/enable lifecycle, and the
same audit/rollback framework (§WE.10). A layer differs from another ONLY in its typed adapter — the domain model,
the domain commands, and the typed inspector/authoring form it contributes.

### WE.2 The shared World Editor shell

The shell owns everything domain-agnostic, exactly once:

| Shell owns | Notes |
|---|---|
| Real map rendering | The shared map primitives (§WE.11), never a bespoke canvas |
| World-coordinate conversion | `openSpaceTransform` `worldToViewBox`/`viewBoxToWorld` (§WE.11) — ONE projection authority |
| Camera state, pan/zoom | `galaxyCamera` `{k,tx,ty}` |
| Selection + layer visibility | select any typed content item; toggle layers on/off |
| Point-placement + polygon-editing tools | shared typed geometry tools (§WE.4) |
| Shared inspector patterns | a common inspection shell each adapter fills with typed fields |
| Draft / published / enabled state display | one lifecycle vocabulary (§WE.10) |
| Authorization state | one owner spine (§WE.10, §7) |
| Validation results + dependency warnings | surfaced uniformly (§WE.10 dependency validation) |
| Audit / revision history | one audit framework (§WE.10) |
| Publish / enable / disable / archive actions | one lifecycle control surface |

**Typed domain adapters** connect the shell to the real underlying systems, one per layer:
`LocationLayerAdapter`, `MiningLayerAdapter`, `ExplorationLayerAdapter`, `ZoneLayerAdapter`, `FutureLayerAdapter`.
Each adapter bridges the shell to its domain's authoritative model and commands (§WE.5–§WE.8) — it is the typed
seam, **not** a second editor.

**Adapter boundary (explicit).** The adapters are **MODULES INSIDE ONE World Editor application** — they are **NOT
separate routes, NOT separate maps, NOT separate editors, NOT separate security models, NOT separate publication
systems.** They share the one shell, the one map, the one owner spine (§WE.10, §7), and the one publication/audit
framework (§WE.10). Each adapter eventually provides ONE typed contract to the shell:

| Adapter operation | Meaning |
|---|---|
| read visible content | enumerate its domain's items for the current view |
| resolve map representation | give the shell point-anchor or polygon geometry to render (§WE.4, §WE.5) |
| select & inspect | fill the shared inspector with typed fields |
| create / edit draft | produce a typed draft (never touching the live row, §WE.10) |
| validate | domain-specific validation, orchestrated by the shared framework |
| publish | freeze a typed published revision (§2.2 philosophy) |
| enable / reveal | activate runtime state (or reveal, where applicable) |
| disable | fast forward-only kill-switch |
| archive | soft-retire |
| report dependencies | real referrers that block move/disable/archive (§WE.10) |
| report audit / revision history | authoring provenance (§WE.10) |

**Not every adapter implements every operation in phase 1.** Where an adapter does not yet support an operation
(because the runtime does not back it), that operation MUST be **explicit and DISABLED in the UI — never
simulated.** An unsupported control is greyed out with a stated reason, never a stub that pretends to work or
writes data the runtime cannot consume (§WE.7, §WE.8 hard rule).

### WE.3 Preserve typed authoritative models (anti-spaghetti)

The editor unifies **authoring and visualization**; the database **preserves correct domain boundaries.** Do NOT
collapse mining/exploration/zones into `locations`:

- Ports & pirate sites keep using `locations` (`…0002…:48-72`).
- Mining keeps `mining_fields` (`…0103…:50-70`).
- Exploration keeps `exploration_sites` (`…0098…:38-58`).
- Zones use the blueprint + typed behavior-module + placement + override model of §2 (materialized on
  `zone_placements`/today's `danger_zones`).

**AVOID (explicit anti-patterns):** one oversized table with unrelated nullable columns; arbitrary JSON as
authoritative config; polymorphic records without referential integrity; duplicated security per domain;
duplicated draft/publish per domain; a separate map per domain. Each is a spaghetti failure the unified-authoring /
separate-storage split is designed to prevent.

### WE.4 Spatial model — audit the coordinate authorities; DO NOT create a third

**CURRENT — there are TWO coordinate authorities, and a location's position is represented TWICE:**

1. **`locations.x/y double precision`** (`…0002…:57-58`) — described in-code as **legacy display-only**; it is what
   `get_world_map` surfaces to the client (`…0002…:115`). It does NOT drive movement.
2. **`space_anchors.space_x/space_y`** (`…0063…:35-36`) — the **movement-authoritative** open-space coordinate
   table: `kind ∈ {base, location}` (`…0063…:30`), `location_id … on delete restrict` (`…0063…:33`), coords NOT
   NULL and bounded ±10000 (`…0063…:50-54`), at most one ACTIVE anchor per location (partial unique
   `…0063…:63-65`), and an **immutability trigger** — an active anchor's kind/owner/coords are immutable; relocation
   = retire + insert a new active row (`…0063…:71-101`). RLS is server-only, `service_role` grant only
   (`…0063…:104-109`).

So `space_anchors` drives authoritative movement; `locations.x/y` is display-only — the same point stored in two
places.

**PROPOSED reconciliation — reuse/evolve `space_anchors`; do NOT create a `world_anchors` table.** The owner's
`world_anchors` sketch (stable anchor identity, canonical x/y, world/map id, lifecycle/revision, typed entities
referencing `anchor_id`) **already has a real candidate: `space_anchors`.** It already provides stable identity, a
canonical coordinate, a closed typed-owner discriminator, a lifecycle (active → retired), immutability, and a
bounded domain. Creating a NEW `world_anchors` table would introduce a **THIRD** coordinate authority — which the
owner forbids. **Recommendation:** evolve `space_anchors` into THE canonical point-based spatial anchor, with typed
entities referencing it (`locations.anchor_id`, `mining_fields.anchor_id`, `exploration_sites.anchor_id`) rather
than re-inventing anchors. (If `space_anchors` were ever found unsuitable — e.g. its base/location kind
discriminator cannot be extended to mining/exploration without a forced migration — the fallback is the **minimal
staged** extension of `space_anchors` (add the new `kind` arms + typed owner FKs by additive migration), NOT a new
table. Default recommendation stays: reuse/evolve `space_anchors`.)

**Staged migration strategy — canonical ENDPOINT vs SAFE STAGED PATH.** This is deliberately NOT one big migration
that adds `anchor_id` everywhere at once. It is a staged sequence, and **the canonical representation at each phase
is stated explicitly** so there is never ambiguity about which coordinate is authoritative mid-flight:

| # | Step | Canonical coordinate DURING this phase |
|---|---|---|
| 1 | Audit **every** current coordinate reader AND writer | `locations.x/y` (display) + `space_anchors` (movement) — unchanged |
| 2 | Verify the current relationship between `locations.x/y` and `space_anchors` (which readers use which) | unchanged |
| 3 | Define **ONE** authoritative coordinate resolver (the single read/derive authority) | still `space_anchors` for movement; resolver formalizes it |
| 4 | Add **NULLABLE** `anchor_id` references where required (additive, no backfill yet) | `space_anchors` (movement); `locations.x/y` still display |
| 5 | **Deterministic backfill** of anchors from existing coordinates | `space_anchors` (movement); display unchanged |
| 6 | **Verify** referential + coordinate parity (anchor coords match display within tolerance) | `space_anchors` |
| 7 | Introduce a **trusted server RPC as the ONLY mutation boundary** for position | `space_anchors` (RPC writes it first) |
| 8 | **TEMPORARILY synchronize** compatibility copies during migration (RPC syncs `locations.x/y` from the anchor) | `space_anchors` authoritative; `locations.x/y` = **compatibility copy** |
| 9 | Move **runtime reads** to `space_anchors` (via the resolver) | `space_anchors` — now sole read authority |
| 10 | **Revoke/remove legacy direct coordinate writes** (no path writes `locations.x/y` except the sync) | `space_anchors` |
| 11 | Remove duplicate coordinate columns **ONLY in a later migration**, after all readers migrated + prod verification | `space_anchors` (display columns gone or pure projection) |

**CRITICAL FRAMING:** during transition, the dual writes are **COMPATIBILITY MACHINERY, NOT two equal
authorities.** The single-writer RPC must **NOT** permanently maintain two co-equal coordinate authorities — that
would be exactly the spaghetti this design forbids. `space_anchors` **ULTIMATELY becomes the authoritative
coordinate**, and `locations.x/y` (and any other copy) becomes **derived compatibility data or is removed** (step
11). At no point is a new `world_anchors` or any third coordinate system introduced. **Conclusion: an existing
table (`space_anchors`) is reused and made canonical — never a third authority.**

**Polygons are NOT reduced to point anchors.** Zone placements and area-based mining/exploration retain canonical
**materialized geometry** — the `geometry(Polygon)` SRID-0 contract of §1.1 (as on `danger_zones.boundary`,
`…0233…:188`). Points → anchor; polygons → materialized geometry. Two canonical spatial representations, one per
geometry form, never a third.

### WE.5 Point AND area content (geometry-form matrix)

The World Editor treats "world content" as broader than "locations." Content is point-based OR area-based, with ONE
canonical runtime representation per form:

| Content | Geometry form | Canonical runtime representation |
|---|---|---|
| Port | point | anchor (§WE.4) |
| Pirate site | point | anchor |
| Mining station | point | anchor |
| Ore field | polygon | materialized `geometry(Polygon)` SRID 0 (§1.1) |
| Exploration landmark | point | anchor |
| Anomaly region | polygon | materialized geometry |
| Pirate activity zone | polygon | materialized geometry (today `danger_zones.boundary`) |
| Corridor | line → materialized polygon | materialized geometry (swept capsule, §4.5) |

Shared typed geometry tools serve every layer; **points → anchor, polygons → materialized geometry** — no implicit
second geometry path (§4.5, §WE.11).

### WE.6 Location layer (grounded in reality)

The Location layer authors the point-based canonical types the runtime actually supports on a `locations` row:

- **Ports** — `location_type='trade_outpost'` (`…0002…:52-56`) with `physical_role` `city`/`port`
  (`…0065…:27-29`).
- **Pirate sites** — `location_type` `pirate_hunt`/`pirate_den` (`…0002…:53-56`), the hostile hosts the intercept
  engine requires (§5.2).
- **Stations / landmarks** where supported — `physical_role` `station`/`landmark` (`…0065…:29`).

Capabilities attach via **real tables, not JSON on the location row:** `location_services`
(`docking`/`market`/`repair`/`refit`/`recruitment`, each with an enable/disable `status`, `…0065…:35-43`), plus
FK ledgers keyed off the location — bases / station-storage (`…0157…`, location FK `on delete restrict`),
`market_offers` (`…0085…`), `port_shop` (`…0235…`), repair, and investment (`…0132…`). **`physical_role`**
(`city`/`port`/`station`/`landmark`/`activity_site`/`unclassified`, `…0065…:27-29`) is a **durable physical
identity orthogonal to `location_type`** (which is gameplay activity) — the editor treats them as distinct axes.
**No arbitrary-JSON authoritative capability on locations** — capabilities are typed rows the adapter reads/writes
through owner-gated commands.

### WE.7 Mining layer (grounded in the real mining schema)

Mining is a **first-class layer** of the World Editor, NOT a separate mining editor. Owner-only authoring flow:

> view existing mining content on the real map → select/inspect → create a supported mining **DRAFT** → place a
> **point** site or draw an **area** field **as the real model supports** → configure a typed resource profile
> **only where real columns exist** → associate with locations/zones where meaningful → **validate** → **publish**
> → **enable** → **disable** → **archive** → **audit/rollback**.

**CURRENT reality (grounded, `…0103…:50-70`):** `mining_fields` has `id`, `name` (unique), `space_x`/`space_y`
(double precision, finite, ±10000), `reward_bundle_json` (jsonb OBJECT, **items-only** `{items:[{item_id,
quantity}]}`), `is_active`, `created_at`. It is **point-based** (space coords, no polygon column), **has NO FK to
`locations`**, and its only per-field payload is `reward_bundle_json`. Extraction is proximity-based and completely
zone-agnostic (`command_mining_extract` / `process_mining_securing`, §1.3), repeatable per (player, field) with a
cooldown from `mining_extractions.created_at` (`…0103…:86-108`).

**Properties the owner named that have NO real column/runtime today — REQUIRES NEW RUNTIME, OUT OF AUTHORING SCOPE
UNTIL BUILT:**
- **richness** — no column on `mining_fields`; yields are the fixed `reward_bundle_json` bundle.
- **depletion** — NOT on `mining_fields`. It exists ONLY as a **separate dark World-State layer**,
  `mining_field_state.reserve_fraction` (`20260618000137_world_balance_p19_field_depletion.sql`), gated on
  `world_balance_enabled=false` → **never runs live** (§1.3).
- **regeneration** — same dark World-State layer; never live.
- **eligibility** (module-based mining gating) — does not exist; the `module_range_attributes` flag the old task
  premise assumed **is not in the repo** (§1.3).

**What the mining adapter CAN currently author (real columns only):** a field's `name`, its position
(`space_x`/`space_y`), its `reward_bundle_json` items-only bundle, and its `is_active` flag. **Nothing else exists
to author.**

**FUTURE runtime capabilities (do NOT invent schema/behavior as if present):** richness, depletion, regeneration,
and module-based eligibility are **future runtime capabilities**, not current ones. Before any editor control for
them may be enabled, the ENGINE work must land first: a per-field richness/yield model that scales
`reward_bundle_json`; a live depletion/regeneration runtime (today only the dark, never-run
`mining_field_state.reserve_fraction` under `world_balance_enabled=false`, `…0137…`); and a module-eligibility
system (which does not exist at all). **Hard rule:** the editor must **NEVER** expose a control that writes data the
runtime does not understand — these controls stay **disabled and explicit** until their engine exists (§WE.2
adapter boundary).

Area mining may reuse the blueprint/placement architecture (§2, a `zone_mining_behaviors` module seeds N fields
inside a boundary, §8 Slice H); point mining sites reference the shared anchor (§WE.4). The adapter **bridges**
`mining_fields` (which has no location FK) to the shell — it does NOT collapse mining into `locations`.

### WE.8 Exploration layer (grounded in the real exploration schema)

Exploration is a **first-class layer**, NOT a separate exploration editor. Owner-only authoring flow:

> view existing exploration content → select/inspect → create a supported exploration **DRAFT** → place a **point**
> discovery or draw an **area** region as supported → configure a typed discovery/event profile **only where real
> columns/runtime exist** → **validate** → **publish** → **enable or reveal separately** → **disable** →
> **archive** → **audit/rollback**.

**CURRENT reality (grounded, `…0098…:38-58`):** `exploration_sites` is the twin of `mining_fields` — `id`, `name`
(unique), `space_x`/`space_y`, `reward_bundle_json` (jsonb, `{metal?, items[]}`), `is_active`, `created_at`.
Point-based, no polygon, no location FK. Per-player state lives in `exploration_discoveries` with **`unique
(player_id, site_id)`** (`…0098…:73-79`) plus a pending→secured lifecycle (`main_ship_id`, `pending_bundle_json`,
`secured_at`, `…0099…:60-62`, `…0100…:34-35`). Discovery is proximity-based via `command_scan` (§1.4). The whole
subsystem is **dark**: `exploration_enabled=false`, never proven live (§1.4).

**Properties the owner named that have NO real column/runtime today — REQUIRES NEW RUNTIME, OUT OF AUTHORING SCOPE
UNTIL BUILT:**
- **one-time vs repeatable** — the runtime is **one-time ONLY**: `unique (player_id, site_id)` (`…0098…:78`)
  permits exactly one discovery per player per site. **Repeatable exploration does not exist** and would need a new
  runtime.
- **cooldown** — no cooldown column/runtime for exploration (unlike mining, which paces via `created_at`); a
  per-site exploration cooldown is out-of-scope-until-built.
- **prerequisites** — no prerequisite column/runtime.
- **visibility / reveal** — sites are **hidden server-only until discovered** (RLS enabled, no client policy,
  `…0098…:60-63`); there is no authorable pre-discovery visibility/reveal state. Per-player **completion** state
  DOES exist (a `discoveries` row = completed), but an authorable **reveal** step separate from discovery does not.

**What the exploration adapter CAN currently author (real columns only):** a site's `name`, its position
(`space_x`/`space_y`), its `reward_bundle_json` (`{metal?, items[]}`), and its `is_active` flag. Per-player
discovery **completion** state already exists (`exploration_discoveries`, one row = completed). **Nothing else
exists to author.**

**FUTURE runtime capabilities (do NOT invent schema/behavior as if present):** repeatable discovery, per-site
cooldown, prerequisites, and an authorable pre-discovery reveal step are **future runtime capabilities**. Before
any editor control for them may be enabled, the ENGINE work must land first: dropping/replacing the `unique
(player_id, site_id)` one-shot constraint (`…0098…:78`) plus a cooldown runtime for repeatability; a prerequisite-
evaluation runtime; and a reveal/visibility runtime distinct from discovery. **Hard rule:** the editor must
**NEVER** expose a control that writes data the runtime does not understand — these controls stay **disabled and
explicit** until their engine exists (§WE.2 adapter boundary).

The exploration adapter authors point discoveries / area regions against the REAL `exploration_sites` /
`exploration_discoveries` model. Because the base system is **dark and unproven** (`exploration_enabled=false`),
this layer is built **LAST** (§8 Slice I): light and prove exploration end-to-end FIRST, then add the layer.

### WE.9 Zone layer

The Zone layer reuses the existing **blueprint + typed behavior-module + placement + override** model already
documented in §2 — it adds nothing new here, it just renders and authors that model as one layer of the World
Editor:

- **Pirate behavior zones (v1)** — the single behavior the first slice ships (§2.8, §5).
- **FUTURE mining / exploration behavior zones + future typed modules** (hazard, trade-modifier, visibility,
  faction, mission-trigger, travel-speed, regeneration, §2.3) — all through the **same** typed
  blueprint/revision/placement/override machinery, gated by the compatibility policy (§6.1).

See §2 (schema), §2.7 (immutable-revision lifecycle), §5.3 (the ONE resolver), §6 (growth/compat/overlap). This
layer does not duplicate those sections; the ZoneLayerAdapter is the seam onto them.

### WE.10 ONE shared security + lifecycle + draft + audit framework (not per-domain)

Every layer shares ONE framework. Domain-specific validation lives inside each typed adapter/command; the
framework itself is built once.

**Authorization — ONE owner/developer authz spine for ALL layers.**
*CURRENT REALITY:* there is **NO server-side owner spine.** No `is_owner()`/`is_admin()`/allow-list exists
(§1.5); `pirate_zone_create`/`delete` are granted to plain `authenticated` with the self-described *"PROTOTYPE:
no admin-role gate"* (`…0233…:1478-1480`, grant at `…0233…:1473`); the only "owner" gate is a **CLIENT-side**
`dev_zone_editor_enabled` flag + a hidden `/dev/zones` route (`20260618000238…`, whose own header states no server
function reads it). *PROPOSED:* build the spine **ONCE** as **prerequisite #1** (the security spine of §7): an owner
allow-list (`app_owners`) + an `is_owner()` `SECURITY DEFINER` predicate that **EVERY** typed domain command
(location / mining / exploration / zone) calls before acting. **Do NOT** create one owner check for zones, another
for mining, another for exploration — one spine, consulted by all adapters.

**Shared guarantees for every layer:** server-side owner authorization; anonymous rejection;
unauthorized-authenticated rejection; no unrestricted direct browser writes; draft isolation; validation before
publication; explicit publication; separate enablement/reveal; audit records; disable/kill switch; rollback/
restoration where practical. *CURRENT REALITY on audit:* **no audit records exist today** —
`danger_zones.created_by` (`…0233…`) is the only authorship attribution anywhere, and `locations` has **none** —
so the audit framework is **NEW** (`zone_authoring_audit`, §7.6, generalized to all layers).

**Shared DRAFT framework — ONE content-authoring lifecycle with typed draft payloads/tables.** Distinguish, for
every layer: **stable content identity / draft revision / published IMMUTABLE revision / enabled runtime state /
revealed visibility state (where applicable) / disabled / archived** (consistent with §2.2/§2.7's immutable-
published-revision philosophy). Physical tables may differ per domain, but editor behavior + lifecycle semantics
stay identical across layers.

**Shared lifecycle ≠ ONE generic table.** Do NOT force every domain into one generic draft/revision table, and
specifically do **NOT** introduce an unrestricted-JSON `world_content` / `world_content_drafts` bag to make the
domains *look* identical — that is the arbitrary-JSON-as-authoritative-config anti-pattern the owner forbids.
**TYPED per-domain revision tables are acceptable and PREFERABLE**, e.g. `location_draft_revisions` /
`mining_field_draft_revisions` / `exploration_site_draft_revisions` / `zone_blueprint_revisions` (§2.2) — or a
carefully **typed** shared revision framework. The COMMONALITY lives in **lifecycle semantics, authorization,
editor commands, validation orchestration, audit conventions, and publication contracts — NOT in storage shape.**
Domain config stays typed and constrained; no arbitrary JSON is ever the authoritative final config.

*CURRENT REALITY:* **no draft/published lifecycle exists.** `locations` has only
`status ∈ {active, locked, hidden}` (a one-way reveal, `service_role`-only, `…0002…:68-69`, `20260618000068…`)
and `location_services.status` (per-service enable/disable, `…0065…:39`); there is **no `created_by`/`updated_at`/
`archived_at` on `locations`.** *PROPOSED:* a **draft-staging** approach so editing a draft **NEVER** touches the
live row (the immutable-published-revision philosophy of §2.2, applied to every layer). **No arbitrary JSON as the
authoritative final config** on any layer.

**Dependency validation (grounded).** Before publish / move / disable / archive, the framework checks REAL
referrers of the affected item and refuses to break them:
`location_presence` (`20260616000008…`), `fleet_movements` targets, `main_ship_space_movements` targets
(`…0055…`), `main_ship_instances.berth_location_id` docking (`…0216…`), `player_home_port` (`…0065…:58-62`,
`on delete restrict`), bases / station-storage (`…0157…`, `on delete restrict`), `space_anchors`
(`…0063…:33`, `on delete restrict`), plus `market_offers`/investments/haul/combat/world_events/`danger_zones`.
**Never hard-delete a referenced published item;** prefer disable/archive; delete only if the item was never
published or referenced.

### WE.11 One real map — retire the bespoke one (anti-spaghetti)

The World Editor renders on the **REAL map primitives**, not a second canvas:
`src/features/map/GalaxyMap.tsx`; coordinate authority `src/features/map/openSpaceTransform.ts`
(`worldToViewBox`/`viewBoxToWorld`, `WORLD_MIN`/`WORLD_MAX` ±10000, `VIEWBOX_SIZE=1000`, `openSpaceTransform.ts:36-39,
74-85`); camera `galaxyCamera.ts`; markers `markerStyle.ts` / `LocationMarker.tsx`; zone render `dangerZoneLayer.ts`;
territory `territoryLayer.ts`; data `mapApi.ts` / `pirateApi.ts`.

*CURRENT REALITY:* `src/features/dev/ZoneEditor.tsx` uses a **BESPOKE** `makeFit` SVG transform (its own
`SVG = 1000`, `ZoneEditor.tsx:31,49-76`, `viewBox 0 0 ${SVG} ${SVG}` at `:223`) and does **NOT** reuse
`GalaxyMap`/`openSpaceTransform`/`galaxyCamera`/`markerStyle` — a second, incompatible world↔SVG projection and a
second renderer for one map (§4.1). *PROPOSED:* the World Editor uses the shared real-map primitives and the
bespoke `ZoneEditor` map is **RETIRED** — **one map authority, not two** (§4, Slice B). A `/dev/zones` route rename
is not required immediately, but the component must be designed for the broader World Editor role: **a single World
Editor route/shell**, never `/dev/mining-editor` + `/dev/exploration-editor`.

### WE.12 Editor UX

> **One map** → **toggle layers** (Locations / Mining / Exploration / Zones) → **select a content type** →
> **add point / draw area / select existing** → **configure typed properties** → **inspect relationships &
> dependencies** → **save draft** → **preview effective result** (via the server resolver, §5.3, never a client
> merge) → **validate** → **publish explicitly** → **enable or reveal separately**.

**The user never leaves the World Editor to author mining or exploration.** Switching from authoring a port to
authoring an ore field to authoring a pirate zone is a **layer toggle**, not a navigation to another tool.

### WE.13 Bounded phased roadmap (ONE editor from the beginning)

The phases exist because the underlying systems have **different readiness** — but the **PRODUCT is one World
Editor from the start.** Later mining/exploration phases **EXTEND the same editor**; they are **NOT separate
editors.**

1. **Foundation** — shared real map + layer registry + selection model + read-only typed inspectors + owner-
   authorization integration (maps onto §8 Slice A security spine + Slice B shared-map extraction).
2. **Unified read-only world view** — show current locations, mining records, exploration records, and zones ALL on
   ONE map as selectable typed layers, even though they come from separate schemas.
3. **Location authoring** — draft authoring for the existing canonical location types (ports, pirate sites).
4. **Mining authoring** — connect the real mining tables/commands (`mining_fields`, §WE.7) to the shared shell
   (§8 Slice H).
5. **Exploration authoring** — connect the real exploration tables/commands (`exploration_sites`, §WE.8) to the
   shared shell, AFTER exploration is lit and proven (§8 Slice I).
6. **Zone behavior authoring** — pirate (v1, §8 Slice G) then mining/exploration behaviors via typed blueprint
   modules + placements (§8 Slices H/I, gated by the §6.1 compatibility policy).

**Gating:** no phase is built until the prerequisites are resolved and each slice is separately approved (§8). The
two prod prerequisites are **SEPARATE, INDEPENDENT prerequisites** — they are not one item: (#1) the **security-
containment** spine that closes the LIVE `pirate_zone_create` griefing hole (§1.5, §7), and (#2) the **`combat_units`
UNIQUE cardinality** fix that unblocks multi-pirate waves (§5.5). Either can be true while the other is false;
both must land before the feature work they respectively gate. Later mining/exploration phases add **adapters to
the same shell**, never new editors.

**V1 boundary (implementation stays bounded even though it is one editor from the start).** "One editor from the
beginning" does **NOT** mean every layer is writable in the first release. The first stages are strictly ordered:

1. **security prerequisites** (the §7 owner spine + the §1.5 containment fix);
2. **shared real-map foundation** (§WE.11, §8 Slice B);
3. **unified READ-ONLY rendering** of existing content across all layers on one map (§WE.13 stage 2);
4. **read-only typed inspectors** for each layer;
5. **draft authoring for ONE already-supported domain only** (locations — the domain with the most-ready runtime);
6. **controlled publication only after separate approval + verification** (§8 per-slice gate).

**Do NOT make location + mining + exploration + zone mutation all writable simultaneously.** Unified rendering and
inspection come first for every layer; write-authoring is unlocked **one domain at a time**, each behind its own
separately-approved slice, its own flag, and its own apply-proof — never as a single big-bang editable release.

### WE.14 Reality-vs-model reconciliation

An honest statement of the CURRENT tensions and how this unified design reconciles each:

| CURRENT tension | How the unified design reconciles it |
|---|---|
| **Two coordinate authorities** — `locations.x/y` display-only (`…0002…:57-58`) + `space_anchors` movement-authoritative (`…0063…:35-54`), same point stored twice | **Reuse/evolve `space_anchors`** as the canonical anchor; one-writer RPC keeps display synced from the anchor — **NO third authority** (`world_anchors` is rejected) (§WE.4) |
| **Mining & exploration in separate tables** (`mining_fields` `…0103…:50-70`, `exploration_sites` `…0098…:38-58`), no location FK | **Typed adapters/layers** bridge them to the shell — **NOT separate editors, NOT collapsed into `locations`** (§WE.3, §WE.7, §WE.8) |
| **No owner spine** — client-flag + hidden route only; `pirate_zone_create` open to `authenticated` (`…0233…:1478-1480`) | **Build ONE shared owner spine** (`app_owners` + `is_owner()`), prerequisite #1, consulted by every layer's commands (§WE.10, §7) |
| **No draft lifecycle** — `locations.status` is a one-way reveal only (`…0002…:68-69`); no `created_by`/`archived_at` | **One shared draft-staging framework** with typed payloads; editing a draft never touches the live row (§WE.10, §2.2) |
| **No mining richness/depletion/regeneration/eligibility; no exploration repeatable/cooldown/prerequisites/reveal** | Author only against **real columns**; those properties are marked **out-of-scope-until-built** until a real runtime backs them (§WE.7, §WE.8) |
| **Two maps** — `GalaxyMap` (`openSpaceTransform`) vs bespoke `ZoneEditor` `makeFit` (`ZoneEditor.tsx:31,49-76`) | **Retire the bespoke `ZoneEditor` map**; the World Editor renders on the shared real-map primitives — one map authority (§WE.11, §4) |

### WE.15 Scope of approval

This document is **architecture only.** **Merging PR #222 approves the ARCHITECTURAL DIRECTION ONLY** — it does
**NOT** approve or authorize any code, any migration, any production write, any grant, any flag change, or any
activation. Every implementation slice (§8) remains subject to its own separate review, its own apply-proof, its
own migration approval on the protected `production` environment, and its own owner-gated enable. Nothing in this
section is built, deployed, or lit by accepting it.
