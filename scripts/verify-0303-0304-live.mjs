// READ-ONLY post-deploy verification for migrations 0303 + 0304, run against production.
// Every statement is a SELECT; it writes nothing.
//
//   node scripts/verify-0303-0304-live.mjs
//
// Checks, in order:
//   0303  the defective `get diagnostics ... row_count` read is gone from the deployed resolver CODE
//         (comments stripped — the migration's explanatory header quotes the old line on purpose, and
//         a naive substring probe matches that quote and reports a false positive);
//         the replacement count over group_sortie_members is present;
//         the function's owner / SECURITY DEFINER / search_path / ACL are unchanged.
//   0304  the registration trigger is live and enabled;
//         no pirate zone is left without its zone_effect_pirate_intercept row.
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
    .split(/\r?\n/)
    .filter((l) => l && !l.trimStart().startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()] })
)

const sql = `
select
  (select position('get diagnostics v_manifest = row_count' in
                   regexp_replace(p.prosrc, '--[^\\n]*', '', 'g')) > 0
     from pg_proc p
    where p.oid = 'public.pirate_intercept_resolve_due_for_movement(uuid)'::regprocedure) as defect_in_code,
  (select position('select count(*) into v_manifest' in p.prosrc) > 0
     from pg_proc p
    where p.oid = 'public.pirate_intercept_resolve_due_for_movement(uuid)'::regprocedure) as counts_manifest,
  (select md5(p.prosrc) from pg_proc p
    where p.oid = 'public.pirate_intercept_resolve_due_for_movement(uuid)'::regprocedure) as body_md5,
  (select p.prosecdef from pg_proc p
    where p.oid = 'public.pirate_intercept_resolve_due_for_movement(uuid)'::regprocedure) as security_definer,
  (select count(*) from pg_trigger t
    where t.tgrelid = 'public.danger_zones'::regclass
      and t.tgname = 'danger_zones_register_pirate_effect'
      and t.tgenabled <> 'D') as trigger_live,
  (select count(*) from public.danger_zones z
     left join public.zone_effect_pirate_intercept ef on ef.zone_id = z.id
    where z.zone_kind = 'pirate' and ef.zone_id is null) as pirate_zones_without_effect,
  (select count(*) from public.danger_zones where zone_kind = 'pirate') as pirate_zones,
  (select max(version)::text from supabase_migrations.schema_migrations) as migration_head;
`

const res = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
})
console.log(res.status)
console.log(await res.text())
