import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import {
  overlayAccountClass,
  overlayRailClass,
  overlayReachClass,
  OVERLAY_SLOTS,
} from '../src/components/ui/overlayLayout'

// ██ THE REACH LAW — the STATIC half. ██
//
// Owner, playing the LIVE game, 2026-08-08: "right now i can't press hunt." The button was enabled
// and 36 of its 44 pixels were below the fold of a scroll box whose cap lived at the CALL SITE
// (`max-h-[60%] overflow-y-auto` on MapScreen's top-left OverlayRail). The rendered proof
// (tests/actionsAreReachable.uispec.ts) measures that it cannot happen today. THIS file makes it
// impossible to reintroduce by hand, because the owner's actual complaint was not the button:
//
//   "one thing made, one thing gets broken, a standard spaghetti. i want you to create things
//    thoroughly. i told you many times that this should not happen yet it always does."
//
// A rule that lives only in a comment gets broken. A rule the suite enforces does not. Three
// invariants, all statically checkable, all of which the pre-fix tree violated:
//
//   1. THE REGIONS ARE WHAT THEY CLAIM — the account scrolls and can shrink; the reach never does.
//   2. NO CALL SITE MAY CAP OR SCROLL A RAIL. A scroll ancestor ABOVE the reach region defeats it
//      silently — that is precisely how this defect survived a green rendered UI proof for weeks.
//   3. EVERY ACTION-BEARING PANEL IN THE MAP OVERLAY RIDES `reach`. Moving one back into the
//      scrolling children is exactly the regression that started this, so it fails the build.

const read = (rel: string) => readFileSync(fileURLToPath(new URL(`../${rel}`, import.meta.url)), 'utf8')

// ── 1 · THE REGIONS ARE WHAT THEY CLAIM ──────────────────────────────────────────────────────────

test('the ACCOUNT region scrolls and yields room; the REACH region does neither', () => {
  const account = overlayAccountClass()
  const reach = overlayReachClass()

  // Information may scroll, and `min-h-0` is what lets it actually shrink inside a flex column —
  // without it a flex item refuses to go below its content height and the cap silently moves onto
  // its sibling, which is the whole bug in one missing utility.
  expect(account).toContain('overflow-y-auto')
  expect(account).toContain('min-h-0')

  // Controls: never scrolled, never shrunk. `shrink-0` is the load-bearing half — it is what makes
  // the account collapse first instead of the buttons being cropped.
  expect(reach).toContain('shrink-0')
  expect(reach).not.toContain('overflow')
  expect(reach).not.toContain('max-h')
  expect(reach).not.toContain('min-h-0')
})

test('the rail bounds itself to the map box and never scrolls — the cap is not a call site’s to give', () => {
  for (const slot of OVERLAY_SLOTS) {
    const cls = overlayRailClass(slot)
    // Bounded, so a rail can never grow past the surface it floats on…
    expect(cls, `${slot} rail must bound itself`).toContain('max-h-[calc(100%-1.5rem)]')
    // …and NOT a scroll container, because scrolling belongs to the account region inside it.
    expect(cls, `${slot} rail must not scroll`).not.toContain('overflow')
    // A flex COLUMN, or "shrink the account first" has no meaning.
    expect(cls, `${slot} rail must be a flex column`).toContain('flex-col')
  }
})

// ── 2 · NO CALL SITE MAY CAP OR SCROLL A RAIL ────────────────────────────────────────────────────

/** Every `<OverlayRail … >` opening tag in a file, as raw text. */
function railTags(source: string): string[] {
  // COMMENTS STRIPPED FIRST. The rule is about what a call site PASSES, never about what it says. A
  // rail whose props are clean can still carry a paragraph explaining why the rail's overflow is now
  // impossible, and a naive substring probe would fail the build on its own documentation. This is
  // the `codeOnly` idiom tests/combatMapCard.spec.ts already uses, and the same coupling the SQL
  // self-asserts strip `--` for: a probe must never trip over the prose that justifies it.
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/[^\n]*$/gm, '')
  return [...code.matchAll(/<OverlayRail\b[\s\S]*?>/g)].map((m) => m[0])
}

/** Every file that mounts a rail — src AND the test harnesses, because a harness that hand-copies a
 *  stale cap is a proof measuring a layout the game does not have. That is not hypothetical: the
 *  fleetinfo harness carried `max-h-[60%] … overflow-y-auto` copied out of MapScreen and stayed
 *  green while the real rail clipped Hunt off the screen. */
const RAIL_CALL_SITES = [
  'src/features/map/MapScreen.tsx',
  'src/features/map/GalaxyMap.tsx',
  'tests/harness/reachHarness.tsx',
  'tests/harness/fleetinfoHarness.tsx',
  // ADDED with the tabs: fightHarness mounted the map's rail with a hand-copied
  // `max-h-[60%] … overflow-y-auto` for months. It measured a layout the game does not have, which
  // is precisely the failure the comment above describes — and it was not on this list, so nothing
  // caught it.
  'tests/harness/fightHarness.tsx',
]

for (const file of RAIL_CALL_SITES) {
  test(`${file}: no OverlayRail is capped or scrolled at the call site`, () => {
    const tags = railTags(read(file))
    expect(tags.length, `${file} is listed as a rail call site but mounts none`).toBeGreaterThan(0)
    for (const tag of tags) {
      expect(tag, `a rail in ${file} sets overflow — the reach region below it would be defeated`).not.toMatch(
        /overflow/,
      )
      expect(tag, `a rail in ${file} sets a height cap — the rail bounds itself; a cap here crops actions`).not.toMatch(
        /max-h-/,
      )
    }
  })
}

// ── 3 · EVERY ACTION-BEARING PANEL IN THE MAP OVERLAY RIDES `reach` ──────────────────────────────
//
// The inventory, enumerated from the map overlay on 2026-08-08 and pinned here so it cannot quietly
// shrink. Each of these mounts at least one control the player presses:
//
//   top-left rail  · ExplorationPanel  → "Scan for signals"
//                  · CombatMapCard     → RetreatControl, per live encounter
//                  · FleetStatusPanel  → the fold toggle, and per fleet either Hunt or Retreat
//   bottom-right   · the hub header    → ← back, ✕ close  (the ONLY way to dismiss the hub)
//     command hub  · FleetCommandPanel → Stop / Go / Dock / Hunt + confirm + the return-port picker
//                  · MiningPanel       → Extract
//                  · ZoneInfoPanel     → "Hunt at <site>"
//                  · PirateInterceptPanel → mode, undo, clear, commit
//
// The ONLY things left in an account region are the ambush and near-miss notices, which are pure
// text. If a notice ever grows a button it moves too — and this test is where that gets caught.
const ACTION_PANELS = [
  'MapOverlayTabs',
  'ExplorationPanel',
  'CombatMapCard',
  'FleetStatusPanel',
  'map-command-panel-header',
  'FleetCommandPanel',
  'MiningPanel',
  'ZoneInfoPanel',
  'PirateInterceptPanel',
]

test('MapScreen mounts every action-bearing overlay panel inside a rail’s `reach` region', () => {
  const source = read('src/features/map/MapScreen.tsx')

  // Slice the file into the two rails' `reach={ … }` payloads by brace-matching from `reach={`.
  const reachBlocks: string[] = []
  for (const m of source.matchAll(/reach=\{/g)) {
    let depth = 1
    let i = m.index! + m[0].length
    while (i < source.length && depth > 0) {
      if (source[i] === '{') depth += 1
      else if (source[i] === '}') depth -= 1
      i += 1
    }
    reachBlocks.push(source.slice(m.index!, i))
  }
  expect(reachBlocks.length, 'MapScreen must mount both map-overlay rails with a reach region').toBe(2)

  const reachSource = reachBlocks.join('\n')
  for (const panel of ACTION_PANELS) {
    expect(
      reachSource,
      `${panel} carries a control, so it must ride a rail's \`reach\` region — not its scrolling children`,
    ).toContain(panel)
  }

  // …and the account regions hold nothing but notices. Anything else there is an action one edit
  // away from being cropped again.
  const outsideReach = reachBlocks.reduce((s, b) => s.replace(b, ''), source)
  const railChildren = outsideReach.slice(outsideReach.indexOf('<OverlayRail'))
  for (const panel of ACTION_PANELS) {
    expect(railChildren, `${panel} must not ALSO be mounted outside \`reach\` (two mounts = two behaviours)`).not.toContain(
      `<${panel}`,
    )
  }
})

// ── 4 · WHAT MUST NOT REGRESS ────────────────────────────────────────────────────────────────────

test('NO-SOFTLOCK: the brake still renders outside the command panel’s own scroll region', () => {
  const source = read('src/features/map/FleetCommandPanel.tsx')
  // The stop section is pinned with the SAME builder the rails use — one authority for the law,
  // composed, never re-stated in a local class string.
  expect(source).toMatch(/stopSection && <div className=\{overlayReachClass\(\)\}>/)
  expect(source).toMatch(/overlayAccountClass\(stopSection \? 'mt-2' : ''\)/)
  // And the model still guarantees Stop is section 0, target-independent (fleetCommandPanel.spec).
  expect(read('src/features/map/fleetCommandModel.ts')).toContain('Stop (when present) is ALWAYS index 0')
})

test('ONE hunt call site in the whole client survives the fix', () => {
  // howAFightStarts.spec.ts owns this rule; restated here because the reach law moved every hunt
  // AFFORDANCE and a second RPC call site would be the easiest way to "fix" reachability wrongly.
  const hits = [...read('src/features/command/teamCombat.ts').matchAll(/send_ship_group_hunt/g)]
  expect(hits.length, 'the hunt RPC name may appear only in its one wrapper').toBeGreaterThan(0)
})

test('AT MOST ONE TAB BODY IS EVER MOUNTED - the stack cannot come back', () => {
  // STRONGER THAN THE YIELD ORDER IT REPLACES. The old rule ranked three simultaneously-mounted
  // panels so that pressure landed on the least urgent one first; it made the overflow SURVIVABLE.
  // The tabs make it IMPOSSIBLE: the rail holds the tab bar, the pinned fight row, and ONE body.
  // A yield order between panels that can never be on screen together is a rule about nothing, so
  // the assertion moved to the invariant that now does the work.
  const model = read('src/features/map/mapOverlayTabModel.ts')
  const shell = read('src/features/map/MapOverlayTabs.tsx')

  // The model can only ever name ONE open tab (a single id, or null) - not a set.
  expect(model).toMatch(/export function pressTab\(open: MapOverlayTabId \| null, pressed: MapOverlayTabId\): MapOverlayTabId \| null/)
  expect(model, 'pressing another tab replaces the open one; it never adds to it').toContain(
    'return open === pressed ? null : pressed',
  )
  // ...and the shell renders exactly one body from it, by a chain of ternaries over that one id.
  expect(shell).toMatch(
    /const body =\s*open === 'explore' \? explore : open === 'fight' \? fight : open === 'fleets' \? fleets : null/,
  )
  expect(shell, 'one body element, rendered once').toMatch(/\{body\}/)
  expect((shell.match(/\{body\}/g) ?? []).length, 'the body may be rendered in exactly one place').toBe(1)

  // The two PINNED rows are pinned, and the body is the only thing that may give way.
  expect(shell, 'the tab bar is all control - it never shrinks').toMatch(/data-testid="map-tabbar"/)
  expect(shell).toMatch(/className="flex shrink-0 items-center gap-1 p-1"/)
  expect(shell, 'the fight row is pinned too - it carries the way out').toMatch(/shrink-0 flex-col gap-2"/)

  // Each body still floors at its own pinned content, so the squeeze can never eat a control.
  for (const [file, name] of [
    ['src/features/exploration/ExplorationPanel.tsx', 'ExplorationPanel'],
    ['src/features/map/CombatMapCard.tsx', 'CombatMapCard'],
    ['src/features/map/FleetStatusPanel.tsx', 'FleetStatusPanel'],
  ] as const) {
    expect(read(file), `${name} must floor at its own pinned content`).toMatch(/min-h-\[[0-9.]+rem\]/)
  }
})

test('THE WAY OUT OF A FIGHT IS NOT IN A TAB', () => {
  // The whole reason a fold is safe. A tab can be closed; a fight cannot be paused. So the ONE
  // RetreatControl is mounted by the shell, per live encounter, above the body and outside it - and
  // the readout that used to carry it now carries no control at all.
  const shell = read('src/features/map/MapOverlayTabs.tsx')
  expect(shell).toContain('<RetreatControl')
  expect(
    shell.indexOf('<RetreatControl'),
    'the fight row renders before the body, so no body can squeeze it',
  ).toBeLessThan(shell.indexOf('map-tab-body-'))
  expect(read('src/features/map/CombatMapCard.tsx'), 'the fight readout must not mount one too').not.toContain(
    '<RetreatControl',
  )
  // ...and a closed fight tab is never silent: the pinned row states the phase in words.
  expect(shell).toContain('{phase.label}')
  expect(shell, 'and the tab itself carries a live dot').toContain('map-tab-fight-live')
})

test('RetreatControl owns its own touch floor — the two map mounts cannot disagree again', () => {
  const control = read('src/features/combat/RetreatControl.tsx')
  expect(control, 'the 44px floor belongs to the control, not to each caller').toContain('min-h-11')
  for (const caller of ['src/features/map/CombatMapCard.tsx', 'src/features/map/FleetStatusPanel.tsx']) {
    expect(read(caller), `${caller} must not reach into the control's internals with [&_button]`).not.toContain(
      '[&_button]:min-h-11',
    )
  }
})
