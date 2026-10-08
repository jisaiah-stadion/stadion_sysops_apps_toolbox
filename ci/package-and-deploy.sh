#!/usr/bin/env bash
# =============================================================================
# ci/package-and-deploy.sh
#
# WHAT
#   Deploys one unit to one account and region.
#
# USAGE
#   bash ci/package-and-deploy.sh <unit-config.yaml> [options]
#
#   # 1. See what would change. This is the default - nothing is applied.
#   bash ci/package-and-deploy.sh tier0-networking/vpc/config/prod-use1.yaml
#
#   # 2. Apply it.
#   bash ci/package-and-deploy.sh tier0-networking/vpc/config/prod-use1.yaml --execute
#
#   Options:
#     --execute                 apply the change set instead of just showing it
#     --package-profile NAME    AWS profile for the DEPLOYMENT account
#     --target-profile NAME     AWS profile for the TARGET account
#     --delete-changeset        remove the change set after showing it
#
# WHY DRY RUN IS THE DEFAULT
#   This is the `terraform plan` / `terraform apply` split. Without --execute the
#   script builds a change set, prints what it would do, and stops. Adding
#   --execute is the moment you accept the change. `aws cloudformation deploy`
#   on its own applies immediately, which is the wrong default for infrastructure
#   you are deploying by hand. Nothing here changes anything without --execute.
#
# WHAT IT DOES, IN ORDER
#   1. Downloads the module library at the version the config pins.
#   2. Renders the config into a stack name, parameters and tags.
#   3. `aws cloudformation package` - uploads each nested module template to the
#      artifact bucket and rewrites the local paths into S3 URLs.
#   4. Checks the packaged template fits CloudFormation's inline size limit.
#   5. `create-change-set --include-nested-stacks` - works out what would change.
#   6. Prints those changes, expanded through every nested module.
#   7. `execute-change-set`, but only if you passed --execute.
#
# WHY NOT `aws cloudformation deploy`
#   It cannot pass --include-nested-stacks, so its change set shows 18 rows of
#   AWS::CloudFormation::Stack and nothing about what is inside them. "18 stacks
#   will be added" is not a plan you can review. Building the change set
#   directly costs a few more lines and shows the actual VPC, subnets, route
#   tables and NAT gateways.
#
# =============================================================================
# TWO ACCOUNTS ARE INVOLVED. This is the part that catches people out.
#
#   Step 3 (package) runs in the DEPLOYMENT account. It writes the module
#   templates into that account's artifact bucket.
#
#   Step 4 (deploy) runs in the TARGET account. It reads those templates back
#   out of the deployment account's bucket, cross-account, and passes
#   stadion-cfn-execution-role to CloudFormation to create the resources.
#
# So the two steps need different credentials, which is what --package-profile
# and --target-profile are for. In the sandbox they are often the same account,
# so --target-profile defaults to whatever --package-profile is.
#
# Use PROFILES, not `aws sts assume-role`. A profile with `role_arn` in
# ~/.aws/config lets the CLI refresh the credentials itself; assume-role hands
# you a token that expires mid-deploy and produces a confusing failure.
# =============================================================================

set -euo pipefail

CONFIG_IN="${1:?usage: package-and-deploy.sh <unit-config.yaml> [--execute]}"
shift

EXECUTE=0
DELETE_CHANGESET=0
PACKAGE_PROFILE=""
TARGET_PROFILE=""

# --execute-changeset NAME: execute a change set that ALREADY EXISTS, and do
# not create a new one.
#
# WHY THIS EXISTS - it is the whole point of an approval gate.
#
# Change sets here are named by timestamp, so running this script twice makes
# TWO different change sets. In a pipeline that splits "plan" and "apply" across
# a manual approval, re-running with --execute would create a second change set
# at apply time - so a reviewer would approve one plan and the pipeline would
# apply a different one. Same commit, so almost always identical. "Almost
# always" is not a property you want guarding production.
#
# With this option the apply step executes the exact change set whose diff was
# read and approved, by name.
EXECUTE_CHANGESET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --execute)          EXECUTE=1 ;;
    --delete-changeset) DELETE_CHANGESET=1 ;;
    --execute-changeset) EXECUTE_CHANGESET="${2:?--execute-changeset needs a change set name}"; shift ;;
    --package-profile)  PACKAGE_PROFILE="${2:?--package-profile needs a value}"; shift ;;
    --target-profile)   TARGET_PROFILE="${2:?--target-profile needs a value}"; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Mutually exclusive: one creates a change set and may execute it, the other
# executes one that exists. Accepting both would silently ignore one of them.
if [ -n "$EXECUTE_CHANGESET" ] && [ "$EXECUTE" -eq 1 ]; then
  echo "ERROR: --execute and --execute-changeset are mutually exclusive." >&2
  echo "  --execute              create a change set, then apply it" >&2
  echo "  --execute-changeset N  apply change set N, which already exists" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/ci/lib/modules.sh"

# wait_for_stack and stack_console_url. Read that file before changing any of
# the waiting below - it documents why `aws cloudformation wait` is not used,
# and the CodeBuild timeout it has to stay underneath.
source "${REPO_ROOT}/ci/lib/stack-wait.sh"

# Resolve the config before we cd - see resolve_config_path.
CONFIG="$(resolve_config_path "$CONFIG_IN" "$REPO_ROOT")"
cd "$REPO_ROOT"

# The Tier 1 IAM units have no committed main.yaml - theirs is generated from
# the iam/ folder by ci/gen-iam.py. Run it before anything reads a template, so
# a deploy works from a clean checkout with no extra step.
#
# Deliberately unconditional rather than "only for IAM units": the same command
# runs here and in ci/lint.sh, so what gets deployed is what got linted.
python ci/gen-iam.py --quiet

# A unit is a directory holding main.yaml and config/, so the unit directory is
# two levels up from the config file.
UNIT_DIR="$(dirname "$(dirname "$CONFIG")")"
TEMPLATE="${UNIT_DIR}/main.yaml"
[ -f "$TEMPLATE" ] || { echo "ERROR: no template at ${TEMPLATE}" >&2; exit 1; }

# Build the two AWS argument lists once. Empty when no profile was given, in
# which case the CLI uses whatever is in the environment.
PKG_ARGS=(); [ -n "$PACKAGE_PROFILE" ] && PKG_ARGS=(--profile "$PACKAGE_PROFILE")
[ -z "$TARGET_PROFILE" ] && TARGET_PROFILE="$PACKAGE_PROFILE"
TGT_ARGS=(); [ -n "$TARGET_PROFILE" ] && TGT_ARGS=(--profile "$TARGET_PROFILE")


# --- values from the config -------------------------------------------------
REGION="$(cfg_get "$CONFIG" region)"
REGION_CODE="$(cfg_get "$CONFIG" regionCode)"
TARGET_ACCOUNT="$(cfg_get "$CONFIG" accountId)"

# Roles created by bootstrap/deployment-roles in every target account.
# stadion-cfn-execution-role is handed to CloudFormation, which uses it to
# create resources - so the permissions that matter are the role's, not yours.
EXECUTION_ROLE="${EXECUTION_ROLE:-arn:aws:iam::${TARGET_ACCOUNT}:role/stadion-cfn-execution-role}"

# Where packaged templates are uploaded. Always the deployment account, in the
# region being deployed to - the target account's execution role reads it
# cross-account, which bootstrap/artifact-store's bucket policy allows.
if [ -z "${ARTIFACT_BUCKET:-}" ]; then
  # MODULES_ACCOUNT_ID is the DEPLOYMENT account, fixed in ci/lib/modules.sh.
  #
  # Deliberately NOT `sts get-caller-identity`. The artifact bucket is always in
  # the deployment account, while this script legitimately runs with TARGET
  # account credentials for the deploy half - so asking "who am I" gives the
  # wrong answer half the time, and gives it as a 404 for a bucket name that
  # looks plausible. The modules bucket had exactly this bug.
  DEPLOY_ACCOUNT="$MODULES_ACCOUNT_ID"
  ARTIFACT_BUCKET="${MODULES_ORGNAME}-${MODULES_ENV_CODE}-${REGION_CODE}-boot-bkt-artifacts-${DEPLOY_ACCOUNT}"
fi

# --- are we actually in the target account? ---------------------------------
#
# CloudFormation runs in ONE account, and --role-arn must name a role in THAT
# SAME account. You cannot call CloudFormation as account A and hand it a role
# from account B - IAM PassRole does not cross an account boundary. AWS reports
# this as "Cross-account pass role is not allowed", which does not say which
# two accounts it means.
#
# So the deploy call has to be made with credentials IN the target account. That
# is what --target-profile is for: a profile whose role_arn points at
# stadion-iac-deployment-role in the target.
#
# Checking here turns a confusing AWS error into one that names both accounts,
# and it fails before spending minutes packaging templates.
CALLER_ACCOUNT="$(aws "${TGT_ARGS[@]}" sts get-caller-identity \
  --query Account --output text </dev/null | tr -d '\r')"

if [ "$CALLER_ACCOUNT" != "$TARGET_ACCOUNT" ]; then
  echo "ERROR: you are in the wrong account for this deploy." >&2
  echo >&2
  echo "  config accountId:  ${TARGET_ACCOUNT}   (where the stack goes)" >&2
  echo "  your credentials:  ${CALLER_ACCOUNT}" >&2
  echo "  profile in use:    ${TARGET_PROFILE:-<none - ambient credentials>}" >&2
  echo >&2
  echo "  CloudFormation runs in one account and --role-arn must name a role in" >&2
  echo "  that same account. IAM PassRole does not cross accounts." >&2
  echo >&2
  echo "  Pass a profile for the target account:" >&2
  echo "    bash ci/package-and-deploy.sh ${CONFIG} --target-profile <profile>" >&2
  echo >&2
  echo "  That profile should assume stadion-iac-deployment-role in ${TARGET_ACCOUNT}." >&2
  echo "  In ~/.aws/config:" >&2
  echo >&2
  echo "    [profile stadion-test]" >&2
  echo "    role_arn       = arn:aws:iam::${TARGET_ACCOUNT}:role/stadion-iac-deployment-role" >&2
  echo "    source_profile = <the profile for ${CALLER_ACCOUNT}>" >&2
  echo "    region         = ${REGION}" >&2
  exit 1
fi

echo "=== ${UNIT_DIR} ==="
echo "  template:        ${TEMPLATE}"
echo "  config:          ${CONFIG}"
echo "  region:          ${REGION}"
echo "  target account:  ${TARGET_ACCOUNT}"
echo "  execution role:  ${EXECUTION_ROLE}"
echo "  artifact bucket: ${ARTIFACT_BUCKET}"
echo "  mode:            $([ "$EXECUTE" -eq 1 ] && echo 'EXECUTE - changes will be applied' || echo 'dry run - nothing applied')"
echo


# --- 1. modules -------------------------------------------------------------
echo "--- modules ---"
modules_reconcile "$CONFIG"
modules_check_references "$TEMPLATE"
echo


# --- 2. render the config ---------------------------------------------------
# Resource names are built here, from ci/naming.yaml, and a name that breaks an
# AWS limit fails now rather than part-way through the deploy.
echo "--- config and names ---"
STACK_NAME="$(python ci/render-config.py "$CONFIG" --emit stack-name)"

# mapfile rather than a `while read` loop. A command inside `while read`
# inherits the loop's stdin and consumes it, so the loop silently ends after the
# first line. mapfile reads everything up front and avoids that entirely.
# tr -d '\r' is belt and braces. render-config.py already forces "\n" endings,
# but mapfile strips only "\n" - so if anything ever reintroduces a carriage
# return, every value here gains an invisible trailing character and the AWS CLI
# fails with an error naming a value that looks correct.
mapfile -t PARAMETERS   < <(python ci/render-config.py "$CONFIG" --emit parameters   | tr -d '\r')
mapfile -t TAGS         < <(python ci/render-config.py "$CONFIG" --emit tags         | tr -d '\r')
mapfile -t CAPABILITIES < <(python ci/render-config.py "$CONFIG" --emit capabilities | tr -d '\r')

echo "  stack name:   ${STACK_NAME}"
printf '  parameter:    %s\n' "${PARAMETERS[@]}"
printf '  tag:          %s\n' "${TAGS[@]}"
echo "  capabilities: ${CAPABILITIES[*]}"
echo


# --- 2b. APPLY-ONLY PATH ----------------------------------------------------
# --execute-changeset stops here and applies a change set that already exists.
#
# Everything below - packaging, uploading, creating a change set - is skipped
# deliberately. Re-packaging would upload fresh template objects and re-creating
# the change set would produce a different one, which is exactly what this
# option exists to avoid: the reviewer approved a specific change set, so that
# is the one that gets applied.
#
# The stack name still comes from render-config.py above, because the change set
# name alone does not identify a change set - CloudFormation needs the stack too.
if [ -n "$EXECUTE_CHANGESET" ]; then
  echo "--- apply an existing change set ---"
  echo "  stack:      ${STACK_NAME}"
  echo "  change set: ${EXECUTE_CHANGESET}"
  echo

  # Confirm it exists and is applicable BEFORE calling execute, so a stale or
  # already-applied change set gives a clear message instead of an API error.
  CS_STATUS="$(aws "${TGT_ARGS[@]}" cloudformation describe-change-set \
    --region "$REGION" --stack-name "$STACK_NAME" \
    --change-set-name "$EXECUTE_CHANGESET" \
    --query 'Status' --output text </dev/null 2>/dev/null | tr -d '\r')" || CS_STATUS=""

  if [ -z "$CS_STATUS" ]; then
    echo "ERROR: no change set '${EXECUTE_CHANGESET}' on stack '${STACK_NAME}'." >&2
    echo "  Change sets do not survive the stack being deleted, and an executed" >&2
    echo "  one cannot be executed twice. Re-run the plan step." >&2
    exit 1
  fi

  if [ "$CS_STATUS" != "CREATE_COMPLETE" ]; then
    echo "ERROR: change set is ${CS_STATUS}, not CREATE_COMPLETE." >&2
    echo "  Only a CREATE_COMPLETE change set can be executed. FAILED usually" >&2
    echo "  means it contained no changes; EXECUTE_COMPLETE means it has already" >&2
    echo "  been applied." >&2
    exit 1
  fi

  echo "--- what is about to be applied ---"
  aws "${TGT_ARGS[@]}" cloudformation describe-change-set \
    --region "$REGION" --stack-name "$STACK_NAME" \
    --change-set-name "$EXECUTE_CHANGESET" \
    --query 'Changes[].ResourceChange.{Action:Action,Logical:LogicalResourceId,Type:ResourceType,Replace:Replacement}' \
    --output table </dev/null

  echo
  echo "--- executing ---"
  aws "${TGT_ARGS[@]}" cloudformation execute-change-set \
    --region "$REGION" --stack-name "$STACK_NAME" \
    --change-set-name "$EXECUTE_CHANGESET" </dev/null

  # Wait, so the pipeline stage fails when the stack fails. Without this the
  # stage goes green the moment the API call returns and a rollback would be
  # reported as a success.
  #
  # This used to be `wait stack-update-complete || wait stack-create-complete`.
  # That is the single worst line this script has had: a failed update finished
  # the first waiter and then sat in the second one for a full extra hour,
  # because UPDATE_ROLLBACK_COMPLETE is not a status stack-create-complete
  # recognises. ci/lib/stack-wait.sh has the detail. This is the PROMOTE path -
  # it reaches production - so it is the one place that most needed fixing.
  echo "Waiting for ${STACK_NAME} to settle (budget ${STACK_WAIT_MINUTES}m)."

  set +e
  wait_for_stack settle "$STACK_NAME"
  WAIT_RESULT=$?
  set -e

  if [ "$WAIT_RESULT" -eq 0 ]; then
    echo
    echo "PASS - applied ${EXECUTE_CHANGESET} to ${STACK_NAME}"
    exit 0
  fi

  if [ "$WAIT_RESULT" -eq 2 ]; then
    echo >&2
    echo "TIMED OUT WAITING - the change set is STILL BEING APPLIED." >&2
    echo >&2
    echo "  ${STACK_NAME} is ${STACK_WAIT_FINAL_STATUS} after ${STACK_WAIT_MINUTES} minutes." >&2
    echo "  NOTHING HAS FAILED. ${EXECUTE_CHANGESET} is still going." >&2
    echo >&2
    echo "  Watch it:  $(stack_console_url "$STACK_NAME")" >&2
    echo >&2
    echo "  The approval has already been given and the change set has already" >&2
    echo "  been executed, so there is nothing to re-approve. Let it finish and" >&2
    echo "  confirm the stack status by hand." >&2
    exit 1
  fi

  echo >&2
  echo "ERROR: applying ${EXECUTE_CHANGESET} did not complete -" >&2
  echo "       ${STACK_NAME} is ${STACK_WAIT_FINAL_STATUS}." >&2
  echo >&2
  echo "Failed resources:" >&2
  aws "${TGT_ARGS[@]}" cloudformation describe-stack-events \
    --region "$REGION" --stack-name "$STACK_NAME" \
    --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
    --output text </dev/null 2>/dev/null | head -20 | sed 's/^/  /' >&2 || true
  echo >&2
  echo "  Full history:  $(stack_console_url "$STACK_NAME")" >&2
  exit 1
fi


# --- 3. package -------------------------------------------------------------
# Uploads every nested module template to the artifact bucket and rewrites the
# local "../../modules/s3/template.yaml" paths into S3 URLs. CloudFormation
# cannot read a local path, so this step is what makes nested modules deployable.
#
# The bucket encrypts with the artifact KMS key by default, so there is no
# --kms-key-id here. Passing one would have to be the correct ARN for this
# region, and the bucket already handles it.
echo "--- package ---"
mkdir -p .build
PACKAGED=".build/$(echo "$UNIT_DIR" | tr '/' '-').packaged.yaml"

aws "${PKG_ARGS[@]}" cloudformation package \
  --region "$REGION" \
  --template-file "$TEMPLATE" \
  --s3-bucket "$ARTIFACT_BUCKET" \
  --s3-prefix "$UNIT_DIR" \
  --output-template-file "$PACKAGED"

echo "  packaged -> ${PACKAGED}"
echo


# --- 4. size check -----------------------------------------------------------
#
# The change set below sends the root template INLINE, with no --s3-bucket.
# That is deliberate, and getting it wrong is subtle.
#
# `aws cloudformation deploy --s3-bucket X` uploads the ROOT template to X
# before creating the change set. But this call runs as the TARGET account,
# which has no write access to the deployment account's artifact bucket - only
# read, which is all it needs. The failure is:
#
#   AccessDenied ... assumed-role/stadion-iac-deployment-role ... is not
#   authorized to perform: s3:PutObject
#
# Without the flag the root template is sent inline in the API call, and the
# nested module templates are read from the S3 URLs that `package` already
# wrote - uploaded in step 3 as the DEPLOYMENT account, which is the half that
# is allowed to write. Cross-account reading of those is what bootstrap/verify
# proved.
#
# The catch is a size limit, checked below.
CFN_INLINE_LIMIT=51200
BODY_BYTES=$(wc -c < "$PACKAGED")

# TWO DIFFERENT LIMITS APPLY, AND ONLY ONE IS CHECKED HERE.
#
#   51,200 bytes   CloudFormation's limit for a template sent in the API
#                  request body. That is what this check is about.
#
#   32,767 chars   Windows' limit on a whole command line. This one used to
#                  bite first, because the template text was passed as an
#                  argument - so a 31 KB template passed the check above and
#                  then failed with "Argument list too long". The change set
#                  now passes file://, so the command line stays tiny and this
#                  limit no longer applies. See the note in section 5.
if [ "$BODY_BYTES" -gt "$CFN_INLINE_LIMIT" ]; then
  echo "ERROR: packaged template is ${BODY_BYTES} bytes, over CloudFormation's" >&2
  echo "  ${CFN_INLINE_LIMIT}-byte limit for a template sent in the request body." >&2
  echo >&2
  echo "  Larger templates must be passed by S3 URL, which needs a bucket the" >&2
  echo "  TARGET account can write to - the deployment account's artifact bucket" >&2
  echo "  grants it read only. Options, in order of preference:" >&2
  echo "    1. Split the unit into smaller units. A root template this large is" >&2
  echo "       usually doing too much." >&2
  echo "    2. Add a per-target-account staging bucket and switch this script to" >&2
  echo "       create-change-set --template-url." >&2
  exit 1
fi

echo "  packaged template: ${BODY_BYTES} bytes (inline limit ${CFN_INLINE_LIMIT})"
echo


# --- 5. build the change set -------------------------------------------------
#
# We call create-change-set directly rather than `aws cloudformation deploy`,
# for one reason: --include-nested-stacks.
#
# `deploy` cannot pass that flag, so its change set shows 18 rows of
# AWS::CloudFormation::Stack and nothing about what is inside them. A plan that
# says "18 stacks will be added" is not a plan. With the flag, CloudFormation
# expands each child and you see the actual VPC, subnets, route tables and NAT
# gateways before anything is applied.

# CREATE or UPDATE?
#
# REVIEW_IN_PROGRESS means a previous CREATE change set was made and never
# executed, so the stack exists but holds no resources. It still needs a CREATE
# change set, not an UPDATE.
STACK_STATUS="$(aws "${TGT_ARGS[@]}" cloudformation describe-stacks \
  --region "$REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' --output text </dev/null 2>/dev/null | tr -d '\r')" || STACK_STATUS=""

if [ -z "$STACK_STATUS" ] || [ "$STACK_STATUS" = "REVIEW_IN_PROGRESS" ]; then
  CHANGESET_TYPE=CREATE
else
  CHANGESET_TYPE=UPDATE
fi

# Some states accept neither a CREATE nor an UPDATE change set, and the naive
# rule above would pick UPDATE and fail with an error that does not say what to
# do about it:
#
#   Stack ... is in ROLLBACK_COMPLETE state and can not be updated.
#
# ROLLBACK_COMPLETE is the normal result of a CREATE that failed - the stack
# name is taken, the stack holds nothing, and DELETE is the only legal move.
# That is not an edge case here, it is what every failed first deploy leaves
# behind, so it deserves a real message rather than an API error.
#
# WHY THIS DOES NOT DELETE THE STACK AUTOMATICALLY
#   It looks safe - a rolled-back create has no resources - but that is not
#   reliably true. Anything with DeletionPolicy: Retain SURVIVES the rollback,
#   and the flow-logs log group is exactly that. Deleting the stack would
#   orphan it, and the next create would then fail with "log group already
#   exists", which is a worse failure than this one. Whether the leftovers
#   should be kept or removed is a judgement call, so a human makes it.
case "$STACK_STATUS" in
  ROLLBACK_COMPLETE|CREATE_FAILED)
    echo >&2
    echo "ERROR: ${STACK_NAME} is ${STACK_STATUS} and cannot be deployed to." >&2
    echo >&2
    echo "  A CREATE failed and rolled back. The stack holds no resources but" >&2
    echo "  the NAME is taken, and CloudFormation allows only DELETE from here." >&2
    echo >&2
    echo "  Delete it, then re-run:" >&2
    echo "    aws cloudformation delete-stack --region ${REGION} \\" >&2
    echo "      --stack-name ${STACK_NAME}${TARGET_PROFILE:+ --profile $TARGET_PROFILE}" >&2
    echo >&2
    echo "  CHECK FOR RETAINED RESOURCES FIRST. Anything with" >&2
    echo "  DeletionPolicy: Retain survived the rollback and will still exist" >&2
    echo "  after the delete - a log group is the usual one. If it is still" >&2
    echo "  there, either remove it or set CreateLogGroup to 'false' in the" >&2
    echo "  config, or the next deploy fails with 'already exists'." >&2
    echo >&2
    echo "  Why it failed in the first place:" >&2
    echo "    aws cloudformation describe-stack-events --region ${REGION} \\" >&2
    echo "      --stack-name ${STACK_NAME}${TARGET_PROFILE:+ --profile $TARGET_PROFILE} \\" >&2
    echo "      --query 'StackEvents[?ResourceStatus==\`CREATE_FAILED\`]'" >&2
    exit 1
    ;;
  ROLLBACK_FAILED|UPDATE_ROLLBACK_FAILED|DELETE_FAILED)
    echo >&2
    echo "ERROR: ${STACK_NAME} is ${STACK_STATUS} and needs manual recovery." >&2
    echo >&2
    echo "  CloudFormation could not finish rolling back, usually because a" >&2
    echo "  resource could not be deleted or restored. It will not accept a new" >&2
    echo "  change set until that is resolved." >&2
    echo >&2
    echo "  Look at the failed events, fix the underlying resource, then run" >&2
    echo "  continue-update-rollback (or delete-stack, retaining what blocks it):" >&2
    echo "    aws cloudformation continue-update-rollback --region ${REGION} \\" >&2
    echo "      --stack-name ${STACK_NAME}${TARGET_PROFILE:+ --profile $TARGET_PROFILE}" >&2
    exit 1
    ;;
esac

echo "--- change set (${CHANGESET_TYPE}) ---"
echo "  stack status: ${STACK_STATUS:-does not exist yet}"

# Change set names must match [a-zA-Z][-a-zA-Z0-9]* - no dots, no underscores.
CHANGESET_NAME="iac-$(date +%Y%m%d-%H%M%S)"

# Parameters and tags go to the CLI as JSON FILES, not as its shorthand.
#
# WHY NOT ParameterKey=K,ParameterValue=V
#   Shorthand separates FIELDS with commas, so a value that itself contains a
#   comma is read as the start of the next field. The CLI then reports a type
#   error naming a parameter INDEX rather than the value that broke it:
#
#     Invalid type for parameter Parameters[9].ParameterValue,
#       value: ['arn:...AdministratorAccess_*', 'arn:...SysAdmin_*'],
#       type: <class 'list'>, valid types: <class 'str'>
#
#   That was KeyAdminArnPatterns - deliberately a comma-separated list of ARN
#   patterns, because a KMS key policy cannot name an SSO role exactly. A
#   perfectly ordinary value that shorthand cannot carry.
#
#   ANY config value containing a comma has this problem. It is not a KMS
#   quirk; it sat here until the first value that needed one.
#
#   Escaping does not rescue it. Quotes are stripped by the shell before the
#   CLI sees them, and backslash escaping inside shorthand is not portable.
#
# JSON has none of these ambiguities. Python writes it - already a dependency
# of this script, and it quotes correctly.
#
# The paths stay RELATIVE. aws.exe cannot open a Git Bash path, and this
# script has already cd'd to the repo root. Same reason as --template-body
# below.
CFN_PARAMS_FILE=".build/$(echo "$UNIT_DIR" | tr '/' '-').params.json"
CFN_TAGS_FILE=".build/$(echo "$UNIT_DIR" | tr '/' '-').tags.json"

# Each line arrives as Key=Value. Split on the FIRST = only - a value may
# legitimately contain one.
printf '%s\n' ${PARAMETERS[@]+"${PARAMETERS[@]}"} | python -c '
import json, sys
out = []
for line in sys.stdin.read().splitlines():
    if line.strip():
        k, _, v = line.partition("=")
        out.append({"ParameterKey": k, "ParameterValue": v})
sys.stdout.write(json.dumps(out))
' > "$CFN_PARAMS_FILE"

printf '%s\n' ${TAGS[@]+"${TAGS[@]}"} | python -c '
import json, sys
out = []
for line in sys.stdin.read().splitlines():
    if line.strip():
        k, _, v = line.partition("=")
        out.append({"Key": k, "Value": v})
sys.stdout.write(json.dumps(out))
' > "$CFN_TAGS_FILE"

CS_ERR=".build/changeset-error.txt"

# --template-body takes a file:// REFERENCE, not the template text.
#
# WHY NOT PASS THE TEXT DIRECTLY
#   "$(cat "$PACKAGED")" puts the whole template into one argument, and Windows
#   caps an entire command line at 32,767 characters (CreateProcess). The Tier 0
#   VPC template is around 31 KB packaged, so with the other arguments it went
#   over and Git Bash reported:
#
#     /c/Program Files/Amazon/AWSCLIV2/aws: Argument list too long
#
#   That limit is LOWER than CloudFormation's 51,200-byte inline limit checked
#   above, so the size check passed and the operating system refused the call.
#   A file:// reference is ~50 characters, so the limit stops applying at all.
#
# WHY A RELATIVE PATH MATTERS
#   aws.exe is a Windows program and cannot open a Git Bash path like
#   /c/Users/... This script has already cd'd to the repo root and $PACKAGED is
#   relative (.build/...), so aws.exe resolves it against the same working
#   directory. Do NOT "improve" this into an absolute path.
if ! aws "${TGT_ARGS[@]}" cloudformation create-change-set \
      --region "$REGION" \
      --stack-name "$STACK_NAME" \
      --change-set-name "$CHANGESET_NAME" \
      --change-set-type "$CHANGESET_TYPE" \
      --include-nested-stacks \
      --template-body "file://${PACKAGED}" \
      --role-arn "$EXECUTION_ROLE" \
      --capabilities "${CAPABILITIES[@]}" \
      --parameters "file://${CFN_PARAMS_FILE}" \
      --tags "file://${CFN_TAGS_FILE}" \
      >/dev/null 2>"$CS_ERR"; then
  echo "ERROR: could not create the change set." >&2
  sed 's/^/  /' "$CS_ERR" >&2
  exit 1
fi

# Nested change sets are created asynchronously, so this waits for all of them.
if ! aws "${TGT_ARGS[@]}" cloudformation wait change-set-create-complete \
      --region "$REGION" --stack-name "$STACK_NAME" \
      --change-set-name "$CHANGESET_NAME" 2>/dev/null; then

  CS_STATUS="$(aws "${TGT_ARGS[@]}" cloudformation describe-change-set \
    --region "$REGION" --stack-name "$STACK_NAME" --change-set-name "$CHANGESET_NAME" \
    --query 'StatusReason' --output text </dev/null 2>/dev/null | tr -d '\r')"

  # "No updates" is not a failure. Re-running a deploy that changes nothing is
  # normal, and CloudFormation reports it by failing the change set.
  case "$CS_STATUS" in
    *"didn't contain changes"*|*"No updates"*|*"no updates"*)
      echo
      echo "No changes. ${STACK_NAME} already matches this config."
      aws "${TGT_ARGS[@]}" cloudformation delete-change-set \
        --region "$REGION" --stack-name "$STACK_NAME" \
        --change-set-name "$CHANGESET_NAME" >/dev/null 2>&1 || true
      exit 0
      ;;
  esac

  echo "ERROR: the change set failed to build." >&2
  echo "  ${CS_STATUS}" >&2
  exit 1
fi

CHANGESET_ARN="$(aws "${TGT_ARGS[@]}" cloudformation describe-change-set \
  --region "$REGION" --stack-name "$STACK_NAME" --change-set-name "$CHANGESET_NAME" \
  --query 'ChangeSetId' --output text </dev/null | tr -d '\r')"


# --- 6. show what it would do ------------------------------------------------
#
# describe-change-set on the ROOT does not inline the children. Each change for
# an AWS::CloudFormation::Stack carries the ChangeSetId of its nested change
# set, and you have to follow it. Without this you only ever see
# "AWS::CloudFormation::Stack" and learn nothing about the actual resources.

declare -a CHANGE_ROWS

collect_changes() {
  local cs="$1" depth="$2" rows line action rtype lid nested replacement prefix
  local -a lines

  rows="$(aws "${TGT_ARGS[@]}" cloudformation describe-change-set \
    --region "$REGION" --change-set-name "$cs" \
    --query 'Changes[].ResourceChange.[Action,ResourceType,LogicalResourceId,ChangeSetId,Replacement]' \
    --output text </dev/null 2>/dev/null)" || return 0

  # Strip carriage returns. The AWS CLI on Windows emits CRLF, and mapfile
  # splits on \n only - so "None\r" would not equal "None" and the recursion
  # would follow resources that have no nested change set.
  rows="${rows//$'\r'/}"
  [ -z "$rows" ] && return 0

  mapfile -t lines <<< "$rows"

  for line in "${lines[@]}"; do
    [ -z "$line" ] && continue
    IFS=$'\t' read -r action rtype lid nested replacement <<< "$line"

    prefix=""
    [ "$depth" -gt 0 ] && prefix="$(printf '%*s' $((depth * 2)) '')+- "

    # Replacement=True means the resource is destroyed and rebuilt, not edited.
    # For a subnet or VPC that takes everything inside it along with it, so it
    # is worth shouting about.
    [ "${replacement:-}" = "True" ] && action="${action} (REPLACE)"

    CHANGE_ROWS+=("${action}|${rtype}|${prefix}${lid}")

    if [ -n "${nested:-}" ] && [ "$nested" != "None" ]; then
      collect_changes "$nested" $((depth + 1))
    fi
  done
}

render_changes() {
  local w1=6 w2=4 w3=10 row a b c sep

  for row in ${CHANGE_ROWS[@]+"${CHANGE_ROWS[@]}"}; do
    IFS='|' read -r a b c <<< "$row"
    [ ${#a} -gt "$w1" ] && w1=${#a}
    [ ${#b} -gt "$w2" ] && w2=${#b}
    [ ${#c} -gt "$w3" ] && w3=${#c}
  done

  sep="+$(printf '%*s' $((w1+2)) '' | tr ' ' '-')+$(printf '%*s' $((w2+2)) '' | tr ' ' '-')+$(printf '%*s' $((w3+2)) '' | tr ' ' '-')+"

  printf '  %s\n' "$sep"
  printf '  | %-*s | %-*s | %-*s |\n' "$w1" "Action" "$w2" "Type" "$w3" "Logical ID"
  printf '  %s\n' "$sep"
  for row in ${CHANGE_ROWS[@]+"${CHANGE_ROWS[@]}"}; do
    IFS='|' read -r a b c <<< "$row"
    printf '  | %-*s | %-*s | %-*s |\n' "$w1" "$a" "$w2" "$b" "$w3" "$c"
  done
  printf '  %s\n' "$sep"
}

echo
echo "Resources this would create or change:"
CHANGE_ROWS=()
collect_changes "$CHANGESET_ARN" 0
render_changes
echo "  ${#CHANGE_ROWS[@]} change(s)"


# --- 7. apply, or stop -------------------------------------------------------
if [ "$EXECUTE" -eq 0 ]; then
  if [ "$DELETE_CHANGESET" -eq 1 ]; then
    aws "${TGT_ARGS[@]}" cloudformation delete-change-set \
      --region "$REGION" --stack-name "$STACK_NAME" \
      --change-set-name "$CHANGESET_NAME" >/dev/null 2>&1 || true
    echo "  change set deleted"
  fi

  echo
  echo "DRY RUN - nothing was applied."
  echo "Re-run with --execute to apply."

  # Machine-readable, on its own line, in a fixed format. ci/buildspec.yml
  # greps for this to hand the name to the apply step through CodePipeline, so
  # the change set a reviewer approved is the one that gets executed.
  #
  # Do not reword this line without updating the grep in ci/buildspec.yml.
  echo "CHANGESET_NAME=${CHANGESET_NAME}"
  echo
  echo "To apply exactly this change set, and nothing newer:"
  echo "  bash ci/package-and-deploy.sh ${CONFIG} --execute-changeset ${CHANGESET_NAME}"

  if [ "$CHANGESET_TYPE" = "CREATE" ]; then
    echo
    echo "NOTE: ${STACK_NAME} now exists in REVIEW_IN_PROGRESS holding no"
    echo "resources - it is the pending change set. Deploying uses it up; to"
    echo "clear it instead:"
    echo "  bash ci/destroy.sh ${CONFIG}${TARGET_PROFILE:+ --target-profile $TARGET_PROFILE} --execute"
  fi
  exit 0
fi

echo
echo "--- applying ---"
aws "${TGT_ARGS[@]}" cloudformation execute-change-set \
  --region "$REGION" --stack-name "$STACK_NAME" --change-set-name "$CHANGESET_NAME"

# How long this takes is entirely about what the unit contains. NAT gateways
# are several minutes; an Aurora cluster is 15-25, and a restore from a large
# snapshot can be an hour or more. wait_for_stack prints the status as it goes
# and explains the three ways this can end - see ci/lib/stack-wait.sh.
echo "Waiting for ${STACK_NAME} to settle (budget ${STACK_WAIT_MINUTES}m)."

# Deliberately not branching on CHANGESET_TYPE. Both a create and an update
# finish in a status wait_for_stack recognises, and picking the wrong waiter
# used to mean polling for an hour against a status it would never accept.
set +e
wait_for_stack settle "$STACK_NAME"
WAIT_RESULT=$?
set -e

case "$WAIT_RESULT" in

  0)
    echo
    echo "--- outputs ---"
    aws "${TGT_ARGS[@]}" cloudformation describe-stacks \
      --region "$REGION" --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table </dev/null || true
    echo
    echo "PASS - ${STACK_NAME} deployed to ${TARGET_ACCOUNT} / ${REGION}"
    ;;

  2)
    # NOT a failure. The stack is still building and will most likely succeed.
    # The stage still goes red, because a deploy we did not see finish is not a
    # deploy we can call green - but the message has to say which of the two
    # happened, or the next person spends an hour looking for a failure that
    # never occurred.
    echo >&2
    echo "TIMED OUT WAITING - the deploy is STILL RUNNING." >&2
    echo >&2
    echo "  ${STACK_NAME} is ${STACK_WAIT_FINAL_STATUS} after ${STACK_WAIT_MINUTES} minutes." >&2
    echo "  NOTHING HAS FAILED. CloudFormation is still working and will" >&2
    echo "  probably finish on its own." >&2
    echo >&2
    echo "  Watch it:  $(stack_console_url "$STACK_NAME")" >&2
    echo >&2
    echo "  Do NOT re-run this stage while the stack is in progress - the next" >&2
    echo "  change set cannot be created until it settles, so the retry fails" >&2
    echo "  for a different reason and buries this one." >&2
    echo >&2
    echo "  If this unit is legitimately this slow, raise the budget AND the" >&2
    echo "  CodeBuild timeout above it:" >&2
    echo "    STACK_WAIT_MINUTES   in the pipeline's buildspec environment" >&2
    echo "    BuildTimeoutMinutes  in pipelines/*.yaml, larger than that" >&2
    exit 1
    ;;

  *)
    echo >&2
    echo "ERROR: the deploy did not complete - ${STACK_NAME} is ${STACK_WAIT_FINAL_STATUS}." >&2
    echo >&2
    echo "Failed resources:" >&2
    aws "${TGT_ARGS[@]}" cloudformation describe-stack-events \
      --region "$REGION" --stack-name "$STACK_NAME" \
      --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
      --output text </dev/null 2>/dev/null | head -20 | sed 's/^/  /' >&2 || true
    echo >&2
    echo "  Full history:  $(stack_console_url "$STACK_NAME")" >&2

    # ROLLBACK_COMPLETE is the one that needs saying out loud, because the
    # obvious next move - fix it and redeploy - does not work.
    if [ "$STACK_WAIT_FINAL_STATUS" = "ROLLBACK_COMPLETE" ]; then
      echo >&2
      echo "  ROLLBACK_COMPLETE means the stack never finished its FIRST create." >&2
      echo "  A stack in this state cannot be updated, only deleted. Delete it" >&2
      echo "  before retrying, or every redeploy fails on the state and not on" >&2
      echo "  whatever you just fixed:" >&2
      echo "    bash ci/destroy.sh ${CONFIG}${TARGET_PROFILE:+ --target-profile $TARGET_PROFILE} --execute" >&2
    fi
    exit 1
    ;;
esac
