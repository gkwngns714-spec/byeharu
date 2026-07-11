import { isDocked, type DockServices } from '../map/dockServices'
import { Badge, Card, SectionLabel, StatRow } from '../../components/ui'

// UI-REBUILD (2b, Port interior) — the docked-port surface, in the Ship-established design
// language: IDENTITY (the port's name + Docked badge) → RIGHT NOW (berth statement + the
// leave-via-Map hint; docking is a passive service — the port's ACTION surfaces are the
// server-lit panels PortScreen mounts below) → DETAILS (each active service as a plain-language
// StatRow). PURE presentation over the server dock projection: the ONE dock read lives in
// PortScreen (useDockServices); this renders nothing unless genuinely docked (isDocked — the
// same fail-closed gate the old DockServicesPanel enforced; free-port law: the server is the
// sole authority, no name/coordinate/affiliation-derived docking).
//
// This card IS the former <DockServicesPanel> re-presented full-width for the Port destination
// (the old absolute map-overlay styling died with the overlay mount); its test ids are preserved
// (dock-services-panel / -title / -list / dock-service-<s> / -none — the rendered-proof uispec
// drives them via tests/harness/dock.html).

const SERVICE_LABELS: Record<string, string> = {
  docking: 'Docking',
  market: 'Market',
  repair: 'Repair',
  refit: 'Refit',
  recruitment: 'Recruitment',
}

// Plain player language for what each active service means at this port today.
const SERVICE_NOTES: Record<string, string> = {
  docking: 'Berth secured',
  market: 'Buy & sell goods',
  repair: 'Hull repairs',
  refit: 'Refit your ship',
  recruitment: 'Hire captains',
}

export function DockedPortCard({ dock }: { dock: DockServices }) {
  // Not docked (in transit / in space / destroyed / no ship / home / legacy / contradictory) → nothing.
  if (!isDocked(dock)) return null

  return (
    <Card tone="success" data-testid="dock-services-panel">
      {/* 1 · IDENTITY — the port itself */}
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 data-testid="dock-services-title" className="text-lg font-semibold text-ink">
            {dock.locationName ?? 'Unknown port'}
          </h2>
          <p className="mt-0.5 text-sm text-ink-muted">Your ship is docked here.</p>
        </div>
        <Badge tone="success">Docked</Badge>
      </div>

      {/* 2 · RIGHT NOW — docking is passive; the one thing to decide is when to leave */}
      <div data-testid="port-right-now" className="mt-4 rounded-lg border border-edge bg-surface-2/50 p-3">
        <p className="text-sm text-ink">Berth secured — your ship is safe while docked.</p>
        <p className="mt-1 text-xs text-ink-faint">
          Ready to leave? Pick your next destination on the <span className="text-ink">Map</span>.
        </p>
      </div>

      {/* 3 · DETAILS — only the ACTIVE services the server reported, in plain language */}
      <SectionLabel className="mt-4">Port services</SectionLabel>
      {dock.services.length > 0 ? (
        // R3 density: two service columns once the card is wide enough (the wide ops split hands
        // this card the full or 2/3 row); same rows, same testids.
        <dl data-testid="dock-services-list" className="mt-2 grid gap-y-1.5 text-sm sm:grid-cols-2 sm:gap-x-8">
          {dock.services.map((s) => (
            <StatRow
              key={s}
              data-testid={`dock-service-${s}`}
              label={SERVICE_LABELS[s] ?? s}
              value={SERVICE_NOTES[s] ?? 'Available'}
            />
          ))}
        </dl>
      ) : (
        <p data-testid="dock-services-none" className="mt-2 text-sm text-ink-faint">
          No services available at this port yet.
        </p>
      )}
    </Card>
  )
}
