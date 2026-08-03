// FLEET-TAB / FOLDABLE-REPORTS (UI proof) — mounts the REAL <ReportsSection> (exactly what
// CommandScreen composes) with injected report rows, so a Playwright spec can drive the rendered
// fold behavior: the section-level CollapsibleCard (persisted via localStorage), the per-report
// rows (newest open by default), and keyboard toggling. No production access; nothing connects —
// the only fetch this component can make (the round log's on-demand ticks) fires ONLY on a
// round-log click, which the spec never performs.
import { createRoot } from 'react-dom/client'
import { ReportsSection } from '../../src/features/combat/ReportsSection'
import type { CombatReport } from '../../src/features/combat/combatTypes'
import type { MapLocation } from '../../src/features/map/mapTypes'

const report = (n: number, created_at: string): CombatReport => ({
  id: `rep-${n}`,
  encounter_id: `enc-${n}`,
  fleet_id: null,
  location_id: 'loc-1',
  result: n % 2 === 0 ? 'completed' : 'defeat',
  waves_cleared: n,
  duration_seconds: 60 * n,
  total_losses_json: { fighter: n },
  total_rewards_json: { metal: 10 * n },
  survivors_json: { fighter: 1 },
  summary_text: null,
  created_at,
})

// Deliberately NOT sorted newest-first: the newest-open default must come from created_at,
// never from array order (the reportFold.ts contract).
const reports: CombatReport[] = [
  report(1, '2026-08-01T10:00:00Z'),
  report(3, '2026-08-03T10:00:00Z'), // the newest — defaults OPEN
  report(2, '2026-08-02T10:00:00Z'),
]

const locations: MapLocation[] = [
  {
    id: 'loc-1',
    name: 'Haven',
    location_type: 'trade_outpost',
    x: 0,
    y: 0,
    base_difficulty: 1,
    reward_tier: 1,
    activity_type: 'none',
    min_power_required: 0,
    is_public: true,
    status: 'active',
    territory_radius: null,
  },
]

createRoot(document.getElementById('root')!).render(
  <ReportsSection reports={reports} locations={locations} unitTypes={[]} />,
)
