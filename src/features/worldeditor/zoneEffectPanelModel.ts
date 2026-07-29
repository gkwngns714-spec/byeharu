// WORLD EDITOR — the TYPED-ZONE EFFECT PANEL model. Props in → view model out. NO React, no DOM,
// no storage, no network — the worldEditorChrome / worldEditorDraftGuard pure-module idiom,
// unit-tested directly (tests/zoneEffectPanelModel.spec.ts).
//
// ── WHAT THIS DECIDES ───────────────────────────────────────────────────────────────────────────
// Every server command for typed zones now exists — effect set/remove (0277), kind change (0285) —
// and nothing drives them. This is the decision layer for the panel that will: which effects does
// this zone carry, which can be added, which control is enabled, and what does a disabled one SAY.
//
// It decides nothing about layout and performs no action. A row's `action` is an INTENT the shell
// dispatches; this module never calls a command, so it can be exercised exhaustively without a
// database and cannot half-apply anything.
//
// ── THE RULE IT ENFORCES, MIRRORED FROM THE SERVER ──────────────────────────────────────────────
// The authoring commands are gated on typed_zone_authoring_enabled, and a dark capability must not
// present live-looking controls. So when authoring is off every row is disabled with a reason that
// says so plainly, rather than letting the owner click into a rejection.
//
// ── WHY A DISABLED CONTROL MUST EXPLAIN ITSELF ─────────────────────────────────────────────────
// This editor already shipped one control that was disabled for a reason it never stated — the Edit
// button that read "Select a location first." while a zone was plainly selected. That cost an
// afternoon. Every disabled row here carries a `reason` naming the actual blocker, and a test
// asserts no reason blames the owner for shell state.

import { ZONE_EFFECT_KINDS, ZONE_EFFECT_LABELS, type ZoneEffectKind } from './zoneEffects'

/** What the shell may dispatch for one effect row. Intents, never calls. */
export type ZoneEffectAction = 'add' | 'edit' | 'remove'

export interface ZoneEffectRow {
  readonly effect: ZoneEffectKind
  readonly label: string
  /** Does the zone carry this effect right now? Presence IS the row, server-side. */
  readonly present: boolean
  /** The primary action this row offers. `add` when absent, `edit` when present. */
  readonly action: ZoneEffectAction
  readonly enabled: boolean
  /** Why the row is disabled — null when enabled. Never blames the owner for shell state. */
  readonly reason: string | null
  /** May this row offer removal? Only when present AND authoring is live. */
  readonly canRemove: boolean
}

export interface ZoneEffectPanelInput {
  /** Effects the selected zone currently carries. */
  readonly carried: readonly ZoneEffectKind[]
  /** typed_zone_authoring_enabled, as the shell resolved it. */
  readonly authoringEnabled: boolean
  /** False while the zone is inactive — a retired zone is inspected, not authored. */
  readonly zoneActive: boolean
  /** True while a command is in flight, so the panel cannot double-dispatch. */
  readonly busy: boolean
}

export interface ZoneEffectPanel {
  readonly rows: readonly ZoneEffectRow[]
  /** True when nothing on the panel can be acted on — lets the shell show one honest summary
   *  instead of repeating the same reason on every row. */
  readonly allDisabled: boolean
  /** The single sentence to show above the rows when everything is blocked, else null. */
  readonly blockedSummary: string | null
}

const REASON_AUTHORING_OFF = 'Typed-zone authoring is not enabled.'
const REASON_INACTIVE = 'This zone is retired. Restore it before changing what it does.'
const REASON_BUSY = 'Waiting for the last change to finish.'

/** The ONE panel decision. Rows follow the effect registry order so the panel never reshuffles. */
export function buildZoneEffectPanel(input: ZoneEffectPanelInput): ZoneEffectPanel {
  // Ordered by BLAST RADIUS, not by convenience: a change already in flight is the most transient
  // blocker and the least alarming to report, so it is checked last. Reporting "waiting…" when the
  // real problem is that authoring is switched off would send the owner back to retry forever.
  const blocker = !input.authoringEnabled
    ? REASON_AUTHORING_OFF
    : !input.zoneActive
      ? REASON_INACTIVE
      : input.busy
        ? REASON_BUSY
        : null

  const carried = new Set(input.carried)
  const rows: ZoneEffectRow[] = ZONE_EFFECT_KINDS.map((effect) => {
    const present = carried.has(effect)
    return {
      effect,
      label: ZONE_EFFECT_LABELS[effect],
      present,
      action: present ? 'edit' : 'add',
      enabled: blocker === null,
      reason: blocker,
      canRemove: present && blocker === null,
    }
  })

  return {
    rows,
    allDisabled: blocker !== null,
    blockedSummary: blocker,
  }
}

/** The effects a zone could still gain — what an "add effect" menu should offer. Empty when the
 *  zone already carries every registered effect. */
export function addableEffects(carried: readonly ZoneEffectKind[]): ZoneEffectKind[] {
  const have = new Set(carried)
  return ZONE_EFFECT_KINDS.filter((e) => !have.has(e))
}

/** A zone carrying no effects at all is legal and meaningful: it keeps its geometry and identity and
 *  simply does nothing. The panel says that rather than looking broken — an empty list with no
 *  explanation is how the editor read as dead the first time. */
export function emptyEffectSummary(carried: readonly ZoneEffectKind[]): string | null {
  return carried.length === 0
    ? 'This zone does nothing yet. Add an effect to give it behaviour.'
    : null
}
