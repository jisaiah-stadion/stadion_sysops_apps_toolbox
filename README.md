# stadion_sysops_apps_toolbox

**Tier 3 — the workloads for the `toolbox` project.** Queues, topics, buckets,
functions and the app-scoped IAM roles and security groups that go with them.

CloudFormation only. No Terraform, no CDK.

---

## Where this sits

```
        ┌──────────────────────────────────────────┐
        │  TIER 3 · Workloads     <- THIS REPO     │
        │  SQS, SNS, S3, Lambda, API Gateway       │
        │  + app-scoped IAM roles and SGs          │
        └────────────────────┬─────────────────────┘
                             │ consumes
        ┌────────────────────▼─────────────────────┐
        │  TIER 2 · Platform                       │
        │  shared RDS, shared ALB, parameter groups│
        └────────────────────┬─────────────────────┘
                             │ consumes
        ┌────────────────────▼─────────────────────┐
        │  TIER 1 · Security                       │
        │  permission boundary, shared KMS, org IAM│
        └────────────────────┬─────────────────────┘
                             │ consumes
        ┌────────────────────▼─────────────────────┐
        │  TIER 0 · Networking                     │
        │  VPC, subnets, route tables, TGW         │
        └──────────────────────────────────────────┘

   Tiers 0-2 live in stadion_sysops_core_infra_toolbox.
   References point DOWNWARD only - never up, never sideways.
```

**Nothing in this repo may be referenced by Tiers 0-2.** If a lower tier needs
something here, the resource is in the wrong tier. That rule is what keeps the
two repos from needing to deploy in lockstep.

## The three repos, and what each owns

| Repo | Owns | Shared how |
|---|---|---|
| `stadion_sysops_modules` | Reusable CloudFormation modules | Published as an immutable versioned tarball; **every** repo fetches from the same bucket |
| `stadion_sysops_core_infra_toolbox` | Tiers 0-2, bootstrap, the shared IAM units | — |
| `stadion_sysops_apps_toolbox` | Tier 3 — this repo | — |

One repo pair **per project**. A second project gets its own
`stadion_sysops_core_infra_<project>` and `stadion_sysops_apps_<project>`, and
both of those also fetch from the one modules bucket.

`ci/` is **copied** between repos rather than shared. Read
[ci/README.md](ci/README.md) before editing anything in it — it lists which
files must stay byte-identical and gives you the `diff` loop that checks.

## Layout

```
ci/                      the toolchain. Mostly a verbatim copy - see ci/README.md
  buildspec.yml          what CodeBuild runs for every pipeline stage
  lint.sh                validate one unit without touching AWS
  package-and-deploy.sh  change set -> review -> apply
  destroy.sh             delete a unit's stack
  modules.lock           module versions THIS repo has reviewed
  naming.yaml            the naming convention
  rules/                 cfn-guard policy
docs/
  STACK-REGISTRY.md      generated catalogue of every stack and its outputs
pipelines/
  apps-dev.yaml          the dev pipeline for this repo
tier3-workloads/
  <unit>/
    main.yaml            the unit's template
    config/
      dev-use1.yaml      one file per environment and region
modules/                 GITIGNORED - fetched by ci/fetch-modules.sh
tests/
  selftest/              proves the toolchain works end to end
```

### What a "unit" is

A directory with `main.yaml` and a `config/` folder. One unit deploys as one
CloudFormation stack, named `<env>-<tier>-<unit>`:

```
tier3-workloads/sqs/config/dev-use1.yaml   ->   dev-wkl-sqs
```

The unit directory name is the stack name's last segment, so **renaming a
directory renames the stack**, which creates a new one and orphans the old.

## Daily workflow

```bash
# 1. validate - no AWS writes, a second on a laptop
bash ci/lint.sh tier3-workloads/sqs/config/dev-use1.yaml

# 2. see what would change - still nothing applied
bash ci/package-and-deploy.sh tier3-workloads/sqs/config/dev-use1.yaml \
  --target-profile target

# 3. apply it
bash ci/package-and-deploy.sh tier3-workloads/sqs/config/dev-use1.yaml \
  --target-profile target --execute
```

Step 2 is the `terraform plan` equivalent and it is the default — nothing is
applied without `--execute`.

In the pipeline, step 1 runs for **every** unit this repo deploys before any
deploy stage starts, so a broken unit fails the run before a working one has
changed anything.

## Prerequisites in the target account

This repo deploys into an account that `bootstrap/deployment-roles` in the
**infra** repo has already prepared. It does not create its own roles.

| Must exist | Created by | Symptom when missing |
|---|---|---|
| `stadion-iac-deployment-role` | infra repo `bootstrap/deployment-roles` | The build cannot assume into the account at all |
| `stadion-cfn-execution-role` | same | `AccessDenied` naming the resource type being created |
| `stadion-platform-boundary` | same | Every role created here fails `iam:CreateRole` with an error that does not mention boundaries |
| Tier 0, Tier 1 stacks | infra repo | `Fn::GetStackOutput` fails when the change set is built |

**The execution role has to be able to create what you are deploying.** It is
deliberately a list of specific services, not `*`, so a new service in this
repo needs a statement adding to it in the infra repo first. A missing one is
an `AccessDenied` at deploy time, not at lint time.

## Adding a unit

1. `mkdir -p tier3-workloads/<name>/config`
2. Write `main.yaml`. Nest modules by local path —
   `../../modules/<module>/template.yaml`.
3. Write `config/dev-use1.yaml`. Copy an existing one; the comments in it
   explain every key.
4. Pin `moduleVersion:` to a version listed in `ci/modules.lock`. Adding a new
   version is two edits — the config and the lock — on purpose.
5. `bash ci/lint.sh tier3-workloads/<name>/config/dev-use1.yaml`
6. Add a stage to `pipelines/apps-dev.yaml` and widen its `LINT_GLOB` and
   trigger path filter.
7. Redeploy the pipeline stack.

Steps 6 and 7 are the ones people forget. A unit with no stage is linted by the
pipeline and never deployed by it.
