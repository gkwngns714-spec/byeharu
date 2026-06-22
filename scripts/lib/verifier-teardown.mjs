// Shared teardown for the legacy main-ship verifiers (Legacy Main-Ship Verifier Safety Repair).
//
// Responsibilities, in this order:
//   1. delete every successfully-created, verifier-owned auth user (this cascades to that player's
//      base / base_units / main_ship_instances / fleets / fleet_units / fleet_movements /
//      main_ship_space_movements / location_presence rows via the existing ON DELETE CASCADE chain);
//   2. restore the captured ORIGINAL `mainship_send_enabled` value (only for verifiers that touch it).
//
// Safety rules:
//   * never hardcode or invent a final flag value;
//   * if the flag was touched but the original value was NOT captured, that is a reported failure —
//     we refuse to write a fallback;
//   * each deletion is independently guarded so one failure cannot prevent the others or the flag
//     restore;
//   * `game_config` is never deleted/reset — only the single flag value is restored.
//
// Returns { failures: string[] }. The caller must fail the verifier (non-zero exit) if non-empty.
export async function teardownVerifier({ admin, createdUserIds = [], flag = null } = {}) {
  const failures = []

  // 1) verifier-owned test users (cascade removes all their game data)
  for (const id of createdUserIds) {
    if (!id) continue
    try {
      const { error } = await admin.auth.admin.deleteUser(id)
      if (error) failures.push(`delete user ${id}: ${error.message}`)
    } catch (e) {
      failures.push(`delete user ${id}: ${e?.message ?? String(e)}`)
    }
  }

  // 2) restore the captured original flag value (only if this verifier touched the flag)
  if (flag && flag.touched) {
    if (flag.original === undefined || flag.original === null) {
      failures.push(
        `restore ${flag.key}: original value was not captured — refusing to invent a fallback`,
      )
    } else {
      try {
        const { error } = await admin.rpc('set_game_config', { p_key: flag.key, p_value: flag.original })
        if (error) failures.push(`restore ${flag.key}: ${error.message}`)
      } catch (e) {
        failures.push(`restore ${flag.key}: ${e?.message ?? String(e)}`)
      }
    }
  }

  return { failures }
}
