// One-off maintenance helper: list graph nodes that have no authored purpose line.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const here = dirname(fileURLToPath(import.meta.url))
const g = JSON.parse(readFileSync(join(here, '..', 'public', 'graph.json'), 'utf8'))
const p = JSON.parse(readFileSync(join(here, '..', 'public', 'purpose.json'), 'utf8'))
const missing = g.nodes.filter((n) => !p.purpose[n.id])
console.log('missing:', missing.length, '/', g.nodes.length)
for (const n of missing) console.log(`${n.id} | ${n.label || ''} | ${n.kind || ''}`)
