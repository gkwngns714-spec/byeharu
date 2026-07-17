// Pre-flip CANARY: proves the Supabase Management-API database/query endpoint (the path the flip
// script uses) honours ONE transaction and SURFACES a RAISE message. Run this ONCE before the flip.
// PASS = the endpoint returns an error carrying 'canary' AND no 'never' row committed.
import { readFileSync } from 'node:fs';
const env = Object.fromEntries(
  readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
    .split(/\r?\n/).filter(l => l.trim() && !l.trim().startsWith('#') && l.includes('='))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const ref = env.SUPABASE_PROJECT_REF || 'dlkbwztrdvnnjlvaydut';
const token = env.SUPABASE_ACCESS_TOKEN;
if (!token) throw new Error('no SUPABASE_ACCESS_TOKEN in .env.local');

const sql = "begin; select 1 as one; do $$ begin raise exception 'canary'; end $$; commit; select 'never' as never;";
const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
  method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
});
const body = await res.text();
const raiseSurfaced = /canary/i.test(body);
const neverRan = /never/i.test(body) && res.ok;   // if 'never' came back, the batch did NOT abort
console.log(`HTTP ${res.status}`);
console.log('body:', body.slice(0, 400));
console.log('');
if (raiseSurfaced && !neverRan) {
  console.log('✅ CANARY PASS — the endpoint surfaced the RAISE and did NOT run past it. The flip script is safe to run.');
} else {
  console.log('❌ CANARY FAIL — the endpoint did NOT behave as one transaction, or did not surface the RAISE.');
  console.log('   DO NOT run the flip via this script. Use the Supabase Dashboard SQL editor instead (it runs one txn + shows the RAISE).');
}
