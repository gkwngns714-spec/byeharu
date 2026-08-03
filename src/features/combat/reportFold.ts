// REPORT-FOLD — the pure open/closed policy for report rows (owner order 2026-08-03: reports
// "separate … and foldable"). No React/DOM; pinned by tests/reportFold.spec.ts.
//
// THE DEFAULT, and why: the NEWEST report starts open, every older one starts collapsed. The
// player opening the reports card is almost always asking "how did my last fight go?" — that
// answer should be readable with zero taps, while the archive stays one tap away. The player's
// own taps override the default per row for the session; row state is deliberately NOT persisted
// to localStorage (per-row keys are per-encounter uuids — unbounded growth — and after a remount
// "newest open" is the right recall anyway; the SECTION's fold is what persists, via the
// Collapsible storageKey).

export interface ReportLike {
  encounter_id: string
  created_at: string
}

/** The encounter_id of the most recent report by created_at (ties + empty → first wins / null).
 *  Derived, never assumed from array order — the RPC's ordering is not a client contract. */
export function newestReportId(reports: readonly ReportLike[]): string | null {
  let newest: ReportLike | null = null
  for (const r of reports) {
    if (newest === null || r.created_at > newest.created_at) newest = r
  }
  return newest ? newest.encounter_id : null
}

/** Whether a report row renders open: the player's explicit toggle wins; otherwise only the
 *  newest report defaults open. */
export function reportRowOpen(
  overrides: Readonly<Record<string, boolean>>,
  encounterId: string,
  newestId: string | null,
): boolean {
  return overrides[encounterId] ?? encounterId === newestId
}
