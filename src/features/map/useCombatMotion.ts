// THE CLOCK for an on-map battle — the one impure shell around map/combatMotion.ts.
//
// Everything that DECIDES anything is pure and lives in combatMotion.ts, driven by a `nowMs` it is
// handed. This hook does the three things a pure function cannot: read the clock, remember the
// previous observation across polls, and schedule frames. Keeping the split at exactly that line is
// what lets tests/combatMotion.spec.ts prove the motion over a clock it passes in, and it is why no
// `Date.now()` is read during render anywhere on this path (an earlier slice shipped that impurity
// and it is not being reintroduced).
//
// ── WHY A FRAME LOOP AND NOT A CSS TRANSITION ─────────────────────────────────────────────────────
// A `transition: transform` on each glyph is cheaper per frame — the browser animates it off the
// main thread entirely — and it was rejected for three reasons, in increasing order of weight:
//   1. It cannot be proven. The whole point of this slice is a spec that says a rendered position is
//      strictly between two observed ones and monotonic in t; a CSS transition's intermediate state
//      is the browser's, not a value any test can read as a function of a clock.
//   2. It is a SECOND smoother. The map already has one authority for "where is this thing between
//      two known points at time t" and the brief for this work is to compose it, not to add another
//      engine beside it — least of all one that also has to be told, per element, not to animate a
//      spawn and not to animate a death.
//   3. It cannot serve the ordnance. A round has to be positioned between two MOVING hulls, so its
//      lane is recomputed every frame from the same interpolation; a transition can only animate
//      between two states it is given, and the target state is itself moving.
// requestAnimationFrame gives vsync alignment and stops dead when the tab is hidden, which an
// interval does not.
//
// ── IT SLEEPS ─────────────────────────────────────────────────────────────────────────────────────
// The loop runs only while something is actually moving: it stops as soon as every step has landed
// and every round is down, and a new poll restarts it. With a 3 s server tick and steps played over
// that same 3 s, that is close to full duty during a fight and ZERO with no fight on the map — a map
// with no positioned battle never schedules a frame, so nothing about an idle map changes.
// Frames are additionally coalesced to ~30 fps: this re-renders a subtree of SVG element
// descriptors, the content is a handful of glyphs drifting a few world units, and halving the
// reconciliation on the 390px phone the owner tests on costs nothing visible.
import { useEffect, useMemo, useRef, useState } from 'react'
import type { CombatEvent, CombatUnit } from '../combat/combatTypes'
import {
  anyTickArtifactLive,
  anyUnitInMotion,
  observeCombatEvents,
  observeCombatUnits,
  smoothCombatUnits,
  type CombatMotion,
  type EventSightings,
} from './combatMotion'

/** ~30 fps. See the header — this bounds React reconciliation, not the smoothness of the motion. */
const FRAME_MIN_MS = 33

export interface CombatMotionState {
  /** the caller's rows with pos_x/pos_y moved to where they are NOW. Pass these wherever the raw
   *  rows went, so every consumer of resolveSpatialUnits (glyphs AND the fleet badge) agrees. */
  units: CombatUnit[]
  /** when each of the exchange's events was first seen — the ordnance's zero AND the damage
   *  number's expiry (combatMotion.TICK_READOUT_MS). */
  sightings: EventSightings
  /** the clock the pure layer renders at. */
  nowMs: number
}

/**
 * Smooth an active battle. Returns the same rows, positioned for this instant.
 *
 * ── ORDERING, AND WHY THERE IS NO JUMP ────────────────────────────────────────────────────────────
 * A poll lands new rows, React renders once with the PREVIOUS ledger, and only then does the effect
 * fold the new observation in. That one frame is not a glitch: the previous ledger's answer for a
 * unit is its previous OBSERVED position, which is exactly where the new step is about to start
 * from. The frame before the fold and the first frame after it draw the same point.
 */
export function useCombatMotion(
  units: readonly CombatUnit[],
  events: readonly CombatEvent[],
): CombatMotionState {
  const [motion, setMotion] = useState<CombatMotion>({})
  const [sightings, setSightings] = useState<EventSightings>({})
  const [nowMs, setNowMs] = useState(() => Date.now())
  const frame = useRef<number | null>(null)
  const lastFrameMs = useRef(0)

  useEffect(() => {
    // Intentional: fold newly-arrived server rows into the keyframe ledger. This is the
    // "derive state from external data that just landed" effect — it runs once per poll (the deps
    // are the fetched arrays' identity), never per frame, and the reducer is pure.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setMotion((prev) => observeCombatUnits(prev, units, Date.now()))
  }, [units])

  useEffect(() => {
    // Same shape for the exchange's events: remember when each was first seen, so a round in flight
    // is never restarted by the next poll handing back the same tick — and so a damage number knows
    // how old it is, which is what stops it outliving the fight over a wreck.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setSightings((prev) => observeCombatEvents(prev, events, Date.now()))
  }, [events])

  useEffect(() => {
    // Nothing on the map is moving and this exchange's drawing has nothing left to change → do not
    // schedule a single frame.
    if (!anyUnitInMotion(motion, Date.now()) && !anyTickArtifactLive(sightings, Date.now())) return
    let live = true
    const tick = () => {
      if (!live) return
      const t = Date.now()
      if (t - lastFrameMs.current >= FRAME_MIN_MS) {
        lastFrameMs.current = t
        setNowMs(t) // advancing the animation clock IS this effect's job

      }
      frame.current = requestAnimationFrame(tick)
    }
    frame.current = requestAnimationFrame(tick)
    return () => {
      live = false
      if (frame.current !== null) cancelAnimationFrame(frame.current)
      frame.current = null
    }
    // `nowMs` is a dependency on purpose: each advance re-evaluates the stop condition, so the loop
    // tears itself down the moment the last step lands instead of spinning until the next poll.
  }, [motion, sightings, nowMs])

  const smoothed = useMemo(() => smoothCombatUnits(units, motion, nowMs), [units, motion, nowMs])

  return { units: smoothed, sightings, nowMs }
}
