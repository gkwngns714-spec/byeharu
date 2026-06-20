import { Component, type ErrorInfo, type ReactNode } from 'react'

// TEMPORARY diagnostic error boundary. Wraps the Galaxy screen so a render crash (e.g. the
// pan-triggered black screen) is CAUGHT and its message + stack are shown on screen + logged,
// instead of unmounting the whole React tree (which blanks the page incl. the header and even a
// body-portaled overlay). Read-only; changes no game logic. Remove in the camera-fix cleanup phase.
export class DebugErrorBoundary extends Component<
  { children: ReactNode },
  { error: Error | null; componentStack: string }
> {
  state = { error: null as Error | null, componentStack: '' }

  static getDerivedStateFromError(error: Error) {
    return { error, componentStack: '' }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // eslint-disable-next-line no-console
    console.error('[DebugErrorBoundary] render crash:', error, info.componentStack)
    this.setState({ componentStack: info.componentStack ?? '' })
  }

  render() {
    const { error, componentStack } = this.state
    if (error) {
      return (
        <div
          style={{
            position: 'fixed', inset: 0, zIndex: 2147483647, overflow: 'auto',
            background: '#1a0000', color: '#ffd0d0', padding: 16,
            font: '12px/1.5 ui-monospace, monospace', whiteSpace: 'pre-wrap',
          }}
        >
          <div style={{ color: '#ff6b6b', fontWeight: 700, fontSize: 14 }}>
            ⚠ Galaxy render crashed (temporary debug boundary)
          </div>
          <div style={{ marginTop: 10 }}>{String(error.message ?? error)}</div>
          <pre style={{ marginTop: 10, whiteSpace: 'pre-wrap' }}>{error.stack}</pre>
          {componentStack && (
            <pre style={{ marginTop: 10, whiteSpace: 'pre-wrap', color: '#ffb0b0' }}>{componentStack}</pre>
          )}
        </div>
      )
    }
    return this.props.children
  }
}
