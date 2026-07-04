// Shared verify-script harness — THE CANONICAL COPY of the three blocks every `verify-*.mjs`
// script had been carrying inline (exploration cleanup, finding #2):
//   1. `loadEnv()` / `resolveEnv()` — .env.local loader + URL/key resolution (anon required,
//      service key optional here; a verifier that REQUIRES the service key asserts that itself);
//   2. the reporting harness — `createReporter()` (ok/bad + pass/fail counts) and `Abort`/`die`;
//   3. `createUserFactory()` — the throwaway-signup `newUser(tag)` helper (tracks each created
//      user id immediately for finally-teardown via ./verifier-teardown.mjs).
//
// ADOPTION / RETIREMENT PLAN for the remaining duplication: of the 27 `scripts/verify-*.mjs`
// scripts, 7 now import this module (captain, captain-progression, exploration, fitting, mining,
// modules, ranking) and the remaining 20 still carry inline copies of these blocks — those 20 MUST
// adopt this module the next time each is meaningfully touched (the documented `osn_distance`
// adopt-on-next-real-change precedent, `docs/SYSTEM_BOUNDARIES.md:101–104` — the "OSN geometry leaf"
// note; the "should adopt the helper" sentence is `:103–104`). New verifiers import from here from
// day one; never add a fresh inline copy. Retirement condition: this plan is discharged when all 27
// import the harness (adopter count reaches 27 / remaining reaches 0).

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'

// .env.local-style file loader (tolerant: missing file → {}).
export function loadEnv(p) {
  const e = {}
  try {
    for (const l of readFileSync(p, 'utf8').split('\n')) {
      const m = l.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/)
      if (m) e[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '')
    }
  } catch {}
  return e
}

// Standard env resolution: .env.local overlaid by process.env; URL + anon key are required
// (exit 2 — the shared "misconfigured, not failed" exit code); the service key is OPTIONAL
// at this layer.
export function resolveEnv() {
  const env = { ...loadEnv('.env.local'), ...process.env }
  const url = env.VITE_SUPABASE_URL
  const anonKey = env.VITE_SUPABASE_ANON_KEY
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
  if (!url || !anonKey) { console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY'); process.exit(2) }
  return { env, url, anonKey, serviceKey }
}

// Reporting harness: Abort ends the run early through the caller's catch; die throws it.
export class Abort extends Error {}
export const die = (m) => { throw new Abort(m) }

// ok/bad line printers sharing one pass/fail count (read `counts` for the final summary).
export function createReporter() {
  const counts = { pass: 0, fail: 0 }
  return {
    counts,
    ok: (n) => { console.log('  ✓', n); counts.pass++ },
    bad: (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); counts.fail++ },
  }
}

// Throwaway-signup factory. Each verifier supplies its own email prefix and its
// createdUserIds array (ids are pushed immediately after creation so the finally-teardown
// sees every user even if a later step dies).
export function createUserFactory({ url, anonKey, emailPrefix, createdUserIds }) {
  return async function newUser(tag) {
    const c = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
    const { data: su, error } = await c.auth.signUp({ email: `${emailPrefix}.${tag}.${Date.now()}@example.com`, password: 'Test123456!' })
    if (error) die(`signup failed: ${error.message}`)
    if (!su.session) die('no session — email confirmation still ON')
    createdUserIds.push(su.user.id)   // track immediately after creation for finally cleanup
    return { client: c, userId: su.user.id }
  }
}
