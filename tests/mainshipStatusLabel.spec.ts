import { test, expect } from '@playwright/test'
import { mainShipInstanceStatusLabel } from '../src/features/map/mainshipStatusLabel'

// Pure unit proof for the raw-status labeler. 4C-CLIENT: the marker-based location labeler
// (resolveMainShipStatusLabel) was deleted with the per-ship marker pipeline; its leak-safety
// tests went with it. Run: `npx playwright test mainshipStatusLabel.spec.ts`.

// TRADE-UI-1 — the raw main_ship_instances.status enum labeler consumed by the ship-switcher (migration 0043).
test('instance status: every enum value maps to a non-raw human label', () => {
  const cases: Record<string, string> = {
    home: 'Ready to launch', traveling: 'Traveling', hunting: 'Hunting', trading: 'Trading',
    exploring: 'Exploring', mining: 'Mining', retreating: 'Retreating', returning: 'Returning',
    repairing: 'Repairing', destroyed: 'Disabled',
  }
  for (const [status, label] of Object.entries(cases)) {
    expect(mainShipInstanceStatusLabel(status)).toBe(label)
  }
})

test('instance status: an unmapped/future value falls back to the raw string (never blank)', () => {
  expect(mainShipInstanceStatusLabel('some_future_status')).toBe('some_future_status')
})
