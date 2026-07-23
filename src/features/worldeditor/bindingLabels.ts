// E4 — COMBAT CONTENT: the PURE label resolver for the location→encounter binding surface. A binding row
// stores raw UUIDs (location_id, encounter_profile_id); the surface should read as human names. This maps a
// UUID to its snapshot label (location name / encounter display_name); a STALE UUID with no snapshot match
// (e.g. the referenced row was deleted) falls back to a short UUID rather than a wall of hex. Purely
// presentational — the stored values stay UUIDs; nothing here changes a payload. NO React, NO supabase.

/** A minimal id→label lookup entry (a location's name, an encounter profile's display_name, …). */
export interface NamedRef {
  readonly id: string
  readonly label: string
}

/** Short form of an unmatched UUID: the first segment + ellipsis (e.g. "a1b2c3d4…"). Non-UUID/short ids
 *  pass through unchanged. Presentation-only — never the value that ships. */
export function shortUuid(id: string): string {
  const head = id.split('-')[0]
  return head.length >= 8 && head.length < id.length ? `${head}…` : id
}

/** Resolve a stored UUID to its human label from the snapshot; a stale id (no match) → a short UUID. */
export function resolveRefLabel(id: string, refs: readonly NamedRef[]): string {
  return refs.find((r) => r.id === id)?.label ?? shortUuid(id)
}
