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

RUN_ID="$(gh run list --repo "$REPO" --workflow "$WF" --limit 10 \
  --json databaseId,status,headSha,createdAt \
  -q '[.[] | select(.status=="waiting" or .status=="queued" or .status=="in_progress")][0].databaseId' 2>/dev/null || true)"

if [ -z "${RUN_ID:-}" ] || [ "$RUN_ID" = "null" ]; then
  echo
  echo "No waiting deploy run found."
  echo "  - If you have NOT merged PR #165 yet, merge it first; the deploy only starts on a push to main."
  echo "  - If you just merged, wait ~20s for GitHub to register the run and re-run this script."
  exit 1
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
echo "Migrations this deploy will apply to PRODUCTION (prod is currently at 0206):"
ls "$REPO_DIR/supabase/migrations" | sed -n '/000207/,$p' | sed 's/^/  /'
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
  -f comment="Approved by owner: movement-unification migrations 0207-0211 (FLEET-GO arc, PR #165)." \
  >/dev/null

echo
echo "Approved. Watching the deploy ..."
gh run watch "$RUN_ID" --repo "$REPO" --exit-status && echo "DEPLOY SUCCEEDED — prod migration head is now 0211." \
  || { echo "DEPLOY FAILED — logs:"; gh run view "$RUN_ID" --repo "$REPO" --log-failed | tail -30; exit 1; }
