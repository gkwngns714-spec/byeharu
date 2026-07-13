// THE strict game_config boolean fold — extracted (SOUL-2) so a new gate never re-writes the
// `byKey.get(flag) === true` line again. Adopted by commissionContextFromConfig (commissionShip.ts)
// and the SOUL-2 fold (shipTraits.ts). FOUR copies remain for the consolidation follow-up (the
// salvage/shipyard files were under the in-flight PR #137 this slice — refactoring them here
// would have manufactured a merge conflict):
//   · salvageConfigFromRows           (features/port/salvageMarket.ts)
//   · the SHIPYARD-3 config fold      (features/port/shipyard.ts — landed with #137)
//   · fetchMainshipSendEnabled        (lib/catalog.ts:52 — the single-flag maybeSingle shape)
//   · fetchMainshipSpaceMovementEnabled (lib/catalog.ts:66 — same maybeSingle shape)
// PURE (no React/DOM/fetch — safe for the pure spec battery).
//
// Semantics (the commissionContextFromConfig posture, verbatim): game_config.value is jsonb and
// the activation scripts write jsonb `true` via set_game_config — ONLY jsonb true reads as lit.
// Anything else fails CLOSED to dark: absent row, jsonb 'true' the STRING, jsonb 1, a failed
// config read collapsed to [] by its API wrapper. The client mirror can never be more permissive
// than the server, which gates its own functions on the same flag (cfg_bool) FIRST.

/** One public-read game_config row (0003: public-read RLS + select grant to anon/authenticated). */
export interface GameConfigFoldRow {
  key: string
  value: unknown
}

/** Strict boolean fold: true ⇔ the key's row exists AND its jsonb value is exactly `true`.
 *  LAST-WINS on a duplicate key (the Map fold — byte-equivalent to the commission original on
 *  every input shape). key is a PK so duplicates are unreachable today, but an any-true-wins
 *  scan would diverge fail-OPEN on that shape, and a gate helper must never carry a fail-open
 *  branch (spec-pinned in tests/shipTraits.spec.ts). */
export function strictConfigFlag(rows: GameConfigFoldRow[], key: string): boolean {
  return new Map(rows.map((r) => [r.key, r.value])).get(key) === true
}
