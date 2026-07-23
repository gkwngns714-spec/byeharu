// WORLD EDITOR — V5: PURE entity SEARCH + camera-jump navigation. Data in → ranked matches / a
// navigation (selection + Camera) out. This module is pure NAVIGATION: it NEVER mutates its inputs,
// NEVER writes a coordinate, and issues no IO — it only READS the adapter-resolved LayerItems the
// shell already holds (the SAME `itemsByLayer` map worldEditorFocus consumes) and REUSES the two
// existing authorities end-to-end:
//   • the entity's canonical world points come from worldEditorGeometry.representationWorldPoints,
//   • the camera-jump comes from galaxyCamera.fitCameraToWorldPoints (the SAME fit the per-domain
//     Focus buttons and the History overlay frame through).
// So there is NO new search index, NO second selection model, and NO new camera engine here. No
// React, no DOM, no fetch: unit-tested directly (tests/worldEditorSearch.spec.ts).
//
// Every searchable domain contributes because its adapter already resolves a LayerItem carrying the
// entity NAME (LayerItem.label) + its selection id + its world representation — locations, mining
// fields, exploration sites, and zones all flow through the ONE registry, so search stays domain-
// agnostic. (Exploration rows are typically empty under the server-only RLS; when the editor has no
// exploration rows client-side that domain simply yields no matches — an honest absence, never an
// invented read.)
import { fitCameraToWorldPoints, type Camera } from '../map/galaxyCamera'
import { representationWorldPoints } from './worldEditorGeometry'
import { itemPassesStatus, type WorldEntityStatusFilter } from './worldEditorFilters'
import type { LayerId, LayerItem, WorldPoint } from './worldEditorTypes'

/** One ranked search hit. `worldPoints` are the entity's CANONICAL world coordinates (a point's own
 *  coord, or a zone polygon's whole ring) — the exact input the shared camera fit frames, so a click
 *  jumps the camera through the ONE authority with no per-domain special-casing. `status` is the
 *  entity's lifecycle (from the 0269 catalog) so the results list can badge an INACTIVE hit and a jump
 *  works identically for inactive entities. */
export interface EntityMatch {
  readonly domain: LayerId
  readonly id: string
  readonly name: string
  readonly worldPoints: readonly WorldPoint[]
  readonly status?: string
}

/** Rank buckets: an exact (case-insensitive) name wins, then a prefix match, then any substring.
 *  Lower sorts first. */
function matchRank(nameLower: string, queryLower: string): number | null {
  if (nameLower === queryLower) return 0
  if (nameLower.startsWith(queryLower)) return 1
  if (nameLower.includes(queryLower)) return 2
  return null
}

/** Search every adapter/catalog-resolved entity by NAME (case-insensitive substring), ranked exact →
 *  prefix → substring, then A→Z, then stable in registry/domain order. Pure: reads only the passed
 *  items map. Results OBEY the shared lifecycle filter (`status`, default 'all') — the SAME
 *  itemPassesStatus predicate the map uses — so search never surfaces an entity the filter hides.
 *
 *  EMPTY-QUERY RULE (chosen): a blank/whitespace query yields NO matches — the results dropdown stays
 *  closed until the owner types, rather than dumping the whole world into a list. */
export function searchEntities(
  itemsByLayer: ReadonlyMap<LayerId, readonly LayerItem[]>,
  query: string,
  status: WorldEntityStatusFilter = 'all',
): EntityMatch[] {
  const q = query.trim().toLowerCase()
  if (q === '') return []
  const ranked: { match: EntityMatch; rank: number; nameLower: string }[] = []
  for (const [domain, items] of itemsByLayer) {
    for (const it of items) {
      if (!itemPassesStatus(it, status)) continue
      const nameLower = it.label.toLowerCase()
      const rank = matchRank(nameLower, q)
      if (rank === null) continue
      ranked.push({
        rank,
        nameLower,
        match: {
          domain,
          id: it.id,
          name: it.label,
          worldPoints: representationWorldPoints(it.representation),
          status: it.status,
        },
      })
    }
  }
  // Stable sort keeps registry/domain order for ties (Map iterates locations→mining→exploration→zones).
  ranked.sort((a, b) => a.rank - b.rank || a.nameLower.localeCompare(b.nameLower))
  return ranked.map((r) => r.match)
}

/** The navigation a result click performs, as PURE data — REUSING both existing authorities:
 *   • `selection` drives the shell's existing `selected` model (identical {layer,id} shape),
 *   • `camera` is galaxyCamera.fitCameraToWorldPoints over the entity's own world points (the SAME
 *     camera-set path a Focus button / the History overlay uses).
 *  The shell handler is a thin `setSelected(nav.selection); setView(nav.camera)` — no bespoke jump. */
export interface EntityNavigation {
  readonly selection: { readonly layer: LayerId; readonly id: string }
  readonly camera: Camera
}

export function entityNavigation(match: EntityMatch): EntityNavigation {
  return {
    selection: { layer: match.domain, id: match.id },
    camera: fitCameraToWorldPoints(match.worldPoints),
  }
}
