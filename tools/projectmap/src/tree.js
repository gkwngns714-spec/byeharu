// 조직도 — the hierarchy view.
//
// The 3D map shows the web: everything touching everything. This shows the
// chain of command: what belongs to what, and in what order we built it.
//
// A tree needs every node to have exactly one parent, which the real graph does
// not respect (a function touches many tables). So parentage here is *assigned*,
// and where assignment is a judgement call the tree says so rather than hiding
// it — see systems.js (the single ownership authority) and the "unclassified"
// bucket at the bottom of this view.

import { STATUS } from './status.js'
import { functionSystems } from './systems.js'

const ROW_H = 24
const COL_W = 250
const BOX_W = 214
const BOX_H = 19

/**
 * Give each function a single owning system, as tree node ids.
 *
 * The rules live in systems.js — ONE authority, shared with the 3D layout, so
 * the 조직도 and the map can never quietly disagree about where a function is.
 * Unclassified functions are deliberately absent from the map (not set to null):
 * the tree renders them as their own honest bucket further down.
 */
export function assignFunctionSystems(graph) {
  const { system, how } = functionSystems(graph.nodes, graph.edges)
  const assign = new Map()
  for (const [fn, sys] of system) if (sys) assign.set(fn, `system:${sys}`)
  return { assign, how }
}

const ROLLUP = ['LIVE', 'ALWAYS_ON', 'DARK', 'MIGRATED', 'NEEDS_CHECK']
function rollup(kids) {
  const keys = kids.map((k) => k.status?.key).filter(Boolean)
  const pick = ROLLUP.find((r) => keys.includes(r))
  return STATUS[pick ?? 'NEEDS_CHECK']
}

/** Count every real (graph-backed) descendant. */
function tally(node) {
  if (!node.children?.length) return node.nodeId ? 1 : 0
  let n = node.nodeId ? 1 : 0
  for (const c of node.children) n += tally(c)
  return n
}

// ── the three ways of looking at it ──────────────────────────────────────────

export function bySystem(graph, status) {
  const byId = new Map(graph.nodes.map((n) => [n.id, n]))
  const { assign, how } = assignFunctionSystems(graph)
  const owned = new Map() // system -> tables
  for (const e of graph.edges.filter((x) => x.type === 'owned-by')) {
    if (!owned.has(e.target)) owned.set(e.target, [])
    owned.get(e.target).push(e.source)
  }
  const fnsOf = new Map()
  for (const [fn, sys] of assign) {
    if (!fnsOf.has(sys)) fnsOf.set(sys, [])
    fnsOf.get(sys).push(fn)
  }

  const leaf = (id, note) => ({
    id: `t:${id}`, nodeId: id, label: byId.get(id).label,
    kind: byId.get(id).kind, status: status.get(id), note, children: [],
  })

  const systems = graph.nodes.filter((n) => n.kind === 'system')
    .sort((a, b) => a.label.localeCompare(b.label))
    .map((s) => {
      const groups = []
      const tables = (owned.get(s.id) ?? []).sort((a, b) => byId.get(a).label.localeCompare(byId.get(b).label))
      const fns = (fnsOf.get(s.id) ?? []).sort((a, b) => byId.get(a).label.localeCompare(byId.get(b).label))
      if (tables.length) groups.push({ id: `g:${s.id}:t`, label: `tables (${tables.length})`, kind: 'group', children: tables.map((t) => leaf(t)) })
      if (fns.length) groups.push({ id: `g:${s.id}:f`, label: `functions (${fns.length})`, kind: 'group', children: fns.map((f) => leaf(f, how.get(f))) })
      return { id: `t:${s.id}`, nodeId: s.id, label: s.label, kind: 'system', status: status.get(s.id), children: groups }
    })
    .filter((s) => s.children.length)

  const extras = []
  const unownedTables = graph.nodes.filter((n) => n.kind === 'table' && !graph.edges.some((e) => e.type === 'owned-by' && e.source === n.id))
  if (unownedTables.length) {
    extras.push({
      id: 'g:unowned-tables', kind: 'group',
      label: `tables with no sole-writer entry (${unownedTables.length})`,
      note: 'not listed in the SYSTEM_BOUNDARIES ownership matrix',
      children: unownedTables.sort((a, b) => a.label.localeCompare(b.label)).map((t) => leaf(t.id)),
    })
  }
  const loose = graph.nodes.filter((n) => n.kind === 'function' && !assign.has(n.id))
  if (loose.length) {
    extras.push({
      id: 'g:unclassified', kind: 'group',
      label: `unclassified functions (${loose.length})`,
      note: 'touches no owned table and calls nothing already placed — could not be attributed to a system',
      children: loose.sort((a, b) => a.label.localeCompare(b.label)).map((f) => leaf(f.id)),
    })
  }

  return { id: 'root', label: 'Byeharu', kind: 'root', children: [...systems, ...extras] }
}

function byBuildOrder(graph, status) {
  const byId = new Map(graph.nodes.map((n) => [n.id, n]))
  const created = new Map()
  for (const e of graph.edges.filter((x) => x.type === 'creates' || x.type === 'seeds')) {
    if (!created.has(e.source)) created.set(e.source, [])
    created.get(e.source).push(e.target)
  }
  // Group by the day git says the file first landed, NOT the filename stamp —
  // the stamps are synthetic and would pile all 205 into one bucket.
  const migs = graph.nodes.filter((n) => n.kind === 'migration').sort((a, b) => a.stamp.localeCompare(b.stamp))
  const days = new Map()
  for (const m of migs) {
    const key = m.addedAt ? m.addedAt.slice(0, 10) : 'not yet committed'
    if (!days.has(key)) days.set(key, [])
    days.get(key).push(m)
  }
  const ordered = [...days].sort((a, b) => a[0].localeCompare(b[0]))
  return {
    id: 'root', label: 'Byeharu — in the order we built it', kind: 'root',
    children: ordered.map(([day, list]) => ({
      id: `g:${day}`, kind: 'group', label: `${day} — ${list.length} migration${list.length > 1 ? 's' : ''}`,
      note: 'grouped by the day git first recorded these files, not the synthetic filename stamp',
      children: list.map((m) => ({
        id: `t:${m.id}`, nodeId: m.id, label: m.label, kind: 'migration', status: status.get(m.id),
        children: (created.get(m.id) ?? []).map((c) => ({
          id: `t:${m.id}:${c}`, nodeId: c, label: byId.get(c).label,
          kind: byId.get(c).kind, status: status.get(c), children: [],
        })),
      })),
    })),
  }
}

function byFeature(graph, status) {
  const byId = new Map(graph.nodes.map((n) => [n.id, n]))
  const migsOf = new Map()
  for (const e of graph.edges.filter((x) => x.type === 'seeds' || x.type === 'gated-by')) {
    if (!migsOf.has(e.target)) migsOf.set(e.target, new Set())
    migsOf.get(e.target).add(e.source)
  }
  const flags = graph.nodes.filter((n) => n.kind === 'flag')
    .sort((a, b) => {
      const o = ROLLUP.indexOf(status.get(a.id).key) - ROLLUP.indexOf(status.get(b.id).key)
      return o || a.label.localeCompare(b.label)
    })
  return {
    id: 'root', label: 'Byeharu — by feature gate', kind: 'root',
    children: flags.map((f) => ({
      id: `t:${f.id}`, nodeId: f.id, label: f.label, kind: 'flag', status: status.get(f.id),
      children: [...(migsOf.get(f.id) ?? [])].sort().map((m) => ({
        id: `t:${f.id}:${m}`, nodeId: m, label: byId.get(m).label,
        kind: 'migration', status: status.get(m), children: [],
      })),
    })),
  }
}

/**
 * What's next — the only view that looks forward.
 *
 * Two lists, both read from FULL_CAPACITY_PLAN.md: the activation ladder (the
 * ordered flips still owed) and the development queue (slices, built or not).
 */
function byRoadmap(graph, status) {
  const byId = new Map(graph.nodes.map((n) => [n.id, n]))
  const kids = (id) => graph.edges
    .filter((e) => e.source === id && ['flips', 'delivers', 'delivered-by'].includes(e.type))
    .map((e) => ({
      id: `t:${id}:${e.target}`, nodeId: e.target, label: byId.get(e.target).label,
      kind: byId.get(e.target).kind, status: status.get(e.target), note: e.type, children: [],
    }))

  const rungs = graph.nodes.filter((n) => n.kind === 'rung').sort((a, b) => a.order - b.order)
  const phases = graph.nodes.filter((n) => n.kind === 'phase')
    .sort((a, b) => {
      const pa = parseInt(a.label.match(/^P(\d+)/)?.[1] ?? '99', 10)
      const pb = parseInt(b.label.match(/^P(\d+)/)?.[1] ?? '99', 10)
      return pa - pb || a.label.localeCompare(b.label)
    })

  const node = (n) => ({
    id: `t:${n.id}`, nodeId: n.id, label: n.label, kind: n.kind,
    status: status.get(n.id), children: kids(n.id),
  })

  return {
    id: 'root', label: 'Byeharu — what is next', kind: 'root',
    children: [
      {
        id: 'g:ladder', kind: 'group', label: `activation ladder (${rungs.length} rungs, in order)`,
        note: 'The flips still owed, from FULL_CAPACITY_PLAN §B. Green = already on. Violet = everything is deployed and it is just waiting for a human to flip it. Amber = blocked, something has not reached prod.',
        children: rungs.map(node),
      },
      {
        id: 'g:queue', kind: 'group', label: `development queue (${phases.length} slices)`,
        note: 'From FULL_CAPACITY_PLAN §C. Grey = planned, nothing built behind it yet.',
        children: phases.map(node),
      },
    ],
  }
}

const BUILDERS = { system: bySystem, build: byBuildOrder, feature: byFeature, roadmap: byRoadmap }

// ── render ───────────────────────────────────────────────────────────────────

export function createTree({ graph, status, svg, onSelect }) {
  let mode = 'system'
  let query = ''
  let root = null
  let collapsed = new Set()
  let selected = null
  let wip = new Map()   // nodeId -> hex, the open-PR overlay (blinks)

  function build() {
    root = BUILDERS[mode](graph, status)
    // roll status up into groups, and stamp counts
    ;(function walk(n) {
      n.children?.forEach(walk)
      if (!n.status && n.children?.length) n.status = rollup(n.children)
      n.total = tally(n)
    })(root)
    collapsed = new Set()
    ;(function collapseBelow(n, d) {
      if (d >= 1 && n.children?.length) collapsed.add(n.id)
      n.children?.forEach((c) => collapseBelow(c, d + 1))
    })(root, 0)
  }

  const matches = (n) => !query || n.label.toLowerCase().includes(query)
  // a node survives search if it or any descendant matches
  function keep(n) {
    if (matches(n)) return true
    return (n.children ?? []).some(keep)
  }

  function visibleTree() {
    const out = []
    let y = 0
    ;(function place(n, depth) {
      if (query && !keep(n)) return null
      const kids = collapsed.has(n.id) && !query ? [] : (n.children ?? []).map((c) => place(c, depth + 1)).filter(Boolean)
      const row = { n, depth, kids, x: depth * COL_W }
      row.y = kids.length ? (kids[0].y + kids[kids.length - 1].y) / 2 : (y += ROW_H)
      out.push(row)
      return row
    })(root, 0)
    return out
  }

  function render() {
    const rows = visibleTree()
    const height = Math.max(...rows.map((r) => r.y)) + ROW_H
    const width = Math.max(...rows.map((r) => r.x)) + BOX_W + 40
    svg.setAttribute('viewBox', `0 0 ${width} ${height + 20}`)
    svg.setAttribute('width', width)
    svg.setAttribute('height', height + 20)

    const parts = []
    for (const r of rows) {
      for (const k of r.kids) {
        const x1 = r.x + BOX_W, y1 = r.y, x2 = k.x, y2 = k.y
        const mx = (x1 + x2) / 2
        parts.push(`<path d="M${x1} ${y1} C${mx} ${y1} ${mx} ${y2} ${x2} ${y2}" fill="none" stroke="${(k.n.status ?? STATUS.NEEDS_CHECK).hex}" stroke-opacity=".33" stroke-width="1.2"/>`)
      }
    }
    for (const r of rows) {
      const s = r.n.status ?? STATUS.NEEDS_CHECK
      const isGroup = r.n.kind === 'group' || r.n.kind === 'root'
      const hasKids = (r.n.children ?? []).length > 0
      const isCollapsed = collapsed.has(r.n.id) && !query
      const dim = query && !matches(r.n) ? 0.42 : 1
      const sel = selected === r.n.id
      const label = r.n.label.length > 30 ? `${r.n.label.slice(0, 29)}…` : r.n.label
      const wc = r.n.nodeId ? wip.get(r.n.nodeId) : null
      parts.push(`<g class="tn${wc ? ' wip' : ''}" data-id="${r.n.id}" data-node="${r.n.nodeId ?? ''}"${wc ? ` style="--wc:${wc}"` : ''} transform="translate(${r.x},${r.y - BOX_H / 2})" opacity="${dim}">
        <rect width="${BOX_W}" height="${BOX_H}" rx="4"
          fill="${isGroup ? 'rgba(255,255,255,.045)' : `${s.hex}1c`}"
          stroke="${sel ? '#fff' : s.hex}" stroke-opacity="${sel ? 1 : isGroup ? .3 : .62}" stroke-width="${sel ? 1.6 : 1}"/>
        ${isGroup ? '' : `<circle cx="9" cy="${BOX_H / 2}" r="3" fill="${s.hex}"/>`}
        <text x="${isGroup ? 8 : 18}" y="${BOX_H / 2 + 3.6}" font-size="10.5"
          fill="${isGroup ? '#c3ccdf' : '#e8ecf5'}">${escapeHtml(label)}</text>
        ${hasKids ? `<text x="${BOX_W - 8}" y="${BOX_H / 2 + 3.6}" font-size="9" text-anchor="end" fill="#8792ab">${isCollapsed ? `+${r.n.total}` : '–'}</text>` : ''}
      </g>`)
    }
    svg.innerHTML = parts.join('')

    svg.querySelectorAll('.tn').forEach((g) => {
      g.style.cursor = 'pointer'
      g.addEventListener('click', () => {
        const id = g.dataset.id
        const row = rows.find((r) => r.n.id === id)
        if (row?.n.children?.length && !query) {
          if (collapsed.has(id)) collapsed.delete(id); else collapsed.add(id)
        }
        selected = id
        onSelect?.(g.dataset.node || null, row?.n ?? null)
        render()
      })
    })
  }

  const escapeHtml = (s) => s.replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]))

  build(); render()

  return {
    setMode(m) { mode = m; selected = null; build(); render() },
    setQuery(q) { query = q.trim().toLowerCase(); render() },
    setWip(map) { wip = map ?? new Map(); render() },
    expandAll() { collapsed = new Set(); render() },
    collapseAll() { build(); render() },
    counts() { return { nodes: tally(root) } },
  }
}
