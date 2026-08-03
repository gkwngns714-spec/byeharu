import { test } from '@playwright/test'
const SHOTS = process.env.LOOK_DIR ?? ''

// A LOOK, not an assertion. Captures the rendered fight so the change can be SEEN rather than
// claimed: the fleet as one glyph, the rounds crossing, the numbers landing. Kept as a uispec so it
// runs on the same harness as the proofs; it asserts nothing, so it can never go red on its own.
test('LOOK: the fight, drawn', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 900, height: 760 })
  await page.goto('/fight.html')
  await page.waitForSelector('#map-host svg > g[transform]')
  for (const [i, ms] of [0, 120, 260, 420, 900].entries()) {
    await page.waitForTimeout(i === 0 ? ms : 140)
    const png = await page.locator('#map-host').screenshot()
    await testInfo.attach(`fight-${String(i)}-${String(ms)}ms`, { body: png, contentType: 'image/png' })
    if (SHOTS) await page.locator('#map-host').screenshot({ path: `${SHOTS}/fight-${String(i)}.png` })
  }
  await page.getByTestId('advance-tick').click()
  for (let i = 0; i < 4; i++) {
    await page.waitForTimeout(700)
    const png = await page.locator('#map-host').screenshot()
    await testInfo.attach(`step-${String(i)}`, { body: png, contentType: 'image/png' })
    if (SHOTS) await page.locator('#map-host').screenshot({ path: `${SHOTS}/step-${String(i)}.png` })
  }
})
