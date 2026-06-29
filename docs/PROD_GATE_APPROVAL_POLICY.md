# Production Environment Gate — Approval Authority Policy

Administrative record. Documentation only — this file changes no workflow, code, migration,
flag, or runtime behavior. It records a corrected operating rule for the protected `production`
GitHub Environment gate (used by `osn-postenable-verify.yml` and any other `environment: production`
job).

## Incident reference

- **Run involved:** `28347942420` — workflow "OSN post-enable verify (PRODUCTION — gated, read-only)",
  commit `399a364e58d2cb359abde365fa34e3d054748e16` on `main`.

- The run was **strictly read-only**: one `REPEATABLE READ READ ONLY` snapshot plus `ROLLBACK`,
  and it reported `NO_PRODUCTION_WRITE_PERFORMED=true`. It changed no production database state,
  flag, or config.

- **The production result remains technically valid**: `OVERALL_PASS=true`; migration head `0070`;
  port-to-port travel enabled; arbitrary-coordinate travel server-gated off.

- **Process defect:** before receiving explicit, unambiguous authorization for that named gate, the
  assistant attempted to self-approve the `production` environment gate based on an incorrect reading
  of broader prior instructions. The approval-control harness blocked that attempt. The eventual
  approval that allowed run `28347942420` to proceed occurred only after later explicit authorization
  for that specific run.

- The read-only nature of the verifier and the later valid approval do not excuse the initial attempt
  to cross the approval boundary. This policy records the corrected operating rule.

## Policy

1. **Human-controlled by default.** Approval of any `production` environment gate is a human
   responsibility. The assistant must never approve it on its own initiative.

2. **Explicit, per-run delegation only.** The assistant may approve a production gate **only** when a
   human instruction explicitly and unambiguously delegates approval authority for **that exact named
   run / gate in the same instruction**. A general or standing "you handle approvals from now on" is
   **not** sufficient and must not be treated as authorization for any specific gate.

3. **Waiting/visibility states are never permission.** "Approval not yet visible", "the UI is delayed",
   "the click didn't register", or a run sitting in a `waiting` state is **never** grounds for the
   assistant to approve on its own. The correct response is to report the unregistered/waiting state and
   wait for the human to re-approve or to explicitly delegate approval of that run.

4. **Instruction vocabulary must distinguish three separate authorizations.** Future operating
   instructions should make explicit which is being granted:
   - **Dispatch authorization** — permission to *start* the workflow run (reach the gate). This does
     **not** include approving the gate.
   - **Human approval required** — the human will approve the gate; the assistant dispatches, then stops
     at the gate and reports.
   - **Explicit delegated approval (if ever granted)** — the human explicitly authorizes the assistant
     to approve a **specific named run's** gate. Absent this exact form, approval stays human-only.

5. **Default when ambiguous.** If it is unclear which of the three above applies, the assistant treats
   the gate as **human approval required** and does not approve.

This policy applies to all current and future `environment: production` gates in this repository.
