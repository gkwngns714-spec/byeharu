// WORLD EDITOR — V2A PR-1 GENERIC draft-validation CONTRACT (types + tiny pure helpers ONLY). No
// React, no DOM, no IO. This module is the SHAPE future domain validators speak — severity / issue /
// report / context — plus the err/warn constructors and the fold aggregator every domain validator
// composes its per-rule outputs with.
//
// DELIBERATE BOUNDARY (V2A PR-1 behavior preservation): the LOCATION domain keeps its own validator
// (locationValidation.ts, BYTE-UNTOUCHED — its import allowlist is pinned by
// tests/locationValidationGuards.spec.ts). The location descriptor simply CALLS validateLocationDraft;
// structural typing flows its ValidationReport into the generic store unchanged. New domains (mining
// etc.) build their validators on THESE types from day one.
import type { DraftValidationEnv } from './draftTypes'

/** 'error' = a future publish WOULD be rejected (live CHECK / hard invariant) → blocks publishable.
 *  'warning' = advisory (convention, server-only-decidable, or visibility risk) → never blocks. */
export type DraftValidationSeverity = 'error' | 'warning'

/** One advisory finding. `TCode` is the domain's closed issue-code union; `TField` is the domain's
 *  payload-key union (null when the issue spans fields / the whole draft). */
export interface DraftValidationIssue<TCode extends string = string, TField extends string = string> {
  readonly code: TCode
  readonly severity: DraftValidationSeverity
  readonly field: TField | null
  readonly message: string
}

/** The folded outcome of every rule. publishable is true iff NO error-severity issue exists —
 *  warnings advise, they never block. */
export interface DraftValidationReport<
  TIssue extends DraftValidationIssue = DraftValidationIssue,
> {
  readonly issues: readonly TIssue[]
  readonly publishable: boolean
}

/** Everything a rule may consult beyond the payload itself — the generic store assembles this from
 *  CURRENT live data (see draftTypes.DraftValidationEnv; re-exported here as the validation-side name). */
export type DraftValidationContext<TPayload, TLive> = DraftValidationEnv<TPayload, TLive>

/** Error-severity issue constructor (a future publish WOULD reject this). */
export const draftValidationError = <TCode extends string, TField extends string>(
  code: TCode,
  field: TField | null,
  message: string,
): DraftValidationIssue<TCode, TField> => ({ code, severity: 'error', field, message })

/** Warning-severity issue constructor (advisory; never blocks). */
export const draftValidationWarning = <TCode extends string, TField extends string>(
  code: TCode,
  field: TField | null,
  message: string,
): DraftValidationIssue<TCode, TField> => ({ code, severity: 'warning', field, message })

/** Fold per-rule outputs (issue | issue-list | null) in canonical order into ONE report — the
 *  aggregator pattern validateLocationDraft uses, extracted for every future domain validator.
 *  Pure and deterministic. */
export function foldDraftValidationReport<TIssue extends DraftValidationIssue>(
  results: readonly (TIssue | readonly TIssue[] | null)[],
): DraftValidationReport<TIssue> {
  const issues: TIssue[] = []
  for (const r of results) {
    if (r === null) continue
    if (Array.isArray(r)) issues.push(...(r as readonly TIssue[]))
    else issues.push(r as TIssue)
  }
  return { issues, publishable: !issues.some((i) => i.severity === 'error') }
}
