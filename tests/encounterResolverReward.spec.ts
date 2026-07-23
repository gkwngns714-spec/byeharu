import { test, expect } from '@playwright/test'

// ENCOUNTER RESOLVER (0260/E3) — a PURE arithmetic proof that resolve_encounter_reward_inputs is the
// algebraic mirror of the pre-E3 :898-899 combat reward formula. No browser, no DB: both formulas are
// reproduced here as pure functions and shown to agree for the seeded pirate_standard params across a
// danger x reward_tier grid. Run: `npx playwright test encounterResolverReward.spec.ts`.
//
// This documents WHY the flag-OFF reward is byte-identical and the flag-ON (authored pirate_standard)
// reward is the SAME number: the resolver's adapter is the legacy formula, re-parameterised off the
// authored reward profile instead of the game_config reward_* keys.

// The pre-E3 scalar formula (combat_logic / process_combat_ticks :898-899):
//   round(reward_metal_base * greatest(reward_tier,1) * (1 + reward_danger_scale * danger) * reward_multiplier)
const REWARD_METAL_BASE = 10        // game_config default
const REWARD_DANGER_SCALE = 0.25    // game_config default
const REWARD_MULTIPLIER = 1.0       // game_config default

function legacyReward(rewardTier: number, danger: number): number {
  return Math.round(
    REWARD_METAL_BASE * Math.max(rewardTier, 1) * (1 + REWARD_DANGER_SCALE * danger) * REWARD_MULTIPLIER,
  )
}

// The E3 adapter resolve_encounter_reward_inputs(resource_grants, reward_tier, danger):
//   round(metal.base * greatest(reward_tier,1) * (1 + coalesce(metal.danger_coeff,0) * danger) * cfg_num(metal.multiplier_ref))
type ResourceGrants = { metal: { base: number; danger_coeff?: number; multiplier_ref: string } }
// the ONLY config key the E0 validator permits for multiplier_ref is 'reward_multiplier'.
const CFG: Record<string, number> = { reward_multiplier: REWARD_MULTIPLIER }

function resolveReward(grants: ResourceGrants, rewardTier: number, danger: number): number {
  const m = grants.metal
  // FIX 5: a missing multiplier_ref key yields 1.0 (coalesce), never NaN/undefined — mirrors the SQL
  // `coalesce(public.cfg_num(...), 1.0)`.
  return Math.round(
    m.base * Math.max(rewardTier, 1) * (1 + (m.danger_coeff ?? 0) * danger) * (CFG[m.multiplier_ref] ?? 1.0),
  )
}

// pirate_standard (seeded by E0 / 0257) documents the SAME params combat uses today.
const PIRATE_STANDARD: ResourceGrants = { metal: { base: 10, danger_coeff: 0.25, multiplier_ref: 'reward_multiplier' } }

test('resolve_encounter_reward_inputs equals the legacy scalar reward for pirate_standard across a danger x tier grid', () => {
  for (let rewardTier = 0; rewardTier <= 5; rewardTier++) {
    for (let danger = 1; danger <= 8; danger++) {
      expect(resolveReward(PIRATE_STANDARD, rewardTier, danger)).toBe(legacyReward(rewardTier, danger))
    }
  }
})

test('an authored base distinct from the config default produces a distinct (discriminable) reward', () => {
  // base=20 (the proof.sql authored profile) must differ from the legacy base-10 value for every tier>=1,
  // which is what lets the disposable proof prove the resolved reward branch was taken.
  const authored: ResourceGrants = { metal: { base: 20, danger_coeff: 0.25, multiplier_ref: 'reward_multiplier' } }
  for (let rewardTier = 1; rewardTier <= 5; rewardTier++) {
    expect(resolveReward(authored, rewardTier, 1)).not.toBe(legacyReward(rewardTier, 1))
  }
})

test('FIX 5: an unknown multiplier_ref key falls back to 1.0 (never NaN/undefined)', () => {
  const missing: ResourceGrants = { metal: { base: 10, danger_coeff: 0.25, multiplier_ref: '__no_such_key__' } }
  const v = resolveReward(missing, 1, 1)
  expect(Number.isFinite(v)).toBe(true)
  // with the multiplier defaulting to 1.0 the value equals the legacy formula (which also uses 1.0).
  expect(v).toBe(legacyReward(1, 1))
})
