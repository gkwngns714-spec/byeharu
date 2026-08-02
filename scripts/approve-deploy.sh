#!/usr/bin/env bash
# Approve the pending `production` migration deploy for byeharu.
#
# WHY THIS EXISTS: the assistant is blocked by its safety classifier from approving a
# production deployment, so the owner runs this. It finds the halted deploy run and shows
# exactly WHAT it would deploy. Nothing is approved unless you pass --yes.
#
# Usage (run from anywhere; the `!` shell's cwd is not the repo):
#   bash /c/Users/gkwng/dev/byeharu/scripts/approve-deploy.sh          # dry run: show, approve nothing
#   bash /c/Users/gkwng/dev/byeharu/scripts/approve-deploy.sh --yes    # actually approve
set -euo pipefail

REPO="gkwngns714-spec/byeharu"
WF="deploy-migrations.yml"

# Run from anywhere: this script is invoked via `!` from a shell whose cwd is NOT the repo.
# Every gh call passes --repo, and the one git call below is anchored here.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Looking for a halted production deploy on $REPO ..."

# Pick the NEWEST unfinished run (sort_by createdAt, take last) — NOT [0]. Migration merges stack
# multiple halted deploy runs at the gate; the newest commit's run pushes ALL unapplied migrations
# idempotently (supabase db push), so approving it advances prod the furthest in one go. Grabbing an
# older run (the original [0] bug) deploys a stale commit and leaves prod behind its own main.
#
# The filter is `status != "completed"`, NOT an allowlist of statuses. It WAS an allowlist
# (waiting/queued/in_progress) and that re-created the very bug the paragraph above describes:
# on 2026-08-02 the run carrying 0310+0311+0312 sat at status **"pending"** — held by the
# `prod-migrations-deploy` concurrency group behind an older run — so the allowlist skipped it and
# this script offered the older commit, which carried only 0310. Approving that would have deployed
# one migration and left prod behind main. GitHub's status vocabulary is open-ended (pending,
# requested, action_required, …); enumerating the live ones is a losing game, so enumerate the one
# terminal one instead. `completed` covers success, failure and cancelled alike.
RUN_ID="$(gh run list --repo "$REPO" --workflow "$WF" --limit 20 \
  --json databaseId,status,headSha,createdAt \
  -q '[.[] | select(.status != "completed")] | sort_by(.createdAt) | last | .databaseId' 2>/dev/null || true)"

if [ -z "${RUN_ID:-}" ] || [ "$RUN_ID" = "null" ]; then
  echo
  echo "No unfinished deploy run found."
  echo "  - If you have not merged the migration PR yet, merge it first; the deploy only starts on a push to main."
  echo "  - If you just merged, wait ~20s for GitHub to register the run and re-run this script."
  exit 1
fi

# A run held behind the concurrency group has NO pending_deployments yet — there is nothing to
# approve until GitHub actually starts its job. Detect that here and say what to do, rather than
# falling back to an older run (which is exactly how a stale commit gets deployed).
if ! gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" -q '.[0].environment.id' >/dev/null 2>&1 \
   || [ -z "$(gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" -q '.[0].environment.id' 2>/dev/null)" ]; then
  BLOCKERS="$(gh run list --repo "$REPO" --workflow "$WF" --limit 20 \
    --json databaseId,status,headSha,createdAt \
    -q "[.[] | select(.status != \"completed\") | select(.databaseId != $RUN_ID)] | sort_by(.createdAt) | .[] | \"  run \(.databaseId)  status=\(.status)  sha=\(.headSha[0:7])\"" 2>/dev/null || true)"
  if [ -n "$BLOCKERS" ]; then
    echo
    echo "The newest deploy run ($RUN_ID) has not reached the approval gate yet — it is queued behind"
    echo "the \`prod-migrations-deploy\` concurrency group. Older unfinished runs holding the group:"
    echo "$BLOCKERS"
    echo
    echo "Those older runs deploy a STRICT SUBSET of the newest commit (db push is idempotent and the"
    echo "newest commit contains every earlier migration), so cancelling them loses nothing and lets"
    echo "the newest run reach the gate. Cancel them, wait ~20s, then re-run this script:"
    echo "$BLOCKERS" | sed "s#  run \([0-9]*\).*#  gh run cancel \1 --repo $REPO#"
    exit 1
  fi
fi

echo "Found run $RUN_ID"
echo

# Show what is actually pending approval, and which environment is asking.
gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" \
  -q '.[] | "PENDING ENVIRONMENT: \(.environment.name)  (id \(.environment.id))\nCan approve: \(.current_user_can_approve)\nWait timer: \(.wait_timer) min"' || {
    echo "That run has no pending deployment — it may already be approved or finished."
    gh run view "$RUN_ID" --repo "$REPO" | head -20
    exit 1
  }

ENV_ID="$(gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" -q '.[0].environment.id')"
HEAD_SHA="$(gh run view "$RUN_ID" --repo "$REPO" --json headSha -q .headSha)"

echo
echo "Commit being deployed: $HEAD_SHA"
echo
# Show the migrations IN THE COMMIT BEING DEPLOYED (git ls-tree of $HEAD_SHA) — NOT a local `ls`,
# which lists whatever is checked out and misleads when the deployed commit is older than main.
# supabase db push is idempotent: it applies every migration in this commit not yet in prod.
echo "Migrations present in the commit being deployed ($HEAD_SHA) — db push applies any not yet in prod:"
git -C "$REPO_DIR" ls-tree --name-only "$HEAD_SHA" supabase/migrations/ 2>/dev/null | sed 's#.*/#  #' | tail -12 \
  || echo "  (could not read the commit's tree; verify prod head after the deploy)"
echo
# CONFIRMATION: an explicit --yes flag, NOT an interactive prompt.
# `read -p` was the first design and it was wrong: this script is invoked from a
# NON-INTERACTIVE `!` shell with no terminal to read from, so the prompt could never
# be answered. A flag keeps the same property (nothing is approved by accident, and
# a bare run is always safe) while actually working in the shell that runs it.
if [ "${1:-}" != "--yes" ]; then
  echo "DRY RUN — nothing approved."
  echo
  echo "The above is what WOULD be deployed to production. To actually approve, re-run with --yes:"
  echo "  bash $REPO_DIR/scripts/approve-deploy.sh --yes"
  exit 0
fi

gh api -X POST "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" \
  -F "environment_ids[]=$ENV_ID" \
  -f state=approved \
  -f comment="Approved by owner: production migration deploy of commit ${HEAD_SHA}." \
  >/dev/null

echo
echo "Approved. Watching the deploy ..."
gh run watch "$RUN_ID" --repo "$REPO" --exit-status \
  && echo "DEPLOY SUCCEEDED. This pushed commit ${HEAD_SHA}. If more migration merges are still queued at the gate, run this again to advance further. VERIFY the real prod migration head before trusting it — do not assume." \
  || { echo "DEPLOY FAILED — logs:"; gh run view "$RUN_ID" --repo "$REPO" --log-failed | tail -30; exit 1; }
