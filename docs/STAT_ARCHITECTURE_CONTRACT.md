# Byeharu — Canonical Stat Architecture: the IMPLEMENTATION CONTRACT

> **Status: DESIGN ONLY. Nothing here is built.** This is Phase 2 (Step 2) of the owner's
> canonical-stat directive — the contract to be approved *before* any code is written.
> Phase 1 was the read-only audit; every load-bearing claim below was re-verified against the
> repository on **2026-08-04** and is cited `file:line`. Where a Phase-1 finding turned out to be
> wrong, §0 says so.
>
> Prod migration head: `20260618000338`. Working branch at time of writing: `guard-the-chain`.
> **`20260618000339` is already taken** by branch `slice-a-fight-you-can-move-in`
> (`20260618000339_a_fight_you_can_move_in.sql`), so this program starts at **0340**. The
> implementer must re-check `scripts/check-migration-versions.mjs` before claiming a number.

---

## §0 — Corrections to the Phase 1 findings

Phase 1 is accurate in its architecture and in its diagnosis. Seven statements need correcting
before they are built against. All were checked directly.

| # | Phase-1 statement | Correction | Evidence |
|---|---|---|---|
| 1 | "Hull `attack`/`defense` live only in `base_stats_json` and are read live; **every other** hull stat is copied onto the instance at commission." | `main_ship_hull_types.base_speed` is **also** read live on every fold, not copied. The live-read set is `{base_stats_json, base_speed}`. Copied at commission: `base_hp, base_cargo_capacity, base_cargo_capacity_m3, base_support_capacity, base_captain_slots, base_module_slots, base_shield`. | `supabase/migrations/20260618000205_cmdbuff_command_buffs.sql:410` · `supabase/migrations/20260618000222_movement_writer_repoint.sql:246-275` |
| 2 | "The stat vocabulary is hand-written in **eight** places." | **Undercount.** There are **16 executable sites** (12 SQL, 4 TS), plus ~13 prose restatements that can drift. | Enumerated in §3.1 |
| 3 | "`evasion`, `scouting`, `mining_yield`, `repair`, `pirate_attention` have **zero consumers**." | `evasion` is an **input** key, not an output — its output name is `retreat_safety`. All five *outputs* have a real display read path (`calculate_group_expedition_stats` → `get_my_group_expedition_totals` → `TeamPreviewSection`). The accurate, and still damning, claim is **zero engine consumers**: nothing in `supabase/migrations` reads them to decide anything. | `supabase/migrations/20260618000166_slice_d0_group_stats_authority.sql:119-151` · `src/features/command/teamSkillset.ts:55-66` · `src/features/command/TeamPreviewSection.tsx:136-159` · stated in-repo at `supabase/migrations/20260618000183_mod2_shield_line.sql:36` |
| 4 | "There is a **single** `insert into combat_units`, in `combat_create_group_encounter`." | There are **three live insert sites**: the group builder (`20260618000301_intercept_fires_at_zone_entry.sql:839`), the legacy solo/catalog builder `combat_create_encounter` (`…0301…:948`), and the enemy-wave spawn **inside `process_combat_ticks`** (four sites patched at `20260618000336_combat_engine_repairs.sql:483, :523, :538, :596`). Only the first is a *player-ship* snapshot; that one is single, and the contract keeps it that way. | as cited |
| 5 | "`repair_credits_per_hp` is 0 (deliberate)." | The **repo seeds `'0.5'`** (`20260618000201_repairecon_hull_repair.sql:64`). The `0` is a *runtime* value the owner set, recorded only as prose at `20260618000335_one_way_to_repair.sql:61-64` — and it was a **live outage**, not a dormant knob: 0201 treated `<= 0` as `repair_misconfigured` and turned paid repair off for every player until 0335 redefined zero as free. | as cited |
| 6 | "The concealment handler is at `0301:807-809`." | It is at **`20260618000301_intercept_fires_at_zone_entry.sql:804-806`** (807 is the closing `end;`). It is present, unmodified, in the current deployed body: `…0301…:661` is the last full `create or replace` of `combat_create_group_encounter`, and none of the eight later text-patch migrations (0308/0313/0315/0316/0320/0330/0331/0336) touches it. **Verified surviving.** | as cited |
| 7 | "Branch protection requires only `build`, with `enforce_admins: false`." | **Not verifiable in-repo.** `.github/` contains only `workflows/`; `enforce_admins` appears nowhere in the repository. The "only `build`" half is asserted in three places as prose (`.github/workflows/build.yml:41-42`, `scripts/check-migration-versions.mjs:13-15`, `docs/DEV_LOG.md:807-809`) and `docs/HANDOFF.md:342` **contradicts** it. Treat as: *the deploy-time self-assert is the only proof that cannot be bypassed.* | as cited |

Two further facts Phase 1 did not surface, both load-bearing:

- **A fleet-scope authority already exists and is single.** `calculate_group_expedition_stats(p_player, p_group_id, p_activity_type)` — `20260618000166_slice_d0_group_stats_authority.sql:58`, never redefined since. It blanket-sums eight stats and takes `min` for speed, exactly the pattern the owner's directive forbids. It is **not** display-only: it drives movement speed (`20260618000207_fleetgo_unified_group_mover.sql:299`), intercept risk (`20260618000301…:543`), docking and retreat. This is the fleet resolver's predecessor and **must be retired onto it, not run beside it.**
- **Migration 0331 already unified the input vocabulary to nine keys.** `attack, defense, repair, cargo, scan, mining, evasion, pirate_attention, speed_mult_bonus` — the hull now speaks 8 of them (`20260618000331_one_authority_for_attack.sql:447-454`), traits and command buffs 9 (`:464-476`, `:486-497`), and `pirate_attention` became a catalog key with the old hardcoded CASE demoted to a default (`:504-508`, `:515-519`). 0331 also **deleted** the support-craft loop, the `warnings` array and `support_capacity_used/_limit` from the output (`:355-399`). This contract builds *on* 0331's direction; it does not reverse it.

---

## §1 — The three authorities: final names and signatures

Naming follows the repo's `resolve_*` leaf family (`resolve_location_encounter`,
`resolve_encounter_reward_inputs`, `resolve_fleet_movement_speed`), `p_`-prefixed parameters,
`public` schema, `security definer`, `set search_path = ''`, server-only ACL.

### 1.1 Effective-stat resolver

```sql
create function public.resolve_effective_stats(
  p_scope       text,                                  -- 'ship' | 'fleet'
  p_entity_id   uuid,
  p_context     jsonb       default '{}'::jsonb,
  p_resolved_at timestamptz default now())
returns jsonb
language plpgsql stable security definer set search_path = '';
```

`p_scope = 'ship'` → `p_entity_id` is `main_ship_instances.main_ship_id`.
`p_scope = 'fleet'` → `p_entity_id` is **`ship_groups.group_id`**.

> **Naming collision, decided here, not escalated.** In this codebase `fleets` is the *spatial
> vehicle* (it carries position, `20260616000006_fleet_system.sql`) and `ship_groups` is the
> *roster* (`20260618000160_slice_a_ship_groups.sql:38-46`). Membership truth is
> `main_ship_instances.group_id`. The owner's word "fleet" means the roster, so
> `p_scope='fleet'` takes a `group_id` — matching the existing
> `calculate_group_expedition_stats(p_player, p_group_id, …)` it replaces. A `fleets.id` is never
> a valid `p_entity_id`. The registry and every comment say so.

Composed by two pure leaves, so that the deterministic arithmetic can be proven without a database
containing anything (see §12.3):

```sql
create function public.stat_registry_snapshot()          -- the registry as one jsonb, ordered
returns jsonb language sql stable;

create function public.stat_combine(                     -- THE pure fold. No table reads.
  p_contributions jsonb,   -- [{stat_id, source_kind, source_id, operation, amount}, …]
  p_bases         jsonb,   -- {stat_id: base_numeric}
  p_registry      jsonb)   -- stat_registry_snapshot()
returns jsonb language sql immutable;

create function public.stat_aggregate_fleet(             -- THE pure per-stat aggregation.
  p_member_stats  jsonb,   -- [{entity_id, stats:{…}}, …]  (member order irrelevant)
  p_registry      jsonb)
returns jsonb language sql immutable;
```

`resolve_effective_stats` **gathers** rows and calls these three. It contains no stat arithmetic of
its own. That split is what makes §12's non-vacuous deploy-time assert possible.

### 1.2 Buff resolver

```sql
create function public.resolve_active_buffs(
  p_scope       text,
  p_entity_id   uuid,
  p_context     jsonb       default '{}'::jsonb,
  p_resolved_at timestamptz default now())
returns jsonb
language plpgsql stable security definer set search_path = '';
```

with two leaves:

```sql
create function public.buff_derive_source_instances(     -- condition-sourced buffs (command ships)
  p_scope text, p_entity_id uuid, p_resolved_at timestamptz)
returns jsonb language sql stable security definer set search_path = '';

create function public.buff_apply_stacking(              -- pure. policy + ordering + expiry filter
  p_instances jsonb, p_registry jsonb, p_resolved_at timestamptz)
returns jsonb language sql immutable;
```

### 1.3 Level/XP resolver

```sql
create function public.progression_level_for_xp(p_track_id text, p_xp numeric)
returns integer language sql stable;                     -- level derived from XP, never stored

create function public.progression_xp_for_level(p_track_id text, p_level integer)
returns numeric language sql stable;                     -- the inverse; the two are asserted inverse

create function public.resolve_progression(
  p_track_id text, p_entity_id uuid, p_resolved_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = '';
```

### 1.4 The dependency graph (acyclic, enforced)

```
                 stat_definitions ─────────────┐  (data only, no calls)
                        ▲                      │
                        │                      ▼
  progression_curves ─► progression_* ──►  resolve_effective_stats
                                ▲              ▲
                                │              │
   buff_definitions ─► resolve_active_buffs ───┘
   buff_instances  ─────────┘
```

Edges, all downward, all read-only:

- `resolve_effective_stats` → `resolve_active_buffs`, `resolve_progression`, `stat_definitions`
- `resolve_active_buffs` → `stat_definitions`, `resolve_progression` *(magnitude scaling only)*
- `resolve_progression` → `progression_curves`, `progression_tracks` *(leaf; calls nothing)*

**Forbidden edge, self-asserted at deploy:** `resolve_active_buffs` and any function it calls must
never call `resolve_effective_stats`. A buff magnitude may be a constant, or a constant scaled by a
**progression level**; it may never be a function of a resolved stat. That single prohibition is
what keeps the graph acyclic and the resolver terminating. Enforced by a `prosrc` assert
(`strpos(prosrc, 'resolve_effective_stats') = 0`) over the buff family, in the idiom of
`20260618000260_encounter_runtime_resolver.sql:1256-1264`.

---

## §2 — Input / output schemas, types and units

### 2.1 `resolve_effective_stats` output

```jsonc
{
  "resolver_version": "stat-v1",          // text; bumped on any change to combination semantics
  "registry_version": 7,                  // integer; max(stat_definitions.revision) — see §3.2
  "scope": "ship",                        // text
  "entity_id": "…uuid…",
  "resolved_at": "2026-08-04T…Z",         // timestamptz, echoed exactly as supplied
  "context": { "purpose": "combat_spawn" },
  "stats": {                              // stat_id -> numeric, rounded per registry
    "combat_power": 15.00,
    "survival": 10.00,
    "speed": 1.000,
    "cargo_capacity": 50
  },
  "breakdown": [                          // ordered, deterministic, ALWAYS present
    { "stat_id":"combat_power", "step":10,  "source_kind":"hull",
      "source_id":"starter_frigate", "operation":"flat", "amount":15.00, "running":15.00 },
    { "stat_id":"combat_power", "step":40,  "source_kind":"module",
      "source_id":"…module_instance uuid…", "operation":"flat", "amount":4.00, "running":19.00 },
    { "stat_id":"combat_power", "step":90,  "source_kind":"clamp",
      "source_id":"stat_definitions.min_value", "operation":"clamp", "amount":0, "running":19.00 }
  ],
  "members": [ … ]                        // fleet scope only: per-member {entity_id, stats}
}
```

**Numeric contract.** Everything internal is Postgres `numeric` (never `double precision`, never
`float8`) — the fold today transits `float8` in places and that is how a mis-set `"NaN"` knob was
able to poison every stat (`20260618000198_nanguard_fix.sql`). `numeric` has no NaN-ordering trap.
Each stat is rounded **once**, at the end, to `stat_definitions.round_to` decimal places, then
clamped to `[min_value, max_value]`. A stat whose `numeric_domain = 'integer'` is emitted as a JSON
integer; everything else as a JSON number with exactly `round_to` decimals.

**Units are declared per stat, in the registry, and appear in the stat's name where ambiguity has
already bitten** — `combat_fleet_move_speed` is world-units-per-**tick** while the fold's `speed`
is world-units-per-**second**, and that exact confusion is documented as a shipped defect at
`20260618000316_combat_five_times_tighter.sql:418-425`. The registry carries a `unit` column; a new
stat whose unit duplicates an existing one under a different name is rejected by the seed assert.

**Determinism laws, asserted at deploy** (the `20260618000260…:1246-1254` idiom):
`random(`, `setseed`, `now()`, `clock_timestamp()`, `current_timestamp` occur **zero** times in
`stat_combine`, `stat_aggregate_fleet` and `buff_apply_stacking`. Time enters only as
`p_resolved_at`, supplied by the caller. Two calls with the same arguments return byte-identical
jsonb.

**No concealing fallbacks.** `coalesce(x, 0)` is legal *only* for an absent catalog key (absent = the
row does not claim that stat). It is **illegal** for a malformed value: a `stats_json` key present
but not castable to `numeric`, a negative `magnitude` where the registry forbids it, or an unknown
`stat_id` **raises**, naming the row. Enforced by a `jsonb_typeof(...) = 'number'` guard rather than
a cast-with-coalesce.

### 2.2 `resolve_active_buffs` output

```jsonc
{
  "resolver_version": "buff-v1",
  "scope": "fleet", "entity_id": "…", "resolved_at": "…",
  "buffs": [                              // ordered by (operation_rank, evaluation_order, buff_def_id)
    { "buff_instance_id":"…", "buff_def_id":"t0_gunnery_command",
      "source_kind":"command_ship", "source_instance_id":"…main_ship_id…",
      "stat_id":"combat_power", "operation":"flat", "magnitude":3.00,
      "stacking_group":"command_doctrine", "stacking_policy":"highest_magnitude",
      "evaluation_order":100, "starts_at":"…", "expires_at":null,
      "duration_kind":"while_source_holds", "suppressed_by":null }
  ],
  "suppressed": [ … ]                     // instances filtered by stacking/expiry/context, WITH the reason
}
```

`suppressed[]` is not decoration. It is how a player-facing "why is my buff not working" question
gets an answer without reading the tick, and it is what the parity proof diffs.

### 2.3 `resolve_progression` output

```jsonc
{ "track_id":"captain_v1", "entity_id":"…", "xp":450, "level":3,
  "xp_into_level":50, "xp_for_next_level":900, "xp_to_next_level":450,
  "max_level":null, "post_cap_behaviour":"accumulate_xp_no_level", "at_cap":false }
```

`xp` is `numeric` (matching `captain_instances.xp numeric not null check (xp >= 0)`,
`20260618000177_captain_xp_foundation.sql:94-96`). `level` is `integer >= 1`.

---

## §3 — The stat registry (the heart of the contract)

### 3.1 What it replaces — the 16 executable sites, enumerated

**SQL (12):**

1. hull fold — `supabase/migrations/20260618000331_one_authority_for_attack.sql:447-454`
2. trait fold — `…0331…:464-476`
3. command-buff fold — `…0331…:486-497`
4. module fold — `supabase/migrations/20260618000205_cmdbuff_command_buffs.sql:555-562` (+ `…0331…:504-508`)
5. captain fold — `…0205…:626-633` (+ `…0331…:515-519`)
6. fold output object — `…0205…:666-685`
7. trait-catalog key allowlist — `supabase/migrations/20260618000186_soul0_traits_foundation.sql:346`
8. command-buff catalog key allowlist — `…0205…:742`
9. 0331 self-assert key array — `…0331…:740`
10. fleet fold — per-member reads, `supabase/migrations/20260618000166_slice_d0_group_stats_authority.sql:119-126`
11. fleet fold — totals object, `…0166…:142-151`
12. `prosrc`-pinning self-asserts in later migrations, e.g. `supabase/migrations/20260618000202_mod22_mk2_tier.sql:237-238`, `supabase/migrations/20260618000183_mod2_shield_line.sql:201`

**TypeScript (4):**

13. `src/features/command/teamSkillset.ts:38-51` — `MemberStats`
14. `src/features/command/teamSkillset.ts:55-66` — `ADDITIVE_STAT_KEYS` *(also encodes the aggregation rule)*
15. `src/features/ship/shipTraits.ts:57` — `STAT_KEY_ORDER`
16. `src/features/port/portShop.ts:44-52` — `STAT_LABELS`

Plus, when a stat must actually *render*: `src/features/ship/shipDossierView.ts:70-75` and `:92-100`,
`src/features/ship/FittingDetail.tsx:481-484`, `src/features/command/TeamDossier.tsx:129-155`,
`src/features/command/TeamPreviewSection.tsx:140-163`, `src/features/ship/moduleInfoView.ts:55-69`,
and the specs `tests/teamSkillset.spec.ts`, `tests/shipDossier.spec.ts`.

Nothing checks that any of these agree with any other.

### 3.2 The registry table

```sql
create table public.stat_definitions (
  stat_id            text collate "C" primary key,      -- canonical id; snake_case; the OUTPUT name
  catalog_key        text collate "C" not null unique,  -- the key catalogs write in stats_json
  display_name       text not null,
  display_order      integer not null unique,
  value_kind         text not null check (value_kind in ('flat','fraction','multiplier')),
  unit               text not null,                     -- 'points' | 'm3' | 'wu_per_second' | 'fraction'
  numeric_domain     text not null check (numeric_domain in ('integer','numeric')),
  round_to           integer not null check (round_to between 0 and 4),
  min_value          numeric,                           -- null = unbounded
  max_value          numeric,
  ship_base_source   text not null check (ship_base_source in ('none','instance_column','hull_column')),
  ship_base_ref      text,                              -- column name; null iff ship_base_source='none'
  combination_class  text not null check (combination_class in ('additive','multiplier_bonus')),
  fleet_aggregation  text not null check (fleet_aggregation in
                       ('sum','min','max','average','weighted_average','primary_ship','none')),
  fleet_weight_stat  text references public.stat_definitions (stat_id),
  combat_snapshot    text not null check (combat_snapshot in ('frozen','live','not_applicable')),
  engine_consumer    text,                              -- the ONE function that decides on it; null = display-only
  revision           integer not null default 1,
  is_active          boolean not null default true,
  registered_in      text not null,                     -- the migration that registered it
  constraint stat_definitions_base_ref_coherent
    check ((ship_base_source = 'none') = (ship_base_ref is null)),
  constraint stat_definitions_weight_coherent
    check ((fleet_aggregation = 'weighted_average') = (fleet_weight_stat is not null)),
  constraint stat_definitions_no_blanket_sum
    check (fleet_aggregation <> 'sum' or value_kind = 'flat')   -- a fraction/multiplier can never be summed
);
```

Posture: **Reference/Config** in the `docs/SYSTEM_BOUNDARIES.md:27` sense — migration-seeded only,
no runtime writer ever, RLS on, `grant select` to `anon, authenticated`, **`revoke insert, update,
delete`** explicitly (the `20260618000254` grant-drift precedent: a Supabase project-default
`GRANT ALL` must be revoked, not merely asserted absent).

`revision` exists so `resolve_effective_stats` can stamp `registry_version = max(revision)` into
every result and every combat snapshot. A snapshot taken under registry version 6 is legible
forever; a consumer can refuse a snapshot it does not understand instead of silently mis-reading it.

### 3.3 The seed — the current vocabulary, as data

Nine rows, transcribed from the deployed fold. `stat_id` is the output name (what consumers and the
UI already use); `catalog_key` is the legacy input key (what catalogs already write). Both are
preserved exactly, so the seed is provably behaviour-neutral.

| stat_id | catalog_key | value_kind | unit | round_to | ship base | combination | fleet agg | combat snapshot | engine consumer |
|---|---|---|---|---|---|---|---|---|---|
| `combat_power` | `attack` | flat | points | 2 | none | additive | **sum** | frozen | `combat_create_group_encounter` |
| `survival` | `defense` | flat | points | 2 | none | additive | **sum** | frozen | `combat_create_group_encounter` |
| `speed` | `speed_mult_bonus` | multiplier | wu_per_second | 3 | hull_column `base_speed` | multiplier_bonus | **min** | frozen | `command_ship_group_go` |
| `cargo_capacity` | `cargo` | flat | points | 0 | instance_column `cargo_capacity` | additive | **sum** | not_applicable | *(null — see §4.3)* |
| `repair` | `repair` | flat | points | 2 | none | additive | **sum** | not_applicable | *(null)* |
| `scouting` | `scan` | flat | points | 2 | none | additive | **max** | not_applicable | *(null)* |
| `mining_yield` | `mining` | flat | points | 2 | none | additive | **sum** | not_applicable | *(null)* |
| `retreat_safety` | `evasion` | flat | points | 2 | none | additive | **min** | not_applicable | *(null)* |
| `pirate_attention` | `pirate_attention` | flat | points | 2 | none | additive | **sum** | not_applicable | *(null)* |

All nine carry `min_value = 0` — the deployed fold clamps every output with
`greatest(0, …)` (`…0205…:676-683`) and `speed` with `greatest(0.2, …)` (`…0205…:662`), so `speed`
takes `min_value = 0.2`.

### 3.4 How the fold becomes registry-driven

The vocabulary stops being code. Every contributor is a **row**, and the registry join produces the
stats:

```sql
with src as (
    select 'hull'::text  k, v_ship.hull_type_id::text sid, h.base_stats_json j, 1::numeric mult
      from public.main_ship_hull_types h where h.hull_type_id = v_ship.hull_type_id
  union all
    select 'trait',       tr.trait_type_id, tt.stats_json, 1
      from public.main_ship_traits tr join public.ship_trait_types tt using (trait_type_id)
     where tr.main_ship_id = v_ship.main_ship_id and v_traits_enabled
  union all
    select 'module',      mi.module_instance_id::text, mt.stats_json, 1
      from public.ship_module_fittings f
      join public.module_instances mi using (module_instance_id)
      join public.module_types mt on mt.id = mi.module_type_id
     where f.main_ship_id = v_ship.main_ship_id
  union all
    select 'captain',     ci.id::text, ct.stats_json, v_lvl_mult * v_aff_mult   -- per-row, §4.1
      from public.ship_captain_assignments a … 
  union all
    select 'command_buff', cb.buff_id, cb.stats_json, 1   -- migrated to buff_instances in S4, §5.4
      from … 
),
contrib as (
  select d.stat_id, s.k source_kind, s.sid source_id,
         case when jsonb_typeof(s.j -> d.catalog_key) <> 'number'
              then stat_raise_malformed(s.k, s.sid, d.catalog_key)     -- refuse, never coalesce
              else (s.j ->> d.catalog_key)::numeric * s.mult end amount
    from src s
    join public.stat_definitions d on s.j ? d.catalog_key
   where d.is_active
)
select public.stat_combine(
         (select jsonb_agg(to_jsonb(c) order by c.stat_id, c.source_kind, c.source_id) from contrib c),
         v_bases, public.stat_registry_snapshot());
```

`v_bases` is a bounded three-entry list (`speed` ← `main_ship_hull_types.base_speed`,
`cargo_capacity` ← `main_ship_instances.cargo_capacity`, and `max_hp` when it is registered), built
from columns the resolver has already read. It grows only when a stat's base becomes a **new
physical column** — which is a schema change regardless.

### 3.5 **The answer: 16 files → 1**

Adding one new stat of the ordinary kind — a numeric contribution any catalog can declare in its
`stats_json`, folded at ship scope, aggregated at fleet scope by a registered rule, displayed with a
label and an order — is **one file**: a single migration containing a single
`insert into public.stat_definitions (…) values (…) on conflict (stat_id) do nothing;`.

**N = 1.**

Nothing else changes. The fold reads the row. The fleet aggregation reads the row. The catalog seed
allowlists (`…0186…:346`, `…0205…:742`) become `where exists (select 1 from stat_definitions …)` and
read the row. The client label and ordering come from a new read RPC `get_stat_definitions()` served
into a store, so `STAT_LABELS` and `STAT_KEY_ORDER` cease to exist.

Two honest boundaries on that number:

- **N = 2** if the stat must *drive* something new: the row, plus the one engine consumer that reads
  it. That consumer is named in `stat_definitions.engine_consumer`, so "which function decides on
  this stat" is itself data. A stat with `engine_consumer is null` is display-only **by declaration**
  — the state five stats are in today by accident.
- **N = 2** if the stat's base value is a new physical column on `main_ship_instances` or
  `main_ship_hull_types` (the `ALTER TABLE` plus the row). Pure-catalog stats — the common case —
  stay at 1.

There is no path at which it is 16 again, because the 16 sites are gone, not merely tidied.

---

## §4 — Combination order and per-stat fleet aggregation

### 4.1 Ship-scope combination order (preserving today's arithmetic exactly)

The deployed fold is entirely additive into one accumulator set, with two per-captain multipliers and
one speed multiplier. The contract fixes that as a *declared* order with numbered steps, so the
`breakdown` is stable and the parity proof can compare step by step:

| step | stage | what | today |
|---|---|---|---|
| 0 | `base_override` | a buff may replace a base outright | *(no source today)* |
| 10 | base | hull column / instance column | `…0205…:410`, `v_ship.cargo_capacity` |
| 20 | flat: hull `base_stats_json` | 8 keys | `…0331…:447-454` |
| 30 | flat: ship traits | 9 keys, gated `ship_traits_enabled` | `…0331…:464-476` |
| 40 | flat: fitted modules | 9 keys | `…0205…:555-562`, `…0331…:504-508` |
| 50 | flat: assigned captains | 9 keys **× level mult × affinity mult** | `…0205…:626-633` |
| 60 | flat: buffs (`operation='flat'`) | command buffs today | `…0331…:486-497` |
| 70 | additive % (`additive_pct`) | Σ then apply once | the `speed_mult_bonus` sum, `…0205…:662` |
| 80 | multiplicative % (`multiplicative_pct`) | applied in registry order | *(no source today)* |
| 90 | clamp | `greatest(min_value, least(max_value, x))` then round | `…0205…:662-683` |

**Additive contributions commute, so steps 20–60 cannot change a total** — the fold's own comment
says exactly this (`…0205…:426-428`). The order is fixed anyway, because the `breakdown` must be
reproducible and because steps 70–90 are order-sensitive.

The two captain multipliers are preserved verbatim, including their gating and their non-application
to tradeoffs:

- level: `v_lvl_mult := case when v_growth then 1 + (level - 1) * v_lvl_bonus else 1 end` (`…0205…:603`)
- affinity: `v_aff_mult := case when station.affinity = captain.specialization then 1 + v_aff_bonus else 1 end` (`…0205…:619`)

Both are per-source **scale multipliers** in the new model (`src.mult` in §3.4) — the same number
applied at the same site, now declared rather than hand-repeated at eight call sites.

### 4.2 Fleet-scope aggregation, per stat, justified

Blanket summation is retired. Each rule is justified from how the game uses the stat **today**.

| stat | rule | why, from the code |
|---|---|---|
| `speed` | **min** | A fleet arrives together, so it travels at its slowest ship. This is already the rule in three independent places: the fleet fold (`…0166…:129-135`), the live mover's three inline copies (`20260618000330_the_mover_is_in_the_repo.sql:1473, :1715, :1790`), and combat (`combat_fleet_move_speed` = `min(move_speed)`, `20260618000337_reposition_is_a_move.sql:133-146`). Summing would make an eight-ship fleet eight times faster than one ship — nonsense that only the `min` has ever prevented. |
| `combat_power` | **sum** | Damage is extensive: every gun on every ship fires. The `min_power_required` gate already sums it (`…0330…:1472`), the encounter builder sums it into `v_power` (`…0301…:809`), and 0331 then splits that sum across the fleet's weapons by share weight (`…0331…:626-632`). |
| `survival` | **sum** | Extensive for the same reason — it is the fleet's aggregate ability to absorb, and intercept risk already reads `combat_power + survival` as one combined pool (`…0301…:543`). |
| `repair` | **sum** | Each ship's repair capacity is independent work per unit time. Extensive. No engine consumer today, so the rule is declared now and inert until one exists. |
| `mining_yield` | **sum** | Each ship mines its own rock. Extensive. |
| `pirate_attention` | **sum** | More hulls = a bigger signature. Extensive, and it is the one stat where "the fleet is worse than any one member" is the intended meaning. |
| `scouting` | **max** *(change)* | Detection quality is **intensive**: the fleet sees as far as its best sensor. Summing means eight blind freighters out-scan one dedicated scout, which inverts the fitting decision the stat exists to create. Today it is summed (`…0166…:123`) and has **no engine consumer**, so the correction is display-only. |
| `retreat_safety` | **min** *(change)* | Evasion is **intensive and weakest-link**: a fleet escapes only as cleanly as its most exposed ship. Summed (`…0166…:122`) it means bolting a fat hauler onto a strike group makes the group *harder to catch* — backwards. No engine consumer, so display-only. |
| `cargo_capacity` | **sum** | Hold volume is extensive. But see §4.3 — this is not the cargo authority the engine uses. |

**Ranges are never aggregated, at either scope.** Weapon range lives per weapon in
`combat_units.weapons_json` (`20260618000234_combat_spatial_tick.sql:172-176`) and is deliberately
excluded from the registry. The hazard is not hypothetical: freezing `my_range = max(range)` per ship
silently disabled a shorter gun on the same hull, shipped and documented as defect #7 at
`20260618000336_combat_engine_repairs.sql:35-40`. Any future range stat must carry
`fleet_aggregation = 'none'`, and the `stat_definitions_no_blanket_sum` CHECK plus a seed assert
refuse a range-unit stat with `sum`, `average` or `weighted_average`.

`primary_ship` and `weighted_average` are registered as valid rules with **no stat using them at
seed time**, so the vocabulary is complete without inventing content. `primary_ship` resolves the
group's lead via the existing `v_lead_ship_id` derivation (`20260618000315_every_fleet_has_a_lead.sql`),
which is already the one authority for "which ship leads".

### 4.3 The second cargo authority — recorded, not silently absorbed

`cargo_capacity` (unitless, from the fold) and `fleet_hold_capacity_m3` /
`fleet_hold_used_m3` (cubic metres, `20260618000333_items_have_a_place.sql`) are **two cargo
authorities in two units**. Every actual cargo decision — transfers, port sales, hold limits — goes
through the m3 pair; the fold's `cargo_capacity` decides nothing. The contract registers
`cargo_capacity` with `engine_consumer = null`, i.e. **display-only by declaration**. Unifying the
two is a separate slice and is listed in the owner-decision list (§14 D4), because collapsing them
changes live hold sizes.

---

## §5 — Buffs: model, stacking, operation order

### 5.1 What exists today

There is **no temporary-buff system anywhere in the 323-migration chain.** No active-buff table, no
expiry column, no stacking rule. Verified: `expires_at` / `ends_at` / `duration` appear only on
`location_presence`, `combat_reports`, `ranking_seasons`, `world_events`, `haul_contracts` — none of
them a stat modifier. The zone-effect tables (`zone_effect_pirate_intercept`, `zone_effect_combat`,
`zone_effect_mining`, `zone_effect_exploration`) are **static per-zone configuration**, never touch
`calculate_expedition_stats`, and modify only the zone's own spawn/reward parameters. They are not a
buff system and this contract does not annex them.

The only buff mechanism is `command_buff_types` (catalog, 5 columns, 20 seeded rows,
`20260618000205_cmdbuff_command_buffs.sql:89-98`) plus the immutable
`main_ship_instances.command_buff_id` (`…0205…:190-191`), rolled deterministically by
`command_buff_roll_for_ship` and NULL-guarded so it can never be re-rolled (`…0205…:256-258`).

**One correction to Phase 1:** command buffs *do* stack structurally. The fold loops over **every**
`is_command_ship` row in the group and sums (`…0205…:465-483`); the index is not unique
(`20260618000204_fleetctrl_command_ship.sql:75-76`) and `set_fleet_command_ship` never clears another
ship's flag (`…0204…:117-119`). N flagged ships today means N buffs summed, with no rule saying so.
The buff resolver's first job is to give that behaviour a *name*.

### 5.2 The model

```sql
create table public.buff_definitions (
  buff_def_id      text collate "C" primary key,
  source_kind      text not null check (source_kind in ('command_ship','consumable','zone','event','debug')),
  target_scope     text not null check (target_scope in ('ship','fleet')),
  stat_id          text not null references public.stat_definitions (stat_id),
  operation        text not null check (operation in
                     ('base_override','flat','additive_pct','multiplicative_pct','clamp_min','clamp_max')),
  magnitude        numeric not null,
  magnitude_per_level integer,                  -- optional: scale by a progression level (the ONLY
                                                -- dynamic input a buff may take; see §1.4)
  progression_track text references public.progression_tracks (track_id),
  stacking_group   text collate "C" not null,
  stacking_policy  text not null check (stacking_policy in
                     ('stack_all','highest_magnitude','latest_only','longest_remaining','first_only')),
  evaluation_order integer not null,
  duration_kind    text not null check (duration_kind in
                     ('permanent','timed','while_source_holds')),
  default_duration_seconds integer,
  context_restriction jsonb not null default '{}'::jsonb,
  is_active        boolean not null default true,
  registered_in    text not null,
  constraint buff_definitions_duration_coherent
    check ((duration_kind = 'timed') = (default_duration_seconds is not null)),
  constraint buff_definitions_level_scale_coherent
    check ((magnitude_per_level is null) = (progression_track is null))
);

create table public.buff_instances (
  buff_instance_id   uuid primary key default gen_random_uuid(),
  buff_def_id        text not null references public.buff_definitions (buff_def_id),
  target_scope       text not null check (target_scope in ('ship','fleet')),
  target_entity_id   uuid not null,
  source_instance_id uuid,                      -- WHICH ship / WHICH consumable granted it
  granted_at         timestamptz not null default now(),
  starts_at          timestamptz not null,
  expires_at         timestamptz,               -- null = never (permanent / while_source_holds)
  magnitude_override numeric,
  unique (buff_def_id, target_scope, target_entity_id, source_instance_id)
);
```

**No executable expression is ever stored.** `magnitude` is `numeric`. `operation` is a
CHECK-constrained enum. `context_restriction` is `{key: [scalar, …]}` and is matched by **equality
against `p_context` only** — never parsed, never evaluated. A deploy-time assert walks every seeded
row and refuses any value that is not a scalar or an array of scalars. There is no formula column,
no `eval`, no `execute`, and a `prosrc` assert proves `execute ` and `format(` do not appear in the
buff family.

**Definition and instance are separate by construction** — a definition is catalog
(`Reference/Config`, migration-seeded), an instance is state (owned by the Buff system, one writer).

### 5.3 Operation order and stacking

Ordering is total and deterministic:

```
operation_rank:  base_override 0 → flat 100 → additive_pct 200 → multiplicative_pct 300
                 → clamp_min 400 → clamp_max 400
tiebreak:        evaluation_order asc, then buff_def_id asc (collate "C"),
                 then buff_instance_id::text asc          -- never a tie
```

`additive_pct` magnitudes are **summed within their rank and applied once** (`× (1 + Σ)`) — this is
already the shipped speed semantics (`…0205…:662`) and keeps eight +10% buffs at +80%, not ×2.14.
`multiplicative_pct` magnitudes are applied **in order, one at a time** (`× (1 + m)` each).

Stacking policies, applied per `stacking_group` **before** ordering:

| policy | rule | deterministic tiebreak |
|---|---|---|
| `stack_all` | every instance applies | — |
| `highest_magnitude` | only the largest effective magnitude | then `buff_instance_id` asc |
| `latest_only` | greatest `granted_at` | then `expires_at` desc, `buff_instance_id` asc |
| `longest_remaining` | greatest `expires_at` (null sorts last = longest) | then `buff_instance_id` asc |
| `first_only` | least `granted_at` | then `buff_instance_id` asc |

Every suppressed instance is returned in `suppressed[]` with the policy that suppressed it.

**Expiry.** An instance contributes iff `starts_at <= p_resolved_at and (expires_at is null or
expires_at > p_resolved_at)`. The comparison uses **only** `p_resolved_at`, never `now()`, so the
same timestamp always reproduces the same result — including replaying a past encounter.

### 5.4 Command buffs become the first registered source, not a neighbour

The twenty `command_buff_types` rows are migrated into `buff_definitions` — one row **per
(buff, stat)** pair, since a buff like `t1_convoy_doctrine` (`{"cargo": 6, "speed_mult_bonus": 0.02}`)
touches two stats and the model is one stat per definition. `stats_json` values map to
`operation='flat'` except `speed_mult_bonus`, which maps to `operation='additive_pct'` on `speed` —
exactly reproducing `…0205…:662`.

Their instances are **derived, never stored.** `buff_derive_source_instances` is the one function
that knows a command buff exists while its source ship is an `is_command_ship` member of the group
carrying a rolled `command_buff_id`. Deriving rather than materialising removes an entire class of
desync bug: there is no reconciler to fall behind membership changes, and the answer to "what is
buffing me right now" has exactly one producer. `resolve_active_buffs` unions the derived instances
with the stored ones and pushes both through the same stacking pipeline — one pipeline, two sources,
no fork.

Today's implicit stacking becomes explicit: `stacking_group = 'command_doctrine:' || stat_id`,
`stacking_policy = 'stack_all'` — which **is** the current behaviour, named. Changing it to
`highest_magnitude` (one doctrine per fleet) is a one-row edit afterwards, and a gameplay decision,
not an architecture one.

`command_buff_types` and `main_ship_instances.command_buff_id` are **not dropped** — the roll is the
ship's identity and is immutable by design. The *fold* stops reading them; `buff_derive_source_instances`
becomes their only reader. The retirement is of the duplicate fold, not of the mechanism.

---

## §6 — XP, curve and cap

### 6.1 What exists, exactly

XP exists on **one entity**: a captain instance. `\bxp\b` across all 323 migrations hits five files
(0177, 0180, 0181, 0189, 0191). There is no ship XP, no fleet XP, no player level; `profiles` has no
level column.

The curve, at both ends:

- server — `20260618000177_captain_xp_foundation.sql:268-270`:
  `level = 1 + floor(sqrt((ci.xp + f.xp) / 100.0))::integer`
- client — `src/features/captains/captainProgress.ts:23` `return (lv - 1) * (lv - 1) * XP_LEVEL_BASE`
  and `:29` `return 1 + Math.floor(Math.sqrt(xp / XP_LEVEL_BASE))`, `XP_LEVEL_BASE = 100` at `:18`

Level *L* begins at `(L-1)² × 100`. **This is the approved curve and it is preserved bit for bit.**

Two violations of the owner's law are live: the level is **cached into a column**
(`captain_instances.level integer not null check (level >= 1)`, `…0177…:94-96`), and the client holds
a second copy of the curve that already hedges about disagreement (`captainProgress.ts:3-8`).

There is **no cap**: `check (level >= 1)` is the only constraint, `xp` is unbounded `numeric`, and the
level multiplier `1 + (level - 1) * v_lvl_bonus` (`…0205…:603`) grows without bound once
`captain_growth_enabled` is lit.

### 6.2 The model

```sql
create table public.progression_curves (
  curve_id           text collate "C" primary key,
  kind               text not null check (kind in ('quadratic')),
  coefficient        numeric not null check (coefficient > 0),
  max_level          integer check (max_level is null or max_level >= 1),
  post_cap_behaviour text not null check (post_cap_behaviour in ('accumulate_xp_no_level','hard_stop')),
  registered_in      text not null);

create table public.progression_tracks (
  track_id      text collate "C" primary key,
  entity_scope  text not null check (entity_scope in ('captain','ship','fleet','player')),
  curve_id      text not null references public.progression_curves (curve_id),
  xp_store      text not null check (xp_store in ('captain_instances','progression_xp')),
  is_active     boolean not null default true,
  registered_in text not null);
```

`kind = 'quadratic'` means, and only means:

```
xp_for_level(L)  = (L - 1)^2 * coefficient
level_for_xp(x)  = 1 + floor(sqrt(x / coefficient))
```

Seed — the existing curve, preserved:
`('captain_v1_quadratic_100', 'quadratic', 100, <cap>, <post-cap>, '0340')`.
Deploy-time assert: `progression_level_for_xp('captain_v1', x)` equals
`1 + floor(sqrt(x/100))` for `x ∈ {0, 99, 100, 399, 400, 899, 900, 1e6}`, and
`progression_xp_for_level` is its exact inverse for `L ∈ 1..50`. Non-vacuous on an empty database.

### 6.3 Tracks: in scope now, deferred

**In scope for the first migration — exactly one:** `captain_v1`
(`entity_scope='captain'`, `curve_id='captain_v1_quadratic_100'`, `xp_store='captain_instances'`).

**Deferred, and deliberately not stubbed:** ship XP, fleet XP, player level. Registering an empty
track for content that does not exist would be the same "lit but inert" trap that produced five
zero-valued knobs and five consumer-less stats. A track is registered when its XP source exists.

### 6.4 Retiring the cached column (required, not optional)

The NO-SPAGHETTI law forbids running two. So the program **commits** to the retirement rather than
leaving the column beside the function:

- **S3** registers the curve, adds `progression_level_for_xp`, and self-asserts at deploy that
  `level = progression_level_for_xp('captain_v1', xp)` holds for **every row** of
  `captain_instances` — with an exact-cardinality guard so an empty table cannot pass the assert
  vacuously (§12.3).
- **S6** repoints all four server readers (`calculate_expedition_stats`'s join at `…0205…:588`,
  `get_my_captain_instances` at `20260618000181_haul_read_surface.sql:164-165`, the shipyard gate at
  `20260618000188_shipyard1_order_rpc.sql:238-242`, the 0331 self-assert at `…0331…:804-806`) and the
  six client readers onto the function, then **drops** `captain_instances.level` and deletes the
  duplicated curve from `src/features/captains/captainProgress.ts` (the file becomes a thin call to
  the served track definition). `captain_instances.xp` stays; it is the store the track names.
- The drop lands only behind a self-assert proving zero remaining `prosrc` references to the column
  — with line comments stripped first, the `20260618000333_items_have_a_place.sql:1975-1977` idiom,
  *"failing on prose would be the 0222 vacuity bug wearing the opposite mask."*

---

## §7 — The snapshot boundary

### 7.1 Decision: keep it exactly where it is

The player-ship snapshot stays at the single `insert into combat_units` inside
`combat_create_group_encounter` (`20260618000301_intercept_fires_at_zone_entry.sql:839-853`).

Three reasons, all from the code:

1. **It is the only place a fight's inputs are established.** Moving it means re-emitting
   `process_combat_ticks` — a body of roughly 73,000 characters that **no migration file holds
   whole** (`20260618000336_combat_engine_repairs.sql:6-7`) and that is only ever edited by
   `pg_get_functiondef` text slicing. That is the highest-blast-radius edit available in this
   repository, on a live 30-player game, for zero architectural gain.
2. **Freezing is correct.** A fight must not change its own inputs mid-fight; a player unfitting a
   module during a battle must not retroactively alter damage already dealt. The boundary is right;
   only its *bookkeeping* is wrong.
3. **The known failure mode is a wrong value, not a wrong place.** Fleet 1 was destroyed by an empty
   `weapons_json` yielding zero damage — a snapshot that was taken correctly and *contained the wrong
   number*. Relocating the boundary would not have prevented it; a declared, versioned, explainable
   snapshot would have made it visible in one query.

### 7.2 The asymmetry: declared, not removed

Today's split is real and partly deliberate:

- **Frozen at insert:** `attack_snapshot`, `defense_snapshot` (from one `calculate_expedition_stats`
  call at `…0301…:742-744`), `move_speed` (`…0301…:754`, scaled by `combat_player_speed_scale`,
  `20260618000316…:417-427`), `weapons_json` (`…0301…:767-776`), `shield_max`, `aggro_priority`, and
  — since 0331 hunks 11/12/14 — `hp_max` (`…0331…:531-560`).
- **Re-read every tick:** the auto-exit policy and its `sum(msi.max_hp)` denominator
  (`20260618000310_hp_auto_exit.sql:427-449`). That one is **deliberate and correct**: `…0310…:425-426`
  — *"Read fresh every tick on purpose: adjusting the threshold MID-FIGHT is the point of the
  feature."*

So the asymmetry is not one bug; it is one intentional live read and one former accident that 0331
already half-closed by freezing `hp_max` too — leaving hull capacity existing in **both** forms.

**The contract makes it a declaration.** `stat_definitions.combat_snapshot ∈ ('frozen','live',
'not_applicable')` states, per stat, which side of the boundary it is on. A stat marked `live` must
name the function that re-reads it. A deploy-time assert proves that every stat marked `frozen`
appears in the snapshot payload and that no stat marked `live` does. The asymmetry stops being an
accident that must be rediscovered by reading two migrations five hundred lines apart.

Additively, `combat_units` gains:

```sql
alter table public.combat_units
  add column resolved_stats_json jsonb,          -- nullable, NO backfill
  add column stat_resolver_version text,
  add column stat_registry_version integer;
```

written from **one** `resolve_effective_stats(p_scope=>'ship', p_context=>'{"purpose":"combat_spawn"}')`
call. The existing scalar columns keep driving the tick until parity is proven; then they are
repointed to read the payload, and the duplicate scalars are dropped last (§10, S7).

### 7.3 The silent concealment is removed in the same slice

```sql
-- 20260618000301_intercept_fires_at_zone_entry.sql:804-806
exception when others then
  v_attack := 0; v_defense := 0; v_hp := 0; v_alive := 0;
  v_shield_max := null; v_shield_cur := null;
```

This wraps the *entire* per-ship stat derivation. Any of the five raises
`calculate_expedition_stats` can produce (`…0205…:401, :408, :536, :577, :650`) enters that ship into
the fight as a **corpse** — `alive_count = 0`, `hp_current = 0`, `attack_snapshot = 0` — with no log,
no event, no warning, and the loop continues. The owner's directive forbids exactly this.

**Replacement, decided here:** the ship is **excluded** from the encounter, not entered as dead.
The handler raises a `WARNING` naming `main_ship_id` and `sqlerrm` (the repo's own per-row isolation
idiom, `20260618000206` CRON-GUARD, `docs/SYSTEM_BOUNDARIES.md:300-304`), records the exclusion in a
new `combat_encounters.excluded_members_json`, and — if **every** member fails — refuses to create
the encounter at all rather than starting a fight nobody is in.

Excluding rather than refusing-on-first-failure is chosen because refusing a whole encounter on one
bad ship would hand any single malformed row a denial-of-service over a live fleet's ability to
fight. Excluding is loud, bounded, and recoverable.

---

## §8 — Mutation boundaries

Every mutation that can change an effective stat, and what it may write. Derived from
`docs/SYSTEM_BOUNDARIES.md:21-81` and from the fold's actual reads (§1 of the agent trace).

| Mutation | May write | May NOT write |
|---|---|---|
| `fitting_apply` (fit/unfit) | `ship_module_fittings` | any stat, any resolver table |
| `captain_assign_apply` (assign/unassign/station) | `ship_captain_assignments` | " |
| `ship_room_configure` | `ship_room_slots` | " |
| `captain_xp_accrue` (cron, 5 min) | `captain_instances.xp` **only** — the derived `level` column is dropped in S6 | any other progression store |
| `soul_roll_traits_for_ship` | `main_ship_traits`, and `main_ship_instances.max_hp` once at roll time | never re-applies `hp_mult` |
| `command_buff_roll_for_ship` | `main_ship_instances.command_buff_id`, NULL-guarded, once ever | `buff_instances` |
| `set_fleet_command_ship` | `main_ship_instances.is_command_ship` | `buff_instances` (instances are derived) |
| `assign_ship_to_group` / unassign / group delete | `main_ship_instances.group_id` | " |
| commission creators (`port_entry_commission_build`, `ensure_main_ship_for_player`) | the instance row's copied hull columns, at INSERT only | no update path |
| `repair_ship_hull` | `main_ship_instances.hp`, `repair_receipts` | `max_hp` |
| `mainship_sync_combat_hp` / `_shield` | `hp` / `shield` | anything else |
| `combat_create_group_encounter` | `combat_units` (incl. the new `resolved_stats_json`) | `main_ship_instances` |
| `process_combat_ticks` | `combat_units` runtime columns, enemy spawns | **never** `resolved_stats_json` — a snapshot is written once, at birth |
| migration seeds (`module_types`, `captain_types`, `ship_trait_types`, `command_buff_types`, `main_ship_hull_types`, `stat_definitions`, `buff_definitions`, `progression_*`) | their own catalog rows | any instance row |
| `set_game_config` (service_role/CI) | `game_config` | — |
| **NEW** `buff_grant` / `buff_revoke` | `buff_instances` **only** — sole writer, service-role-only | any catalog, any stat |

**Three laws:**

1. **No mutation ever writes a resolved stat.** Effective stats are never stored outside the combat
   snapshot. There is no cache, no materialised view, no `effective_stats` column. The owner's
   preference for authoritative resolution is honoured absolutely: the *only* persisted resolver
   output in the entire design is `combat_units.resolved_stats_json`, and that is a **frozen
   historical record of a past fight**, not a cache — nothing ever reads it as a substitute for a
   live resolve.
2. **The three resolver families are `stable`, never `volatile`**, and hold no `insert`/`update`/
   `delete` against any table. Deploy-time `prosrc` assert.
3. **`stat_definitions`, `buff_definitions`, `progression_curves`, `progression_tracks` have no
   runtime writer, ever** — the `market_offers` / `ship_trait_types` posture. Client roles hold
   `select` and are explicitly `revoke`d `insert, update, delete`.

---

## §9 — Consumer migration order

Every step is behind `stat_resolver_enabled` (seeded `false`) and adds a **shadow** phase before a
**cutover** phase: shadow resolves both ways and records disagreement; cutover deletes the old path.

**First consumer: `get_my_expedition_preview`** — `20260618000159_a0_owned_ship_resolve_docked_store_and_preview.sql:185`.

Argued, not assumed:

- It writes **nothing**. It is `stable`, client-facing, read-only.
- It is **already wrapped** in `exception when others → {valid:false, error:sqlerrm}` (`…0159…:188-189`).
  A resolver defect degrades to a visible preview warning — the failure is loud and harmless. That is
  the exact opposite of the encounter builder, whose handler makes the same defect *invisible and
  lethal*.
- It has **one client call site** (`src/features/map/mainshipApi.ts:247`), and that site hard-codes
  `[]` for the loadout, so the input surface is a single ship id.
- Its output is display-only, so a divergence is seen by a human within one page load, which is the
  fastest feedback loop available in this codebase.

**Why not the combat snapshot first**, despite it being the most valuable target: the per-ship block
is wrapped in `exception when others then v_alive := 0` (`…0301…:804-806`). A resolver that raises
there does not fail — it silently enters real ships into a real fight as corpses, and the owner has
already lost a real fleet to a wrong number on that exact path. Debuting a new resolver behind a
handler that hides its failures is the single worst available choice. It goes **last**, and the
handler is removed in the same slice (§7.3).

Full order:

| # | Consumer | Kind | Risk | Gate |
|---|---|---|---|---|
| 1 | `get_my_expedition_preview` (`…0159…:185`) | display, ship scope | trivial — already envelope-wrapped | shadow → cutover |
| 2 | `get_my_group_expedition_totals` (`…0166…:158+`) | display, fleet scope | trivial | shadow → cutover |
| 3 | `calculate_group_expedition_stats` (`…0166…:58`) | **engine** — speed, intercept risk, docking, retreat | high; ~15 call sites | shadow ≥ 1 week, then retire the function onto `resolve_effective_stats('fleet', …)` |
| 4 | The three inline fleet-speed mins in the live mover (`…0330…:1473, :1715, :1790`) | engine | medium — arithmetic identical, source changes | fold onto step 3's output |
| 5 | `resolve_fleet_movement_speed` (`20260618000051…:32-61`) | engine | **behaviour-changing** — see §14 D2 | owner-gated |
| 6 | `combat_create_group_encounter` snapshot (`…0301…:839`) + concealment removal (§7.3) | engine, destructive-on-error | highest | last; own proof; own canary |
| 7 | Client: `STAT_LABELS`, `STAT_KEY_ORDER`, `MemberStats`, `ADDITIVE_STAT_KEYS` deleted; all read `get_stat_definitions()` | display | low | after 1–2 |

**Deliberately never migrated:** `fleet_speed` (`20260616000006_fleet_system.sql:87`),
`fleet_get_power` (`…:101`), `fleet_combat_stats` (`20260616000013_fleet_combat_fns.sql:6`) and
`combat_fleet_return_speed` (`20260618000167…:114`). These operate on `fleet_units`, which Phase 1
correctly identifies as vestigial. They are listed for **retirement** (§10, S8), not migration —
folding a dead path onto a live authority would be work spent keeping a corpse warm.

---

## §10 — Exact tables, functions and files, per step

Migration numbers start at **0340** (0339 is claimed). Each step is one migration plus one CI proof,
all additive, all dark.

### S1 — `0340_stats_have_a_registry.sql` — *foundation, dark, zero readers*
- **NEW tables:** `stat_definitions`
- **NEW functions:** `stat_registry_snapshot()`, `stat_combine(jsonb,jsonb,jsonb)`,
  `stat_aggregate_fleet(jsonb,jsonb)`, `stat_raise_malformed(text,text,text)`
- **NEW flag:** `stat_resolver_enabled` seeded `'false'`, `on conflict do nothing`
- **SEED:** the nine rows of §3.3
- **Self-asserts:** flag is dark · exactly 9 rows · every `catalog_key` matches a key the deployed
  fold actually reads (`prosrc` scan) · every `stat_id` matches a key the deployed fold actually
  emits · the `no_blanket_sum` CHECK exists · client roles hold no write grant · `stat_combine` is
  `immutable` and contains no `random(`/`now(` · **the pure-fold equivalence check of §12.3**
- **Files:** 1 migration, `scripts/stat-registry-proof.sql`, `.sh`, `.github/workflows/stat-registry-proof.yml`

### S2 — `0341_one_resolver_for_effective_stats.sql` — *the resolver, dark, zero readers*
- **NEW function:** `resolve_effective_stats(text,uuid,jsonb,timestamptz)`
- Reads exactly what `calculate_expedition_stats` reads, via §3.4's registry join
- **Self-asserts:** acyclicity (`prosrc` contains no `resolve_active_buffs` *yet*, no writes,
  `stable`) · client roles revoked · ACL · the resolver's output key set equals the registry's
  `is_active` set, cardinality-checked
- **Proof:** `scripts/stat-resolver-parity-proof.sql` — builds **its own** hulls, ships, modules,
  captains, traits and buffs (the `danger-combat-proof.sql` fixture idiom), then asserts
  `resolve_effective_stats('ship', s)` equals `calculate_expedition_stats(p, s, '[]', 'pirate_hunt')`
  stat for stat, across ≥ 12 constructed ships covering every source kind, both gate states, and the
  clamp boundaries

### S3 — `0342_a_level_is_derived_from_xp.sql` — *progression, dark*
- **NEW tables:** `progression_curves`, `progression_tracks`
- **NEW functions:** `progression_level_for_xp`, `progression_xp_for_level`, `resolve_progression`
- **SEED:** `captain_v1_quadratic_100`, track `captain_v1`
- **Self-asserts:** the closed-form checks of §6.2 · inverse property for `L ∈ 1..50` ·
  **every row** of `captain_instances` satisfies `level = progression_level_for_xp('captain_v1', xp)`,
  with an exact-cardinality guard so an empty table cannot pass vacuously

### S4 — `0343_a_buff_says_what_it_does.sql` — *buffs, dark*
- **NEW tables:** `buff_definitions`, `buff_instances`
- **NEW functions:** `resolve_active_buffs`, `buff_derive_source_instances`, `buff_apply_stacking`,
  `buff_grant`, `buff_revoke`
- **SEED:** the 20 `command_buff_types` rows re-expressed as `buff_definitions` (one row per
  (buff, stat) pair)
- **Self-asserts:** no stored expression (every `context_restriction` is scalar-or-array-of-scalars) ·
  `prosrc` of the buff family contains no `execute `/`format(`/`resolve_effective_stats` ·
  `buff_instances` is empty · client roles revoked on both tables · the derived command-buff
  instances for a constructed fixture group reproduce `…0205…:465-483`'s sum exactly

### S5 — `0344_the_resolver_composes_the_buffs.sql` — *wire buffs + progression into the resolver, still dark*
- `resolve_effective_stats` gains its two downward edges
- **Self-assert:** with `stat_resolver_enabled` dark and zero `buff_instances`, output is byte-identical
  to S2's — the double-inertness the repo already demands of every fold hunk

### S6 — `0345_one_answer_for_a_ships_stats.sql` — *cutover, consumers 1–2, plus the level-column retirement*
- Repoints `get_my_expedition_preview` and `get_my_group_expedition_totals`
- Repoints the four server + six client readers of `captain_instances.level`; **drops the column**
- Client: `get_stat_definitions()` RPC + store; delete `STAT_LABELS` (`src/features/port/portShop.ts:44-52`),
  `STAT_KEY_ORDER` (`src/features/ship/shipTraits.ts:57`), `MemberStats` + `ADDITIVE_STAT_KEYS`
  (`src/features/command/teamSkillset.ts:38-66`), and the duplicated curve in
  `src/features/captains/captainProgress.ts:18-29`

### S7 — `0346_one_answer_for_a_fleets_stats.sql` — *cutover, consumers 3–4*
- `calculate_group_expedition_stats` **dropped**, its ~15 call sites repointed via the
  `20260618000305_one_sortie_authority.sql:154+` slice-then-replace idiom (locate by exact deployed
  text, never retyped; LF-only per `.gitattributes:15`)
- The three inline mins at `…0330…:1473, :1715, :1790` folded onto the fleet resolver

### S8 — `0347_the_fight_records_what_it_froze.sql` — *consumer 6, the highest-risk slice, alone*
- `combat_units.resolved_stats_json` / `stat_resolver_version` / `stat_registry_version` (additive,
  nullable, no backfill)
- `combat_encounters.excluded_members_json`
- The concealment handler at `…0301…:804-806` replaced per §7.3
- Retirement of `resolve_fleet_movement_speed`, `fleet_speed`, `fleet_get_power`,
  `fleet_combat_stats`, `combat_fleet_return_speed` — each behind a zero-caller `prosrc` assert
  (comments stripped first)
- Own canary, own proof, own workflow; **never** bundled with anything else

**Total new surface:** 6 tables, 14 functions, 8 migrations, 5 proof scripts, 5 workflows.
**Retired:** 2 functions dropped outright (`calculate_group_expedition_stats`,
`calculate_expedition_stats`), 5 vestigial functions dropped, 1 column dropped
(`captain_instances.level`), 4 client vocabulary copies deleted, 1 client curve copy deleted.

---

## §11 — Explicit exclusions

This architecture will **not**:

1. **Cache a resolved stat.** No `effective_stats` table, no materialised view, no denormalised
   column. `combat_units.resolved_stats_json` is a frozen historical record of a fight that already
   happened, never read as a substitute for a live resolve.
2. **Touch combat damage arithmetic.** 0331's share-weight model
   (`weapons_json[i].power = combat_power × power_i / Σpower`, `…0331…:626-632`) and 0336's eight
   fixes are inputs to this design, not targets of it.
3. **Model weapon range, projectile speed, cooldown or ammo** as registry stats. They are per-weapon
   geometry in `weapons_json`, and §4.2 records why aggregating them has already caused a shipped
   defect.
4. **Annex the zone-effect tables.** `zone_effect_*` are static per-zone spawn/reward configuration,
   not entity stat modifiers, and they never touch the fold.
5. **Introduce ship, fleet or player XP.** One track, `captain_v1`. New tracks arrive with their
   content.
6. **Unify `cargo_capacity` (points) with `fleet_hold_capacity_m3` (m³).** Recorded in §4.3, listed
   as an owner decision (§14 D4), out of scope here.
7. **Change balance.** Every seeded value reproduces the deployed arithmetic. The two intentional
   changes (`scouting` sum→max, `retreat_safety` sum→min) affect only stats with no engine consumer,
   are listed in §14 D3, and are the only numbers this program moves without an explicit gate.
8. **Light any dark flag.** Every flag this program creates is seeded `false`. Flipping is a human
   act, as it is for every other flag in this repository.
9. **Fix the five inert knobs** (`station_affinity_bonus`, `shield_regen_combat_pct`,
   `shield_regen_idle_pct`, `captain_shard_drop_rate`, and the runtime-zero `repair_credits_per_hp`).
   They are balance decisions. The registry makes them *visible* — a stat with a zero-valued
   multiplier and a null `engine_consumer` is now a queryable fact instead of a discovery.
10. **Make `fleet_units` work.** It is vestigial; its functions are retired, not migrated.

---

## §12 — Dark landing and parity proof

Skeleton copied from the named exemplar, `20260618000260_encounter_runtime_resolver.sql`.

### 12.1 The skeleton, per migration

1. **Dependency gate** — `do $sdep$` … `to_regclass` for tables, `to_regprocedure` for functions, one
   `raise exception` per missing surface, message prefixed with the slice name (`…0260…:35-72`).
2. **Additive nullable columns, no backfill**, each with a `comment on column` stating that NULL is
   the legacy shape and that every existing row is NULL (`…0260…:74-83`).
3. **Dark table posture** — `enable row level security`; a read policy only; `grant select`;
   **`revoke insert, update, delete … from anon, authenticated`** explicitly (`…0260…:88-104`).
   Explicit revoke, not an assert of absence: the `20260618000254` grant-drift abort proved that
   Supabase's project-default `GRANT ALL` is present until removed.
4. **Flag seeded FALSE** with `on conflict do nothing` so a re-apply can never un-flip a live
   activation (`…0260…:107-112`).
5. **New functions revoked from client roles** —
   `revoke all on function … from public, anon, authenticated;` then
   `grant execute on function … to service_role;` (the newer explicit three-role form of
   `20260618000333…:316-319`, not 0260's short form).
6. **Self-assert block** — `do $sassert$`, structured exactly as `…0260…:1167-1287`.

### 12.2 The eight-part self-assert (each migration)

1. the flag is committed dark
2. schema shape: new columns exist and are nullable; **exact row counts** on every seeded catalog
3. byte-identity anchors: `strpos()` over the *live* `prosrc` of every function this slice claims not
   to have changed
4. the new surface is actually wired: the new function names occur in the caller's `prosrc`
5. determinism: exact **counts** of `random(`, `setseed`, `now(`, `clock_timestamp(` in the new
   bodies — the `…0260…:1246-1254` counting idiom, not a boolean absence test
6. blast radius: the out-of-scope engine bodies exist and carry **zero** tokens from this slice
7. **the live algebraic-equivalence check, executed at deploy** — §12.3
8. ACL: `has_function_privilege('authenticated'|'anon', …)` is false for every new function; client
   roles hold no write grant on any new table

### 12.3 How a vacuous assert is made impossible

The repo has three documented vacuity shapes. Each is closed by construction:

| shape | where it bit | how this contract closes it |
|---|---|---|
| **Missing-key passes** — `where key in (…) and value is distinct from 'true'` counts only rows that *exist*, so deleting all 44 keys still passes | `20260618000300_lights_on.sql:153-191` | Every existence assert states an **exact expected cardinality** derived from the seed in the same file: `if (select count(*) from stat_definitions) <> 9 then raise`. Absence fails. |
| **Early return on an empty chain** — `if v_n < 1 then raise notice …; return; end if;` before the comparison | `20260618000331_one_authority_for_attack.sql:770-779` | **The equivalence check does not read game data at all.** Because §1.1 splits the pure arithmetic into `stat_combine`, the assert calls it with a **hard-coded contribution set** and compares against the legacy expression spelled out inline in the same block. It runs identically on an empty disposable chain and on production. Data-dependent parity lives in the CI proof, which builds its own fixtures. |
| **Loop over an empty query never runs**, so its inner `raise exception` is unreachable | `20260618000333_items_have_a_place.sql:451-477` | Every proof loop is preceded by `select count(*) into v_n from <the same query>; if v_n <> <expected> then raise exception …`. A loop is never the assertion. |

The deploy-time equivalence assert, concretely:

```sql
-- (7) the pure fold is algebraically the deployed fold, proven on synthetic input.
--     Reads no game row; identical on an empty chain and on production.
v_out := public.stat_combine(
  $j$[ {"stat_id":"combat_power","source_kind":"hull",    "operation":"flat","amount":15},
       {"stat_id":"combat_power","source_kind":"module",  "operation":"flat","amount":4},
       {"stat_id":"combat_power","source_kind":"captain", "operation":"flat","amount":6},
       {"stat_id":"speed",       "source_kind":"module",
        "operation":"additive_pct","amount":0.1},
       {"stat_id":"speed",       "source_kind":"trait",
        "operation":"additive_pct","amount":0.08} ]$j$::jsonb,
  '{"speed":1.0,"cargo_capacity":50}'::jsonb,
  public.stat_registry_snapshot());

if (v_out->>'combat_power')::numeric
   is distinct from greatest(0, round((15 + 4 + 6)::numeric, 2)) then
  raise exception 'STAT-REGISTRY self-assert FAIL: combat_power is not the deployed additive fold';
end if;
if (v_out->>'speed')::numeric
   is distinct from round(greatest(0.2, 1.0 * (1 + 0.1 + 0.08) * (1 - 0)), 3) then
  raise exception 'STAT-REGISTRY self-assert FAIL: speed is not the deployed 0205:662 expression';
end if;
```

The right-hand sides are the deployed expressions transcribed from `…0205…:662` and `…0205…:677`.
If either changes, this assert fails at deploy.

### 12.4 The proof workflow

Each slice ships **both** jobs, matching the repo's better pattern (`team-command-proof`,
`danger-combat-proof`) rather than 0260's single-job shape:

- **`selftest`** — DB-free. Greps the proof script for every `PASS` marker, that it is
  self-rolling-back (`begin;` … `rollback;`), that it toggles every dark flag **only inside** the
  transaction, that it builds its **own** fixtures (no dependency on production data), and that every
  loop is preceded by a cardinality guard.
- **`disposable-matrix`** — `supabase start` applies the whole chain to real Postgres, executing every
  migration self-assert against live CHECK constraints, then runs the proof script and greps every
  marker.

**Stated plainly, because it changes what the proof is worth:** per `.github/workflows/build.yml:41-42`
and `scripts/check-migration-versions.mjs:13-15`, `build` is the only required check, so neither proof
job can block a merge. **The deploy-time self-assert is therefore the only gate that cannot be
bypassed**, and it is where the load-bearing checks belong. The CI proofs catch what a self-assert
cannot (multi-function behaviour over constructed fixtures); the self-asserts catch what CI cannot
(a red proof that was merged anyway).

`.gitattributes:15` pins `*.sql` to LF. Every slice-then-replace migration in S7/S8 must be authored
LF-only or its `old_t` will match zero occurrences and abort the deploy.

---

## §13 — Risks and rollback

| # | Risk | Likelihood | Mitigation | Rollback |
|---|---|---|---|---|
| 1 | A stat diverges between resolver and fold on a shape the fixtures do not cover | medium | Shadow phase records both and diffs on every real call before cutover; fixtures cover every source kind × both gate states × clamp boundaries | flip `stat_resolver_enabled` false — the old path is byte-intact until its cutover slice |
| 2 | **S8 destroys real ships**, as the Fleet-1 loss did | low, catastrophic | S8 is alone in its slice, last, with its own canary; the concealment handler is removed in the same slice so a defect is *loud*; canary uses an expendable stand-in, never a real fleet | flag false; the scalar snapshot columns still drive the tick until S8's own cutover |
| 3 | Grant drift: Supabase's default `GRANT ALL` on a new table | **high** — it has already aborted one deploy (`20260618000254`) | Explicit `revoke insert, update, delete` on every new table, plus a `has_table_privilege` assert | migration aborts and rolls back on its own assert; no partial state |
| 4 | CRLF bakes `\r` into an S7/S8 slice hunk → `guard text occurs 0 time(s)` | medium on this Windows checkout | `.gitattributes:15`; normalise on read in any generator | deploy aborts before any write |
| 5 | S7 misses one of ~15 `calculate_group_expedition_stats` call sites | medium | The drop itself is the guard: a missed caller fails at `drop function` with a dependency error, or at the zero-caller `prosrc` assert (comments stripped, `…0333…:1975-1977` idiom) | migration aborts |
| 6 | Retiring `resolve_fleet_movement_speed` changes live travel times | **certain, if chosen** | Owner-gated (§14 D2); its own before/after table of every live hull's speed | do not take D2 option A |
| 7 | Dropping `captain_instances.level` breaks an unseen reader | low | Zero-caller `prosrc` assert + `tsc -b` catches every TS reader; six client readers enumerated in §6.4 | migration aborts; `build` catches the client half |
| 8 | Registry growth reintroduces spaghetti (someone adds a stat in code instead of a row) | medium, over time | A deploy-time assert in every future migration: the resolver's emitted key set **equals** the registry's active set, cardinality-checked. Adding a stat in code fails the next migration that lands. | — |
| 9 | The resolver becomes a hot path (called per member per tick) | medium | It is `stable`, so Postgres may cache within a statement; the combat path calls it **once per ship per encounter**, not per tick — the snapshot exists precisely so it is not per tick | — |
| 10 | Prod is a live ~30-player game and a flag flip hits everyone | certain | Every flip is a separate human act on a separate slice; shadow phases precede all three engine cutovers | flag false |

**Global rollback property.** S1–S5 are purely additive and dark: rollback is a no-op because nothing
reads them. S6–S8 each retire something, so their rollback is a forward-only re-create from the
migration that owned the retired body — the standard posture in this repo. No step requires a
`DROP` before its replacement is proven.

---

## §14 — Owner decisions required

Four. Everything else in this document is determined engineering and does not need the owner.

---

**D1 — Captain level cap and post-cap behaviour.**

There is no cap today: `check (level >= 1)` is the only constraint (`…0177…:96`), `xp` is unbounded,
and the stat multiplier `1 + (level - 1) × captain_level_bonus_per_level` (`…0205…:603`) grows
without limit once `captain_growth_enabled` is lit. The curve must be registered with *some*
`max_level` and `post_cap_behaviour`, and neither is derivable from the code.

- **(A)** Cap at a named level *N*; past it, XP keeps accruing but the level and the stat multiplier
  stop. — **Recommended.** It bounds the multiplier, keeps the accrual cron unchanged, and leaves
  room to raise the cap later as content.
- **(B)** No cap. — The multiplier is unbounded; the first player to grind past the design range
  breaks combat balance permanently, and the fix afterwards is a nerf to a live account.

*Consequence of not deciding:* S3 cannot register the curve, which blocks S5 and S6. It does **not**
block S1, S2, S4 or S7 — those are unrelated foundation work and proceed.

---

**D2 — Does a fitted module make you travel faster?**

There are two live answers today. `resolve_fleet_movement_speed` (`20260618000051…:32-61`) returns
**raw hull `base_speed`** and never sees modules, captains, traits or buffs. The group mover reads
the **folded** min-speed from `calculate_group_expedition_stats` (`…0207…:299`). One fleet, two
speeds, depending on which command moved it.

- **(A)** One answer = the folded min. Thrusters, engineering captains and `tuned_thrusters` finally
  affect travel. — **Recommended.** It is what the catalogs already promise, and `speed_mult_bonus`
  exists in five catalogs for exactly this. Consequence: **live travel times change** on the legacy
  path the moment the cutover lands.
- **(B)** One answer = raw hull `base_speed`. Travel is a hull property and nothing else. Consequence:
  `speed_mult_bonus` becomes dead content in `module_types`, `captain_types`, `ship_trait_types` and
  `command_buff_types`, and the honest follow-up is to delete it from all four.

*Consequence of not deciding:* consumer step 5 stalls. Steps 1–4 and 6–7 proceed; the two speeds keep
disagreeing until it is answered.

---

**D3 — Two display numbers change.**

`scouting` becomes `max`-over-members instead of `sum`, and `retreat_safety` becomes `min` instead of
`sum` (§4.2). Both have **zero engine consumers** — nothing in the database decides anything with
them — so the change is confined to the team preview panel.

- **(A)** Take the corrected rules. — **Recommended.** Summed scouting means eight blind freighters
  out-scan a dedicated scout; summed evasion means adding a fat hauler makes a strike group harder to
  catch. Both invert the fitting decision the stats exist to create.
- **(B)** Keep `sum` for continuity and correct them when the stats get engine consumers. Consequence:
  the registry ships with two rules known to be wrong, and the first engine consumer inherits them.

*Consequence of not deciding:* S1's seed cannot be written. This is the only decision that blocks the
first migration, and it is a two-cell edit either way.

---

**D4 — Two cargo authorities, two units.**

`cargo_capacity` (unitless, from the fold, summed) and `fleet_hold_capacity_m3` / `fleet_hold_used_m3`
(cubic metres, `20260618000333_items_have_a_place.sql`) both answer "how much can this carry". Every
real cargo decision uses the m³ pair; the fold's number decides nothing.

- **(A)** Declare `cargo_capacity` display-only legacy (`engine_consumer = null`) and let m³ be the
  only engine cargo authority. — **Recommended.** It is already true; this makes it declared, and
  costs nothing now.
- **(B)** Unify them in this program — convert the fold's `cargo` contributions into m³ and retire the
  unitless number. Consequence: **live hold sizes change** for every ship, and it enlarges S1 into a
  cargo-balance slice.

*Consequence of not deciding:* (A) is the safe default and the program proceeds under it; a third
cargo authority appears the next time someone needs one.

---

## Appendix — evidence index

Every claim above traces to one of these. All paths are relative to `C:\Users\디폴리스\byeharu`.

| Subject | Location |
|---|---|
| The fold, current full head | `supabase/migrations/20260618000205_cmdbuff_command_buffs.sql:315-693` |
| The fold, 9 in-place slices | `supabase/migrations/20260618000331_one_authority_for_attack.sql:305-519` |
| The fold's 10 prior definitions | 0044:22 · 0115:58 · 0122:68 · 0170:44 · 0180:70 · 0193:221 · 0196:100 · 0198:50 · 0205:315 · 0331 (slices) |
| Fold output object | `…0205…:666-685` (as edited by `…0331…` hunks 2–3) |
| Final speed expression | `…0205…:662` |
| Fleet fold (the predecessor authority) | `supabase/migrations/20260618000166_slice_d0_group_stats_authority.sql:58-151` |
| Fleet-speed min, three inline copies | `supabase/migrations/20260618000330_the_mover_is_in_the_repo.sql:1473, :1715, :1790` |
| Raw-hull speed resolver | `supabase/migrations/20260618000051_resolve_fleet_movement_speed.sql:32-61` |
| Combat fleet move speed (min) | `supabase/migrations/20260618000337_reposition_is_a_move.sql:133-146` |
| Weapon share-weight formula | `supabase/migrations/20260618000331_one_authority_for_attack.sql:626-635`; column redefined `:679-686` |
| Player snapshot insert | `supabase/migrations/20260618000301_intercept_fires_at_zone_entry.sql:839-853` |
| The concealment handler | `supabase/migrations/20260618000301_intercept_fires_at_zone_entry.sql:804-806` |
| Live re-read (auto-exit) | `supabase/migrations/20260618000310_hp_auto_exit.sql:427-449`, rationale `:425-426` |
| `hp_max` frozen since 0331 | `supabase/migrations/20260618000331_one_authority_for_attack.sql:531-560` |
| Command-buff catalog + column + roll + fold | `supabase/migrations/20260618000205_cmdbuff_command_buffs.sql:89-98, :190-191, :256-258, :465-483` |
| Command-ship flag index (not unique) | `supabase/migrations/20260618000204_fleetctrl_command_ship.sql:75-76, :117-119` |
| XP curve, server | `supabase/migrations/20260618000177_captain_xp_foundation.sql:94-96, :268-270` |
| XP curve, client duplicate | `src/features/captains/captainProgress.ts:18, :23, :29` |
| Client vocabulary copies | `src/features/command/teamSkillset.ts:38-66` · `src/features/ship/shipTraits.ts:57` · `src/features/port/portShop.ts:44-52` · `src/features/ship/shipDossierView.ts:70-100` |
| Trait/buff catalog key allowlists | `supabase/migrations/20260618000186_soul0_traits_foundation.sql:346` · `…0205…:742` |
| Ship→port, the two disagreeing authorities | `supabase/migrations/20260618000335_one_way_to_repair.sql:44-57` |
| `fleet_docked_location` + 4 remaining inline copies | `supabase/migrations/20260618000306_empty_fleet_dock_authority.sql:63-75`; copies at `…0210…:178, :299` · `…0231…:1069, :1486` |
| The one-authority + slice-N-copies idiom | `supabase/migrations/20260618000305_one_sortie_authority.sql:104-155` |
| The dark-landing exemplar (E3) | `supabase/migrations/20260618000260_encounter_runtime_resolver.sql:35-143, :1167-1287` |
| Vacuous asserts | `…0300…:153-191` · `…0331…:770-779` · `…0333…:451-477` |
| Non-vacuity idiom (strip comments first) | `supabase/migrations/20260618000333_items_have_a_place.sql:1975-1977` |
| `build` is the only required check | `.github/workflows/build.yml:41-42` · `scripts/check-migration-versions.mjs:13-15` |
| LF pin | `.gitattributes:15` |
| Sole-writer matrix | `docs/SYSTEM_BOUNDARIES.md:21-81` |
| Allowed call-edges + per-row isolation | `docs/SYSTEM_BOUNDARIES.md:288-382` |
