# Typed-Zone Platform — architecture review (2026-07-25)

**Status: SLICE 1 AUTHORED, NOT DEPLOYED.** Migration `0273` exists on the branch
`slice-typed-zone-foundation`; production head is still `0272`. Slices 2–9 are unwritten.
Deploying and flipping remain the owner's alone. See **§9** for what slice 1 actually is.

This file records an external architecture review (ChatGPT, byeharu project, chat
"Defect Fix Recommendation") of the owner's proposed typed-zone direction, plus the
review of the earlier — now abandoned — `0273` seeded-zone-unlock plan.

Attribution is explicit throughout: **[REVIEW]** = the reviewer's position,
**[OWNER]** = the owner's stated intent, **[VERIFIED]** = confirmed against this repo.

---

## 1. The owner's direction

**[OWNER]** The zone becomes a first-class feature and the one spatial primitive.
Draw a region → declare its kind → set that kind's values → attach it to the map.
Kind drives behaviour: combat → spawn NPCs; exploration → grant rewards; mining →
yield ore; pirate → today's interception, now one kind among several.

**[OWNER]** Exploration and mining zones may *also* spawn things later — "that is for
the future", but the model must not preclude it.

**[OWNER]** The motivating complaint: *"changing the zone shape should not affect
gameplay."*

**[REVIEW]** Restated as three independent concerns:

| Concern | Answers |
|---|---|
| Zone geometry | **WHERE** can something happen? |
| Zone kind | **WHAT** category of behaviour applies? |
| Kind config | **HOW** does that behaviour operate? |

Runtime systems must stop inferring behaviour from the mere existence of a polygon.
They should: find applicable active zones → dispatch by kind → read that kind's config
→ execute per its own rules. The three existing pirate polygons become ordinary rows
of kind `pirate`, preserving today's behaviour.

### The correction to the owner's phrasing

**[REVIEW]** *"Changing a zone shape should not affect gameplay" cannot be literally
true.* Changing a boundary necessarily changes which fleet paths intersect, which
positions are inside, when an effect becomes eligible, and how many players are
exposed.

The coherent version:

> **Changing the boundary must not silently change the zone's behavioural
> definition.** Resizing a mining zone must not change its ore reward table — but it
> does change *where* that reward is available.
>
> **Shape controls eligibility; kind and config control the resulting effect.**
> Both remain gameplay-bearing.

**[REVIEW]** This wording should be fixed in the spec, or implementation and owner
expectation will diverge.

### Ambiguities the reviewer refused to fill in silently

- Is `pirate` a peer of `combat`, or a subtype? `combat` is broad; `pirate` names a
  specific interception mechanism. A flat enum containing both mixes abstraction levels.
- What *activates* mining/exploration zones? Automatic on entry, explicit player action
  while inside, periodic while present, destination selection, one-time discovery, or
  boundary crossing — these are materially different systems.
- Does a zone have exactly one behaviour? The stated model implies one kind per zone.
  **This must be explicit**, or a later "pirate combat zone that also contains mining"
  forces a different many-effect architecture.
  *(Owner has since indicated multi-behaviour is wanted eventually — see §6.)*
- What is `location_id` for in the future: label/map association, or geometry ownership?

---

## 2. Data model — the reviewer's recommendation

**[REVIEW]** Use **one authoritative core zone table + one relational config table per
kind**. Do **not** use a single unconstrained JSONB column as the sole authority.

```
world_zones                 zone_pirate_config
-----------                 ------------------
id                          zone_id PK → world_zones(id)
name                        intercept_profile_id
zone_kind                   cooldown_seconds
boundary                    exposure settings
status
location_id (nullable)      zone_combat_config
revision                    ------------------
created_at                  zone_id PK → world_zones(id)
updated_at                  encounter_binding_id
                            spawn limits / difficulty

                            zone_mining_config / zone_exploration_config
                            ---------------------------------------------
                            zone_id PK → world_zones(id)
                            reward_bundle_json or profile_id, yield/discovery settings
```

**Why not one JSONB blob:** convenient for the editor, but it weakens integrity for
gameplay-bearing data. The DB cannot enforce required-fields-by-kind, foreign keys to
encounter profiles, valid profile references, numeric limits, mutual exclusion of
incompatible fields, schema evolution, safe querying, precise audit diffs, or
server-side guarantees independent of the client.

JSONB remains reasonable *inside* a specific side table where the payload genuinely
behaves as a validated document.

**[REVIEW]** Do **not** rename `danger_zones` in the first slice — RPCs, verifiers and
consumers have migrated to it; renaming early creates unnecessary deployment risk.

### Editor-domain mapping

**[REVIEW]** The final data authority should **not** mirror today's four editor domains
one-to-one.

- Final authority: **Locations** + **Typed zones**.
- Mining / Exploration / Combat / Pirate may remain visible as *editor filters or
  shortcuts* — filtered projections of ONE underlying `zoneDraft` and ONE zone-authoring
  decision module.
- **Never** allow both a Mining domain and a Zones domain to edit the same `world_zones`
  row — that violates ONE AUTHORITY immediately.

---

## 3. Mining fields and exploration sites

**[REVIEW]** Do **not** auto-convert points into degenerate zones. A zero-area polygon
is invalid or useless; an invented tiny radius introduces new gameplay semantics —
invented radius, new containment behaviour, new overlap behaviour, edge-inclusion
questions, changed interaction distance.

> Points should not be reinterpreted as zones until the intended zone footprint is
> defined. **Do not invent the radius.**

**Least-destructive path — staged successor model:**

1. Current point row remains authoritative.
2. A corresponding typed-zone candidate is created **dark**.
3. Runtime continues using the point.
4. The candidate is inspected and compared.
5. Authority switches only after explicit proof.

Each successor zone needs an explicit boundary: manually authored, generated from an
existing interaction radius if one exists, generated from a newly approved default, or
imported from documented world-design data.

---

## 4. Ordered decomposition (9 slices)

**[REVIEW]** The first slice establishes the foundation with **no new live behaviour.**

| # | Slice | Substance |
|---|---|---|
| 1 | **Typed-zone schema foundation, fully dark** | Additive, deploy-inert. Kind-specific config tables; pirate config rows for the 3 existing zones; pure config types + validators; DB assertions linking `zone_kind='pirate'` to pirate config; authoring + runtime flags all seeded false. |
| 2 | **Pure effect-dispatch authority** | One pure module: event + candidate zones → applicable effects → deterministic resolution **plan**. Knows nothing of React, PostGIS IO, or RPC. Returns a plan; does not execute combat or grant rewards. Only pirate needs a real implementation initially. |
| 3 | **Pirate shadow comparison** | Read-only shadow path comparing current resolver vs new dispatcher. No duplicate encounters, no writes. Compare candidate zone IDs, intersection result, exposure, selected ambush zone, cooldown/eligibility, encounter input. Proves the general model reproduces pirate behaviour exactly. |
| 4 | **Pirate runtime cutover** | Behind `typed_zone_pirate_runtime_enabled`. False → current logic authoritative; true → dispatcher authoritative. **Never run both for side effects.** |
| 5 | **Typed-zone editor core** | Geometry editor, kind selector, kind-specific config projection, pure validation, unified zone draft authority. Separate intents — `update-zone-geometry`, `update-zone-behavior`, `change-zone-kind`, `change-zone-lifecycle` — not one giant payload. |
| 6 | **First new non-live kind — combat** | Encounter content already exists, resolver already gated, no live point authority to migrate, can stay fully dark. Requires **both** `typed_zone_combat_runtime_enabled` AND `encounter_resolver_enabled`, with the AND in ONE pure capability module. Enabling typed combat zones must not implicitly enable the resolver. |
| 7 | **Mining shadow migration** | Dark successor zones for existing mining fields. Prove reward-payload equivalence, action-eligibility equivalence, no double grants, deterministic choice on overlap, exact idempotency. Then switch mining authority independently. |
| 8 | **Exploration shadow migration** | Repeat independently. Exploration may have different semantics and must **not** share a rollout gate with mining merely because both use point tables today. |
| 9 | **Legacy retirement** | Only after all consumers move: freeze point-table writes, compatibility projections, remove dead RPCs, optionally rename the core table, drop obsolete constraints/adapters, eventually drop legacy tables. |

**Slice 1 must NOT:** add non-pirate active zones; change the interception query; change
the editor write path; broaden production behaviour; rename `danger_zones`; migrate
points; activate the encounter resolver.

**Slice 1 migration self-assert must prove:** the three live boundaries are
byte-identical; statuses unchanged; revisions unchanged; pirate interception functions
unchanged; all new flags false; every pirate zone has exactly one valid pirate config;
no non-pirate runtime row exists.

---

## 5. The ten traps

1. **Kind alone does not define *when* behaviour runs.** A fleet crossing a mining zone
   must not receive ore merely because its route intersects the polygon. Kind selects
   the behaviour *family*; an **event** determines whether it is evaluated.
2. **Pirate and combat may be the wrong taxonomy** (abstraction-level mismatch).
3. **Overlapping zones need explicit semantics.**
4. **Boundary predicates are not interchangeable.** `ST_Contains` excludes the boundary;
   `ST_Covers` includes it — for gameplay `ST_Covers` is often less surprising.
   `ST_Intersects` lumps together true crossings, touching, starting on the edge,
   travelling wholly inside, and overlapping an edge — these may not deserve the same
   behaviour. Explicit rules needed for: start-outside/end-inside, start-inside/end-outside,
   both-ends-inside, touch-only, travel-along-boundary, repeated movement inside.
   **Preserve existing pirate behaviour exactly during parity migration before improving
   semantics.**
5. **Multiple effects and duplicate side effects.** Every gameplay-producing effect needs
   an idempotency identity: `event ID + zone ID + behaviour version`.
6. **Location `territory_radius` circles are a separate concern.**
7. **The core row must not become a god object.** No `ore_type`, `enemy_profile`,
   `pirate_probability`… as nullable columns → sparse rows, invalid mixed configs,
   ever-growing checks, editor coupling, painful migrations. Keep the core table
   spatial + behavioural-identity only.
8. **Geometry and behaviour need separate commands.** Prefer `zone_update_geometry`,
   `zone_update_pirate_config`, `zone_change_kind`, `zone_set_status` over one overloaded
   `zone_update(payload jsonb)`. Gives the audit log accurate event types.
9. **Kind conversion is not an ordinary field edit** — needs explicit conversion rules.
   A pirate zone must not become a mining zone while retaining stale pirate config.
10. **Migrating points can double rewards.**

---

## 6. SETTLED — identity + composable effects

**[OWNER, 2026-07-25]** Exploration and mining zones may also spawn things in future.
**Decision: identity + composable effects.** This resolves reviewer ambiguity #3
(*"does a zone have exactly one behaviour?"*) — **no**.

- **kind** = what the zone *is* — identity, rendering, which authoring form you get;
- **effects** = what it *does* — a **composable set**, not a switch on kind.

So "a mining zone that also spawns" is ONE zone with TWO effects — never a new kind and
never a special case. **Presence of an effect is the existence of its config row**, never
a NULL-riddled sentinel column on the core row (trap 7).

**Implemented in slice 1** — see §9.

---

## 9. Slice 1 as actually built — `0273` typed-zone effect foundation

Authored on branch `slice-typed-zone-foundation`. **Additive and fully dark; deploying is
the owner's call.**

| File | Role |
|---|---|
| `supabase/migrations/20260618000273_typed_zone_effect_foundation.sql` | `zone_effect_pirate` side table, behaviour-neutral backfill, two flags seeded false, self-assert |
| `src/features/worldeditor/zoneEffects.ts` | pure effect registry, config types, knob resolution, risk curve, advisory validator |
| `tests/zoneEffects.spec.ts` | 16 tests — parity, validation, structural |
| `scripts/typed-zone-foundation-proof.sql` | self-rolling-back disposable-Postgres proof |
| `.github/workflows/typed-zone-foundation-proof.yml` | runs the proof on a throwaway stack |

**How composability is expressed.** `zone_effect_pirate` is keyed
`zone_id uuid primary key references danger_zones(id) on delete cascade`. An effect is
*present* iff its row exists. A future effect is a **sibling table** — adding one edits no
existing table, and a zone may hold rows in several at once. The core row never grows
effect columns.

**How parity is guaranteed.** Each of the five pirate risk knobs is an OPTIONAL per-zone
override of the identically-named global; `NULL` means inherit. The backfill wrote
**all-NULL** rows, so the data is behaviour-neutral *by construction* — not by a promise
about future code. The disposable proof computes this rather than asserting it: it
resolves the knobs and reproduces `pirate_intercept_compute_risk` bit-for-bit over an
input sweep, then shows a real override still moves nothing live.

**Deliberately deferred** (each needs its own slice): the immutable `provenance` column
(Appendix A), widening the `zone_kind` CHECK, the effect dispatcher (slice 2), any editor
surface (slice 5), and every point-entity migration (slices 7–8).

**Not verified locally.** There is no psql/docker on this machine, so `0273` and its proof
have **not been executed** — they are validated by CI on a disposable stack via the
workflow above. Everything else (typecheck, 246 tests, lint) ran clean locally.

---

## 7. The reviewer's argument AGAINST the whole direction

> Mining fields, exploration sites and danger polygons may not be the same domain
> abstraction. Mining and exploration points are discrete landmarks or action nodes,
> while pirate areas are continuous exposure surfaces. Forcing every spatial mechanic
> into polygons can introduce arbitrary radii, complex overlap policy, more expensive
> queries, and an increasingly central dispatcher that becomes a new god module. A more
> conservative architecture would retain distinct point and polygon entities behind a
> shared `SpatialEffect` interface rather than forcing them into one table — preserving
> each mechanic's natural geometry while still separating WHERE from WHAT.
>
> **The owner's approach is justified only if area membership is genuinely intended to
> become part of mining and exploration gameplay, rather than merely a desire for
> schema uniformity.**

---

## 8. Conclusion

**[REVIEW]** The direction is architecturally viable, with four qualifications:

1. One core zone geometry/lifecycle table **plus kind-specific relational config tables**.
2. Do **not** treat JSONB as the sole gameplay schema authority.
3. Migrate live point systems by **dark coexistence and per-kind authority cutovers**,
   not by inventing degenerate polygons.
4. **Define event and overlap semantics before adding non-pirate kinds.**

> The safest first slice is an additive, dark typed-zone foundation that backfills pirate
> configuration while leaving every current boundary, runtime query, reward path and live
> player outcome unchanged.

---

## Appendix — carry-over findings from the abandoned `0273` plan

The earlier plan (unlock the three seeded zones via adopt-on-edit `source` flip) was
**reviewed and rejected**. Two findings survive and apply to any future zone work:

**A. `source` is doing two jobs.** **[VERIFIED]** in this repo:
- geometry representation — generated `circle` vs hand-drawn `drawn`;
- protection provenance — seeded/system vs owner-authored (the RPC guards read `source`).

**[REVIEW]** Flipping `source` to `'drawn'` on first edit makes the row indistinguishable
from an ordinary owner zone, so turning the capability flag **back off would not
re-protect it**. The flag would be a one-way adoption gate, not a reversible capability
gate. Fix: add an **immutable `provenance`** column (`'seeded' | 'owner'`), keep `source`
as geometry-only, gate all protection on `provenance`. Backfill by **stable seeded IDs**,
never by display name (names are mutable authoring data).

**B. Duplicate-zone / double-counting risk.** **[REVIEW]** If any repair or
synchronisation logic guarantees "every pirate-hunt location has a `source='circle'`
zone", then after an adoption it sees no circle for that location and **creates a new
one** → two overlapping active zones → potentially doubled encounter probability,
duplicate intercept records, or double-counted exposure.

**[REVIEW]** Required proof, not inference — search the repo *and* live DB
(`pg_proc` definitions, `information_schema.triggers`, `pg_views`) for every reader of
`source`, every writer of `danger_zones.boundary`, and everything reacting to
`locations.territory_radius`. Check current uniqueness:

```sql
select location_id, count(*) as zone_count,
       count(*) filter (where status = 'active') as active_count
from danger_zones
where location_id is not null
group by location_id
having count(*) > 1 or count(*) filter (where status = 'active') > 1;
```

**C. Error precedence.** **[VERIFIED]** In `zone_update` (`0266`) the optimistic-concurrency
compare (step 6) returns `stale_revision` and exits **before** the seeded check (step 6b)
runs — so editing a seeded zone reports *"the live row changed since this draft was
forked"* instead of *"this is a seeded zone"*. **[REVIEW]** Eligibility should precede the
revision compare, but **after** idempotent-replay resolution and row lock, or a retried
request could return a different result instead of the recorded original success.
