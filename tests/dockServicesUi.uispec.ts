import { test, expect, type Page } from '@playwright/test'

// PHASE 9 — RENDERED docked-port surface proof. Drives the REAL <DockServicesPanel> (mounted by
// tests/harness/dock.html) across server states. ok[8] docked → port + active service labels; ok[9] every
// non-docked state → no port surface. The injected fetcher models the server; nothing connects.

const P1 = 'b1a00001-0066-4a00-8a00-000000000001'
const docked = (services: string[]) => ({
  state: 'at_location', docked: true, locationId: P1, locationName: 'Haven Reach', services,
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
  await expect(page.getByTestId('dock-services-title')).toContainText('Main ship docked at Haven Reach')
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
