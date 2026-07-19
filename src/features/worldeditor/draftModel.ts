// WORLD EDITOR — V2A PR-1 GENERIC draft PURE MODEL (props in → decision out). No React, no DOM, no
// network IO, no storage IO, no client-server call of any kind — the markerStyle.ts / firstOrders.ts
// pure-module idiom. Extracted BEHAVIOR-PRESERVING from locationDraftModel.ts: every function below is
// the exact V1B lifecycle logic, parameterized by a DomainDraftDescriptor instead of hard-coding the
// location domain. Every function is DETERMINISTIC: ids and timestamps are passed IN by the store
// layer (useDrafts), never generated here.
//
// HARD BOUNDARIES (unchanged from V1B):
//   • Drafts NEVER write anywhere — no live-table mutation, no publish, no grant. This module cannot
//     even express a write.
//   • Coordinates are DRAFT-ONLY values. Bounds problems are FLAGGED (descriptor.withinBounds), NEVER
//     clamped and NEVER thrown — the openSpaceTransform no-hidden-clamping law.
//   • Map representation goes through descriptor.toLayerItem — the SAME LayerItem shape the domain's
//     read adapter produces (one visual language, no fork).
import type { LayerItem } from './worldEditorTypes'
import type {
  DomainDraftDescriptor,
  Draft,
  DraftSourceStatus,
} from './draftTypes'

/** Project anything payload-shaped onto exactly the canonical payload keys (extra properties like a
 *  live row's `id` are dropped). The keys come from the descriptor's ONE canonical order. */
export function projectPayload<TPayload>(
  keys: readonly (keyof TPayload & string)[],
  source: TPayload,
): TPayload {
  const out: Partial<TPayload> = {}
  for (const k of keys) out[k] = source[k]
  return out as TPayload
}

/** Stable fingerprint over the descriptor's payload keys (canonical key order + JSON-encoded values →
 *  FNV-1a 32-bit hex). Same field values ⇒ same fingerprint, on any object carrying the payload keys
 *  (extra properties like a live row's `id` are ignored). Used as the edit fork's `sourceRevision`
 *  and recomputed against CURRENT live rows to detect staleness. */
export function computeSourceFingerprint<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  source: TPayload,
): string {
  const canonical = descriptor.payloadKeys
    .map((k) => `${k}=${JSON.stringify(source[k] ?? null)}`)
    .join('|')
  let h = 0x811c9dc5
  for (let i = 0; i < canonical.length; i++) {
    h ^= canonical.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return (h >>> 0).toString(16).padStart(8, '0')
}

/** Start a brand-new draft (mode 'create') at the descriptor's blank payload. Deterministic — the
 *  caller supplies the id and clock. */
export function beginCreate<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  draftId: string,
  now: number,
): Draft<TPayload> {
  return {
    draftId,
    mode: { kind: 'create' },
    payload: { ...descriptor.emptyCreatePayload },
    createdAt: now,
    updatedAt: now,
  }
}

/** Fork an edit draft off a LIVE row: payload starts as a projection of the row, and the mode pins
 *  sourceId + the row's fingerprint + a full snapshot so dirtiness/staleness stay decidable. */
export function forkEdit<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  live: TLive,
  draftId: string,
  now: number,
): Draft<TPayload> {
  const snapshot = descriptor.projectFromLive(live)
  return {
    draftId,
    mode: {
      kind: 'edit',
      sourceId: descriptor.liveId(live),
      sourceRevision: computeSourceFingerprint(descriptor, snapshot),
      sourceSnapshot: snapshot,
    },
    payload: { ...snapshot },
    createdAt: now,
    updatedAt: now,
  }
}

/** Apply a partial payload change immutably; bumps updatedAt to the supplied clock. */
export function patch<TPayload>(
  draft: Draft<TPayload>,
  partial: Partial<TPayload>,
  now: number,
): Draft<TPayload> {
  return { ...draft, payload: { ...draft.payload, ...partial }, updatedAt: now }
}

/** True when the draft's payload differs from its baseline: the forked snapshot for edits, the blank
 *  create payload for creates. Fingerprint equality — so patching a field back to its original value
 *  cleanly returns to not-dirty. */
export function isDirty<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  draft: Draft<TPayload>,
): boolean {
  const baseline =
    draft.mode.kind === 'edit' ? draft.mode.sourceSnapshot : descriptor.emptyCreatePayload
  return (
    computeSourceFingerprint(descriptor, draft.payload) !==
    computeSourceFingerprint(descriptor, baseline)
  )
}

/** Draft ↔ CURRENT live-row relationship (recomputed, never stored): a create is always 'current';
 *  an edit whose live row vanished is 'source_missing'; an edit whose live row's fingerprint moved
 *  since the fork is 'source_changed'. */
export function draftSourceStatus<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  draft: Draft<TPayload>,
  live: TLive | undefined,
): DraftSourceStatus {
  if (draft.mode.kind !== 'edit') return 'current'
  if (!live) return 'source_missing'
  return computeSourceFingerprint(descriptor, descriptor.projectFromLive(live)) ===
    draft.mode.sourceRevision
    ? 'current'
    : 'source_changed'
}

/** Resolve a draft to the SAME LayerItem shape the domain's read adapter produces, via the ONE
 *  descriptor binding (descriptor.toLayerItem) — the preview speaks the map's visual language with
 *  zero adapter-contract change. */
export function draftToLayerItem<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  draft: Draft<TPayload>,
): LayerItem {
  return descriptor.toLayerItem(draft.draftId, draft.payload)
}

/** Parse + structurally validate ONE stored draft JSON string (localStorage rehydration path).
 *  Returns null on anything malformed — a bad stored blob is dropped, never trusted, never thrown
 *  into the render path. Staleness is NOT decided here: the store re-validates every rehydrated
 *  edit draft against CURRENT live rows via draftSourceStatus (mandatory re-validation). */
export function parseStoredDraft<TPayload, TLive, TReport>(
  descriptor: DomainDraftDescriptor<TPayload, TLive, TReport>,
  json: string,
): Draft<TPayload> | null {
  let raw: unknown
  try {
    raw = JSON.parse(json)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null) return null
  const d = raw as Record<string, unknown>
  if (typeof d.draftId !== 'string' || d.draftId.length === 0) return null
  if (typeof d.createdAt !== 'number' || typeof d.updatedAt !== 'number') return null
  if (!descriptor.isPayloadShaped(d.payload)) return null
  const mode = d.mode as Record<string, unknown> | null | undefined
  if (typeof mode !== 'object' || mode === null) return null
  if (mode.kind === 'create') {
    return {
      draftId: d.draftId,
      mode: { kind: 'create' },
      payload: projectPayload(descriptor.payloadKeys, d.payload as TPayload),
      createdAt: d.createdAt,
      updatedAt: d.updatedAt,
    }
  }
  if (mode.kind === 'edit') {
    if (typeof mode.sourceId !== 'string' || typeof mode.sourceRevision !== 'string') return null
    if (!descriptor.isPayloadShaped(mode.sourceSnapshot)) return null
    return {
      draftId: d.draftId,
      mode: {
        kind: 'edit',
        sourceId: mode.sourceId,
        sourceRevision: mode.sourceRevision,
        sourceSnapshot: projectPayload(descriptor.payloadKeys, mode.sourceSnapshot as TPayload),
      },
      payload: projectPayload(descriptor.payloadKeys, d.payload as TPayload),
      createdAt: d.createdAt,
      updatedAt: d.updatedAt,
    }
  }
  return null
}
