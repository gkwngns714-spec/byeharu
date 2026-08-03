import { test, expect } from '@playwright/test'
import { mainShipInstanceStatusLabel } from '../src/features/map/mainshipStatusLabel'

// Pure unit proof for the raw-status labeler. 4C-CLIENT: the marker-based location labeler
// (resolveMainShipStatusLabel) was deleted with the per-ship marker pipeline; its leak-safety
// tests went with it. Run: `npx playwright test mainshipStatusLabel.spec.ts`.

// TRADE-UI-1 — the raw main_ship_instances.status enum labeler consumed by the ship-switcher (migration 0043).
test('instance status: every enum value maps to a non-raw human label', () => {
  // ONE NAME PER STATE (2026-08-03): "Idle" / "In transit" / "Wrecked" are the same words the
  // location resolver (shipLocation.ts) and the recovery copy (shipRecovery.ts) speak — a ship
  // never wears two names for one state depending on the surface.
  const cases: Record<string, string> = {
    home: 'Idle', traveling: 'In transit', hunting: 'Hunting', trading: 'Trading',
    exploring: 'Exploring', mining: 'Mining', retreating: 'Retreating', returning: 'Returning',
    repairing: 'Repairing', destroyed: 'Wrecked',
  }
  for (const [status, label] of Object.entries(cases)) {
    expect(mainShipInstanceStatusLabel(status)).toBe(label)
  }
})

test('instance status: an unmapped/future value falls back to the raw string (never blank)', () => {
  expect(mainShipInstanceStatusLabel('some_future_status')).toBe('some_future_status')
})
