// 3D force-directed layout — small, dependency-free, deterministic.
//
// 544 nodes / ~1450 edges is small enough for plain O(n^2) repulsion if we run a
// fixed number of cooling ticks up front and then freeze. Deterministic seeding
// means the map looks the same every time you open it, which matters when you
// are trying to build a mental picture of your own codebase.

/** Mulberry32 — tiny seeded PRNG so the layout is reproducible. */
function rng(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const KIND_MASS = { system: 6, flag: 3, migration: 1.4, table: 2.2, function: 1 }

export function layout(nodes, edges, { ticks = 320, seed = 1337 } = {}) {
  const rand = rng(seed)
  const n = nodes.length
  const index = new Map(nodes.map((nd, i) => [nd.id, i]))

  const x = new Float32Array(n), y = new Float32Array(n), z = new Float32Array(n)
  const vx = new Float32Array(n), vy = new Float32Array(n), vz = new Float32Array(n)
  const mass = new Float32Array(n)

  // Seed on a sphere, grouped loosely by kind so the sim starts from structure.
  const kinds = [...new Set(nodes.map((nd) => nd.kind))]
  for (let i = 0; i < n; i++) {
    const k = kinds.indexOf(nodes[i].kind)
    const a = rand() * Math.PI * 2
    const b = Math.acos(2 * rand() - 1)
    const r = 60 + k * 22 + rand() * 30
    x[i] = r * Math.sin(b) * Math.cos(a)
    y[i] = r * Math.sin(b) * Math.sin(a)
    z[i] = r * Math.cos(b)
    mass[i] = KIND_MASS[nodes[i].kind] ?? 1
  }

  // Edge list as flat index pairs, with per-type spring strength.
  const TYPE_SPRING = {
    creates: 0.055, seeds: 0.07, 'owned-by': 0.09, 'gated-by': 0.05,
    supersedes: 0.035, extends: 0.03, calls: 0.02, touches: 0.016,
    alters: 0.028, drops: 0.02,
  }
  const ea = [], eb = [], ek = []
  for (const e of edges) {
    const a = index.get(e.source), b = index.get(e.target)
    if (a === undefined || b === undefined) continue
    ea.push(a); eb.push(b); ek.push(TYPE_SPRING[e.type] ?? 0.02)
  }
  const m = ea.length

  const REPULSE = 260
  const CENTER = 0.006
  let temp = 1.0

  for (let t = 0; t < ticks; t++) {
    // repulsion (all pairs)
    for (let i = 0; i < n; i++) {
      let fx = 0, fy = 0, fz = 0
      const xi = x[i], yi = y[i], zi = z[i]
      for (let j = 0; j < n; j++) {
        if (i === j) continue
        let dx = xi - x[j], dy = yi - y[j], dz = zi - z[j]
        let d2 = dx * dx + dy * dy + dz * dz
        if (d2 < 0.01) { dx = rand() - 0.5; dy = rand() - 0.5; dz = rand() - 0.5; d2 = 0.5 }
        const f = (REPULSE * mass[j]) / d2
        const d = Math.sqrt(d2)
        fx += (dx / d) * f; fy += (dy / d) * f; fz += (dz / d) * f
      }
      vx[i] = (vx[i] + fx) * 0.82
      vy[i] = (vy[i] + fy) * 0.82
      vz[i] = (vz[i] + fz) * 0.82
    }
    // springs
    for (let e = 0; e < m; e++) {
      const i = ea[e], j = eb[e], k = ek[e]
      const dx = x[j] - x[i], dy = y[j] - y[i], dz = z[j] - z[i]
      const d = Math.sqrt(dx * dx + dy * dy + dz * dz) || 0.001
      const rest = 34
      const f = (d - rest) * k
      const ux = (dx / d) * f, uy = (dy / d) * f, uz = (dz / d) * f
      const mi = 1 / mass[i], mj = 1 / mass[j]
      vx[i] += ux * mi; vy[i] += uy * mi; vz[i] += uz * mi
      vx[j] -= ux * mj; vy[j] -= uy * mj; vz[j] -= uz * mj
    }
    // gravity to origin + integrate
    for (let i = 0; i < n; i++) {
      vx[i] -= x[i] * CENTER; vy[i] -= y[i] * CENTER; vz[i] -= z[i] * CENTER
      const step = temp * 0.9
      x[i] += Math.max(-8, Math.min(8, vx[i])) * step
      y[i] += Math.max(-8, Math.min(8, vy[i])) * step
      z[i] += Math.max(-8, Math.min(8, vz[i])) * step
    }
    temp *= 0.992
  }

  return nodes.map((nd, i) => ({ ...nd, x: x[i], y: y[i], z: z[i] }))
}
