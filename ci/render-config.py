#!/usr/bin/env python3
"""
ci/render-config.py - turns a unit's config file into arguments for
`aws cloudformation deploy`.

WHAT
    Reads config/<env>-<region>.yaml plus the unit's main.yaml, and prints the
    parameters, tags or stack name the deploy command needs.

WHY
    This is the Terraform `.tfvars` step. It exists as a separate script for one
    reason beyond convenience: resource names are built here, in Python, where
    ci/naming.yaml can be read and its length and character limits enforced.
    CloudFormation's !Sub can join strings together but cannot check that the
    result fits in the 32 characters a load balancer allows - so a name composed
    in a template fails at create time, or worse, does not fail at all.

    It also only ever emits parameters the template actually declares. Passing
    an undeclared parameter is an error from `aws cloudformation deploy`, and
    that error does not say which one.

USAGE
    python ci/render-config.py <config.yaml> --emit parameters
    python ci/render-config.py <config.yaml> --emit tags
    python ci/render-config.py <config.yaml> --emit stack-name
    python ci/render-config.py <config.yaml> --emit json     # all of it, to read

    Output is one Key=Value per line, so a caller can read it into a shell array
    without worrying about spaces in values.

WHERE EACH PARAMETER VALUE COMES FROM, IN ORDER
    1. A name composed from the `Naming:` block in the unit's main.yaml.
    2. The `parameters:` map in the unit config - explicit values and overrides.
    3. The repository constants in ci/naming.yaml:
           OrgName <- org  ProjectName <- project
       A config may restate these but not contradict them.
    4. The standard config keys, matched by parameter name:
           Env <- env      RegionCode <- regionCode   Region <- region
           Tier <- tier    App <- app                 AccountId <- accountId
    5. The parameter's Default in main.yaml, if it has one. Nothing is emitted;
       CloudFormation uses the default.
    6. Otherwise the build fails, naming the parameter.
"""

import argparse
import os
import re
import sys

import yaml

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import naming  # noqa: E402


# Config keys that map to a conventionally named template parameter. This is
# what stops every unit from having to restate the same six values.
STANDARD_PARAMETERS = {
    "Env": "env",
    "RegionCode": "regionCode",
    "Region": "region",
    "Tier": "tier",
    "App": "app",
    "AccountId": "accountId",
}

# Parameters filled from the CONSTANTS in ci/naming.yaml rather than from the
# unit config.
#
# These are properties of the repository, not of a unit: there is one
# organisation and this repo builds one project. naming.yaml says so, and says
# why - if they were per-config they could disagree between environments, and
# a boundary ARN or a KMS alias built from the wrong one fails in a way that
# reads like a missing resource rather than a typo.
#
# A config may restate one of these, and the bootstrap configs do. A config
# that sets a DIFFERENT value is an error. See resolve_parameters below.
SCHEMA_CONSTANT_PARAMETERS = {
    "OrgName": "org",
    "ProjectName": "project",
}

# Tags applied to every stack, taken from the config. CloudFormation copies
# stack-level tags onto every resource that supports tagging, which is how
# SecOps tooling finds things at runtime without reading stack outputs.
STANDARD_TAGS = {
    "Env": "env",
    "Tier": "tier",
    "App": "app",
}


class CfnLoader(yaml.SafeLoader):
    """A YAML loader that tolerates CloudFormation's !Sub, !Ref, !GetAtt tags.

    PyYAML raises on any tag it does not recognise. We only need the plain data
    from main.yaml - its Parameters and Metadata - so every unknown "!Tag"
    becomes None and parsing continues.
    """


CfnLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def read_yaml(path, loader=yaml.SafeLoader):
    if not os.path.isfile(path):
        die(f"file not found: {path}")
    with open(path, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=loader) or {}


def validate_account_id(config, config_path):
    """Refuse a config whose accountId is not a real 12-digit account.

    WHY THIS IS HERE

    accountId is what builds the execution role ARN the deploy passes to
    CloudFormation. A placeholder like REPLACE_WITH_TEST_ACCOUNT_ID produces a
    malformed ARN, and the failure surfaces only at deploy time - after the
    pipeline's Validate stage has gone green and someone has read it as "this
    environment is ready".

    Checking it here means a config that cannot deploy cannot lint either. That
    is the whole point of the lint stage: fail on the laptop or in Validate,
    not half-way through a promote run.

    The format check is all that is possible offline. It cannot tell you the
    account EXISTS, or that bootstrap/deployment-roles has been run in it -
    only that somebody filled the field in.
    """
    account_id = config.get("accountId")

    if account_id is None:
        die(f"{config_path}: no `accountId`.\n"
            f"  Every config names the account it deploys into.")

    account_id = str(account_id)

    if not re.fullmatch(r"\d{12}", account_id):
        die(f"{config_path}: `accountId` is not a 12-digit AWS account id.\n"
            f"  got: {account_id!r}\n"
            f"\n"
            f"  If that is a placeholder, this environment has no account yet.\n"
            f"  Assign one and run bootstrap/deployment-roles in it before\n"
            f"  deploying, or the deploy fails on assume-role.")


# Values that mean "somebody meant to fill this in and did not".
#
# Kept deliberately narrow. A loose pattern here would reject a legitimate
# value one day and send an engineer hunting through this file, so it matches
# only the literal markers this repo actually uses as placeholders.
PLACEHOLDER_PATTERN = re.compile(
    r"REPLACE[-_ ]?ME|REPLACE[-_ ]?WITH|CHANGE[-_ ]?ME|FILL[-_ ]?ME[-_ ]?IN",
    re.IGNORECASE,
)


def find_placeholders(node, path="") -> list:
    """Walk a config and return [(key path, value)] for every placeholder value.

    Recursive because placeholders hide in nested maps - `parameters:` is one
    level down, and a future config could nest further.
    """
    found = []

    if isinstance(node, dict):
        for key, value in node.items():
            found += find_placeholders(value, f"{path}.{key}" if path else str(key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found += find_placeholders(value, f"{path}[{index}]")
    elif isinstance(node, str) and PLACEHOLDER_PATTERN.search(node):
        found.append((path, node))

    return found


def validate_no_placeholders(config, config_path):
    """Refuse a config that still contains a REPLACE-ME style value.

    WHY THIS IS HERE

    A placeholder is a config that CANNOT deploy, and the whole point of the
    lint stage is that such a config fails on a laptop in a second rather than
    part-way through a pipeline run.

    Without this check the failure arrives much later and much less clearly.
    tier0-networking/flow-logs carried

        FlowLogRoleArn: 'arn:aws:iam::923339306134:role/REPLACE-ME-flow-logs'

    which is a syntactically valid ARN, so cfn-lint passed it, the pipeline's
    Validate stage went green, the change set built, the log group was created,
    and the flow log then failed against a role in an account we do not own.
    CloudFormation reported it as:

        Embedded stack ... was not successfully created: null

    Six minutes and a rolled-back stack to learn something a string match knows
    instantly. See validate_account_id above - same class of problem.

    THIS CANNOT CATCH EVERYTHING. A value that is merely WRONG rather than
    obviously unfilled still gets through; only a deploy finds those. That is
    the argument for placeholders always looking like placeholders.
    """
    found = find_placeholders(config)
    if not found:
        return

    lines = "".join(f"    {path}: {value!r}\n" for path, value in found)
    die(f"{config_path}: unfilled placeholder value(s):\n"
        f"{lines}"
        f"\n"
        f"  This config cannot deploy. Failing here rather than part-way\n"
        f"  through a pipeline run, after resources have been created.\n"
        f"\n"
        f"  Fill the value in, or if the thing it refers to does not exist\n"
        f"  yet, that dependency has to be built before this unit deploys.")


def unit_dir_of(config_path):
    """A unit is a directory holding main.yaml and config/.

    So the unit directory is two levels up from the config file:

        tier0-networking/vpc/config/prod-use1.yaml
        ^------- unit ------^ ^--- config ----^
    """
    return os.path.dirname(os.path.dirname(os.path.abspath(config_path)))


def build_names(schema, template, config):
    """Build every name declared in main.yaml's `Metadata: Naming:` block.

    The declaration lives in main.yaml rather than the config file because the
    set of resources a unit creates is the same in every environment - only the
    values filling the name change.

        Metadata:
          Naming:
            AssetsBucketName:
              type: s3-bucket
              qualifier: assets

    Returns {parameter name: composed name}.
    """
    declarations = (template.get("Metadata") or {}).get("Naming") or {}
    overrides = config.get("parameters") or {}
    values = {key: config.get(key, "") for key in ("env", "region", "tier", "app")}

    # The pattern's {region} segment is the SHORT code (use1), not us-east-1.
    values["region"] = config.get("regionCode", "")

    names = {}
    for parameter, spec in declarations.items():
        if not isinstance(spec, dict) or "type" not in spec:
            die(f"Metadata.Naming.{parameter} needs at least a `type:` key")

        # ------------------------------------------------------------------
        # AN EXPLICIT NAME IN THE CONFIG WINS.
        #
        # WHY THIS IS NEEDED
        #   Some names are not ours to choose. An S3 bucket serving
        #   dev.stadionmoney.com through CloudFront is the clearest case - the
        #   bucket name has to match the domain, and no pattern of
        #   env/tier/app/resource segments can produce a domain.
        #
        #   So the config may set the parameter directly, and that value is
        #   used exactly as written. The AWS length and character rules still
        #   apply - see naming.validate - because those belong to the service,
        #   not to our convention.
        #
        # WHY THE PRECEDENCE IS THIS WAY ROUND
        #   It used to be the opposite: a composed name beat a config value, so
        #   setting the parameter in the config did NOTHING. It was not ignored
        #   loudly either - the parameter IS declared by main.yaml, so the
        #   "config sets a key main.yaml does not declare" warning stayed quiet.
        #   You got the composed name and no indication why.
        #
        #   Silently discarding something someone deliberately wrote is the
        #   worst of the options, so the explicit value now wins and says so.
        # ------------------------------------------------------------------
        if parameter in overrides:
            supplied = str(overrides[parameter])
            try:
                names[parameter] = naming.validate(schema, spec["type"], supplied)
            except naming.NamingError as exc:
                die(f"{parameter} is set explicitly in the config, but that "
                    f"value is not a valid {spec['type']} name:\n"
                    f"  {exc}\n"
                    f"\n"
                    f"  Remove it from `parameters:` to use the composed name.")

            print(
                f"NOTE: {parameter} = {supplied!r} from the config, "
                f"not the composed name.",
                file=sys.stderr,
            )
            continue

        try:
            names[parameter] = naming.compose(
                schema,
                resource_type=spec["type"],
                values=values,
                code=spec.get("code"),
                qualifier=spec.get("qualifier"),
                account_id=config.get("accountId"),
            )
        except naming.NamingError as exc:
            die(f"could not build {parameter}:\n  {exc}")

    return names


def resolve_parameters(schema, template, config, names):
    """Work out a value for every parameter main.yaml declares.

    Only declared parameters are returned - see the module docstring for why.
    """
    declared = template.get("Parameters") or {}
    overrides = config.get("parameters") or {}

    # A config may RESTATE a repository constant but must not CONTRADICT it.
    #
    # Restating is harmless and several bootstrap configs do it - those stacks
    # are deployed by hand and carry the value explicitly. Contradicting it is
    # the failure worth catching: two sources of truth for a value that appears
    # in permissions boundary ARNs, bucket names and KMS aliases, where the
    # wrong one fails as "no such resource" rather than as a typo.
    for parameter, key in SCHEMA_CONSTANT_PARAMETERS.items():
        if parameter in overrides and str(overrides[parameter]) != str(schema.get(key, "")):
            die(
                f"config sets `{parameter}: {overrides[parameter]}`, which contradicts\n"
                f"  `{key}: {schema.get(key)}` in ci/naming.yaml.\n"
                f"  This value is a property of the repository, not of a unit.\n"
                f"  Remove it from the config, or change ci/naming.yaml if the\n"
                f"  whole repository is being renamed."
            )

    resolved = {}
    unresolved = []

    for parameter, spec in declared.items():
        spec = spec or {}

        if parameter in names:
            resolved[parameter] = names[parameter]
        elif parameter in SCHEMA_CONSTANT_PARAMETERS and schema.get(
            SCHEMA_CONSTANT_PARAMETERS[parameter]
        ):
            resolved[parameter] = schema[SCHEMA_CONSTANT_PARAMETERS[parameter]]
        elif parameter in overrides:
            resolved[parameter] = overrides[parameter]
        elif parameter in STANDARD_PARAMETERS and config.get(STANDARD_PARAMETERS[parameter]):
            resolved[parameter] = config[STANDARD_PARAMETERS[parameter]]
        elif "Default" in spec:
            continue          # CloudFormation will use the template's default
        else:
            unresolved.append(parameter)

    if unresolved:
        die(
            "no value for these template parameters:\n"
            + "".join(f"    {p}\n" for p in unresolved)
            + "  Add them under `parameters:` in the config, declare them in\n"
            + "  main.yaml's `Metadata: Naming:` block, or give them a Default."
        )

    # Warn about config values nobody asked for. Usually a rename that was done
    # in main.yaml but not in the config, which would otherwise pass silently.
    for key in overrides:
        if key not in declared:
            print(
                f"WARNING: config sets `{key}`, which main.yaml does not declare "
                f"- it will be ignored.",
                file=sys.stderr,
            )

    return {k: str(v) for k, v in resolved.items()}


def resolve_capabilities(config):
    """The capabilities `aws cloudformation deploy` must be given.

    CAPABILITY_NAMED_IAM is the default because ci/naming.yaml gives IAM roles
    explicit names, and CloudFormation requires the stronger acknowledgement for
    named IAM resources. A unit that creates no IAM at all can narrow this with
    `capabilities:` in its config.
    """
    capabilities = config.get("capabilities")
    if not capabilities:
        return ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]
    if isinstance(capabilities, str):
        return [capabilities]
    return [str(c) for c in capabilities]


def resolve_tags(config):
    tags = {}
    for tag, key in STANDARD_TAGS.items():
        if config.get(key):
            tags[tag] = str(config[key])
    for tag, value in (config.get("tags") or {}).items():
        tags[tag] = str(value)
    return tags


def resolve_stack_name(schema, config, unit_dir):
    """The stack name: taken from the config if set, otherwise composed.

    Composed form uses the unit's directory name as the resource segment, so
    tier0-networking/vpc/ deploys as `prod-net-vpc`.
    """
    if config.get("stackName"):
        return str(config["stackName"])

    try:
        return naming.compose(
            schema,
            resource_type="cloudformation-stack",
            values={
                "env": config.get("env", ""),
                "region": config.get("regionCode", ""),
                "tier": config.get("tier", ""),
                "app": config.get("app", ""),
            },
            code=os.path.basename(unit_dir),
        )
    except naming.NamingError as exc:
        die(f"could not build the stack name:\n  {exc}")


def main():
    # Emit Unix line endings, on every platform.
    #
    # On Windows, Python translates "\n" to "\r\n" on stdout by default. A shell
    # reading this output with `mapfile` strips the "\n" but keeps the "\r", so
    # every value silently gains a trailing carriage return - and then the AWS
    # CLI rejects "CAPABILITY_IAM\r" with an enum error naming a value that
    # looks perfectly correct on screen.
    #
    # Command substitution "$( )" happens to strip it, which is why this only
    # broke the places that read arrays.
    sys.stdout.reconfigure(newline="\n")

    parser = argparse.ArgumentParser(
        description="Render a unit config into deploy arguments."
    )
    parser.add_argument("config", help="path to config/<env>-<region>.yaml")
    parser.add_argument(
        "--emit",
        choices=["parameters", "tags", "stack-name", "capabilities", "json"],
        default="parameters",
    )
    parser.add_argument(
        "--naming",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "naming.yaml"),
        help="path to naming.yaml (default: ci/naming.yaml)",
    )
    args = parser.parse_args()

    unit_dir = unit_dir_of(args.config)
    template_path = os.path.join(unit_dir, "main.yaml")

    config = read_yaml(args.config)
    template = read_yaml(template_path, loader=CfnLoader)

    # Only on the paths a DEPLOY depends on.
    #
    # `--emit stack-name` is used by ci/stack-registry.py, which walks every
    # config in the repo to build the registry. Validating there would break it
    # two ways: on bootstrap configs, which have a different shape and carry no
    # top-level accountId at all, and on environments whose account is not
    # assigned yet - neither of which stops a stack NAME from being correct.
    if args.emit != "stack-name":
        validate_account_id(config, args.config)
        validate_no_placeholders(config, args.config)

    try:
        schema = naming.load(args.naming)
    except naming.NamingError as exc:
        die(str(exc))

    names = build_names(schema, template, config)
    parameters = resolve_parameters(schema, template, config, names)
    tags = resolve_tags(config)
    capabilities = resolve_capabilities(config)
    stack_name = resolve_stack_name(schema, config, unit_dir)

    if args.emit == "parameters":
        for key, value in parameters.items():
            print(f"{key}={value}")

    elif args.emit == "tags":
        for key, value in tags.items():
            print(f"{key}={value}")

    elif args.emit == "stack-name":
        print(stack_name)

    elif args.emit == "capabilities":
        for capability in capabilities:
            print(capability)

    elif args.emit == "json":
        import json
        print(json.dumps(
            {
                "stackName": stack_name,
                "composedNames": names,
                "parameters": parameters,
                "tags": tags,
                "capabilities": capabilities,
            },
            indent=2,
        ))


if __name__ == "__main__":
    main()
