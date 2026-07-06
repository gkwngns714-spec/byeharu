import { Link } from 'react-router-dom'
import { Card, CardHeader, buttonClasses } from '../../components/ui'

// Command Center pointer to the single send surface (the Galaxy Map). Replaces the old
// in-dashboard send panel so there is exactly ONE place to launch expeditions. Read-only:
// it just links to /galaxy.
export function ExpeditionLauncher({ hasActive }: { hasActive: boolean }) {
  return (
    <Card tone="accent" data-testid="dashboard-expedition-launcher">
      <CardHeader
        title="Expeditions"
        subtitle={
          hasActive
            ? 'Launch another expedition from the Galaxy Map — pick a destination, choose your ships, and send.'
            : 'No active expedition. Send your first from the Galaxy Map: pick a destination, choose your ships, and send.'
        }
        className="mb-2"
      />
      <p className="text-xs text-ink-faint">
        Rewards stay <span className="text-warning">pending</span> while your fleet is out and are{' '}
        <span className="text-success">secured only when it returns home</span>.
      </p>
      <Link to="/galaxy" className={buttonClasses('primary', 'md', 'mt-4')}>
        🗺 Open Galaxy Map
      </Link>
    </Card>
  )
}
