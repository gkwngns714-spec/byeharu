// WORLD EDITOR — the SELECTED-ENTITY EDIT INTENT planner. Props in → plan out. NO React, no DOM, no
// storage, no network — the worldEditorChrome / worldEditorDraftGuard pure-module idiom, unit-tested
// directly (tests/worldEditorAuthoringIntent.spec.ts).
//
// WHY: the editor holds TWO independent pieces of state — `selected` (what the owner clicked on the map,
// any domain) and `authoringDomain` (which domain's draft workspace is active, default 'locations').
// The Details panel's Edit control used to be branched on authoringDomain, so selecting a ZONE on a cold
// load rendered the LOCATION Edit button, disabled, captioned "Select a location first." — while the
// same panel's header read "Zones / Blackden". A control that denies an action the owner has plainly
// already taken, and blames them for it, reads as a broken editor. It was reported as exactly that.
//
// THE INVARIANT this module encodes (and does NOT widen):
//   • SELECTION decides the edit TARGET.                      ← this module
//   • authoringDomain remains the ONE authority for the active draft workspace.
//   • worldEditorDraftGuard remains the ONE authority for whether a workspace change may commit.
// So this planner never decides dirtiness, never discards, never switches anything. It answers one
// question — "what would Edit do with the current selection?" — and names whether that crosses a domain
// boundary. Crossing one is routed by the caller through the EXISTING 'switch-domain' guard; it is not a
// second guard, and this module deliberately holds no dirty-state input that could become one.
//
// Selection is NOT consent to navigate: clicking a different entity only inspects it. Only pressing Edit
// requests the guarded transition, so ordinary map browsing can never raise a discard prompt.
import type { PendingDraftDomain } from './worldEditorPendingDrafts'

/** What pressing Edit would do with the current selection.
 *  • `disabled`        — nothing to fork: no selection, or no live row behind it (an inactive entity
 *                        carries no active reader row to fork from);
 *  • `edit-here`       — the selection already lives in the active workspace: fork straight away, and
 *                        NEVER consult the switch-domain guard (nothing is being left);
 *  • `switch-then-edit`— the selection belongs to another domain: the caller must commit the domain
 *                        switch AND the fork as ONE action behind the existing guard, so a cancel leaves
 *                        both untouched and a confirm performs both exactly once. */
export type AuthoringEditPlan =
  | { readonly kind: 'disabled'; readonly reason: 'no-selection' | 'no-live-row' }
  | { readonly kind: 'edit-here'; readonly domain: PendingDraftDomain }
  | { readonly kind: 'switch-then-edit'; readonly domain: PendingDraftDomain }

/** Everything the plan reads. `hasLiveRow` is the caller's already-resolved fork source for the SELECTED
 *  domain (the shell's per-domain `selectedLocation` / `selectedZone` / … memos) — this module never
 *  reaches into a reader itself, so it stays domain-blind and trivially testable. Deliberately NO dirty
 *  input: dirtiness belongs to the guard, and taking it here would fork a second authority. */
export interface AuthoringEditInput {
  /** The selected entity's domain — layer ids and authoring domains share ONE vocabulary. */
  readonly selectedDomain: PendingDraftDomain | null
  /** Does an ACTIVE live row exist to fork from? */
  readonly hasLiveRow: boolean
  /** The workspace currently on screen. */
  readonly activeDomain: PendingDraftDomain
}

/** The ONE plan decision. Total over its inputs and free of side conditions. */
export function planSelectedEdit({
  selectedDomain,
  hasLiveRow,
  activeDomain,
}: AuthoringEditInput): AuthoringEditPlan {
  if (!selectedDomain) return { kind: 'disabled', reason: 'no-selection' }
  if (!hasLiveRow) return { kind: 'disabled', reason: 'no-live-row' }
  return selectedDomain === activeDomain
    ? { kind: 'edit-here', domain: selectedDomain }
    : { kind: 'switch-then-edit', domain: selectedDomain }
}

/** Does this plan cross a workspace boundary, i.e. must the caller route it through the EXISTING
 *  'switch-domain' guard? A same-domain edit must NOT raise the guard — it leaves nothing. */
export function editPlanNeedsGuard(plan: AuthoringEditPlan): boolean {
  return plan.kind === 'switch-then-edit'
}

/** Plain-language nouns (map-UX law #4/#5: no domain keys, no slice codes, in the owner's words). */
export const AUTHORING_DOMAIN_NOUNS: Record<PendingDraftDomain, string> = {
  locations: 'location',
  mining: 'mining field',
  exploration: 'exploration site',
  zones: 'zone',
}

/** The button's caption — it names what will actually be edited, so the control can never contradict the
 *  panel header beside it. A disabled plan stays the bare verb (there is no target to name). */
export function authoringEditLabel(plan: AuthoringEditPlan): string {
  return plan.kind === 'disabled' ? 'Edit' : `Edit ${AUTHORING_DOMAIN_NOUNS[plan.domain]}`
}

/** The tooltip — describes the SELECTED entity or the consequence of pressing Edit. It never instructs
 *  the owner to go satisfy an unrelated internal state condition ("Select a location first." was the
 *  reported defect: it blamed the owner for the shell's own domain coupling). */
export function authoringEditTitle(plan: AuthoringEditPlan): string {
  if (plan.kind === 'disabled') {
    return plan.reason === 'no-selection'
      ? 'Pick something on the map first.'
      : 'This one has no live row to copy — reactivate it first.'
  }
  const noun = AUTHORING_DOMAIN_NOUNS[plan.domain]
  return plan.kind === 'edit-here'
    ? `Copy this ${noun} into a draft you can change.`
    : `Copy this ${noun} into a draft you can change. Unpublished work in the current tab is checked first.`
}
