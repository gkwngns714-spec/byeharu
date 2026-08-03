// THE ONE AUTHORITY for reading/writing a game_config knob from a dev tool.
//
// `scripts/set-knob.mjs` and `scripts/list-knobs.mjs` are thin front-ends over this module; every
// piece of shared behaviour (env resolution, the REST reads, the owned write, the reader census,
// the LIVE/FROZEN tier, the domain grouping) lives HERE exactly once. Do not re-inline any of it
// into a tool — that duplication is the disease this file exists to prevent.
//
// WHY THESE TOOLS EXIST. Before them the only generic knob writer was the Supabase dashboard, and
// the only scripted ones were `dev-mainship-flag.mjs` / `dev-mainship-space-movement-flag.mjs`,
// each hard-locked to ONE key (`const FLAG_KEY = … // the ONLY key this tool may write`). So
// "change a number in the game" meant either hand-editing a row in a web console with no
// type check and no confirmation read, or writing a new single-purpose script. The owner asked for
// the opposite: "easy to set for the game … the code can simply apply simple number then it will
// be done."
//
// WHY THE GUARDS ARE NOT CEREMONY. `public.set_game_config(p_key text, p_value jsonb)` is a bare
// UPSERT:
//     insert into game_config (key, value) values (p_key, p_value)
//       on conflict (key) do update set value = excluded.value, updated_at = now();
// It cannot fail on a typo — a misspelt key MINTS A NEW ROW that no reader ever looks up, and it
// writes no description. That is not hypothetical: production carries `combat_hit_variance_pct`
// = 0.5 with a NULL description and no seed anywhere in the migration chain, which is precisely
// what an UPSERT of an unversioned key leaves behind. Hence: `--create` is required to mint a key,
// and a JSON type change requires `--force`.
//
// READ-ONLY BY DEFAULT for everything except the single `set_game_config` call. Nothing here
// deletes a row, touches a table other than `game_config`, or issues DDL.

import { readFileSync, readdirSync } from 'node:fs'
import { join, extname } from 'node:path'
import { resolveEnv } from './env.mjs'

/** The columns every knob read returns. `updated_at` is what tells a hand-edit from a migration. */
export const KNOB_SELECT = 'key,value,description,updated_at'

// ── env ─────────────────────────────────────────────────────────────────────────────────────────
// `resolveEnv()` (scripts/lib/env.mjs) is the canonical `.env.local` loader — this module composes
// it rather than carrying a fourth copy of the same regex.
export function resolveKnobEnv() {
  const { env, url, serviceKey } = resolveEnv()
  if (!serviceKey) {
    console.error(
      'Missing SUPABASE_SERVICE_ROLE_KEY / SUPABASE_SERVICE_KEY / SUPABASE_SECRET_KEY in .env.local.\n' +
        'game_config is service-role-only: set_game_config is granted to postgres and service_role only.',
    )
    process.exit(2)
  }
  return {
    url,
    serviceKey,
    // OPTIONAL. Only the reader census (pg_proc introspection) needs the Management API; without
    // it the tools still read, write and confirm — they just report the tier as unknown rather
    // than guessing one.
    mgmtToken: env.SUPABASE_ACCESS_TOKEN || null,
    projectId: env.SUPABASE_PROJECT_ID || env.SUPABASE_PROJECT_REF || null,
  }
}

const headers = (ctx) => ({
  apikey: ctx.serviceKey,
  Authorization: `Bearer ${ctx.serviceKey}`,
  'Content-Type': 'application/json',
})

// ── the game_config row (PostgREST) ─────────────────────────────────────────────────────────────

/** One knob row, or null when the key does not exist. */
export async function readKnob(ctx, key) {
  const res = await fetch(
    `${ctx.url}/rest/v1/game_config?select=${KNOB_SELECT}&key=eq.${encodeURIComponent(key)}`,
    { headers: headers(ctx) },
  )
  if (!res.ok) throw new Error(`read ${key} → ${res.status} ${await res.text()}`)
  const rows = await res.json()
  return rows[0] ?? null
}

/** Every knob row, key-ordered. */
export async function readAllKnobs(ctx) {
  const res = await fetch(`${ctx.url}/rest/v1/game_config?select=${KNOB_SELECT}&order=key.asc`, {
    headers: headers(ctx),
  })
  if (!res.ok) throw new Error(`read game_config → ${res.status} ${await res.text()}`)
  return res.json()
}

/**
 * The ONLY write in this module. Goes through `public.set_game_config`, the owned writer — never a
 * direct PostgREST table write, so the tool cannot outrun whatever that function grows later.
 */
export async function writeKnob(ctx, key, value) {
  const res = await fetch(`${ctx.url}/rest/v1/rpc/set_game_config`, {
    method: 'POST',
    headers: headers(ctx),
    body: JSON.stringify({ p_key: key, p_value: value }),
  })
  if (!res.ok) throw new Error(`set_game_config(${key}) → ${res.status} ${await res.text()}`)
}

// ── values ──────────────────────────────────────────────────────────────────────────────────────

/**
 * The JSON type of a stored/candidate value, in the same vocabulary as Postgres `jsonb_typeof`, so
 * the tool's "type changed" message matches what the database would say.
 */
export function jsonTypeOf(v) {
  if (v === null) return 'null'
  if (Array.isArray(v)) return 'array'
  return typeof v === 'object' ? 'object' : typeof v
}

/**
 * Parse a command-line value into the JSON the column stores.
 *
 * Strict on purpose: `true`/`false`/`null`, a JSON number, or a JSON literal (`"text"`, `[…]`,
 * `{…}`). A BARE word is rejected rather than silently stored as a string — `set-knob mining_enabled
 * yes` writing the STRING "yes" into a boolean gate is exactly the class of accident that makes a
 * flag read false forever with no error anywhere.
 */
export function parseKnobValue(raw) {
  const s = String(raw).trim()
  if (s === '') return { error: 'empty value' }
  try {
    return { value: JSON.parse(s) }
  } catch {
    return {
      error:
        `'${raw}' is not JSON. Use true/false, a number (0.5), or a quoted JSON literal ('"text"'). ` +
        'A bare word is refused because storing it as a string would silently break a numeric or boolean read.',
    }
  }
}

// ── the reader census (Management API, READ-ONLY) ───────────────────────────────────────────────

/**
 * Run one read-only statement against production through the Management API. This is the same
 * endpoint `scripts/canary-mgmt-api.mjs` uses; it is the only way to see `pg_proc`, which PostgREST
 * does not expose (and must not — a client-visible function census is a surface, not a read).
 */
async function mgmtQuery(ctx, sql) {
  const res = await fetch(`https://api.supabase.com/v1/projects/${ctx.projectId}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${ctx.mgmtToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`management query → ${res.status} ${text.slice(0, 300)}`)
  return JSON.parse(text)
}

/**
 * key → the names of every production function whose body mentions it.
 *
 * Derived from the LIVE database, never from the migration chain: a migration is what was intended,
 * `pg_proc` is what is actually running. The two have already been proven to differ (production's
 * `worldstate_tick` reads `worldstate_pressure_decay_rate`; the migration that created it,
 * `20260617000032_worldstate_fns.sql:77`, reads `worldstate_pressure_drift_per_tick`).
 *
 * Returns null when no Management API token is configured — the caller must then report the tier as
 * unknown rather than assume one.
 */
export async function readersByKey(ctx, keys) {
  if (!ctx.mgmtToken || !ctx.projectId) return null
  const list = keys.map((k) => `(${quoteLiteral(k)})`).join(',')
  const rows = await mgmtQuery(
    ctx,
    `with keys(k) as (values ${list})
     select k.k as key,
            coalesce((select string_agg(p.proname, ', ' order by p.proname)
                        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname not in ('pg_catalog','information_schema')
                         and strpos(p.prosrc, k.k) > 0), '') as fns
       from keys k`,
  )
  const out = new Map()
  for (const r of rows) out.set(r.key, r.fns ? r.fns.split(', ') : [])
  return out
}

function quoteLiteral(s) {
  if (!/^[A-Za-z0-9_]+$/.test(s)) throw new Error(`refusing to inline a non-identifier key: ${s}`)
  return `'${s}'`
}

// ── the LIVE / FROZEN tier ──────────────────────────────────────────────────────────────────────
//
// Combat does not read most of its knobs when it needs them; it SNAPSHOTS them into `combat_units`
// and stops looking. Change one of those and the fight on screen is unaffected — the new value
// appears at the next encounter, or the next wave. An owner who does not know that will change a
// number, watch nothing happen, and change it again.
//
// The two snapshot sites, both cited from the migration that documents them:
//   • ENCOUNTER CREATION — `combat_create_group_encounter` freezes its reads into
//     combat_units.weapons_json / .move_speed / .pos_x / .pos_y
//     (`supabase/migrations/20260618000301_intercept_fires_at_zone_entry.sql:791-802`; the whole
//      consumer map is written out at `…20260618000316_combat_five_times_tighter.sql:143-147`).
//   • WAVE SPAWN — `process_combat_ticks` builds the enemy row once per wave and freezes these
//     stats into it (`…20260618000299_combat_card_reports_true_power.sql:694-708` resolved arm,
//     `:756-760` synthetic arm; consumer map at `…0316:139-142`). Its OTHER reads (pacing,
//     variance, rewards, retreat delay) are genuinely per-tick and stay LIVE.
//
// FROZEN_AT_WAVE is the one list here that is not derived from the database. It must be re-derived
// if that wave-spawn arm ever changes shape — which is why every tier report also prints the actual
// reader functions found in production, so the evidence is always visible next to the verdict.
const ENCOUNTER_BUILDER = 'combat_create_group_encounter'
const COMBAT_TICK = 'process_combat_ticks'
const FROZEN_AT_WAVE = new Set([
  'enemy_synthetic_range_base',
  'enemy_synthetic_range_per_difficulty',
  'enemy_synthetic_speed_base',
  'enemy_synthetic_speed_per_difficulty',
  'enemy_synthetic_projectile_speed',
  'enemy_synthetic_cooldown_seconds',
  'enemy_synthetic_max_units',
  'enemy_hp_base',
  'enemy_hp_danger_scale',
  'enemy_attack_base',
  'enemy_attack_danger_scale',
  'defense_curve_base',
])

/**
 * { tier, note } for one key, from its production readers plus its client references.
 *
 * `readers` may be null (no Management API token) — the tier is then reported as UNKNOWN, not
 * guessed.
 */
export function tierOf(key, readers, clientRefs) {
  if (readers === null) {
    return { tier: 'UNKNOWN', note: 'no SUPABASE_ACCESS_TOKEN — production readers were not inspected' }
  }
  const fns = readers ?? []
  if (FROZEN_AT_WAVE.has(key)) {
    return {
      tier: 'FROZEN (next wave)',
      note: `${COMBAT_TICK} freezes this into the enemy combat_units row when a wave spawns — a fight already running keeps the old value until its next wave.`,
    }
  }
  if (fns.length === 1 && fns[0] === ENCOUNTER_BUILDER) {
    return {
      tier: 'FROZEN (next fight)',
      note: `${ENCOUNTER_BUILDER} freezes this into combat_units at encounter creation — the fight on screen keeps the old value; the next one uses the new.`,
    }
  }
  if (fns.length === 0) {
    return clientRefs.length > 0
      ? { tier: 'LIVE (client only)', note: `no production function reads this; the client does (${clientRefs.join(', ')}) — it bites on the next page load.` }
      : { tier: 'DEAD', note: 'no production function and no file under src/ reads this key — writing it changes nothing.' }
  }
  return { tier: 'LIVE', note: `read at each call by: ${fns.join(', ')}` }
}

// ── client references ───────────────────────────────────────────────────────────────────────────

/**
 * Which files under `src/` mention a key. Half the knobs in this game are client-read
 * (`mainship_space_movement_enabled` → `src/lib/catalog.ts:115`, `dev_zone_editor_enabled` →
 * `src/lib/catalog.ts:143`), so a DEAD verdict that only consulted `pg_proc` would be wrong.
 */
export function clientRefsByKey(repoRoot, keys) {
  const wanted = new Set(keys)
  const out = new Map(keys.map((k) => [k, []]))
  for (const file of walk(join(repoRoot, 'src'))) {
    let text
    try {
      text = readFileSync(file, 'utf8')
    } catch {
      continue
    }
    for (const k of wanted) {
      if (text.includes(k)) {
        const line = text.split(/\r?\n/).findIndex((l) => l.includes(k)) + 1
        out.get(k).push(`${file.slice(repoRoot.length + 1).replace(/\\/g, '/')}:${line}`)
      }
    }
  }
  return out
}

function* walk(dir) {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const e of entries) {
    const p = join(dir, e.name)
    if (e.isDirectory()) yield* walk(p)
    else if (['.ts', '.tsx'].includes(extname(e.name))) yield p
  }
}

// ── domains ─────────────────────────────────────────────────────────────────────────────────────

/**
 * The grouping `list-knobs` prints. Derived from the key's own prefix — the game already names its
 * knobs `combat_*`, `enemy_*`, `mining_*`, so the names ARE the taxonomy and inventing a second one
 * would be a second authority that drifts the first time somebody adds a key.
 */
export function domainOf(key) {
  const head = key.split('_')[0]
  const merged = {
    enemy: 'combat',
    spatial: 'combat',
    per: 'combat',
    pirate: 'combat',
    danger: 'combat',
    shield: 'combat',
    defense: 'combat',
    wave: 'combat',
    retreat: 'combat',
    encounter: 'combat',
    mainship: 'movement',
    fleet: 'movement',
    travel: 'movement',
    min: 'movement',
    max: 'movement',
    movement: 'movement',
    launch: 'movement',
    timed: 'movement',
    port: 'economy',
    trade: 'economy',
    market: 'economy',
    salvage: 'economy',
    repair: 'economy',
    shipyard: 'economy',
    haul: 'economy',
    station: 'economy',
    starting: 'economy',
    reward: 'economy',
    blueprint: 'economy',
    module: 'ships',
    ship: 'ships',
    captain: 'ships',
    hull: 'ships',
    typed: 'world',
    zone: 'world',
    worldstate: 'world',
    world: 'world',
    location: 'world',
    territory: 'world',
    dev: 'dev',
  }
  return merged[head] ?? head
}
