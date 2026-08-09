-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- PRESSURE STAGING (0344) — THE ONE WAY A PROOF ASKS FOR AN ENEMY FIELD, SHARED BY EVERY SUITE
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- Included with `\ir lib/pressure-staging.sql` from inside a proof's own begin;..rollback; txn, the
-- same house convention as scripts/lib/trade-proof-lib.sh on the shell side: sourced, never re-copied.
-- It lives here because TWO suites need it (danger-combat-proof.sql and team-command-proof.sql) and a
-- second copy of a staging idiom is exactly the thing the next slice has to keep in step by hand.
-- It defines pg_temp functions only — no txn control, no fixtures, no state of its own.

-- ── (0344) PRESSURE STAGING — the ONE way a block asks for a FIELD, and it asks the CLOCK ────────
-- 0344 deletes the arrow "the enemy side is empty -> spawn a wave, sized 1 + waves_cleared". Enemy
-- bodies now come from public.combat_pressure_step, which is a CLOCK: at most ONE body per call, only
-- while the field is under its site's authored cap, and NEVER because anything died. So a block that
-- needs n bodies standing together has to SAY so, and these two helpers are how it says it — once,
-- here, rather than in every block that needs one (the same reason ae_tick exists).
--
-- WHY A BLOCK CANNOT JUST DRIVE TICKS UNTIL n BODIES STAND. Two independent reasons, both structural:
--   1. now() is FROZEN for this whole txn and the authority skips its clock past every elapsed slot in
--      ONE step (that is what "a missed arrival is LOST, not banked" means), so the first tick of a
--      fresh fight brings exactly one body and the next slot is a full cadence away — a cadence that
--      can never elapse in here.
--   2. Driving ticks lets the FIGHT proceed between arrivals. By the time a third body landed the
--      first two would have closed different distances and been shot at, so there would be no tick on
--      which the field exists as ONE ring. Every geometry, volley and ordering property below is about
--      a field that stands together; that is the precondition, and it is owned rather than hoped for.
--
-- WHAT THEY MAY WRITE, AND WHY IT IS THE SAME LAW AS rewind_leg / ae_tick:
--   * pressure_site — public.location_pressure, which is CONTENT: a cadence and a concurrent cap,
--     authored per site as ROWS. A block that needs a field of six OWNS the cap that admits six
--     instead of inheriting whichever number the seed happens to carry (the
--     proofs-never-assert-ambient-defaults law). The cap is INERT on its own: nothing arrives until a
--     clock slot comes due, so a block that leaves the cap raised cannot hand a later block a body.
--   * pressure_fill — combat_encounters.next_reinforcement_at, a CLOCK, and nothing else. No status,
--     no geometry, no hp, and NEVER a combat_units row: every body it produces comes out of
--     public.combat_spawn_wave_units through the authority itself, at the same slot the tick would
--     have passed (the population before the arrival), so the ring is the ring a live fight gets —
--     one radius, the measured formation extent plus that body's own range plus one, on 0338's
--     arrival bearing. It is the tick's own call, made n times against n elapsed slots.
create or replace function pg_temp.pressure_site(p_enc uuid, p_cadence double precision, p_cap int)
returns void language plpgsql as $$
declare v_loc uuid;
begin
  select location_id into v_loc from public.combat_encounters where id = p_enc;
  if v_loc is null then
    raise exception 'pressure_site: encounter % resolves no site — an unauthored fight hosts no reinforcements at all, so every arrival a block asked for would be SILENTLY suppressed and the block would pass over an empty field', p_enc;
  end if;
  -- ── 0346: THE INGRESS DURATION IS OWNED HERE TOO, FOR THE SAME REASON THE CAP IS ───────────────
  -- 0346 makes a body spawn AT its zone's city and travel in over combat_enemy_ingress_ticks ticks,
  -- arriving on the same engagement boundary it used to be PLACED on. A block that asks for a FIELD
  -- wants bodies STANDING, not bodies in transit — every geometry, volley and ordering property
  -- downstream is about a field that stands together, which is exactly why this helper exists. So
  -- the duration is owned here beside the cadence and the cap rather than inherited from the seed.
  -- 0 means "no ingress": the spawn takes its degenerate arm and places the body on the boundary
  -- directly, byte-identical to the pre-0346 engine. A block that wants to test the INGRESS itself
  -- must set this to a positive value AFTER staging its field, and say so.
  perform public.set_game_config('combat_enemy_ingress_ticks', '0'::jsonb);
  -- ── 0347: THE CAP GROWTH IS OWNED HERE TOO, AND IT IS OWNED *OFF* ──────────────────────────────
  -- 0347 makes a site's cap GROW: effective_cap = concurrent_cap + floor(the fight's scheduled slot
  -- ordinal / location_pressure.cap_growth_every), and every real site is authored at 3 ("every 3
  -- wave, i want wave to add one fleet"). A NULL period means the cap does not grow, which is 0344's
  -- behaviour value for value.
  -- A block that asks for a field of n wants a cap of n and wants it to STAY n: every arrival,
  -- suppression and cap property in this harness is stated against a fixed number, and a cap that
  -- silently widened on the third slot would move those numbers under blocks that are not about the
  -- growth at all. So the period is owned here beside the cadence and the cap rather than inherited
  -- from the seed — the same law that put the cap here in the first place, and the same law that put
  -- the ingress duration above it.
  -- THE ONE BLOCK THAT IS ABOUT THE GROWTH — DZCOMBAT_PASS_FIELDGROWS — authors the period ITSELF,
  -- immediately after calling this, and says so. That is deliberate: exactly one place in the harness
  -- turns the owner's rule on, so there is exactly one place to look when it changes.
  insert into public.location_pressure (location_id, reinforcement_seconds, concurrent_cap, note,
                                        cap_growth_every, cap_ceiling)
  values (v_loc, p_cadence, p_cap, 'proof fixture: cadence + cap OWNED by the block under test',
          null, null)
  on conflict (location_id) do update
    set reinforcement_seconds = excluded.reinforcement_seconds,
        concurrent_cap        = excluded.concurrent_cap,
        note                  = excluded.note,
        cap_growth_every      = excluded.cap_growth_every,
        cap_ceiling           = excluded.cap_ceiling,
        updated_at            = now();
end $$;

create or replace function pg_temp.pressure_fill(p_enc uuid, p_n int) returns int language plpgsql as $$
declare
  v_tick int; v_ax double precision; v_ay double precision;
  v_lx double precision; v_ly double precision;
  v_arr int; v_got int := 0; i int;
begin
  for i in 1 .. p_n loop
    -- the caller's facts, resolved exactly as the tick resolves them: the anchor is
    -- coalesce(engagement_x, loc.x) and the site is the encounter's own location row.
    select ce.tick_number, coalesce(ce.engagement_x, l.x), coalesce(ce.engagement_y, l.y), l.x, l.y
      into v_tick, v_ax, v_ay, v_lx, v_ly
      from public.combat_encounters ce
      join public.locations l on l.id = ce.location_id
     where ce.id = p_enc;
    if not found then
      raise exception 'pressure_fill: encounter % does not resolve a site row — there is no cadence, no cap and no arrival bearing to fill a field from', p_enc;
    end if;
    update public.combat_encounters set next_reinforcement_at = now() - interval '1 second' where id = p_enc;
    select p.o_arrived into v_arr
      from public.combat_pressure_step(p_enc, v_tick, v_ax, v_ay, v_lx, v_ly, 0, false) p;
    -- a suppressed arrival is LOST, never banked: at the cap the authority answers 0 and stops, and
    -- the caller finds out by counting rather than by getting an extra body later.
    exit when coalesce(v_arr, 0) = 0;
    v_got := v_got + v_arr;
  end loop;
  return v_got;
end $$;

-- ── pg_temp.pressure_refill — "PUT n BODIES ON THE FIELD NOW", the one primitive every caller uses ──
-- pressure_site + pressure_fill are the two halves of every multi-body staging in the harness, and
-- FOUR callers now need exactly that pair back to back: danger-combat's field blocks, TEAMSETTLE's two
-- due slots, team-command's pg_temp.wipe_tick (which must land a LETHAL body after spending the live
-- one) and fleetgo's pg_temp.earn_wave (which must have a real body to clear). Composing it here once
-- is the difference between one authority and four spellings that the next slice keeps in step by hand.
--
-- IT OWNS THE SITE ROW AS WELL AS THE CLOCK, deliberately: a caller that asks for n bodies must not
-- inherit whatever concurrent cap an earlier block in the same transaction happened to leave behind.
-- The cap is set to exactly n, so "n arrived" and "no more than n can stand" are the same statement.
--
-- IT RAISES RATHER THAN RETURNING SHORT. Every caller's next assertion is about a fight that has
-- bodies in it; a silent 0 is precisely the failure that cost this slice a CI round — an empty field
-- reads as "the fleet survived" or "the wave never closed", never as "nothing was ever spawned".
create or replace function pg_temp.pressure_refill(p_enc uuid, p_n int) returns void language plpgsql as $$
declare v_got int;
begin
  perform pg_temp.pressure_site(p_enc, 45.0, p_n);
  v_got := pg_temp.pressure_fill(p_enc, p_n);
  if v_got <> p_n then
    raise exception 'pressure_refill: the pressure authority delivered % of the % bod(ies) asked for at encounter % — after 0344 a body arrives only when a clock slot comes due AND the field is under its site''s cap, and now() is frozen for this transaction, so a caller that needs a field must ask for one. An empty field does not read as an error downstream: it reads as "the fleet survived" or "the wave never closed"',
      v_got, p_n, p_enc;
  end if;
end $$;
