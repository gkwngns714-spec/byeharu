# Zone combat-effect authoring — design record

**Date:** 2026-07-26
**Owner's question:** *"where can i set rewards, pirate types for the zone?"*
**Status:** DESIGN ONLY — nothing built. Read §4 before acting on §3.

---

## 1. The answer to the question as asked

You cannot, yet — and the effect your zone already carries was never going to answer it.

| Effect table | Carries | Rewards? | Enemy types? |
|---|---|---|---|
| `zone_effect_pirate_intercept` (0273) | 5 risk knobs (`base_risk`, `min_risk`, `max_risk`, `exposure_floor`, `stat_reference`) | No | No |
| `zone_effect_combat` (0278) | `encounter_profile_id` + `spawn_chance` / `max_concurrent` / `cooldown_seconds` | **Yes**, via the profile | **Yes**, via the profile |

`zone_effect_combat` does **not** store rewards or enemy types directly. It *selects* an
`encounter_profile`, which remains the authority for fleet composition and rewards. The intended
owner-facing sentence is:

> Select a live zone → Combat effect → choose an encounter profile.
> Enemy types and rewards stay defined in the Combat catalog, never duplicated onto the zone.

Today the only authoring path is the Combat panel: reward profiles → enemy archetypes → fleet
templates → encounter profiles → `location_encounter_bindings`, which binds an encounter to a
**location**, not to a zone's area.

## 2. The model

| Layer | Question | Where |
|---|---|---|
| Geometry | *Where* can it happen? | `danger_zones.boundary` |
| Identity | *What* is this zone? | `danger_zones.zone_kind` |
| Effects | *What does it do?* | `zone_effect_*` tables |

Effects are **composable** — a zone carries a SET, and presence *is* the config row existing.
Identity does not imply effect.

## 3. ChatGPT's recommendation (2026-07-26)

Recorded as given. **§4 documents where it is wrong.**

- **Commands.** Two per-kind commands, `zone_effect_combat_set` / `zone_effect_combat_remove`.
  Explicitly *not* a generic `zone_effect_upsert(kind, config jsonb)` — "a generic discriminator
  command would become a server-side switch over unrelated payloads."
- **Concurrency.** `danger_zones.revision` is the only token. Lock the parent zone, compare
  `expected_revision`, bump exactly once **when state changed**; a semantic no-op returns
  `changed=false` with no bump. No child-row revision.
- **Removal.** A real `DELETE`. The no-hard-delete rule protects first-class world entities; an
  effect row is *set membership*, and an `active=false` column would create two competing meanings
  of presence. Still owner-gated, revision-gated, audited with a full before-image.
- **Read.** Do **not** add effect config to `get_danger_zones()` — it is granted to `anon` and is the
  player read; effect config is owner-only. Extend `world_editor_entity_detail` (0270) instead,
  returning revision + the effect set from one snapshot. Do not duplicate fleet/archetype/reward
  definitions into zone detail.
- **UI.** On the **live zone inspector**, not `ZoneDraftPanel`. Geometry drafts exist because shape
  editing is spatial, previewed and published later; effect config is a discrete mutation of an
  already-live zone. Putting it in the draft would expand the fingerprint, couple geometry to combat
  config, and force effect-only changes to create geometry drafts. New file
  `ZoneCombatEffectEditor.tsx`. Show "Configured — runtime disabled" honestly while the flags are off.
- **Location-binding overlap.** Legal, not a design error. Spatial overlap alone does not prove
  conflict — a location binding responds to arrival/action, a zone combat effect to traversal/presence.
  If both ever subscribe to the same event they must feed ONE server-side encounter-planning
  authority. Never implement precedence in React, never warn from a client approximation.
- **Sequencing.** Migration `0288` first, dark, using the existing `typed_zone_authoring_enabled`
  (no new flag); verify commands reject while dark; then the client; owner flips only the authoring
  flag. `typed_zone_combat_runtime_enabled` and `encounter_resolver_enabled` stay **false** until a
  separate runtime-arbitration slice exists.

## 4. Where the recommendation is built on a false premise — MINE

**I gave ChatGPT a wrong fact and it reasoned correctly from it.** I told it "the command union has 30
commands and not one `zone_effect_*` among them." That is true of the *client* contract
(`commandContract.ts`) and false of the *database*.

**`zone_effect_set` and `zone_effect_remove` already exist** — migration **0277**
(`20260618000277_typed_zone_effect_authoring.sql:65` and `:285`), granted to `authenticated`,
`anon` revoked, gated on `typed_zone_authoring_enabled`, and they **already bump
`danger_zones.revision`**.

`zone_effect_set` is already the **generic, discriminated** shape ChatGPT said not to build:

```
payload = {
  target_id:   <zone uuid>,
  effect_type: 'pirate_intercept',
  expected:    { name, source, location_id },
  overrides:   { base_risk, min_risk, max_risk, exposure_floor, stat_reference }
}
```

So building `zone_effect_combat_set` / `_remove` as siblings would create a **second authority beside
an existing one** — precisely the spaghetti the core rule forbids, and precisely what ChatGPT was
trying to avoid. It had no way to know: I never attached 0277.

Two further corrections ChatGPT offered are **wrong**, both traceable to my incomplete attachment:

| Its claim | Reality |
|---|---|
| `zoneEffectPanelModel.ts` carries "a stale claim that effect commands already exist" | The comment is **accurate** — 0277 created them |
| `ZONE_EFFECT_KINDS` lists mining/exploration tables "not shown in the complete source" | All four tables exist: `pirate_intercept` (0273), `combat` (0278), `mining`, `exploration`. The registry really is 1:1 |

Its warning "do not merge PR #317 unchanged" rests on those two claims and should be re-evaluated,
not taken at face value.

## 5. What is actually true, and the real shape of the work

- The generic command pair exists and handles **`pirate_intercept` only**. The gap is that
  `effect_type` does not yet accept `'combat'`.
- **0277 predates 0287** and still uses the old `expected: {name, source, location_id}` snapshot
  compare. `zone_update` moved to `expected_revision` in 0287. The two write paths now disagree about
  what optimistic concurrency means for the same aggregate — a real inconsistency, independent of
  this feature.
- The client has **no binding** to either command, and `zoneEffectPanelModel.ts` is mounted nowhere.

The likely correct work is therefore **extend, not add**: teach `zone_effect_set` /
`zone_effect_remove` the `'combat'` effect type, and migrate their concurrency to `expected_revision`
so all zone writes share one token. That keeps one authority and closes the 0277/0287 split at the
same time.

**This has not been re-put to ChatGPT with 0277 attached.** Everything in §3 should be treated as
provisional until it is.

## 6. Runtime stays dark regardless

`zone_effect_combat` needs **both** `typed_zone_combat_runtime_enabled` **and**
`encounter_resolver_enabled`. Authoring a combat effect changes no player-visible behaviour until a
separate slice defines same-event arbitration between zone effects and location bindings.
