# Zone Templates — a reusable content-authoring system for Byeharu

**Status:** design plan (no code, no migration). Read-only architecture pass.
**Base:** `origin/main` @ `2518d1f` + the merged zone slices 0233–0238 (prod state).
**Author's vision:** the dev zone editor becomes a reusable **content-authoring** system.
Author "Zone A" (spawns tier-1 pirates) and reuse it across **many** map locations; author
"Zone B" (higher-tier pirates); author **mining** and **exploration** zones too — every one a
reusable, placeable **template** with a **KIND** (`pirate_combat` / `mining` / `exploration`) and
a **PROFILE** (combat: tier/count/difficulty/reward; mining: ore/richness; exploration: what's
discoverable).

---

## 0. What exists today (grounded, so nothing here is hand-waved)

### 0.1 The zone geometry model — `danger_zones` (single-location, single-kind)
`supabase/migrations/20260618000233_pirate_intercept_danger_zones.sql:183-197`:

```
create table public.danger_zones (
  id, name,
  zone_kind   text not null default 'pirate' check (zone_kind in ('pirate')),   -- ← ONE kind only
  source      text not null check (source in ('circle','drawn')),
  location_id uuid references public.locations (id) on delete cascade,          -- ← ONE nullable attach
  boundary    geometry(Polygon) not null,                                       -- PostGIS polygon
  status, created_by, created_at, updated_at,
  check (source <> 'circle' or location_id is not null)
);
```

- **PostGIS** is the geometry engine (installed by 0233:131). Boundaries are arbitrary polygons.
- **3 live zones** in prod (Reaver / Snare / Blackden): `source='circle'`, one auto-seeded per
  `pirate_hunt`/`pirate_den` location that carries a `territory_radius`
  (0233:216-222), later reshaped into organic blobs by the **slime** migration
  `20260618000237_slime_danger_zones.sql` (pure geometry reshape of those 3 rows).
- **`location_id` is a single nullable FK.** Despite the working branch name `slice-zone-multi`,
  **no multi-location attach migration exists** — this is net-new plumbing this plan defines.
- `zone_kind` currently has a **one-value CHECK** (`'pirate'`) — the extension point for KIND.

Supporting tables/functions in 0233:
- `pirate_intercepts` (:225) — audit log of every leg-departure risk roll.
- `fleet_route_legs` (:259) — waypoint route queue.
- `pirate_intercept_leg_zone_hits` (:293) — the ONE PostGIS segment-vs-polygon test
  (`ST_Intersects` / `ST_Intersection` / exposure fraction).
- `pirate_intercept_compute_risk` (:336) — stat-scaled risk formula.
- `pirate_intercept_evaluate_leg` (:378) — **the ambush orchestrator** (see 0.2).
- `get_danger_zones` (:1373) — client read (returns `[x,y]` vertex rings, dark-gated).
- `pirate_zone_create(p_name, p_vertices, p_location_id)` (:1399) — the editor's save RPC.
- `pirate_zone_delete(p_zone_id)` (:1483).
- Flag: `pirate_intercept_enabled` (governs the whole slice; **true in prod**).

### 0.2 How a zone becomes a fight, and where "pirate tier" lives today
On a leg crossing a zone that **has a linked `location_id`**,
`pirate_intercept_evaluate_leg` (0233:475-517) composes the **existing** combat chain verbatim:
`fleet_set_present` → freeze `group_sortie_members` manifest → `presence_create('hunt_pirates')`
→ `combat_create_encounter` → (manifest exists) → `combat_create_group_encounter`. A **standalone**
zone (`location_id` NULL) only forces a stop — the documented combat stub (0233:475-483). The
follow-up named in 0233:44 is *"auto-minting a locations row for a from-scratch drawn zone"*.

The enemy is derived **entirely from the linked `locations` row**:
- `locations.base_difficulty` and `locations.reward_tier` are seeded in
  `20260616000002_world_map.sql:152-160`.
- Enemy scaling (current head `combat_create_group_encounter` / `process_combat_ticks`, 0228 body
  re-created verbatim in `20260618000234_combat_spatial_tick.sql:276`):
  - **HP:** `v_enemy_hp := loc.base_difficulty * cfg_num('enemy_hp_base'=14) * …`
    (pattern at e.g. `…_167:354`, `…_046:220`).
  - **Attack:** `v_enemy_attack := loc.base_difficulty * cfg_num('enemy_attack_base'=1.0) * …`.
  - **Reward:** `v_reward_metal := cfg_num('reward_metal_base'=10) * greatest(loc.reward_tier,1) * …`.
  - **Spatial (0234:161-167):** count `N = min(cfg('enemy_synthetic_max_units'=6), danger_level)`;
    weapon `range = 120 + base_difficulty*5`; `move_speed = 3 + base_difficulty*0.2`;
    projectile_speed 250; cooldown 2.

> **The crux for combat templates:** "pirate tier" today is **`locations.base_difficulty`
> (+`reward_tier`)** — a property of the *location*, not the zone. Every enemy stat is a pure,
> already-parameterized function of it. To make Zone A (tier-1) and Zone B (tier-3) spawn different
> pirates **regardless of which location they're placed at**, difficulty/reward must be carried by
> the **zone/template** into the encounter, with a fallback to the location's own values.

### 0.3 Mining — `mining_fields` (proximity, no zone concept)
`20260618000103_mining_p12_fields_schema.sql`:
```
create table public.mining_fields (
  id, name unique, space_x, space_y,            -- open-space coordinates, NOT a location/zone
  reward_bundle_json jsonb,                      -- items-only bundle (ore/crystal/artifact_core)
  is_active boolean default true, created_at
);   -- RLS enabled, NO client policies (hidden until extracted)
```
- Static migration-seeded world data; **no runtime writer, no zone/location link** — fields just
  float at coordinates.
- `command_mining_extract` (0104) extracts by **proximity** (`osn_distance` within
  `mining_extract_radius=750`, `20260618000102_…:mining_extract_radius`), repeatable with a 300s
  per-(player,field) cooldown. Rewards deposit via the existing `reward_grant('mining', …)` path.
- Flag `mining_enabled=false` (0102) — **dark**, but the extract path is fully built.

### 0.4 Exploration — `exploration_sites` (twin of mining, fully dark)
`20260618000098_exploration_p11_sites_schema.sql`: identical shape
(`space_x, space_y, reward_bundle_json, is_active`), plus `exploration_discoveries` with
`unique(player_id, site_id)` (one-shot discovery). Discovered by **scan proximity**
(`command_scan`, 0099). Reward set `{scan_data, anomaly_shard, blueprint_fragment, artifact_core}`
(0097). Flag `exploration_enabled=false` — **dark end-to-end and never proven in prod**.

### 0.5 The authoring surface — `src/features/dev/ZoneEditor.tsx`
Owner-only route `/dev/zones`, gated on `dev_zone_editor_enabled`
(`20260618000238_dev_zone_editor_flag.sql`). Forks nothing: reads `get_world_map` + `get_danger_zones`,
saves via `pirateZoneCreate` / `pirateZoneDelete` (`src/features/map/pirateApi.ts`). UI: draw polygon
(click vertices) → name → **single** "Attach to" `<select>` (standalone **or one** hostile location)
→ Save. Rendering via `src/features/map/dangerZoneLayer.ts`.

---

## 1. Data model

Three concepts, **one authority each** (NO-SPAGHETTI: a template is definition, a placement is
geometry+attach, an attachment is a location edge):

### 1.1 `zone_templates` — the reusable definition (KIND + PROFILE)
```
create table public.zone_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,                    -- "Zone A", "Ore Belt", …
  kind        text not null check (kind in ('pirate_combat','mining','exploration')),
  profile     jsonb not null default '{}',      -- typed-per-kind (see §2); validated by kind
  status      text not null default 'active' check (status in ('active','inactive')),
  created_by  uuid references auth.users(id) on delete set null,
  created_at, updated_at
);
```
- **`profile` is jsonb, not typed columns** — deliberately. The three kinds have disjoint shapes;
  typed columns would be a sparse table (2/3 NULL per row) and a new column per future knob.
  A jsonb profile validated **per kind** at the write RPC (and a lightweight CHECK on required keys)
  keeps one table, one authority, and stays additive. This mirrors the house `reward_bundle_json`
  convention (0098/0103) and `game_config.value` jsonb.
- **Profile shapes** (§2 details): combat `{tier?, base_difficulty, reward_tier, max_units}`;
  mining `{ore_mix:[{item_id,weight}], richness, field_count}`; exploration
  `{discoverable:[{item_id,weight}], site_count, metal_min, metal_max}`.

### 1.2 The placement — generalize `danger_zones`, don't fork it
`danger_zones` **already is** "a polygon placed in the world, optionally attached." Rather than a
parallel `zone_placements` table (fork), **generalize the existing one** (compose, retire the old
shape):
- **Add** `template_id uuid references zone_templates(id)` (nullable during migration; the 3 legacy
  circle zones get a backfilled system template — §1.4).
- **Widen** the `zone_kind` CHECK to `('pirate','pirate_combat','mining','exploration')` **or** drop
  it and derive kind from `template.kind` (recommended: derive; keep `zone_kind` as a generated/
  denormalized read column for the existing RLS/read path).
- Keep `boundary`, `source`, `status`, `created_by` unchanged.
- **Table-name question (open, §4):** `danger_zones` no longer describes mining/exploration.
  Options: (a) keep the name, generalize semantics + add a neutral `zones` view for new readers;
  (b) rename to `zone_placements` with a `danger_zones` compat view so 0233's RLS/reads/`get_danger_zones`
  keep working. Recommend **(a)** first (least churn, dark-safe), reconsider a rename once all three
  kinds land.

### 1.3 `zone_placement_locations` — the many-to-many attach (the multi-location core)
```
create table public.zone_placement_locations (
  placement_id uuid not null references danger_zones(id) on delete cascade,
  location_id  uuid not null references locations(id)   on delete cascade,
  primary key (placement_id, location_id)
);
```
- Replaces the single `danger_zones.location_id` semantics. **One placement → N locations** — this
  is what lets Zone A be reused across multiple map locations from one draw.
- `danger_zones.location_id` stays **during transition** (dark): the intercept read
  (`pirate_intercept_evaluate_leg` / `_leg_zone_hits`) is repointed to `join zone_placement_locations`
  and iterates every attached location; `location_id` is dropped in a later cleanup slice.
- (For combat, an attached location still must be a real `pirate_hunt`/`pirate_den` row to host a
  presence — §2a. Mining/exploration placements typically have **zero** location attachments.)

### 1.4 What migrates from today's `zone_kind` / `location_id`, backward-compat with the 3 live zones
- **Seed a system template** `"Legacy Pirate Territory"` (`kind='pirate_combat'`,
  `profile={"difficulty_source":"location"}` — an explicit *inherit* mode meaning "use the attached
  location's `base_difficulty`/`reward_tier`", i.e. **exactly today's behavior**).
- **Backfill:** set `danger_zones.template_id` = that template for all 3 `source='circle'` rows.
- **Backfill the join:** one `zone_placement_locations(placement_id, location_id)` row per existing
  non-null `danger_zones.location_id`.
- **Result:** the 3 live zones are byte-identical in behavior (inherit mode + single backfilled
  attach = today), proven by an apply-time self-assert that pins the backfill counts and re-runs an
  intercept roll. `zone_kind='pirate'` rows map to `kind='pirate_combat'`.

---

## 2. Per-kind wiring

### (a) COMBAT — carry template difficulty into the encounter (the real feature)
Today difficulty is read from the linked `locations` row at spawn (§0.2). To make **the zone/template**
decide the tier:
1. **Add override columns to `combat_encounters`:** `difficulty_override double precision`,
   `reward_tier_override integer`, `max_units_override integer` (all nullable). Optionally
   `zone_template_id uuid` for provenance/telemetry.
2. **Set them at encounter creation.** `pirate_intercept_evaluate_leg` knows the ambushing placement;
   it looks up that placement's `template_id` → profile, and passes the profile's
   `base_difficulty`/`reward_tier`/`max_units` through `presence_create` context into
   `combat_create_group_encounter`, which writes the overrides onto the new `combat_encounters` row.
   (Presence→encounter already carries `location_id`; this adds a thin, dark-gated override payload.)
3. **Read override-else-location** in the two spawn sites — `combat_create_group_encounter`'s spawn
   hunk (0234:276+) and `process_combat_ticks`' enemy-spawn hunk: replace `loc.base_difficulty` with
   `coalesce(e.difficulty_override, loc.base_difficulty)` and `loc.reward_tier` with
   `coalesce(e.reward_tier_override, loc.reward_tier)`; `N` cap uses
   `coalesce(e.max_units_override, cfg('enemy_synthetic_max_units'))`. **Every existing formula and
   config knob is untouched** — only the input source gains a coalesce. This is a **surgical, two-
   function change with a fallback**, so encounters that carry no override (all of today's) behave
   identically.
4. **Tier authoring:** `profile.tier` (1/2/3) maps to `base_difficulty` via a small
   `zone_tier_difficulty` config/table (tier 1→low, tier 3→high) so authoring is "tier 1/2/3", not
   raw numbers. `difficulty_source:"location"` (inherit) skips the override entirely (compat).
5. **Reuse across N locations:** the placement attaches (via `zone_placement_locations`) to N existing
   `pirate_hunt` locations; the **template's** override makes all N spawn the **same** tier, even if
   each location's own `base_difficulty` differs. That is exactly "Zone A reused across many map
   locations, all tier-1."
6. **Standalone combat zones** (no location) still hit the 0233 stub (forced stop, no fight) until the
   named 0233:44 follow-up (auto-mint a hosting `locations` row) lands — tracked as an open question (§4).

**Effort: small–medium.** The scaling engine is already fully parameterized; this adds a per-encounter
override + fallback. Multi-attach plumbing (§1.3) is the larger adjacent piece.

### (b) MINING — a placement seeds fields inside its polygon
Mining needs **no change to the extract path** (proximity already works, §0.3). A mining-kind template
profile = `{ore_mix, richness, field_count}`. On **placement save**, a generator seeds `mining_fields`
inside the boundary:
- Scatter `field_count` points inside `danger_zones.boundary` (PostGIS `ST_GeneratePoints`, or reject-
  sample random points via `ST_Contains` — the same "valid-by-construction, pin invariants not coords"
  discipline the slime migration uses, 0237).
- Each field's `reward_bundle_json` is derived from `ore_mix` (which items) × `richness` (quantities).
- Link fields to the placement with a `zone_placement_fields(placement_id, field_id)` join (so a
  placement's fields can be regenerated/removed with it — no orphan world data).
- Requires `mining_enabled=true`; the existing `command_mining_extract` picks the fields up by
  proximity unchanged.

**Effort: medium.** New: a polygon→field generator + the placement↔field link + profile validation.
Extract, rewards, cooldown, RLS all reused as-is.

### (c) EXPLORATION — same pattern, on a still-dark base
Structurally identical to mining: an exploration-kind profile = `{discoverable, site_count,
metal_min, metal_max}`; on placement, seed `exploration_sites` inside the boundary with
`reward_bundle_json` from the profile; the existing `command_scan` discovers them by proximity
(`unique(player_id, site_id)` = one-shot). Link via `zone_placement_sites`.

**Blocker:** exploration is **dark end-to-end and unproven** (`exploration_enabled=false`, never lit
in prod). The zone layer is only as trustworthy as the system beneath it, so this kind must **not** be
built until exploration itself is validated (light the flag, prove scan→discover→reward on live
Postgres). **Effort: medium–high** (validate exploration + the site generator).

---

## 3. The authoring flow in `ZoneEditor.tsx`

Generalize the current draw→name→single-attach→save into:

1. **Pick KIND** — `pirate_combat` / `mining` / `exploration` (radio at top).
2. **Pick or create a TEMPLATE** — a template list filtered by kind; "New template" opens a
   **kind-specific profile form**:
   - combat: tier (1/2/3) or explicit difficulty, reward tier, max units;
   - mining: ore mix + richness + field count;
   - exploration: discoverable set + site count + metal range.
3. **Draw geometry** — unchanged polygon-drawing (click vertices; the existing fit-to-content SVG).
4. **Attach to N locations** — the single `<select>` becomes a **multi-select** of hostile locations
   (combat); mining/exploration default to **no attach** (standalone region).
5. **Save** — new `zone_placement_create(template_id, vertices, location_ids[])` RPC (generalizes
   `pirate_zone_create`; kind-combat validates the location list are `pirate_hunt`/`pirate_den`).
   For mining/exploration, save also triggers the field/site generator (§2b/§2c).
6. **Reuse** — "place existing template": draw a fresh polygon, pick an existing template, attach.
   One "Zone A" template → many placements → many map locations, all sharing the profile.

**RPC changes:** add `zone_template_create/list/update`, `zone_placement_create`; **retire**
`pirate_zone_create` and repoint the editor (NO-SPAGHETTI: one save authority, not two). `get_danger_zones`
gains `template_id`/`kind`/`attached_location_ids[]` for rendering; the editor colors zones by kind.

---

## 4. Phased, dark-first roadmap

Each phase is a shippable method slice with its **own flag** and an **apply-proof** self-assert
(CI `supabase start` applies the whole chain to real Postgres — the net that catches vacuous asserts
and constraint-coupling). Ordered by value × dependency, starting from what exists.

| Phase | Slice | Flag | New/changed | Apply-proof pins | Size |
|---|---|---|---|---|---|
| **0** | *Exists* | `pirate_intercept_enabled`, `dev_zone_editor_enabled` | danger_zones + intercept + spatial combat + slime + editor (single-kind, single-attach) | — | done |
| **1** | **Multi-attach foundation** | `zone_multi_attach_enabled` | `zone_placement_locations` join; backfill 3 zones; repoint intercept read to the join (coalesce with `location_id` while dark) | backfill count = existing non-null `location_id` count; intercept still fires for a backfilled zone | S–M |
| **2** | **Templates + combat override** ★ highest value | `zone_templates_enabled` | `zone_templates` table; `combat_encounters` override cols; 2-function `coalesce(override, loc.*)` edit; seed "Legacy" inherit template; backfill `template_id` | tier-1 vs tier-3 template placed at the SAME location spawn measurably different enemy HP/count on live PG; inherit template reproduces today's numbers | M |
| **3** | **Authoring UI generalization** (client) | `dev_zone_editor_enabled` (reuse) | ZoneEditor kind+template+multi-attach; `zone_template_*` + `zone_placement_create` RPCs; retire `pirate_zone_create` | RPC ACL split; editor saves a 2-location combat placement that both fire | S–M |
| **4** | **Mining zones** | `mining_zone_templates_enabled` (+ `mining_enabled`) | mining profile; polygon→`mining_fields` generator; `zone_placement_fields` join | N fields seeded, ALL inside boundary (ST_Contains), reward bundle shape valid; extract from one works | M |
| **5** | **Exploration zones** | `exploration_zone_templates_enabled` (+ `exploration_enabled`) | *first: validate exploration end-to-end*; then site generator + `zone_placement_sites` | exploration proven live; N sites inside boundary; scan→discover→reward | M–H |

Dependencies: 2 needs 1 (a template placement is multi-attach by default); 3 needs 2; 4 needs
`mining_enabled` proven; 5 needs exploration validated first. Phases 1–3 are the "author reusable
pirate zones of different tiers" core the author asked for and can ship independently of 4–5.

**Small extension vs bigger build:**
- *Small extension:* combat override (2 functions + a fallback), the template table, the editor kind
  picker, the multi-attach join + backfill.
- *Bigger build:* the polygon→field/site generators (new world-data authoring), exploration validation,
  auto-minting host locations for standalone combat zones.

---

## 5. Doability verdict (honest, per kind)

- **`pirate_combat` — CLOSEST / HIGH confidence.** The difficulty engine is already a pure function of
  `base_difficulty`/`reward_tier` with every knob in `game_config` (0234:161-167). The only real work is
  carrying a per-zone/template override into `combat_encounters` and reading `coalesce(override, loc.*)`
  in two spawn sites — a surgical, fully backward-compatible change. Multi-attach (§1.3) is the main
  adjacent plumbing. **Zone A=tier1 / Zone B=tier3 spawning different pirates is very achievable.**

- **`mining` — MEDIUM.** The system is **built** (extract-by-proximity, rewards, cooldown, RLS) but
  **dark** (`mining_enabled=false`). The zone layer is self-contained: a polygon→`mining_fields`
  generator + a placement↔field link; the extract path is untouched. Main new surface = generating
  world data from a polygon + richness profile (pin invariants like slime does, not coordinates).

- **`exploration` — MEDIUM–HIGH / least ready.** Structurally identical to mining, but the underlying
  system is **dark end-to-end and never proven in prod**. Building a zone layer on an unvalidated system
  is spaghetti risk; sequence it **last**, after lighting and proving exploration itself.

### Open questions / risks
1. **Standalone combat zones need a host location.** Combat still requires a real `locations` row to open
   an encounter (0233:475-483 stub). Multi-attach to existing pirate sites covers "reuse Zone A across the
   map"; a from-scratch combat zone with no site needs the 0233:44 auto-mint-location follow-up. Decide:
   auto-mint hidden host locations vs require attach.
2. **`danger_zones` naming** once it holds mining/exploration placements (§1.2) — generalize-in-place +
   neutral view, or rename with a compat view. Least-churn first; revisit after all kinds land.
3. **Tier → difficulty mapping** — authoring-friendly tiers (1/2/3) need a config/table mapping to
   `base_difficulty`, kept as one authority (not scattered literals).
4. **Generator determinism for CI** — random field/site placement must pin *invariants* (count, all
   inside polygon, valid reward shape), never exact coords — the slime-migration discipline (0237).
5. **Per-location vs per-attachment overrides** — v1 keeps the override on the template (all attachments
   of a placement share a tier). Per-attachment tuning is an additive later change if wanted.
