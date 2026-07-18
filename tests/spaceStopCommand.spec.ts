import { test, expect } from '@playwright/test'
import { selectActiveLegacyMovement } from '../src/features/map/spaceStopCommand'

// OSN-4 origin, 4A-POST trimmed — pure proofs for the ONE surviving export: the active-legacy-movement
// selector that AppShell's consolidated arrival-settle wiring still needs while the legacy drain runs
// (removing the drain is 4b-DROP's job). The per-ship Stop surface (RPCs / predicates / controller)
// was deleted with the per-ship movement client. No browser/page/DB. Run: `npm run verify:osn:osn4`.

type Move = { fleet_id: string; status: string; mission_type?: string }

const moves: Move[] = [
  { fleet_id: 'f1', status: 'completed', mission_type: 'rally' },
  { fleet_id: 'f2', status: 'moving', mission_type: 'rally' },
  { fleet_id: 'f1', status: 'moving', mission_type: 'return_home' },
]

test('selectActiveLegacyMovement picks the fleet\'s single moving row', () => {
  expect(selectActiveLegacyMovement({ id: 'f2' }, moves)).toEqual({ fleet_id: 'f2', status: 'moving', mission_type: 'rally' })
  // Matching is by fleet id AND status='moving' — a completed row for the same fleet never matches.
  expect(selectActiveLegacyMovement({ id: 'f1' }, moves)).toEqual({ fleet_id: 'f1', status: 'moving', mission_type: 'return_home' })
})

test('selectActiveLegacyMovement: no fleet or no moving row → null', () => {
  expect(selectActiveLegacyMovement(null, moves)).toBeNull()
  expect(selectActiveLegacyMovement(undefined, moves)).toBeNull()
  expect(selectActiveLegacyMovement({ id: 'f3' }, moves)).toBeNull()
  expect(selectActiveLegacyMovement({ id: 'f1' }, [])).toBeNull()
})
