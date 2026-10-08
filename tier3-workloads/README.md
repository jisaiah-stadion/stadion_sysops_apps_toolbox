# `tier3-workloads/` — the units this repo deploys

Empty today. The first unit will be `sqs/`.

This file also exists so git tracks the directory at all — git stores files,
not folders, so an empty `tier3-workloads/` would not survive a clone.

## The shape of a unit

```
tier3-workloads/<name>/
  main.yaml              the template. Nests modules by local path.
  config/
    dev-use1.yaml        one file per environment AND region
    dev-usw2.yaml
```

One unit is one CloudFormation stack, named `<env>-<tier>-<name>`:

```
tier3-workloads/sqs/config/dev-use1.yaml   ->   dev-wkl-sqs
```

**The directory name is part of the stack name.** Renaming the directory
creates a new stack and orphans the old one with everything in it.

## One unit per service, not per resource

`sqs/` holds **every** queue in the account, the way
`tier1-security/shared-kms/` holds all nine keys and `tier2-platform/rds/`
holds every database. Not `orders-queue/`, `billing-queue/`, `events-queue/`.

The reason is pipeline cost. Every unit needs a deploy stage here, and three
more in a promote pipeline — plan, approve, apply — **for every environment**.
Ten queues as ten units is thirty approval gates for something that should be
one review.

What you give up is smaller than it looks: CloudFormation rolls back only the
resources it **changed**, so a failed update to one queue disturbs another only
if both changed in the same deploy. Change one at a time and read the plan.

## What may and may not be referenced

Tier 3 may read from **any lower tier** — Tier 2 platform, Tier 1 security,
Tier 0 networking — with `Fn::GetStackOutput`. Those all live in
`stadion_sysops_core_infra_toolbox`.

```yaml
# the shared SQS CMK, from Tier 1
KmsKeyId: !GetStackOutput
  StackName: !Sub '${Env}-sec-shared-kms'
  OutputName: SqsKeyId
```

**Nothing in a lower tier may read from here.** If one needs to, the resource
is in the wrong tier — move it down rather than reaching up. A reference
upward makes the two repos deploy in lockstep, which is the thing the split
exists to prevent.

Read the key-ID warnings on the `shared-kms` outputs before wiring one in: the
`*KeyArn` outputs are a **wildcard-region** form that only works in an IAM
policy statement, and passing one to an API call fails with a message that
reads like a permissions problem. Use `*KeyId`.

## Adding one

See the checklist at the end of the repo [README](../README.md). The two steps
people forget are the pipeline stage and the trigger path filter — a unit with
no stage gets linted on every push and deployed by nobody.
