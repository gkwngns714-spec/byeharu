import type { BadgeTone } from '../../components/ui/Badge'

// Pure, read-only presentation helpers for the main ship's human-readable status. 4C-CLIENT: the
// marker-based location labeler (resolveMainShipStatusLabel) was DELETED with the per-ship marker
// pipeline (resolveMainShipMarker et al.) — its only consumer. What remains is the raw
// instance-status label/tone pair below (live: ShipScreen roster rows, TeamRosterPanel).

// TRADE-UI-1 — pure helper for the RAW main_ship_instances.status enum (migration 0043:
// 'home'|'traveling'|'hunting'|'trading'|'exploring'|'mining'|'retreating'|'returning'|'repairing'|'destroyed').
// A ship-list row carries only this activity-status string, so labeling lives here to keep ALL main-ship
// status labels in one module. Pure, and it exposes no location name — nothing to leak.
const INSTANCE_STATUS_LABELS: Record<string, string> = {
  home: 'Ready to launch',
  // NO-HOME (0199): a docked ship (status='stationary'/spatial_state='at_location') reads as "Docked"
  // rather than falling back to the raw 'stationary' code. Deliberately NOT "ready to launch": while the
  // launch_from_dock_enabled flag is dark a docked ship CANNOT launch, so a launch promise here would
  // overpromise and break the "UI byte-identical until flip" guarantee (review M1). "Docked" is honest in
  // both flag states — an improvement over the raw fallback with no promise; the send UI (which reads the
  // flag) is where launch-readiness is surfaced once lit.
  stationary: 'Docked',
  traveling: 'Traveling',
  hunting: 'Hunting',
  trading: 'Trading',
  exploring: 'Exploring',
  mining: 'Mining',
  retreating: 'Retreating',
  returning: 'Returning',
  repairing: 'Repairing',
  destroyed: 'Disabled',
}

// FLEET-READ (UI): the semantic tone for each status, so a roster row is scannable at a glance instead
// of a wall of one grey. It deliberately speaks the SAME colour language the galaxy map already uses —
// outbound travel = warning (the amber FleetMovementLine), returning = accent (the map's return-home
// colour), combat = danger — so a ship reads identically on both surfaces. Tones are semantic tokens
// only; no raw colours here (the Badge/design-system law).
const INSTANCE_STATUS_TONES: Record<string, BadgeTone> = {
  home: 'success', // ready to launch
  stationary: 'neutral', // docked / at rest — the quiet default
  traveling: 'warning', // in transit — matches the map's outbound path
  returning: 'accent', // matches the map's return-home path
  hunting: 'danger',
  retreating: 'danger',
  destroyed: 'danger',
  repairing: 'warning',
  trading: 'accent',
  exploring: 'accent',
  mining: 'accent',
}

/** The semantic tone for a raw main_ship_instances.status. An unmapped/future status falls back to
 *  'neutral' — readable and never a wrong-colour claim (mirrors the label map's `?? status` idiom). */
export function mainShipInstanceStatusTone(status: string): BadgeTone {
  return INSTANCE_STATUS_TONES[status] ?? 'neutral'
}

/** A short human label for a raw main_ship_instances.status; falls back to the raw value so an unmapped/future
 *  status degrades readably rather than blank (mirrors the DockServicesPanel SERVICE_LABELS `?? s` idiom). */
export function mainShipInstanceStatusLabel(status: string): string {
  return INSTANCE_STATUS_LABELS[status] ?? status
}
