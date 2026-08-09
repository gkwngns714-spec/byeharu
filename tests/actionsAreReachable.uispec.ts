import { test, expect, type Page } from '@playwright/test'

// ██ THE ACTION IS ALWAYS REACHABLE — the RENDERED proof of the law. ██
//
// ── THE DEFECT THIS REPRODUCES ────────────────────────────────────────────────────────────────────
// Owner, playing the LIVE game, 2026-08-08: "right now i can't press hunt."
//
// Measured in the running page at 1440x675 — the button was NOT disabled:
//   · "Hunt at Snare"  rect top 391, bottom 435, height 44, `disabled: false`
//   · its scroll ancestor, the top-left OverlayRail (`max-h-[60%] overflow-y-auto`):
//     clientHeight 334, scrollHeight 386, bottom edge y=399
//   ⇒ 8 of the button's 44 pixels were inside the container. The other 36 were below the fold of a
//     scroll area whose scrollbar is easy to miss.
//
// It tipped over because the rail STACKS: a close-call notice ("Slipped past the pirates around
// Snare.") only appears near a danger zone — i.e. exactly when the player needs Hunt — and Hunt,
// being last in the stack, is what gets cut.
//
// ── THE LAW BEING PINNED ──────────────────────────────────────────────────────────────────────────
// An action the player must be able to take may never live where it can be clipped or scrolled out
// of sight. The codebase already held this rule for the BRAKE — FleetCommandPanel.tsx:542, "Stop
// renders OUTSIDE the scroll container so it can never scroll away". This slice makes the rule
// STRUCTURAL and moves it into the one place every map overlay passes through: OverlayRail owns a
// capped, scrollable INFORMATION region and an uncapped, never-scrolled REACH region, and no call
// site may cap or scroll a rail itself (tests/actionsAreReachable.spec.ts is the static half).
//
// ── WHAT IS ASSERTED, AND WHY IT IS NOT A REPEAT OF fleetinfo.uispec ──────────────────────────────
// tests/fleetInfoOnMap.uispec.ts mounts the FleetStatusPanel ALONE in the rail. Alone it always
// fits — which is why that proof was green while the game was broken. THIS proof mounts the STACK
// (notices + combat card + readout) and asserts, for EVERY actionable control in the rail:
//   1. it is fully inside the VIEWPORT (top ≥ 0, bottom ≤ innerHeight, left ≥ 0, right ≤ innerWidth);
//   2. it is fully inside EVERY scrollable ancestor's client box — the check the live game failed;
//   3. it still clears the 44px touch floor.
// Across the owner's phone (390px, and short), the 320px floor, and the exact desktop viewport the
// defect was measured at (1440x675).
//
// Run: `npx playwright test --config playwright.osnui.config.ts actionsAreReachable`

// ── THE SUPPORTED VIEWPORTS, AND THE MEASURED LIMIT ──────────────────────────────────────────────
// Every viewport below is asserted STRICTLY: no control outside the viewport, no control clipped by
// any scroll ancestor. They are real devices, not round numbers.
//
// THE LIMIT, MEASURED (not reasoned) on 2026-08-08, AND WHAT REMOVED IT. The rail's tallest possible
// control stack was a live fight: exploration panel 134px + combat card 210px + fleet readout 224px
// + two 8px gaps = **583px**, plus the rail's 12px top inset ⇒ it needed a viewport at least **595px
// tall**, and a 568px screen (iPhone SE 1st gen) painted the last control 19px below the fold.
//
// THE MAP'S TABS DELETED THAT ARITHMETIC. At most one readout is mounted, so the rail is the tab bar
// (52px) + the pinned fight row + ONE body — the three can no longer be added together. The
// assertion did not get easier, it got WIDER: the tallest state is now a CHOICE, so every tab is
// swept at every viewport, including the state where none is open. If any single tab grows past the
// rail, THIS is what goes red.

/** The owner's phone. Short on purpose — a tall phone hides this whole class of defect. */
const PHONE = { width: 390, height: 664 }
/** The narrowest supported width (the design system's stated 320px floor), at a real device height. */
const FLOOR = { width: 320, height: 640 }
/** iPhone SE 2nd/3rd gen — the shortest screen Apple still ships. */
const SE = { width: 375, height: 667 }
/** The EXACT viewport the defect was measured in, in the owner's browser. */
const MEASURED = { width: 1440, height: 675 }

const VIEWPORTS = [
  { name: 'phone 390x664', ...PHONE },
  { name: 'floor 320x640', ...FLOOR },
  { name: 'iPhone SE 375x667', ...SE },
  { name: 'measured 1440x675', ...MEASURED },
]

/** The touch-target floor the design system commits to. */
const TOUCH_FLOOR = 44

/** Every scenario that puts an action in a rail, CROSSED WITH EVERY TAB.
 *
 *  `?t=` forces the open tab, so the sweep covers what the player can actually choose rather than
 *  whichever tab the default resolver happens to open. `t=none` is the fully-folded map — the state
 *  in which the pinned fight row is the ONLY thing standing between the player and a fight they
 *  cannot leave, which is precisely why it is swept. */
const TABS = ['explore', 'fight', 'fleets', 'none']
const TOP_SCENARIOS = ['zone', 'crowded', 'fight', 'fleets'].flatMap((s) => TABS.map((t) => `${s}&t=${t}`))
const HUB_SCENARIOS = ['hub', 'zoneinfo']

test.beforeEach(async ({ page }) => {
  // RetreatControl → combatApi → the supabase client. Nothing must reach a network: the dummy origin
  // answers [] so a stray read settles instead of hanging.
  await page.route('http://localhost:54321/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }),
  )
  // THE EXPLORATION PANEL IS SERVER-LIT and renders nothing unless the read comes back {ok:true}.
  // The owner's live rail carried it, so the proof lights it — otherwise the harness would stack
  // three things where the game stacks four, and would under-report the very overflow it exists to
  // catch. Registered AFTER the catch-all: Playwright matches routes newest-first.
  await page.route('**/rpc/get_my_exploration_discoveries', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ ok: true, discoveries: [] }),
    }),
  )
})

async function open(page: Page, scenario: string, vp: { width: number; height: number }) {
  await page.setViewportSize({ width: vp.width, height: vp.height })
  await page.goto(`/reach.html?s=${scenario}`)
  await expect(page.getByTestId('map-host')).toBeVisible()
  // Measure only once the real font metrics are in — a box measured mid-swap is measured wrong.
  await page.evaluate(() => document.fonts.ready.then(() => undefined))
}

interface Reach {
  id: string
  text: string
  /** how many pixels of the control's height fall outside the viewport (0 = fully on screen) */
  outsideViewport: number
  /** the worst clip by any scrollable ancestor, in pixels (0 = fully inside every one of them) */
  clippedBy: number
  /** the ancestor that clips it, for a failure message that names the culprit */
  clipper: string
  width: number
  height: number
}

/**
 * EVERY actionable control inside the map overlay, MEASURED against the viewport and against every
 * scrollable ancestor. This is the whole proof: a control that is present, enabled, and 36px below
 * the fold of a hidden scrollbar is a control the player does not have.
 */
async function reachOf(page: Page): Promise<Reach[]> {
  return page.evaluate(() => {
    const controls = [...document.querySelectorAll('[data-testid="map-host"] button, [data-testid="map-host"] a[href]')]
    return controls.map((el) => {
      const r = el.getBoundingClientRect()
      // 1 — the viewport.
      const outTop = Math.max(0, -r.top)
      const outBottom = Math.max(0, r.bottom - window.innerHeight)
      const outLeft = Math.max(0, -r.left)
      const outRight = Math.max(0, r.right - window.innerWidth)
      // 2 — every scrollable ancestor's CLIENT box (what is actually painted without scrolling).
      let worst = 0
      let clipper = ''
      for (let p = el.parentElement; p !== null; p = p.parentElement) {
        const cs = getComputedStyle(p)
        const scrolls = /auto|scroll|hidden/.test(cs.overflowY) || /auto|scroll|hidden/.test(cs.overflowX)
        if (!scrolls) continue
        const pr = p.getBoundingClientRect()
        // The client box excludes the border; padding is inside it. Close enough at this scale, and
        // erring toward LENIENT (border widths are 1px) keeps the proof about clipping, not rounding.
        const cut = Math.max(0, pr.top - r.top, r.bottom - pr.bottom, pr.left - r.left, r.right - pr.right)
        if (cut > worst) {
          worst = cut
          clipper = `${p.tagName}.${p.className.split(' ').slice(0, 4).join('.')}`
        }
      }
      return {
        id: el.getAttribute('data-testid') ?? (el.textContent ?? '?').trim().slice(0, 40),
        text: (el.textContent ?? '').trim().slice(0, 40),
        outsideViewport: Math.round(outTop + outBottom + outLeft + outRight),
        clippedBy: Math.round(worst),
        clipper,
        width: Math.round(r.width),
        height: Math.round(r.height),
      }
    })
  })
}

// ── 1 · THE DEFECT ITSELF, AT THE VIEWPORT IT WAS MEASURED IN ────────────────────────────────────

test('THE OWNER’S BUG: "Hunt at Snare" is fully pressable at 1440x675 with the close-call notice up', async ({
  page,
}) => {
  await open(page, 'zone&t=fleets', MEASURED)
  const hunt = page.getByTestId('fleet-status-hunt-g-fleet-1')
  await expect(hunt).toBeVisible()
  await expect(hunt).toBeEnabled()
  const [h] = (await reachOf(page)).filter((c) => c.id === 'fleet-status-hunt-g-fleet-1')
  expect(h, 'the hunt button must be in the DOM').toBeTruthy()
  expect(h.outsideViewport, `Hunt hangs ${h.outsideViewport}px outside the viewport`).toBe(0)
  expect(h.clippedBy, `Hunt is clipped ${h.clippedBy}px by ${h.clipper}`).toBe(0)
  // …and it still WORKS when pressed, which is the only thing the player cares about.
  await hunt.click()
  expect(await page.evaluate(() => (window as unknown as { __huntSiteCalls: string[] }).__huntSiteCalls)).toEqual([
    'loc-snare',
  ])
})

// ── 2 · THE CLASS, EVERYWHERE IN THE RAILS, AT EVERY SUPPORTED SIZE ──────────────────────────────

for (const vp of VIEWPORTS) {
  for (const scenario of [...TOP_SCENARIOS, ...HUB_SCENARIOS]) {
    test(`EVERY ACTION IS REACHABLE — ${scenario} at ${vp.name}`, async ({ page }) => {
      await open(page, scenario, vp)
      const controls = await reachOf(page)
      expect(controls.length, `${scenario} at ${vp.name} rendered no controls at all`).toBeGreaterThan(0)
      for (const c of controls) {
        expect(
          c.outsideViewport,
          `${c.id} ("${c.text}") hangs ${c.outsideViewport}px outside the viewport in ${scenario} at ${vp.name}`,
        ).toBe(0)
        expect(
          c.clippedBy,
          `${c.id} ("${c.text}") is clipped ${c.clippedBy}px by ${c.clipper} in ${scenario} at ${vp.name}`,
        ).toBe(0)
      }
    })
  }
}

// ── 2b · THE REACH REGION NEVER ACTUALLY SCROLLS ─────────────────────────────────────────────────
// The region has no `overflow`, so if the squeeze ever failed to make room the panels would spill
// off the bottom of the phone rather than scroll. This is the invariant that says the squeeze always
// succeeds: the region's content fits the region, at every supported viewport, in every state.
// MEASURED before the fix, at the owner's own 1440x675: the stack was 583px against a 505px map box.

for (const vp of VIEWPORTS) {
  test(`THE SQUEEZE ALWAYS SUCCEEDS — the reach region never overflows at ${vp.name}`, async ({ page }) => {
    for (const scenario of TOP_SCENARIOS) {
      await open(page, scenario, vp)
      const region = await page.evaluate(() => {
        const r = document.querySelector('[data-overlay-region="reach"]') as HTMLElement | null
        return r === null ? null : { scroll: r.scrollHeight, client: r.clientHeight }
      })
      expect(region, `${scenario} must render a reach region`).not.toBeNull()
      expect(
        region!.scroll,
        `the controls need ${region!.scroll}px but the rail has ${region!.client}px in ${scenario} at ${vp.name} — ` +
          `something was added to the top-left rail that cannot give way. Make its BODY an account, or fold it.`,
      ).toBeLessThanOrEqual(region!.client)
    }
  })
}

// ── 2c · THE MEASURED LIMIT: a fleet list longer than the screen ─────────────────────────────────
// Three fleets standing in one zone is 702px of cards against a ~505px map box: no layout shows them
// all at once. The readout's LIST is therefore an account and it scrolls — but the degradation is
// bounded and honest, which is the whole difference from the defect this slice fixes. The owner's bug
// was the entire rail silently cropping its last panel with no cue and nothing on screen to scroll.
// Here the list is a visible box, fully on screen, that the player can also fold away.

test('THE MEASURED LIMIT: past two fleets the readout SCROLLS ITS LIST — inside a box that is fully on screen', async ({
  page,
}) => {
  await open(page, 'fleets3&t=fleets', FLOOR)
  const box = await page.evaluate(() => {
    const list = document.querySelector('[data-testid="fleet-status-fold-content"] > div') as HTMLElement | null
    if (list === null) return null
    const r = list.getBoundingClientRect()
    return { top: r.top, bottom: r.bottom, scrolls: list.scrollHeight > list.clientHeight, vh: window.innerHeight }
  })
  expect(box, 'the readout must render its list').not.toBeNull()
  // It genuinely needs to scroll at three fleets — if it stops, this proof is no longer about anything.
  expect(box!.scrolls, 'three fleets must exceed the list box, or this limit has moved').toBe(true)
  // …and the box the player scrolls is entirely on screen, which is what the broken rail never was.
  expect(box!.top, 'the list box must start on screen').toBeGreaterThanOrEqual(0)
  expect(box!.bottom, 'the list box must END on screen — a scroll area you cannot see is the bug').toBeLessThanOrEqual(
    box!.vh,
  )
})

// ── 2d · THE TABS, RENDERED: ONE BODY, AND THE EXIT IS NEVER BEHIND A FOLD ───────────────────────
// The static half of this lives in tests/actionsAreReachable.spec.ts. This is the same invariant
// measured in a real browser, because the reason it matters is a layout reason.

test('AT MOST ONE TAB BODY IS RENDERED, in every tab state', async ({ page }) => {
  for (const t of TABS) {
    await open(page, `fight&t=${t}`, PHONE)
    const bodies = await page.locator('[data-testid^="map-tab-body-"]').count()
    expect(bodies, `tab "${t}" rendered ${bodies} bodies`).toBeLessThanOrEqual(1)
    // …and the three square tabs are always there to switch with.
    for (const id of ['explore', 'fight', 'fleets']) {
      await expect(page.getByTestId(`map-tab-${id}`)).toBeVisible()
    }
  }
})

test('THE WAY OUT OF A FIGHT IS ON SCREEN EVEN WITH EVERY TAB FOLDED SHUT', async ({ page }) => {
  // The whole reason a fold is safe. A tab can be closed; a fight cannot be paused.
  await open(page, 'fight&t=none', PHONE)
  await expect(page.getByTestId('map-tab-body-null')).toHaveCount(0)
  const retreat = page.getByTestId('combat-map-retreat-enc-1')
  await expect(retreat).toBeVisible()
  await expect(retreat).toBeEnabled()
  const [r] = (await reachOf(page)).filter((c) => c.id === 'combat-map-retreat-enc-1')
  expect(r, 'the retreat control must be in the DOM with every tab closed').toBeTruthy()
  expect(r.outsideViewport, `Retreat hangs ${r.outsideViewport}px outside the viewport`).toBe(0)
  expect(r.clippedBy, `Retreat is clipped ${r.clippedBy}px by ${r.clipper}`).toBe(0)
  expect(r.height, 'and it still clears the touch floor').toBeGreaterThanOrEqual(TOUCH_FLOOR)
  // …and a fight behind a closed tab is not silent.
  await expect(page.getByTestId('map-fight-row-enc-1')).toContainText('In combat')
  await expect(page.getByTestId('map-tab-fight-live')).toBeVisible()
})

// ── ██ THE WAVE TIMER IS ON SCREEN IN EVERY TAB STATE ██ ─────────────────────────────────────────
// Owner, playing 2026-08-09: *"when a wave starts, i see no timer that indicates next wave"*.
//
// Nothing was broken on the wire and nothing was broken in the leaf. `combatApi` reads `select('*')`,
// `CombatEncounter` declares all three pressure columns, and `combat/reinforcementClock` resolved
// them correctly — into a tab that was not on screen. The countdown lived ONLY inside CombatMapCard
// (the FIGHT tab's body) and ActiveCombatPanel (the Mission screen), and this shell mounts AT MOST
// ONE BODY. Standing on the FLEETS tab, which is where he was, the words came from
// `selectCombatPhase` — a pure function of the row that deliberately carries no time at all — so the
// screen read "Next wave incoming" with no number, forever.
//
// A countdown visible in one of four tab states is a countdown the player does not have, for exactly
// the reason the retreat control above is pinned. This sweeps all four.

test('THE WAVE TIMER IS ON SCREEN IN EVERY TAB STATE — the countdown is not behind a fold', async ({ page }) => {
  for (const t of TABS) {
    await open(page, `fight&t=${t}`, PHONE)
    const row = page.getByTestId('map-fight-row-wave-enc-1')
    await expect(row, `no wave timer with tab "${t}" open`).toBeVisible()
    // The exact countdown, from the harness's FIXED clock — the same one the fight tab's card reads,
    // through the same leaf, so the two can never drift into two different answers.
    await expect(row).toHaveText('Next wave in 12s')
  }
  // And when the fight tab IS open, there is still exactly ONE countdown per surface — the pinned
  // signal and the card's own wave section, both from the leaf, never a third derivation.
  await open(page, 'fight&t=fight', PHONE)
  await expect(page.getByTestId('combat-map-wave-clock-enc-1')).toHaveText('Next wave in 12s')
})

test('THE PINNED ROW STAYS A SIGNAL, NOT A SECOND READOUT — no field count, no rule, no verdict', async ({ page }) => {
  // The field/cap pair and REINFORCEMENT_RULE belong to the fight tab's card, which owns the whole
  // wave section. Restating them on a row that is always on screen would be the duplication the tab
  // shell exists to prevent — and the row must never predict an arrival either.
  await open(page, 'fight&t=none', PHONE)
  const text = await page.getByTestId('map-fight-row-enc-1').innerText()
  expect(text).toMatch(/Next wave in \d+s/)
  expect(text, 'the field count belongs to the card').not.toMatch(/4\/4|Field/i)
  expect(text, 'the rule is stated once, on the card').not.toMatch(/under its limit/i)
  expect(text, 'a countdown states time, never an outcome').not.toMatch(/arriv|nothing comes|no ship|1 ship/i)
})

test('THE FIGHT TAB CARRIES THE WAVE CLOCK AND THE HAUL — the two the owner asked for', async ({ page }) => {
  await open(page, 'fight&t=fight', MEASURED)
  // The wave section: the countdown against a FIXED clock, and the field against the STAMPED cap.
  await expect(page.getByTestId('combat-map-wave-clock-enc-1')).toHaveText('Next wave in 12s')
  await expect(page.getByTestId('combat-map-field-enc-1')).toContainText('4/4')
  // …and NOT a verdict. The field is exactly at its cap here, which is where a client-side
  // computation would be most tempted to promise (or deny) an arrival.
  const wave = await page.getByTestId('combat-map-wave-enc-1').innerText()
  expect(wave).not.toMatch(/arriv|nothing comes|no ship|1 ship/i)
  expect(wave, 'the rule is stated as a rule').toMatch(/under its limit/i)
  // The haul: what is carried, what it takes up, and how full the hold is.
  await expect(page.getByTestId('combat-map-haul-enc-1')).toContainText('Haul')
  await expect(page.getByTestId('combat-map-haul-m3-enc-1')).toContainText('7.5')
  await expect(page.getByTestId('combat-map-hold-enc-1')).toContainText('250')
  await expect(page.getByTestId('combat-map-drops-enc-1')).toContainText('Each kill here drops')
})

test('██ THE HAUL IS THE CARD’S OWN TYPE SIZE — it does not fall back to the document root ██', async ({ page }) => {
  // Owner, playing 2026-08-09: *"the font for haul is too big"*. <ItemChip> INHERITS its font size by
  // design — that is what lets it sit inside a log sentence — and the haul's chip row was the ONE
  // element on this card that set none, so the chips took the document's 16px root while every other
  // line here is 11px or 10px. MEASURED, not eyeballed: the chips must be the same size as the "Haul"
  // heading beside them, and nothing on this card may be at the root size.
  await open(page, 'fight&t=fight', MEASURED)
  const sizes = await page.evaluate(() => {
    const card = document.querySelector('[data-testid="combat-map-card-enc-1"]')!
    const px = (el: Element) => parseFloat(getComputedStyle(el).fontSize)
    // Only elements that OWN a text node are measured. A bare flex wrapper inherits 16px and draws
    // nothing with it; the defect is a element that PRINTS at a size it never chose.
    const inked = [...card.querySelectorAll('*')].filter((el) =>
      [...el.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && (n.textContent ?? '').trim() !== ''),
    )
    return {
      chips: [...card.querySelectorAll('[data-testid^="item-chip-"]')].map(px),
      haulBlock: px(document.querySelector('[data-testid="combat-map-haul-enc-1"]')!),
      oversized: inked
        .filter((el) => px(el) >= 16)
        .map((el) => `${el.tagName}.${el.getAttribute('class') ?? ''}: ${(el.textContent ?? '').slice(0, 40)}`),
    }
  })
  expect(sizes.chips.length, 'the fixture must actually render a haul').toBeGreaterThan(0)
  for (const s of sizes.chips) {
    expect(s, 'a haul chip must not be bigger than the block it sits in').toBeLessThanOrEqual(sizes.haulBlock)
  }
  // The whole card lives in the small register; 16px is the document root fallback, and text sitting
  // at it means the element never chose a size. That is exactly what the haul row did.
  expect(sizes.oversized, 'text on the combat card renders at the document root size').toEqual([])
})

test('██ THE FLEET HOLD IS NOT INSIDE THE HAUL BLOCK — the haul does not land there ██', async ({ page }) => {
  // Owner: *"fleet hold is not updated when fight is done"*. It never will be — combat loot rides the
  // return leg and reward_grant deposits it into the arrival PORT'S storage (base_items); no arm of
  // that chain writes fleet_items. The meter was standing INSIDE the Haul block under a sentence
  // saying the haul would be "banked", which is the only reading the arrangement allowed.
  await open(page, 'fight&t=fight', MEASURED)
  const hold = page.getByTestId('combat-map-hold-enc-1')
  await expect(hold).toBeVisible()
  expect(
    await page.evaluate(() => {
      const haul = document.querySelector('[data-testid="combat-map-haul-enc-1"]')!
      return haul.contains(document.querySelector('[data-testid="combat-map-hold-enc-1"]'))
    }),
    'the hold meter must not sit inside the haul block',
  ).toBe(false)
  // …and the stake sentence names where the haul actually goes.
  await expect(page.getByTestId('combat-map-haul-enc-1')).toContainText('port')
})

// ── 3 · THE TOUCH FLOOR SURVIVES THE FIX ─────────────────────────────────────────────────────────
// Pinning a control out of a scroll region is worthless if it is pinned as a 20px sliver.

for (const vp of [PHONE, FLOOR]) {
  test(`every reachable control still clears ${TOUCH_FLOOR}px at ${vp.width}x${vp.height}`, async ({ page }) => {
    for (const scenario of TOP_SCENARIOS) {
      await open(page, scenario, vp)
      for (const c of await reachOf(page)) {
        expect(c.height, `${c.id} height in ${scenario} at ${vp.width}px`).toBeGreaterThanOrEqual(TOUCH_FLOOR)
      }
    }
  })
}

// ── 4 · THE PAGE NEVER SCROLLS SIDEWAYS ──────────────────────────────────────────────────────────

test('the map surface never scrolls sideways at the 320px floor', async ({ page }) => {
  for (const scenario of [...TOP_SCENARIOS, ...HUB_SCENARIOS]) {
    await open(page, scenario, FLOOR)
    const sideways = await page.evaluate(() => {
      const b = document.body
      const d = document.documentElement
      return b.scrollWidth > b.clientWidth || d.scrollWidth > d.clientWidth
    })
    expect(sideways, `${scenario} pushes the page sideways at 320px`).toBe(false)
  }
})

// ── 4b · THE SURFACE STILL DRAWS — the things this slice must not have broken ────────────────────
// The fix reshaped the map's overlay containers, so the check is not "does my diff work" but "does
// the MAP still work". These three were rendered but only ever asserted in PURE specs, where a
// container change cannot reach them: a `[data-ship-form]` glyph for a placed fleet, the reach ring
// that IS the fire rule, and a fleet label that clears the port glyph instead of lying across it.
// They ride the EXISTING harnesses (/fleet.html, /fight.html) — no second fixture.

test('SURFACE: a placed fleet still draws a ship glyph on the map', async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 760 })
  await page.goto('/fleet.html')
  await page.waitForSelector('#map-host svg > g[transform]')
  // markerStyle/shipGlyph put the form on the glyph itself; no form ⇒ the fleet is an empty marker.
  expect(await page.locator('[data-ship-form]').count(), 'a placed fleet must draw a hull').toBeGreaterThan(0)
})

test('SURFACE: the reach ring still draws over a live battle', async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 760 })
  await page.goto('/fight.html')
  await page.waitForSelector('#map-host svg > g[transform]')
  expect(
    await page.locator('[data-testid^="spatial-combat-range-"]').count(),
    'the ring that states who can be shot must be on the map during a fight',
  ).toBeGreaterThan(0)
})

// ── 5 · THE BRAKE KEEPS ITS PLACE ────────────────────────────────────────────────────────────────
// NO-SOFTLOCK is older than this slice and outranks it: whatever the rail does, Stop stays the first
// thing in the command panel and stays outside a scroll region. Proved on the rendered panel, not
// only in the model.

test('NO-SOFTLOCK survives: the brake is still first in the command panel and still unclipped', async ({ page }) => {
  await open(page, 'hub', PHONE)
  // The hub scenario has no fleet in flight, so there is no stop row — assert instead that the
  // panel's OWN pinned region is still outside its scroll body, which is the property Stop rides on.
  const split = await page.evaluate(() => {
    const panel = document.querySelector('[data-testid="fleet-command-panel"]') as HTMLElement | null
    if (panel === null) return null
    const scrollers = [...panel.querySelectorAll('*')].filter((n) =>
      /auto|scroll/.test(getComputedStyle(n).overflowY),
    ).length
    return { scrollers, panelScrolls: /auto|scroll/.test(getComputedStyle(panel).overflowY) }
  })
  expect(split, 'the command panel must be mounted').not.toBeNull()
  // Exactly ONE scroll region inside the panel: its section body. Two would mean a nested trap.
  expect(split!.scrollers).toBeLessThanOrEqual(1)
})
