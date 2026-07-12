# Byeharu — Team-Command Activation Decision Packet (PROPOSALS — NOTHING FLIPPED)

> **DECISION PACKET — NO ACTIVATION AUTHORIZATION.** This document supports the human activation
> decisions for the team-command system (`docs/TEAM_COMMAND.md` → ACTIVATION CHECKLIST). It flips
> no flag, runs no migration, and changes no code. Every number below is read from the shipped
> migrations/code (anchors given); nothing is invented. The recommendations are proposals; each
> flip remains its own recorded human go/no-go.

**Live baseline (verified):** `main` @ `9a292ed`, prod migration head **`20260618000169`**, zero
open PRs. Team command A → D4 fully built and DARK (`team_command_enabled=false`,
`TEAM_COMMAND_ENABLED=false`). Pre-activation blockers: **all closed** (M1 fixed in 0169).

---

## 0. Grounding — the combat formulas and stat sources as shipped

### 0.1 The enemy math (`process_combat_ticks` — head 0046; re-created with provably-inert parity deltas in 0167/0169)

| Quantity | Formula | Config values (prod) |
| --- | --- | --- |
| danger level | `1 + waves_cleared + floor(secs_inside / 180)` (0046:201) | `danger_time_divisor_seconds=180` (0030:12) |
| wave HP at spawn | `base_difficulty × enemy_hp_base × (1 + danger × enemy_hp_danger_scale) × variance` (0046:220-221) | `enemy_hp_base=14` (seeded 6 in 0023:14, raised 0027:6); `enemy_hp_danger_scale=0.6` (0023:15) |
| enemy attack / tick | `base_difficulty × enemy_attack_base × (1 + danger × enemy_attack_danger_scale)` (0046:203-204) | `enemy_attack_base=1.0` (0023:16); `enemy_attack_danger_scale=0.25` (0023:17) |
| damage the player takes / tick | `enemy_attack × def_base / (def_base + Σdefense) × variance` (0046:253) | `defense_curve_base=100` (0030:14); `combat_damage_variance_pct=0.10` (0030:13) |
| player damage dealt / tick | `Σattack × variance` (0046:235) | — |
| pacing | tick **3 s** (0026:5), wave transition 3 s (0023:18), retreat delay **8 s** (0028:5), forced extract **1800 s** (0020:8) |
| reward / cleared wave | `round(10 × reward_tier × (1 + 0.25 × danger))` metal (0046:289-290; `reward_metal_base=10` 0020:9, `reward_danger_scale=0.25` 0030:11) + loot items (0041: scrap w≥1, pirate_alloy w≥3, weapon_parts w≥5, engine_parts w≥8, repair_parts w≥10) |

For a **team encounter** (D1/D2): `Σattack = Σ member attack_snapshot := combat_power`,
`Σdefense = Σ member defense_snapshot := survival`, hp pool = Σ member **real current** hp
(0168:403-406; 0167 coalesce-first reads). One member = one `combat_units` row, `alive_count=1`.

### 0.2 The seeded hunt zones (0002:151-162; renamed 0148, relocated 0154)

| Zone (today's name) | base_difficulty | reward_tier | min_power_required | wave-1 HP (mean) | enemy dmg/tick @ danger 1 |
| --- | --- | --- | --- | --- | --- |
| **Snare** (Wreck Belt) | 10 | 1 | **0** | 224 | 12.5 |
| **Reaver** (Wreck Belt) | 15 | 2 | **0** | 336 | 18.8 |
| **Blackden** (Ion Storm Route) | 25 | 3 | **0** | 560 | 31.3 |

### 0.3 What a member ship actually brings (`calculate_expedition_stats` — head 0122)

- **Hull (`starter_frigate`, 0043:38-40): hp 500, speed 1.0, cargo 50 — and ZERO combat stats.**
  The adapter never reads `main_ship_hull_types.base_stats_json` (0122 reads only `base_speed`,
  :116); `combat_power`/`survival` come exclusively from the accumulator loops (0122:274-275).
- **Support craft never contribute to a team hunt** — both D2 adapter calls pin the loadout to
  `'[]'::jsonb` (0168:249, 0168:404); support craft are also the ONLY catalog carrying a
  `defense` stat (0042).
- **Modules** (0107 seed + 0111:84-99): `autocannon_battery` **attack 10**, slot 1 — the only
  attack module. 3 module slots per ship (0043) → max **+30 attack**. No module has `defense`.
- **Captains** (0117:101-116): `gunnery_veteran` **attack 4** — the only attack captain.
  2 slots today → **+8**; 6 slots after the deferred bump → **+24**. No captain has `defense`.

**Per-ship `combat_power` therefore:** bare **0** · modules-only **30** · modules + 2 captains
**38** · modules + 6 captains **54**. **`survival` = 0 in every configuration** → the defense
curve is pinned at `100/(100+0) = 1.0` (full enemy damage, the mitigation knob degenerate).

---

## 1. Decision 1 — enemy scaling vs team power

### 1.1 Computed balance table (mean variance; ships at full 500 hp; "kit" = 3 autocannons + 2 gunnery veterans = 38 attack/ship; simulated tick-for-tick against §0.1)

"Waves / metal" = cleared before the hp pool is exhausted fighting to defeat — the farm ceiling; a
disciplined retreat ~1–2 waves earlier keeps everything (retreat locks rewards, then 8 s of
incoming damage while dealing none — 0022/0046:169-171,244-246).

| Zone | Team | Wave-1 clear | Wave-1 damage taken | Farm ceiling (waves / metal / run time) |
| --- | --- | --- | --- | --- |
| **Snare** (bd 10) | solo kit (38) | 6 ticks / 18 s | 75 hp (15% of pool) | 3 w / 46 metal / 1.7 min |
| | 2-ship (76) | 3 ticks / 9 s | 38 hp (3.8%) | 6 w / 114 / 2.6 min |
| | 4-ship (152) | 2 ticks / 6 s | 25 hp (1.3%) | 12 w / 323 / 3.9 min |
| | 6-ship (228) | **1 tick** / 3 s | 13 hp (0.4%) | 17 w / 567 / 4.8 min |
| **Reaver** (bd 15) | solo kit | 9 ticks / 27 s | 169 hp (34%) | 2 w / 55 / 1.3 min |
| | 2-ship | 5 ticks / 15 s | 94 hp (9.4%) | 4 w / 130 / 2.1 min |
| | 4-ship | 3 ticks / 9 s | 56 hp (2.8%) | 8 w / 340 / 3.1 min |
| | 6-ship | 2 ticks / 6 s | 38 hp (1.3%) | 12 w / 640 / 3.9 min |
| **Blackden** (bd 25) | solo kit | 15 ticks / 45 s | **469 hp (94%)** — near-death on wave 1 | 1 w / 38 / 0.8 min |
| | 2-ship | 8 ticks / 24 s | 250 hp (25%) | 2 w / 83 / 1.4 min |
| | 4-ship | 4 ticks / 12 s | 125 hp (6.3%) | 5 w / 264 / 2.4 min |
| | 6-ship | 3 ticks / 9 s | 94 hp (3.1%) | 8 w / 512 / 3.0 min |
| (6-ship, 6 captain slots = 54/ship, 324) | Snare / Reaver / Blackden | 1 / 1 / 2 ticks | ~0.4 / 0.4 / 2.1% | 19 w · 680 / 14 w · 815 / 9 w · 610 |

**Reading:** the zones do NOT trivialize long-run — `danger = 1 + waves_cleared` grows without
bound, so wave HP (+0.6/level) and enemy damage (+0.25/level) always outrun a fixed team; a
bigger team just farms deeper before the retreat point. The ladder is actually coherent:
Snare is solo-able, Reaver wants 2+, **Blackden genuinely requires ~4+ kitted ships** (a solo
kitted ship nearly dies clearing wave 1). "Trivialize" happens only at wave-1 one-shot scale:
6 kitted ships one-shot Snare's wave 1 (228 ≥ 224) but never Reaver's (336) or Blackden's (560).

### 1.2 Findings the difficulty decision actually hinges on

1. **F1 — a bare team deals ZERO damage.** Hull `combat_power` is 0 (§0.3): with modules and
   captains dark, `Σattack = 0` — a team can never clear wave 1 anywhere and just bleeds to
   defeat (a bare 6-ship team at Snare dies in ~9.8 min with 0 waves, 0 metal). **Team combat is
   unshippable without at least one lit damage source.**
2. **F2 — `survival` is structurally 0** (no defense stat exists outside support craft, which are
   pinned out of team hunts) — the defense curve (0046:253) is dead weight.
3. **F3 — the D2 power gate never gates:** all three zones seed `min_power_required = 0`
   (0002:156-159; gate at 0168:259-262).
4. **F4 — loot bootstrap is circular for NEW players:** the only attack module's recipe is
   `weapon_parts 4 + pirate_alloy 2 + scrap 6` (0107:118-120) — all pirate-combat loot (0041,
   waves ≥5/≥3/≥1) — and the legacy unit-fleet hunt UI no longer exists in `src/` (no
   `send_fleet_to_location` caller), so **team hunts are the only player combat surface at
   activation**. Veteran players hold M4-era inventory; a new player can never craft their first
   weapon.
5. **F5 — captains are soft-blocked even when lit:** every recruit recipe needs 1
   `captain_memory_shard` (0125:64-79) and **no loot table, exploration bundle, or mining yield
   drops it** (grep: seeded in 0039:36, consumed in 0125, produced nowhere).

### 1.3 Options

- **A — no formula change.** Keep the curve; accept that 6-ship teams one-shot Snare's wave 1 and
  that deeper zones arrive later as content. Zero risk; per §1.1 the ladder already
  differentiates team sizes.
- **B — a wrap-don't-widen config knob scaling enemies vs `player_power_start`.** A parity-shaped
  re-create of `process_combat_ticks` (the D1 discipline) reading two NEW cfg keys, defaults
  making it byte-inert (e.g. `enemy_team_scale=0` → factor
  `1 + enemy_team_scale × greatest(0, player_power_start/power_baseline − 1)` multiplying wave
  HP/attack). One engine, one knob, tunable without redeploy. Defer the values.
- **C — new higher-difficulty seed locations for teams.** Additive `locations` seed (bd 40–60,
  reward_tier 4–5) with **`min_power_required > 0`** (e.g. 150 ≈ 4 kitted / 3 bumped-captain
  ships) so the D2 gate finally does its job (F3). Pure data; no engine change.

### 1.4 Recommendation

**A now, C at the first content expansion, B held in reserve — but fix the stat sources, which is
the real gap:**

1. **Seed hull base combat stats** via one parity-shaped adapter delta: `calculate_expedition_stats`
   re-created with `a_combat/a_survival += coalesce((hull.base_stats_json->>'attack'/'defense')::numeric, 0)`
   — byte-inert while every hull's `base_stats_json` is `'{}'` (0043 default) — then a data update
   `starter_frigate → {"attack": 15, "defense": 10}`. This kills F1/F2/F4 in one move (a bare solo
   ship clears ~2 Snare waves → scrap → first autocannon; kitted becomes 53/ship) and gives the
   defense curve a live input. No live behavior changes: the only combat consumer of the adapter
   is the dark team path (the live single send rejects combat destinations, 0050:104).
2. **Light `module_crafting_enabled` + `module_fitting_enabled` with team command** — modules are
   the designed mid-game damage source (F1) and their recipes are exactly what hunt loot drops.
3. **Add a `captain_memory_shard` drop** (e.g. `pirate_loot_for_wave` at wave ≥ 6, or the epic
   exploration bundle) in the same window captains are lit (F5).
4. Leave the enemy formulas untouched (A); any later tuning goes through B's knob shape — never a
   second engine.

---

## 2. Decision 2 — `mainship_additional_commission_enabled` + the ship price

**Facts.** Additional ships cost `main_ship_price` = **1000 credits** — a tunable game_config knob,
first ship free (0091:21-27, fallback 1000 at 0091:67-69). While trade is dark, the ONLY credit
source is the one-time wallet seed `starting_credits` = **1000** (0093:23; seeded once on first
wallet creation — raising it later does NOT top up existing wallets). Combat rewards are metal +
items, never credits (0030/0040); every other `wallet_credit` caller is dark trade
(0090/0092/0095/0136/0138). **So at today's numbers a player can afford exactly ONE additional
ship — 2-ship teams, ever, with a 0-credit wallet after.**

**Recommendation: YES — flip it at team launch.** One-ship teams are inert: the entire A → D4
surface (roster, group send, ONE-fleet hunts, folding stats) exists to command N ships; per §1.1
the difficulty ladder only differentiates at N ≥ 2, and Blackden needs ~4. Launching team command
without commissioning would ship a teams UI that can never contain a team.

**Price:** drop `main_ship_price` **1000 → 250** at flip time (one `set_game_config` write — the
knob is exactly for this, 0091:8-10). Seed capital then buys a 5-ship roster (1 free + 4×250),
matching the 4–6-ship band the zones demand, while keeping ships a real sink. Revisit upward when
trade V1 lights and credits become earnable. Alternative (rejected for now): flip trade V1
simultaneously — a much bigger activation surface in the same window.
Remember the compile-time mirror `MAINSHIP_ADDITIONAL_ENABLED` (osnReleaseGates.ts:26) flips in
the same frontend PR as `TEAM_COMMAND_ENABLED`.

---

## 3. Decision 3 — captain slots + captains at launch

**The deferred bump (checklist item 2)** — run WITH the captain flag, idempotent + monotonic; the
exact SQL pinned in `docs/TEAM_COMMAND.md` ("Explicitly deferred"):

```sql
update public.main_ship_hull_types
   set base_captain_slots = 6 where hull_type_id = 'starter_frigate' and base_captain_slots < 6;
update public.main_ship_instances i
   set captain_slots = h.base_captain_slots, updated_at = now()
  from public.main_ship_hull_types h
 where i.hull_type_id = h.hull_type_id and i.captain_slots < h.base_captain_slots;
```

**Facts.** Captains add +4 attack each (gunnery, 0117:104): +8/ship at 2 slots, +24/ship at 6 —
a 21%→42% share of a kitted ship's power, meaningful but not gating (§1.1 works uncaptained).
Assignment is gated by `captain_assignment_enabled` (0120/0121); **recruiting** is gated by
`captain_progression_enabled` (0126:114) and is dead-ended by F5 (no memory-shard source). The
C1 captain UI is already in the roster, server-lit — it appears the moment assignment lights.
The bump is safe to run early (it is player-visible — "Captain seats 2 → 6" — but harmless) and
must NEVER be lowered after captains assign into slots 3–6: the adapter refuses over-capacity
(`captain_slots_used > captain_slots` raises — 0122:251-253), which would poison every stat
surface as `stats_invalid`.

**Recommendation: launch teams UNCAPTAINED; captains are the first fast-follow flip.**
Flip `team_command_enabled` alone first (one observable change at a time); then, in a second
window: the bump migration + `captain_assignment_enabled=true` + a memory-shard drop (and
`captain_progression_enabled` with it, or recruiting stays dead — F5). Teams fight fine meanwhile
(modules carry the damage); the C1 surface stays byte-invisible (fail-closed) until the flag.
If a single-window launch is preferred instead, the checklist already supports it — just include
the shard drop, or captains exist only by admin mint.

> **FAST-FOLLOW PREP SHIPPED 2026-07-12 (build half done; the flip stays human):** migration
> `20260618000171_captains_launch_prep` = the bump SQL above VERBATIM + the F5 shard drop —
> `pirate_loot_for_wave` (head 0041) re-created with one marked hunk: each cleared wave **≥ 2**
> rolls `random() < captain_shard_drop_rate` for exactly **1 shard** (wave 1 stays deterministic
> scrap-only so the live verify-phase5 pin never goes flaky). The knob is a NEW game_config key
> **seeded 0 → byte-inert** until the flip. `scripts/activate-captains.{sql,sh}` is the recorded
> human gate: knob → **0.15** (proposed conservative launch rate — ≈0.3 shards/solo-Snare-run,
> ≈2.4/deep-6-ship-run per §1.1's wave counts; one `set_game_config` write to retune), then BOTH
> captain flags → true, then read-only smoke. **No client PR** — all three captain surfaces are
> server-lit on `get_my_captain_instances` (verified: CaptainsPanel.tsx:83,
> RecruitCaptainPanel.tsx:82, TeamRosterPanel.tsx:144) and mount on the server envelope alone.
> Proof: `scripts/team-command-proof.sh` gained `TEAMCMD_PASS_SHARDDROP` (rate-0 byte-parity /
> rate-1 wave-2 drop / wave-1 threshold / end-to-end deposit into `player_inventory`) and now
> asserts the slot bump as migration state instead of fixturing it in-txn.

---

## 4. Decision 4 — `max_active_fleets`

**Facts.** `max_active_fleets` = **3** (seed 0003:31), LIVE, read via
`coalesce(cfg_num('max_active_fleets'), 3)` by the legacy unit send (0010/0019), the live
single-ship expedition send (0050/0152, re-created 0169), and the team hunt (0168:228-233 —
counts the player's fleets with `status in ('moving','present','returning')`). A team hunt
consumes exactly **ONE** slot regardless of size (D2's narrow bridge); each legacy expedition
send consumes one per ship.

**Reading:** 3 teams hunting simultaneously = the cap exactly consumed — zero headroom for any
solo expedition send (it would reject `fleet_limit_reached`) or a 4th anything. The cap was sized
for the single-fleet era.

**Recommendation: raise 3 → 6 at flip time** (one `set_game_config` write; reversible): 3 team
slots + 3 solo-send slots of headroom. Note it is LIVE-shared — raising it also lets a player run
more concurrent legacy sends; at 6 that is harmless (sends are self-limited by owned ships).

---

## 5. Decision 5 — deferred policies (brief)

- **Partial destruction (a zeroed member on a team WIN).** Today: a tick-killed member
  (`alive_count=0`) is NOT destroyed on escape/complete — it stays `'hunting'` at hp 0 until the
  D3 reconciler re-homes it as a zero-hp `'home'` ship (0169; exactly what D2's `hp > 0` send
  guard anticipates), revivable via `repair_main_ship` (the free instant safelock, 0052). Full
  destruction happens only on team DEFEAT (the D1 member loop). **Recommendation: KEEP
  survive-at-0.** It matches the roadmap law ("returns damaged … rather than being deleted"),
  the real repair/recovery economy is a designed future initiative (ROADMAP §Repair & Recovery),
  and destroying on a WIN punishes the winning outcome twice. Revisit with that initiative.
- **`retreat_safety` modulation.** The stat is folded into D0 totals (0166) but has NO combat
  consumer — retreat timing is the flat `retreat_delay_seconds = 8` (0028:5; 0046:118,169-171).
  **Recommendation: leave inactive at launch**; when wanted, wrap it as a config-knob modulation
  of the delay (e.g. `base × 100/(100 + retreat_safety)`) via a parity-shaped tick re-create —
  a knob, never a second engine. Not a launch gate.
- **Low-2 lock-ordering polish (D3 adversarial review).** Low severity; correctness already
  proven by the D3 pins. **Recommendation: not a gate** — fold it into the captains fast-follow
  PR (or the first post-activation maintenance slice).

---

## 6. The staged flip plan (proposed order of operations)

**Stage 0 — any time, independent:** the exploration flip (§7). Low-risk, and it starts stocking
`scan_data`/`anomaly_shard` (captain + sensor-module ingredients) before teams light.

**Stage 1 — pre-flip prep (one PR + one human-approved migration deploy, all still inert):**
1. If Decision 1.4 is accepted: the hull-stats adapter parity delta + `starter_frigate`
   `base_stats_json` update (and, if captains launch in stage 3, the memory-shard drop).
2. Config knobs via the `set_game_config` service-role pattern (`scripts/dev-mainship-flag.mjs`
   idiom): `main_ship_price` → 250, `max_active_fleets` → 6. (Both reversible one-liners;
   `main_ship_price` is unread while commissioning is gated; `max_active_fleets` is live-shared —
   see §4.)

**Stage 2 — the switch (one sitting, this order):**
1. `mainship_additional_commission_enabled` → `true` (server; commissioning opens).
2. `team_command_enabled` → `true` (server; every team RPC lights — B0/B1/B-send/B-stop/C0/D0/D2
   all reject-before-read on it).
3. Optionally (single-window variant of Decision 3): the captain-slot bump migration +
   `captain_assignment_enabled` → `true` (+ `captain_progression_enabled` for recruiting).
4. ONE frontend PR flipping `TEAM_COMMAND_ENABLED` + `MAINSHIP_ADDITIONAL_ENABLED`
   (osnReleaseGates.ts) → admin merge → Pages deploy mounts the roster/Hunt UI.

**Stage 3 — proof + smoke (checklist item 6):**
- Run `scripts/team-command-proof.sh` once against the lit environment — every `TEAMCMD_PASS_*`
  block must still pass with the real flag on.
- Manual smoke: create team → commission a ship (price debited, `insufficient_credits` on an empty
  wallet) → assign → C0 preview and D0 "Server totals" agree → hunt Snare → clear ≥ 1 wave →
  retreat → members return `'home'`, metal + loot deposited → `repair_main_ship` on a dented ship.
- Watch: `combat_ticks`/`combat_events` volume (the 0046 logging flags + `db_runtime_counts`),
  `fleet_limit_reached` / `stats_invalid` / `member_not_ready` rates, count of zero-hp `'home'`
  ships.

**Rollback story:**
- **Flags are reversible** (`set_game_config`). Flipping `team_command_enabled` off strands
  nothing: the combat cron, settle path, and D3 reconciler are not team-flag-gated (they key on
  manifest rows), so in-flight sorties finish and settle server-side; only NEW team RPC calls
  reject. The frontend gate can lag safely (server rejects are the authority).
- **The bump migration is NOT player-visibly reversible** once any captain occupies slots 3–6
  (lowering `captain_slots` below the assigned count makes the 0122 adapter raise →
  `stats_invalid` everywhere). Roll back the FLAG, never the slot counts.
- Commissioned ships persist (there is no un-commission path); the price/fleet-cap knobs revert
  with one write each.

---

## 7. Meanwhile: the exploration flip (can go first)

One server flag, no migration, no client change: `exploration_enabled` (0097) — the UI is
server-lit (`explorationApi.ts:12`, no compile-time constant; the panel renders only on a lit
envelope). Content is already seeded: 5 exploration sites (0098:99-115; metal 25–100 + item
bundles), OSN-proximity scan radius 750 (0099:76), duplicate-scan guard (0146). Rewards ride the
existing `reward_grant` path.

Checklist:
1. **Verify:** `node scripts/verify-exploration.mjs` green against prod (service-role env).
2. **Flip:** `exploration_enabled` → `true` via the `set_game_config` pattern
   (`scripts/dev-mainship-flag.mjs` idiom).
3. **Smoke:** undock, fly within 750 of a site → ExplorationPanel appears → scan → discovery +
   reward deposited; a re-scan of the same site rejects (0146). Rollback = flip the flag back
   (discoveries persist, harmless).

---

## 8. Decision ledger (to be filled by the owner)

| # | Decision | Proposal | Go/no-go |
| --- | --- | --- | --- |
| 1 | Enemy scaling vs team power | Option A (no formula change) + hull base stats `{attack 15, defense 10}` via parity adapter delta + light modules with teams; C-seeds later; B's knob in reserve | ✅ GO |
| 2 | Multi-ship commissioning | Flip at team launch; `main_ship_price` 1000 → 250 (knob) | ✅ GO |
| 3 | Captain slots / captains at launch | Launch uncaptained; fast-follow = bump SQL + `captain_assignment_enabled` (+ progression + a memory-shard drop) | ✅ GO |
| 4 | `max_active_fleets` | 3 → 6 at flip (knob, reversible) | ✅ GO |
| 5 | Deferred policies | Keep survive-at-0 on WIN; `retreat_safety` stays inactive; Low-2 polish = post-flip, not a gate | ✅ GO |
| — | Exploration (independent) | Flip first (§7) | ✅ GO |

**DECISIONS TAKEN 2026-07-12: all recommendations approved** (owner: "go with the recommendations" —
every row above as proposed). Prep shipped the same day: migration `20260618000170_team_activation_prep`
(the §1.4 hull-stats parity delta + starter_frigate seed — pre-flip it is API-visible only: the values
answer through `get_my_expedition_preview`, which no shipped UI calls today), the DARK client
commissioning slice (`CommissionShipPanel` + the ship-switcher re-gate on ShipScreen, behind
`MAINSHIP_ADDITIONAL_ENABLED` — closing the gap that `commission_additional_main_ship` had no client
caller, i.e. §2's "a teams UI that can never contain a team"), and
`scripts/activate-team-command.{sql,sh}` (the §6 staged flip, HUMAN-run: stage-1 knobs
`main_ship_price`→250 / `max_active_fleets`→6, stage-2 flags commission + team + module
crafting/fitting, stage-3 smoke asserts, marked rollback). The one-line client PR flipping
`TEAM_COMMAND_ENABLED` + `MAINSHIP_ADDITIONAL_ENABLED` then mounts the roster/Hunt UI, the
Commission-ship control, and the ship switcher. Captains remain the fast-follow window (§3); each
script run and that client-flip PR stay their own recorded human gates.

**CAPTAINS FAST-FOLLOW PREP shipped 2026-07-12** (row 3's build half, after teams went live):
migration `20260618000171_captains_launch_prep` (the §3 bump SQL verbatim + the F5
`captain_memory_shard` drop, config-gated on `captain_shard_drop_rate` seeded 0 = inert) and
`scripts/activate-captains.{sql,sh}` (the flip: knob → 0.15, `captain_assignment_enabled` +
`captain_progression_enabled` → true, smoke; selftest-green). **No client PR is needed** — every
captain surface is server-lit (§3 note). The script run remains its own recorded human gate.

*Every flip is a separate recorded human gate; the post-flip proof
(`scripts/team-command-proof.sh`) is mandatory before the activation is called done.*
