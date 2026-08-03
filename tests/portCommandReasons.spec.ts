import { test, expect } from '@playwright/test'
import { craftModuleErrorMessage } from '../src/features/modules/modulesTypes'
import { recruitCaptainErrorMessage } from '../src/features/captains/captainsTypes'
import { shipyardReasonMessage } from '../src/features/port/shipyardReasonMessage'
import { transferReasonMessage } from '../src/features/inventory/transferReasonMessage'

// ITEMS LIVE AT PORTS (0333) — the SEAM spec.
//
// The server side of this slice made three commands SPATIAL: craft_module, recruit_captain and
// start_hull_build now derive their port from the acting ship's dock and refuse with a typed
// `not_docked` (plus `port_has_no_storage` / `ship_not_found`) instead of silently drawing from a
// placeless pool. A typed reason code the client cannot render is exactly the 0292 half-slice
// failure — a WORKING refusal shown to the player as "unavailable" — so the copy for those codes is
// pinned here, for every one of the four surfaces that can now emit them.
//
// These two maps (craft, recruit) had NO spec at all before this file; shipyard and transfer each
// had one. One home for the whole vocabulary keeps them from drifting apart.

const LAW3_CODES = ['not_docked', 'port_has_no_storage', 'ship_not_found'] as const

test('every surface that can now refuse on LOCATION has specific copy for all three law-3 codes', () => {
  for (const code of LAW3_CODES) {
    // craft — the envelope is `code`-keyed and the map is the fallback when the server sends no message
    expect(craftModuleErrorMessage(code)).not.toBe(craftModuleErrorMessage('unavailable'))
    // recruit — same shape, via the res-object helper
    expect(recruitCaptainErrorMessage({ code })).not.toBe(recruitCaptainErrorMessage({ code: 'unavailable' }))
    // shipyard — reason-keyed with a generic fallback
    expect(shipyardReasonMessage(code)).not.toBe('Shipyard unavailable.')
  }
  // the transfer verb already spoke this vocabulary; it must still say the same thing.
  expect(transferReasonMessage('not_docked')).toBe('Dock at the port to reach its storage.')
  expect(transferReasonMessage('port_has_no_storage')).toBe('This place has no storage.')
})

test('the not_docked copy tells the player WHAT TO DO, on every surface', () => {
  // Not a style check: the whole point of the code is that the player is standing in the wrong
  // place, so the line has to say "dock" — "unavailable" would be the 0292 defect again.
  expect(craftModuleErrorMessage('not_docked')).toContain('Dock at a port')
  expect(recruitCaptainErrorMessage({ code: 'not_docked' })).toContain('Dock at a port')
  expect(shipyardReasonMessage('not_docked')).toContain('Dock at a port')
  expect(transferReasonMessage('not_docked')).toContain('Dock at the port')
})

test('the shortfall copy now names the PLACE — a port shortfall is not a player-wide one', () => {
  // 0333: there is no player-wide pool any more, so "not enough materials" without a place would be
  // a lie the player cannot act on (they may have plenty at the port they just left).
  for (const msg of [
    craftModuleErrorMessage('insufficient_items'),
    recruitCaptainErrorMessage({ code: 'insufficient_items' }),
    shipyardReasonMessage('insufficient_items'),
  ]) {
    expect(msg).toContain('this port')
  }
  expect(transferReasonMessage('insufficient_stored')).toContain("port doesn't have")
})

test('the server MESSAGE still wins over the map, and the shortfall context still appends', () => {
  // The wrapper envelopes carry the server's own message; the maps are the fallback. Preserving
  // that precedence is what keeps a future server-side reason renderable without a client release.
  expect(recruitCaptainErrorMessage({ code: 'not_docked', message: 'server says so' })).toBe('server says so')
  expect(
    recruitCaptainErrorMessage({ code: 'insufficient_items', item_id: 'scrap', have: 1, need: 4 }),
  ).toContain('(scrap: 1/4)')
})

test('an unknown code still falls back on every surface (no crash, no blank)', () => {
  expect(craftModuleErrorMessage('a_code_from_the_future')).toBe(craftModuleErrorMessage('unavailable'))
  expect(recruitCaptainErrorMessage({ code: 'a_code_from_the_future' })).toBe(
    recruitCaptainErrorMessage({ code: 'unavailable' }),
  )
  expect(shipyardReasonMessage('a_code_from_the_future')).toBe('Shipyard unavailable.')
  expect(transferReasonMessage('a_code_from_the_future')).toBe('Move unavailable.')
})
