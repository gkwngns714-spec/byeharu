import { useEffect, useState } from 'react'
import { resolveMainShipMarker, type MarkerInputs, type ShipMarker } from './resolveMainShipMarker'
import { worldToViewBox } from './openSpaceTransform'

// OSN-3 S6B4 — pure coordinate-space ROUTING for a resolved ShipMarker: choose the viewBox-local point by
// provenance. `legacy_dynamic` → the map's dynamic normalizer (`norm`); `open_space_fixed` → the S6B1
// fixed-domain transform (`worldToViewBox`). Exhaustive switch + `never` guard — an unknown provenance can
// NEVER silently fall back to `norm`, so a coordinate marker can never reach buildNormalizer() by accident.
// Pure routing only: no coordinate mutation / interpolation / clamping / target validation / camera logic.
// MainShipMarker (below) calls this; the S6B4 tests call this SAME function (no duplicated routing logic).
export function markerViewBoxPoint(
  marker: Pick<ShipMarker, 'x' | 'y' | 'coordinateSpace'>,
  norm: (p: { x: number; y: number }) => { x: number; y: number },
): { x: number; y: number } {
  switch (marker.coordinateSpace) {
    case 'legacy_dynamic':
      return norm({ x: marker.x, y: marker.y })
    case 'open_space_fixed':
      return worldToViewBox({ x: marker.x, y: marker.y })
    default: {
      const _exhaustive: never = marker.coordinateSpace
      throw new Error(`markerViewBoxPoint: unhandled coordinateSpace ${String(_exhaustive)}`)
    }
  }
}

// OSN-1 — presentational main-ship marker. Renders ONLY the local player's own ship (relation
// 'self'), pointer-transparent, as the top child of the map's transform group. Position comes
// solely from the pure resolver (the single source of position truth); a 1s tick advances the
// interpolation ONLY while outbound/returning so just this component re-renders. Visual only —
// it never fetches, writes, or commands. World coords from the resolver are mapped through the
// map's existing `norm` so it shares the map's coordinate/zoom conventions exactly.

export function MainShipMarker({
  inputs,
  norm,
  k,
}: {
  inputs: MarkerInputs
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}) {
  // `now` in state (lazy init), advanced by the 1s tick below ONLY while moving — keeps Date.now()
  // out of render (react-hooks purity) while preserving the exact prior tick behavior.
  const [now, setNow] = useState(() => Date.now())
  const marker = resolveMainShipMarker(inputs, now)
  const moving = marker?.state === 'outbound' || marker?.state === 'returning'

  // Local visual tick — only while moving; clears when static/hidden. Never mutates game state.
  useEffect(() => {
    if (!moving) return
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [moving])

  if (!marker) return null
  // OSN-3 S6B2/S6B4 — route the marker's WORLD coords to viewBox-local space by coordinate-space
  // provenance via the shared pure helper (legacy → dynamic `norm`; open-space → S6B1 fixed transform).
  // The existing camera <g> applies pan/zoom afterward. This is the exact function the S6B4 tests exercise.
  const p = markerViewBoxPoint(marker, norm)
  // OSN-2b note: in_space reuses the existing default marker colour (no new main-ship visual
  // language introduced here). A distinct parked-in-space colour is a future approved visual decision.
  const color =
    marker.state === 'returning' ? '#38bdf8' : marker.state === 'outbound' ? '#fbbf24' : '#34d399'
  const r = 7 / k
  // Upward chevron/triangle — distinct from the cyan home diamond and the location dots.
  const points = `${p.x},${p.y - r} ${p.x + r * 0.8},${p.y + r * 0.7} ${p.x - r * 0.8},${p.y + r * 0.7}`

  return (
    <g data-testid="mainship-marker" style={{ pointerEvents: 'none' }}>
      <polygon points={points} fill={color} stroke="#0b1220" strokeWidth={1} vectorEffect="non-scaling-stroke" />
    </g>
  )
}
