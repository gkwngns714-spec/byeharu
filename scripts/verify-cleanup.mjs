// Verify self-cleanup — removes runtime rows left by verify test users.
//   node scripts/verify-cleanup.mjs [--confirm] [--pattern '%test%@example.com']
//
// Cleans ONLY runtime rows owned by test-email players (cleanup key = email pattern, which
// must contain "test"). Dry-run by default. Never TRUNCATE; never touches auth.users,
// bases, inventory, main_ship_instances, config, or world data.

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
if (!url || !serviceKey) { console.error('verify:cleanup needs VITE_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const argv = process.argv.slice(2)
const confirm = argv.includes('--confirm')
const patIdx = argv.indexOf('--pattern')
const pattern = patIdx >= 0 ? argv[patIdx + 1] : '%test%@example.com'
const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

const { data, error } = await admin.rpc('cleanup_test_runtime', { p_pattern: pattern, p_dry_run: !confirm })
if (error) { console.error('cleanup_test_runtime failed:', error.message); process.exit(1) }

console.log(`\nVerify runtime cleanup — ${confirm ? 'LIVE (deleting)' : 'DRY-RUN (no deletes)'} — key='${pattern}' — ${url}\n`)
console.log('  MATCHED  DELETED  TABLE')
let tm = 0, td = 0
for (const r of data) { tm += Number(r.rows_matched); td += Number(r.rows_deleted); console.log(`  ${String(r.rows_matched).padStart(7)}  ${String(r.rows_deleted).padStart(7)}  ${r.table_name}`) }
console.log(`  ${'─'.repeat(16)}`)
console.log(`  ${String(tm).padStart(7)}  ${String(td).padStart(7)}  TOTAL   (cleanup_key: email LIKE '${pattern}')\n`)
