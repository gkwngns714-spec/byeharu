// Byeharu Project Map — 3D viewer.
import * as THREE from 'three'
import { layout } from './layout.js'
import { createTree } from './tree.js'
import { createTimeline } from './timeline.js'
import { createMethod } from './method.js'
import { deriveStatuses, STATUS, STATUS_ORDER } from './status.js'
import { deriveHistory } from './history.js'

const KIND_SIZE = { system: 5.2, rung: 4.6, phase: 4.2, flag: 3.4, table: 2.4, migration: 1.7, function: 1.3 }
const EDGE_TYPES = ['creates', 'supersedes', 'extends', 'alters', 'drops', 'seeds', 'gated-by', 'calls', 'touches', 'owned-by', 'owned-by-fn', 'delivers', 'delivered-by', 'flips', 'waits-on']
const EDGE_DESC = {
  creates: 'migration defines a function/table',
  supersedes: 'migration re-creates a function an earlier one defined',
  extends: 'migration alters a table an earlier one created',
  alters: 'migration changes a table',
  drops: 'migration removes a function',
  seeds: 'migration inserts a game_config flag',
  'gated-by': 'migration reads a flag to gate behaviour',
  calls: 'function calls another function',
  touches: 'function reads/writes a table',
  'owned-by': 'table belongs to a system (sole writer)',
  'owned-by-fn': 'function belongs to a system (named in SYSTEM_BOUNDARIES)',
  delivers: 'a plan slice delivers this feature gate',
  'delivered-by': 'a plan slice was delivered by this migration',
  flips: 'an activation rung flips this flag',
  'waits-on': 'this rung waits on the one before it',
}

const base = import.meta.env.BASE_URL || '/'
const [graph, live, wip0, purposeDoc] = await Promise.all([
  fetch(`${base}graph.json`).then((r) => r.json()),
  fetch(`${base}live.json`).then((r) => r.json()).catch(() => null),
  fetch(`${base}wip.json`).then((r) => r.json()).catch(() => null),
  fetch(`${base}purpose.json`).then((r) => r.json()).catch(() => null),
])
// purpose[nodeId] → a plain-language "what is this FOR in the game?" line, authored
// in public/purpose.json. Missing/failed load degrades gracefully to nothing.
const purpose = purposeDoc?.purpose ?? {}
const gamePurpose = (id) => purpose[id] || ''

const { status, why, frontier } = deriveStatuses(graph, live)
const { birth, days } = deriveHistory(graph)   // nodeId -> 'YYYY-MM-DD', and the sorted day list

// individual-node reveal order for the playback video — the codebase builds itself
// ONE node at a time (not a day's whole batch at once). Chronological by birth day,
// and within a day a migration appears just before the functions/tables/flags it
// creates (origin-stamp, then kind).
const _byIdN = new Map(graph.nodes.map((n) => [n.id, n]))
const _originStamp = new Map()   // symbol/flag id -> earliest creating/seeding migration stamp
for (const e of graph.edges) {
  if (e.type !== 'creates' && e.type !== 'seeds') continue
  const s = _byIdN.get(e.source)?.stamp
  if (!s) continue
  const cur = _originStamp.get(e.target)
  if (!cur || s < cur) _originStamp.set(e.target, s)
}
const _ORDER_KIND = { migration: 0, flag: 1, table: 2, function: 3, system: 4, phase: 5, rung: 6 }
const _orderStamp = (n) => (n.kind === 'migration' ? n.stamp : _originStamp.get(n.id)) ?? '99999999999999'
const bornOrder = graph.nodes.slice().sort((a, b) => {
  const ba = birth.get(a.id), bb = birth.get(b.id)
  if (ba !== bb) return ba < bb ? -1 : 1
  const sa = _orderStamp(a), sb = _orderStamp(b)
  if (sa !== sb) return sa < sb ? -1 : 1
  const ka = _ORDER_KIND[a.kind] ?? 9, kb = _ORDER_KIND[b.kind] ?? 9
  if (ka !== kb) return ka - kb
  return a.id < b.id ? -1 : 1
}).map((n) => n.id)
const orderRank = new Map(bornOrder.map((id, i) => [id, i]))
const PB_LAST = bornOrder.length - 1
const positioned = layout(graph.nodes, graph.edges)
const byId = new Map(positioned.map((n) => [n.id, n]))
const idx = new Map(positioned.map((n, i) => [n.id, i]))

// adjacency for the inspector + neighbour highlighting
const adj = new Map()
for (const e of graph.edges) {
  if (!adj.has(e.source)) adj.set(e.source, [])
  if (!adj.has(e.target)) adj.set(e.target, [])
  adj.get(e.source).push({ ...e, dir: 'out', other: e.target })
  adj.get(e.target).push({ ...e, dir: 'in', other: e.source })
}

// ── scene ─────────────────────────────────────────────────────────────────────
const canvas = document.getElementById('scene')
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true })
renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
const scene = new THREE.Scene()
scene.fog = new THREE.FogExp2(0x07090f, 0.0016)
const camera = new THREE.PerspectiveCamera(58, 1, 1, 6000)
scene.add(new THREE.AmbientLight(0xffffff, 1.5))
const key = new THREE.DirectionalLight(0xffffff, 1.1); key.position.set(1, 1, 1); scene.add(key)

// nodes as one instanced mesh
const geo = new THREE.SphereGeometry(1, 14, 10)
const mat = new THREE.MeshLambertMaterial({ transparent: true })
const mesh = new THREE.InstancedMesh(geo, mat, positioned.length)
mesh.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(positioned.length * 3), 3)
scene.add(mesh)

const dummy = new THREE.Object3D()
const baseColor = new Float32Array(positioned.length * 3)
positioned.forEach((n, i) => {
  const c = new THREE.Color(status.get(n.id).color)
  baseColor[i * 3] = c.r; baseColor[i * 3 + 1] = c.g; baseColor[i * 3 + 2] = c.b
})

// edges as one line-segment mesh
const lineGeo = new THREE.BufferGeometry()
const lpos = new Float32Array(graph.edges.length * 6)
const lcol = new Float32Array(graph.edges.length * 6)
graph.edges.forEach((e, i) => {
  const a = byId.get(e.source), b = byId.get(e.target)
  lpos.set([a.x, a.y, a.z, b.x, b.y, b.z], i * 6)
})
lineGeo.setAttribute('position', new THREE.BufferAttribute(lpos, 3))
lineGeo.setAttribute('color', new THREE.BufferAttribute(lcol, 3))
const lines = new THREE.LineSegments(lineGeo, new THREE.LineBasicMaterial({
  vertexColors: true, transparent: true, opacity: 0.3, depthWrite: false,
  blending: THREE.AdditiveBlending,
}))
scene.add(lines)

// ── filter state ──────────────────────────────────────────────────────────────
const state = {
  status: new Set(STATUS_ORDER),
  kind: new Set(['system', 'rung', 'phase', 'flag', 'table', 'migration', 'function']),
  edge: new Set(['creates', 'supersedes', 'extends', 'seeds', 'gated-by', 'owned-by', 'owned-by-fn', 'delivers', 'flips', 'waits-on']),
  query: '',
  selected: null,
}

// ── work-in-progress overlay ────────────────────────────────────────────────────
// wipIds: node ids that an OPEN pull request is touching right now — those pulse.
// wipTint: instanceIndex -> THREE.Color, the item colour to pulse toward.
let wipItems = []
let wipIds = new Set()
const wipTint = new Map()          // instanceIndex -> THREE.Color (map pulse)
let wipPulse = []                  // [{ i, n, col }] visible wip nodes, for the scale breathe
const wipHex = new Map()           // nodeId -> hex, shared with the tree + timeline views

// view state — declared here (not at setTab) so the WIP overlay, which runs at
// load, can notify the tree/timeline the moment they exist without a TDZ.
let tab = 'map'
let tree = null
let timeline = null
let method = null

// playback — the build-history time-lapse. `on` gates node visibility by birth
// day; `i` is the current day index into `days`; `playing` auto-advances in tick.
const pb = { on: false, playing: false, i: days.length - 1, last: 0 }
const STEP_MS = 200    // dwell per NODE while playing (one node revealed at a time)
const FLASH_MS = 560   // how long a freshly-revealed node stays lit (outlives one step → a trailing cascade)

const matchesQuery = (n) => !state.query || n.label.toLowerCase().includes(state.query)
  || (n.detail ?? '').toLowerCase().includes(state.query)

function nodeVisible(n) {
  if (pb.on && orderRank.get(n.id) > pb.i) return false   // not revealed yet in the node-by-node build
  return state.status.has(status.get(n.id).key) && state.kind.has(n.kind) && matchesQuery(n)
}

function apply() {
  const focus = state.selected
  const near = focus ? new Set([focus, ...(adj.get(focus) ?? []).map((e) => e.other)]) : null

  let shown = 0
  positioned.forEach((n, i) => {
    const vis = nodeVisible(n)
    if (vis) shown++
    const dim = near && !near.has(n.id)
    const s = vis ? KIND_SIZE[n.kind] * (n.id === focus ? 2.1 : 1) * (wipIds.has(n.id) ? 1.7 : 1) : 0
    dummy.position.set(n.x, n.y, n.z)
    dummy.scale.setScalar(vis ? (dim ? s * 0.55 : s) : 0)
    dummy.updateMatrix()
    mesh.setMatrixAt(i, dummy.matrix)
    const f = dim ? 0.22 : 1
    mesh.instanceColor.array[i * 3] = baseColor[i * 3] * f
    mesh.instanceColor.array[i * 3 + 1] = baseColor[i * 3 + 1] * f
    mesh.instanceColor.array[i * 3 + 2] = baseColor[i * 3 + 2] * f
  })
  mesh.instanceMatrix.needsUpdate = true
  mesh.instanceColor.needsUpdate = true

  let edgeShown = 0
  graph.edges.forEach((e, i) => {
    const a = byId.get(e.source), b = byId.get(e.target)
    const on = state.edge.has(e.type) && nodeVisible(a) && nodeVisible(b)
      && (!near || (near.has(e.source) && near.has(e.target)))
    if (on) edgeShown++
    const c = on ? new THREE.Color(status.get(e.source).color) : null
    for (let k = 0; k < 2; k++) {
      const o = i * 6 + k * 3
      lcol[o] = c ? c.r : 0; lcol[o + 1] = c ? c.g : 0; lcol[o + 2] = c ? c.b : 0
      if (!on) { lpos[o] = 0; lpos[o + 1] = 0; lpos[o + 2] = 0 }
      else {
        const p = k === 0 ? a : b
        lpos[o] = p.x; lpos[o + 1] = p.y; lpos[o + 2] = p.z
      }
    }
  })
  lineGeo.attributes.position.needsUpdate = true
  lineGeo.attributes.color.needsUpdate = true

  hud(shown, edgeShown)
}

// ── UI ────────────────────────────────────────────────────────────────────────
const countBy = (fn) => positioned.reduce((a, n) => (a[fn(n)] = (a[fn(n)] ?? 0) + 1, a), {})
const statusCounts = countBy((n) => status.get(n.id).key)
const kindCounts = countBy((n) => n.kind)
const edgeCounts = graph.edges.reduce((a, e) => (a[e.type] = (a[e.type] ?? 0) + 1, a), {})

function checkbox({ id, label, color, count, checked, title, onChange }) {
  const el = document.createElement('label')
  el.className = 'row'
  if (title) el.title = title
  el.innerHTML = `<input type="checkbox" ${checked ? 'checked' : ''}/>
    ${color ? `<span class="swatch" style="background:${color}"></span>` : ''}
    <span>${label}</span><span class="count">${count}</span>`
  el.querySelector('input').addEventListener('change', (ev) => { onChange(ev.target.checked); apply() })
  return el
}

const sf = document.getElementById('statusFilters')
for (const k of STATUS_ORDER) {
  const s = STATUS[k]
  sf.append(checkbox({
    label: s.label, color: s.hex, count: statusCounts[k] ?? 0, checked: true, title: s.desc,
    onChange: (on) => on ? state.status.add(k) : state.status.delete(k),
  }))
}
const kf = document.getElementById('kindFilters')
for (const k of ['rung', 'phase', 'system', 'flag', 'table', 'migration', 'function']) {
  kf.append(checkbox({
    label: k, count: kindCounts[k] ?? 0, checked: true,
    onChange: (on) => on ? state.kind.add(k) : state.kind.delete(k),
  }))
}
const ef = document.getElementById('edgeFilters')
for (const t of EDGE_TYPES) {
  ef.append(checkbox({
    label: t, count: edgeCounts[t] ?? 0, checked: state.edge.has(t), title: EDGE_DESC[t],
    onChange: (on) => on ? state.edge.add(t) : state.edge.delete(t),
  }))
}

// Off by default: the map should hold still unless you ask it to spin.
let autoRotate = false
document.getElementById('cameraOptions').append(checkbox({
  label: 'Auto-rotate', count: '', checked: autoRotate,
  title: 'Slowly orbit the map on its own while you are not dragging or flying',
  onChange: (on) => { autoRotate = on },
}))

document.getElementById('search').addEventListener('input', (e) => {
  const v = e.target.value
  if (tab === 'tree') { tree?.setQuery(v); return }
  if (tab === 'timeline') { timeline?.setQuery(v); return }
  if (tab === 'method') { method?.setQuery(v); return }
  state.query = v.trim().toLowerCase(); apply()
})
document.getElementById('reset').addEventListener('click', () => {
  state.status = new Set(STATUS_ORDER)
  state.kind = new Set(['rung', 'phase', 'system', 'flag', 'table', 'migration', 'function'])
  state.edge = new Set(['creates', 'supersedes', 'extends', 'seeds', 'gated-by', 'owned-by', 'owned-by-fn', 'delivers', 'flips', 'waits-on'])
  state.query = ''; state.selected = null
  document.getElementById('search').value = ''
  // Re-sync each filter group from its own container — no index arithmetic, so
  // adding a control elsewhere in the rail can never silently shift these.
  // Auto-rotate is a view preference, not a filter, and survives the reset.
  document.querySelectorAll('#statusFilters input, #kindFilters input').forEach((c) => { c.checked = true })
  document.querySelectorAll('#edgeFilters input').forEach((c, i) => { c.checked = state.edge.has(EDGE_TYPES[i]) })
  document.getElementById('inspect').classList.remove('on')
  targetG.set(0, 0, 0); distG = 520; yawG = 0.7; pitchG = 0.35   // glide back to the home view
  apply()
})

const subtitle = document.getElementById('subtitle')
subtitle.textContent = `${graph.counts.nodes} nodes · ${graph.counts.edges} connections`

function hud(nodesShown, edgesShown) {
  const el = document.getElementById('hud')
  const ok = live?.sources?.gameConfig?.ok
  const when = live?.fetchedAt ? new Date(live.fetchedAt).toLocaleString() : '—'
  const dep = live?.deploy?.state ?? 'unknown'
  const warn = dep !== 'success'
  el.innerHTML = `
    <b>${nodesShown}</b> nodes · <b>${edgesShown}</b> connections shown &nbsp;|&nbsp;
    prod: ${ok ? `<b>${live.sources.gameConfig.host}</b> · ${Object.values(live.flags).filter(Boolean).length}/${Object.keys(live.flags).length} flags on`
      : '<span class="warn">no live read — colours are unproven</span>'} &nbsp;|&nbsp;
    deploy: <b class="${warn ? 'warn' : ''}">${dep}</b>
    ${frontier.missingFrom ? `&nbsp;|&nbsp; <span class="warn">prod is behind main from ${frontier.missingFrom} onward</span>` : ''}
    &nbsp;|&nbsp; read ${when}
    <br><b>drag</b> rotate · <b>WASD / arrows</b> fly · <b>Q / E</b> down·up · <b>scroll</b> zoom · <b>shift- or right-drag</b> pan`
}

// inspector
function inspect(id) {
  const el = document.getElementById('inspect')
  if (!id) { el.classList.remove('on'); return }
  const n = byId.get(id)
  const s = status.get(id)
  const rel = (adj.get(id) ?? [])
  const groups = {}
  for (const e of rel) {
    const k = `${e.dir === 'out' ? '' : '← '}${e.type}`
    ;(groups[k] ??= []).push(e)
  }
  el.classList.add('on')
  const inGame = gamePurpose(id)
  el.innerHTML = `
    <div class="kind">${n.kind}</div>
    <h3>${n.label}</h3>
    <div class="pill" style="background:${s.hex}22;color:${s.hex}">
      <span class="swatch" style="background:${s.hex}"></span>${s.label}</div>
    ${inGame ? `<div class="ingame"><span class="ingame-tag">In the game</span>${inGame}</div>` : ''}
    <div class="why">${why.get(id) ?? ''}</div>
    ${n.file ? `<div class="file">${n.file}</div>` : ''}
    ${n.detail ? `<div class="det">${n.detail}</div>` : ''}
    <div class="rel">
      ${Object.entries(groups).map(([k, es]) => `
        <h4>${k} (${es.length})</h4>
        ${es.slice(0, 22).map((e) => {
          const o = byId.get(e.other)
          const os = status.get(e.other)
          return `<div data-goto="${e.other}">
            <span class="swatch" style="background:${os.hex}"></span>
            <span>${o.label}</span>${e.note ? `<span class="t">${e.note}</span>` : ''}</div>`
        }).join('')}
        ${es.length > 22 ? `<div class="t">…${es.length - 22} more</div>` : ''}
      `).join('')}
    </div>`
  el.querySelectorAll('[data-goto]').forEach((d) => {
    d.addEventListener('click', () => select(d.dataset.goto))
  })
}

function select(id) {
  state.selected = id
  inspect(id)
  if (id) {
    const n = byId.get(id)
    targetG.set(n.x, n.y, n.z)          // glide the camera to it (eased in tick)
    // Also frame it. Re-centring alone is not enough: from far out the node is
    // a couple of pixels and its neighbours are dimmed, so selecting something
    // looks like nothing happened — especially after a pinch-out on a phone.
    distG = Math.min(distG, 340)
  }
  apply()
}

// ── work-in-progress: pulse what open PRs are touching, refreshed live ──────────
const wnEl = document.getElementById('workingNow')

function setWip(payload) {
  wipItems = payload?.items ?? []
  wipIds = new Set(wipItems.flatMap((it) => it.nodes))
  wipTint.clear(); wipHex.clear(); wipPulse = []
  for (const it of wipItems) {
    const hex = it.color || '#ff2d95'
    const col = new THREE.Color(hex)
    for (const nid of it.nodes) {
      wipHex.set(nid, hex)
      const i = idx.get(nid)
      if (i != null) { wipTint.set(i, col); wipPulse.push({ i, n: positioned[i], col }) }
    }
  }
  renderWorkingNow(payload)
  tree?.setWip?.(wipHex)
  timeline?.setWip?.(wipHex)
  apply()   // pick up the size bump
}

function renderWorkingNow(payload) {
  if (!wipItems.length) {
    wnEl.innerHTML = '<div class="wn-head"><span>Working now</span></div>'
      + '<div class="wn-empty">No open pull requests — nothing in flight.</div>'
    wnEl.classList.add('on'); return
  }
  const when = payload?.generatedAt ? new Date(payload.generatedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : ''
  const rows = wipItems.map((it) => {
    const target = it.nodes[0]
    const touchN = (it.touches?.functions?.length ?? 0) + (it.touches?.tables?.length ?? 0)
    const meta = [
      it.stamp ? it.stamp.slice(8) : null,           // the migration's mmss tail — enough to tell them apart
      `#${it.pr}`,
      touchN ? `${touchN} symbol${touchN === 1 ? '' : 's'}` : `${it.nodes.length} node${it.nodes.length === 1 ? '' : 's'}`,
    ].filter(Boolean).join(' · ')
    return `<div class="wn-item" data-node="${target}" title="Fly to it">
      <span class="wn-dot" style="background:${it.color}"></span>
      <span class="wn-body"><span class="wn-title">${it.title.replace(/</g, '&lt;')}</span>
      <span class="wn-meta">${meta}</span></span></div>`
  }).join('')
  wnEl.innerHTML = `<div class="wn-head"><span class="wn-live"></span><span>Working now</span>`
    + `<span class="wn-when">${when}</span>`
    + `<button class="wn-fold" title="Collapse" aria-label="Collapse">${wnEl.classList.contains('folded') ? '+' : '–'}</button></div>${rows}`
  wnEl.classList.add('on')
  wnEl.querySelector('.wn-fold')?.addEventListener('click', () => {
    wnEl.classList.toggle('folded')
    wnEl.querySelector('.wn-fold').textContent = wnEl.classList.contains('folded') ? '+' : '–'
  })
  wnEl.querySelectorAll('.wn-item').forEach((el) => el.addEventListener('click', () => {
    const id = el.getAttribute('data-node'); if (byId.has(id)) select(id)
  }))
}

let lastWipGen = wip0?.generatedAt ?? null
setWip(wip0)
// Poll for movement — a merge, a new PR, a force-push — so the map tracks the work
// as it shifts without a reload. Only re-render when the overlay ACTUALLY changed
// (generatedAt moves only when scan/wip.mjs regenerates it); an unchanged poll is a
// no-op, so the view never redraws on its own. Cache-busted; failures keep the last.
setInterval(async () => {
  if (document.hidden) return
  try {
    const p = await fetch(`${base}wip.json?t=${Math.floor(performance.now())}`).then((r) => r.json())
    const gen = p?.generatedAt ?? null
    if (gen === lastWipGen) return          // nothing moved — do not touch the DOM/scene
    lastWipGen = gen
    setWip(p)
  } catch { /* keep the last good overlay */ }
}, 20000)

// ── folding + declutter ────────────────────────────────────────────────────────
// Each .fold button collapses its named panel to the title bar; ⤢ / the H key
// hide every panel at once so the 3D view is clear. One authority: a body/panel
// class, toggled here, styled in CSS.
document.querySelectorAll('.fold[data-fold]').forEach((btn) => {
  btn.addEventListener('click', () => {
    const panel = document.getElementById(btn.dataset.fold)
    panel?.classList.toggle('folded')
    btn.textContent = panel?.classList.contains('folded') ? '+' : '–'
  })
})
const declutter = document.getElementById('declutter')
const toggleClean = () => {
  const on = document.body.classList.toggle('clean')
  declutter.setAttribute('aria-pressed', String(on))
  declutter.title = on ? 'Show panels (H)' : 'Hide all panels (H)'
}
declutter.addEventListener('click', toggleClean)
addEventListener('keydown', (e) => {
  if (e.key.toLowerCase() === 'h' && tab === 'map' && !isTyping()) toggleClean()
})

// ── playback: watch the codebase build itself, day by day ───────────────────────
const historyBtn = document.getElementById('historyBtn')
const pbBar = document.getElementById('playback')
const pbPlayBtn = document.getElementById('pbPlay')
const pbSlider = document.getElementById('pbSlider')
const pbLabel = document.getElementById('pbLabel')
const pbCaption = document.getElementById('pbCaption')
const pbSpeedSel = document.getElementById('pbSpeed')
let pbSpeed = 1                          // playback speed multiplier (0.5×–8×)
pbSpeedSel.addEventListener('change', (e) => { pbSpeed = parseFloat(e.target.value) || 1 })
let bornFlash = []   // [{ i, t }] nodes revealed recently — a brief pop
// the git commit day of the node — the real day that work was done — nicely formatted
const fmtDate = (ymd) => { try { return new Date(ymd + 'T00:00:00').toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) } catch { return ymd } }

// ── the day's caption: what THIS day introduced, in player-facing words ─────────
// Rank the newly-born nodes so the headline features the ones that mean the most to
// a player (a system or a feature switch outranks a lone helper function), surface
// the top few with their game-purpose, and count the rest as "+N more".
const capLabel = (n) => {
  if (n.kind === 'flag') return n.label.replace(/_enabled$/, '').replace(/_/g, ' ')
  if (n.kind === 'migration') return n.label.replace(/^(init|add|create|new|seed|make)_/i, '').replace(/_/g, ' ')
  return n.label
}
const capText = (id) => gamePurpose(id).replace(/\s*\([^)]*\)\s*$/, '')   // drop the trailing (technical label)
// The caption tracks the ONE node being revealed this step — its game-purpose, so
// the video reads like a guided tour: node appears, it tells you what it's for.
function renderCaption() {
  if (!pb.on) { pbCaption.classList.remove('on'); return }
  const id = bornOrder[pb.i]
  const n = _byIdN.get(id)
  const p = capText(id)
  pbCaption.classList.add('on')
  pbCaption.innerHTML = `<div class="cap-date">${fmtDate(birth.get(id))}</div>`
    + `<div class="cap-head"><span class="cap-dot" style="background:${status.get(id).hex}"></span>`
    + `<b>${capLabel(n)}</b> <span class="cap-kind">${n.kind}</span></div>`
    + (p ? `<div class="cap-row">${p}</div>` : '<div class="cap-quiet">Under-the-hood plumbing — no direct player effect.</div>')
}

function pbRender() {
  pbSlider.max = String(PB_LAST)
  pbSlider.value = String(pb.i)
  const n = _byIdN.get(bornOrder[pb.i])
  pbLabel.innerHTML = `<b>${capLabel(n)}</b><span class="pb-sub">${pb.i + 1} / ${bornOrder.length} · ${birth.get(bornOrder[pb.i])}</span>`
  pbPlayBtn.textContent = pb.playing ? '⏸' : '▶'
}
function pbSetStep(i, flash = false) {
  const c = Math.max(0, Math.min(PB_LAST, i))
  if (flash && c !== pb.i) { const ix = idx.get(bornOrder[c]); if (ix != null) bornFlash.push({ i: ix, t: performance.now() }) }
  pb.i = c
  apply(); pbRender(); renderCaption()
}
function pbSetMode(on) {
  pb.on = on
  pb.playing = false
  bornFlash = []
  document.body.classList.toggle('history', on)
  historyBtn.setAttribute('aria-pressed', String(on))
  pbBar.classList.toggle('on', on)
  pb.i = on ? 0 : PB_LAST     // enter at the first node; leave on the full present-day map
  apply(); if (on) pbRender()
  renderCaption()
}
function pbPlayPause() {
  if (!pb.on) return
  if (pb.i >= PB_LAST) pbSetStep(0)     // at the end → replay from the start
  pb.playing = !pb.playing
  pb.last = performance.now()
  pbRender()
}
historyBtn.addEventListener('click', () => pbSetMode(!pb.on))
pbPlayBtn.addEventListener('click', pbPlayPause)
pbSlider.addEventListener('input', (e) => { pb.playing = false; pbSetStep(+e.target.value); })
addEventListener('keydown', (e) => {
  if (tab !== 'map' || isTyping()) return
  if (e.key.toLowerCase() === 'p') pbSetMode(!pb.on)   // toggle the time-lapse
})

// ── the drawer (small screens only) ───────────────────────────────────────────
const menuBtn = document.getElementById('menuBtn')
const scrim = document.getElementById('scrim')
function drawer(open) {
  document.getElementById('controls').classList.toggle('open', open)
  scrim.classList.toggle('on', open)
  menuBtn.setAttribute('aria-expanded', String(open))
}
menuBtn.addEventListener('click', () => drawer(!document.getElementById('controls').classList.contains('open')))
scrim.addEventListener('click', () => drawer(false))
addEventListener('keydown', (e) => { if (e.key === 'Escape') drawer(false) })

// ── camera: orbit + zoom, DAMPED ──────────────────────────────────────────────
// Every control writes a GOAL (…G); the live values ease toward it each frame in tick(). That one
// indirection is what makes the whole thing feel friendly instead of jerky: a drag/zoom/keypress
// nudges the goal and the camera glides there with weight, and clicking a node smoothly flies to it.
const target = new THREE.Vector3(0, 0, 0)       // live — what the camera frames THIS frame
const targetG = new THREE.Vector3(0, 0, 0)      // goal — where it's heading
let dist = 520, yaw = 0.7, pitch = 0.35, drag = null
let distG = 520, yawG = 0.7, pitchG = 0.35
const EASE = 0.22                                // per-frame catch-up (higher = snappier, lower = floatier)

// ── free movement: fly the pivot through the scene (WASD / arrows), drag-pan to slide it ──
// The camera always frames `target`; moving `target` moves you through the graph. Keys fly it
// in the camera's own horizontal frame; shift-drag / right-drag pans it in true screen space.
const held = new Set()
const MOVE_KEYS = new Set(['w', 'a', 's', 'd', 'q', 'e', ' ',
  'arrowup', 'arrowdown', 'arrowleft', 'arrowright'])
const isTyping = () => {
  const el = document.activeElement
  return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT')
}
addEventListener('keydown', (e) => {
  if (tab !== 'map' || isTyping()) return
  const k = e.key.toLowerCase()
  if (MOVE_KEYS.has(k)) { held.add(k); if (k === ' ') e.preventDefault() }
})
addEventListener('keyup', (e) => held.delete(e.key.toLowerCase()))
addEventListener('blur', () => held.clear())
// right-drag needs the browser context menu out of the way
canvas.addEventListener('contextmenu', (e) => e.preventDefault())
const _r = new THREE.Vector3(), _u = new THREE.Vector3(), _f = new THREE.Vector3()

function resize() {
  const w = innerWidth, h = innerHeight
  // updateStyle MUST stay on: a <canvas> is a replaced element, so without an explicit CSS size it
  // falls back to its intrinsic drawing-buffer size (viewport × devicePixelRatio). On a dpr>1 screen
  // that overflows the viewport by the DPR factor, pushing the whole scene — and every click target —
  // off the visible area (nodes become un-tappable). setSize(w,h) keeps CSS = viewport, buffer = ×dpr.
  renderer.setSize(w, h); camera.aspect = w / h; camera.updateProjectionMatrix()
}
addEventListener('resize', resize); resize()

// Pointer bookkeeping, so one finger orbits and two fingers pinch-zoom. Without
// this, touch had no way to zoom at all — wheel is mouse-only.
const pointers = new Map()
let pinchFrom = null

const spread = () => {
  const [a, b] = [...pointers.values()]
  return Math.hypot(a.x - b.x, a.y - b.y)
}

canvas.addEventListener('pointerdown', (e) => {
  canvas.setPointerCapture?.(e.pointerId)
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
  if (pointers.size === 2) { pinchFrom = { d: spread(), dist: distG }; drag = null }
  else if (pointers.size === 1) drag = { x: e.clientX, y: e.clientY, moved: false, pan: e.button === 2 || e.shiftKey }
})

function endPointer(e) {
  const was = pointers.size
  pointers.delete(e.pointerId)
  if (was === 1 && drag && !drag.moved) pick(e)   // a tap, not a drag
  if (pointers.size < 2) pinchFrom = null
  if (pointers.size === 0) drag = null
  // lifting one of two fingers: keep orbiting from the remaining one
  else if (pointers.size === 1) {
    const [p] = [...pointers.values()]
    drag = { x: p.x, y: p.y, moved: true }
  }
}
addEventListener('pointerup', endPointer)
addEventListener('pointercancel', endPointer)

addEventListener('pointermove', (e) => {
  if (pointers.has(e.pointerId)) pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })

  if (pointers.size === 2 && pinchFrom) {
    const now = spread()
    if (now > 0 && pinchFrom.d > 0) {
      distG = Math.max(40, Math.min(2200, pinchFrom.dist * (pinchFrom.d / now)))
    }
    return
  }
  if (drag) {
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y
    if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true
    if (drag.pan) {
      // slide the pivot in true screen space (grab-and-drag), scaled by zoom distance
      camera.matrixWorld.extractBasis(_r, _u, _f)
      const k = distG * 0.0016
      targetG.addScaledVector(_r, -dx * k)
      targetG.addScaledVector(_u, dy * k)
    } else {
      yawG -= dx * 0.0034; pitchG = Math.max(-1.45, Math.min(1.45, pitchG - dy * 0.0034))
    }
    drag.x = e.clientX; drag.y = e.clientY
  } else if (e.pointerType === 'mouse') hover(e)
})
// zoom toward the cursor, not the pivot: find the world point under the mouse and scale the
// camera+pivot about it, so that point stays put on screen (the standard "zoom to cursor").
const _zW = new THREE.Vector3(), _zN = new THREE.Vector3(), _zPlane = new THREE.Plane()
canvas.addEventListener('wheel', (e) => {
  e.preventDefault()
  // Normalise across input kinds so a mouse notch and a trackpad swipe zoom by comparable, gentle
  // amounts (deltaMode: 0=pixels/trackpad, 1=lines/wheel, 2=pages), then clamp a momentum fling.
  let d = e.deltaY
  if (e.deltaMode === 1) d *= 16
  else if (e.deltaMode === 2) d *= 400
  const step = Math.max(-0.2, Math.min(0.2, d * 0.0022))
  const newDist = Math.max(40, Math.min(2200, distG * (1 + step)))
  const f = newDist / distG                       // effective factor after clamping
  if (f !== 1) {
    ndc.x = (e.clientX / innerWidth) * 2 - 1
    ndc.y = -(e.clientY / innerHeight) * 2 + 1
    ray.setFromCamera(ndc, camera)                // raycast the LIVE view the user sees
    let w = null
    for (const h of ray.intersectObject(mesh)) {
      if (nodeVisible(positioned[h.instanceId])) { w = _zW.copy(h.point); break }
    }
    if (!w) {                                     // no node under cursor → plane through the pivot
      camera.getWorldDirection(_zN)
      _zPlane.setFromNormalAndCoplanarPoint(_zN, target)
      w = ray.ray.intersectPlane(_zPlane, _zW)
    }
    if (w) targetG.lerp(w, 1 - f)                 // steer the goal so the cursor point stays put
  }
  distG = newDist
}, { passive: false })

const ray = new THREE.Raycaster()
const ndc = new THREE.Vector2()
function hit(e) {
  ndc.x = (e.clientX / innerWidth) * 2 - 1
  ndc.y = -(e.clientY / innerHeight) * 2 + 1
  ray.setFromCamera(ndc, camera)
  const hits = ray.intersectObject(mesh)
  for (const h of hits) {
    const n = positioned[h.instanceId]
    if (nodeVisible(n)) return n
  }
  return null
}
const tip = document.getElementById('tip')
function hover(e) {
  const n = hit(e)
  canvas.style.cursor = n ? 'pointer' : 'default'
  if (!n) { tip.style.display = 'none'; return }
  const s = status.get(n.id)
  tip.style.display = 'block'
  tip.style.left = `${e.clientX + 13}px`
  tip.style.top = `${e.clientY + 13}px`
  tip.innerHTML = `<span class="swatch" style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${s.hex};margin-right:6px"></span>${n.label} <span style="color:#8792ab">· ${n.kind}</span>`
}
function pick(e) { const n = hit(e); select(n ? n.id : null) }

// ── tabs: the 3D web, and the 조직도 hierarchy ─────────────────────────────────
const TREE_HINT = {
  roadmap: 'The only view that looks forward. Both lists come from FULL_CAPACITY_PLAN.md: the activation ladder (§B) is the ordered flips still owed — violet means everything is deployed and it is only waiting on a human. The development queue (§C) is the slices; grey means planned with nothing built behind it.',
  system: 'Who owns what. Systems come from the sole-writer matrix in SYSTEM_BOUNDARIES. Tables sit under their owner; a function sits under the system whose tables it touches, or — failing that — under the system whose functions it calls. Anything that fits neither is left unclassified rather than forced.',
  build: 'Every migration in the order it landed, grouped by the day git first recorded it — the filename stamps are synthetic and would pile all 205 into one bucket. Each migration lists what it created.',
  feature: 'Every feature gate, and the migrations that seed or read it. Sorted live first, unproven last.',
  timeline: 'The whole arc in one view. Past — every shipped arc, the migration history behind it, and the complete build log from the dev log. Present — what production proves is live, plus the deploy frontier (merged, not yet deployed). Future — the activation ladder still owed and the planned queue.',
  method: 'How this codebase is actually built — the no-spaghetti law, the per-slice build loop (architect → implementer → adversarial reviewer → real-Postgres proof → owner-gated deploy), the verification discipline, and the server-authoritative stance. Every citation is a real node — click one to jump to it on the map. Grounded in docs/HOW_ITS_BUILT.md.',
}

function setTab(next) {
  tab = next
  document.body.className = next
  document.getElementById('treeWrap').classList.toggle('on', next === 'tree')
  document.getElementById('timelineWrap').classList.toggle('on', next === 'timeline')
  document.getElementById('methodWrap').classList.toggle('on', next === 'method')
  document.getElementById('scene').style.display = next === 'map' ? 'block' : 'none'
  document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === next))
  const search = document.getElementById('search')
  search.value = ''
  search.placeholder = next === 'tree' ? 'Search the tree…' : next === 'timeline' ? 'Search the timeline…'
    : next === 'method' ? 'Search the method…' : 'Search nodes…'
  if (next === 'tree') {
    const firstOpen = !tree
    tree ??= createTree({
      graph, status, svg: document.getElementById('tree'),
      onSelect: (nodeId, treeNode) => {
        if (nodeId) return select(nodeId)
        // a grouping node — no graph node behind it, so explain the grouping
        const el = document.getElementById('inspect')
        el.classList.add('on')
        el.innerHTML = `<div class="kind">${treeNode?.kind ?? 'group'}</div>
          <h3>${treeNode?.label ?? ''}</h3>
          ${treeNode?.status ? `<div class="pill" style="background:${treeNode.status.hex}22;color:${treeNode.status.hex}">
            <span class="swatch" style="background:${treeNode.status.hex}"></span>${treeNode.status.label}</div>` : ''}
          <div class="why">${treeNode?.note ?? 'A grouping, not a thing in the codebase. Its colour is rolled up from what is underneath it.'}</div>
          <div class="det">${treeNode?.total ?? 0} item(s) beneath this.</div>`
      },
    })
    // The <select> defaults to the first option; make the tree agree with it
    // rather than quietly rendering a different arrangement than it advertises.
    if (firstOpen) { tree.setMode(document.getElementById('treeMode').value); tree.setWip(wipHex) }
    else tree.setQuery('')
  } else if (next === 'timeline') {
    timeline ??= createTimeline({
      graph, status, mount: document.getElementById('timeline'),
      onSelect: (nodeId) => select(nodeId),
    })
    timeline.setWip(wipHex)
    timeline.setQuery('')
  } else if (next === 'method') {
    method ??= createMethod({
      graph, status, mount: document.getElementById('method'),
      onSelect: (nodeId) => select(nodeId),
    })
    method.setQuery('')
  } else {
    state.query = ''; apply()
  }
  document.getElementById('treeHint').textContent = TREE_HINT[document.getElementById('treeMode').value]
  document.getElementById('timelineHint').textContent = TREE_HINT.timeline
  document.getElementById('methodHint').textContent = TREE_HINT.method
}

document.querySelectorAll('#tabs button').forEach((b) => {
  b.addEventListener('click', () => setTab(b.dataset.tab))
})
document.getElementById('treeMode').addEventListener('change', (e) => {
  tree?.setMode(e.target.value)
  document.getElementById('treeHint').textContent = TREE_HINT[e.target.value]
})
document.getElementById('expandAll').addEventListener('click', () => tree?.expandAll())
document.getElementById('collapseAll').addEventListener('click', () => tree?.collapseAll())

// Debug hook: read the camera from the console, and let tests assert that a
// pinch actually zoomed rather than merely not throwing.
window.__cam = () => ({ dist, yaw, pitch })

document.getElementById('loading').remove()
setTab('map')
apply()
;(function tick() {
  requestAnimationFrame(tick)
  if (held.size) {
    const sp = distG * 0.012                         // fly speed scales with zoom
    _f.set(-Math.sin(yawG), 0, -Math.cos(yawG))      // horizontal forward
    _r.set(Math.cos(yawG), 0, -Math.sin(yawG))       // strafe right
    if (held.has('w') || held.has('arrowup')) targetG.addScaledVector(_f, sp)
    if (held.has('s') || held.has('arrowdown')) targetG.addScaledVector(_f, -sp)
    if (held.has('d') || held.has('arrowright')) targetG.addScaledVector(_r, sp)
    if (held.has('a') || held.has('arrowleft')) targetG.addScaledVector(_r, -sp)
    if (held.has('e') || held.has(' ')) targetG.y += sp
    if (held.has('q')) targetG.y -= sp
  }
  if (autoRotate && !drag && !held.size) yawG += 0.0004  // opt-in orbit; pauses while you fly

  // ── ease the live camera toward its goal — the friendliness lives here ──
  yaw += (yawG - yaw) * EASE
  pitch += (pitchG - pitch) * EASE
  dist += (distG - dist) * EASE
  target.lerp(targetG, EASE)

  camera.position.set(
    target.x + dist * Math.cos(pitch) * Math.sin(yaw),
    target.y + dist * Math.sin(pitch),
    target.z + dist * Math.cos(pitch) * Math.cos(yaw),
  )
  camera.lookAt(target)

  // ── pulse the work-in-progress nodes ──────────────────────────────────────
  // A hard, unmissable strobe: colour snaps base → over-bright PR hue and the
  // node swells ~2×, both driven off the same phase. apply() set everyone else,
  // so we only touch wip indices here (colour every frame, matrix while visible).
  if (wipTint.size) {
    const raw = 0.5 + 0.5 * Math.sin(performance.now() * 0.0075)  // 0..1, faster
    const k = raw * raw                                           // sharpen — sit dark, snap bright
    const hi = 0.25 + 0.75 * k
    const arr = mesh.instanceColor.array
    for (const [i, col] of wipTint) {
      const o = i * 3
      arr[o]     = baseColor[o]     * (1 - hi) + Math.min(1, col.r * 2.0 + 0.15) * hi
      arr[o + 1] = baseColor[o + 1] * (1 - hi) + Math.min(1, col.g * 2.0 + 0.15) * hi
      arr[o + 2] = baseColor[o + 2] * (1 - hi) + Math.min(1, col.b * 2.0 + 0.15) * hi
    }
    mesh.instanceColor.needsUpdate = true

    const grow = 1 + 1.1 * k                                      // breathe up to ~2.1×
    for (const { i, n } of wipPulse) {
      if (!nodeVisible(n)) continue                              // respect the active filters
      const s = KIND_SIZE[n.kind] * 1.7 * grow
      dummy.position.set(n.x, n.y, n.z)
      dummy.scale.setScalar(s)
      dummy.updateMatrix()
      mesh.setMatrixAt(i, dummy.matrix)
    }
    mesh.instanceMatrix.needsUpdate = true
  }

  // ── playback: reveal the next node, and pop it in ──────────────────────────
  if (pb.on && pb.playing) {
    const now = performance.now()
    if (now - pb.last >= STEP_MS / pbSpeed) {   // faster/slower per the speed selector
      pb.last = now
      if (pb.i >= PB_LAST) { pb.playing = false; pbRender() }
      else pbSetStep(pb.i + 1, true)
    }
  }
  if (bornFlash.length) {
    const now = performance.now()
    bornFlash = bornFlash.filter((f) => now - f.t < FLASH_MS)
    for (const f of bornFlash) {
      const n = positioned[f.i]
      if (!nodeVisible(n)) continue
      const age = (now - f.t) / FLASH_MS          // 0..1
      const pop = 1 + 1.6 * (1 - age)            // burst big, settle to normal
      dummy.position.set(n.x, n.y, n.z)
      dummy.scale.setScalar(KIND_SIZE[n.kind] * pop)
      dummy.updateMatrix()
      mesh.setMatrixAt(f.i, dummy.matrix)
      const o = f.i * 3, w = 1 - age              // flash white on arrival
      mesh.instanceColor.array[o]     = baseColor[o]     * (1 - w) + w
      mesh.instanceColor.array[o + 1] = baseColor[o + 1] * (1 - w) + w
      mesh.instanceColor.array[o + 2] = baseColor[o + 2] * (1 - w) + w
    }
    mesh.instanceMatrix.needsUpdate = true
    mesh.instanceColor.needsUpdate = true
  }

  renderer.render(scene, camera)
})()
