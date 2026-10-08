#!/usr/bin/env bash
# =============================================================================
# ci/lint.sh
#
# WHAT
#   Validates one deployable unit without touching AWS. This is our equivalent
#   of `terraform validate`, and it should be the last thing you run before
#   opening a PR.
#
# USAGE
#   bash ci/lint.sh <unit-config.yaml>
#   bash ci/lint.sh tier0-networking/vpc/config/prod-use1.yaml
#
# WHAT IT DOES, IN ORDER
#   1. Downloads the module library at the version the config pins.
#   2. Confirms every nested module path in main.yaml actually exists.
#   3. Builds the resource names and checks them against AWS service limits.
#   4. Resolves every cross-stack reference, and checks the stack registry.
#   5. Runs cfn-lint on the unit's main.yaml.
#   6. Runs cfn-guard, once policy rules exist in ci/rules/.
#
# WHY STEP 1 COMES FIRST
#   main.yaml points at modules by local path (../../modules/s3/template.yaml).
#   cfn-lint opens that file and checks that the parameters we pass match the
#   ones the module actually declares — a wrong or missing parameter is caught
#   here rather than at deploy time. If ./modules/ is missing or at the wrong
#   version, that check is testing the wrong thing.
# =============================================================================

set -euo pipefail

CONFIG_IN="${1:?usage: lint.sh <unit-config.yaml>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/ci/lib/modules.sh"

# Work out where the config actually is BEFORE we cd, so a path relative to the
# directory you ran this from still resolves. See resolve_config_path.
CONFIG="$(resolve_config_path "$CONFIG_IN" "$REPO_ROOT")"

cd "$REPO_ROOT"

# --- 0. generate the IAM templates ------------------------------------------
# The two Tier 1 IAM units have no committed main.yaml. Theirs is built from
# the iam/ folder, because CloudFormation cannot turn N files into N resources
# on its own - see ci/gen-iam.py.
#
# THIS RUNS FIRST, AND FOR EVERY UNIT, NOT JUST THE IAM ONES.
#   ci/stack-registry.py below walks every unit in the repo and reads its
#   template. On a fresh clone the IAM templates do not exist yet, so anything
#   that reads them has to come after this. Cheap and idempotent, so running it
#   on every lint costs nothing and removes a whole class of "works on my
#   machine".
#
# GUARDED BECAUSE NOT EVERY REPO HAS ONE.
#   This script is shared verbatim across the infra and apps repos. Only the
#   repo that owns the shared IAM units carries ci/gen-iam.py; a repo with no
#   generated templates has nothing to generate, and hard-coding the call would
#   make this file un-shareable for the sake of one line.
#
#   The day an apps repo grows its own app-scoped roles, copying gen-iam.py and
#   an iam/ folder in is all it takes - this picks it up with no edit here.
if [ -f ci/gen-iam.py ]; then
  python ci/gen-iam.py --quiet
fi

# A unit is a directory holding main.yaml plus config/. So the unit directory is
# two levels up from the config file:
#
#   tier0-networking/vpc/config/prod-use1.yaml
#   ^--------- unit ---^ ^-- config dir --^
UNIT_DIR="$(dirname "$(dirname "$CONFIG")")"
TEMPLATE="${UNIT_DIR}/main.yaml"

# For an IAM unit this fires when its source folder is empty - a stack with no
# resources is not a legal template, so gen-iam.py removes the file rather than
# writing an invalid one.
[ -f "$TEMPLATE" ] || { echo "ERROR: no template at ${TEMPLATE}" >&2; exit 1; }

REGION="$(cfg_get "$CONFIG" region)"

echo "=== ${UNIT_DIR} ==="
echo "  template: ${TEMPLATE}"
echo "  config:   ${CONFIG}"
echo "  region:   ${REGION}"
echo

# --- 1. modules -------------------------------------------------------------
echo "--- modules ---"
modules_reconcile "$CONFIG"
echo

# --- 2. every nested template resolves --------------------------------------
# Do this before cfn-lint, not after. cfn-lint treats a missing nested template
# as a logged warning and still exits 0, so on its own it would report success
# while having validated nothing inside the module. See modules_check_references.
echo "--- nested templates ---"
if modules_check_references "$TEMPLATE"; then
  echo "  all nested templates resolve"
else
  echo "  FAILED — see above" >&2
  exit 1
fi
echo

# --- 3. config and names ----------------------------------------------------
# Render the config the same way a deploy would. This is where resource names
# get built from ci/naming.yaml, so a name that is too long or uses an illegal
# character fails HERE, on a laptop in a second, rather than part-way through a
# CloudFormation deploy.
#
# It also catches a template parameter the config has no value for.
echo "--- config and names ---"
if RENDERED="$(python ci/render-config.py "$CONFIG" --emit json)"; then
  echo "$RENDERED" | sed 's/^/  /'
else
  echo "  FAILED — see above" >&2
  exit 1
fi
echo

# --- 4. cross-stack references ----------------------------------------------
# Every Fn::GetStackOutput in this repo is resolved against the units that
# actually exist here.
#
# WHY THIS STAGE EXISTS
#   cfn-lint cannot check a cross-stack reference at all. It has no idea which
#   stacks exist or what they publish, so
#
#     StackName:  !Sub '${Env}-net-vpc'
#     OutputName: VpcIdentifier          <- typo
#
#   passes every other check here and only fails when the change set is built
#   against a live account. Renaming a unit without updating its consumers has
#   the same shape.
#
#   This also keeps docs/STACK-REGISTRY.md honest. That file is generated, so
#   an out-of-date copy means someone changed an output and did not regenerate.
echo "--- cross-stack references ---"

# WHAT FAILS HERE
#   A broken cross-stack reference. Every Fn::GetStackOutput in the repo is
#   resolved against the units that actually exist, so a renamed output or a
#   typo'd stack name fails now rather than when the change set is built
#   against a live account.
#
# WHAT DOES NOT FAIL HERE
#   docs/STACK-REGISTRY.md being out of date. It is generated and gitignored -
#   this call rewrites it - so there is no committed copy to drift and nothing
#   for anyone to remember.
#
#   It was committed and compared until that had failed three pipeline runs,
#   each time for a one-line documentation diff caused by adding a policy
#   file. A derived artifact kept in git always needs a human to refresh it,
#   and "remember the second command" is not a control. Deleting the copy
#   deleted the whole failure mode; the reference check above was never part
#   of it.
if ! python ci/stack-registry.py; then
  echo "  FAILED — see above" >&2
  exit 1
fi
echo

# --- 5. cfn-lint ------------------------------------------------------------
echo "--- cfn-lint ---"

# Two flags worth explaining:
#
# -i W3002
#   W3002 warns that a local-file TemplateURL "only works with the package
#   command". That is exactly what we do — ci/package-and-deploy.sh runs
#   `aws cloudformation package`, which uploads each module and rewrites the
#   path into an S3 URL. So the warning is expected and we suppress it.
#
# -t
#   -i accepts more than one rule id, so if the filename came straight after it
#   cfn-lint would treat the filename as another rule id, find no template, and
#   print its usage text instead of linting. -t names the template explicitly
#   and removes the ambiguity.
if cfn-lint -i W3002 --regions "$REGION" -t "$TEMPLATE"; then
  echo "  cfn-lint OK"
else
  echo "  cfn-lint FAILED" >&2
  exit 1
fi
echo

# --- 6. cfn-guard -----------------------------------------------------------
echo "--- cfn-guard ---"

# cfn-guard enforces our own policy (naming, tagging, encryption, IAM breadth)
# rather than CloudFormation syntax. The rule files exist but are still empty
# placeholders, and cfn-guard errors on an empty rules directory — so skip until
# there is something to enforce.
if find ci/rules -name '*.guard' -size +0 -print -quit 2>/dev/null | grep -q .; then

  # Check the TOOL before blaming the RULES.
  #
  # Without this, a missing binary makes `cfn-guard validate` return non-zero
  # and the else branch reports "cfn-guard FAILED" - so the first person to
  # write a rule debugs their rule for an hour while the real problem is that
  # cfn-guard was never installed. It is not in the CodeBuild image by default.
  if ! command -v cfn-guard >/dev/null 2>&1; then
    echo "  ERROR: rules exist in ci/rules/ but cfn-guard is not installed." >&2
    echo >&2
    echo "  This is NOT a rule failure - the tool is missing." >&2
    echo >&2
    echo "  Locally:   https://github.com/aws-cloudformation/cloudformation-guard" >&2
    echo "  In CI:     ci/buildspec.yml installs it when ci/rules/ is non-empty." >&2
    exit 1
  fi

  # THREE RULE SETS, THREE SHAPES OF DATA.
  #
  # They are separate directories because the same policy looks different
  # depending on where you read it, and because an identity policy and a trust
  # policy are OPPOSITES on the thing that matters most:
  #
  #   ci/rules/template/   a CloudFormation template. Rules about how a
  #                        resource is DECLARED - boundary present, no inline
  #                        policies, no IAM users.
  #
  #   ci/rules/policy/     raw JSON in iam/policies/. Rules about what a policy
  #                        GRANTS. Here a Principal is INVALID.
  #
  #   ci/rules/trust/      raw JSON in iam/trust-policies/. Here a Principal is
  #                        the entire point, and its absence is the error.
  #
  # Running one set over both kinds of JSON rejects every correct trust policy.
  # That is not hypothetical - it is what the first version did.
  #
  # WHY THE JSON IS CHECKED HERE AND NOT ONLY IN THE TEMPLATE
  #   By the time a policy reaches the generated template its placeholders have
  #   become Fn::Sub maps, so a rule matching on a string no longer sees one.
  #   Checking the source also means the failure names the file you edit.
  GUARD_FAILED=0

  guard_run() {   # $1 = rules dir, $2... = data files
    local rules="$1"; shift
    [ -d "$rules" ] || return 0
    find "$rules" -name '*.guard' -size +0 -print -quit 2>/dev/null | grep -q . || return 0
    local f
    for f in "$@"; do
      [ -f "$f" ] || continue
      if ! cfn-guard validate --rules "$rules" --data "$f"; then
        echo "  cfn-guard FAILED: ${f}" >&2
        GUARD_FAILED=1
      fi
    done
  }

  guard_run ci/rules/template "$TEMPLATE"

  # Repo-wide, so run on every unit rather than only the IAM ones - the same
  # reasoning as the stack registry check above. A bad policy is caught by
  # whichever unit is linted first, instead of waiting for a change that
  # happens to touch Tier 1.
  guard_run ci/rules/policy iam/policies/*.json
  guard_run ci/rules/trust  iam/trust-policies/*.json

  if [ "$GUARD_FAILED" -eq 0 ]; then
    echo "  cfn-guard OK"
  else
    exit 1
  fi
else
  echo "  skipped — ci/rules/ has no rules yet"
fi

echo
echo "PASS — ${UNIT_DIR}"
