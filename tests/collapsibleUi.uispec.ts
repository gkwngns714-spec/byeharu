import { test, expect, type Page } from '@playwright/test'

// FOLDABLE-REPORTS — RENDERED proof of the Collapsible primitive through its REAL consumer:
// tests/harness/fold.html mounts the actual <ReportsSection> (exactly what CommandScreen
// composes) with three injected reports, deliberately unsorted, newest = enc-3. Proves the owner's
// ask end-to-end in a real DOM: each report is its own fold (newest open, older collapsed), the
// whole card folds, folding is keyboard-operable (real <button> + aria-expanded), and the
// section's state survives a full page reload via localStorage. Nothing connects to a server.

const SECTION = 'combat-reports-section-fold'
const row = (n: number) => `report-row-enc-${n}`

async function boot(page: Page) {
  await page.goto('/fold.html')
  await expect(page.getByTestId(`${SECTION}-toggle`)).toBeVisible()
}

test('default fold state: section open; ONLY the newest report row open (by created_at, not array order)', async ({ page }) => {
  await boot(page)
  // Section defaults open.
  await expect(page.getByTestId(`${SECTION}-toggle`)).toHaveAttribute('aria-expanded', 'true')
  // enc-3 is the newest (created 08-03) though it sits MID-ARRAY in the harness data → open;
  // its detail (the Reported StatRow) is rendered.
  await expect(page.getByTestId(`${row(3)}-toggle`)).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByTestId(`${row(3)}-content`)).toContainText('Reported')
  // The older two start collapsed — headers visible, details unmounted.
  for (const n of [1, 2]) {
    await expect(page.getByTestId(`${row(n)}-toggle`)).toHaveAttribute('aria-expanded', 'false')
    await expect(page.getByTestId(`${row(n)}-content`)).toBeEmpty()
  }
})

test('mouse toggling: an older report opens on click; the newest folds away on click', async ({ page }) => {
  await boot(page)
  await page.getByTestId(`${row(1)}-toggle`).click()
  await expect(page.getByTestId(`${row(1)}-toggle`)).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByTestId(`${row(1)}-content`)).toContainText('Waves cleared')
  // The newest stays open (independent folds — opening one never closes another)…
  await expect(page.getByTestId(`${row(3)}-toggle`)).toHaveAttribute('aria-expanded', 'true')
  // …until ITS header is clicked.
  await page.getByTestId(`${row(3)}-toggle`).click()
  await expect(page.getByTestId(`${row(3)}-toggle`)).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByTestId(`${row(3)}-content`)).toBeEmpty()
})

test('keyboard: the fold header is a real button — focus + Enter and Space both toggle it', async ({ page }) => {
  await boot(page)
  const toggle = page.getByTestId(`${row(2)}-toggle`)
  await toggle.focus()
  await page.keyboard.press('Enter')
  await expect(toggle).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByTestId(`${row(2)}-content`)).toContainText('Reported')
  await page.keyboard.press('Space')
  await expect(toggle).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByTestId(`${row(2)}-content`)).toBeEmpty()
})

test('the whole reports card folds: closing the section hides every row', async ({ page }) => {
  await boot(page)
  await page.getByTestId(`${SECTION}-toggle`).click()
  await expect(page.getByTestId(`${SECTION}-toggle`)).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByTestId(`${row(3)}-toggle`)).toHaveCount(0) // children unmount while closed
})

test('persistence: the section fold survives a full reload (localStorage), and the stored value is the contract', async ({ page }) => {
  await boot(page)
  await page.getByTestId(`${SECTION}-toggle`).click() // fold it
  // The write landed under the versioned key with the '0' (closed) value.
  const stored = await page.evaluate(() => window.localStorage.getItem('byeharu.fold.v1:command.reports'))
  expect(stored).toBe('0')
  await page.reload()
  await expect(page.getByTestId(`${SECTION}-toggle`)).toHaveAttribute('aria-expanded', 'false')
  // Re-open → persists open again.
  await page.getByTestId(`${SECTION}-toggle`).click()
  await page.reload()
  await expect(page.getByTestId(`${SECTION}-toggle`)).toHaveAttribute('aria-expanded', 'true')
  // Row folds are session-local BY DESIGN (reportFold.ts): after reload the default is back —
  // only the newest row open.
  await expect(page.getByTestId(`${row(3)}-toggle`)).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByTestId(`${row(1)}-toggle`)).toHaveAttribute('aria-expanded', 'false')
})

test('aria wiring: every fold header controls the region that holds its content', async ({ page }) => {
  await boot(page)
  for (const id of [`${SECTION}-toggle`, `${row(3)}-toggle`]) {
    const controls = await page.getByTestId(id).getAttribute('aria-controls')
    expect(controls).toBeTruthy()
    await expect(page.locator(`[id="${controls}"]`)).toHaveCount(1)
  }
})
