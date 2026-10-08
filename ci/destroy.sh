#!/usr/bin/env bash
# =============================================================================
# ci/destroy.sh
#
# WHAT
#   Deletes a deployed unit. The CloudFormation equivalent of `terraform destroy`.
#
# USAGE
#   bash ci/destroy.sh <unit-config.yaml> [options]
#
#   # 1. See what would be deleted. This is the default - nothing is destroyed.
#   bash ci/destroy.sh tier0-networking/vpc/config/test-use1.yaml
#
#   # 2. Actually delete it.
#   bash ci/destroy.sh tier0-networking/vpc/config/test-use1.yaml --execute
#
#   Options:
#     --execute               really delete. Without it, nothing is destroyed.
#     --target-profile NAME   AWS profile for the account holding the stack
#     --no-wait               return immediately instead of waiting for completion
#
# HOW IT WORKS
#   Deleting the root stack deletes every nested stack inside it. There is no
#   need to delete the 18 module stacks individually, and you should not try -
#   CloudFormation works out the dependency order, which is the whole point.
#
#   The unit's config is read only to work out the stack name, the region and
#   the account. Nothing is fetched and no modules are needed.
#
# =============================================================================
# READ THIS BEFORE USING IT IN ANYTHING THAT IS NOT A SANDBOX
#
# 1. DELETION IS NOT ALWAYS COMPLETE.
#    A resource with `DeletionPolicy: Retain` survives, on purpose. The s3
#    module sets it, so buckets are kept while the stack around them goes.
#    The stack disappears from CloudFormation and the bucket stays, now managed
#    by nobody. Redeploying then fails on the existing bucket name.
#
# 2. A VPC WILL NOT DELETE IF ANYTHING IS STILL IN IT.
#    Anything created outside this stack - a Lambda ENI, a manually launched
#    instance, an RDS subnet group - blocks deletion of the subnet or VPC. The
#    failure names the resource, but it is a slow way to find out.
#
# 3. HIGHER TIERS BREAK SILENTLY.
#    Tiers 1-3 read this stack's outputs with Fn::GetStackOutput. That is a weak
#    reference: deleting the producer is NOT blocked, and the consumer only
#    fails on its next operation - possibly weeks later. Check what depends on
#    this before deleting it.
#
# 4. NAT GATEWAYS ARE SLOW. Expect several minutes.
# =============================================================================

set -euo pipefail

CONFIG_IN="${1:?usage: destroy.sh <unit-config.yaml> [--execute]}"
shift

EXECUTE=0
WAIT=1
TARGET_PROFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --execute)        EXECUTE=1 ;;
    --no-wait)        WAIT=0 ;;
    --target-profile) TARGET_PROFILE="${2:?--target-profile needs a value}"; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/ci/lib/modules.sh"

# wait_for_stack and stack_console_url. Read that file before changing the
# waiting below - it documents why `aws cloudformation wait` is not used.
source "${REPO_ROOT}/ci/lib/stack-wait.sh"

CONFIG="$(resolve_config_path "$CONFIG_IN" "$REPO_ROOT")"
cd "$REPO_ROOT"

TGT_ARGS=(); [ -n "$TARGET_PROFILE" ] && TGT_ARGS=(--profile "$TARGET_PROFILE")

REGION="$(cfg_get "$CONFIG" region)"
TARGET_ACCOUNT="$(cfg_get "$CONFIG" accountId)"
STACK_NAME="$(python ci/render-config.py "$CONFIG" --emit stack-name)"

# The same role CloudFormation used to create the resources must be used to
# delete them. Without it CloudFormation uses your own credentials, which may
# not have the permissions the execution role had.
EXECUTION_ROLE="${EXECUTION_ROLE:-arn:aws:iam::${TARGET_ACCOUNT}:role/stadion-cfn-execution-role}"

# Same account check as package-and-deploy.sh. Deleting also passes the
# execution role, and PassRole does not cross an account boundary.
CALLER_ACCOUNT="$(aws "${TGT_ARGS[@]}" sts get-caller-identity \
  --query Account --output text </dev/null | tr -d '\r')"

if [ "$CALLER_ACCOUNT" != "$TARGET_ACCOUNT" ]; then
  echo "ERROR: you are in the wrong account for this stack." >&2
  echo "  config accountId:  ${TARGET_ACCOUNT}" >&2
  echo "  your credentials:  ${CALLER_ACCOUNT}" >&2
  echo "  profile in use:    ${TARGET_PROFILE:-<none - ambient credentials>}" >&2
  echo >&2
  echo "  Re-run with --target-profile <profile for ${TARGET_ACCOUNT}>." >&2
  exit 1
fi

echo "=== destroy ${STACK_NAME} ==="
echo "  config:          ${CONFIG}"
echo "  region:          ${REGION}"
echo "  target account:  ${TARGET_ACCOUNT}"
echo "  execution role:  ${EXECUTION_ROLE}"
echo "  mode:            $([ "$EXECUTE" -eq 1 ] && echo 'EXECUTE - resources WILL be deleted' || echo 'dry run - nothing deleted')"
echo


# --- does it exist? ----------------------------------------------------------
if ! STATUS="$(aws "${TGT_ARGS[@]}" cloudformation describe-stacks \
      --region "$REGION" --stack-name "$STACK_NAME" \
      --query 'Stacks[0].StackStatus' --output text </dev/null 2>/dev/null | tr -d '\r')"; then
  echo "Stack ${STACK_NAME} does not exist in ${TARGET_ACCOUNT} / ${REGION}."
  echo "Nothing to delete."
  exit 0
fi

echo "Current status: ${STATUS}"

# A dry run of package-and-deploy.sh leaves a stack in REVIEW_IN_PROGRESS: the
# change set was created but never executed, so no resources exist. Deleting it
# is safe and is how you clear one out.
if [ "$STATUS" = "REVIEW_IN_PROGRESS" ]; then
  echo "  (this stack holds no resources - it is a change set that was never executed)"
fi
echo


# --- what is in it? ----------------------------------------------------------
# Walk the nested stacks so the list shows real resources rather than 18 rows of
# AWS::CloudFormation::Stack.
list_resources() {
  local stack="$1" depth="$2" rows line rtype lid pid prefix

  rows="$(aws "${TGT_ARGS[@]}" cloudformation list-stack-resources \
    --region "$REGION" --stack-name "$stack" \
    --query 'StackResourceSummaries[].[ResourceType,LogicalResourceId,PhysicalResourceId]' \
    --output text </dev/null 2>/dev/null)" || return 0

  rows="${rows//$'\r'/}"
  [ -z "$rows" ] && return 0

  # mapfile first: a command inside `while read` inherits the loop's stdin and
  # consumes it, so the loop would stop after the first row.
  local -a lines
  mapfile -t lines <<< "$rows"

  for line in "${lines[@]}"; do
    [ -z "$line" ] && continue
    IFS=$'\t' read -r rtype lid pid <<< "$line"

    prefix="$(printf '%*s' $((depth * 2)) '')"

    if [ "$rtype" = "AWS::CloudFormation::Stack" ]; then
      printf '  %s%-38s %s\n' "$prefix" "$rtype" "$lid"
      [ -n "${pid:-}" ] && [ "$pid" != "None" ] && list_resources "$pid" $((depth + 1))
    else
      printf '  %s%-38s %-28s %s\n' "$prefix" "$rtype" "$lid" "${pid:-}"
    fi
  done
}

echo "Resources that would be deleted:"
list_resources "$STACK_NAME" 0
echo


# --- retained resources ------------------------------------------------------
# Scan the local templates rather than the deployed stack, because CloudFormation
# does not report DeletionPolicy through the API.
UNIT_DIR="$(dirname "$(dirname "$CONFIG")")"
RETAINED="$(grep -rl 'DeletionPolicy: Retain' "${UNIT_DIR}/main.yaml" modules/ 2>/dev/null || true)"
if [ -n "$RETAINED" ]; then
  echo "NOT deleted - these templates set DeletionPolicy: Retain:"
  printf '  %s\n' $RETAINED
  echo "  Those resources survive the stack. Redeploying can then fail on a name"
  echo "  collision until they are removed by hand."
  echo
fi


# --- do it -------------------------------------------------------------------
if [ "$EXECUTE" -eq 0 ]; then
  echo "DRY RUN - nothing was deleted."
  echo "Re-run with --execute to delete ${STACK_NAME}."
  exit 0
fi

echo "Deleting ${STACK_NAME}..."
aws "${TGT_ARGS[@]}" cloudformation delete-stack \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --role-arn "$EXECUTION_ROLE"

if [ "$WAIT" -eq 0 ]; then
  echo "Deletion started. Not waiting (--no-wait)."
  exit 0
fi

# Deleting is often SLOWER than creating. NAT gateways are minutes; an RDS
# cluster whose DeletionPolicy is Snapshot has to take that final snapshot
# before it can go, and the snapshot is sized by the data in the cluster.
echo "Waiting for deletion to finish (budget ${STACK_WAIT_MINUTES}m)."

set +e
wait_for_stack delete "$STACK_NAME"
WAIT_RESULT=$?
set -e

case "$WAIT_RESULT" in

  0)
    echo
    echo "PASS - ${STACK_NAME} deleted."
    ;;

  2)
    # Still deleting. Saying "deletion did not complete" here would be wrong
    # in a way that invites someone to go and delete things by hand.
    echo >&2
    echo "TIMED OUT WAITING - the deletion is STILL RUNNING." >&2
    echo >&2
    echo "  ${STACK_NAME} is ${STACK_WAIT_FINAL_STATUS} after ${STACK_WAIT_MINUTES} minutes." >&2
    echo "  NOTHING HAS FAILED. Do not start deleting resources by hand - that" >&2
    echo "  is how a stack ends up DELETE_FAILED on something it no longer owns." >&2
    echo >&2
    echo "  Watch it:  $(stack_console_url "$STACK_NAME")" >&2
    echo >&2
    echo "  A database with a large final snapshot is the usual reason. Raise" >&2
    echo "  the budget if you expect it:" >&2
    echo "    STACK_WAIT_MINUTES=240 bash ci/destroy.sh ${CONFIG} --execute" >&2
    exit 1
    ;;

  *)
    echo >&2
    echo "ERROR: deletion did not complete - ${STACK_NAME} is ${STACK_WAIT_FINAL_STATUS}." >&2
    echo "The usual cause is a resource something outside this stack is still using" >&2
    echo "- a Lambda ENI in a subnet, a manually created instance, an RDS subnet" >&2
    echo "group. CloudFormation names it in the events below." >&2
    echo >&2
    aws "${TGT_ARGS[@]}" cloudformation describe-stack-events \
      --region "$REGION" --stack-name "$STACK_NAME" \
      --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
      --output text </dev/null 2>/dev/null | sed 's/^/  /' >&2 || true
    echo >&2
    echo "  Full history:  $(stack_console_url "$STACK_NAME")" >&2
    exit 1
    ;;
esac
