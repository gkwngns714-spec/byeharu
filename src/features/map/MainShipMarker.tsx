import { useEffect, useState } from 'react'
import { resolveMainShipMarker, type MarkerInputs } from './resolveMainShipMarker'

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
  const [, setTick] = useState(0)
  const marker = resolveMainShipMarker(inputs, Date.now())
  const moving = marker?.state === 'outbound' || marker?.state === 'returning'

  // Local visual tick — only while moving; clears when static/hidden. Never mutates game state.
  useEffect(() => {
    if (!moving) return
    const iv = setInterval(() => setTick((n) => n + 1), 1000)
    return () => clearInterval(iv)
  }, [moving])

  if (!marker) return null
  const p = norm({ x: marker.x, y: marker.y })
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
