// Byeharu Project Map — 3D viewer.
import * as THREE from 'three'
import { layout } from './layout.js'
import { createTree } from './tree.js'
import { deriveStatuses, STATUS, STATUS_ORDER } from './status.js'

const KIND_SIZE = { system: 5.2, flag: 3.4, table: 2.4, migration: 1.7, function: 1.3 }
const EDGE_TYPES = ['creates', 'supersedes', 'extends', 'alters', 'drops', 'seeds', 'gated-by', 'calls', 'touches', 'owned-by']
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
}

const base = import.meta.env.BASE_URL || '/'
const [graph, live] = await Promise.all([
  fetch(`${base}graph.json`).then((r) => r.json()),
  fetch(`${base}live.json`).then((r) => r.json()).catch(() => null),
])

const { status, why, frontier } = deriveStatuses(graph, live)
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
  kind: new Set(['system', 'flag', 'table', 'migration', 'function']),
  edge: new Set(['creates', 'supersedes', 'extends', 'seeds', 'gated-by', 'owned-by']),
  query: '',
  selected: null,
}

const matchesQuery = (n) => !state.query || n.label.toLowerCase().includes(state.query)
  || (n.detail ?? '').toLowerCase().includes(state.query)

function nodeVisible(n) {
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
    const s = vis ? KIND_SIZE[n.kind] * (n.id === focus ? 2.1 : 1) : 0
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
for (const k of ['system', 'flag', 'table', 'migration', 'function']) {
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

document.getElementById('search').addEventListener('input', (e) => {
  const v = e.target.value
  if (tab === 'tree') { tree?.setQuery(v); return }
  state.query = v.trim().toLowerCase(); apply()
})
document.getElementById('reset').addEventListener('click', () => {
  state.status = new Set(STATUS_ORDER)
  state.kind = new Set(['system', 'flag', 'table', 'migration', 'function'])
  state.edge = new Set(['creates', 'supersedes', 'extends', 'seeds', 'gated-by', 'owned-by'])
  state.query = ''; state.selected = null
  document.getElementById('search').value = ''
  document.querySelectorAll('#controls input[type=checkbox]').forEach((c, i) => {
    const groups = [STATUS_ORDER.length, 5, EDGE_TYPES.length]
    c.checked = i < groups[0] + groups[1] ? true : state.edge.has(EDGE_TYPES[i - groups[0] - groups[1]])
  })
  document.getElementById('inspect').classList.remove('on')
  target.set(0, 0, 0); dist = 520
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
    &nbsp;|&nbsp; read ${when}`
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
  el.innerHTML = `
    <div class="kind">${n.kind}</div>
    <h3>${n.label}</h3>
    <div class="pill" style="background:${s.hex}22;color:${s.hex}">
      <span class="swatch" style="background:${s.hex}"></span>${s.label}</div>
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
  if (id) { const n = byId.get(id); target.set(n.x, n.y, n.z) }
  apply()
}

// ── camera: orbit + zoom ──────────────────────────────────────────────────────
const target = new THREE.Vector3(0, 0, 0)
let dist = 520, yaw = 0.7, pitch = 0.35, drag = null

function resize() {
  const w = innerWidth, h = innerHeight
  renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix()
}
addEventListener('resize', resize); resize()

canvas.addEventListener('pointerdown', (e) => { drag = { x: e.clientX, y: e.clientY, moved: false } })
addEventListener('pointerup', (e) => {
  if (drag && !drag.moved) pick(e)
  drag = null
})
addEventListener('pointermove', (e) => {
  if (drag) {
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y
    if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true
    yaw -= dx * 0.005; pitch = Math.max(-1.5, Math.min(1.5, pitch - dy * 0.005))
    drag.x = e.clientX; drag.y = e.clientY
  } else hover(e)
})
canvas.addEventListener('wheel', (e) => {
  e.preventDefault(); dist = Math.max(40, Math.min(2200, dist * (1 + Math.sign(e.deltaY) * 0.11)))
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
  system: 'Who owns what. Systems come from the sole-writer matrix in SYSTEM_BOUNDARIES. Tables sit under their owner; a function sits under the system whose tables it touches, or — failing that — under the system whose functions it calls. Anything that fits neither is left unclassified rather than forced.',
  build: 'Every migration in the order it landed, grouped by the day git first recorded it — the filename stamps are synthetic and would pile all 205 into one bucket. Each migration lists what it created.',
  feature: 'Every feature gate, and the migrations that seed or read it. Sorted live first, unproven last.',
}

let tab = 'map'
let tree = null

function setTab(next) {
  tab = next
  document.body.className = next
  document.getElementById('treeWrap').classList.toggle('on', next === 'tree')
  document.getElementById('scene').style.display = next === 'map' ? 'block' : 'none'
  document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === next))
  const search = document.getElementById('search')
  search.value = ''
  search.placeholder = next === 'tree' ? 'Search the tree…' : 'Search nodes…'
  if (next === 'tree') {
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
    tree.setQuery('')
  } else {
    state.query = ''; apply()
  }
  document.getElementById('treeHint').textContent = TREE_HINT[document.getElementById('treeMode').value]
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

document.getElementById('loading').remove()
setTab('map')
apply()
;(function tick() {
  requestAnimationFrame(tick)
  camera.position.set(
    target.x + dist * Math.cos(pitch) * Math.sin(yaw),
    target.y + dist * Math.sin(pitch),
    target.z + dist * Math.cos(pitch) * Math.cos(yaw),
  )
  camera.lookAt(target)
  if (!drag) yaw += 0.0004
  renderer.render(scene, camera)
})()
