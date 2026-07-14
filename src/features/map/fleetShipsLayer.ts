import { createElement, useEffect, useState, type ReactElement } from 'react'
import type { FleetPosition } from './mainshipApi'
import type { MapLocation } from './mapTypes'
import { resolveFleetMarkers, type FleetMarker } from './resolveFleetMarkers'

// FLEETMAP — the whole-fleet map overlay. Additive BESIDE the existing single-ship marker + team markers:
// it draws every owned ship EXCEPT the selected one at its real position, so a player owning 2+ ships no
// longer goes invisible. Read-only, pointer-transparent, tokens only. Position math is the ONE shared
// interpolation (via resolveFleetMarkers) — no second pipeline.
//
// SINGLE SOURCE OF TRUTH for the SELECTED ship: this layer deliberately does NOT draw the selected ship.
// Its glyph AND its selected-emphasis come solely from the single shipLayer's MainShipMarker (one resolver,
// one 1s clock). The exclusion is keyed to the SAME id the single marker renders (the fetch-scoped
// mainShip.main_ship_id), so the fleet layer and the single marker can never disagree about which ship is
// selected or where it is — no dual-pipeline drift, and no orphan ring if the oracle can't place it.
//
// Wiring follows the `shipLayer` / `teamMarkersLayer` element-descriptor convention: the pure `fleetShipsLayer`
// helper returns element descriptors so GalaxyMap and the unit test call the SAME function. Gated on the
// existing `mainshipSendEnabled` data-dark gate (parity with the single-ship marker) — dark environments render
// byte-identical.

const EMPTY_IDS: ReadonlySet<string> = new Set()

// State → design-system token color (mirrors MainShipMarker: returning=accent, outbound=warning,
// in_space=success) with docked as a neutral parked tone.
function stateColor(state: FleetMarker['state']): string {
  switch (state) {
    case 'returning':
      return 'var(--color-accent)'
    case 'outbound':
      return 'var(--color-warning)'
    case 'in_space':
      return 'var(--color-success)'
    case 'docked':
      return 'var(--color-ink-muted)'
  }
}

/** The markers the fleet LAYER draws: every placeable owned ship EXCEPT the selected one (owned by the single
 *  shipLayer/MainShipMarker) AND except any ship a TEAM marker already represents (a docked-team badge or an
 *  in-flight moving badge) — no ship is drawn twice. Pure — the shared position resolver + selection filter. */
export function fleetLayerMarkers(
  positions: readonly FleetPosition[],
  locations: readonly Pick<MapLocation, 'id' | 'x' | 'y'>[],
  selectedShipId: string | null,
  nowMs: number,
  teamRepresentedShipIds: ReadonlySet<string> = EMPTY_IDS,
): FleetMarker[] {
  return resolveFleetMarkers(positions, locations, selectedShipId, nowMs, teamRepresentedShipIds).filter((m) => !m.selected)
}

/** One subdued fleetmate marker: a small state-colored chevron with a faint halo, dimmed so the selected
 *  ship (drawn prominently by the single MainShipMarker) reads as the focus. */
export function FleetShipMarker({
  marker,
  x,
  y,
  k,
}: {
  marker: FleetMarker
  x: number
  y: number
  k: number
}) {
  const r = 6 / k
  const points = `${x},${y - r} ${x + r * 0.8},${y + r * 0.7} ${x - r * 0.8},${y + r * 0.7}`
  return createElement(
    'g',
    { 'data-testid': `fleet-ship-${marker.main_ship_id}`, style: { pointerEvents: 'none' as const }, opacity: 0.6 },
    createElement('circle', { cx: x, cy: y, r: r * 1.5, fill: stateColor(marker.state), opacity: 0.12 }),
    createElement('polygon', {
      points,
      fill: stateColor(marker.state),
      stroke: 'var(--color-app)',
      strokeWidth: 1,
      vectorEffect: 'non-scaling-stroke',
    }),
  )
}

/** All fleet-ship markers (excluding the selected ship), with the MainShipMarker 1s interpolation tick —
 *  advanced ONLY while a fleetmate is in transit (outbound/returning), cleared otherwise (the shared marker
 *  idiom; Date.now() stays out of render). */
export function FleetShipsMarkers({
  positions,
  locations,
  selectedShipId,
  teamRepresentedShipIds,
  norm,
  k,
}: {
  positions: FleetPosition[]
  locations: Pick<MapLocation, 'id' | 'x' | 'y'>[]
  selectedShipId: string | null
  teamRepresentedShipIds?: ReadonlySet<string>
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}) {
  const [now, setNow] = useState(() => Date.now())
  const markers = fleetLayerMarkers(positions, locations, selectedShipId, now, teamRepresentedShipIds ?? EMPTY_IDS)
  const moving = markers.some((m) => m.state === 'outbound' || m.state === 'returning')

  useEffect(() => {
    if (!moving) return
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [moving])

  if (markers.length === 0) return null
  return createElement(
    'g',
    { 'data-testid': 'fleet-ships-layer' },
    ...markers.map((m) => {
      const p = norm({ x: m.x, y: m.y })
      return createElement(FleetShipMarker, { key: m.main_ship_id, marker: m, x: p.x, y: p.y, k })
    }),
  )
}

// ── Pure, hook-free GalaxyMap fleet-overlay layer (the `shipLayer` element-tree convention). Returns element
// DESCRIPTORS only — no hooks run, so the unit test calls this SAME function. Gated on `mainshipSendEnabled`
// (parity with the single-ship marker); empty projection → [] (map renders byte-identical to today). The
// `selectedShipId` here is the ship the single MainShipMarker owns — passed so this layer EXCLUDES it. ──
export function fleetShipsLayer(args: {
  mainshipSendEnabled: boolean
  positions: FleetPosition[]
  locations: Pick<MapLocation, 'id' | 'x' | 'y'>[]
  selectedShipId: string | null
  // FLEETMAP de-dup: ship ids a TEAM marker already represents (docked-team badge / in-flight moving badge).
  // Members of a drawn team are skipped here so they are not double-drawn as redundant chevrons.
  teamRepresentedShipIds?: readonly string[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}): ReactElement[] {
  if (!args.mainshipSendEnabled) return []
  if (args.positions.length === 0) return []
  return [
    createElement(FleetShipsMarkers, {
      key: 'fleet-ships-markers',
      positions: args.positions,
      locations: args.locations,
      selectedShipId: args.selectedShipId,
      teamRepresentedShipIds:
        args.teamRepresentedShipIds && args.teamRepresentedShipIds.length > 0 ? new Set(args.teamRepresentedShipIds) : EMPTY_IDS,
      norm: args.norm,
      k: args.k,
    }),
  ]
}
