import {
  KNOWN_AUDIT_COMMAND_TYPES,
  KNOWN_AUDIT_TARGET_TYPES,
  type WorldEditorAuditFilters,
} from './worldEditorAuditTypes'

// WORLD EDITOR V1.5 — History filter bar. Presentation only; the Panel owns state and requests. Exposes
// ONLY the RPC-supported filters (command_type / target_type / exact request_id). "All" is the OMISSION
// of a filter (never an invented enum value); the request_id is trimmed. No client-only fuzzy search.

interface Props {
  readonly filters: WorldEditorAuditFilters
  readonly onChange: (next: WorldEditorAuditFilters) => void
  readonly disabled?: boolean
}

const selectClass =
  'rounded-md border border-edge bg-surface-2 px-2 py-1 text-sm text-ink disabled:opacity-50'

export function WorldEditorHistoryFilters({ filters, onChange, disabled }: Props) {
  return (
    <div className="flex flex-col gap-1.5">
      <label className="flex flex-col gap-0.5">
        <span className="text-[10px] uppercase tracking-wide text-ink-faint">Command</span>
        <select
          className={selectClass}
          value={filters.commandType ?? ''}
          disabled={disabled}
          onChange={(e) => onChange({ ...filters, commandType: e.target.value || undefined })}
        >
          <option value="">All commands</option>
          {KNOWN_AUDIT_COMMAND_TYPES.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </select>
      </label>

      <label className="flex flex-col gap-0.5">
        <span className="text-[10px] uppercase tracking-wide text-ink-faint">Domain</span>
        <select
          className={selectClass}
          value={filters.targetType ?? ''}
          disabled={disabled}
          onChange={(e) => onChange({ ...filters, targetType: e.target.value || undefined })}
        >
          <option value="">All domains</option>
          {KNOWN_AUDIT_TARGET_TYPES.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </select>
      </label>

      <label className="flex flex-col gap-0.5">
        <span className="text-[10px] uppercase tracking-wide text-ink-faint">Exact request ID</span>
        <input
          className={selectClass}
          type="text"
          value={filters.requestId ?? ''}
          disabled={disabled}
          placeholder="paste a request id"
          spellCheck={false}
          onChange={(e) => {
            const v = e.target.value.trim()
            onChange({ ...filters, requestId: v || undefined })
          }}
        />
      </label>
    </div>
  )
}
