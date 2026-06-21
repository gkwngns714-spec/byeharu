-- OSN-3 S1 — DISPOSABLE proof of the fleets.main_ship_id write-once trigger + the planned FK
-- delete-action graph. Runs on an EPHEMERAL postgres:15 container (NOT Supabase, NOT main).
--
-- It reproduces the EXACT relational shapes + delete actions + trigger logic planned for the S1
-- migration (0055), using plain stand-in tables (no Supabase auth/RLS dependency — those are proven
-- separately on the real DB post-deploy). The point is to prove, on the real PostgreSQL engine, that:
--   (a) the write-once trigger rejects reassignment / late-attach / ordinary detach;
--   (b) ON DELETE SET NULL runs AFTER the parent main_ship_instances row is deleted, so the trigger's
--       NOT EXISTS sees no parent and ALLOWS the orphaning (cleanup paths keep working);
--   (c) the cyclic fleets <-> main_ship_space_movements FK graph deletes cleanly (no assumed order);
--   (d) deleting a user (cascade) and deleting a ship clean up all child rows with no orphan pointers.
--
-- Any assertion failure raises and (with ON_ERROR_STOP) fails the CI job. Whole script is one
-- transaction, rolled back at the end → fully disposable.

\set ON_ERROR_STOP on
begin;

create extension if not exists pgcrypto;

-- ── Stand-in schema: same FK actions as the planned 0055 graph ────────────────────────────────
create table users_stub (id uuid primary key default gen_random_uuid());

create table main_ship_instances (
  main_ship_id uuid primary key default gen_random_uuid(),
  player_id    uuid not null references users_stub(id) on delete cascade   -- mirrors 0043
);

create table fleets (
  id                       uuid primary key default gen_random_uuid(),
  player_id                uuid not null references users_stub(id) on delete cascade,        -- mirrors 0006
  main_ship_id             uuid references main_ship_instances(main_ship_id) on delete set null, -- mirrors 0050 (UNCHANGED)
  active_space_movement_id uuid                                                              -- FK added below (cycle)
);

create table main_ship_space_movements (
  id           uuid primary key default gen_random_uuid(),
  main_ship_id uuid not null references main_ship_instances(main_ship_id) on delete cascade,
  fleet_id     uuid not null references fleets(id) on delete cascade,
  player_id    uuid not null references users_stub(id) on delete cascade,
  status       text not null default 'moving'
);

-- The cycle: fleets.active_space_movement_id -> main_ship_space_movements.id (SET NULL on movement delete).
-- DEFERRABLE INITIALLY DEFERRED: makes the cyclic fleets<->movements graph order-independent — during a
-- ship delete that cascade-deletes the movement while the fleet survives, the FK check defers to COMMIT
-- (after the SET NULL settles), so a transient dangling pointer mid-cascade is tolerated.
alter table fleets
  add constraint fleets_active_space_movement_fk
  foreign key (active_space_movement_id) references main_ship_space_movements(id)
  on delete set null deferrable initially deferred;

create table main_ship_space_command_receipts (
  id           uuid primary key default gen_random_uuid(),
  main_ship_id uuid not null references main_ship_instances(main_ship_id) on delete cascade,
  player_id    uuid not null references users_stub(id) on delete cascade,
  movement_id  uuid references main_ship_space_movements(id) on delete set null,
  request_id   uuid not null
);

-- ── The write-once trigger (EXACT planned logic) ──────────────────────────────────────────────
create function fleets_main_ship_id_write_once() returns trigger
language plpgsql as $fn$
begin
  if new.main_ship_id is distinct from old.main_ship_id then
    -- allow ONLY parent-deletion orphaning: non-null -> NULL while the referenced ship is already gone
    if not (old.main_ship_id is not null
            and new.main_ship_id is null
            and not exists (select 1 from main_ship_instances m where m.main_ship_id = old.main_ship_id)) then
      raise exception 'fleets.main_ship_id is write-once; reassignment, late attachment, and ordinary detach are forbidden';
    end if;
  end if;
  return new;
end $fn$;

create trigger fleets_main_ship_id_write_once_trg
  before update of main_ship_id on fleets
  for each row execute function fleets_main_ship_id_write_once();

-- ── Proof ─────────────────────────────────────────────────────────────────────────────────────
do $proof$
declare
  v_u uuid; v_u2 uuid; v_a uuid; v_b uuid; v_f uuid; v_f0 uuid; v_m uuid; v_cnt int; v_link uuid; caught boolean;
begin
  insert into users_stub default values returning id into v_u;
  insert into users_stub default values returning id into v_u2;
  insert into main_ship_instances(player_id) values (v_u) returning main_ship_id into v_a;
  insert into main_ship_instances(player_id) values (v_u) returning main_ship_id into v_b;
  insert into fleets(player_id, main_ship_id) values (v_u, v_a) returning id into v_f;

  -- TEST 1: NULL -> non-NULL (late attach) is REJECTED
  insert into fleets(player_id, main_ship_id) values (v_u, null) returning id into v_f0;
  caught := false;
  begin update fleets set main_ship_id = v_a where id = v_f0; exception when others then caught := true; end;
  if not caught then raise exception 'TEST1 FAIL: NULL->non-NULL (late attach) was allowed'; end if;
  raise notice 'TEST1 ok: late-attach rejected';

  -- TEST 2: ship A -> ship B (reassignment) is REJECTED
  caught := false;
  begin update fleets set main_ship_id = v_b where id = v_f; exception when others then caught := true; end;
  if not caught then raise exception 'TEST2 FAIL: reassignment A->B was allowed'; end if;
  raise notice 'TEST2 ok: reassignment rejected';

  -- TEST 3: ship A -> NULL while A STILL EXISTS (ordinary detach) is REJECTED
  caught := false;
  begin update fleets set main_ship_id = null where id = v_f; exception when others then caught := true; end;
  if not caught then raise exception 'TEST3 FAIL: ordinary detach (ship still exists) was allowed'; end if;
  raise notice 'TEST3 ok: ordinary detach rejected';

  -- sanity: same-value update is allowed (no change)
  update fleets set main_ship_id = v_a where id = v_f;
  raise notice 'sanity ok: same-UUID update allowed';

  -- TEST 4 + 5: DIRECT delete of referenced ship A SUCCEEDS, and the FK SET NULL runs AFTER the
  -- parent is gone so the trigger ALLOWS it → surviving fleet ends with main_ship_id = NULL.
  delete from main_ship_instances where main_ship_id = v_a;
  select main_ship_id into v_link from fleets where id = v_f;
  if v_link is not null then raise exception 'TEST5 FAIL: fleet.main_ship_id not nulled after ship delete (got %)', v_link; end if;
  raise notice 'TEST4/5 ok: ship delete succeeded; FK SET NULL fired AFTER parent gone; fleet orphaned to NULL';

  -- TEST 6: child cascade cleanup — rebuild a full graph then delete the USER, expect full cleanup.
  insert into main_ship_instances(player_id) values (v_u2) returning main_ship_id into v_a;
  insert into fleets(player_id, main_ship_id) values (v_u2, v_a) returning id into v_f;
  insert into main_ship_space_movements(main_ship_id, fleet_id, player_id) values (v_a, v_f, v_u2) returning id into v_m;
  update fleets set active_space_movement_id = v_m where id = v_f;
  insert into main_ship_space_command_receipts(main_ship_id, player_id, movement_id, request_id)
    values (v_a, v_u2, v_m, gen_random_uuid());
  delete from users_stub where id = v_u2;   -- cyclic fleets<->movements + ships + receipts all cascade
  select count(*) into v_cnt from fleets where player_id = v_u2;                       if v_cnt<>0 then raise exception 'TEST6 FAIL: fleets remain'; end if;
  select count(*) into v_cnt from main_ship_instances where player_id = v_u2;          if v_cnt<>0 then raise exception 'TEST6 FAIL: ships remain'; end if;
  select count(*) into v_cnt from main_ship_space_movements where player_id = v_u2;    if v_cnt<>0 then raise exception 'TEST6 FAIL: movements remain'; end if;
  select count(*) into v_cnt from main_ship_space_command_receipts where player_id = v_u2; if v_cnt<>0 then raise exception 'TEST6 FAIL: receipts remain'; end if;
  raise notice 'TEST6 ok: user delete cascaded cleanly through the cyclic FK graph (no orphans)';

  -- TEST 7: deleting a TERMINAL coordinate movement nulls fleets.active_space_movement_id (no invalid pointer).
  insert into main_ship_instances(player_id) values (v_u) returning main_ship_id into v_a;
  insert into fleets(player_id, main_ship_id) values (v_u, v_a) returning id into v_f;
  insert into main_ship_space_movements(main_ship_id, fleet_id, player_id, status) values (v_a, v_f, v_u, 'arrived') returning id into v_m;
  update fleets set active_space_movement_id = v_m where id = v_f;
  delete from main_ship_space_movements where id = v_m;
  select active_space_movement_id into v_link from fleets where id = v_f;
  if v_link is not null then raise exception 'TEST7 FAIL: active_space_movement_id not nulled after movement delete'; end if;
  raise notice 'TEST7 ok: deleting a movement nulled the fleet pointer (no invalid pointer)';

  -- TEST 8: deleting a SHIP cascades its movements/receipts and nulls fleet pointers (no partial residue).
  insert into main_ship_space_movements(main_ship_id, fleet_id, player_id) values (v_a, v_f, v_u) returning id into v_m;
  update fleets set active_space_movement_id = v_m where id = v_f;
  insert into main_ship_space_command_receipts(main_ship_id, player_id, movement_id, request_id) values (v_a, v_u, v_m, gen_random_uuid());
  delete from main_ship_instances where main_ship_id = v_a;
  select count(*) into v_cnt from main_ship_space_movements where main_ship_id = v_a;          if v_cnt<>0 then raise exception 'TEST8 FAIL: movements remain after ship delete'; end if;
  select count(*) into v_cnt from main_ship_space_command_receipts where main_ship_id = v_a;   if v_cnt<>0 then raise exception 'TEST8 FAIL: receipts remain after ship delete'; end if;
  select main_ship_id, active_space_movement_id into v_link, v_m from fleets where id = v_f; -- both should be NULL
  if (select main_ship_id from fleets where id = v_f) is not null then raise exception 'TEST8 FAIL: fleet.main_ship_id not nulled'; end if;
  if (select active_space_movement_id from fleets where id = v_f) is not null then raise exception 'TEST8 FAIL: fleet.active_space_movement_id not nulled'; end if;
  raise notice 'TEST8 ok: ship delete cascaded movements+receipts and nulled fleet pointers (no residue)';

  raise notice 'OSN-3 S1 TRIGGER/FK PROOF: ALL PASSED';
end
$proof$;

rollback;  -- disposable
