# Activation Guide — the dark-system flip scripts

This file documents the owner-run activation scripts under `scripts/activate-*.{sql,sh}`. Each one
flips an already-built, already-deployed **dark** system live. They are **human tools** — never CI,
nothing flips at build/deploy time; each run is the recorded human go decision. Every `[D]` number
below is **OWNER-TUNABLE** — edit the value in the `.sql` before running.

Every script is one all-or-nothing `begin … commit` transaction, precondition-guarded (running it on
an unready substrate RAISES, never corrupts), with a commented rollback and a green `.sh selftest`.
Run one with either:

```
bash scripts/activate-<name>.sh run ACTIVATE_<NAME>     # DB_URL required
# or paste scripts/activate-<name>.sql into the Supabase Dashboard SQL editor (meta-command-free)
```

## ACT-readiness: the five new activation scripts

| Script | Flips | `[D]` OWNER-TUNABLE defaults | Migrations | Hard preconditions |
|---|---|---|---|---|
| `activate-shield` | regenerating shields (data-gated, no flag) | hull `base_shield`: Sparrow/`starter_frigate` **100**, Mule/`bulk_hauler` **130**, Talon/`strike_corvette` **85**; `shield_regen_combat_pct` **0.02**; `shield_regen_idle_pct` **0.10** | 0191/0195/0197 | knobs currently `0` (first-flip) |
| `activate-soul` | ship traits `ship_traits_enabled → true` + backfill | backfill = **YES** | 0186/0193 | catalog **frozen at 8**; flag `false` |
| `activate-salvage` | `salvage_market_enabled → true` | accept the seeded 0174 price table (do **not** re-seed) | 0174 | seeded 3×5 demand rows intact |
| `activate-decks3` | `station_affinity_bonus → 0.15` | **0.15** | 0196 | **captains committed lit**; knob `0` |
| `activate-shipyard` | `shipyard_enabled → true` + `blueprint_fragment_drop_rate → 0.15` | **0.15** faucet | 0185/0188/0194 | **mining committed lit**; every ingredient faucet live; 0194 cancel-refund present; flag/faucet dark |

### Per-script detail

- **activate-shield** — the only DATA-flip activator (shields are data-gated, not flag-gated).
  Stage 1 seeds each hull's `base_shield` **monotonically** (only ever raises). Stage 2 runs the
  **monotonic instance backfill** (the deferred-bump idiom, the 0171 never-lower posture):
  `shield = max_shield = base_shield` for every ship whose `max_shield` is *below* its hull value —
  a ship already at/above (e.g. a shield damaged after a prior flip) is untouched, so a re-run never
  resets a damaged pool. Stage 3 sets both regen knobs. Preconditions prosrc-pin the 0191 leaf (both
  clamps), the 0195 tick's ONE absorb point, and the 0197 reconciler's idle-regen statement. **Note:
  shields matter in combat — pair with hunting.**
- **activate-soul** — flag flip BEFORE the backfill (the roll writer gate-rejects while dark; the
  same txn sees the flip). The **ACT-SOUL catalog-freeze precondition** (`ship_trait_types` = 8) is
  load-bearing: a ship's two traits are a deterministic function of its id indexed into the catalog
  size+order, so a grown catalog would change every unrolled ship's derivation. Backfill calls
  `soul_roll_traits_for_ship` for every soul-less ship (idempotent — on-conflict-do-nothing).
- **activate-salvage** — flag flip + a zero-write gate probe (the sell RPC advances past the gate to
  `ship_not_found` for a no-ship subject). The 0174 price table is accepted as seeded (referenced,
  never re-seeded). The SALVAGE-2 UI (#128) already mounts off the flag. **Sells combat loot — pair
  with hunting.**
- **activate-decks3** — sets the station-affinity bonus knob. **HARD-gated on captains**
  (`captain_assignment_enabled` committed true), exactly as ACT-HAUL hard-gates on trade: the bonus
  scales a captain's contribution and is a dead knob while captains are dark.
- **activate-shipyard** — **THE BUILD-LOOP UNLOCK** (the #1 audit gap). Flips `shipyard_enabled` AND
  opens the blueprint faucet. **HARD-gated on mining** (ore/crystal), verifies **SHIPYARD-2's
  hull-aware cancel refund (0194)** is in place (the 0188 pre-flip requirement — else a cancel would
  eat a build's ingredients), and runs a **per-ingredient reachability check** that RAISES if any
  recipe ingredient has no live faucet.

## Flip order / dependency notes

- **captains before decks3** — `activate-decks3` hard-RAISES unless `captain_assignment_enabled` is
  committed true (no captain staffs a station to match otherwise).
- **mining + combat before shipyard** — `activate-shipyard` hard-RAISES unless `mining_enabled` is
  committed true (the ore/crystal faucet), and it verifies each combat ingredient
  (scrap/pirate_alloy/weapon_parts/engine_parts/blueprint_fragment) is sourced by the combat loot
  faucet. Combat is inherently live (the tick cron); the blueprint faucet is what this script opens.
- **shields + salvage pair with combat** — both are combat-coupled: shields buy survivability in the
  hunt; salvage is the economy exit for combat loot. Flip them alongside the hunting loop.

## Shipyard build-loop reachability finding

**Opening the faucet DOES make both T1 hulls buildable — there is NO missing ingredient faucet.**
The T1 recipes consume seven distinct items; every one has a live faucet once mining is lit and the
blueprint faucet is opened:

| Ingredient | Recipes | Faucet |
|---|---|---|
| `ore` | bulk_hauler 24, strike_corvette 16 | mining fields (all 5) — needs `mining_enabled` |
| `crystal` | bulk_hauler 6, strike_corvette 4 | mining fields (3 of 5) — needs `mining_enabled` |
| `scrap` | bulk_hauler 12 | combat loot, wave ≥ 1 |
| `pirate_alloy` | strike_corvette 8 | combat loot, wave ≥ 3 |
| `weapon_parts` | strike_corvette 6 | combat loot, wave ≥ 5 |
| `engine_parts` | bulk_hauler 6 | combat loot, wave ≥ 8 |
| `blueprint_fragment` | both ×2 | the w ≥ 8 combat faucet **this script opens** (0 → 0.15) + the 0098 exploration one-shot |

The `blueprint_fragment` gate was the closed valve: with the faucet at rate 0 the fragment was
unobtainable, so both recipes were unbuildable. Raising `blueprint_fragment_drop_rate` to 0.15 makes
deep-wave (≥ 8) combat grinding yield the ×2 fragments each recipe needs. The build loop is then
fully server-side (enqueue → 30s-cron promote → `build_seconds` timer → commission delivery at Haven
Reach). A build-order **UI** is SHIPYARD-3's concern (not built by this scripts-only slice).

## Re-run semantics

- `activate-salvage` is a safe re-run no-op (idempotent flag upsert; value not asserted).
- `activate-shield` / `activate-soul` / `activate-decks3` / `activate-shipyard` are **first-flip**
  tools: their knob/flag preconditions require the dark seed, so a verbatim re-run after success
  RAISES by design (it refuses to silently re-clobber a later deliberate retune). The shield/soul
  **data** stages are monotonic + idempotent on their own regardless.
