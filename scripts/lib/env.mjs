// THE canonical `.env.local` loader for every Node script in scripts/.
//
// Split out of `verify-harness.mjs` so that reading two environment variables does not require
// `@supabase/supabase-js`. The harness imports the Supabase client at module scope, so ANY importer
// of it — including a tool that only needs a URL and a key to call `fetch` — could not run without
// `node_modules` installed. `scripts/set-knob.mjs` and `scripts/list-knobs.mjs` must work in a bare
// checkout, so the env block moved here and the harness now re-exports it.
//
// There is still exactly ONE copy of this logic; `verify-harness.mjs` re-exports these two symbols
// so its existing importers are unchanged. Never re-inline it anywhere.

import { readFileSync } from 'node:fs'

/** .env.local-style file loader (tolerant: missing file → {}). */
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

/**
 * Standard env resolution: .env.local overlaid by process.env; URL + anon key are required
 * (exit 2 — the shared "misconfigured, not failed" exit code); the service key is OPTIONAL
 * at this layer.
 */
export function resolveEnv() {
  const env = { ...loadEnv('.env.local'), ...process.env }
  const url = env.VITE_SUPABASE_URL
  const anonKey = env.VITE_SUPABASE_ANON_KEY
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY || env.SUPABASE_SECRET_KEY
  if (!url || !anonKey) { console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY'); process.exit(2) }
  return { env, url, anonKey, serviceKey }
}
