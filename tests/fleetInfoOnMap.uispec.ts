import { test, expect, type Page } from '@playwright/test'

// ██ MY FLEETS, ON THE MAP — the RENDERED proof. ██
//
// ── THE REQUEST (owner, playing, 2026-08-04) ───────────────────────────────────────────────────────
// "in map, i want to see information regarding fleet, where it is, stats, what it is currently doing.
//  I am in snare but in no fight is occuring, i want also a toggle combat on map as well when i
//  arrive at the combat zone on the fleet information on map"
//
// ── WHY A DOM PROOF AND NOT ONLY A MODEL PROOF ────────────────────────────────────────────────────
// tests/fleetStatus.spec.ts proves the model returns the right words. It cannot see whether the words
// reach the screen, whether the button that starts a fight is big enough to press on a phone, or
// whether "Hunt at Snare" pushes the map sideways at 320px. The owner plays on a phone and has twice
// lost a day to a control that was present in the code and absent on the screen — so what the panel
// SHOWS is measured here, on the real components, in a real browser.
//
// ── WHAT THIS PINS ────────────────────────────────────────────────────────────────────────────────
//  1. a fleet with no fight — where it is, what it is doing, its stats, and NO action offered;
//  2. a fleet standing in a zone that wraps a huntable site — the SITE is offered, and pressing it
//     hands back that site's location id (the map's own marker-selection path, not a new command);
//  3. a fleet already fighting — the way OUT is what the same slot offers (the ONE RetreatControl);
//  4. a fleet in flight — the arrival, exact, from a fixed clock;
//  5. a fleet that CANNOT fight — the reason is on the screen, in the server's words, naming the fix;
//  6. nothing clipped and no sideways scroll at 320px AND at 288px (10% under the floor, because a
//     margin smaller than platform text-metric variance is not a proof), every control ≥ 44px;
//  7. the fold — the owner's map-UX law: it must be dismissable, and a player with no fleets sees
//     nothing at all.

/** The narrowest phone the game supports. */
const PHONE_FLOOR = 320
/** 10% under the floor. CI's Linux Chromium draws different glyph widths than a Windows dev box, and
 *  a 3px overflow has already slipped past a local run and been caught only in CI. */
const MARGIN_FLOOR = 288
/** The touch-target floor the design system commits to. */
const TOUCH_FLOOR = 44

const FLEET = 'g-fleet-1'

test.beforeEach(async ({ page }) => {
  // The panel mounts RetreatControl → combatApi → the supabase client. Nothing must reach a network:
  // the dummy origin answers [] so a stray read settles instead of hanging.
  await page.route('http://localhost:54321/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }),
  )
})

async function open(page: Page, scenario: string, width = 390) {
  await page.setViewportSize({ width, height: 900 })
  await page.goto(`/fleetinfo.html?s=${scenario}`)
  if (scenario !== 'none') await expect(page.getByTestId('fleet-status-panel')).toBeVisible()
  // Measure only once the real font metrics are in — a box measured mid-swap is a box measured wrong.
  await page.evaluate(() => document.fonts.ready.then(() => undefined))
}

/** Does the document scroll sideways? The house rule is that it never may. */
async function scrollsSideways(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const b = document.body
    const d = document.documentElement
    return b.scrollWidth > b.clientWidth || d.scrollWidth > d.clientWidth
  })
}

/** Every box the readout lays out. A `truncate`d leaf may overflow its own box — that is what
 *  truncation IS — so the check is on the containers that would push the PAGE. */
async function panelOverflow(page: Page) {
  return page.evaluate(() => {
    const ids = ['fleet-status-panel', 'fleet-status-fold', 'fleet-status-fold-content']
    return ids
      .map((id) => document.querySelector(`[data-testid="${id}"]`) as HTMLElement | null)
      .filter((el): el is HTMLElement => el !== null)
      .map((el) => ({
        id: el.getAttribute('data-testid') ?? '',
        scroll: el.scrollWidth,
        client: el.clientWidth,
      }))
  })
}

// ── 1 · A FLEET WITH NO FIGHT ────────────────────────────────────────────────────────────────────

test('A FLEET WITH NO FIGHT: where it is, what it is doing, its stats — and nothing to press', async ({ page }) => {
  await open(page, 'parked')
  await expect(page.getByTestId(`fleet-status-${FLEET}`)).toContainText('Fleet 1')
  await expect(page.getByTestId(`fleet-status-where-${FLEET}`)).toHaveText('In orbit of Snare')
  await expect(page.getByTestId(`fleet-status-doing-${FLEET}`)).toHaveText('Holding position')
  await expect(page.getByTestId(`fleet-status-stats-${FLEET}`)).toContainText('Ships')
  await expect(page.getByTestId(`fleet-status-stats-${FLEET}`)).toContainText('2')
  // Nothing to fight here → no offer. An action with nothing behind it is the dead click the owner met.
  await expect(page.getByTestId(`fleet-status-hunt-${FLEET}`)).toHaveCount(0)
  await expect(page.getByTestId(`fleet-status-retreat-${FLEET}`)).toHaveCount(0)
})

test('NO DORMANT STAT AND NO CARGO NUMBER REACHES THE SCREEN', async ({ page }) => {
  // Owner ruling on the 2026-08-04 stat audit: five fold outputs have zero engine consumers and must
  // not be described as effective; the integer cargo_capacity is deprecated in favour of the m³ hold.
  await open(page, 'parked')
  const text = ((await page.getByTestId('fleet-status-panel').textContent()) ?? '').toLowerCase()
  for (const banned of ['evasion', 'retreat safety', 'scouting', 'mining', 'pirate attention', 'cargo', 'power', 'speed']) {
    expect(text, `the map must not render "${banned}"`).not.toContain(banned)
  }
})

// ── 2 · THE FIGHT UNDER THE FLEET'S FEET ─────────────────────────────────────────────────────────

test('STANDING IN THE ZONE: the SITE is offered — "i am in snare but in no fight is occuring"', async ({ page }) => {
  await open(page, 'zone')
  const hunt = page.getByTestId(`fleet-status-hunt-${FLEET}`)
  await expect(hunt).toBeVisible()
  // The words are the hunt-copy authority's, and they name the SITE — never the zone.
  await expect(hunt).toHaveText('Hunt at Snare')
})

test('pressing it SELECTS THE SITE — the map’s own marker path, never a second hunt command', async ({ page }) => {
  await open(page, 'zone')
  await page.getByTestId(`fleet-status-hunt-${FLEET}`).click()
  // The panel hands back a location id and nothing else: the existing hunt control does the rest.
  expect(await page.evaluate(() => (window as unknown as { __huntSiteCalls: string[] }).__huntSiteCalls)).toEqual([
    'loc-snare',
  ])
})

// ── 3 · THE WAY OUT ──────────────────────────────────────────────────────────────────────────────

test('ALREADY FIGHTING: the same slot offers the way OUT, and the way IN is not shown beside it', async ({ page }) => {
  await open(page, 'fighting')
  await expect(page.getByTestId(`fleet-status-where-${FLEET}`)).toHaveText('In combat at Snare')
  await expect(page.getByTestId(`fleet-status-doing-${FLEET}`)).toHaveText('In combat')
  await expect(page.getByTestId(`fleet-status-retreat-${FLEET}`)).toBeVisible()
  await expect(page.getByTestId(`fleet-status-retreat-${FLEET}`)).toHaveText('Retreat')
  // The fleet is standing in the huntable zone too — the exit must not be displaced by an invitation.
  await expect(page.getByTestId(`fleet-status-hunt-${FLEET}`)).toHaveCount(0)
})

test('the fight’s RUNNING COMMENTARY stays on the combat card — the readout is not a second fight display', async ({ page }) => {
  await open(page, 'fighting')
  const text = (await page.getByTestId('fleet-status-panel').textContent()) ?? ''
  // 'Hull' USED TO BE ON THIS LIST and has been deliberately removed from it. The owner, playing
  // 2026-08-09: *"the fleets tab on map does not show range, its moving speed, hull, shield, shield
  // generation"*. He is asking for the fleet's STANDING — what it is made of and what is left of it —
  // on the readout that describes his fleet, and that outranks the earlier tidiness rule. What is
  // still refused is the fight's blow-by-blow: the last exchange and the retreat threshold are
  // events, they change every tick, and CombatMapCard owns them three inches away.
  for (const banned of ['Last exchange', 'Auto-retreat', 'units to go']) {
    expect(text, `${banned} belongs to CombatMapCard, which is on this same screen`).not.toContain(banned)
  }
})

// ── 3b · ██ WHAT THE FLEET IS MADE OF, AND WHAT IT SHOOTS WITH ██ ────────────────────────────────
// Owner, playing 2026-08-09: *"the fleets tab on map does not show range, its moving speed, hull,
// shield, shield generation"* and *"the fleets tab should also show attacking power, what weapon
// system it is using"*.
//
// ⚠ THE REASON THESE ARE HERE AND NOT ONLY IN tests/fightingFleetStats.spec.ts: this harness used to
// pass `units={[]}` into the 'fighting' scenario, so the model returned null and NOT ONE fight stat
// was ever rendered in a proof. "Reach 5 units · Fires every round · 3s · Combat speed 0.2
// units/round" was live on the owner's map with a fully green rendered suite. The fixture now
// carries his actual production rows.

test('EVERY STAT HE ASKED FOR IS ON THE SCREEN, with the numbers the server sent', async ({ page }) => {
  await open(page, 'fighting')
  const stats = page.getByTestId(`fleet-status-stats-${FLEET}`)
  // Five living hulls at 473+500+500+33+92 of 500 each — the DEAD sixth hull and the enemy rows
  // contribute nothing, which is the whole reason both are in the fixture.
  await expect(stats).toContainText('Hull')
  await expect(stats).toContainText('1598 / 2500')
  // 5 guns × power 15. 0331 makes weapons_json[i].power the ship's own combat_power share, so this
  // is the engine's per-round volley and not a client re-fold of anything.
  await expect(stats).toContainText('Attack')
  await expect(stats).toContainText('75 / round')
  // "what weapon system it is using" — off the frozen array, named by the ONE id→label authority.
  await expect(stats).toContainText('Weapons')
  await expect(stats).toContainText('Basic Player Weapon ×5')
  await expect(stats).toContainText('Range')
  await expect(stats).toContainText('5 units')
  await expect(stats).toContainText('0.2 units/round')
})

test('THE WORDS ARE HIS: "Range" and "Speed", never "Reach" and never "Combat speed"', async ({ page }) => {
  // He listed range and moving speed as MISSING while the panel was printing "Reach" and "Combat
  // speed" at that exact moment. A stat the player does not recognise is a stat that is not there.
  await open(page, 'fighting')
  const text = (await page.getByTestId('fleet-status-panel').textContent()) ?? ''
  expect(text).toContain('Range')
  expect(text, 'Reach is a word this codebase invented; range is the word on the weapon').not.toContain('Reach')
  // The two speeds must never be readable as one number — combat move_speed and map-travel speed are
  // different quantities in different units.
  expect(text).toContain('Speed in battle')
  expect(text).not.toContain('Combat speed')
})

test('THE FIRE CADENCE STAYS HONEST — the ROUND, never the cooldown the engine does not read', async ({ page }) => {
  // The fixture's weapon carries cooldown_seconds 2 (production's real value). The engine stamps
  // next_ready_at := now() and never adds it, so every weapon in range fires every tick. Printing
  // "Reload 2s" would be a number that changes nothing in the game.
  await open(page, 'fighting')
  const text = (await page.getByTestId('fleet-status-panel').textContent()) ?? ''
  expect(text).toContain('every round · 3s')
  expect(text, 'the unread cooldown must never reach the screen').not.toMatch(/reload/i)
  expect(text).not.toContain('2s')
})

test('SHIELDS ARE SILENT WHILE THE GAME HAS NONE — no 0/0 bar, no zero regen', async ({ page }) => {
  // Measured on production 2026-08-09: 0 of 327 combat_units rows carry a pool, 0 of 77 ships have
  // max_shield > 0, 0 of 3 hulls have base_shield > 0, and shield_regen_combat_pct is 0. A "Shield
  // 0/0" line would be a bar that can never move and "Shield regen 0" would name a mechanic that
  // does not run — the same refusal the dormant fold stats get.
  await open(page, 'fighting')
  const text = (await page.getByTestId('fleet-status-panel').textContent()) ?? ''
  expect(text, 'a shieldless fight must say nothing about shields').not.toMatch(/shield/i)
})

test('…AND THEY APPEAR BY THEMSELVES ONCE A POOL EXISTS — the silence is the DATA, not a missing feature', async ({ page }) => {
  // The same fight after scripts/activate-shield.sql: five hulls at 60/100 with the combat regen knob
  // at 0.02. This is the anti-proof for the test above — without it, "shields are silent" and
  // "shields were never built" are indistinguishable.
  await open(page, 'shielded')
  const stats = page.getByTestId(`fleet-status-stats-${FLEET}`)
  await expect(stats).toContainText('Shield')
  await expect(stats).toContainText('300 / 500')
  await expect(stats).toContainText('Shield regen')
  await expect(stats).toContainText('10 / round')
})

// ── 4 · IN FLIGHT ────────────────────────────────────────────────────────────────────────────────

test('IN FLIGHT: the readout says when it arrives', async ({ page }) => {
  await open(page, 'flight')
  await expect(page.getByTestId(`fleet-status-where-${FLEET}`)).toHaveText('In flight')
  await expect(page.getByTestId(`fleet-status-doing-${FLEET}`)).toHaveText('Arriving in 2m 08s')
})

// ── 5 · WHY IT CANNOT FIGHT ──────────────────────────────────────────────────────────────────────

test('CANNOT FIGHT: THE REASON IS ON THE SCREEN, and it names the fix', async ({ page }) => {
  // The likeliest blocker on production today: send_ship_group_hunt refuses a fleet with no command
  // ship BEFORE it reads the destination, and 2 of 77 live ships carry the flag. A disabled control
  // with no reason is what cost the owner a whole day.
  await open(page, 'blocked')
  const blocked = page.getByTestId(`fleet-status-blocked-${FLEET}`)
  await expect(blocked).toBeVisible()
  await expect(blocked).toContainText('no command ship')
  await expect(blocked, 'the player must be told where to fix it').toContainText('Fleet tab')
})

// ── 6 · IT FITS A PHONE ──────────────────────────────────────────────────────────────────────────

for (const width of [MARGIN_FLOOR, PHONE_FLOOR]) {
  test(`NOTHING IS CLIPPED AND THE PAGE NEVER SCROLLS SIDEWAYS at ${width}px`, async ({ page }) => {
    for (const scenario of ['parked', 'zone', 'fighting', 'shielded', 'flight', 'blocked']) {
      await open(page, scenario, width)
      expect(await scrollsSideways(page), `${scenario} at ${width}px pushes the page sideways`).toBe(false)
      for (const o of await panelOverflow(page)) {
        expect(o.scroll, `${o.id} overflows its own width in ${scenario} at ${width}px`).toBeLessThanOrEqual(o.client)
      }
    }
  })

  test(`EVERY CONTROL CLEARS THE ${TOUCH_FLOOR}px TOUCH FLOOR at ${width}px`, async ({ page }) => {
    for (const scenario of ['zone', 'fighting', 'parked']) {
      await open(page, scenario, width)
      const boxes = await page.evaluate(() =>
        [...document.querySelectorAll('[data-testid="fleet-status-panel"] button')].map((el) => {
          const r = el.getBoundingClientRect()
          return { id: el.getAttribute('data-testid') ?? el.textContent ?? '?', w: r.width, h: r.height }
        }),
      )
      expect(boxes.length, `controls rendered in ${scenario} at ${width}px`).toBeGreaterThan(0)
      for (const b of boxes) {
        expect(b.h, `${b.id} height in ${scenario} at ${width}px`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
        expect(b.w, `${b.id} width in ${scenario} at ${width}px`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
      }
    }
  })
}

// ── 7 · CLEAN MAP ────────────────────────────────────────────────────────────────────────────────

test('IT FOLDS AWAY — the owner’s map-UX law: nothing on the map is unavoidable', async ({ page }) => {
  await open(page, 'parked')
  await expect(page.getByTestId(`fleet-status-${FLEET}`)).toBeVisible()
  await page.getByTestId('fleet-status-fold-toggle').click()
  await expect(page.getByTestId(`fleet-status-${FLEET}`)).toHaveCount(0)
  // …and it comes back, so folding is a choice and not a loss.
  await page.getByTestId('fleet-status-fold-toggle').click()
  await expect(page.getByTestId(`fleet-status-${FLEET}`)).toBeVisible()
})

test('NO FLEETS → NOTHING AT ALL. A clean map is the default', async ({ page }) => {
  await open(page, 'none')
  await expect(page.getByTestId('fleet-status-panel')).toHaveCount(0)
})
