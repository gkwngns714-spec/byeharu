// Management-API runner for an activation .sql (this machine has no jq/psql, so the house .sh's
// curl+jq path can't run — this is the node equivalent, the run-activation pattern). POSTs the
// WHOLE file as ONE query (the canary proved the endpoint runs it as one transaction + surfaces
// RAISE). Usage: node run-activation.mjs <path-to-.sql>
import { readFileSync } from 'node:fs';
const sqlPath = process.argv[2];
if (!sqlPath) throw new Error('usage: node run-activation.mjs <path-to-.sql>');
const env = Object.fromEntries(
  readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
    .split(/\r?\n/).filter(l => l.trim() && !l.trim().startsWith('#') && l.includes('='))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const ref = env.SUPABASE_PROJECT_REF || 'dlkbwztrdvnnjlvaydut';
const token = env.SUPABASE_ACCESS_TOKEN;
if (!token) throw new Error('no SUPABASE_ACCESS_TOKEN in .env.local');

const sql = readFileSync(sqlPath, 'utf8');

const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
  method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
});
const body = await res.text();
console.log(`HTTP ${res.status}`);
console.log(body.slice(0, 1200));
console.log('');
if (res.ok) console.log('✅ ACT COMMITTED — the endpoint accepted the whole transaction. Verify the resulting state next.');
else console.log('⛔ ACT DID NOT COMMIT — a precondition or the sweep RAISEd (message above). Nothing changed; fix the named cause and re-run.');
