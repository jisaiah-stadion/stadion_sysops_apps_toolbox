# Standing this repo up

Five steps, in order. Steps 1-3 happen once per repo; steps 4-5 once per target
account.

Nothing here creates networking, keys or roles in the target account — that is
`bootstrap/deployment-roles` in `stadion_sysops_core_infra_toolbox`, and it has
to have run first.

---

## 1. Check `ci/` has not drifted from the infra repo

Most of `ci/` is a byte-for-byte copy. Before anything else, confirm it still
is — a half-updated copy is the failure mode this repo is most exposed to:

```bash
# from the parent directory holding both repos
for f in ci/package-and-deploy.sh ci/destroy.sh ci/lint.sh ci/fetch-modules.sh \
         ci/render-config.py ci/stack-registry.py ci/naming.yaml \
         ci/lib/modules.sh ci/lib/naming.py ci/lib/stack-wait.sh; do
  diff -q "stadion_sysops_core_infra_toolbox/$f" "stadion_sysops_apps_toolbox/$f" \
    >/dev/null && echo "same  $f" || echo "DRIFT $f"
done
```

See [ci/README.md](../ci/README.md) for which files are shared and why this is
a copy rather than a fetch.

## 2. Prove the toolchain locally

No AWS writes. This renders the config, composes the names, resolves every
cross-stack reference and runs cfn-lint:

```bash
bash ci/lint.sh tests/selftest/config/dev-use1.yaml
```

Expect `PASS — tests/selftest`. It needs credentials for the **deployment**
account's modules bucket — the first thing it does is fetch the module tarball
at the version in `ci/modules.lock`.

If it fails at `--- modules ---` with a 400 or 403, that is credentials, not
the repo.

## 3. Deploy the pipeline into the DEPLOYMENT account

By hand, once. `pipelines/apps-dev.yaml` is not deployed by any pipeline — it
*is* the pipeline.

Five parameters have no default and must be supplied:

| Parameter | Where to get it |
|---|---|
| `ProjectName` | `toolbox` |
| `TargetAccountId` | the dev account this deploys into |
| `ConnectionArn` | the **existing** CodeConnections connection the infra pipelines use — connections are regional, not per-pipeline, so do not make a new one |
| `RepositoryId` | `<org>/stadion_sysops_apps_toolbox` — **this** repo, not the infra one |
| `ArtifactKeyArn` | the artifact bucket's CMK in this region |

```bash
aws cloudformation create-change-set \
  --stack-name stadion-toolbox-apps-dev \
  --change-set-name initial \
  --change-set-type CREATE \
  --template-body file://pipelines/apps-dev.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=toolbox \
    ParameterKey=TargetAccountId,ParameterValue=<dev account id> \
    ParameterKey=ConnectionArn,ParameterValue=<connection arn> \
    ParameterKey=RepositoryId,ParameterValue=<org>/stadion_sysops_apps_toolbox \
    ParameterKey=ArtifactKeyArn,ParameterValue=<key arn>

# read it, then
aws cloudformation execute-change-set \
  --stack-name stadion-toolbox-apps-dev --change-set-name initial
```

`CAPABILITY_NAMED_IAM` is **mandatory** — the template creates two roles with
explicit names.

### Updating it later

Use `update-stack` or a change set, never `create`. The roles are **named**, so
a second stack cannot create them:

```
stadion-toolbox-apps-dev-codebuild-role already exists in stack arn:...
```

That error means you created a new stack instead of updating the existing one.
Pass `UsePreviousValue=true` for the five parameters above rather than retyping
them.

## 4. Confirm the assume-role chain — no change required

The pipeline's CodeBuild role is brand new, so it looks like the target account
must be taught to trust it. **It does not.**

`bootstrap/deployment-roles` trusts the **deployment account's root**:

```yaml
Principal:
  AWS: arn:aws:iam::<deployment account>:root
```

Trusting `:root` **delegates** the decision to that account's IAM rather than
granting anything — a principal there still needs its own explicit
`sts:AssumeRole` permission, and `apps-dev.yaml`'s CodeBuild role has exactly
that in its `AssumeDeploymentRoleInTarget` statement. Both halves are already
present.

The bootstrap template says why it is built that way: trusting root "avoids
hardcoding pipeline role names that do not exist yet" — this pipeline being
one of those.

So there is nothing to do here, only somewhere to look when it *does* break.
Check both halves:

```bash
# this half - the grant, in the DEPLOYMENT account
aws iam get-role-policy \
  --role-name stadion-toolbox-apps-dev-codebuild-role \
  --policy-name stadion-toolbox-apps-codebuild-assume-target

# the other half - the delegation, in the TARGET account
aws --profile target iam get-role \
  --role-name stadion-iac-deployment-role \
  --query 'Role.AssumeRolePolicyDocument'
```

Missing either one produces the same unhelpful error, with nothing to say
which:

```text
An error occurred (AccessDenied) when calling the AssumeRole operation
```

## 5. Check the execution role can create what you are deploying

`stadion-cfn-execution-role` is a list of **specific services**, not `*`. It
has statements for VPC networking, log groups, KMS, **SQS**, RDS, Secrets
Manager, roles and policies, nested stacks and artifacts — and nothing for SNS
or S3 object creation yet.

So a new service in this repo needs a statement added to that role in the
infra repo *first*. The symptom otherwise is an `AccessDenied` naming the
resource type, at deploy time — `ci/lint.sh` cannot catch it, because linting
never calls AWS.

The selftest in step 2 deliberately creates a **log group**, which that role
can already do, so it proves the path without needing a permission change.

---

## Then

```bash
# smoke-test the whole path, end to end, for one cheap resource
bash ci/package-and-deploy.sh tests/selftest/config/dev-use1.yaml \
  --target-profile target --execute

# and remove it
bash ci/destroy.sh tests/selftest/config/dev-use1.yaml --execute
```

A green selftest means the modules bucket, the artifact bucket, the KMS key,
the assume-role chain, the execution role and the naming convention all work.
Every failure after that is about the unit you are writing.
