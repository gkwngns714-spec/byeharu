// E4 — COMBAT CONTENT: THE ONE new module that talks to the command client. Every combat authoring
// write (E0-E2 create/update/set_active) flows through here; every other E4 module is pure. The hook
// owns the transient per-attempt state and the requestId-once idempotency law (mint ONCE per attempt,
// REUSE on retry so the server replays instead of double-applying — the same law ExplorationDraftPanel
// uses). It is a THIN driver: it builds no payloads (combatPayloads does) and interprets no errors
// (combatErrorMap does). The server is_owner()/flag guard is the sole authority — this grants nothing.
//
// fail-closed not_enabled: the FIRST not_enabled for an entity marks that entity session-disabled, so its
// authoring controls go inert until reload. The UI NEVER reads or flips any *_enabled flag — it only
// reacts to the server's typed refusal.
import { useCallback, useRef, useState } from 'react'
import { invokeWorldEditorCommand } from './commandClient'
import { newRequestId, type WorldEditorCommandFailure, type WorldEditorCommandType } from './commandContract'
import type { CombatCommand } from './combatPayloads'

/** The five authoring entities (each maps to a fail-closed tier in combatErrorMap). */
export type CombatEntity =
  | 'reward_profile'
  | 'enemy_archetype'
  | 'fleet_template'
  | 'encounter_profile'
  | 'location_binding'

/** Transient state for ONE authoring attempt (one form/row). requestId is minted ONCE and reused on
 *  retry of the SAME attempt (idempotent replay); commandType is retained to detect a direction flip. */
export interface AuthoringAttempt {
  readonly requestId: string
  readonly commandType: WorldEditorCommandType
  readonly phase: 'sending' | 'failed'
  readonly failure: WorldEditorCommandFailure | null
}

/** Stable key per logical action so retries reuse the requestId and each row shows its own error. */
function attemptKey(entity: CombatEntity, op: 'create' | 'update' | 'setactive', targetId?: string): string {
  return targetId ? `${entity}:${op}:${targetId}` : `${entity}:${op}`
}

export interface CombatAuthoring {
  /** The current attempt for a key (sending/failed), or null when idle/succeeded. */
  readonly attemptFor: (key: string) => AuthoringAttempt | null
  /** True while a key's command is in flight (drives busy state). */
  readonly isSending: (key: string) => boolean
  /** True once the server has refused this entity with not_enabled (controls go inert this session). */
  readonly isDisabled: (entity: CombatEntity) => boolean
  readonly keyFor: typeof attemptKey
  /** Issue a create. onSuccess closes the form; reload() re-reads the server truth (no optimistic edit). */
  readonly submitCreate: (entity: CombatEntity, command: CombatCommand, onSuccess: () => void) => void
  /** Issue an update addressed by targetId (natural key for E0/E1, binding UUID for E2). */
  readonly submitUpdate: (
    entity: CombatEntity,
    targetId: string,
    command: CombatCommand,
    onSuccess: () => void,
  ) => void
  /** Issue a set_active (enable/disable) addressed by targetId. */
  readonly submitSetActive: (
    entity: CombatEntity,
    targetId: string,
    command: CombatCommand,
    onSuccess: () => void,
  ) => void
}

/** THE hook. `reload` re-reads the combat-content snapshot after any applied write (server authority). */
export function useCombatAuthoring(reload: () => void | Promise<void>): CombatAuthoring {
  const [attempts, setAttempts] = useState<ReadonlyMap<string, AuthoringAttempt>>(new Map())
  const [disabled, setDisabled] = useState<ReadonlySet<CombatEntity>>(new Set())
  // A ref mirror so back-to-back submits read the freshest attempt map for requestId reuse.
  const attemptsRef = useRef(attempts)
  attemptsRef.current = attempts

  const setAttempt = useCallback((key: string, next: AuthoringAttempt | null) => {
    setAttempts((prev) => {
      const map = new Map(prev)
      if (next) map.set(key, next)
      else map.delete(key)
      attemptsRef.current = map
      return map
    })
  }, [])

  const run = useCallback(
    async (key: string, entity: CombatEntity, command: CombatCommand, onSuccess: () => void) => {
      if (disabled.has(entity)) return
      const existing = attemptsRef.current.get(key)
      if (existing?.phase === 'sending') return // guard against a double-submit
      // Mint the requestId ONCE per attempt; a retry of the SAME command reuses it (idempotent replay).
      const requestId =
        existing && existing.commandType === command.commandType ? existing.requestId : newRequestId()
      setAttempt(key, { requestId, commandType: command.commandType, phase: 'sending', failure: null })
      const result = await invokeWorldEditorCommand({
        requestId,
        commandType: command.commandType,
        payload: command.payload,
      })
      // ok:true covers a duplicate_request replay too (code:'duplicate_request') — treat it as success.
      if (result.ok) {
        setAttempt(key, null)
        onSuccess()
        void reload()
        return
      }
      // First not_enabled for an entity disables its authoring for the session (never touch the flag).
      if (result.error === 'not_enabled') {
        setDisabled((prev) => new Set(prev).add(entity))
      }
      setAttempt(key, { requestId, commandType: command.commandType, phase: 'failed', failure: result })
    },
    [disabled, reload, setAttempt],
  )

  const submitCreate = useCallback<CombatAuthoring['submitCreate']>(
    (entity, command, onSuccess) => void run(attemptKey(entity, 'create'), entity, command, onSuccess),
    [run],
  )
  const submitUpdate = useCallback<CombatAuthoring['submitUpdate']>(
    (entity, targetId, command, onSuccess) =>
      void run(attemptKey(entity, 'update', targetId), entity, command, onSuccess),
    [run],
  )
  const submitSetActive = useCallback<CombatAuthoring['submitSetActive']>(
    (entity, targetId, command, onSuccess) =>
      void run(attemptKey(entity, 'setactive', targetId), entity, command, onSuccess),
    [run],
  )

  return {
    attemptFor: (key) => attempts.get(key) ?? null,
    isSending: (key) => attempts.get(key)?.phase === 'sending',
    isDisabled: (entity) => disabled.has(entity),
    keyFor: attemptKey,
    submitCreate,
    submitUpdate,
    submitSetActive,
  }
}
