// Which system does a function belong to? — the ONE authority.
//
// This used to be answered twice: tree.js for the 조직도 and layout.js for the
// 3D clusters, with quietly different rules (tree ran four bidirectional
// call-inference passes and ignored unowned tables; layout ran one pass and let
// an unowned table vote "nobody"). They disagreed about 49 of 274 functions and
// nothing in the tool could notice — the same function sat in one system in the
// tree and in a different cluster on the map. One question, one answer, here.
//
// Precedence, strongest evidence first:
//   0. named    — SYSTEM_BOUNDARIES states the owner outright (node.system).
//                 This is law, not inference, and nothing below overrules it.
//                 It is how a system that owns NO table (the World Editor, an
//                 owner-gated authoring surface over other systems' tables) can
//                 exist at all: its identity lives in its RPCs.
//   1. direct   — it touches a table with a sole writer -> that system.
//   2. indirect — it calls (or is called by) placed functions -> majority.
//   3. neither  — unclassified, and counted honestly rather than guessed.

/** Deterministic majority: highest count, ties broken by label. */
const winner = (v) => (v && v.size)
  ? [...v].sort((a, b) => b[1] - a[1] || String(a[0]).localeCompare(String(b[0])))[0][0]
  : null

const addVote = (map, key, sys) => {
  const v = map.get(key) ?? new Map()
  v.set(sys, (v.get(sys) ?? 0) + 1)
  map.set(key, v)
}

/**
 * @returns {{ system: Map<string,string|null>, how: Map<string,string> }}
 *   system: function node id -> owning system LABEL, or null for unclassified.
 *   how:    function node id -> why, in words, for whoever reads the tree.
 */
export function functionSystems(nodes, edges) {
  const system = new Map()
  const how = new Map()
  const fnNodes = nodes.filter((n) => n.kind === 'function')

  // table id -> owning system label. Only OWNED tables vote: "touches a table
  // nobody owns" is no evidence at all, and must not outvote real evidence.
  const tableSystem = new Map()
  for (const n of nodes) if (n.kind === 'table') tableSystem.set(n.id, n.system ?? null)

  // 0 — named ownership.
  for (const n of fnNodes) {
    if (!n.system) continue
    system.set(n.id, n.system)
    how.set(n.id, 'named explicitly in SYSTEM_BOUNDARIES')
  }

  // 1 — the tables it touches.
  const touchVotes = new Map()
  for (const e of edges) {
    if (e.type !== 'touches') continue
    const sys = tableSystem.get(e.target)
    if (sys) addVote(touchVotes, e.source, sys)
  }
  for (const [fn, votes] of touchVotes) {
    if (system.has(fn)) continue // law already spoke
    system.set(fn, winner(votes))
    how.set(fn, 'writes/reads a table this system owns')
  }

  // 2 — the company it keeps. Repeat until it stops adding, so a function two
  // hops from any table still lands somewhere.
  const calls = edges.filter((e) => e.type === 'calls')
  for (let pass = 0; pass < 4; pass++) {
    const add = new Map()
    for (const n of fnNodes) {
      if (system.has(n.id)) continue
      const votes = new Map()
      for (const e of calls) {
        const other = e.source === n.id ? e.target : e.target === n.id ? e.source : null
        if (!other) continue
        const s = system.get(other)
        if (!s) continue
        votes.set(s, (votes.get(s) ?? 0) + 1) // neighbours in that system
      }
      const w = winner(votes)
      if (w) add.set(n.id, w)
    }
    if (!add.size) break
    for (const [k, v] of add) { system.set(k, v); how.set(k, 'inferred — it calls functions owned by this system') }
  }

  // 3 — everyone else, named as unclassified rather than left undefined.
  for (const n of fnNodes) if (!system.has(n.id)) system.set(n.id, null)
  return { system, how }
}
