// WORLD EDITOR — the CHROME model (UX comfort pass). The owner's map-UX law says the map is the
// product: chrome is SUMMONED, lives in the corners, folds and dismisses, and never parks itself over
// the map. This module is the ONE authority for that chrome state — which tool panel is open, and
// whether the corner rail is showing at all.
//
// PURE by construction: no React, no DOM, no IO, no draft store. It decides VIEW state only, so it can
// never discard, patch, or publish a draft — dismissing chrome is always a no-op on authoring state
// (proven in tests/worldEditorChrome.spec.ts). The shell binds it with useState; the guard
// (worldEditorDraftGuard) remains the ONE authority for unsaved work.
import type { IconName } from '../../components/ui/icons'

/** The tools the editor's side chrome can show — ONE ordered registry (rail order = this order).
 *  Internal ids stay the codebase's vocabulary; the LABELS below are what the owner reads. */
export const WORLD_EDITOR_TOOLS = ['layers', 'find', 'inspect', 'author', 'history', 'combat'] as const

export type WorldEditorTool = (typeof WORLD_EDITOR_TOOLS)[number]

/** Plain-language, minimal-word labels (map-UX law #4/#5: no slice codes, no engineering caveats). */
export const WORLD_EDITOR_TOOL_LABELS: Record<WorldEditorTool, string> = {
  layers: 'Layers',
  find: 'Find',
  inspect: 'Details',
  author: 'Edit',
  history: 'History',
  combat: 'Combat',
}

/** Icon per tool — the rail is icon-led, the label is the tooltip/secondary text (map-UX law #4). */
export const WORLD_EDITOR_TOOL_ICONS: Record<WorldEditorTool, IconName> = {
  layers: 'layers',
  find: 'search',
  inspect: 'info',
  author: 'edit',
  history: 'history',
  combat: 'combat',
}

/** The chrome's whole visible state.
 *  • `railVisible` — is the corner icon rail (and the rest of the corner chrome) showing at all?
 *  • `openTool`    — which tool panel is summoned; `null` = folded away, clean map. */
export interface WorldEditorChromeState {
  readonly railVisible: boolean
  readonly openTool: WorldEditorTool | null
}

/** The default: a CLEAN map. The corner rail is available to summon from, but NO panel is parked
 *  over the map (map-UX law #1/#2). */
export const INITIAL_WORLD_EDITOR_CHROME: WorldEditorChromeState = {
  railVisible: true,
  openTool: null,
}

/** Summon a tool panel (also un-hides the rail so the panel is never orphaned). */
export function openTool(state: WorldEditorChromeState, tool: WorldEditorTool): WorldEditorChromeState {
  if (state.railVisible && state.openTool === tool) return state
  return { railVisible: true, openTool: tool }
}

/** Rail click: open the tool, or fold it away when it is already the open one. */
export function toggleTool(state: WorldEditorChromeState, tool: WorldEditorTool): WorldEditorChromeState {
  if (state.railVisible && state.openTool === tool) return { railVisible: true, openTool: null }
  return openTool(state, tool)
}

/** Fold the panel back to the rail (collapse) — the rail stays. */
export function collapsePanel(state: WorldEditorChromeState): WorldEditorChromeState {
  return state.openTool === null ? state : { ...state, openTool: null }
}

/** Dismiss ALL chrome: no rail, no panel — a bare, fully usable map (map-UX law #6). */
export function dismissChrome(): WorldEditorChromeState {
  return { railVisible: false, openTool: null }
}

/** Bring the rail back (the double-click-to-summon gesture's target). */
export function summonChrome(state: WorldEditorChromeState): WorldEditorChromeState {
  return state.railVisible ? state : { ...state, railVisible: true }
}

/** The double-click-on-map gesture: summon when hidden, dismiss when showing. */
export function toggleChrome(state: WorldEditorChromeState): WorldEditorChromeState {
  return state.railVisible ? dismissChrome() : summonChrome(state)
}

/** Is a given tool's panel on screen right now? */
export function isToolOpen(state: WorldEditorChromeState, tool: WorldEditorTool): boolean {
  return state.railVisible && state.openTool === tool
}

/** Is ANY panel on screen (i.e. is the map partially covered)? */
export function isPanelOpen(state: WorldEditorChromeState): boolean {
  return state.railVisible && state.openTool !== null
}
