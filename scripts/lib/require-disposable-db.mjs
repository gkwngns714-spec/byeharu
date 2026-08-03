// THE ONE AUTHORITY for "this verifier may not point at the live game."
//
// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────────
// Six verifiers shrink the global travel knobs so a round trip finishes in seconds instead of
// minutes:
//
//   set_game_config('travel_scale', 0.001)      -- a journey takes 1/1000th of its real time
//   set_game_config('min_travel_seconds', 2)
//
// `game_config` is GLOBAL. Those two writes do not scope to the test user — they change how far every
// fleet in the game travels per second, for everyone. Each script restores the captured originals in
// a `finally`, which covers a thrown exception and nothing else: a Ctrl-C, a cancelled workflow, a
// killed container, a lost network at the wrong moment, or a pre-capture that quietly returned
// `undefined` (every one of these scripts skips the restore for an uncaptured value) all end with the
// override still committed. The result on a ~30-player production database is that every trip becomes
// instantaneous, permanently, with no alarm anywhere — and the audit that produced this module found
// movement rows on production whose arithmetic is only possible under those values. These scripts
// have already run against the live game.
//
// ── WHY A HARD REFUSAL, AND NOT A BETTER `finally` ──────────────────────────────────────────────
// Because a better `finally` cannot be honest. Node can trap `SIGINT`/`SIGTERM`/`uncaughtException`,
// but it cannot trap `SIGKILL`, a hard reset, or a runner that vanishes — so any wrapper would be
// best-effort while READING as a guarantee, and claiming a safety that does not hold is worse than
// the bug. The guarantee has to come from the target, not from the cleanup path.
//
// And once the target can only be a throwaway database, the restore path stops being a safety
// mechanism at all: a disposable Postgres left with `travel_scale = 0.001` is destroyed minutes
// later and harms nobody. One guard replaces every crash handler that would otherwise be needed —
// and it covers the OTHER global writes these scripts make (feature flags, signed-up users,
// commissioned ships), not just the two travel knobs.
//
// ── WHAT COUNTS AS DISPOSABLE ───────────────────────────────────────────────────────────────────
// A local `supabase start` stack (http://127.0.0.1:54321 by default), or a Supabase reachable on a
// loopback/private address. A hosted project — anything on *.supabase.co / *.supabase.in or any
// public host — is refused.
//
// ── NO ENVIRONMENT-VARIABLE ESCAPE HATCH, DELIBERATELY ──────────────────────────────────────────
// An `ALLOW_LIVE_DB=1` style override would be set once in a workflow and the hole would be back,
// silently, exactly as `grant execute … to authenticated` on send_fleet_to_location survived twenty
// migrations by being copied forward. Pointing one of these verifiers at a hosted project has to be
// an edit to a tracked file that a human reads.

const PRIVATE_V4 =
  /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/

/** true for a loopback / link-local / RFC1918 host, or a docker-style local hostname. */
function isLocalHost(hostname) {
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, '')
  if (h === 'localhost' || h === '::1' || h === '0.0.0.0') return true
  if (h.endsWith('.localhost') || h.endsWith('.local') || h.endsWith('.internal')) return true
  if (h === 'host.docker.internal' || h === 'kong' || h === 'supabase_kong') return true
  return PRIVATE_V4.test(h)
}

/**
 * Exit(2) unless `url` is a disposable Supabase. Call it BEFORE the first write of any kind.
 * @param {string|undefined} url    the target Supabase URL (VITE_SUPABASE_URL)
 * @param {string} scriptName       for the message, e.g. 'verify-mainship-move'
 */
export function requireDisposableTarget(url, scriptName) {
  let host
  try {
    host = new URL(url).hostname
  } catch {
    console.error(`✖ ${scriptName}: VITE_SUPABASE_URL is not a URL (${url ?? '<unset>'}).`)
    process.exit(2)
  }
  if (isLocalHost(host)) return

  console.error(`
✖ ${scriptName} REFUSES TO RUN against ${host}.

  This verifier writes GLOBAL game_config (travel_scale / min_travel_seconds and feature flags),
  signs up real auth users and commissions ships. game_config is not scoped to a test player: while
  it runs, EVERY fleet in the game travels 1000x faster, and if the process dies before its restore
  step the override stays committed with nothing to notice it.

  Point it at a disposable database and run it again:

      supabase start
      VITE_SUPABASE_URL=http://127.0.0.1:54321 \\
      VITE_SUPABASE_ANON_KEY=<local anon key> \\
      SUPABASE_SERVICE_ROLE_KEY=<local service key> \\
      npm run <the verify script>

  There is no environment-variable override on purpose — see scripts/lib/require-disposable-db.mjs.
`)
  process.exit(2)
}
