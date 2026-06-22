// Local UNIT proof for scripts/lib/verifier-teardown.mjs (Legacy Main-Ship Verifier Safety Repair).
//   node scripts/verify-mainship-teardown-unit.mjs
//
// No database / no network: drives teardownVerifier() with a mock `admin` and asserts the repaired
// behavior, including the mid-run-failure path (created users + captured flag must still be cleaned
// up / restored when the verifier body aborted early). The disposable-stack INTEGRATION proof
// (CI: verify-mainship-safety-proof) exercises the real verifiers end to end.

import { teardownVerifier } from './lib/verifier-teardown.mjs'

let pass = 0, fail = 0
const ok = (n) => { console.log('  ✓', n); pass++ }
const bad = (n, d) => { console.log('  ✗', n, d ? `— ${d}` : ''); fail++ }

// Mock admin: records deleteUser ids and set_game_config calls; per-id deletion outcome configurable.
function mockAdmin({ deleteResults = {}, rpcError = null } = {}) {
  const calls = { deleted: [], rpc: [] }
  return {
    calls,
    auth: { admin: { deleteUser: async (id) => {
      calls.deleted.push(id)
      const r = deleteResults[id]
      if (r === 'throw') throw new Error(`boom ${id}`)
      return { error: r ? { message: r } : null }
    } } },
    rpc: async (fn, args) => { calls.rpc.push({ fn, args }); return { error: rpcError ? { message: rpcError } : null } },
  }
}

function eq(actual, expected, label) {
  (JSON.stringify(actual) === JSON.stringify(expected)) ? ok(`${label}`) : bad(label, `got ${JSON.stringify(actual)} want ${JSON.stringify(expected)}`)
}

async function main() {
  console.log('\nteardownVerifier() unit proof\n')

  // 1) normal: both users deleted; original TRUE restored exactly
  {
    const a = mockAdmin()
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: ['u1', 'u2'], flag: { key: 'mainship_send_enabled', original: true, touched: true } })
    eq(a.calls.deleted, ['u1', 'u2'], '1. deletes each created user, in order')
    eq(a.calls.rpc, [{ fn: 'set_game_config', args: { p_key: 'mainship_send_enabled', p_value: true } }], '1a. restores original TRUE (exact)')
    eq(failures, [], '1b. no failures')
  }

  // 2) original FALSE is a real value — must be restored, not skipped
  {
    const a = mockAdmin()
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: ['u1'], flag: { key: 'mainship_send_enabled', original: false, touched: true } })
    eq(a.calls.rpc, [{ fn: 'set_game_config', args: { p_key: 'mainship_send_enabled', p_value: false } }], '2. restores original FALSE (not hardcoded/skipped)')
    eq(failures, [], '2a. no failures')
  }

  // 3) flag touched but original NOT captured → no write, reported failure (no invented fallback)
  {
    const a = mockAdmin()
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: ['u1'], flag: { key: 'mainship_send_enabled', original: undefined, touched: true } })
    eq(a.calls.rpc, [], '3. uncaptured original → NO flag write (no fallback)')
    ;(failures.length === 1 && /not captured/i.test(failures[0])) ? ok('3a. reports the uncaptured-original failure') : bad('3a', JSON.stringify(failures))
  }

  // 4) flag not touched (e.g. preview) → only deletes, no flag write, no failures
  {
    const a = mockAdmin()
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: ['u1', 'u2'], flag: null })
    eq(a.calls.rpc, [], '4. preview/no-flag → no flag write')
    eq(a.calls.deleted, ['u1', 'u2'], '4a. still deletes all users')
    eq(failures, [], '4b. no failures')
  }

  // 5) one deletion fails (error) → reported, but the OTHER user is still deleted AND flag still restored
  {
    const a = mockAdmin({ deleteResults: { u1: 'perm denied' } })
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: ['u1', 'u2'], flag: { key: 'mainship_send_enabled', original: true, touched: true } })
    eq(a.calls.deleted, ['u1', 'u2'], '5. attempts every deletion despite one failing')
    eq(a.calls.rpc.length, 1, '5a. flag restore still attempted after a deletion failure')
    ;(failures.length === 1 && /u1/.test(failures[0])) ? ok('5b. reports the failed deletion') : bad('5b', JSON.stringify(failures))
  }

  // 6) deletion throws → captured as a failure, processing continues
  {
    const a = mockAdmin({ deleteResults: { u1: 'throw' } })
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: ['u1', 'u2'], flag: null })
    eq(a.calls.deleted, ['u1', 'u2'], '6. a thrown deletion does not abort the rest')
    ;(failures.length === 1 && /u1/.test(failures[0])) ? ok('6a. thrown deletion reported') : bad('6a', JSON.stringify(failures))
  }

  // 7) flag restore fails → reported
  {
    const a = mockAdmin({ rpcError: 'rpc down' })
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: [], flag: { key: 'mainship_send_enabled', original: true, touched: true } })
    ;(failures.length === 1 && /restore mainship_send_enabled/.test(failures[0])) ? ok('7. flag-restore failure reported') : bad('7', JSON.stringify(failures))
  }

  // 8) skips null/empty ids defensively
  {
    const a = mockAdmin()
    const { failures } = await teardownVerifier({ admin: a, createdUserIds: ['u1', null, undefined, ''], flag: null })
    eq(a.calls.deleted, ['u1'], '8. ignores null/empty user ids')
    eq(failures, [], '8a. no failures')
  }

  console.log(`\nteardown unit: ${pass} passed, ${fail} failed\n`)
  process.exitCode = fail > 0 ? 1 : 0
}

main()
