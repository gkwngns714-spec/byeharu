// WORLD EDITOR — the PURE zone lifecycle decision model for the live-zone inspector. No React, no DOM,
// no supabase, no network IO — so the button-visibility rule and the two command payload shapes are
// unit-testable directly (tests/publishZoneClient.spec.ts). The transport/UI lives in
// ZoneInspectorActions.tsx which composes this; server-authoritative security lives in the RPCs
// (is_owner() guard) — this module grants no authority.
//
// The zone lifecycle is TWO complementary owner-gated commands over ONE danger_zones row's status:
//   • DEACTIVATE (active → inactive): zone_unpublish (0255) — the SOLE unpublish path, unchanged.
//   • REACTIVATE (inactive → active): zone_set_active (0268) — the restore-half that closes the parity gap.
// The editor's live read (get_danger_zones) is active-rows-only, so a freshly-selected zone starts
// ACTIVE; a successful command flips this LOCAL presentational status (the server is the authority),
// exactly the 0250 exploration/mining set_active precedent.
import type { WorldEditorCommandType } from './commandContract'
import type { DangerZoneLite } from '../map/pirateApi'

export type ZoneLifecycleStatus = 'active' | 'inactive'

/** The fork-time sourceSnapshot both status commands compare value-by-value (optimistic concurrency):
 *  the stable identity the zone read exposes. Geometry is NOT included — a status flip never touches it. */
export interface ZoneStatusExpected {
  readonly name: string
  readonly source: DangerZoneLite['source']
  readonly location_id: string | null
}

/** The payload both zone_unpublish and zone_set_active carry: target_id (the zone uuid) + `expected`. */
export interface ZoneStatusCommandPayload {
  readonly target_id: string
  readonly expected: ZoneStatusExpected
}

/** The ONE descriptor the inspector renders from: which command the button fires, the resulting status,
 *  and the button copy — derived purely from the zone's CURRENT presentational status. When the zone is
 *  active the button DEACTIVATES (zone_unpublish); when inactive it REACTIVATES (zone_set_active). */
export interface ZoneLifecycleAction {
  readonly commandType: Extract<WorldEditorCommandType, 'zone_unpublish' | 'zone_set_active'>
  /** the status the row will hold after this command succeeds. */
  readonly nextStatus: ZoneLifecycleStatus
  readonly label: string
  readonly busyLabel: string
  readonly title: string
}

/** The button-visibility + command rule: active → Unpublish (deactivate); inactive → Reactivate. */
export function zoneLifecycleAction(status: ZoneLifecycleStatus): ZoneLifecycleAction {
  if (status === 'inactive') {
    return {
      commandType: 'zone_set_active',
      nextStatus: 'active',
      label: 'Reactivate zone',
      busyLabel: 'Reactivating…',
      title:
        'Reactivate this zone (status → active): it returns to the player map and pirate interception. ' +
        'Only editor-created (drawn) zones can be reactivated.',
    }
  }
  return {
    commandType: 'zone_unpublish',
    nextStatus: 'inactive',
    label: 'Unpublish zone',
    busyLabel: 'Unpublishing…',
    title:
      'Unpublish this zone (status → inactive): it leaves the player map and pirate interception at once; ' +
      'the row, geometry and attachment are preserved for a future reactivate.',
  }
}

/** Build the shared {target_id, expected} payload for either status command from a live zone. */
export function zoneStatusCommandPayload(zone: DangerZoneLite): ZoneStatusCommandPayload {
  return {
    target_id: zone.id,
    expected: { name: zone.name, source: zone.source, location_id: zone.location_id },
  }
}

/** Only editor-created ('drawn') zones are toggleable; seeded 'circle' zones are protected server-side
 *  (validation_failed / protected_zone). Reflect that in the control rather than inviting a sure reject. */
export function isZoneToggleable(zone: DangerZoneLite): boolean {
  return zone.source === 'drawn'
}
