// READ-ONLY. Prints the md5 + metadata of the deployed pirate_intercept_resolve_due_for_movement
// body, which migration 0303's drift gate pins. Every statement here is a SELECT; it writes nothing.
//
//   node scripts/read-resolver-body-hash.mjs
//
// Why this exists: 0303 re-creates a live SECURITY DEFINER function. Per the review, a precondition
// that only checks "the defect is present" is too weak — production could carry the defect PLUS
// legitimate later changes, and re-creating from a local copy would silently revert them. The gate
// therefore pins the WHOLE deployed body by hash, and this script is how that hash is obtained
// honestly (from production) rather than assumed.
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
    .split(/\r?\n/)
    .filter((l) => l && !l.trimStart().startsWith('#') && l.includes('='))
    .map((l) => {
      const i = l.indexOf('=')
      return [l.slice(0, i).trim(), l.slice(i + 1).trim()]
    })
)

const ref = env.SUPABASE_PROJECT_ID
const token = env.SUPABASE_ACCESS_TOKEN
if (!ref || !token) {
  console.error('need SUPABASE_PROJECT_ID + SUPABASE_ACCESS_TOKEN in .env.local')
  process.exit(1)
}

const sql = `
select
  md5(p.prosrc)                                as body_md5,
  length(p.prosrc)                             as body_len,
  pg_get_userbyid(p.proowner)                  as owner,
  p.prosecdef                                  as security_definer,
  p.provolatile                                as volatility,
  p.proparallel                                as parallel,
  p.proconfig                                  as proconfig,
  pg_get_function_identity_arguments(p.oid)    as args,
  pg_get_function_result(p.oid)                as result,
  p.proacl::text                               as acl,
  position('get diagnostics v_manifest = row_count' in p.prosrc) > 0 as has_defect
from pg_proc p
where p.oid = 'public.pirate_intercept_resolve_due_for_movement(uuid)'::regprocedure;
`

const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
})
const body = await res.text()
console.log(res.status)
console.log(body)
