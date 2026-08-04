# OWNER RULING — Target capacity, and the speed/range rejections

**Issued 2026-08-04. Recorded, NOT started.** Recording this architecture is authorized; **no schema,
allocator, progression or combat implementation may begin** under that authorization.

---

## What target capacity is

> **The maximum number of distinct enemy ships that one fleet may actively engage at the same time.**

It does **not** limit how many friendly ships may fire. Capacity 1 → every eligible ship focuses one
enemy. Capacity 2 → fire may be distributed across at most two. Capacity 6 → up to six concurrently.

## Why it is worth building — the arithmetic reverses the intuition

Restricting the fleet to one target is **not** a nerf. Let `H` = the wave's total HP and `P` = the
fleet's damage per tick.

- **Spread (today):** damage divides among `n` targets, so they all die at roughly `T = H/P`. Every
  enemy shoots for the whole wave. Damage taken `= attack_total × H/P`.
- **Focus (capacity 1):** the k-th enemy dies at `k·H/(nP)`; each kill removes `1/n` of enemy DPS.
  Damage taken `= attack_total × H/P × (n+1)/(2n)`.

**Time to clear is identical** — total wave HP is conserved and all player damage lands either way.
**Damage taken falls by `(n+1)/(2n)`: −25% at n=2, −37.5% at n=4, −42% at n=6.** Against 0310's 30%
auto-exit that means fleets survive **more** waves and are pushed **deeper**. It is an escalation.

## What the current behaviour actually is — and what it is NOT

The spread is **across SHIPS**, and it is **unconditional and ungated**: the tick loops every unit and
calls `combat_acquire_target` from *that ship's own position*, so four ships on the escort ring resolve
to up to four different enemies. Multiple guns on **one** hull already focus a single enemy (0336 hunk
15 re-acquires only when the held target dies).

> **`per_ship_targeting_enabled` is NOT this rule and must not be repurposed.** It is read once and
> used once, inside the legacy non-spatial arm that no live fight executes. Flipping it changes nothing.

## Ownership

Persist on the **persistent roster** (`ship_groups`), never on the sortie-created `fleets` row — a
`fleets` row is minted fresh per sortie and would evaporate. Two values:

```
1 <= selected_target_capacity <= unlocked_target_capacity <= 6
```

A new roster defaults to selected **1**. A sortie **inherits** the roster setting and never becomes its
authority. Lowering or removing the command captain **clamps the effective value** to the newly
unlocked maximum **without corrupting the stored preference** — preserve the preferred value separately
so it can be restored when eligibility returns.

## Progression driver — the command ship's captain, and nothing else

Growth is driven by the captain assigned to the roster's designated **command ship / flagship**.

**Explicitly rejected:** highest captain level anywhere in the fleet (this would make arbitrary captain
swapping the fleet-command authority) · sum of captain levels · average · ship count · fleet power · a
newly minted sortie row.

If there is no unambiguous persistent command-ship designation, **do not approximate one** — add or
identify that authority first. **With no valid command captain, unlocked capacity is 1.**

## Unlock table — discrete, data-defined, centrally testable

| command captain level | unlocked capacity |
|---:|---:|
| 1 | 1 |
| 10 | 2 |
| 25 | 3 |
| 45 | 4 |
| 70 | 5 |
| 99 | 6 |

Not a continuous formula. Functional level caps at **99**; XP may exceed it; post-cap XP unlocks
nothing above 6.

## Ceiling — 6, and it is not derived at runtime

Six is the current maximum wave size (`enemy_synthetic_max_units`); above it has no gameplay meaning.
The registry must reject values above the engine-supported ceiling. **Do not derive the ceiling
silently from mutable wave data** — if maximum wave size changes later, the capacity ceiling requires
an explicit content and balance ruling.

## The allocator — one deterministic fleet-level authority

1. Resolve the fleet's effective capacity. 2. Build the eligible enemy set. 3. Select no more than that
many distinct targets. 4. Assign friendly ships deterministically. 5. Stable tie-breaking. 6. No random
spread. 7. **No ship may independently expand the target set.**

Capacity 1 must produce genuine focused fire. The allocator changes damage **distribution** and
therefore enemy attrition timing — it must **not** change total friendly damage merely because capacity
changed.

**Required tests:** capacity 1 never yields two simultaneous targets · capacity N never exceeds N ·
multiple ships may share one target · removing a target reassigns deterministically · identical ticks
produce identical assignments · **ship iteration order cannot change the selected set** · capacity
cannot exceed six · **missing progression data fails explicitly rather than granting capacity six.**

## Prerequisite — progression integrity, before activation

Do **not** activate capacity progression while the captain cap has three competing interpretations or
while a live writer can produce an uncapped functional level. The curve exists in three places and
**the live writer is uncapped**:

- `20260618000340:1625` — capped at 99 (the resolver)
- `20260618000177_captain_xp_foundation.sql:268-270` — **the live writer, UNCAPPED**
- `src/features/captains/captainProgress.ts:29` — the client mirror

0340 only *audits* the disagreement; that audit starts failing at **960,400 XP**.

A bounded progression-integrity slice must first: keep XP stored and growing past 99 · clamp functional
level at 99 · route all stat and unlock consumers through the canonical resolver · ensure no live writer
grants a functional level above 99 · preserve existing above-cap XP · destroy or reduce no progression
data · cover exact boundaries (first XP for level 99, the cap boundary, **960,400**, and above) · retire
all three disagreeing sites onto one authority.

**Do not store target capacity as a free-standing progression result to avoid fixing the evaluator.**

## Delivery sequence

1. Finish and merge PR #396 (only after authoritative purchase proof — **done**, head `346d3800`).
2. Remaining trait/captain/module lifecycle-presentation cleanup.
3. Repair captain progression cap consistency.
4. Target-capacity schema + deterministic allocator, **dark behind a new false-seeded flag**.
5. Prove current-behaviour parity while the flag is false.
6. Disposable balance proofs for capacities 1–6.
7. Separate owner authorization before deployment.
8. Another explicit authorization before flag activation.

**Must not be combined with:** wave cadence · weapon fire rate · speed · range content · cargo · ambush
risk · rewards · port authority · combat snapshot migration.

## Interaction with wave cadence — separate slices, deliberately

They do not cancel. Wave cadence controls **how many enemies appear**; capacity controls **how many
receive simultaneous fire**. It is acceptable that capacity is invisible while a wave holds one enemy:
if waves 1–5 hold one, capacity first shows at wave 6. *"Early waves teach survival and positioning;
later waves expose command coordination."* They stay separate migrations so their effects on
survivability can be measured independently.

---

## Rejected: a player-configurable combat-speed control

The reposition mechanism already supplies the visual movement lever. Preserve the anti-kite invariant
(`20260618000316:754-762`, f7): the player **must not** be able to match or exceed closing enemies
indefinitely — its own comment records why (*"the player would hold it outside its own range forever
and take no fire at all"*). Repositioning must stay observable; close/kite balance must not change
silently; `combat_reposition_speed_scale` is **not** a general fleet-speed progression mechanism.

Measured, for the record: a combat step is ~0.2 world units/tick ≈ **0.3 px** at a typical camera. The
lever already exists on the fitting screen.

*This rejects a new control only.* The canonical stat architecture still owns ship and fleet speed
resolution wherever speed is legitimately consumed.

## Rejected: a fleet-level range slider

Range remains a property of **weapon and content choices**. The whole operating band is 1–2 world units
across the only two weapon modules in the game, and enemies close at 1.0–1.6 units/tick against the
player's 0.2 — the simulation would override any setting within a few ticks. **Do not expose a setting
that implies the player can hold a range the simulation immediately overrides.**

Future differentiation belongs in content: long-range/low-damage and short-range/high-damage weapons,
decided on the fitting screen. The effective-stat architecture must still resolve range correctly for
weapons and consumers.
