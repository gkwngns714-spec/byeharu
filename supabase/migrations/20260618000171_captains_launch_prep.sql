-- Byeharu — CAPTAINS-LAUNCH PREP: the deferred captain-slot bump (2 → 6, hull + instance backfill)
-- + the config-gated captain_memory_shard drop source. The DDL/data half of the captains
-- fast-follow window (docs/TEAM_COMMAND.md → ACTIVATION CHECKLIST item 2 / packet
-- docs/TEAM_ACTIVATION_PACKET.md §3, Decision 3 APPROVED 2026-07-12: "fast-follow = bump SQL +
-- captain_assignment_enabled (+ progression + a memory-shard drop)").
--
-- ── WHAT THIS SHIPS (both halves inert-or-cosmetic until the human flip) ─────────────────────────
--   1. THE PINNED CAPTAIN-SLOT BUMP — the exact SQL pinned in docs/TEAM_COMMAND.md ("Explicitly
--      deferred"): hull base_captain_slots 2 → 6 + the existing-instance captain_slots backfill.
--      Idempotent + monotonic (both writes are `<` guarded); columns verified against 0043
--      (main_ship_hull_types.base_captain_slots :23, main_ship_instances.captain_slots :58).
--   2. A captain_memory_shard DROP SOURCE — the packet-F5 fix ("recruiting is dead-ended without
--      a shard source": every 0125 recruit recipe needs 1 shard and nothing produced it). One
--      parity-shaped re-create of pirate_loot_for_wave (head 0041 — its ONLY create site,
--      grep-verified; NOT another process_combat_ticks re-create: the tick already injects this
--      function's output into the wave-clear reward bundle at 0169's head, so the leaf is the
--      minimal-spaghetti seam, and the packet §1.4.3 names it: "e.g. pirate_loot_for_wave").
--      CONFIG-GATED INERT: gated on the NEW game_config knob `captain_shard_drop_rate`, seeded 0 —
--      `random() < 0` is always false, so the function's output is BYTE-IDENTICAL to the 0041 head
--      for every input until the activation script raises the knob (the human's tunable).
--   3. NO FLAG FLIP — captain_assignment_enabled / captain_progression_enabled stay false; the
--      knob stays 0. Flips + the launch drop rate are scripts/activate-captains.{sql,sh} (HUMAN).
--
-- ── DROP MATH (proposed here; SCRIPT-TUNABLE, packet §3 has no pinned economy number) ────────────
--   Each cleared pirate wave FROM WAVE 2 ONWARD rolls `random() < captain_shard_drop_rate` for
--   exactly 1 shard (flat qty — the 0041 anti-explosion posture). Launch value 0.15 (set by the
--   activation script, adjustable any time with one set_game_config write):
--     · solo kitted ship, Snare (3-wave farm ceiling, packet §1.1) → 2 rolls ≈ 0.3 shards/run;
--     · 6-ship team farming deep (17 waves)                      → 16 rolls ≈ 2.4 shards/run.
--   Each recruit costs exactly 1 shard (0125). WHY WAVE >= 2: wave 1's loot stays deterministic
--   scrap-only at ANY rate — scripts/verify-phase5.mjs pins `wave 1 → scrap only` exactly, and a
--   probabilistic wave-1 drop would make that live verifier flaky post-flip. Shards ride the
--   existing bundle path unchanged: wave clear → reward_delta/total_rewards_json (0041/0046/0169)
--   → carried home → reward_grant → player_inventory (captain_memory_shard is a 0039-seeded
--   item_types row, 0039:36) — forfeited on defeat, secured on arrival, like every other drop.
--
-- ── THE PARITY DISCIPLINE (the D1/D3/0170 re-create law, applied to the 0041 leaf) ───────────────
--   pirate_loot_for_wave is copied VERBATIM from its TRUE head — migration 0041 (grep-verified:
--   0041 is the only `create ... function public.pirate_loot_for_wave` site; 0046/0167/0169 only
--   CALL it). Exactly TWO deltas, both marked `-- CAPTAINS-LAUNCH (0171):`:
--     · the ONE body hunk (the config-gated shard append, added lines only, appended AFTER every
--       legacy element so the rate-0 output is byte-identical INCLUDING element order), and
--     · `immutable` → `volatile` in the header — forced, not stylistic: the hunk reads
--       game_config (a table) and calls random(), both illegal under immutable. plpgsql call
--       sites (the tick's per-clear invocation) evaluate per call either way, so no caller's
--       behavior changes. The 0041 header's "deterministic (no RNG)" law now holds at the knob's
--       ENDPOINTS (rate 0 → never, rate 1 → always) — exactly what the proof pins.
--   Verified by extracting both bodies and diffing (the 0170 procedure): the diff is the one
--   marked hunk + the volatility keyword, nothing else.
--
-- ── LIVE-SURFACE HONESTY (what a player sees when this DEPLOYS, before the flag flip) ────────────
--   The slot bump is PLAYER-VISIBLE ON DEPLOY: ShipStatusCard.tsx renders "Captain seats"
--   UNGATED today (hull.base_captain_slots in the no-ship teaser :100, ship.captain_slots :219),
--   so the label moves 2 → 6 in the deploy → flip window, BEFORE captains light. This is the
--   packet's accepted posture (§3: "The bump is safe to run early (it is player-visible —
--   'Captain seats 2 → 6' — but harmless)"): while assignment is dark no captain can occupy a
--   seat, so the count is purely cosmetic. The checklist wants bump + flags "together" — this
--   migration + scripts/activate-captains.sql ARE that one window; deploy them in the same
--   sitting to keep the cosmetic gap short. IRREVERSIBILITY LAW (packet §3/§6): once captains
--   occupy slots 3–6 the counts must NEVER be lowered — the 0122 adapter refuses over-capacity,
--   which would poison every stat surface as stats_invalid. Roll back FLAGS, never slots.
--   The shard drop is invisible pre-flip: rate 0 → byte-identical loot.
--
-- Forward-only: 0001–0170 unedited.

-- ── 1) THE PINNED BUMP — verbatim from docs/TEAM_COMMAND.md "Explicitly deferred" (idempotent,
--       monotonic; run-with-the-captain-flag per checklist item 2 — see the window note above) ────
update public.main_ship_hull_types
   set base_captain_slots = 6 where hull_type_id = 'starter_frigate' and base_captain_slots < 6;
update public.main_ship_instances i
   set captain_slots = h.base_captain_slots, updated_at = now()
  from public.main_ship_hull_types h
 where i.hull_type_id = h.hull_type_id and i.captain_slots < h.base_captain_slots;

-- ── 2) the shard-drop knob — seeded 0 (INERT; the activation script raises it) ───────────────────
insert into public.game_config (key, value, description) values
  ('captain_shard_drop_rate', '0',
   'CAPTAINS-LAUNCH (0171): probability (0..1) that a cleared pirate wave (wave >= 2 only — wave 1 '
   'stays deterministic scrap-only) drops exactly 1 captain_memory_shard into the combat reward '
   'bundle (pirate_loot_for_wave). 0 = OFF (byte-identical legacy loot). Raised by the human '
   'captains activation script (scripts/activate-captains.sql, launch 0.15); tunable any time via '
   'set_game_config.')
on conflict (key) do nothing;

-- ── 3) pirate_loot_for_wave — 0041 head re-created with the marked shard-drop delta ──────────────
-- Copied verbatim from 0041:26-46 (its only create site). Deltas: the volatility keyword + ONE
-- marked hunk; nothing else (diff-verified against the head).
create or replace function public.pirate_loot_for_wave(p_wave integer, p_danger numeric default 0)
returns jsonb
language plpgsql
volatile   -- CAPTAINS-LAUNCH (0171): was `immutable` (0041). Forced by the delta below (reads
           -- game_config + random() — both illegal under immutable); plpgsql call sites evaluate
           -- per call either way, so no caller's behavior changes. At rate 0 the OUTPUT is still
           -- byte-identical to the 0041 head for every input.
set search_path = public
as $$
declare
  v_items jsonb := '[]'::jsonb;
begin
  if p_wave is null or p_wave < 1 then
    return '[]'::jsonb;
  end if;
  -- guaranteed small scrap each cleared wave
  v_items := v_items || jsonb_build_object('item_id', 'scrap', 'quantity', 1);
  if p_wave >= 3  then v_items := v_items || jsonb_build_object('item_id', 'pirate_alloy', 'quantity', 1); end if;
  if p_wave >= 5  then v_items := v_items || jsonb_build_object('item_id', 'weapon_parts', 'quantity', 1); end if;
  if p_wave >= 8  then v_items := v_items || jsonb_build_object('item_id', 'engine_parts', 'quantity', 1); end if;
  if p_wave >= 10 then v_items := v_items || jsonb_build_object('item_id', 'repair_parts', 'quantity', 1); end if;
  -- CAPTAINS-LAUNCH (0171): the config-gated captain_memory_shard drop (packet F5 — the recruit
  -- economy's ONE source). Wave >= 2 keeps wave 1 deterministic (see header); appended AFTER every
  -- legacy element so the rate-0 array is byte-identical including order; flat qty 1 (the 0041
  -- anti-explosion posture). rate 0 (the seed) → `random() < 0` never fires → byte-inert.
  if p_wave >= 2 and random() < coalesce(cfg_num('captain_shard_drop_rate'), 0) then
    v_items := v_items || jsonb_build_object('item_id', 'captain_memory_shard', 'quantity', 1);
  end if;
  -- END CAPTAINS-LAUNCH (0171) delta — nothing else changed from the 0041 head.
  return v_items;
end;
$$;

-- ── ACL — re-asserted for the re-created function (the 0041:353 posture verbatim: server-only;
--    service_role for CI verification; NEVER clients). The TARGETED idiom (0170 precedent). No
--    other function's grants touched.
revoke execute on function public.pirate_loot_for_wave(integer, numeric) from public, anon, authenticated;
grant  execute on function public.pirate_loot_for_wave(integer, numeric) to service_role;
