#!/usr/bin/env python3
"""
ci/stack-registry.py

WHAT
    Builds a catalogue of every stack this repo deploys: its name, the outputs
    it publishes, and which other stacks it reads from. Writes it to
    docs/STACK-REGISTRY.md.

    That file is GENERATED AND GITIGNORED - it is not in the repository. Build
    it when you want to read it; ci/lint.sh rebuilds it on every run anyway.

WHY
    Two problems, one tool.

    1. A new engineer wanting to consume a value has nowhere to look. The stack
       names live in ci/naming.yaml plus a directory name, the outputs live in
       each unit's main.yaml, and nothing joins them up.

    2. NOTHING VERIFIES A CROSS-STACK REFERENCE. A unit says

           StackName: !Sub '${Env}-net-vpc'
           OutputName: VpcId

       and CloudFormation only finds out whether that stack and that output
       exist when the change set is built - against a live account. A typo in
       an output name, or a unit renamed without its consumers updated, is not
       caught by cfn-lint at all.

       This script resolves every reference against the units in the repo and
       fails if one does not line up.

    Generating rather than hand-writing matters because a hand-maintained list
    drifts the moment someone adds an output and forgets the doc. Here the doc
    IS the parse, so it cannot disagree with the templates.

HOW
    For every directory holding a main.yaml:
      - render each config's stack name with ci/render-config.py, so the name
        comes from exactly the same code path a deploy uses
      - read the Outputs block from main.yaml
      - find every Fn::GetStackOutput and resolve its StackName
    Then cross-reference, and write Markdown.

USAGE
    python ci/stack-registry.py              # rewrite docs/STACK-REGISTRY.md
    python ci/stack-registry.py --check      # resolve refs, do NOT write

    ci/lint.sh runs the FIRST form. Reason 2 above - resolving every
    cross-stack reference - happens either way and is the part that stops a
    broken deploy; it needs no file on disk to compare against.

    --check additionally compares the file to what the repo produces. That is
    only useful if you have chosen to keep a copy. It is not used by the build:
    it was, as a gate, and it failed three pipeline runs for a one-line
    documentation diff, because a derived file kept in git needs somebody to
    remember to refresh it. The file is gitignored now instead.

    Neither form makes an AWS call.

WHERE TO RUN IT
    From the repo root. Paths here are relative.
"""

import argparse
import os
import re
import subprocess
import sys
import yaml

DOC_PATH = "docs/STACK-REGISTRY.md"

# Directories searched for units. A unit is any directory directly inside one
# of these that contains a main.yaml.
UNIT_ROOTS = ["bootstrap", "tier0-networking", "tier1-security",
              "tier2-platform", "tier3-workloads", "tests"]


# ---------------------------------------------------------------------------
# YAML loading that keeps CloudFormation's tags
#
# WHY  render-config.py throws every "!Tag" away, because it only wants the
#      plain data. Here the tags ARE the data - a GetStackOutput reference is
#      the thing being catalogued - so each one is kept as a small dict.
# ---------------------------------------------------------------------------
class CfnLoader(yaml.SafeLoader):
    pass


def _keep_tag(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        value = loader.construct_mapping(node, deep=True)
    return {"__tag__": tag_suffix, "__value__": value}


CfnLoader.add_multi_constructor("!", _keep_tag)


def load_yaml(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=CfnLoader) or {}


def walk(node):
    """Yield every dict and list nested anywhere inside node."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def find_units():
    """Every directory holding a main.yaml, with its config files."""
    units = []
    for root in UNIT_ROOTS:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            unit_dir = os.path.join(root, name)
            main = os.path.join(unit_dir, "main.yaml")
            if not os.path.isfile(main):
                continue
            config_dir = os.path.join(unit_dir, "config")
            configs = []
            if os.path.isdir(config_dir):
                configs = [os.path.join(config_dir, c)
                           for c in sorted(os.listdir(config_dir))
                           if c.endswith(".yaml")]
            units.append({"dir": unit_dir.replace("\\", "/"),
                          "tier": root, "name": name,
                          "main": main, "configs": configs})
    return units


def stack_name_for(config_path):
    """Ask render-config.py, so the name matches what a deploy would use."""
    out = subprocess.run(
        [sys.executable, "ci/render-config.py", config_path, "--emit", "stack-name"],
        capture_output=True, text=True)
    if out.returncode != 0:
        return None, out.stderr.strip()
    return out.stdout.strip().replace("\r", ""), None


def config_env(config_path):
    with open(config_path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}
    return {k: str(cfg.get(k, "")) for k in
            ("env", "region", "regionCode", "tier", "app", "accountId")}


def read_config(config_path):
    with open(config_path, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def config_rows(config_path):
    """Stack name, env and region for one config file.

    TWO CONFIG FORMATS EXIST, and they are not interchangeable.

    PIPELINE configs - everything under tier0 and above - have a top-level
    `region:` and a `parameters:` map. ci/render-config.py composes their stack
    name from ci/naming.yaml, and a deploy uses exactly that code path, so this
    asks render-config.py rather than reimplementing the rules.

    MANUAL bootstrap configs have a `deployments:` list instead, one entry per
    region, and state `stackName:` outright. They are applied by hand before the
    pipeline exists, so render-config.py has never been able to read them and is
    not supposed to. Their name is taken straight from the file.

    Returns (rows, error). Each row is (env, region, stack name, values, manual).
    """
    cfg = read_config(config_path)

    if "deployments" in cfg:
        name = cfg.get("stackName")
        if not name:
            return [], f"{config_path}: has `deployments:` but no `stackName:`"
        env = str((cfg.get("tags") or {}).get("Env", ""))
        rows = []
        for dep in cfg["deployments"]:
            region = str(dep.get("region", ""))
            params = dep.get("parameters") or {}
            values = {"env": env, "region": region,
                      "regionCode": str(params.get("RegionCode", "")),
                      "tier": "boot", "app": "",
                      "accountId": str(cfg.get("accountId", ""))}
            rows.append((env, region, name, values, True))
        return rows, None

    name, err = stack_name_for(config_path)
    if err:
        return [], f"{config_path}: could not render a stack name - {err}"
    vals = config_env(config_path)
    return [(vals["env"], vals["region"], name, vals, False)], None


def resolve_sub(expr, values):
    """Turn !Sub '${Env}-net-vpc' into 'test-net-vpc'.

    Only the standard config-backed parameters can be resolved, because those
    are the only ones whose value is known without deploying. Anything else is
    left as-is and reported as unresolvable rather than guessed at.
    """
    mapping = {
        "Env": values["env"], "Region": values["region"],
        "RegionCode": values["regionCode"], "Tier": values["tier"],
        "App": values["app"], "AccountId": values["accountId"],
    }
    out = expr
    for key, val in mapping.items():
        out = out.replace("${%s}" % key, val)
    return out


def references_in(main_path):
    """Every Fn::GetStackOutput in a unit, as (stack_expr, output_name)."""
    doc = load_yaml(main_path)
    found = []
    for node in walk(doc):
        if node.get("__tag__") != "GetStackOutput":
            continue
        value = node.get("__value__") or {}
        if not isinstance(value, dict):
            continue
        stack = value.get("StackName")
        if isinstance(stack, dict) and stack.get("__tag__") == "Sub":
            stack_expr = stack.get("__value__")
        elif isinstance(stack, dict) and stack.get("__tag__") == "Ref":
            stack_expr = "!Ref " + str(stack.get("__value__"))
        else:
            stack_expr = stack
        found.append((stack_expr, value.get("OutputName")))
    # Same reference often appears many times; catalogue each pair once.
    seen, unique = set(), []
    for ref in found:
        if ref not in seen:
            seen.add(ref)
            unique.append(ref)
    return unique


def outputs_of(main_path):
    """Output names and their Description, in declaration order."""
    doc = load_yaml(main_path)
    result = []
    for name, body in (doc.get("Outputs") or {}).items():
        desc = ""
        if isinstance(body, dict):
            d = body.get("Description")
            if isinstance(d, str):
                desc = " ".join(d.split())
        result.append((name, desc))
    return result


EXTERNAL_STACKS_FILE = "ci/external-stacks.yaml"


def load_external_stacks():
    """Stacks another repository deploys, which units here may read.

    Optional. A repo that owns everything it reads has no such file, and the
    behaviour is exactly as it was before this existed.

    Shape:

        dev-sec-shared-kms:
          repo:    stadion_sysops_core_infra_toolbox
          unit:    tier1-security/shared-kms
          regions: [us-east-1]
          outputs: [SqsKeyId, RdsKeyId, ...]

    `regions` and `outputs` are both checked. An empty or absent list means
    "do not check this one", which is a deliberate escape hatch but makes the
    reference unverified - so it is worth filling in.
    """
    if not os.path.exists(EXTERNAL_STACKS_FILE):
        return {}
    data = load_yaml(EXTERNAL_STACKS_FILE) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"{EXTERNAL_STACKS_FILE}: expected a mapping of "
                         f"stack name -> details")
    return data


def build():
    """Collect every unit, its stack names, outputs and references."""
    units = find_units()
    external = load_external_stacks()
    errors = []

    for u in units:
        u["outputs"] = outputs_of(u["main"])
        u["refs"] = references_in(u["main"])
        u["stacks"] = []   # (config, env, region, stack name, values, manual)
        for cfg in u["configs"]:
            rows, err = config_rows(cfg)
            if err:
                errors.append(err)
                continue
            for env, region, name, vals, manual in rows:
                u["stacks"].append((cfg, env, region, name, vals, manual))

    # Which unit answers to a given stack name IN A GIVEN REGION?
    #
    # WHY THE REGION IS PART OF THE KEY
    #   Stack names carry no region - test-net-vpc is the name in us-east-1 and
    #   in us-west-2 alike, and they are two different stacks. Matching on the
    #   name alone would say a reference resolves when the producer has no
    #   config for that region at all, which is exactly the case where the
    #   deploy fails.
    by_name = {}
    seen = {}
    for u in units:
        for cfg, _env, region, name, vals, _manual in u["stacks"]:
            by_name.setdefault((name, region), u)

            # Two configs producing the same stack name, in the same region and
            # the same account, are the same stack. Deploying both means the
            # second overwrites the first, with no warning from CloudFormation.
            key = (name, region, vals.get("accountId", ""))
            if key in seen:
                errors.append(
                    f"{u['dir']}: '{os.path.basename(cfg)}' and "
                    f"'{os.path.basename(seen[key])}' both deploy stack "
                    f"'{name}' to {region} in account {vals.get('accountId')}. "
                    f"One would overwrite the other - give them different "
                    f"`env:` values, or delete one.")
            else:
                seen[key] = cfg

    # --- the check that cfn-lint cannot do ---------------------------------
    for u in units:
        for cfg, env, region, _, vals, _manual in u["stacks"]:
            for stack_expr, output_name in u["refs"]:
                if not isinstance(stack_expr, str):
                    errors.append(f"{u['dir']}: GetStackOutput StackName is not "
                                  f"a string or !Sub - cannot be checked")
                    continue
                if stack_expr.startswith("!Ref "):
                    errors.append(
                        f"{u['dir']} ({os.path.basename(cfg)}): StackName uses "
                        f"{stack_expr}. Derive it with !Sub '${{Env}}-<tier>-<unit>' "
                        f"instead - a stack name passed in from config restates "
                        f"env: and tier: and lets them disagree.")
                    continue
                resolved = resolve_sub(stack_expr, vals)
                if "${" in resolved:
                    errors.append(f"{u['dir']} ({os.path.basename(cfg)}): cannot "
                                  f"resolve StackName '{stack_expr}'")
                    continue
                producer = by_name.get((resolved, region))

                # Not in THIS repo - is it declared as one another repo owns?
                #
                # The tier model splits across repositories: Tier 3 units in the
                # apps repo read Tier 0-2 stacks from the infra repo, and that
                # is the intended direction. Without this, every such reference
                # is an error and the apps repo cannot lint at all.
                #
                # It is NOT a bypass. An external stack has to be declared, with
                # the regions it exists in and the outputs it publishes, so a
                # typo'd output name still fails here - which is the check that
                # was worth having in the first place.
                if producer is None:
                    ext = external.get(resolved)
                    if ext is not None:
                        regions = ext.get("regions") or []
                        if regions and region not in regions:
                            errors.append(
                                f"{u['dir']} ({os.path.basename(cfg)}): reads "
                                f"external stack '{resolved}' in {region}, but "
                                f"ci/external-stacks.yaml says it exists only in "
                                f"{', '.join(regions)}.")
                            continue
                        declared = ext.get("outputs") or []
                        if declared and output_name not in declared:
                            errors.append(
                                f"{u['dir']} ({os.path.basename(cfg)}): reads "
                                f"output '{output_name}' from external stack "
                                f"'{resolved}', which ci/external-stacks.yaml "
                                f"does not list. It lists: "
                                f"{', '.join(declared)}\n"
                                f"    If the producing repo added it, refresh "
                                f"that file - see its header.")
                        continue

                if producer is None:
                    # Is it only the region that is missing? That is a much more
                    # useful thing to say than "no such stack".
                    elsewhere = sorted({r for (n, r) in by_name if n == resolved})
                    if elsewhere:
                        errors.append(
                            f"{u['dir']} ({os.path.basename(cfg)}): reads stack "
                            f"'{resolved}' in {region}, but the unit that "
                            f"deploys it has no config for that region - only "
                            f"{', '.join(elsewhere)}.")
                    else:
                        errors.append(
                            f"{u['dir']} ({os.path.basename(cfg)}): reads stack "
                            f"'{resolved}', which no unit in this repo deploys.\n"
                            f"    If another repo owns it - Tier 3 reading a "
                            f"Tier 1 stack, for instance - declare it in "
                            f"ci/external-stacks.yaml.")
                    continue
                if output_name not in [o for o, _ in producer["outputs"]]:
                    have = ", ".join(o for o, _ in producer["outputs"]) or "(none)"
                    errors.append(
                        f"{u['dir']} ({os.path.basename(cfg)}): reads output "
                        f"'{output_name}' from '{resolved}', which does not "
                        f"publish it. It publishes: {have}")
    return units, by_name, errors


def render(units, by_name):
    out = []
    w = out.append

    w("# Stack registry")
    w("")
    w("**Generated by `ci/stack-registry.py`. Do not edit by hand.**")
    w("Run `python ci/stack-registry.py` after changing any unit's outputs,")
    w("name or config. `ci/lint.sh` fails if this file is out of date.")
    w("")
    w("Every stack this repo deploys, what it publishes, and what it reads.")
    w("Look here first when you need a value from another stack.")
    w("")
    w("---")
    w("")
    w("## How to consume one of these")
    w("")
    w("```yaml")
    w("Parameters:")
    w("  Env:")
    w("    Type: String        # filled in automatically by ci/render-config.py")
    w("    AllowedValues: [sbox, dev, test, prep, prod]")
    w("")
    w("Resources:")
    w("  Thing:")
    w("    Type: AWS::CloudFormation::Stack")
    w("    Properties:")
    w("      Parameters:")
    w("        VpcId: !GetStackOutput")
    w("          StackName: !Sub '${Env}-net-vpc'")
    w("          OutputName: VpcId")
    w("```")
    w("")
    w("Derive the stack name with `!Sub`; never put it in a config file. See")
    w("the README section \"Reading a value from another stack\" for why.")
    w("")
    w("---")
    w("")

    # --- who reads whom ----------------------------------------------------
    w("## Dependency graph")
    w("")
    w("Deploy top to bottom: a stack must exist before anything that reads it.")
    w("")
    w("```text")
    # One line per producer/consumer PAIR, not per reference - a unit that
    # reads four outputs from the VPC stack is still one dependency.
    edges = set()
    for u in units:
        for stack_expr, _ in u["refs"]:
            if isinstance(stack_expr, str):
                edges.add((stack_expr, u["dir"]))
    if edges:
        for producer in sorted({p for p, _ in edges}):
            consumers = sorted(c for p, c in edges if p == producer)
            w(f"  {producer}")
            for c in consumers:
                count = sum(1 for u in units if u["dir"] == c
                            for e, _ in u["refs"] if e == producer)
                w(f"      <- {c}  ({count} output{'s' if count != 1 else ''})")
    else:
        w("  (no cross-stack references yet)")
    w("```")
    w("")
    w("---")
    w("")

    # --- the units ---------------------------------------------------------
    current_tier = None
    for u in units:
        if u["tier"] != current_tier:
            current_tier = u["tier"]
            w(f"## `{current_tier}`")
            w("")

        w(f"### {u['dir']}")
        w("")

        if u["stacks"]:
            w("| Config | Env | Region | Stack name |")
            w("| --- | --- | --- | --- |")
            for cfg, env, region, name, _, manual in u["stacks"]:
                how = " _(by hand)_" if manual else ""
                w(f"| `{os.path.basename(cfg)}` | {env or '—'} | {region} | "
                  f"**`{name}`**{how} |")
        else:
            w("_No config files yet, so this unit deploys nothing._")
        w("")

        if u["outputs"]:
            w("**Publishes**")
            w("")
            w("| Output | What it is |")
            w("| --- | --- |")
            for name, desc in u["outputs"]:
                w(f"| `{name}` | {desc or '—'} |")
        else:
            w("**Publishes** — nothing.")
        w("")

        if u["refs"]:
            w("**Reads**")
            w("")
            w("| From stack | Output |")
            w("| --- | --- |")
            for stack_expr, output_name in u["refs"]:
                w(f"| `{stack_expr}` | `{output_name}` |")
            w("")

    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="verify references resolve and the doc is current")
    args = ap.parse_args()

    if not os.path.isfile("ci/render-config.py"):
        print("ERROR: run this from the repo root (stadion_sysops_core_infra/).",
              file=sys.stderr)
        return 2

    units, by_name, errors = build()
    content = render(units, by_name)

    if errors:
        print("Cross-stack reference problems:\n", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        print("", file=sys.stderr)
        return 1

    if args.check:
        existing = ""
        if os.path.isfile(DOC_PATH):
            with open(DOC_PATH, encoding="utf-8") as fh:
                existing = fh.read()
        if existing != content:
            print(f"ERROR: {DOC_PATH} is out of date.", file=sys.stderr)
            print("  Regenerate it:  python ci/stack-registry.py", file=sys.stderr)
            return 1
        stacks = sum(len(u["stacks"]) for u in units)
        refs = sum(len(u["refs"]) for u in units)
        print(f"  OK   {len(units)} units, {stacks} stacks, {refs} reference(s) resolve")
        return 0

    os.makedirs(os.path.dirname(DOC_PATH), exist_ok=True)
    with open(DOC_PATH, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    stacks = sum(len(u["stacks"]) for u in units)
    print(f"  wrote {DOC_PATH}: {len(units)} units, {stacks} stacks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
