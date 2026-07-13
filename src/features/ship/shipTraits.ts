import { strictConfigFlag, type GameConfigFoldRow } from '../../lib/gameConfigFold'

// SOUL-2 — PURE view logic for the ship-dossier TRAITS section (no React/DOM/fetch — the
// shipDossierView.ts / salvageMarket.ts mold). Specs: tests/shipTraits.spec.ts.
//
// SERVER TRUTH, display only: a ship's traits are its STORED main_ship_traits rows (rolled once,
// immutable — 0186's insert-only writer) joined against the public-read ship_trait_types catalog.
// The client never re-derives a roll — no hashing, no catalog indexing, only the join of what the
// server stored. The stat numbers rendered are the catalog's stats_json verbatim (the same
// input-vocabulary hunks the 0193 adapter folds server-side); the folded RESULT already shows in
// the dossier's stats strip — this section shows the WHY.
//
// DARK (ship_traits_enabled — seeded false, 0186): the fold below is the ONE strict jsonb-true
// coercion (strictConfigFlag — shared with the commission/salvage folds, never a re-copy).
// Anything but jsonb true (absent row, 'true' the string, failed read → []) reads as dark and the
// dossier renders byte-identical to today.

/** True ⇔ game_config.ship_traits_enabled is strictly jsonb `true` (else DARK, fail-closed). */
export function shipTraitsEnabledFromConfig(rows: GameConfigFoldRow[]): boolean {
  return strictConfigFlag(rows, 'ship_traits_enabled')
}

// ── row shapes (the 0186 columns; numeric may arrive as a string over PostgREST) ─────────────────

/** One ship_trait_types catalog row (Reference/Config, public-read — 0186). */
export interface ShipTraitTypeRow {
  trait_type_id: string
  name: string
  description: string
  stats_json: unknown
  hp_mult: number | string
}

/** One main_ship_traits instance row (owner-read via the ship join — 0186). */
export interface MainShipTraitRow {
  slot: number
  trait_type_id: string
}

// ── stat-effect formatter (stats_json → signed display labels) ───────────────────────────────────
// The trait catalog speaks the ONE shared input stat vocabulary (0180 adapter / 0186 seed pin:
// attack/defense/repair/cargo/scan/mining/evasion + speed_mult_bonus). Flat keys render as signed
// integers ('+6 attack'); speed_mult_bonus is a MULTIPLIER bonus and renders as a signed percent
// ('+8% speed'); hp_mult renders as '+8% hull' only when ≠ 1 (1.0 = no birthmark on the hull).
// Zero / non-numeric / non-finite values are SKIPPED (a zero effect is no effect; a malformed
// value must never crash or render NaN). A key outside the vocabulary still renders honestly
// (underscores → spaces — the TeamPreviewSection statLabel idiom): the server's stored truth
// outranks this map's completeness.

/** One displayable stat effect; tone drives the green/red token (positive = a buff). */
export interface TraitEffect {
  label: string
  tone: 'positive' | 'negative'
}

/** The shared input vocabulary in its pinned display order (0180:212–219 / the 0186 key pin). */
const STAT_KEY_ORDER = ['attack', 'defense', 'repair', 'cargo', 'scan', 'mining', 'evasion', 'speed_mult_bonus'] as const

/** Signed percent string for a multiplier delta ('+8%', '-4%'); one decimal max, never float
 *  noise. null when the delta ROUNDS to 0 — a '+0%' token is the zero-effect shape wearing a
 *  sign, so it takes the same skip path as a flat 0 (spec-pinned). */
const signedPercent = (delta: number): string | null => {
  const pct = Math.round(delta * 1000) / 10
  if (pct === 0) return null
  return `${pct > 0 ? '+' : ''}${pct}%`
}

const signedFlat = (v: number): string => `${v > 0 ? '+' : ''}${v}`

/** Effects for one trait: stats_json entries in pinned vocabulary order (unknown keys after,
 *  sorted), then the hp_mult hull line. Malformed shapes collapse to [] — never a throw. */
export function traitEffects(statsJson: unknown, hpMult: number | string): TraitEffect[] {
  const effects: TraitEffect[] = []
  if (typeof statsJson === 'object' && statsJson !== null && !Array.isArray(statsJson)) {
    const stats = statsJson as Record<string, unknown>
    const known: string[] = STAT_KEY_ORDER.filter((k) => k in stats)
    const unknown = Object.keys(stats)
      .filter((k) => !(STAT_KEY_ORDER as readonly string[]).includes(k))
      .sort((a, b) => a.localeCompare(b, 'en')) // deterministic — never jsonb key order
    for (const key of [...known, ...unknown]) {
      const v = stats[key]
      if (typeof v !== 'number' || !Number.isFinite(v) || v === 0) continue // zero effect = no effect
      if (key === 'speed_mult_bonus') {
        const pct = signedPercent(v)
        if (pct === null) continue // rounds to 0% → the zero-skip path (never a '+0%' token)
        effects.push({ label: `${pct} speed`, tone: v > 0 ? 'positive' : 'negative' })
      } else {
        effects.push({ label: `${signedFlat(v)} ${key.replace(/_/g, ' ')}`, tone: v > 0 ? 'positive' : 'negative' })
      }
    }
  }
  // hp_mult (numeric → possibly a string over PostgREST): a hull birthmark only when ≠ 1. The
  // sub-1 branch renders '-N% hull' (danger tone) — unreachable today (hp_mult >= 1.0 by the
  // 0186 CHECK) but pinned anyway so a relaxed CHECK can never render a debuff in green.
  const mult = Number(hpMult)
  if (Number.isFinite(mult) && mult !== 1 && mult > 0) {
    const delta = mult - 1
    const pct = signedPercent(delta)
    if (pct !== null) effects.push({ label: `${pct} hull`, tone: delta > 0 ? 'positive' : 'negative' })
  }
  return effects
}

// ── the traits view-model (instance rows × catalog, slot order) ──────────────────────────────────

export type ShipTraitCard =
  | {
      kind: 'trait'
      slot: number
      trait_type_id: string
      name: string
      description: string
      effects: TraitEffect[]
    }
  // FAIL-CLOSED join miss: a stored trait_type_id absent from the catalog read (a catalog grown/
  // read raced) renders a muted 'unknown trait' line — the row is server truth and must not
  // vanish, but the client never invents a name for it (and never crashes).
  | { kind: 'unknown'; slot: number; trait_type_id: string }

/** Join a ship's stored trait rows against the catalog, ordered by slot ascending. */
export function shipTraitCards(rows: MainShipTraitRow[], catalog: ShipTraitTypeRow[]): ShipTraitCard[] {
  const byId = new Map(catalog.map((t) => [t.trait_type_id, t]))
  return [...rows]
    .sort((a, b) => a.slot - b.slot)
    .map((row): ShipTraitCard => {
      const t = byId.get(row.trait_type_id)
      if (!t) return { kind: 'unknown', slot: row.slot, trait_type_id: row.trait_type_id }
      return {
        kind: 'trait',
        slot: row.slot,
        trait_type_id: t.trait_type_id,
        name: t.name,
        description: t.description,
        effects: traitEffects(t.stats_json, t.hp_mult),
      }
    })
}
