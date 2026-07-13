// THE strict game_config boolean fold — extracted (SOUL-2) so a new gate never re-writes the
// `byKey.get(flag) === true` line again. Adopted by commissionContextFromConfig (commissionShip.ts),
// the SOUL-2 fold (shipTraits.ts), and — via the CONFIGFOLD follow-up — salvageConfigFromRows
// (features/port/salvageMarket.ts) and shipyardConfigFromRows (features/port/shipyard.ts). This is
// now the SOLE array/last-wins fold implementation.
//
// NOT routed through here (a deliberate honesty call, not an oversight):
//   · fetchMainshipSendEnabled          (lib/catalog.ts — the single-flag maybeSingle shape)
//   · fetchMainshipSpaceMovementEnabled (lib/catalog.ts — same maybeSingle shape)
// Both do a bare `data?.value === true` on a row the QUERY already keyed (`.select('value')
// .eq('key', …).maybeSingle()`) — there is no array and no `key` column to fold over. Forcing them
// through strictConfigFlag would mean fabricating a synthetic `[{ key, value }]` row (re-attaching
// the key the query already filtered on) — MORE code and indirection than the one-liner, and a
// naive `[data]` wrap would silently fail dark (the row carries no `key`, so the Map keys on
// undefined). The strict `=== true` semantics there are already identical; leaving them is the
// less-code call. PURE (no React/DOM/fetch — safe for the pure spec battery).
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
