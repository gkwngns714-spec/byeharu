-- Byeharu — COMBAT-TICKS RESULT VOCABULARY FIX: admit 'next_wave_incoming' to combat_ticks.result.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE BUG (latent, dormant behind a dark flag): migration 0014
-- (20260616000014_combat_tables.sql:54-56) created combat_ticks with an inline column CHECK —
-- Postgres auto-named `combat_ticks_result_check` — permitting exactly SIX result literals:
--     ('ongoing','wave_cleared','retreat_started','escaped','defeat','completed').
-- It has NEVER been altered since (git grep of every migration confirms 0014 is the sole definition).
--
-- But process_combat_ticks' WAVE-PAUSE branch — present since 0023 and carried verbatim through the
-- live 0234 spatial head (20260618000234_combat_spatial_tick.sql, BOTH arms: spatial :682 and
-- aggregate :975) — logs a tick with a SEVENTH literal the CHECK does not allow:
--     if v_log_ticks then
--       insert into combat_ticks (..., result) values (..., 'next_wave_incoming');   -- <- rejected
--     end if;
-- `v_log_ticks` = the `combat_tick_logging` game_config flag. Production seeds it FALSE, so the branch
-- is never taken and the defect is DORMANT. If `combat_tick_logging` is ever enabled, the wave-pause
-- tick's INSERT raises check_violation; process_combat_ticks' per-encounter guard
-- (cronguard_perrow_isolation 0206 / carried in 0234:1134-1137, `exception when others then raise
-- warning ... left in-place`) SWALLOWS it into a warning and ROLLS BACK that encounter's tick — so
-- tick_number does NOT advance and last_resolved_at is not refreshed: the encounter STALLS in the
-- wave pause, silently, every tick, forever. (PR #225's multi-pirate proof documents this quirk and
-- had to toggle tick-logging OFF around the pause tick to sidestep it — scripts/
-- multipirate-lifecycle-proof.sql:394-405.)
--
-- WHY EXTEND (not retire) THE LITERAL: 'next_wave_incoming' is a MEANINGFUL, CONSUMED event, not a
-- stray internal artifact. Two client readers depend on it:
--   • src/features/combat/RoundLog.tsx:41  — renders "Wave N incoming…" for a next_wave_incoming tick.
--   • src/features/combat/ActiveCombatPanel.tsx:57 — skips next_wave_incoming ticks to find the latest
--       REAL combat round.
-- The TS `CombatTick.result` field is a plain `string` (src/features/combat/combatTypes.ts:89) — there
-- is NO closed union / generated enum to widen in lockstep, so this migration is the sole vocabulary
-- authority and no code change accompanies it. The fix is therefore the MINIMAL correct one: widen the
-- persisted vocabulary by ONE value so the branch that already exists (and the readers that already
-- consume it) become legal — a pure widening. Every previously-legal result stays legal.
--
-- WHY NOT re-write the writer: changing the two `'next_wave_incoming'` literals to `'ongoing'` would
-- mean re-creating the ~700-line live spatial process_combat_ticks under byte-parity discipline (far
-- higher risk) AND would silently break the two client readers above (they special-case the pause
-- tick). Rejected.
--
-- ATOMIC + TRANSACTIONAL: DROP CONSTRAINT + ADD CONSTRAINT run in this migration's single implicit
-- transaction. ADD CONSTRAINT re-validates every existing combat_ticks row against the WIDER predicate
-- — a strict superset of the old one, so it can never fail on legacy data. If anything is off the whole
-- migration rolls back cleanly; the CHECK is never left dropped-without-replacement.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1. drop the six-value CHECK 0014 minted (auto-named combat_ticks_result_check) ────────────────
alter table public.combat_ticks
  drop constraint combat_ticks_result_check;

-- ── 2. re-add it widened by the one already-written, already-consumed literal 'next_wave_incoming' ──
alter table public.combat_ticks
  add constraint combat_ticks_result_check
  check (result = any (array[
    'ongoing','wave_cleared','retreat_started','escaped','defeat','completed','next_wave_incoming'
  ]));

comment on constraint combat_ticks_result_check on public.combat_ticks is
  'COMBAT-TICKS RESULT (0241): the seven result literals combat_ticks may carry. Widens 0014''s '
  'six-value CHECK by ''next_wave_incoming'' — the wave-pause tick written by process_combat_ticks '
  '(0234 spatial :682 + aggregate :975, guarded by combat_tick_logging) and consumed by RoundLog.tsx '
  '/ ActiveCombatPanel.tsx. Before this, a logged pause tick raised check_violation → the per-encounter '
  'cron guard swallowed it → the encounter stalled in the wave pause whenever combat_tick_logging was on.';

-- ── 3. self-assert (deploy-time; a raise aborts the migration txn — nothing half-applies) ─────────
-- The disposable-DB apply-proof (scripts/combat-ticks-result-fix-proof.sql via `supabase start`) is the
-- real net: it drives a REAL encounter across a wave pause with combat_tick_logging ON and proves the
-- next_wave_incoming tick now lands with no check_violation and the encounter continues. This block is
-- the cheap deploy-time guard that the widened CHECK actually took, mirroring the 0240 self-assert idiom.
do $rescheck$
declare
  v_def text;
begin
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conname = 'combat_ticks_result_check'
    and c.conrelid = 'public.combat_ticks'::regclass
    and c.contype = 'c';

  if v_def is null then
    raise exception 'COMBAT-TICKS RESULT self-assert FAIL: combat_ticks_result_check is missing after the re-add';
  end if;
  -- every one of the seven literals must be present (the six legacy + the newly-admitted one).
  if v_def !~ 'next_wave_incoming' then
    raise exception 'COMBAT-TICKS RESULT self-assert FAIL: constraint does not admit ''next_wave_incoming'' (%)', v_def;
  end if;
  if v_def !~ 'ongoing' or v_def !~ 'wave_cleared' or v_def !~ 'retreat_started'
     or v_def !~ 'escaped' or v_def !~ 'defeat' or v_def !~ 'completed' then
    raise exception 'COMBAT-TICKS RESULT self-assert FAIL: a legacy result literal was dropped from the vocabulary (%)', v_def;
  end if;

  raise notice 'COMBAT-TICKS RESULT self-assert ok: combat_ticks_result_check now admits all seven result literals incl. next_wave_incoming — a logged wave-pause tick no longer check_violates (def: %)', v_def;
end $rescheck$;
