# World Editor — Roadmap Closure (2026-07-22/23)

**Verdict: `WORLD EDITOR ROADMAP — COMPLETE, LIFECYCLE-PARITY PROVEN, PRODUCTION-LIVE, CLOSURE-VERIFIED`** (read-only smoke + CI apply-proofs).

This is a documentation-only closure record. It records the authoritative production state at
completion. It introduces no implementation, migration, workflow, feature-flag, test, or gameplay
change.

## Production state

**Production migration head: `0271`.** Migrations `0263`–`0271` are all deployed to production, each
with a disposable `supabase start` apply-proof on real Postgres:

| Migration | Change |
|---|---|
| `0263` | `get_world_map` read-cutover to `space_anchors` (byte-identical map). |
| `0264` | Location anchor write-authority: `location_create`/`update` write anchors; `get_world_map` fail-closed on the active anchor; byte-identical. |
| `0265` | One canonical `canonical_coord_violation` validation authority used by all 6 point-coordinate-write RPCs. |
| `0266` | `zone_update` — zones reach create/update/unpublish parity. |
| `0267` | Unified server-side `world_editor_revert(request_id, audit_id)`: reverts any audited edit across all domains (incl. server-only `reward_bundle` + zone WKT geometry + the location anchor path); owner-gated intentional overwrite; writes a new domain-update audit row. |
| `0268` | `zone_set_active` (reactivate-only) — zones reach full lifecycle parity: create / update / unpublish / reactivate. |
| `0269` | `world_editor_entity_catalog`: owner-only lifecycle index; active + inactive across all 4 domains; gameplay readers untouched / byte-identical. |
| `0270` | `world_editor_entity_detail`: owner-only inactive-detail reader for zone + location; returns the opaque `reactivation_expected` each RPC needs; rejects active entities + mining/exploration. |
| `0271` | Catalog marker-style enrichment: adds `location_type` / `activity_type` / `reward_tier` / `base_difficulty` to catalog rows, locations only; everything else byte-identical. |

## Frontend (client-only, Pages-deployed)

- Unified one-click revert UI: History "Revert to this version" → `world_editor_revert` for all 4
  domains, single path.
- V5 usability: entity search + camera jump; coordinate go-to; global active/inactive/all lifecycle
  filter; global unpublished-drafts indicator.
- Inactive-entity selection + reactivation (zone/location via `detail.reactivation_expected` passed
  verbatim; mining/exploration straight from the catalog).
- Location marker-style preservation via the existing `markerStyle` from the enriched catalog fields.
- Mandatory unsaved-draft navigation guard (Keep editing / Discard-and-continue on every context
  switch; explicit "Reload live version" on optimistic-concurrency conflict).

## Verification

- Every mutation path (create / update / unpublish / reactivate / revert, concurrency, audit,
  reactivation contracts) is proven end-to-end by the disposable PostgreSQL CI apply-proofs through
  migration `0271`. Gameplay readers (`get_world_map` / `get_active_mining_fields` /
  `get_danger_zones` / `get_my_exploration_discoveries`) are asserted byte-identical.
- Production **CLOSURE SMOKE** was intentionally limited to **READ-ONLY** operations (per the
  architecture review, to avoid mutating the live world). In the owner's `/dev/world` session:
  editor loads owner-gated; catalog loaded all 4 domains (Locations 8, Mining 5, Exploration 5,
  Zones 3); search returns the correct entity (e.g. "hav" → Haven); the active / inactive / all
  lifecycle filter switches without error; History panel present; coordinate go-to present; the
  unpublished-drafts indicator is live; the SVG map renders; **no production write RPC was invoked**.
  Inactive-entity selection was not exercised live because no entity is currently inactive; that path
  is covered by the CI apply-proofs.

## Explicitly deferred (out of scope, not done)

- Physical ×17 coordinate rescaling.
- Complete multi-domain physical-frame unification.
- Combat resolver reactivation.
- New gameplay systems.

## Final state

**WORLD EDITOR ROADMAP — COMPLETE, LIFECYCLE-PARITY PROVEN, PRODUCTION-LIVE, CLOSURE-VERIFIED**
(read-only smoke + CI apply-proofs).
