#!/usr/bin/env bash
# =============================================================================
# ci/fetch-modules.sh
#
# WHAT
#   Downloads a specific version of the module library into ./modules/.
#
# USAGE
#   bash ci/fetch-modules.sh <version> [region-code]
#
#   bash ci/fetch-modules.sh v0.2.0          # from us-east-1 (default)
#   bash ci/fetch-modules.sh v0.2.0 usw2     # from us-west-2
#
# WHICH VERSION SHOULD I USE?
#   Look in the module library's version tracker. It lists every published
#   version, what changed, and whether the change breaks anything:
#
#       stadion_sysops_modules/CHANGELOG.md
#
#   Or list what is actually in the bucket:
#
#       aws s3 ls s3://stadion-dev-use1-boot-bkt-modules-<account>/
#
# WHY THIS SCRIPT EXISTS
#   You do not normally need it. ci/lint.sh and ci/package-and-deploy.sh both
#   download modules on their own, at the version the unit's config pins, and
#   skip the download when ./modules/ is already correct.
#
#   This is the repair tool. It deletes ./modules/ and downloads again, for when
#   you have edited files under it by hand, or a download was interrupted, or
#   you want to read a different version's templates.
#
# IMPORTANT: THIS DOES NOT CHANGE WHAT GETS DEPLOYED
#   Deploys read `moduleVersion:` from the unit's config file, never from here.
#   Fetching v0.2.0 by hand and then deploying a unit pinned to v0.1.0 will
#   re-download v0.1.0 first. To change what deploys, edit the config.
# =============================================================================

set -euo pipefail

VERSION="${1:?usage: fetch-modules.sh <version> [region-code]   e.g. fetch-modules.sh v0.2.0}"

# us-east-1 is the primary region and the one almost every fetch wants. The
# us-west-2 copy exists for DR deploys.
REGION_CODE="${2:-use1}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/ci/lib/modules.sh"
cd "$REPO_ROOT"

# --- validate the version ----------------------------------------------------
# Catching the format here gives a useful message instead of an S3 404 that
# looks like the version was never published.
if ! printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: '${VERSION}' is not a version number." >&2
  echo "  Expected vMAJOR.MINOR.PATCH, for example v0.2.0" >&2
  echo "  Published versions are listed in stadion_sysops_modules/CHANGELOG.md" >&2
  exit 1
fi

REGION="$(region_for_code "$REGION_CODE")"

echo "=== Fetching modules ${VERSION} from ${REGION} ==="

# Delete what is there first. modules_fetch would overwrite anyway, but being
# explicit means a half-extracted directory from an interrupted run cannot
# survive into the new copy.
modules_purge

modules_fetch "$VERSION" "$REGION_CODE" "$REGION"

echo
echo "modules/ now at $(modules_current_version)"
echo
echo "Contents:"
ls -1 "$MODULES_DIR"
echo
echo "Note: deploys use the moduleVersion in each unit's config, not this."
