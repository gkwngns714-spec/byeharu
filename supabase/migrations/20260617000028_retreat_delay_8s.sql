-- Byeharu — M4: shorten retreat to ~8s (was 20s). Already a config value, so this
-- is a pure tuning change; the UI countdown reads retreat_delay_seconds. Later this
-- can scale by danger/ship/captain.

update public.game_config set value = '8', updated_at = now() where key = 'retreat_delay_seconds';
