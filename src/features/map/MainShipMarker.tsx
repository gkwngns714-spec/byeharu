import { useEffect, useState } from 'react'
import { resolveMainShipMarker, type MarkerInputs } from './resolveMainShipMarker'
import { worldToViewBox } from './openSpaceTransform'

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
  // OSN-3 S6B2 — route the marker's WORLD coords to viewBox-local space by its coordinate-space
  // provenance: legacy/named states use the map's dynamic normalizer; open-space states use the S6B1
  // fixed-domain transform. Both yield viewBox-local coords; the existing camera <g> applies pan/zoom
  // afterward. Exhaustive switch with a `never` guard — NO default and NO silent fallback to `norm`, so
  // a coordinate marker can never be projected through buildNormalizer() by accident.
  let p: { x: number; y: number }
  switch (marker.coordinateSpace) {
    case 'legacy_dynamic':
      p = norm({ x: marker.x, y: marker.y })
      break
    case 'open_space_fixed':
      p = worldToViewBox({ x: marker.x, y: marker.y })
      break
    default: {
      const _exhaustive: never = marker.coordinateSpace
      throw new Error(`MainShipMarker: unhandled coordinateSpace ${String(_exhaustive)}`)
    }
  }
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
