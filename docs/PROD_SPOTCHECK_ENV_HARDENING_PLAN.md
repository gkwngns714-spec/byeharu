# Production Live-Spotcheck Environment Hardening — Reconnaissance & Repair Plan (PLAN ONLY, rev. 3)

> **Status: PLANNING ONLY — local-only, code-free.** No code, commit, push, PR, secret change, environment
> policy change, production spotcheck run, OSN-DOCK-0 change, or PR #9 change. **rev. 3** makes `main`-only
> enforcement mandatory and dual, rewrites rollback as forward-fix, and adds the human-only prerequisite
> checklist. Awaiting the approval phrase (item 7) before any implementation.

**Goal:** gate the six live-spotcheck workflows behind the protected `production` Environment with mandatory
`main`-only execution, sourcing every **production-sensitive** credential from the Environment — then (Phase
B, separately authorized) retire only the three repository-scoped **deploy** secrets.

**In-scope files (exactly six):** `osn3-legacy-send-activation-check.yml`, `osn3-s2-live-spotcheck.yml`,
`osn3-s3-live-spotcheck.yml`, `osn3-s4-live-spotcheck.yml`, `osn3-s5-live-spotcheck.yml`,
`osn3-s6a-live-spotcheck.yml`. **Must NOT modify:** `deploy-migrations.yml`, application code, migrations,
OSN-DOCK-0, any secret, the `production` protection policy, feature flags, PR #9.

---

## 1. Exact job-level YAML change (each of the six)
The single `spotcheck` job gains **two** job-level keys — both required. **Nothing else changes** (no
`secrets.X` reference change, no step/trigger/concurrency/permission change, scripts untouched):

```yaml
jobs:
  spotcheck:
    runs-on: ubuntu-latest
    timeout-minutes: 12
    if: ${{ github.ref == 'refs/heads/main' }}   # ADDED — mandatory self-skip on any non-main ref
    environment: production                       # ADDED — normal env record + protection + approval
    steps:
      ...                                         # unchanged
```

- Use the **ordinary** `environment: production`. **Do NOT** set `deployment: false` or otherwise suppress
  the deployment/environment record — the Environment/deployment record is the desired **audit trail** that a
  production-protected job was approved and executed. (A spotcheck creating that record does **not** deploy
  the database.)
- Diff per file = **+2 job-level lines** (plus, if a YAML key-order tidy is needed, no semantic change).

---

## 2. `main`-only enforcement — mandatory and enforced in THREE layers
`workflow_dispatch` lets a user pick any ref, so main-only must **not** depend on the user's choice. Three
independent protections (all required):

| # | Protection | Where | Purpose |
|---|---|---|---|
| 1 | `environment: production` | each `spotcheck` job (this PR) | No production Environment secret is available until Environment protection rules + required-reviewer approval pass |
| 2 | Environment **deployment-branch restriction = `main` only** | `production` Environment (already configured) | GitHub-side rejection: a non-`main` ref cannot use the `production` Environment (job fails before any step; no secrets issued) |
| 3 | `if: ${{ github.ref == 'refs/heads/main' }}` | each `spotcheck` job (this PR) | **Required** defense-in-depth: the job self-skips before any step when a non-`main` ref is selected |

**Acceptance proof must show:**
- selected ref is **`main`**;
- the executed commit is **on `main`** (run `headSha` = `main` tip / ancestor of `main`);
- the **production Environment approval completed before Environment secrets were available** (job sat in
  `waiting`; approval event logged; only then did steps run);
- a **non-`main` dispatch cannot execute the `spotcheck` job or receive production Environment secrets**
  (proven by dispatching one spotcheck from a throwaway non-`main` ref → the job **self-skips via the `if`**
  and/or is **rejected by the Environment branch restriction**; no step runs, no secret issued). *(This is a
  control test of the gate, not a production spotcheck — it must not reach the read-only script.)*

---

## 3. Complete credential inventory + final Phase A disposition
Verified by grep across `.github/workflows/**`. Names/consumers only; no values.

| Credential | Consumers | Env copy? | Repo copy? | Phase A disposition |
|---|---|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | `deploy-migrations` (gated) + 6 spotchecks | ✅ | ✅ | **Source from `production` Env** (gated six). Repo copy retained in Phase A; **deletable in Phase B** (all consumers then gated). |
| `SUPABASE_PROJECT_ID` | `deploy-migrations` (gated) + 6 spotchecks | ✅ | ✅ | Same — env-sourced; repo copy **deletable in Phase B**. |
| `SUPABASE_DB_PASSWORD` | `deploy-migrations` (gated) + 6 spotchecks | ✅ | ✅ | Same — env-sourced; repo copy **deletable in Phase B**. |
| **`SUPABASE_SERVICE_ROLE_KEY`** (privileged server credential) | 6 spotchecks **+ 19 other ungated workflows** (`browser`, `browser-galaxy`, `db-cleanup`, `db-report`, `cleanup-m45-orphans`, `dev-clean-test-users`, `dev-commission-mainship`, `dev-destroy-mainship`, `dev-mainship-flag`, `dev-mainship-space-movement-flag`, `osn2-spatial-distribution`, `runtime-owners`, `verify-mainship-{send,move,repair,preview}`, `verify-osn2`, `verify-osn3-s1`, `verify-speed-resolver`) | **must exist (prereq)** | ✅ | **Source from `production` Env** for the gated six (Env copy is a hard prerequisite, §4). **Repo copy MUST remain** (19 ungated consumers) and **must NOT be deleted/rotated/renamed/changed** in this charter. Repo-scope retirement is **explicitly out of scope** (separate broader charter). |
| `VITE_SUPABASE_URL` | 6 + ~20 others (`pages`, `browser*`, `db-*`, `dev-*`, `verify-*`, `runtime-owners`) | ❌ | ✅ | **Public client configuration** (the `<ref>.supabase.co` URL, shipped to the browser as a `VITE_` var). **Not** a privileged server credential and **not** used as one by the six (scripts use it only for anon REST reads). **May remain repository-scoped** in Phase A; gated six read it from repo scope (F2). **Not equivalent to SERVICE_ROLE.** |
| `VITE_SUPABASE_ANON_KEY` | 6 + `browser*`, `pages`, `verify-mainship-*`, `verify-osn2`, `verify-osn3-s1`, `verify-speed-resolver` | ❌ | ✅ | **Public client configuration** (publishable anon key, designed to ship in the frontend, RLS-bounded). **Not** a privileged server credential; the six use it only for anon REST reads. **May remain repository-scoped** in Phase A. **Not equivalent to SERVICE_ROLE.** |

*(GitHub-behavior basis: a job declaring `environment: production` resolves `secrets.X` from the Env copy when
present, repo copy as fallback; repo-only secrets — the public `VITE_*` — still resolve in a gated job.)*

---

## 4. Human-only prerequisite checklist — `production` Environment credentials
Before Phase A implementation may begin, a human confirms **existence only** (do **not** read, print,
compare, expose, copy into chat, write into code, or write into docs) of these four under the `production`
Environment:

- [ ] `SUPABASE_ACCESS_TOKEN` — present
- [ ] `SUPABASE_PROJECT_ID` — present
- [ ] `SUPABASE_DB_PASSWORD` — present
- [ ] `SUPABASE_SERVICE_ROLE_KEY` — **present (hard prerequisite — the Env-scoped copy MUST exist before
      implementation begins)**

Rules:
- The repository-level `SUPABASE_SERVICE_ROLE_KEY` **must not be deleted, rotated, renamed, or changed** in
  this charter (19 other active consumers remain).
- `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` are **not** required in the Environment (public client config).
- **If any of the four required Environment secrets is absent → STOP before implementation.** Do **not**
  create or move a secret through code or automation; a human adds it via the GitHub Environment UI/CLI.

*(At this writing, a read-only names-only check shows `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`,
`SUPABASE_DB_PASSWORD` already present in `production`; `SUPABASE_SERVICE_ROLE_KEY` is **not yet** present —
so the human must add the Env-scoped SERVICE_ROLE copy before Phase A can start.)*

---

## 5. Chosen post-merge read-only smoke check (exactly one) — LOCKED via live reconciliation
**`osn3-s2-live-spotcheck`** (job `spotcheck`), dispatched once from `main`, explicitly approved.
- **Reconciled against observed live state (2026-06-22T04:41:19Z, anon REST GET): `mainship_send_enabled=false`,
  `mainship_space_movement_enabled=false`.** The six scripts split on the expected `send` value:
  `s2`/`s3` assert `send=false` (compatible); `legacy`/`s4`/`s5`/`s6a` assert `send=true` (**incompatible** →
  would red-fail).
- `osn3-s2-live-spotcheck.sh` asserts **both flags false** (inspect SQL `osn3-s2-live-inspect.sql:85-86`;
  REST `:75-76`), matching observed live → **passes green**.
- Strictly read-only (`migration list` / `db dump` / catalog `SELECT`s / REST reads; "NO mutation, NO flag
  change", header `:9`) and consumes **all four** protected credentials → one green run proves env-sourced
  resolution of ACCESS_TOKEN/PROJECT_ID/DB_PASSWORD/SERVICE_ROLE end-to-end.
- **Do NOT use `osn3-s6a-live-spotcheck` or `osn3-legacy-send-activation-check`** as the smoke: both assert
  `mainship_send_enabled=true` (s6a `osn3-s6a-live-check.sh:116,130`; legacy `osn3-legacy-send-live-check.sh:93,107`)
  while live is **`false`** → they red-fail on a stale state assertion unrelated to credentials.
- Do **not** dispatch the other five merely to validate the YAML change. *(`osn3-s3-live-spotcheck` is an
  equally-compatible fallback if S2 is ever unavailable.)*

---

## 6. Revised rollback procedure (forward-fix only)
Returning a spotcheck to an **ungated repository-secret path is FORBIDDEN** (it would reopen the bypass)
unless there is **separate, explicit emergency authorization**. If a post-merge protected spotcheck fails
because a required Environment secret is missing or an Environment setting is wrong:

1. **Stop the run.**
2. **Identify** the missing Environment secret or the incorrect Environment setting (e.g., branch
   restriction, reviewer, a typo'd Env secret value).
3. **Correct that Environment configuration through the approved human/admin path** (GitHub Environment
   settings — not via code/automation, no values in chat).
4. **Rerun from `main`** (re-dispatch; approve at the gate).

*(Because the workflow change is only the two added job-level lines, a pure git revert of the PR is available
as a code-rollback of the gating change itself — but that is a config rollback of the workflow edit, not a
return to an ungated production-credential path, which remains forbidden absent emergency authorization.)*

---

## Two-phase summary (for later, separate authorization)
- **Phase A — hardening:** (A0 human prereq §4: confirm the four Env secrets, incl. adding Env SERVICE_ROLE)
  → add the two job-level lines to the six (§1), `js-yaml`-validate, one PR, Build, admin-merge → acceptance =
  gate present in all six + consumer audit (zero ungated consumers of the three deploy secrets) + the §2
  control test + the one §5 smoke run. Rollback per §6.
- **Phase B — repo-secret retirement (separate authorization; THREE deploy secrets only):** fresh full
  consumer audit (ACCESS/PROJECT_ID/DB_PASSWORD all-gated) → human deletes those three repo copies → final
  read-only confirmation. **SERVICE_ROLE and `VITE_*` repo copies are NOT deleted.**

## Resolved decisions
- **D1 `main`-only:** mandatory, three-layer (§2), with the `if` guard **required**.
- **D2 approval:** all six gated; every dispatch requires approval; read-only does not exempt.
- **D3 validation depth:** config + consumer-audit primary; exactly one approved read-only smoke (§5); not all six.

---

## 7. Exact approval phrase required to start implementation
> **begin Production Live-Spotcheck Environment Hardening Phase A only**

Until that exact phrase is given: no code, commit, push, PR, secret change, environment-policy change,
production spotcheck run, OSN-DOCK-0 change, or PR #9 change. PR #9 remains frozen at `2961b61`; the pending
production deploy test run remains unapproved; repository-secret deletion remains BLOCKED.
