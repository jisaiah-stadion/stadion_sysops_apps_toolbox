"""
ci/lib/naming.py - builds resource names from ci/naming.yaml.

WHAT
    Turns a set of segment values (env, region, tier, app, resource, qualifier)
    into one finished AWS resource name, and refuses to return a name that
    breaks the service's rules.

WHY
    The naming convention is still being reviewed, and it has to work for every
    AWS service rather than one. Keeping it in a data file (ci/naming.yaml) and
    reading it here means changing the convention is a one-file edit, and every
    service's length limit and character rules are recorded in one place.

    It fails loudly and never truncates. A truncated name is a name nobody can
    predict, search for, or match with an IAM wildcard - so a name that does not
    fit is a build failure, not something to quietly shorten.

    Not every name can follow the convention. A bucket that has to match a DNS
    name cannot, for instance. Those are supplied by the unit config and checked
    with validate() instead of compose() - same AWS rules, no pattern.

HOW
    schema = load("ci/naming.yaml")

    name = compose(
        schema,
        resource_type="s3-bucket",
        values={"env": "prod", "region": "use1", "tier": "wkl", "app": "payapi"},
        qualifier="assets",
        account_id="111122223333",
    )
    # -> "prod-use1-wkl-payapi-bkt-assets-111122223333"

Every failure raises NamingError with a message saying what was wrong and what
to do about it.
"""

import re
import yaml


class NamingError(Exception):
    """Raised when a name cannot be built, or breaks a rule in naming.yaml."""


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load(path):
    """Read and sanity-check naming.yaml.

    We check the shape here rather than letting a typo surface later as a
    confusing KeyError deep inside compose().
    """
    with open(path, encoding="utf-8") as fh:
        schema = yaml.safe_load(fh) or {}

    for section in ("patterns", "rules", "segments", "resourceTypes"):
        if section not in schema:
            raise NamingError(f"{path} is missing the `{section}:` section")

    for scope in ("regional", "global"):
        if scope not in schema["patterns"]:
            raise NamingError(f"{path} has no `patterns.{scope}` pattern")

    return schema


# ---------------------------------------------------------------------------
# Composing
# ---------------------------------------------------------------------------

def compose(schema, resource_type, values, code=None, qualifier=None,
            account_id=None):
    """Build one resource name.

    schema         parsed naming.yaml
    resource_type  a key under resourceTypes, e.g. "s3-bucket"
    values         segment values from the unit config: env, region, tier, app
    code           overrides the resource type's default `code`
    qualifier      optional trailing segment, e.g. "assets", "priv"
    account_id     required only for resource types with appendAccountId
    """
    rt = schema["resourceTypes"].get(resource_type)
    if rt is None:
        known = ", ".join(sorted(schema["resourceTypes"]))
        raise NamingError(
            f"unknown resource type '{resource_type}'.\n"
            f"  Known types: {known}\n"
            f"  Add a new one to ci/naming.yaml - no code change needed."
        )

    rules = schema["rules"]
    separator = rt.get("separator", rules.get("separator", "-"))

    # --- 1. gather the segment values ---------------------------------------
    #
    # org and project come from the SCHEMA, not from `values`. They are
    # properties of the repository rather than of a unit, so a config cannot
    # set them and cannot make two environments disagree about them.
    segments = {
        "org": schema.get("org", ""),
        "project": schema.get("project", ""),
        "env": values.get("env", ""),
        "region": values.get("region", ""),
        "tier": values.get("tier", ""),
        "app": values.get("app", ""),
        "resource": code if code is not None else rt.get("code", ""),
        "qualifier": qualifier or "",
    }
    segments = {k: ("" if v is None else str(v)) for k, v in segments.items()}

    # --- 2. check each value is allowed -------------------------------------
    # Catches a typo like env: producton (should be prod) here, at build time, rather
    # than after a wrongly named resource exists.
    for seg, allowed in (schema.get("segments") or {}).items():
        if not allowed:
            continue
        value = segments.get(seg, "")
        if value and value not in allowed:
            raise NamingError(
                f"segment '{seg}' has value '{value}', which is not allowed.\n"
                f"  Allowed: {', '.join(allowed)}\n"
                f"  Fix the unit config, or add the value to ci/naming.yaml."
            )

    # --- 3. fill in the pattern ---------------------------------------------
    scope = rt.get("scope", "regional")
    if scope not in schema["patterns"]:
        raise NamingError(
            f"resource type '{resource_type}' has scope '{scope}', "
            f"but ci/naming.yaml has no pattern by that name."
        )

    pattern = schema["patterns"][scope]

    # A regional name has no region segment, so blank it out. Otherwise a
    # pattern that does not use {region} would still trip the "unused value"
    # check below.
    if "{region}" not in pattern:
        segments["region"] = ""

    missing = [
        seg for seg in re.findall(r"\{(\w+)\}", pattern)
        if seg not in segments
    ]
    if missing:
        raise NamingError(
            f"pattern '{pattern}' uses {{{missing[0]}}}, which is not a known "
            f"segment. Add it to `segments:` in ci/naming.yaml."
        )

    # Split the pattern into its literal separators and placeholders so an empty
    # segment can take its separator with it. Otherwise a unit with no `app`
    # produces "prod-net--vpc".
    parts = []
    for token in re.split(r"(\{\w+\})", pattern):
        if not token:
            continue
        if token.startswith("{"):
            parts.append(segments[token[1:-1]])
        else:
            parts.append(token)

    name = "".join(parts)

    if rules.get("omitEmptySegments", True):
        # Collapse the runs of separators left behind by empty segments, then
        # trim any at the ends.
        name = re.sub(re.escape(separator) + r"{2,}", separator, name)
        name = name.strip(separator)

    # --- 4. account id suffix -----------------------------------------------
    # S3 bucket names must be unique across every AWS account in the world, so
    # the account id is what makes ours definitely ours.
    if rt.get("appendAccountId"):
        if not account_id:
            raise NamingError(
                f"resource type '{resource_type}' needs the account id, but the "
                f"unit config has no `accountId:`."
            )
        name = f"{name}{separator}{account_id}"

    # --- 5. case ------------------------------------------------------------
    case = rt.get("case", rules.get("case", "lower"))
    if case == "lower":
        name = name.lower()
    elif case == "upper":
        name = name.upper()

    # --- 6. the checks that make this worth doing ---------------------------
    _check_length(name, resource_type, rt)
    _check_charset(name, resource_type, rt)

    return name


def validate(schema, resource_type, name):
    """Check a name somebody supplied by hand, instead of composing one.

    WHY THIS EXISTS
        Some resources cannot use the convention, because their name is decided
        by something outside this platform. The clearest case is an S3 bucket
        that has to match a DNS name:

            bucket   dev.stadionmoney.com
            served   https://dev.stadionmoney.com via CloudFront

        A composed name like prod-use1-wkl-web-bkt-assets-111122223333 cannot
        be made to match a domain, so for those the unit config supplies the
        name outright and this function is all that runs.

    WHAT IS STILL ENFORCED
        The AWS rules - length and character set - because those are the
        service's, not ours, and an illegal name fails at create time no matter
        who chose it. Catching it here keeps the promise that a name which
        cannot exist fails on a laptop in a second.

    WHAT IS NOT ENFORCED
        The pattern, the segment values, the case fix-up and the account id
        suffix. A supplied name is taken exactly as written. It is not
        lowercased - an uppercase letter in a bucket name is rejected with a
        clear message rather than silently corrected, because a name that
        changes shape between the config and AWS is a name nobody can grep for.

    Returns the name unchanged, so it reads naturally at the call site.
    """
    rt = schema["resourceTypes"].get(resource_type)
    if rt is None:
        known = ", ".join(sorted(schema["resourceTypes"]))
        raise NamingError(
            f"unknown resource type '{resource_type}'.\n"
            f"  Known types: {known}"
        )

    if not name:
        raise NamingError(
            f"an explicit {resource_type} name was given but it is empty.\n"
            f"  Remove the key to use the composed name instead."
        )

    _check_length(name, resource_type, rt)
    _check_charset(name, resource_type, rt)
    return name


def _check_length(name, resource_type, rt):
    """Reject a name longer than the AWS limit for its service."""
    limit = rt.get("maxLength")
    if limit is None or len(name) <= limit:
        return

    raise NamingError(
        f"name is {len(name)} characters, but {resource_type} allows "
        f"{limit}.\n"
        f"  Name: {name}\n"
        f"  Shorten it by dropping the qualifier first, then the app code.\n"
        f"  Names are never truncated automatically - a truncated name is one\n"
        f"  nobody can predict or match with an IAM wildcard."
    )


def _check_charset(name, resource_type, rt):
    """Reject a name containing characters the service does not accept."""
    charset = rt.get("charset")
    if not charset or re.match(charset, name):
        return

    raise NamingError(
        f"name is not valid for {resource_type}.\n"
        f"  Name:    {name}\n"
        f"  Must match: {charset}\n"
        f"  Usually an underscore, an uppercase letter, or a leading digit."
    )
