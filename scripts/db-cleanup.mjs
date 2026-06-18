// Safe retention cleanup runner.  node scripts/db-cleanup.mjs [--confirm]
// Dry-run by default (reports only). With --confirm it deletes expired runtime rows in
// batches via maintenance_cleanup_runtime_data(). NEVER truncates; never touches active
// gameplay, config/world, or permanent player-owned data.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

function loadEnv(p) {
  const e = {}
  try {
    for (const l of readFileSync(p, 'utf8').split('\n')) {
      const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/)
      if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '')
    }
  } catch {}
  return e
}
const env = { ...loadEnv('.env.local'), ...process.env }
const url = env.VITE_SUPABASE_URL
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
if (!url || !serviceKey) { console.error('db:cleanup needs VITE_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const confirm = process.argv.includes('--confirm')
const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

const { data, error } = await admin.rpc('maintenance_cleanup_runtime_data', { dry_run: !confirm, batch_limit: 5000 })
if (error) { console.error('maintenance_cleanup_runtime_data failed:', error.message); process.exit(1) }

console.log(`\nRetention cleanup — ${confirm ? 'LIVE (deleting)' : 'DRY-RUN (no deletes)'} — ${url}\n`)
console.log('  MATCHED  DELETED  TABLE              RULE')
let totMatched = 0, totDeleted = 0
for (const r of data) {
  totMatched += Number(r.rows_matched); totDeleted += Number(r.rows_deleted)
  console.log(`  ${String(r.rows_matched).padStart(7)}  ${String(r.rows_deleted).padStart(7)}  ${String(r.table_name).padEnd(18)} ${r.retention_rule}`)
}
console.log(`  ${'─'.repeat(16)}`)
console.log(`  ${String(totMatched).padStart(7)}  ${String(totDeleted).padStart(7)}  TOTAL`)
const dryFlag = data.length ? data[0].dry_run : !confirm
if (confirm && dryFlag) console.log('\n  NOTE: ran as dry-run because runtime_cleanup_enabled=false (kill-switch).')
console.log('')
