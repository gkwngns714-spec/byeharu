import { Meter, type MeterTone } from '../../components/ui'
import { meterPairSrLabel, type ShipMeterPair } from './meterPair'

// SHIELD-2 — THE one shield/hull bar pair (the classic layout: shield ABOVE hull), shared by
// ShipStatusCard and ShipDossier so the bar markup exists exactly once. Rendering rules:
//   · shield row — ONLY when the pure view-model derived a reading (max_shield > 0; data-gated,
//     no flag — every ship is 0/0 on prod today, so this renders nothing new anywhere yet), plus
//     the sr-only "Shield x/y · Hull x/y" pair label riding the same condition;
//   · hull row — byte-identical markup to the pre-SHIELD-2 ShipStatusCard block (label row +
//     Meter), tone owned by the caller (the status card keeps its disabled/danger logic).
export function MeterPairBars({ pair, hullTone }: { pair: ShipMeterPair; hullTone: MeterTone }) {
  const srLabel = meterPairSrLabel(pair)
  return (
    <>
      {pair.shield && (
        <>
          <div className="flex items-center justify-between text-xs text-ink-faint" data-testid="ship-shield-meter">
            <span>Shield</span>
            <span className="text-ink">{pair.shield.current} / {pair.shield.max}</span>
          </div>
          <Meter pct={pair.shield.pct} tone="accent" className="mt-1" />
          {srLabel && <span className="sr-only">{srLabel}</span>}
        </>
      )}
      <div className={pair.shield ? 'mt-2 flex items-center justify-between text-xs text-ink-faint' : 'flex items-center justify-between text-xs text-ink-faint'}>
        <span>Hull integrity</span>
        <span className="text-ink">{pair.hull.current} / {pair.hull.max}</span>
      </div>
      <Meter pct={pair.hull.pct} tone={hullTone} className="mt-1" />
    </>
  )
}
