import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuthStore } from '../../store/authStore'
import { Button, Card, CardHeader, Notice } from '../../components/ui'

// Shared token-based input chrome (both fields are identical); touch-sized for mobile.
const INPUT_CLASSES =
  'min-h-11 w-full rounded-lg border border-edge bg-surface-2 px-3 py-3 text-sm text-ink ' +
  'placeholder:text-ink-faint outline-none transition focus:border-accent focus:ring-1 focus:ring-accent/40'

type Mode = 'signin' | 'signup'

export function AuthPage() {
  const [mode, setMode] = useState<Mode>('signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const signIn = useAuthStore((s) => s.signIn)
  const signUp = useAuthStore((s) => s.signUp)
  const navigate = useNavigate()

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setNotice(null)
    setBusy(true)

    const action = mode === 'signin' ? signIn : signUp
    const { error } = await action(email, password)
    setBusy(false)

    if (error) {
      setError(error)
      return
    }
    if (mode === 'signup') {
      setNotice('Account created. Check your email if confirmation is required, then sign in.')
      setMode('signin')
      return
    }
    navigate('/', { replace: true })
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-app px-4 text-ink">
      <Card className="w-full max-w-sm">
        <CardHeader
          title="Byeharu"
          subtitle={mode === 'signin' ? 'Welcome back, commander.' : 'Claim your first colony.'}
        />

        <form onSubmit={handleSubmit} className="space-y-4">
          <input
            type="email"
            required
            placeholder="Email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className={INPUT_CLASSES}
          />
          <input
            type="password"
            required
            minLength={6}
            placeholder="Password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className={INPUT_CLASSES}
          />

          {error && <Notice tone="danger">{error}</Notice>}
          {notice && <Notice tone="success">{notice}</Notice>}

          <Button
            type="submit"
            variant="primary"
            busy={busy}
            busyLabel="Working…"
            className="w-full"
          >
            {mode === 'signin' ? 'Sign in' : 'Create account'}
          </Button>
        </form>

        <Button
          variant="ghost"
          size="sm"
          className="mt-4 w-full"
          onClick={() => {
            setMode((m) => (m === 'signin' ? 'signup' : 'signin'))
            setError(null)
            setNotice(null)
          }}
        >
          {mode === 'signin'
            ? "Don't have an account? Sign up"
            : 'Already have an account? Sign in'}
        </Button>
      </Card>
    </div>
  )
}
