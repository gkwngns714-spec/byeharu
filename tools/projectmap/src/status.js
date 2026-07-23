// Status derivation — the honest core of the map.
//
// Rule: a node is only coloured LIVE/DARK when production actually proves it.
// Anything we cannot prove lands in NEEDS_CHECK. We never infer "deployed"
// from "merged to main" — on this project those are demonstrably different
// things (the Deploy workflow waits on a manual production approval).

export const STATUS = {
  LIVE:        { key: 'LIVE',        label: 'Live in production',   color: 0x3ddc84, hex: '#3ddc84', desc: 'Deployed AND its gate is on. Players are touching this right now.' },
  DARK:        { key: 'DARK',        label: 'Dark (built, gated off)', color: 0xa66cff, hex: '#a66cff', desc: 'Deployed to prod but its flag is false. Code is live, behaviour is not.' },
  MIGRATED:    { key: 'MIGRATED',    label: 'Merged, not deployed', color: 0xffb03a, hex: '#ffb03a', desc: 'On main but NOT in the production database yet. Waiting on the deploy gate.' },
  ALWAYS_ON:   { key: 'ALWAYS_ON',   label: 'Live, ungated',        color: 0x35c1e0, hex: '#35c1e0', desc: 'In prod with no feature flag — additive data or always-on infrastructure.' },
  PLANNED:     { key: 'PLANNED',     label: 'Planned, not built',   color: 0x8e99b8, hex: '#8e99b8', desc: 'Written down in the plan, with no migration behind it yet. This is the future.' },
  NEEDS_CHECK: { key: 'NEEDS_CHECK', label: 'Needs checking',       color: 0xff5470, hex: '#ff5470', desc: 'Production state could not be proven from the repo or the live read.' },
}

export const STATUS_ORDER = ['LIVE', 'ALWAYS_ON', 'DARK', 'MIGRATED', 'PLANNED', 'NEEDS_CHECK']

/**
 * Work out the deploy frontier from hard evidence.
 *
 * A migration that seeds a game_config flag leaves a fingerprint in prod: if the
 * row is there, the migration ran. That gives us confirmed-deployed stamps and
 * confirmed-missing stamps, and therefore a boundary. Migrations between the two
 * carry no fingerprint, so we say so instead of pretending.
 */
export function deriveFrontier(graph, live) {
  const flagsKnown = live?.sources?.gameConfig?.ok === true
  const prod = live?.flags ?? {}

  // Without a live read we know NOTHING about prod. Bail before computing a
  // frontier: an empty `prod` makes every flag look absent, which would let us
  // announce "prod is behind main from <the very first flag>" on zero evidence.
  if (!flagsKnown) {
    return { flagsKnown: false, deployedThrough: null, missingFrom: null, confirmedDeployed: [], confirmedMissing: [] }
  }

  const confirmedDeployed = []
  const confirmedMissing = []

  for (const n of graph.nodes) {
    if (n.kind !== 'migration' || !n.seedsFlag?.length) continue
    const present = n.seedsFlag.filter((f) => f in prod)
    const absent = n.seedsFlag.filter((f) => !(f in prod))
    if (present.length && !absent.length) confirmedDeployed.push(n.stamp)
    if (absent.length) confirmedMissing.push(n.stamp)
  }

  confirmedDeployed.sort()
  confirmedMissing.sort()

  return {
    flagsKnown,
    // highest stamp we can PROVE reached prod
    deployedThrough: confirmedDeployed.length ? confirmedDeployed[confirmedDeployed.length - 1] : null,
    // lowest stamp we can PROVE did NOT reach prod
    missingFrom: confirmedMissing.length ? confirmedMissing[0] : null,
    confirmedDeployed,
    confirmedMissing,
  }
}

/** Status for a single migration node. */
function migrationStatus(node, prod, frontier) {
  if (!frontier.flagsKnown) return STATUS.NEEDS_CHECK

  if (node.seedsFlag?.length) {
    const absent = node.seedsFlag.filter((f) => !(f in prod))
    if (absent.length) return STATUS.MIGRATED          // proven not in prod
    const anyOn = node.seedsFlag.some((f) => prod[f] === true)
    return anyOn ? STATUS.LIVE : STATUS.DARK           // proven in prod
  }

  // No flag fingerprint of its own — position it against the frontier.
  if (frontier.missingFrom && node.stamp >= frontier.missingFrom) return STATUS.MIGRATED
  if (frontier.deployedThrough && node.stamp <= frontier.deployedThrough) return STATUS.ALWAYS_ON
  return STATUS.NEEDS_CHECK
}

/**
 * Assign a status to every node.
 * Symbols (functions/tables) inherit from the migration that last defined them,
 * then get darkened if a flag gates them.
 */
export function deriveStatuses(graph, live) {
  const prod = live?.flags ?? {}
  const frontier = deriveFrontier(graph, live)
  const status = new Map()
  const why = new Map()

  const byId = new Map(graph.nodes.map((n) => [n.id, n]))

  // 1. flags — the most directly provable thing we have
  for (const n of graph.nodes) {
    if (n.kind !== 'flag') continue
    if (!frontier.flagsKnown) { status.set(n.id, STATUS.NEEDS_CHECK); why.set(n.id, 'no live read available'); continue }
    if (!(n.label in prod)) {
      status.set(n.id, STATUS.MIGRATED)
      why.set(n.id, 'seeded in a migration, but no such row in production — its migration has not been applied')
    } else if (prod[n.label] === true) {
      status.set(n.id, STATUS.LIVE); why.set(n.id, 'game_config row is true in production')
    } else {
      status.set(n.id, STATUS.DARK); why.set(n.id, 'game_config row is false in production')
    }
  }

  // 2. migrations
  for (const n of graph.nodes) {
    if (n.kind !== 'migration') continue
    const s = migrationStatus(n, prod, frontier)
    status.set(n.id, s)
    why.set(n.id, s === STATUS.MIGRATED
      ? 'not present in production (proven by a missing flag row, or sits after the deploy frontier)'
      : s === STATUS.NEEDS_CHECK
        ? 'seeds no flag and falls in the unproven band between the deploy frontier and the first missing migration'
        : 'reached production')
  }

  // 3. functions + tables — inherit from their newest defining migration
  const definedBy = new Map() // symbolId -> [migration nodes]
  for (const e of graph.edges) {
    if (e.type !== 'creates') continue
    const arr = definedBy.get(e.target) ?? []
    arr.push(byId.get(e.source))
    definedBy.set(e.target, arr)
  }
  // which flags gate a symbol: migration --gated-by--> flag, for the mig that made it
  const gatesOf = new Map()
  for (const e of graph.edges) {
    if (e.type !== 'gated-by') continue
    const arr = gatesOf.get(e.source) ?? []
    arr.push(e.target)
    gatesOf.set(e.source, arr)
  }

  for (const n of graph.nodes) {
    if (n.kind !== 'function' && n.kind !== 'table') continue
    const migs = (definedBy.get(n.id) ?? []).filter(Boolean).sort((a, b) => a.stamp.localeCompare(b.stamp))
    const head = migs[migs.length - 1]
    if (!head) { status.set(n.id, STATUS.NEEDS_CHECK); why.set(n.id, 'no creating migration found'); continue }

    const headStatus = status.get(head.id) ?? STATUS.NEEDS_CHECK
    if (headStatus === STATUS.MIGRATED || headStatus === STATUS.NEEDS_CHECK) {
      status.set(n.id, headStatus)
      why.set(n.id, `its newest definition is ${head.label}, which is ${headStatus.label.toLowerCase()}`)
      continue
    }

    // In prod. Is anything gating it dark?
    const flags = (gatesOf.get(head.id) ?? []).map((fid) => byId.get(fid)?.label).filter(Boolean)
    const known = flags.filter((f) => f in prod)
    if (known.length && known.every((f) => prod[f] === false)) {
      status.set(n.id, STATUS.DARK)
      why.set(n.id, `in prod, gated off by ${known.join(', ')}`)
    } else if (known.some((f) => prod[f] === true)) {
      status.set(n.id, STATUS.LIVE)
      why.set(n.id, `in prod, gate ${known.filter((f) => prod[f]).join(', ')} is on`)
    } else {
      status.set(n.id, STATUS.ALWAYS_ON)
      why.set(n.id, 'in prod, no feature gate found')
    }
  }

  // 4. the future — plan phases and activation rungs.
  // These are the only nodes that describe intent rather than code, so they are
  // the only ones that can be PLANNED. A rung's colour answers the question the
  // ladder actually poses: is this done, ready to flip, or blocked?
  const outOf = (id, type) => graph.edges.filter((e) => e.source === id && e.type === type).map((e) => e.target)
  for (const n of graph.nodes) {
    if (n.kind !== 'phase' && n.kind !== 'rung') continue

    const flagIds = [...outOf(n.id, 'delivers'), ...outOf(n.id, 'flips')]
    const flagNames = flagIds.map((f) => byId.get(f)?.label).filter(Boolean)
    const migIds = outOf(n.id, 'delivered-by')

    if (n.kind === 'phase' && n.planned) {
      status.set(n.id, STATUS.PLANNED)
      why.set(n.id, 'named in FULL_CAPACITY_PLAN with no migration behind it — not built yet')
      continue
    }
    if (!frontier.flagsKnown) { status.set(n.id, STATUS.NEEDS_CHECK); why.set(n.id, 'no live read available'); continue }
    if (!flagNames.length && !migIds.length) {
      status.set(n.id, STATUS.NEEDS_CHECK)
      why.set(n.id, 'the plan names no flag, script, or migration for this — nothing to check it against')
      continue
    }

    const known = flagNames.filter((f) => f in prod)
    const absent = flagNames.filter((f) => !(f in prod))
    const migStatuses = migIds.map((m) => status.get(m)).filter(Boolean)

    if (absent.length || migStatuses.some((s) => s === STATUS.MIGRATED)) {
      status.set(n.id, STATUS.MIGRATED)
      why.set(n.id, n.kind === 'rung'
        ? `blocked — ${absent.length ? `${absent.join(', ')} is not in production` : 'a migration behind it has not deployed'}`
        : 'a migration or flag behind this has not reached production')
    } else if (known.length && known.every((f) => prod[f] === true)) {
      status.set(n.id, STATUS.LIVE)
      why.set(n.id, n.kind === 'rung' ? 'done — every flag this rung flips is already on' : 'shipped and live')
    } else if (known.some((f) => prod[f] === true)) {
      const on = known.filter((f) => prod[f])
      const off = known.filter((f) => !prod[f])
      // A rung is a job. Half-done is not done — it is still owed, so it stays
      // in the "still to flip" colour rather than being waved through as live.
      status.set(n.id, n.kind === 'rung' ? STATUS.DARK : STATUS.LIVE)
      why.set(n.id, n.kind === 'rung'
        ? `still owed — ${off.join(', ')} is off (${on.join(', ')} already on)`
        : `partly on — ${on.join(', ')} live, ${off.join(', ')} still off`)
    } else if (known.length) {
      status.set(n.id, STATUS.DARK)
      why.set(n.id, n.kind === 'rung'
        ? `ready to flip — everything is deployed, ${known.join(', ')} is just off`
        : `built and deployed, gated off by ${known.join(', ')}`)
    } else {
      status.set(n.id, STATUS.ALWAYS_ON)
      why.set(n.id, 'its migrations are in production and it has no gate')
    }
  }

  // 5. systems — roll up from the tables they own
  for (const n of graph.nodes) {
    if (n.kind !== 'system') continue
    const owned = graph.edges.filter((e) => e.type === 'owned-by' && e.target === n.id).map((e) => status.get(e.source))
    if (!owned.length) { status.set(n.id, STATUS.NEEDS_CHECK); why.set(n.id, 'owns no scanned table'); continue }
    const pick = ['LIVE', 'ALWAYS_ON', 'DARK', 'MIGRATED', 'NEEDS_CHECK']
      .find((k) => owned.some((s) => s?.key === k))
    status.set(n.id, STATUS[pick])
    why.set(n.id, `rolled up from ${owned.length} owned table(s)`)
  }

  for (const n of graph.nodes) if (!status.has(n.id)) status.set(n.id, STATUS.NEEDS_CHECK)

  return { status, why, frontier }
}
