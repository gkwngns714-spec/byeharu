-- Byeharu — PIRATE INTERCEPT: RELIABLE AMBUSH ON ZONE ENTRY. Migration 0236.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE PROBLEM (owner, 2026-07-19, furious): "send a fleet into a danger zone → you visibly get jumped
-- by pirates. Right now sending a fleet to a danger zone appears to do NOTHING."
--
-- ROOT CAUSE (verified by arithmetic against the 0233 seed): the intercept roll was tuned as a RARE
-- risk, not a reliable event. The 0233 defaults were base_risk=0.35, min_risk=0.02, max_risk=0.9,
-- exposure_floor=0.15. The formula (0233 pirate_intercept_compute_risk) is
--   risk = clamp(base_risk * ref/(ref+combined), min_risk, max_risk) * clamp(exposure, floor, 1.0)
-- so even the WEAKEST fleet at FULL exposure rolled only base_risk = 0.35 (a 65% chance of NOTHING),
-- and a normal fleet (combined stats ~100, a leg that merely grazes a zone) rolled ~0.02–0.10 — i.e.
-- entering a danger zone did nothing ~90–97% of the time. That is exactly the owner's "does NOTHING".
--
-- THE FIX (owner's explicit directive: "owner expects RELIABLE combat on entry, not a rare roll — if
-- the risk formula makes ambush too rare, RAISE the floor so entering a hostile zone reliably starts a
-- fight"): raise the floor so ANY crossing of a hostile danger zone is a near-certain ambush,
-- regardless of fleet stats or how shallowly the leg clips the zone.
--   • pirate_intercept_base_risk    0.35 → 1.0   (a zero-stat fleet at full exposure = certain)
--   • pirate_intercept_min_risk     0.02 → 0.98  (even an overwhelmingly strong fleet is ~certain to
--                                                 be jumped — the floor now DOMINATES the stat falloff,
--                                                 which is the owner's call: reliability over nuance)
--   • pirate_intercept_max_risk     0.90 → 1.0   (ceiling lifted so the floor is reachable)
--   • pirate_intercept_exposure_floor 0.15 → 1.0 (even a razor-thin graze carries FULL risk — "enter =
--                                                 fight", not "graze safely")
-- Net: every danger-zone crossing now rolls risk ∈ [0.98, 1.0]. A ~2% escape is retained deliberately
-- ("there is ALWAYS a risk", the owner's own earlier words) — but entry is now RELIABLY a fight.
--
-- pirate_intercept_stat_reference is left at 120 (inert now that the floor dominates, but harmless and
-- retained so the stat-scaling shape survives if a future retune lowers the floor again).
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THIS IS SAFE / NOT SPAGHETTI:
--   • ONE AUTHORITY: this touches ONLY the four game_config tuning rows the 0233 risk leaf already
--     reads via cfg_num — it re-creates NO function, adds NO column, forks NO code path. The risk
--     formula (pirate_intercept_compute_risk, 0233) is untouched; only its inputs move.
--   • NOT dark-gated on purpose: the whole intercept feature is already governed by ONE flag,
--     pirate_intercept_enabled (0233). While that flag is off the risk knobs are never read, so this
--     migration is inert on a dark deploy and only takes effect where the owner has already lit the
--     feature. Raising a live balance tunable is not a new capability — it needs no second flag.
--   • Forward-only: 0001–0235 unedited. Idempotent (plain UPDATEs by key; a re-apply is a no-op once
--     the values are in place). The rows are guaranteed to exist (0233 seeded them).
--
-- SEPARATELY (reported to the coordinator, NOT flipped here — the owner owns the final flag flip):
-- for the ambush to be VISIBLE AS ON-MAP SPATIAL COMBAT (ship dots + pirate triangles + fire lines on
-- the galaxy map, the S4 spatialCombatLayer), spatial_combat_enabled (0234) must be lit BEFORE the
-- encounter opens — the 0234 null-pos fallback means an encounter created while dark never spatialises.
-- With spatial dark the ambush still FIGHTS (the aggregate combat path + ActiveCombatPanel), it just is
-- not drawn on the map. That flag is a runtime game_config value, deliberately left to the owner.

update public.game_config set value = '1.0'::jsonb,  updated_at = now() where key = 'pirate_intercept_base_risk';
update public.game_config set value = '0.98'::jsonb, updated_at = now() where key = 'pirate_intercept_min_risk';
update public.game_config set value = '1.0'::jsonb,  updated_at = now() where key = 'pirate_intercept_max_risk';
update public.game_config set value = '1.0'::jsonb,  updated_at = now() where key = 'pirate_intercept_exposure_floor';

-- ── self-assert (real-apply proof): the four knobs now read the reliable-ambush values, AND the risk
--    leaf composes them to a near-certain roll for a representative crossing. Runs at apply time inside
--    the disposable-DB chain (the CI apply-proof net) and on the real deploy. Vacuity-proof: it asserts
--    concrete numbers the UPDATEs above must have produced.
do $pi236$
declare
  v_base  double precision := public.cfg_num('pirate_intercept_base_risk');
  v_min   double precision := public.cfg_num('pirate_intercept_min_risk');
  v_max   double precision := public.cfg_num('pirate_intercept_max_risk');
  v_floor double precision := public.cfg_num('pirate_intercept_exposure_floor');
  -- a strong fleet (combined=300) grazing a zone (exposure 0.05, well below the new floor) — the
  -- pre-fix worst case that used to roll ~0.02. Must now be >= 0.9 (reliable).
  v_strong_graze double precision := public.pirate_intercept_compute_risk(300, 0.05);
  -- a weak fleet at full exposure — must be effectively certain.
  v_weak_full    double precision := public.pirate_intercept_compute_risk(0, 1.0);
begin
  if v_base is distinct from 1.0 or v_min is distinct from 0.98 or v_max is distinct from 1.0 or v_floor is distinct from 1.0 then
    raise exception 'PIRATE-INTERCEPT 0236: risk knobs did not take (base=% min=% max=% floor=% — want 1.0/0.98/1.0/1.0)',
      v_base, v_min, v_max, v_floor;
  end if;
  if v_strong_graze < 0.9 then
    raise exception 'PIRATE-INTERCEPT 0236: a strong fleet grazing a zone still rolls only % (want >= 0.9 — the fix did not make ambush reliable)', v_strong_graze;
  end if;
  if v_weak_full < 0.98 then
    raise exception 'PIRATE-INTERCEPT 0236: a weak fleet at full exposure rolls only % (want >= 0.98 — near-certain)', v_weak_full;
  end if;
  raise notice 'PIRATE-INTERCEPT 0236: reliable ambush armed — strong-graze risk=%, weak-full risk=% (both >= the reliable floor)', v_strong_graze, v_weak_full;
end $pi236$;
