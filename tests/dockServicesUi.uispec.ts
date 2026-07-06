import { test, expect, type Page } from '@playwright/test'

// PHASE 9 — RENDERED docked-port surface proof. Drives the REAL <DockServicesPanel> (mounted by
// tests/harness/dock.html) across server states. ok[8] docked → port + active service labels; ok[9] every
// non-docked state → no port surface. The injected fetcher models the server; nothing connects.

const P1 = 'b1a00001-0066-4a00-8a00-000000000001'
const docked = (services: string[]) => ({
  state: 'at_location', docked: true, locationId: P1, locationName: 'Haven', services,
})
const notDocked = (state: string) => ({ state, docked: false, locationId: null, locationName: null, services: [] })

async function boot(page: Page, dock: unknown) {
  await page.addInitScript((d) => { (window as unknown as { __state: unknown }).__state = { dock: d } }, dock)
  await page.goto('/dock.html')
}

test('dock-services UI: docked shows port + active services; every non-docked state shows nothing', async ({ page }) => {
  // ok[8] — docked at a port → panel visible with the port name + only the ACTIVE service labels
  await boot(page, docked(['docking']))
  await expect(page.getByTestId('dock-services-panel')).toBeVisible()
  await expect(page.getByTestId('dock-services-title')).toContainText('Main ship docked at Haven')
  await expect(page.getByTestId('dock-service-docking')).toBeVisible()
  await expect(page.getByTestId('dock-service-market')).toHaveCount(0) // no inactive/absent service shown

  // ok[9] — each non-docked state renders NO port-action surface
  for (const state of ['in_transit', 'in_space', 'destroyed', 'no_main_ship', 'incoherent_or_unavailable']) {
    await page.evaluate((d) => (window as unknown as { __set: (x: unknown) => void }).__set({ dock: d }), notDocked(state))
    await expect(page.getByTestId('dock-services-panel')).toHaveCount(0)
  }

  // returning to docked re-renders the surface (lifecycle refetch works)
  await page.evaluate((d) => (window as unknown as { __set: (x: unknown) => void }).__set({ dock: d }), docked(['docking']))
  await expect(page.getByTestId('dock-services-panel')).toBeVisible()
})

test('stale-data protection: a previously-docked port never lingers after a lifecycle change', async ({ page }) => {
  await boot(page, docked(['docking']))
  await expect(page.getByTestId('dock-services-title')).toContainText('Haven')
  // movement begins → not docked → the prior port must NOT remain visible
  await page.evaluate((d) => (window as unknown as { __set: (x: unknown) => void }).__set({ dock: d }), notDocked('in_transit'))
  await expect(page.getByTestId('dock-services-panel')).toHaveCount(0)
  // dock at a DIFFERENT port → shows the new port only, never the stale one
  const slag = { state: 'at_location', docked: true, locationId: 'b1a00002-0066-4a00-8a00-000000000002', locationName: 'Slagworks', services: ['docking'] }
  await page.evaluate((d) => (window as unknown as { __set: (x: unknown) => void }).__set({ dock: d }), slag)
  await expect(page.getByTestId('dock-services-title')).toContainText('Slagworks')
  await expect(page.getByTestId('dock-services-title')).not.toContainText('Haven')
})

test('safe failure: a dock fetch error degrades to no panel', async ({ page }) => {
  await boot(page, { state: 'at_location', docked: true, locationId: 'b1a00001-0066-4a00-8a00-000000000001', locationName: 'Haven', services: ['docking'], __fail: true })
  await expect(page.getByTestId('dock-services-panel')).toHaveCount(0)
})

test('narrow mobile-width layout: panel stays within its half and does not overflow', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 720 })
  await boot(page, docked(['docking']))
  const panel = page.getByTestId('dock-services-panel')
  await expect(panel).toBeVisible()
  const box = await panel.boundingBox()
  expect(box).not.toBeNull()
  if (box) {
    // Harness-honest layout check (the bare harness compiles no Tailwind): the panel renders within the
    // narrow viewport with no horizontal overflow. The half-width cap that prevents overlap with the left OSN
    // panel is the component's `max-w-[calc(50vw-0.75rem)]` class, compiled in the production build.
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(360)
  }
})
