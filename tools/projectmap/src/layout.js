// Deliberate 3D layout — assigned regions, not an emergent blob.
//
// The force sim this file used to run produced an organic cloud: honest about
// connectivity, mute about structure. This layout ASSIGNS every kind of node a
// region, so the first glance reads like a diagram:
//
//   · SYSTEMS sit on a ring at y = 0. Each system anchor carries its owned
//     tables on an inner shell and the functions that touch them on an outer
//     shell, in a tight local cluster. Ring arc is allotted per cluster from
//     its actual radius, so clusters can never collide. Tables and functions
//     no doc assigns land in one honest "(unclassified)" cluster that takes a
//     ring slot like everyone else.
//   · MIGRATIONS run along a straight time axis below the ring (y = -190), in
//     chain order — history reads left → right.
//   · FLAGS float in a band at y = +95, each hanging at the bearing of the
//     system its migrations touch, so a gate sits above the thing it gates.
//   · The ROADMAP has its own region high above (y ≥ 205): the activation
//     ladder as an ascending run of rungs, the phase queue as a grid over it.
//
// Fully deterministic — no randomness at all, same graph in → same map out —
// and O(nodes + edges): 600 nodes place instantly, no cooling ticks needed.

import { functionSystems } from './systems.js'

const GOLDEN = Math.PI * (3 - Math.sqrt(5))

/** k-th of n directions spread evenly over a unit sphere (Fibonacci lattice). */
function sphereDir(k, n) {
  const y = n === 1 ? 0 : 1 - (2 * (k + 0.5)) / n
  const r = Math.sqrt(Math.max(0, 1 - y * y))
  const a = k * GOLDEN
  return [r * Math.cos(a), y, r * Math.sin(a)]
}

const UNOWNED = null

// Majority vote with a deterministic tie-break, so the result never depends on
// edge order. Shared by cluster membership and flag placement.
const winner = (v) => (v && v.size)
  ? [...v].sort((a, b) => b[1] - a[1] || String(a[0]).localeCompare(String(b[0])))[0][0]
  : undefined
const addVote = (map, key, sys) => {
  const v = map.get(key) ?? new Map()
  v.set(sys, (v.get(sys) ?? 0) + 1)
  map.set(key, v)
}

// ── cluster membership: who belongs with which system ────────────────────────
// Exported so the agreement between this and the 조직도 is testable — nothing
// else in the tool would notice if the two views drifted apart.
export function clusterMembership(nodes, edges) {
  const tableSystem = new Map() // table id -> system label, or null
  for (const n of nodes) if (n.kind === 'table') tableSystem.set(n.id, n.system ?? UNOWNED)
  // Function membership is not decided here — systems.js decides it once, for
  // this view and the 조직도 alike.
  const { system } = functionSystems(nodes, edges)
  const fnSystem = new Map()
  for (const n of nodes) if (n.kind === 'function') fnSystem.set(n.id, system.get(n.id) ?? UNOWNED)
  return { tableSystem, fnSystem }
}

export function layout(nodes, edges) {
  const pos = new Map() // id -> {x, y, z}
  const put = (id, x, y, z) => pos.set(id, { x, y, z })
  const byKind = (k) => nodes.filter((n) => n.kind === k)
  const byLabel = (a, b) => String(a.label).localeCompare(String(b.label))

  const { tableSystem, fnSystem } = clusterMembership(nodes, edges)

  const clusters = new Map() // system label (or UNOWNED) -> { node, tables, fns }
  const clusterOf = (sys) => {
    if (!clusters.has(sys)) clusters.set(sys, { node: null, tables: [], fns: [] })
    return clusters.get(sys)
  }
  for (const n of byKind('system')) clusterOf(n.label).node = n
  for (const n of byKind('table')) clusterOf(tableSystem.get(n.id)).tables.push(n)
  for (const n of byKind('function')) clusterOf(fnSystem.get(n.id)).fns.push(n)

  // ── the system ring ────────────────────────────────────────────────────────
  // Alphabetical around the ring, unclassified last. Each cluster asks for arc
  // equal to its own diameter plus a gap; the ring radius grows to fit, which
  // is what makes collisions impossible by construction.
  const keys = [...clusters.keys()]
    .sort((a, b) => (a === UNOWNED) - (b === UNOWNED) || String(a).localeCompare(String(b)))
  const rTables = (c) => 12 + 3.1 * Math.sqrt(c.tables.length)
  const rFns = (c) => rTables(c) + 8 + 2.5 * Math.sqrt(c.fns.length)
  const arcs = keys.map((k) => 2 * rFns(clusters.get(k)) + 15)
  const total = arcs.reduce((a, b) => a + b, 0)
  const R = Math.max(250, total / (2 * Math.PI))
  const bearing = new Map() // system -> angle on the ring
  let acc = 0
  keys.forEach((k, i) => { bearing.set(k, ((acc + arcs[i] / 2) / total) * 2 * Math.PI); acc += arcs[i] })

  for (const k of keys) {
    const c = clusters.get(k)
    const th = bearing.get(k)
    const ax = R * Math.cos(th), az = R * Math.sin(th)
    if (c.node) put(c.node.id, ax, 0, az)
    const rT = rTables(c), rF = rFns(c)
    c.tables.sort(byLabel).forEach((n, i) => {
      const [dx, dy, dz] = sphereDir(i, c.tables.length)
      put(n.id, ax + dx * rT, dy * rT, az + dz * rT)
    })
    c.fns.sort(byLabel).forEach((n, i) => {
      const [dx, dy, dz] = sphereDir(i, c.fns.length)
      put(n.id, ax + dx * rF, dy * rF, az + dz * rF)
    })
  }

  // ── the migration time axis ────────────────────────────────────────────────
  const migs = byKind('migration').sort((a, b) => String(a.stamp).localeCompare(String(b.stamp)))
  const W = Math.min(760, Math.max(300, migs.length * 4))
  migs.forEach((n, i) => {
    const t = migs.length === 1 ? 0.5 : i / (migs.length - 1)
    put(n.id, -W / 2 + W * t, -190, 0)
  })

  // ── flags: above the system they gate ──────────────────────────────────────
  // Bearing found through evidence: the migrations that seed/read the flag, to
  // the tables those migrations create/alter, to the owning system. Flags with
  // no such trail form a small ring at the centre rather than being hidden.
  const migTables = new Map() // migration id -> [table ids]
  for (const e of edges) {
    if ((e.type === 'creates' || e.type === 'alters') && tableSystem.has(e.target)) {
      if (!migTables.has(e.source)) migTables.set(e.source, [])
      migTables.get(e.source).push(e.target)
    }
  }
  const flagVotes = new Map()
  for (const e of edges) {
    if (e.type !== 'seeds' && e.type !== 'gated-by') continue
    for (const t of migTables.get(e.source) ?? []) {
      const sys = tableSystem.get(t)
      if (sys !== UNOWNED && sys !== undefined) addVote(flagVotes, e.target, sys)
    }
  }
  const gated = new Map() // system -> [flag nodes]
  const homeless = []
  for (const n of byKind('flag').sort(byLabel)) {
    const sys = winner(flagVotes.get(n.id))
    if (sys !== undefined && bearing.has(sys)) {
      if (!gated.has(sys)) gated.set(sys, [])
      gated.get(sys).push(n)
    } else homeless.push(n)
  }
  for (const [sys, fs] of gated) {
    const th = bearing.get(sys)
    fs.forEach((n, i) => {
      const a = th + (i - (fs.length - 1) / 2) * 0.055 // fan siblings along the ring
      put(n.id, 0.74 * R * Math.cos(a), 95, 0.74 * R * Math.sin(a))
    })
  }
  homeless.forEach((n, i) => {
    const a = (i / Math.max(1, homeless.length)) * 2 * Math.PI
    put(n.id, 42 * Math.cos(a), 95, 42 * Math.sin(a))
  })

  // ── the roadmap: ladder + queue, in their own region up top ────────────────
  const rungs = byKind('rung').sort((a, b) => (a.order ?? 0) - (b.order ?? 0) || byLabel(a, b))
  rungs.forEach((n, i) => put(n.id, (i - (rungs.length - 1) / 2) * 46, 205 + i * 8, 0))

  const phases = byKind('phase')
    .sort((a, b) => (!!a.planned - !!b.planned) || byLabel(a, b)) // shipped first, then the queue
  const COLS = 8
  phases.forEach((n, i) => {
    const row = Math.floor(i / COLS), col = i % COLS
    const inRow = Math.min(COLS, phases.length - row * COLS)
    put(n.id, (col - (inRow - 1) / 2) * 54, 300 + row * 30, 0)
  })

  // Anything a future scan invents is parked in plain sight, not lost at origin.
  nodes.filter((n) => !pos.has(n.id)).forEach((n, i) => put(n.id, i * 20, -95, 0))

  return nodes.map((n) => ({ ...n, ...pos.get(n.id) }))
}
