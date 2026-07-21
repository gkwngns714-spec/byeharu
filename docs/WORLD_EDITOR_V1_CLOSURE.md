# World Editor — Four-Domain Authoring V1: Closure Record

**Verdict: `WORLD EDITOR FOUR-DOMAIN AUTHORING V1: COMPLETE`** (2026-07-20).

This is a documentation-only closure record. It records the authoritative production state at
completion. It introduces no implementation, migration, workflow, feature-flag, or production change.

## Final production state

- **Production migration head: `0255`.**
- Location create / edit / unpublish — **live**.
- Mining create / edit / unpublish — **live**.
- Exploration create / edit / unpublish — **live**.
- Zone geometry authoring — **live**.
- Zone create — **live and production-proven**.
- Zone unpublish — **live and production-proven**.
- Owner authorization (`is_owner()` in-body) — **production-proven**.
- Idempotency (`world_editor_audit.request_id` ledger) — **production-proven**.
- Optimistic concurrency (`expected` fork-time snapshot compare) — **production-proven**.
- Audit before/after snapshots — **production-proven**.
- Player-active read isolation (flag + `status='active'` gating) — **production-proven**.
- Pirate interception status filtering (`status='active'` in the interception leaf) — **production-proven**.
- Direct client zone writes on `danger_zones` — **revoked**.
- Legacy pirate-zone RPCs (`pirate_zone_create` / `pirate_zone_delete`) — **client-revoked** (service_role only).
- Physical coordinate normalization (×17) — **held and NOT approved**.
- Inactive lifecycle-proof canary retained: **`af7f3455-94bf-4ccc-a943-8b0d1ab080d2`** (status `inactive`).

## Migrations, PRs, merge commits, and deploy runs

| Slice | Migration | PR | Merge commit | Deploy |
|---|---|---|---|---|
| Point-domain publish (exploration/mining/location create+edit+set-active) | `0244`,`0246`,`0247`,`0248`,`0249`,`0250`,`0252` | (earlier publish slices) | — | deployed |
| C1 display-adapter contract (client-only) | none | #249 | `ca2d491` | n/a |
| Zone create | `0254` | #248 | `ce5cd70` | run `29720884922` (success, prod head → 0254) |
| Zone create ACL fix (prod grant-drift) | `0254` (amended) | #250 | `2b4e215` | (same 0254 deploy above) |
| Zone unpublish | `0255` | #251 | `1ae80e8` | run `29726094426` (success, prod head → 0255) |
| Physical ×17 normalize (HELD) | `0253` | #245 | — | **held; never merged/deployed** |

Note: the first `0254` deploy attempt (run `29716996088`) fail-closed on the migration's own
self-assert — production `danger_zones` carried a Supabase project-default `GRANT ALL` that the
fresh-chain CI apply-proof never reproduced (a vacuous assert). PR #250 amended `0254` to REVOKE client
write before asserting it; production was never mutated by the failed attempt.

## Lifecycle proof result

Controlled production create→unpublish proof — **PASS**. Canary `CANARY-0255-LIVEPROOF`
(`af7f3455-94bf-4ccc-a943-8b0d1ab080d2`), drawn circle centre `(-900,-900)` r25, provably isolated
(nearest content 1100+ world units; zero unfinished movement legs). Owner create → active, in player
read, interception-relevant → owner unpublish → gone from player read AND interception, row retained
inert; **active window 529 ms**. With the canary inactive: create/unpublish replays idempotent (no
second row/audit); non-owner → `not_authorized`, anonymous → `not_authenticated` for both calls
(authorization precedes replay disclosure); seeded zones Blackden/Reaver/Snare rejected unpublish as
`not_unpublishable`/`protected_zone` and stayed active. Final: 4 zones (3 seeded active + 1 canary
inactive), exactly 1 `zone_create` + 1 `zone_unpublish` audit row (zero from rejected attempts). The
inert canary row is retained as the audit artifact (no direct SQL, no hard delete).

## Final privilege posture

- `zone_create` / `zone_unpublish`: `SECURITY DEFINER`, `search_path=''`, EXECUTE to `authenticated`
  only (anon/PUBLIC denied), owner enforced in-body.
- `danger_zones`: client `INSERT`/`UPDATE`/`DELETE` revoked; SELECT preserved; RLS enabled with only
  the `danger_zones_select_when_lit` (SELECT) policy — no write policy.
- `pirate_zone_create` / `pirate_zone_delete`: client-revoked; service_role retained.

## Final flag values

- `dev_zone_editor_enabled = true`
- `pirate_intercept_enabled = true`

## Known non-blocking observations

- The publish-command self-asserts verify `prosecdef` but not the function's own `SET search_path=''`
  (the body sets it; runtime is safe). Shared with the sibling slices `0250`/`0254` — not a regression.
- No `zone_republish` verb ships yet; the row is preserved, so republish is a future additive command
  (to be evaluated inside a unified recovery/revision model, not as an ad-hoc command).
- `danger_zones` retains `TRUNCATE`/`REFERENCES`/`TRIGGER` for anon/authenticated (Supabase default,
  matches sibling tables, not reachable via the PostgREST client API) — a future defense-in-depth
  cleanup candidate, out of V1 scope.

## Held coordinate-normalization decision

The physical ×17 DB normalize (`0253`, PR #245) is **held / not approved / historical research only**.
Migration slot `0253` remains intentionally reserved and absent from the deployed chain. The approved
direction is the C1 display-adapter contract (stored coordinates unchanged; editor view controlled by
typed display adapters + the camera).

## Next approved phase

**World Editor V1.5 — Operations & Audit UX** (read-only): make every World Editor command, target,
actor, request ID, revision, and before/after state inspectable from the owner interface. No new
production mutation command in this phase; `zone_republish` deferred to a later unified
recovery/revision model.
