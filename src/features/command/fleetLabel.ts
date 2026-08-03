// THE ONE WAY A FLEET IS NAMED ON SCREEN.
//
// ── THE DEFECT ─────────────────────────────────────────────────────────────────────────────────────
// Four map-badge resolvers each built their label as `Fleet ${name}`. The owner's teams are actually
// NAMED "Fleet 1", "Fleet 2" (upsert_ship_group takes a free-text name and that is what was typed),
// so the map read "Fleet Fleet 2" — live, on screen, for months. Four copies of one prefix rule is
// also four places to fix it, which is the shape the anti-spaghetti law exists to stop; the fix is
// one function, composed four times, not four edits.
//
// PURE. It does not rename anything: `ship_groups.name` stays the server's, untouched. This decides
// only whether the word "Fleet" needs adding to it before it is shown.

/** Does this name already announce itself as a fleet? Leading article/whitespace tolerated so
 *  "the Fleet", " fleet 2" and "FLEET 2" all count; a name that merely CONTAINS the word later
 *  ("Ghost Fleet") does not, because "Fleet Ghost Fleet" is the wrong repair for it — that name
 *  reads correctly with the prefix and would read oddly without one. */
const ALREADY_A_FLEET = /^\s*(?:the\s+)?fleet\b/i

/**
 * The player-facing name of a fleet: the group's own name when it already says "Fleet", otherwise
 * that name with the word in front. An empty/blank name falls back to the bare word rather than
 * rendering a dangling "Fleet " with nothing after it.
 */
export function fleetLabel(name: string | null | undefined): string {
  const trimmed = (name ?? '').trim()
  if (!trimmed) return 'Fleet'
  return ALREADY_A_FLEET.test(trimmed) ? trimmed : `Fleet ${trimmed}`
}
