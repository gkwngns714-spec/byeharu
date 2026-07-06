import { test, expect } from '@playwright/test'

// OSN-ENABLEMENT-1B — RENDERED player-facing OSN command-surface proof. Drives the REAL <PortNavPanel>
// (mounted by tests/harness) in a real browser, modelling the post-reveal ACTIVE-port server state with
// mainship_space_movement_enabled=true. Proves the rendered surface behaves correctly:
//   panel visibility ← server readiness; current port excluded; eligible active ports shown; select +
//   confirm dispatches the real port-move command (locationId + requestId only); in-transit travel view;
//   refresh derives state from the (changed) server; dark when the server says unavailable.
// The injected portRpc records the dispatch; the REAL RPC execution is proven by the backend journey.

const P1 = 'b1a00001-0066-4a00-8a00-000000000001' // Haven (current dock — must be EXCLUDED)
const P2 = 'b1a00002-0066-4a00-8a00-000000000002' // Slagworks (eligible)
const P3 = 'b1a00003-0066-4a00-8a00-000000000003' // Driftmarch (eligible)

const loc = (id: string, name: string) => ({
  id, name, location_type: 'trade_outpost', x: 0, y: 0, base_difficulty: 1, reward_tier: 1,
  activity_type: 'none', min_power_required: 0, is_public: true, status: 'active',
})

// The anchored post-reveal readiness the server would return for a ship docked at Haven.
const anchoredState = {
  readiness: { osnAvailable: true, originCategory: 'anchored', reason: 'ok', eligibleDestinationIds: [P2, P3] },
  visibleLocations: [loc(P1, 'Haven'), loc(P2, 'Slagworks'), loc(P3, 'Driftmarch')],
  shipStatus: 'stationary', shipSpatialState: 'at_location', spaceMovement: null, currentDockedLocationId: P1,
}

async function boot(page: import('@playwright/test').Page, state: unknown) {
  await page.addInitScript((s) => { (window as unknown as { __state: unknown }).__state = s }, state)
  await page.goto('/')
}

test('rendered OSN PortNav journey: visible→exclude current→select→dispatch→in-transit→refresh→dark', async ({ page }) => {
  await boot(page, anchoredState)

  // 1) panel becomes visible because the server readiness says anchored + osn_available + eligible exist
  await expect(page.getByTestId('port-nav-panel')).toBeVisible()
  await expect(page.getByTestId('port-nav-selection')).toBeVisible()

  // 2) the current port (Haven) is EXCLUDED; the active eligible ports are shown
  await expect(page.getByTestId(`port-nav-dest-${P1}`)).toHaveCount(0)
  await expect(page.getByTestId(`port-nav-dest-${P2}`)).toBeVisible()
  await expect(page.getByTestId(`port-nav-dest-${P3}`)).toBeVisible()

  // 3) select one eligible port THROUGH THE UI, then confirm → dispatches the real command (id + reqId only)
  await page.getByTestId(`port-nav-dest-${P2}`).click()
  await expect(page.getByTestId('port-nav-confirm')).toBeVisible()
  await page.getByTestId('port-nav-confirm').click()
  await expect.poll(() => page.evaluate(() => (window as unknown as { __rpcCalls: unknown[] }).__rpcCalls.length)).toBe(1)
  const call = await page.evaluate(() => (window as unknown as { __rpcCalls: { locationId: string; requestId: string }[] }).__rpcCalls[0])
  expect(call.locationId).toBe(P2)
  expect(call.requestId).toBe('req-ui-fixed-1')
  expect(await page.evaluate(() => (window as unknown as { __committed: number }).__committed)).toBeGreaterThanOrEqual(1)

  // 4) UI refresh derives the in-transit state from the (now-changed) server: travel view + Stop, no selection
  await page.evaluate((p2) => (window as unknown as { __set: (x: unknown) => void }).__set({
    readiness: { osnAvailable: false, originCategory: 'in_transit', reason: 'in_transit', eligibleDestinationIds: [] },
    shipStatus: 'traveling', shipSpatialState: 'in_transit',
    spaceMovement: { id: 'mv-ui-1', status: 'moving', target_kind: 'location', target_location_id: p2, arrive_at: '2026-06-28T03:00:00Z' },
  }), P2)
  await expect(page.getByTestId('port-nav-travel')).toBeVisible()
  await expect(page.getByTestId('port-nav-travel')).toContainText('Slagworks')
  await expect(page.getByTestId('port-nav-selection')).toHaveCount(0) // no stale enabled command surface during transit

  // 5) arrival/dark: server says unavailable and no transit → the panel renders NOTHING (dark-safe)
  await page.evaluate(() => (window as unknown as { __set: (x: unknown) => void }).__set({
    readiness: { osnAvailable: false, originCategory: 'anchored', reason: 'feature_disabled', eligibleDestinationIds: [] },
    shipStatus: 'stationary', shipSpatialState: 'at_location', spaceMovement: null,
  }))
  await expect(page.getByTestId('port-nav-panel')).toHaveCount(0)
})
