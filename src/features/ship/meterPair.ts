// SHIELD-2 — the PURE shield/hull meter-pair view-model (no React, no IO; specs in
// tests/shipMeterPair.spec.ts). The ONE derivation both ship cards (ShipStatusCard + ShipDossier)
// render through MeterPairBars — never a second copy of the bar math.
//
// DATA-GATED (the 0191 posture, no flag): the shield reading is non-null ONLY when
// max_shield > 0. Every ship is 0/0 until the human ACT-SHIELD flip, so on prod today the pair
// derives shield: null everywhere and the cards render ZERO new DOM — byte-identical to before
// this slice. Malformed/missing numbers (an older cached bundle racing the column add, a NaN)
// fail closed to the same hidden state.

export interface MeterReading {
  current: number
  max: number
  /** 0–100, clamped (a server clamp breach must never overflow the bar). */
  pct: number
}

export interface ShipMeterPair {
  /** null = shieldless (max_shield <= 0 / missing / non-finite) → render NOTHING shield-shaped. */
  shield: MeterReading | null
  hull: MeterReading
}

const clampPct = (current: number, max: number): number =>
  max > 0 ? Math.max(0, Math.min(100, (current / max) * 100)) : 0

const finite = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0)

export function shipMeterPair(ship: {
  shield?: number | null
  max_shield?: number | null
  hp: number
  max_hp: number
}): ShipMeterPair {
  const maxShield = finite(ship.max_shield)
  const shield = finite(ship.shield)
  const hp = finite(ship.hp)
  const maxHp = finite(ship.max_hp)
  return {
    shield: maxShield > 0 ? { current: shield, max: maxShield, pct: clampPct(shield, maxShield) } : null,
    hull: { current: hp, max: maxHp, pct: clampPct(hp, maxHp) },
  }
}

/** The sr-only pair label ("Shield 3/40 · Hull 90/100") — spoken only when the shield row shows. */
export function meterPairSrLabel(pair: ShipMeterPair): string | null {
  if (!pair.shield) return null
  return `Shield ${pair.shield.current}/${pair.shield.max} · Hull ${pair.hull.current}/${pair.hull.max}`
}
