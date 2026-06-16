-- Byeharu — M4 pacing tune: raise wave HP so early waves last ~3+ ticks (the
-- "easy = 3-6 ticks" target) instead of ~2. HP scales with danger from here, so
-- later waves naturally reach the normal (6-12) and strong (12+) bands.
-- Pure config change; process_combat_ticks reads cfg_num('enemy_hp_base').

update public.game_config set value = '14', updated_at = now() where key = 'enemy_hp_base';
