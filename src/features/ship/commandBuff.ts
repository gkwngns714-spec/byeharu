import { strictConfigFlag, type GameConfigFoldRow } from '../../lib/gameConfigFold'
import { traitEffects, type TraitEffect } from './shipTraits'

// COMMAND-BUFFS (0205) — PURE view logic for the ship-dossier COMMAND BUFF line (no React/DOM/fetch
// — the shipTraits.ts mold). Specs: tests/commandBuff.spec.ts.
//
// SERVER TRUTH, display only: a ship's command buff is its STORED command_buff_id (rolled once at
// commission, immutable — 0205's NULL-guarded roll writer) joined against the public-read
// command_buff_types catalog. The client never re-derives the roll — only the join of what the
// server stored. The stat numbers rendered are the catalog's stats_json verbatim (the same
// input-vocabulary hunks the 0205 adapter folds server-side). The buff is DORMANT until the ship is
// its fleet's FIRST ACTIVE command ship AND command_buffs_enabled is lit — the dossier says so in
// copy. ONE buff per fleet (owner decision 2026-07-16): the server folds only the first command
// ship's buff (order by created_at, main_ship_id — limit 1), so a second command ship's buff adds
// NOTHING. This module renders a ship's OWN rolled buff regardless — whether it is currently the
// one that applies is a fleet-level question the dossier's copy explains rather than computing here
// (the client never re-derives a server fold).
//
// DARK (command_buffs_enabled — seeded false, 0205): the fold below is the ONE strict jsonb-true
// coercion (strictConfigFlag — shared with the trait / commission / salvage folds, never a re-copy).
// Anything but jsonb true (absent row, 'true' the string, failed read → []) reads as dark and the
// dossier renders byte-identical to today.
//
// EFFECT FORMATTER REUSE: a command buff speaks the SAME shared input vocabulary as a ship trait, so
// the stat-effect labels reuse traitEffects verbatim (ONE formatter — no second copy). A buff has no
// hp_mult, so hpMult is passed as 1 (which appends no hull line).

/** True ⇔ game_config.command_buffs_enabled is strictly jsonb `true` (else DARK, fail-closed). */
export function commandBuffsEnabledFromConfig(rows: GameConfigFoldRow[]): boolean {
  return strictConfigFlag(rows, 'command_buffs_enabled')
}

/** One command_buff_types catalog row (Reference/Config, public-read — 0205). */
export interface CommandBuffTypeRow {
  buff_id: string
  tier: string
  name: string
  description: string
  stats_json: unknown
}

/** The dossier's displayable command buff, or a fail-closed unknown-id shape. */
export type CommandBuffCard =
  | {
      kind: 'buff'
      buff_id: string
      tier: string
      name: string
      description: string
      effects: TraitEffect[]
    }
  // FAIL-CLOSED join miss: a stored command_buff_id absent from the catalog read (a catalog grown /
  // read raced) renders a muted 'unknown buff' line — server truth must not vanish, but the client
  // never invents a name for it (and never crashes).
  | { kind: 'unknown'; buff_id: string }

/**
 * Join a ship's stored command_buff_id against the catalog. null when the ship carries no buff
 * (buff_id null — an unrolled ship or a tier with no pool): the dossier then hides the line, never
 * invents a buff. A non-null id absent from the catalog → the muted unknown card (fail closed).
 */
export function shipCommandBuffCard(
  buffId: string | null | undefined,
  catalog: CommandBuffTypeRow[],
): CommandBuffCard | null {
  if (buffId == null || buffId === '') return null
  const t = catalog.find((b) => b.buff_id === buffId)
  if (!t) return { kind: 'unknown', buff_id: buffId }
  return {
    kind: 'buff',
    buff_id: t.buff_id,
    tier: t.tier,
    name: t.name,
    description: t.description,
    // a command buff carries no hp_mult — pass 1 so the shared formatter appends no hull line.
    effects: traitEffects(t.stats_json, 1),
  }
}
