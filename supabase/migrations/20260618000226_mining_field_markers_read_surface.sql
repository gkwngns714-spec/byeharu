-- Byeharu — MINING-FIELD-MARKERS: the missing client read surface for ACTIVE mining_fields.
--
-- WHY: mining_enabled was flipped true in prod (mining is live — MiningPanel's Extract action
-- server-accepts calls today), but mining_fields (0103) is server-only by design — RLS enabled,
-- NO anon/authenticated grant, no client read path. Players can extract but cannot SEE where any
-- field is, so command_mining_extract's 'no_field_in_range' failure is the only feedback a player
-- ever gets. This migration adds the ONE missing piece: a narrow, position-only read.
--
-- WHAT THIS EXPOSES (and what it deliberately does NOT):
--   · name, space_x, space_y of every is_active field — enough to navigate a settled fleet within
--     mining_extract_radius (750, 0102) and find something to extract from.
--   · reward_bundle_json is NEVER returned here. Composition/value stays revealed only through the
--     existing reveal-after-extraction surface (get_my_mining_extractions, 0106) — this migration
--     does not loosen that posture at all; it only lets a player find a field to extract FROM.
--   · mining_fields itself keeps its 0103 RLS posture verbatim (enabled, no policies, no grant) —
--     this is a SEPARATE SECURITY DEFINER reader, not a new grant on the table.
--
-- FAIL-CLOSED BY GATE (mining is live today, so this ships LIT — not behind a flag — but stays
-- inert automatically if mining is ever turned back off): checks mining_enabled FIRST (the 0097
-- reject-before-any-read law, applied to a read) and returns an EMPTY jsonb array — not an error,
-- not an ok/reason envelope — while it is false, so the map's field layer just renders nothing.
-- Mirrors get_world_map's "always a plain jsonb value, never a failure envelope" shape (0002) rather
-- than get_my_mining_extractions' ok/reason shape (0106) — there is no caller-specific failure mode
-- to report (no auth-required special case: any authenticated player may see where the fields are).
--
-- ACL: authenticated only (0104/0106 mining idiom) — NOT anon, unlike the public get_world_map:
-- fields are hidden world data revealed to signed-in players, not part of the always-public sector
-- map.

create or replace function public.get_active_mining_fields()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- DARK-GATE-FIRST, applied to a read: before touching mining_fields at all, answer the SAME
  -- empty result mining_enabled=false would give a real caller — no probing, no partial reveal.
  if not public.cfg_bool('mining_enabled') then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (select jsonb_agg(
       jsonb_build_object('name', f.name, 'space_x', f.space_x, 'space_y', f.space_y)
       order by f.name)
     from public.mining_fields f
     where f.is_active),
    '[]'::jsonb);
end;
$$;

comment on function public.get_active_mining_fields() is
  'MINING-FIELD-MARKERS: client read surface for the map — position + name of every active '
  'mining_fields row ONLY (never reward_bundle_json). Returns a plain jsonb array, [] while '
  'mining_enabled is false (fail-closed) — mining_fields itself keeps its 0103 no-grant RLS '
  'posture; this is a narrow SECURITY DEFINER reveal, not a table grant.';

-- ACL (0104/0106 idiom): revoke the default PUBLIC grant, then authenticated only.
revoke execute on function public.get_active_mining_fields() from public, anon;
grant  execute on function public.get_active_mining_fields() to authenticated;
