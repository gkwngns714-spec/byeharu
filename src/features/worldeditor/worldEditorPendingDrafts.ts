// WORLD EDITOR — V5: the PURE cross-domain PENDING-DRAFTS selector. Draft-store views in → one
// {total, byDomain} summary out. This is the ONE authority for "how much unpublished authoring work is
// sitting across ALL four domains", so the shell shows a single compact indicator instead of the owner
// having to open each domain panel to remember what they started. Pure DERIVED/READ-ONLY VIEW state: it
// NEVER mutates a store, writes no draft, triggers NO publish/discard, and issues no IO — it reads only
// the `drafts` array each already-mounted store exposes (the SAME DraftsStore.drafts the panels render).
// No React, no DOM, no fetch: unit-tested directly (tests/worldEditorPendingDrafts.spec.ts).
//
// HONEST DEFINITION OF "PENDING" (§WE.2): publish does NOT exist in the draft layer — every draft in a
// store is by construction a LOCAL, UNPUBLISHED authoring intent (draftTypes.ts), and discard is the
// ONLY way a draft leaves the store. So "pending for a domain" is exactly "a draft is present in that
// domain's store" — `store.drafts.length`. We never fabricate a published/dirty distinction the store
// doesn't carry: a create draft with no edits is still unpublished work the owner should not lose track
// of. (Dirtiness/staleness are SEPARATE advisory notions the panels already surface per draft.)

/** The four live authoring domains — the ONE ordered authority the summary + the tab dots share (same
 *  registry order the map/filter use: locations → mining → exploration → zones). */
export const PENDING_DRAFT_DOMAINS = ['locations', 'mining', 'exploration', 'zones'] as const
export type PendingDraftDomain = (typeof PENDING_DRAFT_DOMAINS)[number]

/** The MINIMAL shape this selector reads from a domain's draft store — just its current draft list.
 *  The real DraftsStore<…> satisfies this structurally (its `drafts: readonly Draft[]`), so the shell
 *  passes the live stores straight in with zero adapter. Kept `unknown[]` on purpose: the count never
 *  inspects a draft's payload — it only asks "is a draft present?". */
export interface DomainDraftsView {
  readonly drafts: readonly unknown[]
}

/** The cross-domain roll-up: the grand total of pending drafts + the per-domain breakdown (every domain
 *  key ALWAYS present, 0 when empty — so the shell can index it without a fallback). */
export interface PendingDraftsSummary {
  readonly total: number
  readonly byDomain: Record<PendingDraftDomain, number>
}

/** The ONE selector: sum each domain store's present drafts into {total, byDomain}. Pure — reads only
 *  `.drafts.length`, mutates nothing, keeps ALL four domain keys (0 when a store is empty). Default
 *  zero-drafts state yields `{ total: 0, byDomain: {…: 0} }` so the shell renders NO intrusive badge. */
export function pendingDraftsSummary(
  stores: Record<PendingDraftDomain, DomainDraftsView>,
): PendingDraftsSummary {
  const byDomain = {} as Record<PendingDraftDomain, number>
  let total = 0
  for (const domain of PENDING_DRAFT_DOMAINS) {
    const count = stores[domain].drafts.length
    byDomain[domain] = count
    total += count
  }
  return { total, byDomain }
}

/** The domains that currently hold at least one pending draft, in registry order (drives the tab dots
 *  and the "jump" target set). Empty when nothing is pending. */
export function pendingDomains(summary: PendingDraftsSummary): PendingDraftDomain[] {
  return PENDING_DRAFT_DOMAINS.filter((d) => summary.byDomain[d] > 0)
}

/** The NEXT domain with pending drafts to jump to from `current`, cycling in registry order (so
 *  repeated clicks on the indicator walk through every domain that has unpublished work). Skips
 *  `current` itself when other domains have pending work, but returns `current` if it is the ONLY
 *  domain with pending drafts, and `null` when nothing is pending. PURE navigation TARGET only — it
 *  never switches anything; the shell feeds the result to the existing domain-switch. */
export function nextPendingDomain(
  summary: PendingDraftsSummary,
  current: PendingDraftDomain,
): PendingDraftDomain | null {
  const pending = pendingDomains(summary)
  if (pending.length === 0) return null
  const startIndex = PENDING_DRAFT_DOMAINS.indexOf(current)
  // walk the ordered ring AFTER current; the first pending domain we meet (possibly current itself,
  // met last) is the target.
  for (let step = 1; step <= PENDING_DRAFT_DOMAINS.length; step++) {
    const domain = PENDING_DRAFT_DOMAINS[(startIndex + step) % PENDING_DRAFT_DOMAINS.length]
    if (summary.byDomain[domain] > 0) return domain
  }
  return null
}
