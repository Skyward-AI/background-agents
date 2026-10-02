#!/usr/bin/env bash
# Deploys the production Terraform environment from a saved, reviewed plan.
#
# `plan` builds the worker bundles, writes a timestamped plan to
# terraform/environments/production/plans/, and summarizes it. `apply` applies
# exactly that saved plan, so what gets deployed is what was reviewed. Plan files
# contain secrets in plain text; the plans/ directory is gitignored.
#
# Usage:
#   scripts/deploy.sh plan                 # build, plan, save, summarize
#   scripts/deploy.sh show [plan]          # summarize a saved plan (default: latest)
#   scripts/deploy.sh apply [plan]         # apply a saved plan (default: latest)
#   scripts/deploy.sh apply [plan] --allow-data-loss

# PLAN_FILE is set by resolve_plan.
# shellcheck disable=SC2153
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TF_DIR="$REPO_ROOT/terraform/environments/production"
PLANS_DIR="$TF_DIR/plans"
DEPLOY_BRANCH="skyward"

# Resources that hold data or key material. Replacing or destroying one loses
# what it stores (or makes stored ciphertext unreadable), so apply refuses such
# a plan unless --allow-data-loss is passed.
PROTECTED_TYPES="cloudflare_d1_database cloudflare_r2_bucket cloudflare_workers_kv_namespace cloudflare_queue random_password random_bytes"

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

check_checkout() {
  local branch
  branch="$(git -C "$REPO_ROOT" branch --show-current)"
  [[ "$branch" == "$DEPLOY_BRANCH" ]] || die "deploys run from $DEPLOY_BRANCH; current branch is '$branch'"
  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    die "working tree has uncommitted changes; deploy only committed code"
  fi
  git -C "$REPO_ROOT" fetch --quiet origin "$DEPLOY_BRANCH"
  if [[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" != "$(git -C "$REPO_ROOT" rev-parse "origin/$DEPLOY_BRANCH")" ]]; then
    die "local $DEPLOY_BRANCH differs from origin/$DEPLOY_BRANCH; pull or push first"
  fi
}

build() {
  info "Installing dependencies and building worker bundles"
  (
    cd "$REPO_ROOT"
    npm install --no-audit --no-fund --silent
    npm run build -w @open-inspect/shared
    npm run build -w @open-inspect/control-plane -w @open-inspect/slack-bot \
      -w @open-inspect/github-bot -w @open-inspect/linear-bot
  ) >/dev/null
}

# Prints each changed resource and its actions, then every protected resource
# the plan replaces or destroys. Exits 3 when there is at least one.
summarize() {
  local plan="$1"
  terraform -chdir="$TF_DIR" show -json "$plan" | PROTECTED_TYPES="$PROTECTED_TYPES" python3 -c "
import json, os, sys

plan = json.load(sys.stdin)
protected = set(os.environ[\"PROTECTED_TYPES\"].split())
changes = [
    r for r in plan.get(\"resource_changes\", [])
    if r[\"change\"][\"actions\"] not in ([\"no-op\"], [\"read\"])
]
if not changes:
    print(\"No changes.\")
risky = []
for r in changes:
    actions = r[\"change\"][\"actions\"]
    print(\"  %-14s %s\" % (\"/\".join(actions), r[\"address\"]))
    if r[\"type\"] in protected and \"delete\" in actions:
        risky.append(r[\"address\"])
if risky:
    print()
    print(\"!!! This plan REPLACES OR DESTROYS resources that hold data or keys:\")
    for address in risky:
        print(\"!!!   \" + address)
    sys.exit(3)
"
}

latest_plan() {
  local latest
  latest="$(find "$PLANS_DIR" -maxdepth 1 -name '*.tfplan' 2>/dev/null | sort | tail -n 1)"
  [[ -n "$latest" ]] || die "no saved plan in $PLANS_DIR; run '$0 plan' first"
  echo "$latest"
}

resolve_plan() {
  PLAN_FILE="${1:-$(latest_plan)}"
  [[ -f "$PLAN_FILE" ]] || die "plan file not found: $PLAN_FILE"
  PLAN_FILE="$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")"
}

cmd_plan() {
  check_checkout
  build
  if [[ ! -d "$TF_DIR/.terraform" ]]; then
    info "Initializing Terraform"
    terraform -chdir="$TF_DIR" init -input=false -backend-config=backend.tfvars >/dev/null
  fi
  mkdir -p "$PLANS_DIR"
  local name
  name="$(date +%Y%m%d-%H%M%S)-$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  local plan="$PLANS_DIR/$name.tfplan"
  info "Planning (log: plans/$name.plan.log)"
  terraform -chdir="$TF_DIR" plan -input=false -no-color -out="$plan" >"$PLANS_DIR/$name.plan.log" 2>&1 ||
    die "terraform plan failed; see $PLANS_DIR/$name.plan.log"
  terraform -chdir="$TF_DIR" show -no-color "$plan" >"$PLANS_DIR/$name.txt"
  echo
  grep -E '^(Plan:|No changes)' "$PLANS_DIR/$name.txt" || true
  local status=0
  summarize "$plan" || status=$?
  echo
  info "Saved plans/$name.tfplan (full text: plans/$name.txt)"
  if [[ "$status" -eq 3 ]]; then
    info "Review the flagged resources. To deploy anyway: $0 apply $plan --allow-data-loss"
  elif [[ "$status" -ne 0 ]]; then
    die "could not summarize the plan"
  else
    info "To deploy exactly this plan: $0 apply $plan"
  fi
}

cmd_show() {
  resolve_plan "${1:-}"
  info "$PLAN_FILE"
  summarize "$PLAN_FILE" || [[ $? -eq 3 ]]
}

cmd_apply() {
  local plan_arg="" allow_data_loss=false
  for arg in "$@"; do
    case "$arg" in
      --allow-data-loss) allow_data_loss=true ;;
      -*) die "unknown option: $arg" ;;
      *) plan_arg="$arg" ;;
    esac
  done
  check_checkout
  resolve_plan "$plan_arg"

  local status=0
  info "Applying $PLAN_FILE"
  summarize "$PLAN_FILE" || status=$?
  if [[ "$status" -eq 3 ]] && ! $allow_data_loss; then
    die "refusing to apply a plan that replaces or destroys data; pass --allow-data-loss after reviewing it"
  elif [[ "$status" -ne 0 && "$status" -ne 3 ]]; then
    die "could not summarize the plan"
  fi

  local log="${PLAN_FILE%.tfplan}.apply.log"
  # A saved plan only applies against the state it was made from; Terraform
  # rejects it as stale if anything changed since, and a new plan is needed.
  terraform -chdir="$TF_DIR" apply -input=false -no-color "$PLAN_FILE" 2>&1 | tee "$log"
  local apply_status="${PIPESTATUS[0]}"
  [[ "$apply_status" -eq 0 ]] || die "terraform apply failed; see $log"
  info "Deployed. Log: $log"
}

case "${1:-}" in
  plan) cmd_plan ;;
  show) shift; cmd_show "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  -h | --help | help | "") sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (try '$0 help')" ;;
esac
