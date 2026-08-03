import { test, expect } from '@playwright/test'
import {
  A_ZONE_IS_NOT_A_HUNT,
  HOW_A_FIGHT_STARTS,
} from '../src/features/command/howAFightStarts'

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// RENDERED PROOF — "i went to snare, zone, no fighting happens" (owner, 2026-08-03).
//
// The pure specs pin the words and the eligibility rules. Only a rendered proof can show that the
// player is actually OFFERED the way out of the dead end: that a real button exists on the real
// panel, in the DOM, and that pressing it hands the map the one id that opens the existing hunt
// control. That is the exact link that did not exist while the owner was tapping.
//
// Harness: tests/harness/hunt.html?zone=site|loose&miss=settled|inflight|none — the REAL
// <ZoneInfoPanel> and <NearMissSection> from src, nothing stubbed but the callback.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

test('THE DEAD END IS OPEN: a pirate zone offers the site inside it, and pressing it hands over that site', async ({ page }) => {
  await page.goto('/hunt.html?zone=site&miss=none')
  const button = page.getByTestId('zone-info-hunt-site')
  await expect(button).toBeVisible()
  // Named, not generic — the player has to recognise it as the thing on the map.
  await expect(button).toHaveText('Hunt at Snare')
  await button.click()
  // The map turns this id into a marker selection, which mounts the EXISTING hunt section. The
  // harness records the id rather than re-implementing that; a second hunt path is what we refuse
  // to build, so there is deliberately nothing else to assert here.
  expect(await page.evaluate(() => (window as unknown as { __huntSiteCalls: string[] }).__huntSiteCalls)).toEqual([
    'loc-snare',
  ])
})

test('the panel SAYS how a fight starts, in the one wording, right where the confusion happens', async ({ page }) => {
  await page.goto('/hunt.html?zone=site&miss=none')
  const warning = page.getByTestId('zone-info-warning')
  await expect(warning).toContainText(A_ZONE_IS_NOT_A_HUNT)
  await expect(warning).toContainText(HOW_A_FIGHT_STARTS)
  // The sentence that sent the owner into the blob for an afternoon must not be on screen.
  await expect(warning).not.toContainText('almost always')
})

test('a zone with nothing to fight at offers NO button — never an affordance that leads nowhere', async ({ page }) => {
  await page.goto('/hunt.html?zone=loose&miss=none')
  await expect(page.getByTestId('zone-info-panel')).toBeVisible()
  await expect(page.getByTestId('zone-info-hunt-site')).toHaveCount(0)
  // …and it still tells the truth about what the zone does, without instructing the impossible.
  const warning = page.getByTestId('zone-info-warning')
  await expect(warning).toContainText(A_ZONE_IS_NOT_A_HUNT)
  await expect(warning).not.toContainText(HOW_A_FIGHT_STARTS)
})

// ── THE NEAR MISS, RENDERED ──────────────────────────────────────────────────────────────────────

test('A ROLLED-AND-MISSED CROSSING IS NO LONGER SILENCE — it renders as a close call', async ({ page }) => {
  await page.goto('/hunt.html?zone=loose&miss=settled')
  const section = page.getByTestId('near-miss-section')
  await expect(section).toBeVisible()
  await expect(section).toContainText('Slipped past the pirates around Snare.')
  // No probability reaches the screen: the event is the news, a percentage is a debug readout.
  await expect(section).not.toContainText('%')
  await expect(section).not.toContainText('0.5')
})

test('nothing is claimed while the fleet is still flying — the crossing has not happened yet', async ({ page }) => {
  await page.goto('/hunt.html?zone=loose&miss=inflight')
  await expect(page.getByTestId('near-miss-section')).toHaveCount(0)
})

test('no rolls at all renders NOTHING — a trip that never entered a zone is not a near miss', async ({ page }) => {
  await page.goto('/hunt.html?zone=loose&miss=none')
  await expect(page.getByTestId('near-miss-section')).toHaveCount(0)
  // The self-hide is total: no empty card, no "nothing happened" line beside the reports.
  await expect(page.getByText('Close calls')).toHaveCount(0)
})
