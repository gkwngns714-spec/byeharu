import { test, expect, type Page } from '@playwright/test'

// OSN-COORD-ENABLE-1C — RENDERED coordinate-capability proof. Drives the REAL <GalaxyMap> (mounted by
// tests/harness/galaxy.html) and asserts the empty-space coordinate command surface (SpaceMoveControls,
// data-testid="s6c-panel") mounts/unmounts SOLELY from the server-derived runtime capability
// (coordinate_travel_available) plus the existing movement-flag + ship-eligibility conditions. The injected
// fetcher models the server; nothing connects. Port-to-port UI (PortNavPanel) is a separate surface, is not
// mounted here, and is unchanged by 1C — its own UI proof remains green.

const baseState = {
  coordinateTravelAvailable: false,
  fail: false,
  spaceMoveEnabled: true,
  shipPresent: true,
  shipStatus: 'stationary',
  shipSpatialState: 'in_space',
}

async function boot(page: Page, patch: Record<string, unknown>) {
  const state = { ...baseState, ...patch }
  await page.addInitScript((s) => {
    ;(window as unknown as { __state: unknown }).__state = s
  }, state)
  await page.goto('/galaxy.html')
}

const set = (page: Page, patch: Record<string, unknown>) =>
  page.evaluate((p) => (window as unknown as { __set: (x: unknown) => void }).__set(p), patch)

const panel = (page: Page) => page.getByTestId('s6c-panel')

// item 4 — capability false → no coordinate controls (the production dark default)
test('coordinate controls stay hidden while the server capability is false (dark default)', async ({ page }) => {
  await boot(page, { coordinateTravelAvailable: false })
  await expect(panel(page)).toHaveCount(0)
})

// item 5 — readiness fetch failure → no coordinate controls
test('coordinate controls stay hidden on a readiness fetch failure', async ({ page }) => {
  await boot(page, { fail: true, coordinateTravelAvailable: true })
  await expect(panel(page)).toHaveCount(0)
})

// item 6 — capability true + eligible + movement enabled → controls mount
test('coordinate controls mount when capability is true and the ship is eligible', async ({ page }) => {
  await boot(page, { coordinateTravelAvailable: true, spaceMoveEnabled: true })
  await expect(panel(page)).toBeVisible()
})

// item 7 — controls hidden for non-eligible ships even when capability is true
test('coordinate controls stay hidden for non-eligible ships even when capability is true', async ({ page }) => {
  await boot(page, { coordinateTravelAvailable: true, spaceMoveEnabled: true })
  await expect(panel(page)).toBeVisible() // eligible baseline

  await set(page, { shipStatus: 'destroyed' })
  await expect(panel(page)).toHaveCount(0) // destroyed

  await set(page, { shipStatus: 'stationary', shipSpatialState: 'in_transit' })
  await expect(panel(page)).toHaveCount(0) // in transit

  await set(page, { shipSpatialState: 'in_space', shipPresent: false })
  await expect(panel(page)).toHaveCount(0) // missing ship

  // returning to an eligible ship re-mounts the surface (lifecycle re-evaluation works)
  await set(page, { shipPresent: true })
  await expect(panel(page)).toBeVisible()
})

// extra — movement domain disabled keeps it hidden even if capability is true (defense in depth)
test('coordinate controls stay hidden when the movement domain is disabled', async ({ page }) => {
  await boot(page, { coordinateTravelAvailable: true, spaceMoveEnabled: false })
  await expect(panel(page)).toHaveCount(0)
})
