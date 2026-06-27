import { test, expect } from '@playwright/test'
import {
  PORT_MOVE_RPC,
  portMoveErrorMessage,
  createPortMoveController,
  type PortMoveResult,
  type PortMoveControllerDeps,
} from '../src/features/map/portMoveCommand'
import { SPACE_MOVE_RPC } from '../src/features/map/spaceMoveCommand'
import type { MapLocation } from '../src/features/map/mapTypes'

// PORT-LAUNCH-1B — pure proofs for the location-target command boundary + lifecycle. No browser/DB/network;
// the controller's `rpc` is injected, so these PROVE the command contract (location id + request id ONLY,
// idempotency lifecycle, sanitized errors) without any DB. Run: `npm run verify:osn:port`.

const port = (id: string, name = id): MapLocation => ({
  id,
  name,
  location_type: 'trade_outpost',
  x: 100,
  y: 200,
  base_difficulty: 1,
  reward_tier: 1,
  activity_type: 'none',
  min_power_required: 0,
  is_public: true,
  status: 'active',
})

function recorder() {
  const calls: Array<{ args: unknown[] }> = []
  // Capture EVERY positional argument the controller passes, to prove exactly (locationId, requestId) reach
  // the RPC — no ship/player/coordinate/anchor data is ever appended.
  const rpc = ((...args: unknown[]): Promise<PortMoveResult> => {
    calls.push({ args })
    return Promise.resolve({ ok: true, target_location_id: String(args[0]), arrive_at: '2026-06-27T13:00:00Z' })
  }) as unknown as PortMoveControllerDeps['rpc']
  return { calls, rpc }
}

// ── command boundary: ONLY the location RPC, ONLY (locationId, requestId) ────────────────────────────────
test('the only permitted command is the location-target wrapper — never the coordinate RPC (F2/F6)', () => {
  expect(PORT_MOVE_RPC).toBe('command_main_ship_space_move_to_location')
  expect(PORT_MOVE_RPC).not.toBe(SPACE_MOVE_RPC)
})

test('selecting a port and confirming calls rpc with EXACTLY (destinationId, requestId) — no ship/coord/anchor (F6/F7)', async () => {
  const { calls, rpc } = recorder()
  const ctrl = createPortMoveController({ rpc, genRequestId: () => 'req-1' })
  ctrl.selectPort(port('p1', 'Slagworks'))
  await ctrl.submit()
  expect(calls.length).toBe(1)
  // exactly two positional args reach the RPC: the destination id and the request id — nothing else.
  expect(calls[0].args.length).toBe(2)
  expect(calls[0].args).toEqual(['p1', 'req-1'])
})

test('submit does nothing without a selected port (no command, no leak)', async () => {
  const { calls, rpc } = recorder()
  const ctrl = createPortMoveController({ rpc, genRequestId: () => 'req-1' })
  await ctrl.submit()
  expect(calls.length).toBe(0)
  expect(ctrl.getState().phase).toBe('idle')
})

// ── idempotency lifecycle ───────────────────────────────────────────────────────────────────────────────
test('a retry of the SAME destination reuses the request id; a CHANGED destination mints a new one', async () => {
  let n = 0
  const ids: string[] = []
  const gen = () => {
    const id = `req-${++n}`
    ids.push(id)
    return id
  }
  const seen: string[] = []
  const rpc: PortMoveControllerDeps['rpc'] = async (_loc, requestId) => {
    seen.push(requestId)
    return { ok: false, code: 'unavailable' }
  }
  const ctrl = createPortMoveController({ rpc, genRequestId: gen })

  ctrl.selectPort(port('p1'))
  await ctrl.submit()
  await ctrl.submit() // retry same destination
  expect(seen).toEqual(['req-1', 'req-1']) // reused
  expect(n).toBe(1)

  ctrl.selectPort(port('p2')) // change destination → new key
  await ctrl.submit()
  expect(seen[2]).toBe('req-2')
})

// ── sanitized errors + no local position mutation on rejection (F10) ────────────────────────────────────
test('a server rejection surfaces sanitized copy and keeps the selection (no client repair/mutation)', async () => {
  const rpc: PortMoveControllerDeps['rpc'] = async () => ({ ok: false, code: 'origin_not_anchored', message: 'raw-db-detail-should-not-show' })
  const ctrl = createPortMoveController({ rpc, genRequestId: () => 'req-1' })
  ctrl.selectPort(port('p1', 'Driftmarch'))
  await ctrl.submit()
  const s = ctrl.getState()
  expect(s.phase).toBe('error')
  expect(s.errorCode).toBe('origin_not_anchored')
  expect(s.errorMessage).toBe('Your ship must be docked at a port first.') // sanitized, not the raw message
  expect(s.errorMessage).not.toContain('raw-db-detail')
  expect(s.selected?.id).toBe('p1') // selection preserved; nothing locally mutated
})

test('a thrown/network failure is sanitized and keeps the request id for an idempotent retry', async () => {
  const rpc: PortMoveControllerDeps['rpc'] = async () => {
    throw new Error('boom')
  }
  const ctrl = createPortMoveController({ rpc, genRequestId: () => 'req-1' })
  ctrl.selectPort(port('p1'))
  await ctrl.submit()
  expect(ctrl.getState().errorCode).toBe('network')
  expect(ctrl.getState().requestId).toBe('req-1')
})

test('error copy falls back safely for unknown codes', () => {
  const unavailable = 'That port is not available to travel to right now.'
  expect(portMoveErrorMessage('feature_disabled')).toBe('Port travel is not available yet.')
  expect(portMoveErrorMessage('something_new')).toBe(unavailable)
  expect(portMoveErrorMessage(null)).toBe(unavailable)
})
