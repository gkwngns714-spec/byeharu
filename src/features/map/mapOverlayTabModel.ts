// ██ THE MAP'S OVERLAY TABS — the ONE authority for "which readout is open in the map's top-left". ██
//
// ── THE REQUEST ────────────────────────────────────────────────────────────────────────────────────
// Owner: *"i want a separate tab on map for exploration, which is foldable, at the top, a square
// shaped one. also for combat, when opened it will show next wave incoming (wave info), and fleets
// info"* — then *"the fleets info tab should have info like range, speed, reload time, etc"* and
// *"on the wave tab, it should have loot info as well, with total cargo space"*.
//
// Three readouts, three square tabs, at the top of the rail: EXPLORE, FIGHT, FLEETS.
//
// ── ██ ONE OPEN AT A TIME — THIS IS A STRUCTURAL FIX, NOT A STYLE CHOICE ██ ────────────────────────
// The top-left rail used to STACK the exploration panel, the combat card and the fleet readout. Three
// panels at once is 583px against a 505px map box at the owner's own 1440x675, which is how *"right
// now i can't press hunt"* happened: the last panel in the stack was cropped by 36 of its button's 44
// pixels. The reach law (components/ui/overlayLayout.ts) made that survivable by squeezing each
// panel's information; ONE OPEN AT A TIME makes it impossible, because the rail can never hold more
// than one body plus its two pinned rows. The squeeze is now a safety net rather than the mechanism.
//
// Closing the open tab returns a genuinely clean map — the standing map-UX law — and the choice is
// remembered, so a player who wants the fleet readout up keeps it and a player who wants the map bare
// keeps that.
//
// ── ██ WHAT IS NOT IN A TAB, AND WHY ██ ────────────────────────────────────────────────────────────
// THE WAY OUT OF A FIGHT. `RetreatControl` is pinned in the rail beside the tab bar, not inside the
// FIGHT tab, because a control behind a fold is a control the player does not have — the same
// sentence the reach law is built on, applied one level up. A fight is also never silent behind a
// closed tab: that pinned row states the fight's phase, so "under fire" is on screen whatever tab is
// open and even when none is.
//
// PURE. No React, no DOM, no storage access (the reader is injected, the collapsibleState idiom).

export const MAP_OVERLAY_TABS = ['explore', 'fight', 'fleets'] as const
export type MapOverlayTabId = (typeof MAP_OVERLAY_TABS)[number]

/** The one label per tab — the button's accessible name and its tooltip. Plain player words: the
 *  owner's standing rule against insider jargon. */
export const MAP_OVERLAY_TAB_LABEL: Record<MapOverlayTabId, string> = {
  explore: 'Explore',
  fight: 'Fight',
  fleets: 'Fleets',
}

/**
 * The persisted key. Follows the codebase's ONE client-persistence convention (a `byeharu.` prefix +
 * a versioned namespace — `components/ui/collapsibleState.foldStorageKey`, itself following
 * `onboarding/firstOrders`). Deliberately NOT user-scoped, for the same reason folds are not: which
 * readout a player likes open is a cosmetic preference with no per-account meaning.
 */
export const MAP_OVERLAY_TAB_STORAGE_KEY = 'byeharu.maptab.v1'

/** The stored value for "every tab closed" — a real, remembered choice, distinct from "never chose". */
export const MAP_OVERLAY_TAB_NONE = ''

/** Serialize an open tab (or none) for storage. */
export function tabStateValue(open: MapOverlayTabId | null): string {
  return open ?? MAP_OVERLAY_TAB_NONE
}

const isTabId = (v: unknown): v is MapOverlayTabId =>
  typeof v === 'string' && (MAP_OVERLAY_TABS as readonly string[]).includes(v)

/**
 * Which tab a player who has never chosen one should get.
 *
 * A live fight outranks everything: it is the only state on this screen that is both urgent and
 * time-bounded. Otherwise the fleet readout, which is what the owner asked to see on the map.
 * Deliberately NOT a switch that fires when a fight starts — a remembered choice always wins below,
 * so the map never yanks a panel out from under the player mid-tap.
 */
export function defaultOpenTab(fighting: boolean): MapOverlayTabId {
  return fighting ? 'fight' : 'fleets'
}

/**
 * Resolve the open tab from a persisted value.
 *
 * ONLY the values this module writes are trusted: a known id opens that tab, the empty string means
 * the player closed everything, and absence / garbage / a throwing reader (private-mode storage) all
 * fall back to the default. A corrupt byte can never wedge the rail into a state with no way out.
 */
export function resolveOpenTab(stored: string | null, fighting: boolean): MapOverlayTabId | null {
  if (stored === MAP_OVERLAY_TAB_NONE) return null
  if (isTabId(stored)) return stored
  return defaultOpenTab(fighting)
}

/** Read the persisted choice through an injected reader (localStorage.getItem-shaped). */
export function readOpenTab(
  read: (key: string) => string | null,
  fighting: boolean,
): MapOverlayTabId | null {
  try {
    return resolveOpenTab(read(MAP_OVERLAY_TAB_STORAGE_KEY), fighting)
  } catch {
    return defaultOpenTab(fighting)
  }
}

/**
 * What pressing a tab does: opening a different tab CLOSES the one that was open (that is the whole
 * invariant — at most one body is ever mounted), and pressing the open tab again closes it, which is
 * the "foldable" the owner asked for and the only route back to a bare map.
 */
export function pressTab(open: MapOverlayTabId | null, pressed: MapOverlayTabId): MapOverlayTabId | null {
  return open === pressed ? null : pressed
}
