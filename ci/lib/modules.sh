#!/usr/bin/env bash
# =============================================================================
# ci/lib/modules.sh
#
# WHAT
#   Downloads the shared module library into ./modules/ at the version a unit's
#   config pins.
#
# WHY
#   Modules live in a separate repo (stadion_sysops_modules) and are published
#   as versioned tarballs. Our templates need them on disk before they can be
#   linted or deployed. Think of it as `terraform init`.
#
# HOW TO USE IT
#   This file is SOURCED, not run:
#
#       source ci/lib/modules.sh
#       modules_reconcile tier0-networking/vpc/config/prod-use1.yaml
#
#   Three scripts need this same logic (fetch-modules.sh, lint.sh and later
#   package-and-deploy.sh), so it lives here once instead of being copied.
# =============================================================================


# -----------------------------------------------------------------------------
# BACKGROUND: two rules that explain most of the code below
#
# 1. `moduleVersion:` in a unit's config is the lock file.
#    ./modules/ is gitignored and never committed, so that one line is the only
#    record of which module version a stack was built against.
#
# 2. Templates must reference modules by local path, e.g.
#       TemplateURL: ../../modules/s3/template.yaml
#    NOT by an S3 URL. cfn-lint can open a local file and check that the
#    parameters we pass match the ones the module declares. An S3 URL is just an
#    opaque string to cfn-lint, so that check silently stops running — it passes
#    whether or not the parameters are correct. Downloading the modules first is
#    what keeps that validation working.
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# Windows / Git Bash settings
#
# AWS_PAGER=
#   The AWS CLI tries to open a pager, which fails inside Git Bash. Empty
#   disables it.
#
# MSYS_NO_PATHCONV=1
#   Git Bash normally rewrites arguments that start with "/" into Windows paths
#   (so "/tmp/x" becomes "C:/Users/.../tmp/x"). That corrupts things like IAM
#   paths and S3 URIs, so we turn it off.
#
#   The catch: it is all-or-nothing. With it off, a real path we hand to aws.exe
#   is NOT converted either, and aws.exe cannot read a Git Bash path like
#   "/tmp/foo". The fix is simple — this file only ever uses RELATIVE paths
#   (".build/x.tar.gz"), which both shells understand.
# -----------------------------------------------------------------------------
export AWS_PAGER=
export MSYS_NO_PATHCONV=1


# -----------------------------------------------------------------------------
# Where the modules bucket lives.
#
# It is always in the DEPLOYMENT account, regardless of which account we are
# deploying to. These values build the bucket name, and they must stay identical
# to the ones in the modules repo's ci/publish.sh — that script builds the same
# name when it uploads. If they drift, downloads 404.
#
# Override with environment variables if your setup differs.
# -----------------------------------------------------------------------------
MODULES_ORGNAME="${ORGNAME:-stadion}"
MODULES_ENV_CODE="${ENV_CODE:-dev}"

# The DEPLOYMENT account - stadion-dev. NOT the account being deployed into.
#
# The module library lives in one bucket, in the deployment account, for every
# environment. A target account never holds one.
#
# This used to fall back to `sts get-caller-identity` when unset, which meant
# the bucket name was built from WHOEVER YOU HAPPENED TO BE AUTHENTICATED AS.
# That is right only when you run from the deployment account. Run a lint while
# holding target-account credentials - which is normal, since that is what you
# deploy with - and it silently asks for
#   stadion-dev-use1-boot-bkt-modules-<TARGET account>
# and reports a 404 for a bucket that was never supposed to exist.
#
# A constant cannot drift with your shell. Override with DEPLOYMENT_ACCOUNT_ID
# if this repo is ever used against a different deployment account.
MODULES_ACCOUNT_ID="${DEPLOYMENT_ACCOUNT_ID:-977692454741}"

MODULES_DIR="modules"                          # where modules are extracted
MODULES_STAMP="${MODULES_DIR}/.module-version"  # records the version now on disk
MODULES_CACHE=".build"                          # downloaded tarballs, gitignored
MODULES_LOCK="ci/modules.lock"                  # version -> sha256, IN GIT


# =============================================================================
# resolve_config_path <given-path> <repo-root>
#
# WHAT  Takes the config path a user typed and prints it as a path relative to
#       the repo root. Prints an error and fails if it cannot find the file.
#
# WHY   Our scripts cd to the repo root before doing anything, so every path
#       after that point has to be relative to the root. But people run these
#       scripts from wherever they happen to be:
#
#         cd stadion_sysops_core_infra
#         bash ci/lint.sh tests/selftest/config/test-use1.yaml
#
#         cd ..                                    # the parent folder
#         bash stadion_sysops_core_infra/ci/lint.sh tests/selftest/config/test-use1.yaml
#
#       Both are reasonable. This accepts either, plus an absolute path.
#
# HOW   Look for the file in two places, in order:
#         1. relative to the current directory (this also covers absolute paths)
#         2. relative to the repo root
#       Then convert whatever was found into a repo-root-relative path.
#
# MUST BE CALLED BEFORE THE SCRIPT cd's TO THE REPO ROOT, or option 1 is
# measured from the wrong directory.
# =============================================================================
resolve_config_path() {
  local given="$1" root="$2"
  local found dir

  if [ -f "$given" ]; then
    found="$given"
  elif [ -f "${root}/${given}" ]; then
    found="${root}/${given}"
  else
    echo "ERROR: config file not found: ${given}" >&2
    echo "  Looked in:" >&2
    echo "    $(pwd)/${given}" >&2
    echo "    ${root}/${given}" >&2
    echo >&2
    echo "  A config path is <unit-dir>/config/<env>-<region>.yaml, for example" >&2
    echo "    tests/selftest/config/test-use1.yaml" >&2
    return 1
  fi

  # Turn it into an absolute path. Note this is deliberately TWO statements.
  #
  # Writing it as one line is a trap:
  #     ABS="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  # If the cd fails, the exit status of the assignment comes from the LAST
  # command substitution - basename - which succeeded. So `set -e` does not
  # fire, ABS silently becomes "/filename", and the script carries on with
  # nonsense. Splitting it means a failed cd stops the script properly.
  dir="$(cd "$(dirname "$found")" && pwd)" || return 1
  found="${dir}/$(basename "$found")"

  case "$found" in
    "$root"/*)
      printf '%s' "${found#"$root"/}"
      ;;
    *)
      echo "ERROR: ${given} is outside the repository." >&2
      echo "  Repo root: ${root}" >&2
      echo "  Resolved:  ${found}" >&2
      return 1
      ;;
  esac
}


# =============================================================================
# cfg_get <config-file> <key> [default]
#
# WHAT  Prints one top-level value from a config YAML file.
# WHY   Every function here needs to read moduleVersion / region / regionCode.
# HOW   Shells out to Python. If the key is missing and no default was given,
#       it exits non-zero with a clear message rather than returning "".
#
# We use Python instead of `yq` because yq is not installed on the developer
# workstations, and ci/render-config.py already requires Python. One YAML
# parser to install, not two.
#
#   VERSION=$(cfg_get config/prod-use1.yaml moduleVersion)
# =============================================================================
cfg_get() {
  local file="$1" key="$2" default="${3-__REQUIRED__}"

  [ -f "$file" ] || { echo "ERROR: config not found: ${file}" >&2; return 1; }

  python - "$file" "$key" "$default" <<'PY'
import sys, yaml

path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh) or {}

if not isinstance(doc, dict):
    sys.exit(f"ERROR: {path} is not a YAML mapping")

if key in doc and doc[key] is not None:
    print(doc[key])
elif default != "__REQUIRED__":
    print(default)
else:
    sys.exit(f"ERROR: {path} has no `{key}:` — it is required")
PY
}


# =============================================================================
# modules_bucket <region-code>
#
# WHAT  Prints the name of the S3 bucket holding the module tarballs.
# HOW   Either uses $MODULES_BUCKET if set, or builds the name from the org,
#       environment, region code and deployment account id.
#
# The bootstrap stack `modules-store` outputs `ModulesBucketName` — that value
# can be exported as MODULES_BUCKET to skip the lookup entirely.
#
#   stadion-dev-use1-boot-bkt-modules-541074195889
#   ^org    ^env ^rgn                 ^deployment account
# =============================================================================
modules_bucket() {
  local region_code="$1"

  if [ -n "${MODULES_BUCKET:-}" ]; then
    printf '%s' "$MODULES_BUCKET"
    return 0
  fi

  # Always the deployment account, never the caller's. See MODULES_ACCOUNT_ID
  # at the top of this file for why this is not resolved from sts.
  local account="$MODULES_ACCOUNT_ID"

  [ -n "$account" ] || { echo "ERROR: DEPLOYMENT_ACCOUNT_ID is empty." >&2; return 1; }

  printf '%s-%s-%s-boot-bkt-modules-%s' \
    "$MODULES_ORGNAME" "$MODULES_ENV_CODE" "$region_code" "$account"
}


# =============================================================================
# region_for_code <region-code>
#
# WHAT  Turns a short region code into the full AWS region name.
# WHY   Configs and resource names use the short form (use1); the AWS CLI needs
#       the long form (us-east-1). They are one-to-one, so nobody should have to
#       type both.
#
# Add a line here when a new region is adopted. The same mapping exists in the
# modules repo's ci/publish.sh - keep them in step.
# =============================================================================
region_for_code() {
  case "$1" in
    use1) printf 'us-east-1' ;;
    usw2) printf 'us-west-2' ;;
    *)
      echo "ERROR: unknown region code '$1'." >&2
      echo "  Known codes: use1 (us-east-1), usw2 (us-west-2)" >&2
      echo "  Add new ones to region_for_code in ci/lib/modules.sh." >&2
      return 1
      ;;
  esac
}


# =============================================================================
# modules_purge          — delete ./modules/
# modules_current_version — print the version currently on disk, or fail if none
#
# The stamp file is how we know what is already downloaded, so we can skip the
# download when it is already correct.
# =============================================================================
modules_purge() {
  rm -rf "$MODULES_DIR"
}

modules_current_version() {
  [ -f "$MODULES_STAMP" ] || return 1
  tr -d '\r' < "$MODULES_STAMP" | head -1
}


# =============================================================================
# modules_expected_sha <version>
#
# WHAT  Prints the SHA256 recorded for a module version in ci/modules.lock.
#
# WHY   ci/fetch-modules.sh downloads by KEY, not by S3 versionId. The modules
#       bucket denies DeleteObject, but nothing stops a PutObject over an
#       existing key - that creates a new version and silently changes what
#       `moduleVersion: v0.5.0` resolves to. Versioning keeps the old bytes, but
#       nothing points at them.
#
#       The lock file is the answer: the hash lives in git, is reviewed in the
#       PR that adopts the version, and is checked on every build. Adopting a
#       module version is therefore two edits - the version in the unit config,
#       and the hash here. That is deliberate friction, and it is the point.
#
# FAILS CLOSED. An unknown version is an error, not a skip. A check that can be
# bypassed by forgetting to add a line is not a check.
# =============================================================================
modules_expected_sha() {
  local version="$1"

  if [ ! -f "$MODULES_LOCK" ]; then
    echo "ERROR: ${MODULES_LOCK} is missing." >&2
    echo "  It records the SHA256 of every module version this repo may use." >&2
    echo "  Without it a build would trust whatever the bucket happens to hold." >&2
    return 1
  fi

  local sha
  # Ignore comments and blank lines; take the first match.
  sha="$(awk -v v="$version" '$1 !~ /^#/ && $1 == v {print $2; exit}' "$MODULES_LOCK")"

  if [ -z "$sha" ]; then
    echo "ERROR: ${version} is not recorded in ${MODULES_LOCK}." >&2
    echo >&2
    echo "  Add the line printed by the modules repo's ci/publish.sh, or read" >&2
    echo "  it from that repo's CHECKSUMS file:" >&2
    echo >&2
    echo "    ${version}  <sha256>" >&2
    echo >&2
    echo "  This is failing on purpose. Pinning a version without its hash" >&2
    echo "  leaves the build trusting whatever bytes are in the bucket today." >&2
    return 1
  fi

  printf '%s\n' "$sha"
}


# =============================================================================
# modules_verify_sha <file> <expected-sha256> [quiet]
#
# WHAT  Compares a file's SHA256 against the expected value.
# WHY   See modules_expected_sha. This is the check itself.
#
# `quiet` suppresses the failure message, for the cache probe where a mismatch
# is handled by re-downloading rather than by failing the build.
# =============================================================================
modules_verify_sha() {
  local file="$1" expected="$2" quiet="${3:-}"
  local actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"

  [ "$actual" = "$expected" ] && return 0

  [ -n "$quiet" ] && return 1

  echo "ERROR: checksum mismatch for ${file}" >&2
  echo "  expected: ${expected}" >&2
  echo "  actual:   ${actual}" >&2
  echo >&2
  echo "  The bytes in the bucket are NOT the bytes this version was published" >&2
  echo "  with. Do not work around this by editing ${MODULES_LOCK}." >&2
  echo >&2
  echo "  Either the tarball was overwritten - published versions are supposed" >&2
  echo "  to be immutable - or the lock entry is wrong. Find out which before" >&2
  echo "  deploying anything built from it." >&2
  return 1
}


# =============================================================================
# modules_fetch <version> <region-code> <region>
#
# WHAT  Downloads and extracts one module version into ./modules/.
# HOW   Downloads the tarball to .build/ (kept, so a re-run is instant), deletes
#       the old ./modules/, extracts, then writes the stamp file.
#
# Most callers want modules_reconcile below instead — it decides whether a fetch
# is needed at all.
# =============================================================================
modules_fetch() {
  local version="$1" region_code="$2" region="$3"

  # -------------------------------------------------------------------------
  # There is deliberately NO local-folder shortcut here.
  #
  # An earlier version could copy modules straight from a modules-repo working
  # copy, to lint against changes that were not published yet. It was removed:
  # it let a build pass against files that would never be deployed, so a laptop
  # could say PASS while the same config failed in the pipeline.
  #
  # To test an unpublished module change, publish a version. That is what
  # version numbers are for, and it keeps every component tested the way it
  # will run in production.
  # -------------------------------------------------------------------------
  local tarball="${MODULES_ORGNAME}-modules-${version}.tar.gz"
  local cached="${MODULES_CACHE}/${tarball}"

  # -------------------------------------------------------------------------
  # ORDER MATTERS HERE. Everything that can be done offline is done first.
  #
  # Resolving the bucket name calls sts:GetCallerIdentity for the account id.
  # Doing that up front would make every lint require live AWS credentials,
  # even when the tarball is already cached and verifiable - so an expired SSO
  # session would fail a lint that needs nothing from AWS.
  #
  # So: look up the expected hash from the lock file (local), check the cache
  # against it (local), and only reach for credentials when there is actually
  # something to download.
  # -------------------------------------------------------------------------
  local expected
  expected="$(modules_expected_sha "$version")" || return 1

  mkdir -p "$MODULES_CACHE"

  # The cache is NOT trusted on the strength of the file existing. It used to
  # be, on the reasoning that published versions are immutable - but that was
  # an assumption about the bucket, and this whole checksum mechanism exists
  # because nothing enforced it. A cached file can also be truncated by a
  # killed build or edited by hand.
  if [ -f "$cached" ] && modules_verify_sha "$cached" "$expected" quiet; then
    echo "  ${tarball}  (cached, checksum verified)"
  else
    [ -f "$cached" ] && {
      echo "  cached copy failed verification - discarding and re-downloading"
      rm -f "$cached"
    }

    # Only now do we need credentials.
    local bucket
    bucket="$(modules_bucket "$region_code")" || return 1
    echo "  s3://${bucket}/${tarball}  (${region})"

    if ! aws s3 cp "s3://${bucket}/${tarball}" "$cached" --region "$region"; then
      echo "ERROR: could not download ${tarball}." >&2
      echo "  Check it was published:  aws s3 ls s3://${bucket}/" >&2
      echo "  Publish it (modules repo):  bash ci/publish.sh ${version}" >&2
      return 1
    fi
    if ! modules_verify_sha "$cached" "$expected"; then
      # Leave nothing behind that a later run might treat as good.
      rm -f "$cached"
      return 1
    fi
    echo "  checksum verified"
  fi

  modules_purge
  tar xzf "$cached" -C .

  # The tarball is built with `tar czf ... modules/`, so it must extract to
  # ./modules/. If it did not, every "../../modules/..." TemplateURL points at
  # nothing and the lint would fail for a misleading reason.
  [ -d "$MODULES_DIR" ] || { echo "ERROR: ${tarball} did not extract to ./${MODULES_DIR}/" >&2; return 1; }

  printf '%s\n' "$version" > "$MODULES_STAMP"
}


# =============================================================================
# modules_check_references <template-file>
#
# WHAT  Checks that every local TemplateURL in a template points at a file that
#       actually exists.
#
# WHY   This one is important. cfn-lint does NOT fail when a nested template is
#       missing - it logs "Template file not found" to stderr and still exits 0.
#       That means a typo in a module path, or a forgotten fetch, would make the
#       nested-parameter check quietly stop running while the build reports
#       success. Verified on cfn-lint 1.55.0.
#
#       In other words, without this function our validation fails OPEN, which
#       is the exact problem the local-path design was meant to avoid.
#
# HOW   Read the template, collect every TemplateURL value, ignore the http/s3
#       ones (those are resolved by CloudFormation, not by us), and confirm the
#       rest exist on disk relative to the template's own directory.
# =============================================================================
modules_check_references() {
  local template="$1"

  python - "$template" <<'PY'
import os, sys, yaml

template = sys.argv[1]
base = os.path.dirname(template)

# CloudFormation shorthand like !Sub and !GetAtt is not standard YAML, and
# PyYAML raises on tags it does not know. We do not care what those tags mean
# here - we only want the TemplateURL strings - so map every unknown "!Tag" to
# None and carry on.
class Loader(yaml.SafeLoader):
    pass

Loader.add_multi_constructor("!", lambda loader, suffix, node: None)

with open(template, encoding="utf-8") as fh:
    doc = yaml.load(fh, Loader=Loader) or {}

missing = []
for name, res in (doc.get("Resources") or {}).items():
    if not isinstance(res, dict) or res.get("Type") != "AWS::CloudFormation::Stack":
        continue

    url = (res.get("Properties") or {}).get("TemplateURL")
    if not isinstance(url, str):
        continue
    if url.startswith(("http://", "https://", "s3://")):
        continue

    path = os.path.normpath(os.path.join(base, url))
    if os.path.isfile(path):
        print(f"  OK  {name} -> {url}")
    else:
        missing.append((name, url, path))

for name, url, path in missing:
    print(f"  MISSING  {name} -> {url}", file=sys.stderr)
    print(f"           looked in {path}", file=sys.stderr)

if missing:
    print("", file=sys.stderr)
    print("Nested templates are missing. cfn-lint would skip the parameter", file=sys.stderr)
    print("check for these and still exit 0, so this is a hard failure here.", file=sys.stderr)
    print("Run: bash ci/fetch-modules.sh <version>   e.g. v0.2.0", file=sys.stderr)
    sys.exit(1)
PY
}


# =============================================================================
# modules_reconcile <config-file>
#
# WHAT  Makes ./modules/ match the moduleVersion in that config. Does nothing if
#       it already matches.
# WHY   This is the safe entry point — call it before linting, packaging or
#       deploying and you can be sure you are working against the pinned
#       version, not whatever a previous run left behind.
# HOW   Compare the stamp file to the config, and fetch only on a mismatch.
# =============================================================================
modules_reconcile() {
  local config="$1"
  local want have region_code region

  want="$(cfg_get "$config" moduleVersion)"   || return 1
  region_code="$(cfg_get "$config" regionCode)" || return 1
  region="$(cfg_get "$config" region)"         || return 1

  if have="$(modules_current_version)"; then
    if [ "$have" = "$want" ]; then
      # The stamp file says the right version. That is NOT enough to trust
      # what is on disk.
      #
      # The stamp is a version STRING written at extraction time. It says
      # nothing about the bytes next to it, so anything that edits modules/
      # afterwards leaves the stamp reading "correct" - and the build lints
      # against files that will never be deployed. That has already happened
      # once in this repo: a module template was edited in the fetched copy
      # after the version was published, and nothing detected it.
      #
      # So re-extract from the cached tarball, which modules_fetch verifies
      # against ci/modules.lock. The tarball is tens of kilobytes and no
      # network call is made when the cache is warm and verified, so this
      # costs milliseconds and makes "modules/ is v0.5.0" mean the bytes are
      # v0.5.0's, not just that a file says so.
      echo "modules/ stamped ${want} — re-verifying against ${MODULES_LOCK}"
    else
      echo "modules/ is at ${have}, config pins ${want} — refetching"
    fi
  else
    echo "modules/ not present — fetching ${want}"
  fi

  modules_fetch "$want" "$region_code" "$region" || return 1

  echo "modules/ now at $(modules_current_version)"
}
