#!/usr/bin/env node
// Byeharu Project Map — WORK-IN-PROGRESS overlay.
//
// Answers one question the static graph can't: what are we touching RIGHT NOW?
// The honest signal for "in flight" is an OPEN pull request. This reads them
// (via gh), finds the migration each one introduces, parses which functions /
// tables that migration creates or drops, and resolves those to real nodes in
// graph.json. The map then pulses exactly those nodes.
//
// Pure derivation, same contract as scan.mjs / live.mjs: every pulsed node
// traces to an open PR's diff. Nothing here is hand-authored opinion. If there
// are no open PRs, the overlay is empty and the map simply doesn't blink.
//
//   node tools/projectmap/scan/wip.mjs
//   -> tools/projectmap/public/wip.json

import { readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = join(HERE, '..', '..', '..')
const GRAPH = join(HERE, '..', 'public', 'graph.json')
const OUT = join(HERE, '..', 'public', 'wip.json')
const GH_REPO = 'gkwngns714-spec/byeharu'

// Distinct, high-chroma hues — deliberately NOT any status colour (green/purple/
// amber/blue/grey/red), so a pulse never reads as a real deploy state.
const PALETTE = ['#ff2d95', '#00e5ff', '#ffd400', '#7cff00', '#ff7a00', '#c04bff']

const git = (...a) => execFileSync('git', ['-C', REPO, ...a], { encoding: 'utf8' }).trim()
const strip = (s) => s.replace(/^public\./i, '').toLowerCase()

function sqlBody(src) {
  return src
    .replace(/--[^\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/'(?:[^']|'')*'/g, "''")
}

// Which system a title/branch is about, when a brand-new migration adds objects
// that don't yet exist on main (so there are no fn:/table: nodes to anchor to).
const SYSTEM_HINTS = [
  [/pirate|danger|intercept|waypoint|territor/i, 'system:Combat'],
  [/combat|telegraph|damage|kiting|projectile/i, 'system:Combat'],
  [/movement|mover|schema.?drop|repoint|osn/i, 'system:Movement'],
  [/mining|ore|belt|extract/i, 'system:Mining'],
  [/shipyard|build|production|craft/i, 'system:Production'],
  [/module|fitting/i, 'system:Modules'],
  [/fleet|group/i, 'system:Fleet'],
]

function openPRs() {
  try {
    const raw = execFileSync('gh', ['pr', 'list', '--repo', GH_REPO, '--state', 'open',
      '--json', 'number,title,headRefName', '--limit', '30'], { encoding: 'utf8' })
    return JSON.parse(raw)
  } catch (e) {
    console.log('! gh pr list failed — no open-PR overlay (', e.message.split('\n')[0], ')')
    return []
  }
}

// Migration files this branch introduces that aren't on main.
function introducedMigrations(branch) {
  try {
    const out = git('diff', '--diff-filter=A', '--name-only', `origin/main...origin/${branch}`,
      '--', 'supabase/migrations/')
    return out ? out.split('\n').filter(Boolean) : []
  } catch { return [] }
}

function fileFromBranch(branch, path) {
  try { return execFileSync('git', ['-C', REPO, 'show', `origin/${branch}:${path}`], { encoding: 'utf8' }) }
  catch { return '' }
}

function main() {
  const graph = JSON.parse(readFileSync(GRAPH, 'utf8'))
  const has = new Set(graph.nodes.map((n) => n.id))
  // label -> id, for resolving parsed function/table names to nodes
  const fnId = new Map(graph.nodes.filter((n) => n.kind === 'function').map((n) => [n.label, n.id]))
  const tblId = new Map(graph.nodes.filter((n) => n.kind === 'table').map((n) => [n.label, n.id]))

  try { git('fetch', 'origin', '--quiet') } catch {}

  const prs = openPRs()
  const items = []

  prs.forEach((pr, i) => {
    const migs = introducedMigrations(pr.headRefName)
    const nodes = new Set()
    let stamp = null
    const touchedFns = new Set(), touchedTbls = new Set()

    for (const path of migs) {
      const m = path.match(/(\d{14})_/)
      if (m) { stamp = m[1]; if (has.has(`mig:${stamp}`)) nodes.add(`mig:${stamp}`) }
      const body = sqlBody(fileFromBranch(pr.headRefName, path))
      for (const mm of body.matchAll(/(?:create(?:\s+or\s+replace)?|drop|alter)\s+function\s+(?:if\s+exists\s+)?([a-z0-9_.]+)/gi)) {
        const id = fnId.get(strip(mm[1])); if (id) { nodes.add(id); touchedFns.add(strip(mm[1])) }
      }
      for (const mm of body.matchAll(/(?:create|drop|alter)\s+table\s+(?:if\s+(?:not\s+)?exists\s+)?([a-z0-9_.]+)/gi)) {
        const id = tblId.get(strip(mm[1])); if (id) { nodes.add(id); touchedTbls.add(strip(mm[1])) }
      }
    }

    // Nothing resolved (brand-new objects not on main) — anchor to a system by topic.
    if (nodes.size === 0) {
      const hint = SYSTEM_HINTS.find(([re]) => re.test(pr.title) || re.test(pr.headRefName))
      if (hint && has.has(hint[1])) nodes.add(hint[1])
    }

    if (nodes.size === 0) return // truly nothing to point at — skip rather than lie

    items.push({
      pr: pr.number,
      title: pr.title,
      branch: pr.headRefName,
      stamp,
      color: PALETTE[i % PALETTE.length],
      touches: { functions: [...touchedFns], tables: [...touchedTbls] },
      nodes: [...nodes],
    })
  })

  const payload = {
    generatedAt: new Date().toISOString(),
    source: `open pull requests on ${GH_REPO}`,
    count: items.length,
    items,
  }
  writeFileSync(OUT, JSON.stringify(payload, null, 2))
  console.log(`\nWIP overlay (${items.length} open PR${items.length === 1 ? '' : 's'}):\n`)
  for (const it of items) console.log(`  #${it.pr}  ${it.color}  ${it.nodes.length} node(s)  ${it.title.slice(0, 60)}`)
  console.log(`\n-> ${OUT}`)
}

main()
