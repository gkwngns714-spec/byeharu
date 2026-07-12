-- Byeharu — DECKS-0+1: ship decks — six named captain stations (owner directive: "In ship i
-- should be able to see decks - like control room, weapon system room, etc, with empty slots
-- that will be later assigned captains").
--
-- WHAT SHIPS HERE (structure + the station axis on the ONE writer path; the board UI is the
-- client half of this slice):
--   (1) `ship_stations` — the six-station catalog (Reference/Config; the 0107/0117 posture
--       verbatim: RLS public-read, migration-seeded, NO runtime writer). `affinity_specialization`
--       is INERT DATA this slice — DECKS-3 owns the affinity bonus; NOTHING reads it yet (the
--       0117 specialization precedent: a constrained mechanism input shipped before its consumer).
--   (2) `ship_captain_assignments.station` — a NULLABLE text FK onto the catalog (existing rows
--       stay valid; NULL = general quarters) + a partial unique index on (main_ship_id, station)
--       where station is not null (the 0167:95-96 partial-index idiom — zero effect on NULL rows).
--       The HEADCOUNT CAP (count(*) < captain_slots, 0119) stays THE capacity authority; the
--       station axis is placement, not capacity.
--   (3) The captain assign path re-created from its grep-verified TRUE heads with marked
--       `-- DECKS-1` hunks ONLY (reviewers: extract each function and diff against its head —
--       everything outside a marked hunk is byte-identical):
--         · captain_assign_apply        — TRUE head 0119:94-177 (its ONLY head)
--         · captain_execute_command     — TRUE head 0121:205-314 (0120 superseded)
--         · assign_captain_to_ship      — TRUE head 0120:251-275 (its ONLY head)
--         · captain_command_client_envelope — TRUE head 0121:319-364 (0120 superseded)
--         · get_my_captain_instances    — TRUE head 0181:132-177 (0123 superseded)
--       unassign_captain_from_ship (0120:277-297) is NOT re-created: plpgsql bodies late-bind, so
--       its positional 5-arg call resolves against the new defaulted command signature, and the
--       station frees AUTOMATICALLY because unassign deletes the assignment ROW (verified: the
--       0119 unassign branch is a row delete — the station column goes with it; no second free
--       path needed).
--   (4) A deterministic BACKFILL of any pre-existing assignment rows (per ship: rows by
--       (assigned_at, captain_instance_id), stations by sort) — display-only consequence,
--       monotonic, no randomness (the 0041 determinism law).
--
-- SIGNATURE CHANGES (drop-then-create, NOT an overload): `p_station text default null` on the
-- writer/command/wrapper would OVERLOAD the old identity and make every existing positional call
-- ambiguous, so the old identities are DROPPED first and the grants re-asserted on the new ones.
-- Old callers are BEHAVIOR-EQUIVALENT + enriched: a station-less assign auto-assigns the
-- lowest-sort FREE station (deterministic), the client envelope gains an additive `station` key,
-- and every pre-existing reject keeps its exact reason and ORDER (the new station checks append
-- AFTER the headcount cap — reject-before-read order preserved; nothing moves). The two pinned
-- identities in scripts/activate-captains.sql are synced this same step.
--
-- DEPLOY-INERT WHILE DARK (captain_assignment_enabled='false', 0117 — unflipped): the catalog and
-- the nullable column are pure additive DDL no live path reads; the re-created functions sit
-- behind the SAME reject-before-any-read dark gates as their heads (identical dark envelopes, no
-- new oracle); the backfill touches zero-or-more existing assignment rows (zero on a dark prod —
-- and even against a lit database every hunk is additive/behavior-equivalent, so the migration is
-- safe in either posture). NO new flag: decks v1 is a display reframe of the existing dark captain
-- system — the existing captain gates are the gates.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): `ship_stations` → Reference/Config
-- (migration-seeded, no runtime writer); the station column stays under Captain's sole writer
-- (captain_assign_apply — one writer covers the new column's every mutation; no second path).
-- New edge: Captain → its own ship_stations catalog (intra-family read). No cycle; no flag flipped.

-- ── 1) ship_stations — the six-station deck catalog (Reference/Config; public read-only) ─────────
create table public.ship_stations (
  station_id              text primary key,
  name                    text not null,
  sort                    integer not null unique,  -- total order: the auto-assign + board order
  -- INERT this slice (DECKS-3 owns the affinity bonus): the station's favored captain
  -- specialization; NULL = no affinity (the bridge). NOT an FK — captain_types.specialization is
  -- not a key (0117 seeds one type per specialization but never made it unique) — so the honest
  -- constraint is the SAME CHECK vocabulary 0117:76 locked; the two columns cannot drift apart.
  affinity_specialization text
    check (affinity_specialization is null
           or affinity_specialization in ('combat','trade','exploration','mining','support')),
  description             text not null
);

alter table public.ship_stations enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate.
-- Only migrations / service_role (admin) write (the 0039/0107/0117 catalog posture verbatim).
create policy "ship_stations_public_read" on public.ship_stations for select using (true);
grant select on public.ship_stations to anon, authenticated;

comment on table public.ship_stations is
  'DECKS-0: the six named captain stations of a main ship (Reference/Config — migration-seeded, '
  'no runtime writer, public read-only). sort is the deterministic auto-assign + display order. '
  'affinity_specialization is INERT until DECKS-3 (the bonus slice); nothing reads it yet.';
comment on column public.ship_stations.affinity_specialization is
  'DECKS-0: the station''s favored captain specialization (0117 vocabulary; NULL = none). INERT '
  'DATA this slice — DECKS-3 owns the affinity bonus; no reader exists yet.';

-- Seed EXACTLY six (idempotent; the 0117 seed posture). Affinity mapping is the locked DECKS-0
-- set: bridge —, gunnery combat, engineering mining, logistics trade, sensors exploration,
-- medbay support.
insert into public.ship_stations (station_id, name, sort, affinity_specialization, description) values
  ('bridge',      'Bridge',      1, null,
   'The command deck. Every ship answers to whoever holds this chair.'),
  ('gunnery',     'Gunnery',     2, 'combat',
   'Fire control and the weapon batteries. Loud, hot, and never quite off-duty.'),
  ('engineering', 'Engineering', 3, 'mining',
   'Reactors, extractors, and the drills. Where the ship''s muscle is kept honest.'),
  ('logistics',   'Logistics',   4, 'trade',
   'Cargo manifests and berth ledgers. The hold is only as good as its paperwork.'),
  ('sensors',     'Sensors',     5, 'exploration',
   'The listening post. Long-range sweeps and the charts nobody else bothers to keep.'),
  ('medbay',      'Medbay',      6, 'support',
   'Patches crew and hull alike. The quietest deck until it suddenly is not.')
on conflict (station_id) do nothing;

-- ── 2) the station axis on ship_captain_assignments (nullable; existing rows stay valid) ─────────
alter table public.ship_captain_assignments
  add column station text references public.ship_stations (station_id);
-- One captain per station per ship — the 0167:95-96 partial-unique idiom (zero effect on NULL
-- rows; NULL = general quarters remains legal). This index BACKSTOPS the writer's check exactly
-- like the 0119 PK backstops one-ship-per-captain.
create unique index ship_captain_assignments_one_station_per_ship
  on public.ship_captain_assignments (main_ship_id, station) where station is not null;

comment on column public.ship_captain_assignments.station is
  'DECKS-1: which deck station this captain holds (ship_stations FK; NULL = general quarters). '
  'Placement only — capacity stays the 0119 headcount cap. Sole writer = captain_assign_apply '
  '(explicit station validated unknown_station/station_occupied; NULL auto-assigns the '
  'lowest-sort free station). Unassign frees it by deleting the row.';

-- ── 3) captain_assign_apply — re-created from its TRUE head (0119:94-177, the ONLY head) ─────────
-- PARITY DISCIPLINE: body byte-identical to 0119 EXCEPT the marked -- DECKS-1 hunks (the
-- p_station param + declare line, the step-5b station resolution, the widened insert). The 0119
-- contract holds: returns void — the COMMAND layer composes/reads the success payload; the
-- writer stays exception-style and rejects, never clamps. Drop-then-create: a defaulted 4th
-- param would overload the 3-arg identity and make existing positional calls ambiguous.
drop function public.captain_assign_apply(uuid, uuid, uuid);
create or replace function public.captain_assign_apply(
  p_player_id           uuid,
  p_captain_instance_id uuid,
  p_main_ship_id        uuid,  -- NOT NULL = ASSIGN to this ship · NULL = UNASSIGN
  p_station             text default null  -- DECKS-1: assign only — explicit station, or NULL =
                                           -- auto-assign the lowest-sort FREE station; ignored on
                                           -- unassign (the row delete frees whatever it held)
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_captain     captain_instances%rowtype;
  v_ship_owner  uuid;
  v_slots_limit integer;
  v_used        integer;
  v_current     uuid;
  v_prev_ship   uuid;
  v_station     text;  -- DECKS-1: the resolved station for the insert
begin
  -- 1) per-player serialization FIRST (the exact 0112:99–103 idiom, captain domain): ALL of a
  --    player's assignment mutations queue here, so the headcount below cannot be raced by
  --    another assign/unassign of the same player (and every assignment on a ship belongs to the
  --    ship's owner, so per-player IS per-ship-assignment-set).
  perform pg_advisory_xact_lock(hashtext('captain_assignment'), hashtext(p_player_id::text));

  -- 2) the captain instance must exist AND belong to p_player_id (intra-system read). One reason
  --    for both cases — another player's instance answers exactly like a nonexistent one.
  select * into v_captain from captain_instances
    where id = p_captain_instance_id and player_id = p_player_id;
  if not found then
    raise exception 'captain_assign_apply: captain_not_owned — captain instance % not found for player %',
      p_captain_instance_id, p_player_id;
  end if;

  -- ── UNASSIGN (p_main_ship_id NULL): delete the captain's assignment row ─────────────────────────
  if p_main_ship_id is null then
    delete from ship_captain_assignments
      where captain_instance_id = p_captain_instance_id
      returning main_ship_id into v_prev_ship;
    if v_prev_ship is null then
      -- distinct truthful reason; idempotency ENVELOPES are the future command slice's job
      -- (receipt replay), not this writer's — a bare re-unassign is a real not_assigned here.
      raise exception 'captain_assign_apply: not_assigned — captain instance % has no assignment',
        p_captain_instance_id;
    end if;
    return;
  end if;

  -- ── ASSIGN (p_main_ship_id NOT NULL) ────────────────────────────────────────────────────────────
  -- 3) the target ship is read by the (main_ship_id, player_id) PAIR — never "the player's ship"
  --    singular (the player_id UNIQUE was dropped in 0079; the 0115:96–101 shape). Also fixes
  --    owner-consistency: row.player_id = captain owner = ship owner (0115:47–50).
  select player_id, captain_slots into v_ship_owner, v_slots_limit
    from main_ship_instances where main_ship_id = p_main_ship_id;
  if v_ship_owner is null or v_ship_owner <> p_player_id then
    raise exception 'captain_assign_apply: ship_not_owned — ship % not found for player %',
      p_main_ship_id, p_player_id;
  end if;

  -- 4) one-ship-per-captain: an already-assigned captain is REJECTED naming its current ship —
  --    never silently re-homed (an explicit unassign must come first). The PK backstops this
  --    check.
  select main_ship_id into v_current from ship_captain_assignments
    where captain_instance_id = p_captain_instance_id;
  if v_current is not null then
    raise exception 'captain_assign_apply: already_assigned — captain instance % is assigned to ship %',
      p_captain_instance_id, v_current;
  end if;

  -- 5) HEADCOUNT HARD CAP (the captain analogue of the Σ slot_cost ≤ module_slots gate,
  --    0112:144–156 / 0044:112–115 — reject, NEVER clamp): count, not a slot_cost sum, because
  --    one captain occupies exactly one slot (slice-A locked decision; captain_slots is a
  --    headcount). Race-free under the step-1 player lock (see header (4)).
  select count(*) into v_used from ship_captain_assignments
    where main_ship_id = p_main_ship_id;
  if v_used >= v_slots_limit then
    raise exception 'captain_assign_apply: captain_slots_full — ship % has % of % captain slots occupied',
      p_main_ship_id, v_used, v_slots_limit;
  end if;

  -- 5b) DECKS-1 — STATION RESOLUTION (appended AFTER every pre-existing reject, so old callers
  --     keep their exact reject order; capacity above stays the ONE authority — this step is
  --     placement only). Race-free under the step-1 player lock (owner-consistency makes
  --     per-player per-ship, exactly like the headcount read); the partial unique index
  --     backstops. Deterministic: no randomness, lowest sort wins (the 0041 law).
  if p_station is not null then
    -- explicit station: must exist in the catalog…
    if not exists (select 1 from ship_stations where station_id = p_station) then
      raise exception 'captain_assign_apply: unknown_station — station % is not in the ship_stations catalog',
        p_station;
    end if;
    -- …and be free on THIS ship.
    if exists (select 1 from ship_captain_assignments
                 where main_ship_id = p_main_ship_id and station = p_station) then
      raise exception 'captain_assign_apply: station_occupied — station % on ship % is already held',
        p_station, p_main_ship_id;
    end if;
    v_station := p_station;
  else
    -- auto-assign: the lowest-sort FREE station. With captain_slots = 6 = the catalog size the
    -- headcount cap (step 5) fires first, so exhaustion is UNREACHABLE today — but a future slot
    -- bump above the station count would reach it, so it is handled honestly, never silently
    -- (a NULL insert here would silently invent a seventh place).
    select s.station_id into v_station
      from ship_stations s
      where not exists (select 1 from ship_captain_assignments a
                          where a.main_ship_id = p_main_ship_id and a.station = s.station_id)
      order by s.sort
      limit 1;
    if v_station is null then
      raise exception 'captain_assign_apply: no_free_station — ship % has every station occupied',
        p_main_ship_id;
    end if;
  end if;

  -- 6) the ONE mutation. Plain insert: the PK cannot conflict here — step 4 ran under the step-1
  --    lock, and only the owner (serialized above) can reference this captain.
  insert into ship_captain_assignments (captain_instance_id, main_ship_id, player_id, station)  -- DECKS-1: + station
    values (p_captain_instance_id, p_main_ship_id, p_player_id, v_station);
end;
$$;

-- ACL re-asserted on the NEW identity (drop discards the 0119 grants; the 0108:108–113 relock
-- idiom): the ONE writer stays OFF the client surface.
revoke execute on function public.captain_assign_apply(uuid, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.captain_assign_apply(uuid, uuid, uuid, text) to service_role;

-- ── 4) captain_execute_command — re-created from its TRUE head (0121:205-314) ─────────────────────
-- PARITY DISCIPLINE: body byte-identical to 0121 EXCEPT the marked -- DECKS-1 hunks (the
-- p_station param + declare line, the action-shape clause, the delegate arg, the three new
-- translated reasons, the post-delegate station read-back, the envelope's station key).
-- Drop-then-create (overload ambiguity, as above). unassign_captain_from_ship's positional
-- 5-arg call late-binds onto this defaulted identity — no wrapper re-create needed.
drop function public.captain_execute_command(uuid, text, uuid, uuid, text);
create or replace function public.captain_execute_command(
  p_player_id           uuid,
  p_action              text,
  p_captain_instance_id uuid,
  p_main_ship_id        uuid,   -- required on 'assign'; must be NULL on 'unassign'
  p_request_id          text,
  p_station             text default null  -- DECKS-1: 'assign' only (explicit station or NULL =
                                           -- auto); must be NULL on 'unassign'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rcpt       captain_assignment_receipts%rowtype;
  v_check_ship uuid;
  v_res        jsonb;
  v_reason     text;
  v_station    text;  -- DECKS-1: the station actually taken (read back after the delegate)
begin
  -- 1) DARK GATE FIRST (0117 law / 0113:118–122 idiom): while captain_assignment_enabled is
  --    false, reject deterministically BEFORE any other read — no receipt read, no lock, no row
  --    read.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 2) pure input validation of the idempotency key (0113:124–128 verbatim): TEXT, non-empty,
  --    sanity-capped (clients send 36-char crypto.randomUUID() strings).
  if p_request_id is null or p_request_id = '' or length(p_request_id) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 3) per-player serialization BEFORE the replay check (0113:130–135; the SAME
  --    ('captain_assignment', player) key captain_assign_apply takes — reentrant within this
  --    transaction, see the 0120 header): all of this player's assignment commands AND mutations
  --    queue here, so a same-request_id race resolves to one mutation + one verbatim replay, and
  --    the settled-rule read below cannot be raced by another assignment command of this player.
  perform pg_advisory_xact_lock(hashtext('captain_assignment'), hashtext(p_player_id::text));

  -- 4) IDEMPOTENCY REPLAY (0089/0095/0109/0113 trade semantics, matched exactly): a receipt for
  --    (player, request_id) already exists → return its stored success envelope VERBATIM,
  --    flagged — no write, no re-check, NO payload-conflict check (a reused request_id replays
  --    the original result even if this call names a different action/captain/ship).
  select * into v_rcpt from captain_assignment_receipts
    where player_id = p_player_id and request_id = p_request_id;
  if found then
    return v_rcpt.result_json || jsonb_build_object('idempotent_replay', true);
  end if;

  -- 5) action-shape validation: exactly two actions; 'assign' targets a ship, 'unassign' must not.
  if p_action is null or p_action not in ('assign', 'unassign')
     or (p_action = 'assign'   and p_main_ship_id is null)
     or (p_action = 'unassign' and p_main_ship_id is not null)
     or (p_action = 'unassign' and p_station is not null)  -- DECKS-1: a station makes no sense on unassign
     then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request');
  end if;

  -- 6) THE GAME RULE THIS LAYER OWNS — ship-must-be-SETTLED-SAFE (the 0120 header's promised
  --    amendment; header E3): a loadout, captain roster included, is frozen mid-transit /
  --    in-space / mid-combat. Resolve the affected ship per action (the 0114 branch shapes),
  --    then run the ONE shared Main-Ship leaf. Reads are owner-scoped so another player's ship
  --    state can never be probed; the writer remains the final authority on ownership.
  if p_action = 'assign' then
    select main_ship_id into v_check_ship from main_ship_instances
      where main_ship_id = p_main_ship_id and player_id = p_player_id;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'ship_not_owned');
    end if;
  else
    -- unassign: the affected ship is the one the captain is CURRENTLY assigned to. Owner-scoped
    -- read; if no assignment row exists, v_check_ship stays NULL and the rule is skipped — the
    -- writer answers captain_not_owned / not_assigned truthfully (the 0114 unfit-branch
    -- semantics; an unassigned captain is not a settled-safe concern).
    select a.main_ship_id into v_check_ship
      from ship_captain_assignments a
      where a.captain_instance_id = p_captain_instance_id and a.player_id = p_player_id;
  end if;
  if v_check_ship is not null
     and not public.mainship_space_assert_settled_safe(v_check_ship) then
    return jsonb_build_object('ok', false, 'reason', 'ship_not_settled');
  end if;

  -- 7) DELEGATE the mutation to THE ONE writer (0119) — this command never touches
  --    ship_captain_assignments directly. The writer is exception-style (the 0119 locked
  --    decision): its reason-prefixed raises are TRANSLATED here into failure envelopes — the
  --    known reasons only; anything else RE-RAISES (never hide a bug). A raise writes nothing
  --    (the failure-writes-no-receipt law holds by construction).
  begin
    perform public.captain_assign_apply(p_player_id, p_captain_instance_id,
      case when p_action = 'assign' then p_main_ship_id else null end,
      p_station);  -- DECKS-1: thread the station (NULL on unassign by step 5's shape check)
  exception when others then
    v_reason := substring(sqlerrm from '^captain_assign_apply: ([a-z_]+)');
    if v_reason in ('captain_not_owned','ship_not_owned','already_assigned',
                    'captain_slots_full','not_assigned',
                    'unknown_station','station_occupied','no_free_station') then  -- DECKS-1
      return jsonb_build_object('ok', false, 'reason', v_reason);
    end if;
    raise;
  end;

  -- 7b) DECKS-1 — read back the station the writer took (explicit OR auto-picked). The writer
  --     returns void (the 0119 contract: this command is the envelope's one author), so the one
  --     honest source is the row it just wrote — read under the step-3 lock still held in this
  --     transaction, so nothing can move between the delegate and this read. NULL on unassign
  --     (the row is gone).
  if p_action = 'assign' then
    select station into v_station from ship_captain_assignments
      where captain_instance_id = p_captain_instance_id;
  end if;

  -- 8) RECEIPT — only a SUCCESSFUL mutation writes one, atomically with the mutation (same
  --    transaction as the writer's insert/delete). The writer returns void, so the success
  --    envelope is built here; result_json stores it verbatim for replay.
  v_res := jsonb_build_object('ok', true, 'action', p_action,
    'captain_instance_id', p_captain_instance_id,
    'main_ship_id', case when p_action = 'assign' then p_main_ship_id else null end,
    'station', v_station);  -- DECKS-1: additive; replay returns it verbatim from the receipt
  insert into captain_assignment_receipts
      (player_id, request_id, action, captain_instance_id, main_ship_id, result_json)
    values (p_player_id, p_request_id, p_action, p_captain_instance_id,
            case when p_action = 'assign' then p_main_ship_id else null end, v_res);

  return v_res;
end;
$$;

revoke execute on function public.captain_execute_command(uuid, text, uuid, uuid, text, text) from public, anon, authenticated;
grant  execute on function public.captain_execute_command(uuid, text, uuid, uuid, text, text) to service_role;

-- ── 5) assign_captain_to_ship — re-created from its TRUE head (0120:251-275, the ONLY head) ──────
-- PARITY DISCIPLINE: body byte-identical to 0120 EXCEPT the marked -- DECKS-1 hunks (the
-- p_station param, the delegate arg). Drop-then-create (overload ambiguity, as above). The dark
-- gate order is untouched — while dark this wrapper answers the identical locked envelope
-- REGARDLESS of the new input too (anti-probe: an unknown station is indistinguishable from a
-- known one while the feature is off).
drop function public.assign_captain_to_ship(text, uuid, uuid);
create or replace function public.assign_captain_to_ship(
  p_request_id          text,
  p_captain_instance_id uuid,
  p_main_ship_id        uuid,
  p_station             text default null  -- DECKS-1: explicit deck station, or NULL = auto
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'message', 'You must be signed in.');
  end if;
  -- flag gate FIRST (defense-in-depth + anti-probe, 0083/0099/0109/0113 idiom): while dark, the
  -- answer is the identical locked envelope regardless of input. The private command re-checks
  -- first and is the final authority.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;
  return public.captain_command_client_envelope(
    public.captain_execute_command(v_player, 'assign', p_captain_instance_id, p_main_ship_id, p_request_id,
      p_station));  -- DECKS-1: thread the station
end;
$$;

revoke execute on function public.assign_captain_to_ship(text, uuid, uuid, text) from public, anon;
grant  execute on function public.assign_captain_to_ship(text, uuid, uuid, text) to authenticated;

-- ── 6) captain_command_client_envelope — re-created from its TRUE head (0121:319-364) ────────────
-- PARITY DISCIPLINE: byte-identical to 0121 EXCEPT the marked -- DECKS-1 hunks — the three new
-- station reason + message entries (the exact 0121 E4 precedent: the mapper grows one entry per
-- new writer reason). Same signature → plain create-or-replace; grants survive but are
-- re-asserted (the 0121 §5 explicit-posture idiom).
create or replace function public.captain_command_client_envelope(p_res jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_reason text;
begin
  if (p_res->>'ok')::boolean is true then
    return p_res || jsonb_build_object('idempotent_replay',
      coalesce((p_res->>'idempotent_replay')::boolean, false));
  end if;

  v_reason := coalesce(p_res->>'reason', 'unavailable');

  -- the ONE dark visibility signal (no message — the 0110/0116 read-surface envelope shape):
  if v_reason = 'feature_disabled' then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;

  return jsonb_build_object(
    'ok', false,
    'reason', case v_reason
      when 'invalid_request_id'  then 'invalid_request'
      when 'invalid_request'     then 'invalid_request'
      when 'ship_not_settled'    then 'ship_not_settled'
      when 'captain_not_owned'   then 'captain_not_owned'
      when 'ship_not_owned'      then 'ship_not_owned'
      when 'already_assigned'    then 'already_assigned'
      when 'captain_slots_full'  then 'captain_slots_full'
      when 'not_assigned'        then 'not_assigned'
      when 'unknown_station'     then 'unknown_station'      -- DECKS-1
      when 'station_occupied'    then 'station_occupied'     -- DECKS-1
      when 'no_free_station'     then 'no_free_station'      -- DECKS-1
      else 'unavailable'
    end,
    'message', case v_reason
      when 'invalid_request_id'  then 'Invalid command request.'
      when 'invalid_request'     then 'Invalid command request.'
      when 'ship_not_settled'    then 'The ship must be settled at home or docked at a location to change its captain roster.'
      when 'captain_not_owned'   then 'That captain is not in your possession.'
      when 'ship_not_owned'      then 'That ship is not yours.'
      when 'already_assigned'    then 'That captain is already assigned to a ship. Unassign them first.'
      when 'captain_slots_full'  then 'No free captain slots on this ship.'
      when 'not_assigned'        then 'That captain is not assigned to any ship.'
      when 'unknown_station'     then 'That deck station does not exist.'                       -- DECKS-1
      when 'station_occupied'    then 'That deck station is already held. Free it first.'       -- DECKS-1
      when 'no_free_station'     then 'Every deck station on this ship is occupied.'            -- DECKS-1
      else 'Captain assignment is unavailable right now.'
    end);
end;
$$;

revoke execute on function public.captain_command_client_envelope(jsonb) from public, anon, authenticated;
grant  execute on function public.captain_command_client_envelope(jsonb) to service_role;

-- ── 7) get_my_captain_instances — re-created from its TRUE head (0181:132-177) ───────────────────
-- PARITY DISCIPLINE: byte-identical to 0181 EXCEPT the ONE marked [DECKS-1 hunk] projection line
-- (the exact 0181 C2-3 precedent — one additive display key). Gate/ordering/joins/ACL unchanged;
-- dark answers stay identical, so nothing new leaks while the feature is off.
create or replace function public.get_my_captain_instances()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_captains jsonb;
  c_empty    constant jsonb := '[]'::jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject FIRST (0117 law; the 0087/0101/0106/0110 read idiom): before any
  -- instance read, and the identical envelope regardless of the caller's captains — no probing
  -- while dark.
  if not public.cfg_bool('captain_assignment_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'captain_assignment_disabled');
  end if;

  -- read-only: ONLY the caller's own instances (query-scoped — defense in depth over RLS),
  -- joined to their public catalog identity, LEFT-joined to the assignment row for the per-row
  -- roster indicator (header (1) locked decision: display data only). Writes nothing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'instance_id',     i.id,
           'captain_type_id', i.captain_type_id,
           'name',            t.name,
           'specialization',  t.specialization,
           'stats_json',      t.stats_json,
           'xp',              i.xp,     -- [C2-3 hunk] the 0177 progression columns, additive:
           'level',           i.level,  -- [C2-3 hunk] xp=0/level=1 everywhere while growth is dark
           'main_ship_id',    a.main_ship_id,
           'station',         a.station,  -- [DECKS-1 hunk] the held deck station (null = unassigned/general quarters)
           'created_at',      i.created_at) order by i.created_at desc),
         c_empty)
    into v_captains
    from public.captain_instances i
    join public.captain_types t on t.id = i.captain_type_id
    left join public.ship_captain_assignments a on a.captain_instance_id = i.id
    where i.player_id = v_player;

  return jsonb_build_object('ok', true, 'captains', coalesce(v_captains, c_empty));
end;
$$;
-- ACL re-asserted on the re-created identity (the 0123 §3 idiom verbatim; create-or-replace
-- preserves grants — re-emitted for an explicit posture, the 0092/0179 idiom).
revoke execute on function public.get_my_captain_instances() from public, anon;
grant  execute on function public.get_my_captain_instances() to authenticated;

-- ── 8) BACKFILL — deterministic stations for pre-existing assignment rows ────────────────────────
-- Zero-or-more rows (ZERO on a dark prod — no assignment can exist while captain_assignment_
-- enabled has never been true; still written defensively for a lit database). Per ship, rows in
-- (assigned_at, captain_instance_id) order take stations in sort order — fully deterministic
-- (the 0041 law: the uuid tiebreak resolves same-timestamp rows identically on every run),
-- display-only in consequence, and MONOTONIC: it never moves a non-null station, only fills
-- nulls. The headcount cap (≤ 6 = the catalog size) guarantees every row ranks within the six
-- stations, so no null can survive (self-asserted below).
with ranked as (
  select a.captain_instance_id,
         row_number() over (partition by a.main_ship_id
                            order by a.assigned_at, a.captain_instance_id) as rn
    from public.ship_captain_assignments a
   where a.station is null
), stations as (
  select station_id, row_number() over (order by sort) as rn
    from public.ship_stations
)
update public.ship_captain_assignments a
   set station = s.station_id
  from ranked r
  join stations s on s.rn = r.rn
 where a.captain_instance_id = r.captain_instance_id;

-- ── 9) SELF-ASSERTS (the 0181 §3 posture: identities, ACLs, prosrc pins, seed truth, backfill) ───
do $$
declare
  n int;
  v_src text;
begin
  -- 1. catalog: EXACTLY six rows, and the six verbatim (id, name, sort, affinity) tuples.
  select count(*) into n from public.ship_stations;
  if n <> 6 then raise exception 'DECKS self-assert FAIL: ship_stations has % rows (want exactly 6)', n; end if;
  select count(*) into n
    from (values ('bridge','Bridge',1,null::text),
                 ('gunnery','Gunnery',2,'combat'),
                 ('engineering','Engineering',3,'mining'),
                 ('logistics','Logistics',4,'trade'),
                 ('sensors','Sensors',5,'exploration'),
                 ('medbay','Medbay',6,'support')) w(id, nm, srt, aff)
    join public.ship_stations s
      on s.station_id = w.id and s.name = w.nm and s.sort = w.srt
     and s.affinity_specialization is not distinct from w.aff;
  if n <> 6 then raise exception 'DECKS self-assert FAIL: ship_stations seed tuples drifted (% of 6 verbatim)', n; end if;

  -- 2. the station column + the partial unique index exist.
  select count(*) into n from information_schema.columns
    where table_schema = 'public' and table_name = 'ship_captain_assignments' and column_name = 'station';
  if n <> 1 then raise exception 'DECKS self-assert FAIL: ship_captain_assignments.station column missing'; end if;
  select count(*) into n from pg_indexes
    where schemaname = 'public' and indexname = 'ship_captain_assignments_one_station_per_ship'
      and indexdef ilike '%where (station is not null)%';
  if n <> 1 then raise exception 'DECKS self-assert FAIL: the (main_ship_id, station) partial unique index is missing/unpartial'; end if;

  -- 3. NEW identities exist; OLD identities are GONE (drop-then-create really replaced, never
  --    overloaded — an ambiguous pair would break every positional caller).
  if to_regprocedure('public.captain_assign_apply(uuid, uuid, uuid, text)') is null then
    raise exception 'DECKS self-assert FAIL: captain_assign_apply(uuid,uuid,uuid,text) missing'; end if;
  if to_regprocedure('public.captain_assign_apply(uuid, uuid, uuid)') is not null then
    raise exception 'DECKS self-assert FAIL: the OLD captain_assign_apply(uuid,uuid,uuid) identity survives'; end if;
  if to_regprocedure('public.captain_execute_command(uuid, text, uuid, uuid, text, text)') is null then
    raise exception 'DECKS self-assert FAIL: captain_execute_command(...,text) missing'; end if;
  if to_regprocedure('public.captain_execute_command(uuid, text, uuid, uuid, text)') is not null then
    raise exception 'DECKS self-assert FAIL: the OLD captain_execute_command identity survives'; end if;
  if to_regprocedure('public.assign_captain_to_ship(text, uuid, uuid, text)') is null then
    raise exception 'DECKS self-assert FAIL: assign_captain_to_ship(text,uuid,uuid,text) missing'; end if;
  if to_regprocedure('public.assign_captain_to_ship(text, uuid, uuid)') is not null then
    raise exception 'DECKS self-assert FAIL: the OLD assign_captain_to_ship identity survives'; end if;
  -- the untouched wrapper keeps its 0120 identity (late-binds onto the defaulted command):
  if to_regprocedure('public.unassign_captain_from_ship(text, uuid)') is null then
    raise exception 'DECKS self-assert FAIL: unassign_captain_from_ship(text,uuid) missing'; end if;

  -- 4. writer prosrc: the marked hunks are present; the old-head fingerprints are NOT; no
  --    randomness anywhere in the resolution.
  select prosrc into v_src from pg_proc where oid = 'public.captain_assign_apply(uuid, uuid, uuid, text)'::regprocedure;
  if v_src not like '%DECKS-1%' then
    raise exception 'DECKS self-assert FAIL: writer lacks the DECKS-1 marked hunks'; end if;
  if v_src not like '%unknown_station%' or v_src not like '%station_occupied%' or v_src not like '%no_free_station%' then
    raise exception 'DECKS self-assert FAIL: writer lacks a station reject reason'; end if;
  if v_src not like '%order by s.sort%' then
    raise exception 'DECKS self-assert FAIL: writer auto-assign lost the lowest-sort determinism'; end if;
  -- the 0119 old-head fingerprint: the station-less VALUES clause `..., p_player_id);` (the new
  -- clause ends `..., p_player_id, v_station);`; no other `p_player_id);` exists in either body —
  -- the step-3 comment's "(main_ship_id, player_id) PAIR" is deliberately not used, it survives
  -- verbatim in the new body).
  if v_src like '%p_player_id);%' then
    raise exception 'DECKS self-assert FAIL: writer still carries the old-head station-less insert'; end if;
  if v_src like '%random(%' then
    raise exception 'DECKS self-assert FAIL: writer contains random()'; end if;
  -- the pre-existing reject order survived (a coarse but honest pin: all five 0119 reasons remain):
  if v_src not like '%captain_not_owned%' or v_src not like '%ship_not_owned%'
     or v_src not like '%already_assigned%' or v_src not like '%captain_slots_full%'
     or v_src not like '%not_assigned%' then
    raise exception 'DECKS self-assert FAIL: writer lost a 0119 reject reason'; end if;

  -- 5. command prosrc: threads the station, reads it back, ships it in the envelope; translates
  --    the three new reasons; keeps the dark gate FIRST; no randomness.
  select prosrc into v_src from pg_proc where oid = 'public.captain_execute_command(uuid, text, uuid, uuid, text, text)'::regprocedure;
  if v_src not like '%DECKS-1%' or v_src not like '%p_station%' then
    raise exception 'DECKS self-assert FAIL: command does not thread p_station'; end if;
  if v_src not like '%''station'', v_station%' then
    raise exception 'DECKS self-assert FAIL: command envelope lacks the station key'; end if;
  if v_src not like '%''unknown_station'',''station_occupied'',''no_free_station''%' then
    raise exception 'DECKS self-assert FAIL: command does not translate the station reasons'; end if;
  -- gate-first pin: the flag check must precede the receipt READ (the `from` clause — the
  -- declare-block %rowtype mention sits before both and must not satisfy this).
  if position('captain_assignment_enabled' in v_src) > position('from captain_assignment_receipts' in v_src) then
    raise exception 'DECKS self-assert FAIL: command dark gate no longer precedes the receipt read'; end if;
  if v_src like '%random(%' then
    raise exception 'DECKS self-assert FAIL: command contains random()'; end if;

  -- 6. wrapper + mapper + read-surface prosrc pins.
  select prosrc into v_src from pg_proc where oid = 'public.assign_captain_to_ship(text, uuid, uuid, text)'::regprocedure;
  if v_src not like '%p_station%' or v_src not like '%captain_assignment_disabled%' then
    raise exception 'DECKS self-assert FAIL: assign wrapper lost the station thread or its dark gate'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.captain_command_client_envelope(jsonb)'::regprocedure;
  if v_src not like '%unknown_station%' or v_src not like '%station_occupied%' or v_src not like '%no_free_station%' then
    raise exception 'DECKS self-assert FAIL: envelope mapper lacks a station entry'; end if;
  select prosrc into v_src from pg_proc where oid = 'public.get_my_captain_instances()'::regprocedure;
  if v_src not like '%''station''%' or v_src not like '%a.station%' then
    raise exception 'DECKS self-assert FAIL: roster read lacks the station projection'; end if;

  -- 7. ACLs on the re-created identities (client wrappers authenticated-only; internals
  --    service_role-only — the 0119/0120/0121 postures re-verified).
  if not has_function_privilege('authenticated', 'public.assign_captain_to_ship(text, uuid, uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.assign_captain_to_ship(text, uuid, uuid, text)', 'execute') then
    raise exception 'DECKS self-assert FAIL: assign wrapper ACL wrong'; end if;
  if has_function_privilege('authenticated', 'public.captain_assign_apply(uuid, uuid, uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.captain_assign_apply(uuid, uuid, uuid, text)', 'execute') then
    raise exception 'DECKS self-assert FAIL: writer is client-executable'; end if;
  if has_function_privilege('authenticated', 'public.captain_execute_command(uuid, text, uuid, uuid, text, text)', 'execute')
     or has_function_privilege('anon', 'public.captain_execute_command(uuid, text, uuid, uuid, text, text)', 'execute') then
    raise exception 'DECKS self-assert FAIL: private command is client-executable'; end if;

  -- 8. backfill completeness: NO station-less assignment rows remain. The headcount cap
  --    (count ≤ captain_slots = 6 = the catalog size) means every ranked row matched a station;
  --    a surviving null would mean a ship somehow held MORE assignments than stations — a state
  --    the 0119 writer cannot produce, so it is a hard failure, not a documented remainder.
  select count(*) into n from public.ship_captain_assignments where station is null;
  if n <> 0 then
    raise exception 'DECKS self-assert FAIL: % assignment row(s) left station-less by the backfill', n; end if;

  raise notice 'DECKS-0+1 self-asserts ok: 6-station catalog verbatim; station column + partial unique; 5 functions on their new heads (old identities gone, marked hunks pinned, no random()); backfill complete';
end $$;
