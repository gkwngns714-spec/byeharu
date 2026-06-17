// M4.5 — shared, display-only location label. Coordinates stay as coordinates in
// the data; this only formats player-facing text so raw "0, 0" never shows alone.

export function formatLocationLabel(location: {
  name?: string | null
  type?: string | null
  is_home?: boolean | null
  x?: number | null
  y?: number | null
}): string {
  if (location.is_home || location.type === 'home') return 'Home Base'
  if (location.name && location.name.trim().length > 0) return location.name
  if (location.x != null && location.y != null) return `Sector ${location.x}:${location.y}`
  return 'Unknown Sector'
}
