# `ci/` — what is shared, what is this repo's, and how to tell

Most of this directory is a **byte-for-byte copy** of `ci/` in
`stadion_sysops_core_infra_toolbox`. That is deliberate, and it is also the
thing most likely to go wrong, so read this before editing anything here.

## The rule

> **If a file is in the shared list below, never edit it in one repo only.**
> Change it in `stadion_sysops_core_infra_toolbox`, then copy it here, then
> check the two are identical.

```bash
# from the parent directory that holds both repos
for f in ci/package-and-deploy.sh ci/destroy.sh ci/lint.sh ci/fetch-modules.sh \
         ci/render-config.py ci/stack-registry.py ci/naming.yaml \
         ci/lib/modules.sh ci/lib/naming.py ci/lib/stack-wait.sh; do
  if diff -q "stadion_sysops_core_infra_toolbox/$f" "stadion_sysops_apps_toolbox/$f" >/dev/null; then
    echo "same  $f"
  else
    echo "DRIFT $f"
  fi
done
```

Run that before you open a PR that touches `ci/`.

## Shared verbatim

| File | What it does |
|---|---|
| `package-and-deploy.sh` | Builds a change set, shows it, applies it with `--execute` |
| `destroy.sh` | Deletes a unit's stack |
| `lint.sh` | Validates one unit without touching AWS |
| `fetch-modules.sh` | Downloads the module tarball |
| `render-config.py` | Turns a config into a stack name, parameters and tags |
| `stack-registry.py` | Resolves every `Fn::GetStackOutput` in the repo |
| `naming.yaml` | The naming convention and the resource-type catalogue |
| `lib/modules.sh` | Module fetch, version reconcile, checksum check |
| `lib/naming.py` | The name composer `render-config.py` calls |
| `lib/stack-wait.sh` | `wait_for_stack` — why `aws cloudformation wait` is not used |
| `rules/` | cfn-guard policy rules |

`lint.sh` runs `ci/gen-iam.py` **only if that file exists**, which is what lets
it be shared with a repo that has no generated IAM units. This repo does not
have one yet. When app-scoped IAM roles arrive here, copy `gen-iam.py` and add
an `iam/` folder and it is picked up with no edit to `lint.sh`.

## This repo's own

| File | Why it differs |
|---|---|
| `modules.lock` | Each repo pins and reviews its **own** module versions. That is the point of the file — see its header. |
| `buildspec.yml` | One line: `LINT_GLOB` names the tiers this repo actually has. |

`naming.yaml` is in the shared list because `org: stadion` and
`project: toolbox` happen to be the same in both. **A repo for a different
project changes `project:` and `naming.yaml` stops being shareable for it** —
that is the one knob to check when this scaffolding is reused.

## Why this is copied rather than fetched

There is no mechanism for sharing *scripts* today. The modules repo publishes
an immutable versioned tarball and every repo fetches it, which is why
`modules/` is shared cleanly and `ci/` is not.

**This duplication has already cost us once.** `stadion_sysops_core_infra`'s
copy of `package-and-deploy.sh` still contains a stack-waiter bug that was
fixed in the toolbox repo, because nobody had a reason to look at the other
copy. With one repo per project per layer, the number of copies grows with the
number of projects, and so does the chance that a fix lands in some of them.

The fix is to publish `ci/` the same way `modules/` is published: a
`stadion-toolkit-<version>.tar.gz` built by the modules repo, pinned by hash in
a `toolkit.lock`, fetched by a small bootstrap script that each repo does keep.
That is a migration of the existing working repos, not a thing to bolt onto a
new one, so it has not been done. **Until it is, the `diff` loop at the top of
this file is the only control there is.**
