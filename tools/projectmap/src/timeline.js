// Timeline — the whole arc: past → present → future.
//
// The roadmap mode of the 조직도 looks forward only. This view answers the
// broader question in one screen: what has been BUILT (the shipped phases, the
// migration history, and the complete DEV_LOG build log — frontend slices and
// fix batches included), what is LIVE right now plus the deploy frontier
// (merged but not yet in prod), and what is PLANNED (the development queue and
// the activation ladder). Every colour comes from STATUS — evidence, never
// decoration.

import { STATUS } from './status.js'

// Same first-present-wins priority the tree uses to roll a group's colour up.
const ROLLUP = ['LIVE', 'ALWAYS_ON', 'DARK', 'MIGRATED', 'NEEDS_CHECK']
const KINDS = ['system', 'rung', 'phase', 'flag', 'table', 'function', 'migration']

const esc = (s) => String(s).replace(/[<>&"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]))

export function createTimeline({ graph, status, mount, onSelect }) {
  let query = ''
  let selected = null
  let wip = new Map()   // nodeId -> hex, the open-PR overlay (blinks)

  const byId = new Map(graph.nodes.map((n) => [n.id, n]))
  const jobs = graph.jobs ?? [] // the scanned DEV_LOG build log, oldest first
  const st = (id) => status.get(id) ?? STATUS.NEEDS_CHECK
  const rollup = (ids) => {
    const keys = ids.map((id) => st(id).key)
    return STATUS[ROLLUP.find((k) => keys.includes(k)) ?? 'NEEDS_CHECK']
  }

  // ── PAST — migrations oldest → newest ──────────────────────────────────────
  // Ordered by the day git first recorded the file; anything git never saw
  // falls back to its filename seq and sits at the end, labelled honestly.
  const migs = graph.nodes.filter((n) => n.kind === 'migration').sort((a, b) => {
    if (a.addedAt && b.addedAt) return a.addedAt.localeCompare(b.addedAt) || a.stamp.localeCompare(b.stamp)
    if (a.addedAt !== b.addedAt) return a.addedAt ? -1 : 1
    return (a.seq ?? 0) - (b.seq ?? 0) || a.stamp.localeCompare(b.stamp)
  })
  const days = []
  for (const m of migs) {
    const day = m.addedAt ? m.addedAt.slice(0, 10) : 'not yet committed'
    if (days.at(-1)?.day === day) days.at(-1).migs.push(m)
    else days.push({ day, migs: [m] })
  }

  // Shipped phases as milestones, dated by the first migration that delivered them.
  const deliveredBy = new Map() // phase id -> [migration ids]
  for (const e of graph.edges) {
    if (e.type !== 'delivered-by') continue
    if (!deliveredBy.has(e.source)) deliveredBy.set(e.source, [])
    deliveredBy.get(e.source).push(e.target)
  }
  const built = graph.nodes.filter((n) => n.kind === 'phase' && !n.planned)
    .map((p) => {
      const pm = (deliveredBy.get(p.id) ?? []).map((id) => byId.get(id)).filter(Boolean)
      const dates = pm.map((m) => m.addedAt).filter(Boolean).sort()
      return { p, migCount: pm.length, first: dates[0]?.slice(0, 10) ?? null }
    })
    .sort((a, b) => {
      if (a.first && b.first) return a.first.localeCompare(b.first) || a.p.label.localeCompare(b.p.label)
      if (a.first !== b.first) return a.first ? -1 : 1
      return a.p.label.localeCompare(b.p.label)
    })

  // ── PRESENT — proven prod state + the deploy frontier ──────────────────────
  const liveCounts = KINDS.map((kind) => {
    const ns = graph.nodes.filter((n) => n.kind === kind)
    return {
      kind,
      live: ns.filter((n) => st(n.id).key === 'LIVE').length,
      on: ns.filter((n) => st(n.id).key === 'ALWAYS_ON').length,
    }
  }).filter((r) => r.live || r.on)
  const liveFlags = graph.nodes.filter((n) => n.kind === 'flag' && st(n.id).key === 'LIVE')
    .sort((a, b) => a.label.localeCompare(b.label))
  const migrated = graph.nodes.filter((n) => st(n.id).key === 'MIGRATED')
  const unproven = graph.nodes.filter((n) => st(n.id).key === 'NEEDS_CHECK').length
  // With no live read nothing is provable and "all deployed" would be a lie.
  const anyProof = graph.nodes.some((n) => ['LIVE', 'ALWAYS_ON', 'DARK', 'MIGRATED'].includes(st(n.id).key))

  // ── FUTURE — the ladder and the planned queue ──────────────────────────────
  const flips = new Map() // rung id -> [flag ids]
  for (const e of graph.edges) {
    if (e.type !== 'flips') continue
    if (!flips.has(e.source)) flips.set(e.source, [])
    flips.get(e.source).push(e.target)
  }
  const rungs = graph.nodes.filter((n) => n.kind === 'rung').sort((a, b) => a.order - b.order)
  // Queue order read from the labels: the S-series arc first (S2…S6), then
  // un-numbered slices of that arc (RETIRE), then the P-numbered queue.
  const qKey = (n) => {
    const s = n.label.match(/—\s*S(\d+)/)
    if (s) return +s[1]
    const p = n.label.match(/^P(\d+)/)
    if (p) return 100 + +p[1]
    return 50
  }
  const planned = graph.nodes.filter((n) => n.kind === 'phase' && n.planned)
    .sort((a, b) => qKey(a) - qKey(b) || a.label.localeCompare(b.label))

  // ── render ─────────────────────────────────────────────────────────────────
  function render() {
    const dimCls = (label) => query && !label.toLowerCase().includes(query) ? ' dm' : ''
    const selCls = (id) => id === selected ? ' sel' : ''

    const chip = (s) => `<span class="tl-chip" style="background:${s.hex}22;color:${s.hex}">
      <span class="swatch" style="background:${s.hex}"></span><span class="ct">${esc(s.label)}</span></span>`
    const nodeChip = (id) => {
      const n = byId.get(id)
      const s = st(id)
      return `<span class="tl-fchip${selCls(id)}${dimCls(n.label)}" data-goto="${esc(id)}"
        style="background:${s.hex}22;color:${s.hex}">
        <span class="swatch" style="background:${s.hex}"></span>${esc(n.label)}</span>`
    }
    const row = (n, { date = '—', count = '' } = {}) => `
      <div class="tl-row${selCls(n.id)}${dimCls(n.label)}" data-goto="${esc(n.id)}">
        <span class="tl-date">${esc(date)}</span>
        <span class="tl-label">${esc(n.label)}</span>
        ${chip(st(n.id))}
        <span class="tl-count">${esc(count)}</span>
      </div>`

    // migration spine: one tick per day, height = how much landed, colour = rollup
    let spine = ''
    if (days.length) {
      const max = Math.max(...days.map((d) => d.migs.length))
      const SP = 11
      const w = days.length * SP + 14
      const ticks = days.map((d, i) => {
        const s = rollup(d.migs.map((m) => m.id))
        const h = 5 + 30 * (d.migs.length / max)
        return `<rect x="${7 + i * SP}" y="${41 - h}" width="4" height="${h.toFixed(1)}" rx="1"
          fill="${s.hex}" fill-opacity=".85"><title>${esc(d.day)} — ${d.migs.length} migration${d.migs.length > 1 ? 's' : ''}</title></rect>`
      }).join('')
      spine = `<div class="tl-spine"><svg width="${Math.max(w, 220)}" height="58" viewBox="0 0 ${Math.max(w, 220)} 58">
        <line x1="4" y1="42" x2="${w - 4}" y2="42" stroke="rgba(255,255,255,.14)"/>
        ${ticks}
        <text x="6" y="55" font-size="9" fill="#8792ab">${esc(days[0].day)}</text>
        <text x="${w - 4}" y="55" font-size="9" fill="#8792ab" text-anchor="end">${esc(days.at(-1).day)}</text>
      </svg></div>`
    }

    const pastRows = built.map(({ p, migCount, first }) =>
      row(p, { date: first ?? '—', count: migCount ? `${migCount} mig${migCount > 1 ? 's' : ''}` : '' })).join('')

    // The build log — every job docs/DEV_LOG.md records, oldest first. These
    // are log entries, not graph nodes, so the row itself does not navigate;
    // the migration chips under a row are real nodes with real status colours.
    const jobRows = jobs.map((j) => {
      const chips = (j.migs ?? []).filter((s) => byId.has(`mig:${s}`))
        .map((s) => nodeChip(`mig:${s}`)).join('')
      return `<div class="tl-row static${dimCls(j.title)}">
          <span class="tl-date">${esc(j.date)}</span>
          <span class="tl-label" title="${esc(j.title)}">${esc(j.title)}</span>
          <span></span><span class="tl-count"></span>
        </div>
        ${chips ? `<div class="tl-flips">${chips}</div>` : ''}`
    }).join('')

    // present: counts that line up, the gates that are on, then the frontier
    const totLive = liveCounts.reduce((a, r) => a + r.live, 0)
    const totOn = liveCounts.reduce((a, r) => a + r.on, 0)
    const table = `<table class="tl-table">
      <thead><tr><th></th>
        <th style="color:${STATUS.LIVE.hex}">${esc(STATUS.LIVE.label)}</th>
        <th style="color:${STATUS.ALWAYS_ON.hex}">${esc(STATUS.ALWAYS_ON.label)}</th></tr></thead>
      <tbody>
        ${liveCounts.map((r) => `<tr><td>${r.kind}</td><td>${r.live || '·'}</td><td>${r.on || '·'}</td></tr>`).join('')}
        <tr class="tot"><td>total</td><td>${totLive}</td><td>${totOn}</td></tr>
      </tbody></table>`
    const gates = liveFlags.length
      ? `<div class="tl-subhead">gates on in prod (${liveFlags.length})</div>
         <div class="tl-chips">${liveFlags.map((f) => nodeChip(f.id)).join('')}</div>`
      : ''
    let frontier
    if (!anyProof) {
      frontier = `<div class="tl-note" style="color:${STATUS.NEEDS_CHECK.hex}">no live read — the deploy frontier cannot be proven</div>`
    } else if (!migrated.length) {
      frontier = '<div class="tl-note">all merged work is deployed — nothing is waiting at the deploy gate</div>'
    } else {
      frontier = KINDS.map((kind) => {
        const ns = migrated.filter((n) => n.kind === kind).sort((a, b) => a.label.localeCompare(b.label))
        if (!ns.length) return ''
        return `<div class="tl-note">${kind} (${ns.length})</div>
          <div class="tl-chips">${ns.slice(0, 40).map((n) => nodeChip(n.id)).join('')}
          ${ns.length > 40 ? `<span class="tl-note">…${ns.length - 40} more</span>` : ''}</div>`
      }).join('')
    }

    const ladder = rungs.map((r) => {
      const fl = (flips.get(r.id) ?? []).map(nodeChip).join('')
      return `<div class="tl-rung">
        ${row(r, { date: `R${r.order}` })}
        ${fl ? `<div class="tl-flips">${fl}</div>` : ''}
      </div>`
    }).join('')

    const plannedRows = planned.map((p, i) =>
      row(p, { date: `${i + 1}.`, count: (p.size ?? '').split('—')[0].trim() })).join('')

    mount.innerHTML = `
      <section class="tl-sec">
        <div class="tl-era">과거 · past</div>
        <h2>What has been built</h2>
        <div class="tl-desc">${migs.length} migrations across ${days.length} days of history —
          each tick is a day, its height how much landed, its colour rolled up from what that day is today.
          Below, every shipped arc in the order it began; the chip is its proven production state.
          Then the complete build log from docs/DEV_LOG.md — every job, database or not.</div>
        ${spine}
        <div class="tl-subhead">shipped arcs (${built.length})</div>
        ${pastRows}
        ${jobs.length ? `
          <div class="tl-subhead">build log — every job in docs/DEV_LOG.md (${jobs.length})</div>
          ${jobRows}` : ''}
      </section>
      <section class="tl-sec">
        <div class="tl-era">현재 · present</div>
        <h2>Where we are now</h2>
        <div class="tl-desc">What production proves is live right now, and the deploy frontier —
          work merged to main that has not reached the production database.</div>
        ${table}
        ${gates}
        <div class="tl-subhead">deploy frontier</div>
        ${frontier}
        ${unproven ? `<div class="tl-note">…and <span style="color:${STATUS.NEEDS_CHECK.hex}">${unproven}</span> node(s) whose production state could not be proven.</div>` : ''}
      </section>
      <section class="tl-sec">
        <div class="tl-era">미래 · future</div>
        <h2>What comes next</h2>
        <div class="tl-desc">The activation ladder — the flips still owed, in order — and the development
          queue of planned slices. ${esc(STATUS.PLANNED.label)} (grey) means nothing is built behind it yet.</div>
        <div class="tl-subhead">activation ladder (${rungs.length} rungs)</div>
        ${ladder}
        <div class="tl-subhead">development queue (${planned.length} planned slices)</div>
        ${plannedRows}
      </section>`

    // WIP overlay: mark any row/chip an open PR is touching so it blinks. Runs
    // after every render because innerHTML wipes the classes each time.
    if (wip.size) for (const el of mount.querySelectorAll('[data-goto]')) {
      const hex = wip.get(el.dataset.goto)
      if (hex) { el.classList.add('wip'); el.style.setProperty('--wc', hex) }
    }
  }

  mount.addEventListener('click', (e) => {
    const t = e.target.closest('[data-goto]')
    if (!t || !mount.contains(t)) return
    selected = t.dataset.goto
    onSelect?.(selected)
    render()
  })

  render()

  return {
    setQuery(q) { query = q.trim().toLowerCase(); render() },
    setWip(map) { wip = map ?? new Map(); render() },
  }
}
