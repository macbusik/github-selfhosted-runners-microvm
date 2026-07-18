# Migration plan: `awscc` provider → CloudFormation

> **Execution status (2026-07-18):**
> - **Phase 0 — done.** Local state backed up to
>   `terraform/terraform.tfstate.pre-cfn-migration-2026-07-18.backup`
>   (primary worktree, not committed). Old image ARN recorded:
>   `arn:aws:lambda:us-east-1:191138354216:microvm-image:gh-runner-microvm-sample-cicd-repo`.
> - **Phase 1 — run 2026-07-18, findings:**
>   1. Schema check passed: every property name in the template matches
>      `describe-type` output (incl. `MinimumMemoryInMiB`); `Name` is
>      confirmed createOnly (name change = replacement, as designed).
>   2. **Variant A is mandatory, variant B is invalid**: the registry schema
>      marks `AdditionalOsCapabilities`/`EgressNetworkConnectors` (and
>      `Description`, `Logging`, `Hooks`, `EnvironmentVariables`) as
>      *required* — that is the root cause of the awscc "required key not
>      found" error. Explicit `[]` in the template is accepted (create
>      confirmed live).
>   3. **New contract discovered**: the CFN handler wants `BaseImageVersion`
>      as a single major version number (`0`) and rejects the API-normalized
>      `0.0` the old import path required. Template + variable now enforce
>      this; `terraform.tfvars` must change `"0.0"` → `"0"` at cutover.
> - **Phase 2 — done** (this commit). `terraform validate` passes; plan
>   output could not be generated yet (no credentials, state in primary
>   worktree).
> - **Phases 3–4 — not started.** Cutover checklist in §3; remember
>   `terraform state rm awscc_lambda_microvm_image.gh_runner` *before* the
>   apply.

**Scope:** replace the single `awscc` resource in this repo —
`awscc_lambda_microvm_image.gh_runner` ([terraform/main.tf](terraform/main.tf)) —
with a CloudFormation-managed equivalent, and drop the `awscc` provider
entirely. Every other resource already uses `hashicorp/aws` and is untouched.

**Audience/constraints:** written for a change-managed, highly regulated
environment (fintech): every phase has an approval gate, a rollback path, and
produces auditable artifacts. No in-place mutation of the production image —
cutover is blue/green.

---

## 1. Why migrate, and why CloudFormation

The `awscc` resource is currently unusable as a real desired-state definition.
Two live-confirmed defects (see comments in `main.tf`):

1. **Empty `Set(String)` bug** (class of
   [terraform-provider-awscc#847](https://github.com/hashicorp/terraform-provider-awscc/issues/847),
   still present in awscc 1.92.0): `additional_os_capabilities = []` and
   `egress_network_connectors = []` are *dropped from the request* instead of
   being sent as `[]`, and the create/update call fails with
   `required key not found`. Workaround today: create the image out-of-band
   with `aws lambda-microvms create-microvm-image`, then `terraform import`.
2. **Broken read handler**: the Cloud Control read for this resource returns
   only `name`/`arn`/`tags`; every other property comes back `null`. Without
   `ignore_changes` on essentially *all* properties, every `terraform plan`
   wants to "re-add" values that are already set server-side.

Net effect: Terraform tracks the ARN and nothing else. Changing
`code_artifact` or `environment_variables` in HCL does **not** roll a new
image — the real change path is CLI + re-import, undocumented in state.

**What CloudFormation fixes:**

- **Bug 1 is a client-side serialization bug.** In a CFN template *we* control
  serialization: `AdditionalOsCapabilities: []` is written literally and sent
  literally. (Fallback if the shared registry handler still rejects it: omit
  the properties entirely — the template author can do that too; the awscc
  provider cannot. See the spike in Phase 1.)
- **Bug 2 stops causing perpetual drift.** CloudFormation diffs *template vs.
  previous template*, not template vs. a (broken) live read. Updates are
  driven by the desired state we submit. Cost: CFN drift detection for this
  one resource will be unreliable until AWS fixes the read handler — accepted
  and documented (§8).
- The out-of-band CLI + `terraform import` + 12-entry `ignore_changes` ritual
  disappears. The image definition becomes a reviewable, checksummable YAML
  artifact deployed by `terraform apply` like everything else.

**Regulated-environment benefits (the fintech angle):**

- The template is a **static artifact**: no interpolation inside it (all
  inputs are CFN Parameters), so the reviewed/approved file is byte-identical
  to what is deployed. Its SHA-256 can be recorded in the change ticket.
- **Separation of duties** via a dedicated CloudFormation service role
  (`iam_role_arn`): the human/CI deployer needs only `cloudformation:*` on
  this stack; the `lambda-microvms` mutations run under a scoped stack role.
- **Stack policy** (`policy_body`) denies accidental deletion of the image
  resource; failed creates/updates **auto-rollback** (`on_failure =
  "ROLLBACK"`) instead of leaving a half-applied state.
- Full CloudTrail trail: `CreateStack`/`UpdateStack` events plus per-resource
  stack events give an audit narrative Terraform state changes don't.

### Considered and rejected: full migration of the whole stack to CloudFormation

Everything else (S3, IAM, Secrets Manager, dispatcher Lambda + Function URL)
works flawlessly under `hashicorp/aws`. Migrating it means importing ~15
resources into CFN (high-risk, zero functional gain) and maintaining two IaC
dialects or abandoning Terraform. Only revisit if org policy mandates
CFN-only IaC. This plan is the **hybrid**: Terraform stays the orchestrator;
CloudFormation (via `aws_cloudformation_stack`) manages exactly the resource
whose Cloud-Control-through-Terraform path is broken.

---

## 2. Target design

```
terraform apply
 ├── aws_s3_bucket / IAM roles / secrets / dispatcher   (unchanged, aws provider)
 └── aws_cloudformation_stack.microvm_image
      ├── template: terraform/templates/microvm-image.yaml  (static, parameterized)
      ├── parameters: bucket, role ARNs, env values (from Terraform)
      └── output ImageArn ──→ dispatcher env, terraform outputs
```

- `providers.tf`: `awscc` block and provider config **removed**.
- IAM policies that build the image ARN from `local.image_name`
  (`SelfTerminate` in main.tf, `RunMicrovm` in dispatcher.tf) keep working —
  they never referenced the awscc resource, only the name. They update
  automatically when the image name changes for blue/green.

### 2.1 New file: `terraform/templates/microvm-image.yaml`

Deliberately a 1:1 transliteration of the current HCL (same values, same
comments carried over) so review is a side-by-side diff, not a re-audit.

> **Property names below are derived** from the awscc schema (awscc is
> generated from the CFN registry schema, snake_case ↔ PascalCase). Phase 1
> verifies every name against the authoritative schema:
> `aws cloudformation describe-type --type RESOURCE --type-name AWS::Lambda::MicrovmImage`.
> Watch the one non-obvious one: `minimum_memory_in_mi_b` → `MinimumMemoryInMiB`.

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >-
  Lambda MicroVM image for the ephemeral GitHub Actions runner.
  Managed via CloudFormation (not the awscc provider) - see MIGRATION_PLAN.md.

Parameters:
  ImageName:          { Type: String }
  ImageDescription:   { Type: String }
  CodeArtifactUri:    { Type: String }
  BaseImageArn:       { Type: String }
  BaseImageVersion:   { Type: String }
  BuildRoleArn:       { Type: String }
  BaselineMemoryMiB:  { Type: Number }
  GithubOwner:        { Type: String }
  GithubRepo:         { Type: String }
  GhAppSecretArn:     { Type: String }
  RunnerLabels:       { Type: String }
  MicrovmAwsRegion:   { Type: String }
  ProjectTag:         { Type: String }

Resources:
  MicrovmImage:
    Type: AWS::Lambda::MicrovmImage
    Properties:
      Name: !Ref ImageName
      Description: !Ref ImageDescription
      CodeArtifact:
        Uri: !Ref CodeArtifactUri
      BaseImageArn: !Ref BaseImageArn
      BaseImageVersion: !Ref BaseImageVersion   # must be a real version id, "" is rejected
      BuildRoleArn: !Ref BuildRoleArn
      CpuConfigurations:
        - Architecture: ARM_64                  # enum value, not CLI-style "arm64"
      Resources:
        - MinimumMemoryInMiB: !Ref BaselineMemoryMiB
      # Spike decision point (Phase 1): explicit [] first; if the registry
      # handler still throws "required key not found", DELETE these two lines
      # (omitting optional properties is exactly what the working CLI path does).
      AdditionalOsCapabilities: []
      EgressNetworkConnectors: []
      EnvironmentVariables:
        - { Key: GITHUB_OWNER,       Value: !Ref GithubOwner }
        - { Key: GITHUB_REPO,        Value: !Ref GithubRepo }
        - { Key: GH_APP_SECRET_ARN,  Value: !Ref GhAppSecretArn }
        - { Key: RUNNER_LABELS,      Value: !Ref RunnerLabels }
        - { Key: HOOK_PORT,          Value: "8080" }
        # AWS_REGION is a reserved key server-side; hook_server.py prefers the
        # platform-injected AWS_REGION and falls back to this.
        - { Key: MICROVM_AWS_REGION, Value: !Ref MicrovmAwsRegion }
      # API requires at least one enabled hook when Port is set. These four
      # match hook_server.py exactly; resume/suspend intentionally unset
      # (ephemeral runners terminate, they don't sleep).
      Hooks:
        Port: 8080
        MicrovmImageHooks:
          Ready: ENABLED
          Validate: ENABLED
        MicrovmHooks:
          Run: ENABLED
          RunTimeoutInSeconds: 60   # API caps at 60 (confirmed live 2026-07-10)
          Terminate: ENABLED
      Logging: {}
      Tags:
        - { Key: Project, Value: !Ref ProjectTag }

Outputs:
  ImageArn:
    Description: Pass as --image-identifier to run-microvm.
    Value: !GetAtt MicrovmImage.ImageArn
```

### 2.2 `terraform/main.tf` — replace the awscc resource

```hcl
# ---------------------------------------------------------------------------
# MicroVM image - managed through CloudFormation instead of awscc because of
# two confirmed awscc defects (empty-Set(String) serialization + null-only
# read handler). Full rationale: MIGRATION_PLAN.md.
# The template is static (no interpolation); all inputs enter as Parameters,
# so the reviewed file is byte-identical to what is deployed.
# ---------------------------------------------------------------------------
resource "aws_cloudformation_stack" "microvm_image" {
  name          = "${var.name_prefix}-microvm-image"
  template_body = file("${path.module}/templates/microvm-image.yaml")

  parameters = {
    ImageName         = local.image_name
    ImageDescription  = "Ephemeral GitHub Actions self-hosted runner for ${var.github_owner}/${var.github_repo}"
    CodeArtifactUri   = "s3://${aws_s3_bucket.runner_artifacts.bucket}/gh-runner-image.zip"
    BaseImageArn      = local.base_image_arn
    BaseImageVersion  = var.base_image_version
    BuildRoleArn      = aws_iam_role.microvm_build_role.arn
    BaselineMemoryMiB = var.runner_image_baseline_memory_mib
    GithubOwner       = var.github_owner
    GithubRepo        = var.github_repo
    GhAppSecretArn    = aws_secretsmanager_secret.github_app.arn
    RunnerLabels      = var.runner_labels
    MicrovmAwsRegion  = var.aws_region
    ProjectTag        = var.name_prefix
  }

  # Failed create/update rolls back automatically - no half-applied images.
  on_failure = "ROLLBACK"

  # Optional but recommended for separation of duties (see MIGRATION_PLAN.md §6):
  # iam_role_arn = aws_iam_role.cfn_microvm_image.arn

  # Stack policy: the image may be replaced (blue/green) but never silently
  # deleted by a routine update.
  policy_body = jsonencode({
    Statement = [
      { Effect = "Allow", Action = "Update:*", Principal = "*", Resource = "*" },
      { Effect = "Deny", Action = "Update:Delete", Principal = "*", Resource = "LogicalResourceId/MicrovmImage" },
    ]
  })

  tags = { Project = var.name_prefix }

  depends_on = [
    aws_iam_role_policy.microvm_build_role,
    aws_iam_role_policy.microvm_execution_role,
  ]
}
```

Blue/green naming: change `local.image_name` to include a version segment so
the replacement image can coexist with the old one during burn-in:

```hcl
image_name = "${var.name_prefix}-${var.github_repo}-${var.image_generation}"
```

with `variable "image_generation" { type = string, default = "g2" }` —
bumping it is the documented way to roll a new image (a `Name` change is a
CFN *replacement*: new image built, old one deleted in the cleanup step).

### 2.3 Reference updates (mechanical)

| File | Old | New |
|---|---|---|
| [terraform/outputs.tf](terraform/outputs.tf) `microvm_image_arn`, `run_microvm_example_command` | `awscc_lambda_microvm_image.gh_runner.image_arn` | `aws_cloudformation_stack.microvm_image.outputs["ImageArn"]` |
| [terraform/dispatcher.tf](terraform/dispatcher.tf) `MICROVM_IMAGE_ARN` env | same | same |
| [terraform/providers.tf](terraform/providers.tf) | `awscc` required_provider + provider block | *removed* |
| [README.md](README.md) "Faza 2" | CLI create + `terraform import` + ignore_changes ritual | plain `terraform apply`; rebuild = bump `image_generation` |

---

## 3. Phased execution

Each phase ends at an approval gate. Nothing in Phases 0–1 touches the
production image.

### Phase 0 — Preparation (no AWS changes)
- Freeze changes to `terraform/` (branch protection / change ticket).
- `terraform state pull > backups/pre-migration-$(date +%F).tfstate` — store
  per your artifact-retention policy.
- Record current image ARN (`terraform output microvm_image_arn`) and the
  deployed image version list
  (`aws lambda-microvms list-microvm-image-versions --image-identifier <arn>`).

**Gate:** state backup verified restorable; ticket opened.

### Phase 1 — Feasibility spike (sandbox account / throwaway names)
This is the go/no-go for the whole plan, because **CloudFormation and Cloud
Control share the same registry handler** — the `required key not found`
failure could theoretically reproduce.

1. Pull the authoritative schema and verify every property name in the
   template (esp. `MinimumMemoryInMiB`, hook enums):
   `aws cloudformation describe-type --type RESOURCE --type-name AWS::Lambda::MicrovmImage`
2. Deploy the template standalone (`aws cloudformation deploy`) with a
   throwaway name, **variant A**: explicit `AdditionalOsCapabilities: []` /
   `EgressNetworkConnectors: []`.
3. If A fails with the known error → **variant B**: both properties omitted
   (this mirrors the CLI call that is known to work).
4. Whichever variant succeeds: confirm the built image reaches `AVAILABLE`,
   run one `run-microvm` smoke test against it, then delete the spike stack
   and confirm the image is actually deleted (README warns deletion is
   refused while MicroVMs from it exist).
5. Also test an **UpdateStack** that changes only `Description`: verify hooks
   and OS capabilities survive (there are community reports of
   `UpdateMicrovmImage` losing hooks — if it reproduces, adopt the
   "immutable image" rule: *every* change bumps `image_generation` and is a
   replacement, never an in-place update; enforce by making all params except
   `ImageDescription` effectively create-only in review).

**Gate:** one variant creates/deletes cleanly + smoke test passes. If *both*
variants fail → **no-go**: stay on CLI + import, file an AWS support case,
re-run the spike each awscc/handler release.

### Phase 2 — Code change (PR)
- Add `terraform/templates/microvm-image.yaml` (spike-selected variant),
  the `aws_cloudformation_stack` resource, `image_generation` variable,
  reference updates (§2.3). Delete the `awscc_lambda_microvm_image` block and
  the provider config.
- **Do not** run `terraform apply` yet. PR must include: `terraform validate`
  + `terraform plan` output as artifacts, template SHA-256 in the ticket.
- Expected plan: **create** stack (new image name `...-g2`), **update**
  dispatcher env + both IAM policies to the new ARN/name, **no destroy** of
  the old image *after* the state operation below.

### Phase 3 — Cutover (production, quiet window)
1. Detach the old image from Terraform without destroying it (it stays as
   the rollback target):
   `terraform state rm awscc_lambda_microvm_image.gh_runner`
2. `terraform apply` (two operators: one executes, one verifies the plan
   matches the PR-attached plan — standard four-eyes).
3. Wait for the stack `CREATE_COMPLETE` and the image `AVAILABLE`.
4. **E2E verification:** push a workflow run to the target repo; confirm the
   webhook → dispatcher → `run-microvm` → job green path on the **new** image
   ARN (check dispatcher logs for the new ARN, runner logs under
   `/aws/lambda-microvms/<new-image-name>`).

**Gate:** E2E green. Old image still exists and is still runnable.

### Phase 4 — Burn-in and decommission
- Burn-in window (suggested: 5 business days / N successful jobs, per your
  change policy). Rollback during this window is trivial (§4).
- After burn-in: delete the old image out-of-band —
  `aws lambda-microvms delete-microvm-image --image-identifier <old-arn>`
  (CLI, since it is no longer in any IaC state). Verify no MicroVMs from it
  are running first.
- Close out: update README (drop "Faza 2" CLI ritual), record final state.

---

## 4. Rollback

| When | How |
|---|---|
| Phase 3 apply fails | CFN auto-rolls back the stack; dispatcher/IAM changes revert with `git revert` + apply. Old image untouched (it was `state rm`'d, never destroyed). |
| Burn-in failure | `git revert` the PR, `terraform apply` (dispatcher env + IAM point back at the old image name), `terraform import` the old image back into the awscc resource if returning long-term, delete the CFN stack. |
| After decommission | Old image is gone; roll *forward*: bump `image_generation`, fix, re-apply. This is why burn-in precedes deletion. |

---

## 5. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | CFN registry handler rejects both `[]` and omitted optional sets (same handler as Cloud Control) | Low–med | Blocks migration | Phase 1 spike is the explicit go/no-go; no production change before it passes |
| 2 | Broken read handler → CFN drift detection unreliable for this resource; CFN *import* not viable | Certain (today) | Low | Accepted & documented; blue/green replaces import; compensating control: periodic `get-microvm-image` compare script in CI (§6) |
| 3 | `UpdateMicrovmImage` loses hooks/os-capabilities (community reports) | Med | Broken image version | Immutable-image rule: changes = `image_generation` bump = replacement; tested in Phase 1 step 5 |
| 4 | Old-image deletion refused while its MicroVMs run | Med | Cleanup delay only | Decommission checks running MicroVMs first; replacement cleanup runs in quiet window |
| 5 | Derived PascalCase property names wrong | Low | Fails fast in spike | `describe-type` schema check is Phase 1 step 1 |
| 6 | Secret/env ARNs baked into image env diverge after rollback | Low | Runner auth failure | Secret names/ARNs are unchanged by this migration by design |

---

## 6. Regulated-environment control checklist

- [ ] **Static template**: no `templatefile()` interpolation — parameters only;
      SHA-256 of the YAML recorded in the change ticket.
- [ ] **Four-eyes apply**: plan attached to PR must match plan at execution.
- [ ] **Separation of duties** (recommended follow-up): dedicated CFN service
      role with only `lambda:CreateMicrovmImage`, `lambda:UpdateMicrovmImage`,
      `lambda:DeleteMicrovmImage`, `lambda:GetMicrovmImage`, `iam:PassRole`
      (on the build role); set `iam_role_arn` on the stack; deployer keeps
      only `cloudformation:*` on this stack ARN.
- [ ] **Stack policy** denying `Update:Delete` on the image (in §2.2 code).
- [ ] **Termination protection**: enable post-create via
      `aws cloudformation update-termination-protection --enable-termination-protection --stack-name <name>`
      (the Terraform `aws_cloudformation_stack` resource does not expose it —
      verify against your pinned provider version; if your version supports
      it, prefer the in-code setting).
- [ ] **Drift compensating control** (because of risk #2): scheduled CI job
      diffing `aws lambda-microvms get-microvm-image` output against the
      template parameters; alert on mismatch.
- [ ] **Audit evidence**: CloudTrail `CreateStack`/`UpdateStack` +
      `lambda-microvms` events referenced in the ticket; state backup retained.

---

## 7. Explicit non-goals

- Migrating `aws_*` resources (S3, IAM, Secrets Manager, dispatcher) to
  CloudFormation — no defect to fix, pure risk.
- Changing runner behavior, hooks, labels, or the secret handling pattern —
  the image definition is transliterated value-for-value.
- MicroVM *instances* — they remain dynamic runtime resources launched by the
  dispatcher, managed by neither Terraform nor CloudFormation.

## 8. Known accepted limitations after migration

- CFN drift detection on `AWS::Lambda::MicrovmImage` is unreliable until AWS
  fixes the read handler (compensated per §6).
- Every substantive image change is a **replacement** (new name, new build,
  ~minutes of build time) — deliberate, and safer than in-place updates given
  risk #3.
- The `build-host/` stack is out of scope (aws provider only).
