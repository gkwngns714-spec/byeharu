// DB visibility — top 20 largest user tables.  node scripts/db-size.mjs
// Reads pg_total_relation_size via the service-role-only db_table_sizes() RPC.

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
if (!url || !serviceKey) { console.error('db:size needs VITE_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

const { data, error } = await admin.rpc('db_table_sizes')
if (error) { console.error('db_table_sizes failed:', error.message); process.exit(1) }
console.log(`\nTop ${data.length} tables by total size — ${url}\n`)
console.log('  SIZE        TABLE')
for (const r of data) console.log(`  ${String(r.total_pretty).padEnd(11)} ${r.table_name}`)
console.log('')
