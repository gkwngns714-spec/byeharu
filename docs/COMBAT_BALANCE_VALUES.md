# Combat balance values — MEASURED, with the reasoning and the falsification test for each

**Status: decided 2026-08-08. Every number below is either measured on production or argued from a
measurement. None is invented.** Companion to `COMBAT_OWNER_DIRECTIVES_CONTRACT.md`, which holds the
architecture; this file holds the numbers that architecture needs.

Second opinion consulted (the owner's ChatGPT byeharu project) with the real source pasted, not a prose
summary. It declined to give values until measurements existed, which is why this file exists.

---

## §1 The measurements that constrain everything

Queried read-only against production 2026-08-08.

| fact | value | why it matters |
|---|---|---|
| `combat_tick_seconds` | **3** | every duration is quantised to 3 s; a 1.5 s value is indistinguishable from zero |
| every fitted weapon `cooldown_seconds` | **2**, both sides, no exceptions (91 player rows, 115 enemy) | **2 < 3, so the cooldown gate at live `pct.sql:770-771` can NEVER deny a shot.** Every weapon fires every tick. This is the mechanical cause of the owner's *"it just attacks every fleet simultaneously"* — there is no timing mechanism in the fight at all |
| player weapon range | 150 → 25 → **5** (35 rows, current) | rescaled over time; only the newest rows are the live scale |
| enemy weapon range | 170/195/180 → 20 → **4** (39 rows, current) | player outranges enemy by exactly 1 |
| zone spans | 29–79 world units | so range 5 is a knife fight, and the old 150 was effectively unlimited |
| measured engagement distances | 3.20, 3.50, 3.54, 3.91 near hulls; 4 enemies at 5.06–6.86 | the real geometry of a fight |
| weapons per player hull | **0 → 47 hulls · 1 → 85 hulls · 3 → 2 hulls** | D5 is observable (the 3-weapon hulls); 47 hulls cannot shoot at all |
| enemy hulls | 115 rows, `hp_max` 104.6–368.8, mean 157.3 | `hp_max` does **not** correlate with `danger_level` (danger 1 → avg 217; danger 5 → 104.6) |
| encounter ledger, all time | 44: **24 escaped, 19 defeat, 0 completed** | avg ~130 s, longest 398 s |
| player chase speed | 0.2 units/tick | committed reposition ≈ 1.6/tick; enemies close at 1.0–1.6 |

**Speeds are NOT changed by this programme.** A recorded owner law forbids the player matching pirate
closing speed (past roughly half of it the kite becomes unbreakable and pirates stop landing shots).

---

## §2 Lock duration — `lock_ticks = 1` (3 s), FLAT

**Not derived from weapon range.** Range has been rescaled from ~150 to 5; any `f(range)` formula would
encode a historical accident as a game rule. If weapon classes should later differ, make `lock_ticks`
**explicit per weapon profile** (light 1, heavy 2) — never computed from range.

**Why 1 tick and not 2:** 6 s of dead time is too punishing for the **85 one-weapon hulls**, which are
the overwhelming majority. One tick still produces a clearly observable sequence:

```
tick N     acquire target, begin lock
tick N+1   lock complete, weapon may fire
```

**What falsifies 1 tick** — instrument and measure: `lock_started` → `first_shot` per weapon; the share
of acquired locks that produce **zero** shots before the target dies or the lock invalidates; shots/min
for one-weapon hulls measured **separately** from multi-weapon hulls; time from target death to that
weapon's next shot; retreat/defeat rate against the number of effectively-firing weapons.

Raise to 2 ticks only if acquisition is still visually imperceptible. Remove the mechanic only if
one-weapon hulls become non-contributors.

---

## §3 Reinforcement cadence — FLAT per site, one body per arrival

| site | base_difficulty | cadence |
|---|---|---|
| Snare | 10 | **45 s** (15 ticks) |
| Reaver | 15 | **36 s** (12 ticks) |
| Blackden | 25 | **30 s** (10 ticks) |

**Do NOT shorten the interval as presence elapses — not in v1.** Population already accumulates. If
population growth, enemy quality drift and spawn acceleration all move at once, then when balance goes
bad you cannot tell which dimension caused it.

**The clock, exactly:**

```
encounter starts:   next_reinforcement_at = started_at + cadence
on arrival:         if population < cap  -> spawn exactly 1
                    else                 -> spawn NOTHING
                    next_reinforcement_at += cadence
```

**Never:** `enemy dies → population slot frees → spawn replacement`. And **do not queue missed
reinforcements** — a suppressed arrival is lost, not banked. *That distinction is the executable form of
D3*: no arrow from enemy death back into pressure.

Against the ~130 s historical average fight, this puts real pressure development inside the window a
fight actually occupies.

**What falsifies these:** encounter duration; time spent at each concurrent enemy count; reinforcement
arrivals actually seen before retreat/defeat; enemy population at disengagement; damage received per
30 s bucket; kills per interval; **share of scheduled reinforcements suppressed by the cap**; reward per
minute by site. The strongest signal is the **population trajectory**. Do not tune cadence on win rate —
there is deliberately no win.

---

## §4 Concurrent population cap — per site, 3 / 4 / 6

| site | cap | reaches cap at |
|---|---|---|
| Snare | **3** | ~90 s |
| Reaver | **4** | ~108 s |
| Blackden | **6** | ~150 s |

Blackden keeps today's ceiling of 6. Do **not** expose six bodies at the easiest site.

**Store the caps as actual data rows. Do NOT compute `cap = round(base_difficulty / N)`** — that would
make `base_difficulty` yet another overloaded authority, which is the disease this whole programme is
removing. This gives difficulty 10/15/25 an observable content consequence without deriving anything.

**What falsifies 3/4/6**, per site: max concurrent enemies; seconds spent at cap; incoming damage/tick at
each population size; player HP at retreat; defeat rate; manual vs threshold retreat; kills/min; weapon–
target saturation. Specifically graph **concurrent enemies → incoming damage per 30 s**: if 3→4 or 4→6 is
a discontinuous jump rather than a smooth increase, the cap is wrong. Lower a site's cap if players spend
a large fraction of encounters pinned at it.

---

## §5 Cooldown becomes a real stat — 2 s → **6 s** (2 ticks), BOTH sides

Leaving cooldown inert would make the lock the only gate, and the behaviour would degrade to
**"lock once, then fire every tick forever"** — still no firing rhythm.

Lock and cooldown answer different questions and both are needed:

- **lock** — *how long before this weapon can engage this target?*
- **cooldown** — *how often can it attack once it has the target?*

**6 s, not 4 or 5** — under a 3 s scheduler those all collapse to the same two-tick behaviour. Resulting
baseline: 3 s acquisition latency, then one shot per 6 s.

```
t=0 acquire · t=3 first shot · t=6 not ready · t=9 second shot · t=12 no shot · t=15 third shot
```

This cuts theoretical sustained fire from **20 → 10 shots/min/weapon**. That is a large balance change, so
it applies to **player and enemy alike** — symmetric, so it does not tilt the fight.

**Required instrumentation — record the REASON a ready weapon did not fire:** `LOCK` · `COOLDOWN` ·
`RANGE` · `NO_TARGET`. Cooldown must appear meaningfully in that data after the change; if it never does,
6 s was pointless. If cooldown dominates inactive time and fights become mostly waiting, come back down.
Under a 3 s tick the only real alternatives are 3 s (every tick), 6 s (every 2), 9 s (every 3).

---

## §6 The 47 unarmed hulls — OUT OF SCOPE, but instrumented

**Do not auto-equip them. Do not silently exclude them from combat. Do not give them zero-damage
weapons.** First establish which they are: an intentional tank/support/transport, an incomplete fitting,
legacy content from before weapons were required, or a player configuration mistake. **Those are
different product rulings**, and folding the cleanup into lock/cooldown/reinforcement work would poison
the before/after comparison this programme depends on.

Instrument them here: every encounter should expose player hull count alongside the count of hulls that
actually carry a weapon.

---

## §7 What this programme does NOT change

- **No victory condition.** The owner's core law is already in the deployed engine at `pct.sql:968-971`:
  *"the whole point of this game is never to win, but exit appropriately… "* — waves are endless BY
  DESIGN; the skill is leaving in time. **0 wins in 44 encounters is the design working, not a defect.**
  A victory slice was designed and then deleted on this evidence.
- **No speed changes** (§1).
- **No feature flags.** The owner's ruling: *"don't make anything dark, make it so that i can check."*
