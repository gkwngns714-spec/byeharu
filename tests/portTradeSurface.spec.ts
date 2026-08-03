import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { TRADE_MARKET_ENABLED, MAINSHIP_ADDITIONAL_ENABLED, TEAM_COMMAND_ENABLED } from '../src/features/map/osnReleaseGates'
import { salvageWalletDisplay } from '../src/features/port/salvageMarket'

// PORT TRADE SURFACE — the proof that did not exist while the bug did.
//
// THE BUG THIS FILE IS THE ANSWER TO (2026-08-03). A player accepted haul contracts, sailed to the
// destination, and could do nothing. Accepting a contract is a CLAIM, not a transaction — it moves no
// cargo (20260618000179_haul_accept_deliver.sql:259-271) — and delivery FIFO-consumes ship_cargo_lots
// (:387), answering `insufficient_cargo` when there are none (:379-382). The ONLY player-reachable
// producer of ship_cargo_lots is `market_buy`, rendered by MarketPanel, mounted by PortScreen behind
// the COMPILE-TIME constant TRADE_MARKET_ENABLED. Production had `trade_market_enabled = true` on the
// server and `TRADE_MARKET_ENABLED = false` in the bundle, so the door into the economy was never
// drawn and the whole game held ZERO cargo lots.
//
// WHY NO EXISTING PROOF COULD SEE IT. The mismatch lives BETWEEN two systems: the frontend suite has
// no production access (frontend-tests.yml says so in its own header) and cannot read game_config; the
// real-Postgres migration proofs execute SQL and cannot see a TypeScript constant. A compile-time gate
// left dark after its server flag is lit is therefore invisible to every layer — it is not a bug any
// single proof was ever positioned to catch. The complete check compares the constant against the LIVE
// flag and belongs in a production verifier (the repo already has that shape: scripts/osn-postenable-
// verify greps this very file for OSN_COORDINATE_TRAVEL_ENABLED_FRONTEND).
//
// WHAT THIS FILE DOES INSTEAD, deterministically and with no network: it makes a dark mirror gate an
// EXPLICIT, NAMED decision rather than a silent default. Every gate that mirrors a server game_config
// flag must be lit, or must appear in INTENTIONALLY_DARK with a reason. A future feature that ships
// dark-first adds one reviewed line here; the day its server flag lights, that line is the greppable
// liability someone has to delete. Silence — the actual failure mode — is no longer possible.
// It also pins the two seams that flipping the gate exposed (one acting ship per screen; honest
// credits), because those are what made the lit panel still say "you can't".

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const read = (...p: string[]) => readFileSync(join(repo, ...p), 'utf8')

const gates = read('src', 'features', 'map', 'osnReleaseGates.ts')
const portScreen = read('src', 'features', 'port', 'PortScreen.tsx')
const marketPanel = read('src', 'features', 'map', 'MarketPanel.tsx')

// ── 1. THE MIRROR REGISTER — no compile-time gate may sit dark without saying why ────────────────

/** Compile-time constants that MIRROR a server game_config flag. Adding a mirror gate to
 *  osnReleaseGates.ts without adding it here fails the completeness test below. */
const MIRROR_GATES: Array<{ constant: string; serverFlag: string; value: boolean }> = [
  { constant: 'TRADE_MARKET_ENABLED', serverFlag: 'trade_market_enabled', value: TRADE_MARKET_ENABLED },
  {
    constant: 'MAINSHIP_ADDITIONAL_ENABLED',
    serverFlag: 'mainship_additional_commission_enabled',
    value: MAINSHIP_ADDITIONAL_ENABLED,
  },
  { constant: 'TEAM_COMMAND_ENABLED', serverFlag: 'team_command_enabled', value: TEAM_COMMAND_ENABLED },
]

/** A mirror gate deliberately held dark, and WHY. Empty today. An entry here is a standing claim that
 *  the named server flag is also false in production — the moment that stops being true, the surface
 *  it gates is invisible to players while the server serves it, which is exactly the defect above. */
const INTENTIONALLY_DARK: Array<{ constant: string; reason: string }> = []

/** Not a mirror: OSN_COORDINATE_TRAVEL_ENABLED is retired as a UI authority and kept at false ONLY so
 *  the production verifier can grep it. The file says it must never be true; this asserts that. */
test('OSN_COORDINATE_TRAVEL_ENABLED is retired-dark by design and never re-enters the render path', () => {
  expect(gates).toMatch(/export const OSN_COORDINATE_TRAVEL_ENABLED = false as const/)
  const importers = [portScreen, marketPanel]
  for (const src of importers) expect(src).not.toContain('OSN_COORDINATE_TRAVEL_ENABLED')
})

test('every mirror gate in the register is either LIT or named in INTENTIONALLY_DARK', () => {
  const excused = new Set(INTENTIONALLY_DARK.map((d) => d.constant))
  const silentlyDark = MIRROR_GATES.filter((g) => !g.value && !excused.has(g.constant))
  expect(
    silentlyDark.map((g) => `${g.constant} is false while nothing explains it (server flag: ${g.serverFlag})`),
  ).toEqual([])
})

test('every INTENTIONALLY_DARK entry names a real gate and carries a reason', () => {
  const known = new Set(MIRROR_GATES.map((g) => g.constant))
  for (const d of INTENTIONALLY_DARK) {
    expect(known.has(d.constant), `${d.constant} is not a registered mirror gate`).toBe(true)
    expect(d.reason.trim().length).toBeGreaterThan(20)
  }
  // A gate that is LIT must not also claim to be intentionally dark — the register would be lying.
  const lit = new Set(MIRROR_GATES.filter((g) => g.value).map((g) => g.constant))
  expect(INTENTIONALLY_DARK.filter((d) => lit.has(d.constant))).toEqual([])
})

test('the register is COMPLETE: every mirror gate declared in the source is registered here', () => {
  // Mirror gates are the ones the file documents as mirroring a server flag; the register must not
  // drift behind the source. Every exported *_ENABLED constant is either a registered mirror or the
  // one documented non-mirror (the retired coordinate gate).
  const declared = [...gates.matchAll(/export const ([A-Z0-9_]+_ENABLED)\b/g)].map((m) => m[1])
  expect(declared.length).toBeGreaterThan(0)
  const registered = new Set([...MIRROR_GATES.map((g) => g.constant), 'OSN_COORDINATE_TRAVEL_ENABLED'])
  expect(declared.filter((d) => !registered.has(d))).toEqual([])
})

test('each registered mirror names its server flag in the source, so the pairing is greppable', () => {
  for (const g of MIRROR_GATES) {
    expect(gates, `${g.constant} must document its server flag ${g.serverFlag}`).toContain(g.serverFlag)
  }
})

// ── 2. THE LOOP'S DOOR — the market must be mounted, on the port's acting ship ────────────────────

test('PortScreen mounts MarketPanel behind the trade gate', () => {
  expect(portScreen).toContain('TRADE_MARKET_ENABLED && (')
  expect(portScreen).toMatch(/<MarketPanel\b/)
})

test('MarketPanel acts on the SAME ship as the rest of the Port screen, never the raw shell selection', () => {
  // The seam the gate flip exposed: every other panel here takes `chosenShipId` (resolveChosenShipId
  // over the ports the player actually has ships at), while MarketPanel used to take
  // shipSelection.selectedShip. Those diverge whenever the shared selection points at an UNDOCKED
  // ship, and the market alone then answers not_docked on a screen where everything else works.
  const mount = portScreen.slice(portScreen.indexOf('<MarketPanel'), portScreen.indexOf('<MarketPanel') + 240)
  expect(mount).toContain('selectedShip={chosenShip}')
  expect(mount).not.toContain('shipSelection.selectedShip')
  expect(mount).not.toContain('shipSelection.selectedShipId')
  // chosenShip is DERIVED from the resolved chosen ship id — one acting-ship authority, not a second.
  expect(portScreen).toMatch(/const chosenShip =[\s\S]{0,160}chosenShipId/)
})

test('a completed trade re-reads the sibling that consumes the cargo (the contract board hold count)', () => {
  // Composition, not a second refresh path: the trade bumps the ONE lifecycleKey every panel on this
  // screen already refetches on, so the haul board's "hold n/qty" cannot show the pre-purchase hold.
  expect(marketPanel).toContain('onCargoChanged?.()')
  expect(portScreen).toContain('onCargoChanged={onCargoChanged}')
  expect(portScreen).toMatch(/const lifecycleKey = [^\n]*cargoEpoch/)
  // and the board is keyed off that same lifecycleKey
  expect(portScreen).toMatch(/<HaulBoardPanel[\s\S]{0,200}lifecycleKey=\{lifecycleKey\}/)
})

// ── 3. HONEST CREDITS — the lit panel must not tell a player they are broke when they are not ─────

test('MarketPanel renders the wallet through the ONE honest fold, never a collapsed 0', () => {
  // 0093 makes the wallet LAZY: no row means the player is still on `starting_credits`, so 0 is a
  // false claim. On production only 1 of 73 ship-owning players had a wallet row — the old
  // `typeof w === 'number' ? w : 0` would have told 72 players they had nothing.
  expect(marketPanel).toContain('salvageWalletDisplay(wallet, startingCredits)')
  expect(marketPanel).not.toContain("typeof w === 'number' ? w : 0")
  // reused, never re-implemented (the repairEconomy.ts precedent)
  expect(marketPanel).toMatch(/import \{ foldStartingCredits, salvageWalletDisplay \} from '\.\.\/port\/salvageMarket'/)
})

test('the wallet fold itself: no row → the starting-credits seed, never 0', () => {
  // Behavioural pin of the semantics the panel now depends on (salvageMarket.spec.ts owns the full
  // battery; this asserts the exact case the panel got wrong).
  expect(salvageWalletDisplay(null, 1000)).toBe('1,000 (starting credits)')
  expect(salvageWalletDisplay(null, 1000)).not.toBe('0')
  expect(salvageWalletDisplay('error', 1000)).toBe('—')
  expect(salvageWalletDisplay(undefined, 1000)).toBe('—')
  expect(salvageWalletDisplay(0, 1000)).toBe('0') // a REAL zero row still reads zero
  expect(salvageWalletDisplay(1234, 1000)).toBe('1,234')
})
