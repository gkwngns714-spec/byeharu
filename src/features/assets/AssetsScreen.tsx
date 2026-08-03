import { useEffect, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { getCommissionConfigRows, getWalletBalance } from '../map/tradeApi'
import { foldStartingCredits, salvageWalletDisplay } from '../port/salvageMarket'
import { useAssetLedger } from './useAssetLedger'
import { AssetsLedgerView } from './AssetsLedgerView'

// ASSETS-TAB (owner order 2026-08-04: "i need to be able to see my assets. make a assets tab and
// show what i have, the estimate price, on which city etc.") — asked the moment after "where is my
// ship's cargo?", which they could not find.
//
// THE SCREEN ANSWERS THREE QUESTIONS IN THAT ORDER: what do I own → where is it → what is it worth
// THERE. The top level of the page is CITY, not item type: location is the whole point of the item
// model (storage is per-port; you can only reach it while docked there), and a flat list of items
// with one number beside each would quietly imply a single global stash — which is exactly the
// model migration 0333 deleted.
//
// FINDABILITY IS HALF THE SLICE. Before this, the only way to see what a fleet was carrying was to
// open Ships, pick a ship, and look in the right-hand rail. The hold was fleet-wide underneath, but
// reaching it meant choosing a ship first — the per-ship framing the owner had already rejected
// once ("make inventory not per ship, but for total fleet"). That rail panel is DELETED, not
// duplicated: one home per panel, and this is now the home.
//
// THIS FILE OWNS THE READS AND NOTHING ELSE. The layout is AssetsLedgerView (pure props, so the
// rendered proof can drive it across every price-coverage state); the model and every number are
// assetLedger.ts. There is no arithmetic in either this file or the view.

export function AssetsScreen() {
  const { game, map, selection } = useShellState()
  const refreshKey = `${map.mainShip?.status ?? 'n'}`

  const { ledger, unavailable, pricesUnavailable, shipCount, fleetCount } = useAssetLedger(
    refreshKey,
    map.fleetPositions,
    game.locations,
    selection.ships,
  )

  // CREDITS — the SAME owner-read pair AccountMenu and every port panel use, folded through the
  // one null-honest display helper. Not a second wallet authority: same two calls, same helper,
  // '—' over a false 0 while the lazy wallet row does not exist yet.
  const [wallet, setWallet] = useState<number | null | 'error' | undefined>(undefined)
  const [startingCredits, setStartingCredits] = useState<number | null>(null)
  useEffect(() => {
    let alive = true
    void (async () => {
      const [balance, rows] = await Promise.all([
        getWalletBalance().catch(() => 'error' as const),
        getCommissionConfigRows().catch(() => []),
      ])
      if (!alive) return
      setWallet(balance)
      setStartingCredits(foldStartingCredits(rows.find((r) => r.key === 'starting_credits')?.value))
    })()
    return () => {
      alive = false
    }
  }, [refreshKey])

  return (
    <AssetsLedgerView
      ledger={ledger}
      unavailable={unavailable}
      pricesUnavailable={pricesUnavailable}
      shipCount={shipCount}
      fleetCount={fleetCount}
      creditsLabel={salvageWalletDisplay(wallet, startingCredits)}
    />
  )
}
