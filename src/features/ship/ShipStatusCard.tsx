import { useEffect, useRef, useState } from 'react'
import {
  deriveMainShipStatus,
  renameMainShip,
  repairMainShip,
  type MainShipFleet,
  type MainShipView,
} from '../map/mainshipApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MapLocation } from '../map/mapTypes'
import { Badge, Button, Card, CardHeader, Meter, Notice, SectionLabel, Skeleton, StatRow, type BadgeTone } from '../../components/ui'
import { normalizeShipName, renameReasonMessage, shipNameProblem, SHIP_NAME_MAX } from './shipName'
import { shipMeterPair } from './meterPair'
import { MeterPairBars } from './MeterPairBars'
import { resolveShipLocationLabel } from './shipLocation'

// UI-REBUILD (2b, Ship interior) — THE one ship-status surface. Merges the two former panels
// (MainShipPreview: card + repair + the only recall · MainShipPanel: derived status + destination
// countdown) into a single hierarchy a new player reads top-down:
//   1. IDENTITY   — ship name, hull, state badge, hull-integrity meter
//   2. RIGHT NOW  — one prominent primary action for the current state: Repair when disabled,
//                   the live travel countdown when under way, Return-home when away, a quiet
//                   ready line otherwise
//   3. DETAILS    — cargo + fittings (plain-language stat rows)
// PRESENTATION ONLY: the command wiring is the two panels' existing RPCs verbatim
// (repair_main_ship / request_main_ship_return, same double-submit guards, same testids); the
// data is the shell's already-polled state (no own fetch — the old preview's self-fetch existed
// only because the pre-shell overlay had no shared state).
//
// NO-SOFTLOCK: Repair renders whenever the ship is disabled, independent of the send flag — the
// server's repair safelock is deliberately ungated (0052:120), so the UI matches it. Return-home
// stays send-flag-gated exactly as before (its RPC is flag-gated server-side).

export function ShipStatusCard({
  mainShip,
  fleet,
  movements,
  locations,
  onChanged,
}: {
  mainShip: MainShipView | null
  fleet: MainShipFleet | null
  movements: FleetMovement[]
  locations: MapLocation[]
  onChanged: () => Promise<void>
}) {
  // 1s tick for a smooth countdown/progress bar (the backend stays the source of truth).
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  const [repairing, setRepairing] = useState(false)
  const [repairError, setRepairError] = useState<string | null>(null)
  const repairRef = useRef(false)

  // SHIP-IDENTITY — inline rename ("I should be able to rename them, personalize them" — owner).
  // Same guard idiom as repair: synchronous ref + busy flag; NON-OPTIMISTIC (await RPC → onChanged
  // refetch — the displayed name is always the server's). The pure mirror (shipNameProblem)
  // disables Save before a doomed round-trip; the server (rename_main_ship_self, 0184) re-validates
  // and asserts ownership.
  const [renaming, setRenaming] = useState(false)
  const [nameDraft, setNameDraft] = useState('')
  const [renameBusy, setRenameBusy] = useState(false)
  const [renameError, setRenameError] = useState<string | null>(null)
  const renameRef = useRef(false)

  const ship = mainShip?.has_ship ? mainShip.ship : undefined
  const hull = mainShip?.hull

  async function doRename() {
    if (renameRef.current || !ship) return // synchronous double-submit guard
    const clean = normalizeShipName(nameDraft)
    if (shipNameProblem(nameDraft) || clean === ship.name) return // Save is disabled for these; belt-and-braces
    renameRef.current = true
    setRenameBusy(true)
    setRenameError(null)
    try {
      const res = await renameMainShip(clean, ship.main_ship_id) // §2.5: explicit ship id; server asserts ownership
      if (res.ok) {
        await onChanged() // refetch — the new name arrives from the server, never patched locally
        setRenaming(false)
      } else {
        setRenameError(renameReasonMessage(res.reason))
      }
    } finally {
      renameRef.current = false
      setRenameBusy(false)
    }
  }

  async function doRepair() {
    if (repairRef.current) return // synchronous double-submit guard
    repairRef.current = true
    setRepairing(true)
    setRepairError(null)
    try {
      await repairMainShip(ship?.main_ship_id ?? null) // §2.5: explicit ship id; server asserts ownership
      await onChanged()
    } catch (e) {
      setRepairError(e instanceof Error ? e.message : String(e))
    } finally {
      repairRef.current = false
      setRepairing(false)
    }
  }

  // Shared-state loading (the shell polls; first paint may briefly have no ship view yet).
  // R3: card-shaped Skeleton rows instead of bare pulsing text (same state, design-system placeholder).
  if (!mainShip) {
    return (
      <Card tone="accent" data-testid="ship-status-card" aria-busy="true">
        <Skeleton className="h-5 w-40" />
        <Skeleton className="mt-3 h-2 w-full" />
        <Skeleton className="mt-4 h-20 w-full rounded-lg" />
        <span className="sr-only">Checking on your ship…</span>
      </Card>
    )
  }

  // No commissioned ship yet → the starter-hull teaser (plain language; claiming happens in Command).
  if (!ship) {
    return (
      <Card tone="accent" data-testid="ship-status-card">
        <CardHeader title="No ship yet" subtitle="Claim your first ship from Command to get started." className="mb-2" />
        {hull && (
          <>
            <SectionLabel className="mt-3">Your starter ship will be</SectionLabel>
            {/* R3 density: two stat columns once the card is wide enough (wide ops split). */}
            <dl className="mt-2 grid gap-y-1.5 text-sm sm:grid-cols-2 sm:gap-x-8">
              <StatRow label="Hull" value={hull.name} />
              <StatRow label="Toughness" value={hull.base_hp} />
              <StatRow label="Speed" value={hull.base_speed} />
              <StatRow label="Cargo hold" value={hull.base_cargo_capacity} />
              <StatRow label="Captain seats" value={hull.base_captain_slots} />
              <StatRow label="Module slots" value={hull.base_module_slots} />
            </dl>
          </>
        )}
      </Card>
    )
  }

  // ── Server-authoritative state, derived exactly as the two former panels did ────────────────
  const isDisabled = ship.status === 'destroyed' // disabled/needs-repair, never deletion (10F)
  const displayStatus = isDisabled ? 'disabled' : deriveMainShipStatus(fleet)
  const move = fleet ? movements.find((m) => m.fleet_id === fleet.id && m.status === 'moving') : undefined
  // SHIPLOC — the shared location resolver owns the name/destination/countdown derivation this card
  // used to inline (now single-sourced, reused by ShipDossier). This card's render is byte-identical:
  // it still uses its OWN displayStatus/badge/branch/progress; only destination/heading/etaText are
  // sourced here. (When isDisabled the repair branch renders instead, so destination is never shown —
  // the helper deriving it from the fleet regardless is inert.)
  const loc = resolveShipLocationLabel(fleet, move ?? null, locations)
  const destination = loc.destination
  const heading = loc.heading
  const countdown = loc.etaText
  const progress = move
    ? (() => {
        const dep = new Date(move.depart_at).getTime()
        const arr = new Date(move.arrive_at).getTime()
        if (!(arr > dep)) return null
        return Math.max(0, Math.min(1, (now - dep) / (arr - dep)))
      })()
    : null

  const badge: { tone: BadgeTone; text: string } = isDisabled
    ? { tone: 'warning', text: 'Needs repair' }
    : displayStatus === 'traveling'
      ? { tone: 'accent', text: heading ? 'Returning' : 'Under way' }
      : displayStatus === 'returning'
        ? { tone: 'accent', text: 'Returning' }
        : displayStatus === 'present'
          ? { tone: 'success', text: destination ? `At ${destination}` : 'On station' }
          : { tone: 'neutral', text: 'Ready to launch' }

  // SHIELD-2: the shared shield/hull pair view-model (pure — specs in tests/shipMeterPair.spec.ts).
  // Data-gated: the shield row exists ONLY when max_shield > 0 (every ship is 0/0 on prod until
  // the human ACT-SHIELD flip, so the card's DOM stays byte-identical today — no flag needed).
  const meters = shipMeterPair(ship)

  return (
    <Card tone="accent" data-testid="ship-status-card">
      {/* 1 · IDENTITY — SHIP-DOSSIER: the hull CLASS leads, LOUD (owner: "And what type of ship
          is it?" — that question must never need asking again). The class designator sits ABOVE
          the personal name as an accent ops-register line ('SPARROW-CLASS FRIGATE'), inside the
          heading (class + name ARE the ship's one identity); the ship's own renameable name stays
          the big line. Was: the class as a faint CardHeader subtitle below the name. */}
      <CardHeader
        title={
          <span className="block">
            <span
              data-testid="mainship-class"
              className="block font-mono text-sm font-semibold uppercase tracking-widest text-accent"
            >
              {hull?.name ?? ship.hull_type_id}
            </span>
            <span className="inline-flex items-baseline gap-2">
              <span data-testid="mainship-name">{ship.name}</span>
              {!renaming && (
                <button
                  type="button"
                  data-testid="mainship-rename-open"
                  aria-label="Rename ship"
                  className="text-xs font-normal text-ink-faint underline-offset-2 hover:text-ink hover:underline"
                  onClick={() => {
                    setNameDraft(ship.name)
                    setRenameError(null)
                    setRenaming(true)
                  }}
                >
                  Rename
                </button>
              )}
            </span>
          </span>
        }
        aside={<Badge tone={badge.tone}>{badge.text}</Badge>}
        className="mb-3"
      />
      {renaming && (
        <div className="mb-3" data-testid="mainship-rename-form">
          <div className="flex items-center gap-2">
            <input
              value={nameDraft}
              maxLength={SHIP_NAME_MAX}
              autoFocus
              onChange={(e) => setNameDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void doRename()
                if (e.key === 'Escape') setRenaming(false)
              }}
              className="min-w-0 flex-1 rounded-lg border border-edge bg-surface-2 px-2 py-1 text-sm text-ink"
              aria-label="Ship name"
              data-testid="mainship-rename-input"
            />
            <Button
              size="sm"
              variant="ghost"
              busy={renameBusy}
              busyLabel="Saving…"
              disabled={shipNameProblem(nameDraft) !== null || normalizeShipName(nameDraft) === ship.name}
              onClick={() => void doRename()}
              data-testid="mainship-rename-save"
            >
              Save
            </Button>
            <Button
              size="sm"
              variant="ghost"
              disabled={renameBusy}
              onClick={() => setRenaming(false)}
              data-testid="mainship-rename-cancel"
            >
              Cancel
            </Button>
          </div>
          {shipNameProblem(nameDraft) === 'name_empty' && nameDraft !== '' && (
            <p className="mt-1 text-xs text-ink-faint">{renameReasonMessage('name_empty')}</p>
          )}
          {renameError && (
            <Notice tone="danger" className="mt-2" data-testid="mainship-rename-error">
              {renameError}
            </Notice>
          )}
        </div>
      )}
      {/* SHIELD-2: the classic pair — shield ABOVE hull, via the ONE shared bar component. The
          hull row/tone are the pre-SHIELD-2 markup verbatim; the shield row is data-gated inside
          (max_shield > 0 — nothing new renders while every ship is 0/0). */}
      <MeterPairBars
        pair={meters}
        hullTone={isDisabled ? 'danger' : meters.hull.pct < 100 ? 'accent' : 'success'}
      />

      {/* 2 · RIGHT NOW — one obvious primary action for the current state */}
      <div data-testid="ship-primary-action" className="mt-4 rounded-lg border border-edge bg-surface-2/50 p-3">
        {isDisabled ? (
          <>
            <Notice tone="warning" data-testid="mainship-disabled-note" className="mb-2">
              🛠 Your ship is disabled. Repair it to get moving again.
            </Notice>
            {repairError && (
              <Notice tone="danger" data-testid="mainship-repair-error" className="mb-2">
                {repairError}
              </Notice>
            )}
            <Button
              variant="warning"
              data-testid="mainship-repair"
              busy={repairing}
              busyLabel="Repairing…"
              onClick={doRepair}
              className="min-h-11 w-full"
            >
              Repair ship
            </Button>
          </>
        ) : move ? (
          <>
            <p className="text-sm text-ink">
              {heading ? 'Returning' : <>Traveling to <span className="font-medium">{destination}</span></>}
            </p>
            {countdown && (
              <p data-testid="ship-travel-countdown" className="mt-1 text-2xl font-semibold tabular-nums text-ink">
                {countdown}
              </p>
            )}
            {progress !== null && <Meter pct={progress * 100} tone="accent" className="mt-2 h-1.5" />}
            {!heading && (
              <p className="mt-2 text-xs text-ink-faint">Changed your mind? Use Stop on the Map to turn around.</p>
            )}
          </>
        ) : displayStatus === 'present' ? (
          <>
            <p className="text-sm text-ink">
              Your ship is docked at <span className="font-medium">{destination ?? 'a port'}</span>.
            </p>
            <p className="mt-2 text-center text-xs text-ink-faint">
              Pick your next destination on the Map to set out.
            </p>
          </>
        ) : (
          <p className="text-sm text-ink-muted">
            Ready to fly — pick a destination on the <span className="text-ink">Map</span> to set out.
          </p>
        )}
      </div>

      {/* 3 · DETAILS — cargo + fittings, plain language. R3 density: two stat columns once the
          card is wide enough (the wide ops split hands this card the full or 2/3 row). */}
      <SectionLabel className="mt-4">Cargo & fittings</SectionLabel>
      <dl className="mt-2 grid gap-y-1.5 text-sm sm:grid-cols-2 sm:gap-x-8">
        <StatRow label="Cargo hold" value={ship.cargo_capacity} />
        <StatRow label="Speed" value={hull?.base_speed ?? '—'} />
        <StatRow label="Captain seats" value={ship.captain_slots} />
        <StatRow label="Module slots" value={ship.module_slots} />
      </dl>
    </Card>
  )
}
