// Build history — when was each node born?
//
// Only migrations carry a real date (the day git first recorded the file).
// Everything else inherits: a function/table is born the day its earliest
// CREATING migration landed; a flag the day its earliest SEEDING migration
// landed; a system the day its earliest owned table appeared. Anything with no
// migration behind it (planned phases/rungs, orphans) is dated to the last day,
// so the final frame of the playback equals the map exactly as it stands now.
//
// One derivation, one authority — the same edge-walk status.js uses.

const push = (map, key, val) => { const a = map.get(key) ?? []; a.push(val); map.set(key, a) }
const earliest = (arr) => (arr && arr.length ? arr.slice().sort()[0] : null)

export function deriveHistory(graph) {
  const byId = new Map(graph.nodes.map((n) => [n.id, n]))
  const migDay = (n) => (n?.addedAt ? n.addedAt.slice(0, 10) : null)
  const birth = new Map()

  // 1. migrations — the only nodes with a first-class date
  for (const n of graph.nodes) if (n.kind === 'migration') birth.set(n.id, migDay(n))

  // 2. gather the migrations that create / seed each symbol
  const creators = new Map()  // targetId -> [day]
  const seeders = new Map()
  for (const e of graph.edges) {
    const day = migDay(byId.get(e.source))
    if (!day) continue
    if (e.type === 'creates') push(creators, e.target, day)
    else if (e.type === 'seeds') push(seeders, e.target, day)
  }

  // 3. functions / tables / flags inherit their earliest origin migration
  for (const n of graph.nodes) {
    if (birth.get(n.id)) continue
    if (n.kind === 'function' || n.kind === 'table') birth.set(n.id, earliest(creators.get(n.id)))
    else if (n.kind === 'flag') birth.set(n.id, earliest(seeders.get(n.id)))
  }

  // 4. systems roll up from the earliest table they own
  for (const n of graph.nodes) {
    if (n.kind !== 'system') continue
    const owned = graph.edges.filter((e) => e.type === 'owned-by' && e.target === n.id)
      .map((e) => birth.get(e.source)).filter(Boolean)
    birth.set(n.id, earliest(owned))
  }

  const days = [...new Set([...birth.values()].filter(Boolean))].sort()
  const lastDay = days[days.length - 1] ?? null

  // 5. everything still undated (future phases/rungs, orphans) lands on the last
  //    day, so the end of the playback is the present-day map, whole.
  for (const n of graph.nodes) if (!birth.get(n.id)) birth.set(n.id, lastDay)

  return { birth, days }
}
