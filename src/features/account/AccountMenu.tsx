import { useEffect, useState } from 'react'
import { useShellState } from '../../app/shellState'
import { useAuthStore } from '../../store/authStore'
import { getCommissionConfigRows, getWalletBalance } from '../map/tradeApi'
import { foldStartingCredits, salvageWalletDisplay } from '../port/salvageMarket'
import { Button, Icon, SectionLabel, StatRow } from '../../components/ui'

// ACCOUNT (owner order 2026-08-03: "make another tab of account - showing info as a whole") — the
// top-corner profile affordance in AppShell's header, NOT a bottom-nav cell: the thumb bar is for
// destinations you act on, identity is something you check. One tap shows the player "as a whole":
// who they are (email), what they hold (credits), what they own (ships), what they've done
// (battle reports), and the one account ACTION (sign out — moved here from the old Command
// footer; one home per control).
//
// DATA HONESTY — everything composes reads that already exist:
//   · ships / reports come from the shell's already-polled state (zero new fetches);
//   · credits use the SAME owner-read pair every port panel uses (getWalletBalance +
//     starting_credits via getCommissionConfigRows), folded through the ONE null-honest display
//     helper salvageWalletDisplay — '—' over a false 0, "(starting credits)" while the lazy
//     wallet row doesn't exist yet. The pair is read when the panel OPENS (a closed menu costs
//     nothing), and a fleet/battle count we cannot source honestly is simply not shown.

export function AccountMenu() {
  const { selection, combat } = useShellState()
  const user = useAuthStore((s) => s.user)
  const signOut = useAuthStore((s) => s.signOut)

  const [open, setOpen] = useState(false)
  const [wallet, setWallet] = useState<number | null | 'error' | undefined>(undefined)
  const [startingCredits, setStartingCredits] = useState<number | null>(null)

  // Read the wallet pair when the panel opens (and re-read on every open — credits move).
  useEffect(() => {
    if (!open) return
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
  }, [open])

  // Escape closes — the same dismissal every overlay owes the player.
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])

  const shipCount = selection.ships.length
  const wreckCount = selection.ships.filter((s) => s.status === 'destroyed').length

  return (
    <div className="relative">
      <button
        type="button"
        aria-label="Account"
        aria-expanded={open}
        data-testid="account-open"
        onClick={() => setOpen((v) => !v)}
        className={`flex h-11 w-11 items-center justify-center rounded-lg transition-colors ${
          open ? 'text-accent' : 'text-ink-muted hover:text-ink'
        }`}
      >
        <Icon name="profile" size={22} />
      </button>

      {open && (
        <>
          {/* Click-away backdrop (transparent; the panel sits above it). */}
          <button
            type="button"
            aria-label="Close account panel"
            data-testid="account-backdrop"
            onClick={() => setOpen(false)}
            className="fixed inset-0 z-40 cursor-default"
          />
          <div
            data-testid="account-panel"
            className="absolute right-0 top-full z-50 mt-1 w-72 max-w-[calc(100vw-1.5rem)] rounded-lg border border-edge bg-surface/95 p-3 shadow-overlay backdrop-blur"
          >
            <SectionLabel>Account</SectionLabel>
            <p className="truncate text-sm font-medium text-ink" data-testid="account-email">
              {user?.email ?? 'Signed in'}
            </p>

            <dl className="mt-3 space-y-1.5 border-t border-edge pt-3 text-sm">
              <StatRow
                label="Credits"
                value={
                  <span className="font-mono tabular-nums" data-testid="account-credits">
                    {salvageWalletDisplay(wallet, startingCredits)}
                  </span>
                }
              />
              <StatRow
                label="Ships"
                value={<span className="font-mono tabular-nums">{shipCount}</span>}
                hint={wreckCount > 0 ? `(${wreckCount} wrecked)` : undefined}
              />
              <StatRow
                label="Battle reports"
                value={<span className="font-mono tabular-nums">{combat.reports.length}</span>}
              />
            </dl>

            {/* EMPTY STATE, first-run: a brand-new player sees what these numbers become. */}
            {shipCount === 0 && (
              <p className="mt-2 text-xs text-ink-muted">
                Nothing owned yet — claim your first ship on the Mission tab and your ships and
                credits show up here.
              </p>
            )}

            <div className="mt-3 border-t border-edge pt-3">
              <Button
                variant="ghost"
                size="sm"
                className="w-full"
                data-testid="account-signout"
                onClick={signOut}
              >
                Sign out
              </Button>
            </div>
          </div>
        </>
      )}
    </div>
  )
}
