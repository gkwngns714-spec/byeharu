// WORLD EDITOR — the FIRST-RUN HINT decision authority. Props in → decision out. NO React, no DOM, no
// storage, no network — the worldEditorChrome.ts / worldEditorDraftGuard.ts pure-module idiom, unit-
// tested directly (tests/worldEditorFirstRunHint.spec.ts).
//
// WHY: map-UX law #1 says the editor opens on a CLEAN map — `INITIAL_WORLD_EDITOR_CHROME.openTool` is
// null, so WorldEditorDock renders nothing and the whole surface is a starfield plus six icon-only rail
// buttons. That law is right (the map is the product) but it leaves a first-time owner with no visible
// affordance saying the rail is the summon surface: clicking the map appears to do nothing, because
// there is no panel for the selection to land in. The editor reads as BROKEN when it is merely folded.
//
// This module decides — and ONLY decides — whether to render a one-line pointer at the rail. It never
// opens a tool, never touches chrome state, and never touches a draft: dismissing the hint is a no-op on
// both (chrome stays the ONE authority for panel state, the guard stays the ONE authority for unsaved
// work). Deliberately NOT an overlay, NOT a modal, NOT parked over the map — law #1 survives intact.

import type { WorldEditorChromeState } from './worldEditorChrome'

/** localStorage key for the hint dismissal — scoped PER USER so two owners on one browser never share a
 *  dismissal, and versioned so a future rail revision can re-surface the pointer. Mirrors the
 *  firstOrdersDismissKey idiom exactly; storage IO lives in the component, never here. */
export function worldEditorHintDismissKey(userId: string | null | undefined): string {
  return `byeharu.worldEditor.hint.v1.dismissed:${userId || 'anon'}`
}

/** Everything the decision reads. `pendingDraftTotal` is the SAME count the rail badge and the
 *  unpublished-drafts indicator use — an owner who already has drafts parked has plainly found the
 *  editor, so the hint has nothing left to teach them. */
export interface FirstRunHintInput {
  readonly chrome: WorldEditorChromeState
  readonly pendingDraftTotal: number
  readonly dismissed: boolean
}

/** Show the pointer ONLY on a genuinely cold, genuinely empty surface:
 *    • the rail is visible          — a fully dismissed map already has its own summon hint (law #6),
 *                                     and stacking two hints would re-clutter what dismissal cleared;
 *    • NO tool panel is open        — the moment anything is summoned the hint has been obeyed;
 *    • NO drafts are pending        — prior authoring work proves the rail was already discovered;
 *    • not previously dismissed     — one explicit dismissal is permanent (per user, per version).
 *  Every condition is necessary: drop any one and the hint reappears over a surface that no longer
 *  needs it. */
export function shouldShowFirstRunHint({
  chrome,
  pendingDraftTotal,
  dismissed,
}: FirstRunHintInput): boolean {
  if (dismissed) return false
  if (!chrome.railVisible) return false
  if (chrome.openTool !== null) return false
  return pendingDraftTotal === 0
}

/** The hint's words. Plain language, no slice codes, no engineering caveats (map-UX law #4/#5): it
 *  names the ONE gesture that unfolds the editor and the ONE tool that authors, and stops. */
export const WORLD_EDITOR_HINT_TITLE = 'Pick a tool to begin'
export const WORLD_EDITOR_HINT_BODY = 'Edit authors zones. Details inspects what you click.'
