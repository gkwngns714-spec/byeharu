// DB visibility — row counts for high-growth runtime tables.  node scripts/db-counts.mjs
// Reads the service-role-only db_runtime_counts() RPC.

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
if (!url || !serviceKey) { console.error('db:counts needs VITE_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

const { data, error } = await admin.rpc('db_runtime_counts')
if (error) { console.error('db_runtime_counts failed:', error.message); process.exit(1) }
let total = 0
console.log(`\nRuntime table row counts — ${url}\n`)
console.log('  ROWS        TABLE')
for (const r of data) { total += Number(r.row_count); console.log(`  ${String(r.row_count).padEnd(11)} ${r.table_name}`) }
console.log(`  ${'─'.repeat(11)}`)
console.log(`  ${String(total).padEnd(11)} TOTAL\n`)
