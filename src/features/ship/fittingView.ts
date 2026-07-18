import type { FleetPosition } from '../map/mainshipApi'
import type { ModuleInstance, ShipFittingRow } from '../modules/modulesTypes'

// S6 FITTING — PURE selectors for the Fitting tab (no React/DOM/fetch — the shipDossierView.ts
// mold; specs in tests/fittingView.spec.ts).
//
// ONE-READ LAW: fit-eligibility derives from the SAME get_my_fleet_positions row every location
// label folds from (map.fleetPositions via useShellState) — NEVER a second dockedness query. The
// client mirror is display-only: the server (fitting_execute_command step 6, migration 0114) stays
// the enforcer — it requires mainship_space_validate_context ok AND state in ('home','at_location')
// plus the cross-domain exclusion, and answers ship_not_settled otherwise. A place the client
// enables that the server rejects surfaces the server's own honest copy; the UI is never the control.

export type FitGateReason = 'position_unknown' | 'not_settled' | 'berthed_not_fittable'

export interface FitEditability {
  editable: boolean
  reason: FitGateReason | null
}

/**
 * Whether the loadout edit surface (fit/unfit) is ENABLED for a ship, from its ONE fleet-positions
 * row. Editable exactly when the server-decided `place` is 'docked' (fleeted, settled at a port —
 * best-effort: its fleet is normally at_location, which 0114 accepts; the rare legacy-corpse edge
 * still surfaces the server's own ship_not_settled copy on attempt). Everything else fails closed:
 * transit / in_space are the exact states the 0114 settled-safe rule exists to forbid, 'hidden' is
 * an unknown place (never guess), and a missing row (projection dark/empty, or a destroyed ship —
 * the projection excludes those) is position-unknown.
 *
 * INTERIM-UNTIL-4C: 'berthed' (unfleeted at its berth port — the S1/0216 place) is NOT editable.
 * A berthed ship validates to legacy_home / a contradictory state, and the server's settled-safe
 * rule (0114) accepts ONLY ('home','at_location') — so every fit attempt on a berthed ship returns
 * ship_not_settled. Until slice 4c/4d canonicalizes berthed to a settled state 0114 accepts, the
 * client must not promise a capability the server will always reject. When 4c lands: restore
 * berthed → editable here and delete the 'berthed_not_fittable' reason.
 */
export function fittingEditability(pos: FleetPosition | undefined): FitEditability {
  if (!pos) return { editable: false, reason: 'position_unknown' }
  if (pos.place === 'docked') return { editable: true, reason: null }
  if (pos.place === 'berthed') return { editable: false, reason: 'berthed_not_fittable' }
  return { editable: false, reason: 'not_settled' }
}

/** Short player copy for a disabled fit gate (the teamReasonMessage tone; never a raw code). */
export function fitGateMessage(reason: FitGateReason): string {
  if (reason === 'position_unknown') return 'Ship position unavailable right now — loadout editing is paused.'
  if (reason === 'berthed_not_fittable')
    return 'This ship is berthed. Bring a fleet to its port — assign it to a fleet, or dock a fleet here — to change its fitting.'
  return 'The ship must be docked at a port to change its loadout.'
}

/**
 * The player's UNFITTED module pool — crafted instances not currently fitted to ANY ship (the fit
 * candidates the detail offers the selected ship). Instance order preserved (0110 returns newest
 * first). Pure set-difference against the WHOLE fittings read, so a module fitted to another ship
 * is never offered twice.
 */
export function unfittedModuleInstances(
  instances: ModuleInstance[],
  fittings: ShipFittingRow[],
): ModuleInstance[] {
  const fitted = new Set(fittings.map((f) => f.module_instance_id))
  return instances.filter((m) => !fitted.has(m.instance_id))
}
