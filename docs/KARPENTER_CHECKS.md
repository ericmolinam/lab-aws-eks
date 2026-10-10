# Offline implementation evidence — 2026-10-10

Baseline: `5d2cf29a298d004f2f0697cf5c4ea5a47ea1e8f3`.
All checks ran in the sandbox on the runner-owned branch. No AWS or Kubernetes
credentials/access were used, no live commands ran, and no Terraform plan,
apply or destroy was executed.

Installed tooling: Terraform 1.15.0 (official HashiCorp release), Helm
3.19.0 (official Helm release). Initialized provider versions: AWS 6.68.0,
Helm 3.3.0, Cloudflare 5.27.0. The dependency lock file records these selections.
Python test dependencies were installed from `tests/requirements.txt` in a
sandbox-only venv. Initial venv creation failed because python3-venv was absent;
installing that OS package resolved it.

Final command:

```sh
HELM=/tmp/karpenter-tools/helm TERRAFORM=/tmp/karpenter-tools/terraform \
PYTHON=/tmp/karpenter-venv/bin/python scripts/check-karpenter-offline.sh
```

Results (exit 0):

- `terraform fmt -check -recursive`: passed. Baseline initially failed on
  aws-lbc.tf and network-public.tf; formatting-only corrections included.
- `terraform init -backend=false -input=false`: passed.
- `terraform validate`: passed with installed supported providers.
- Pinned 1.13.0 controller/CRD Helm pull and render: passed.
- Local capacity Helm lint/render: passed (only informational icon recommendation).
- Release CRD structural JSON Schema and unknown spec-field checks: passed.
- Controller placement/resources, bounded Spot constraints, pinned AMI, IAM/tag
  scope and Terraform discovery/identity/dependency wiring assertions: passed.
- Existing infrastructure HCL semantics and it-tools byte preservation: passed.
- Smoke shell syntax and executable fake-kubectl up/down/failure checks: passed.
- `git diff --check`: passed.

During test development the schema check initially failed on unrelated CRDs with
no v1 API, then a wiring check failed on quoted HCL parser keys; both harness
issues were corrected, and the final full command above passed with the pinned
dependencies. No successful live results are inferred from these tests.

Unverified: regional AMI availability, account Spot service-linked role/quotas,
actual bootstrap free resources, Terraform plan drift/replacement risks, API CEL
admission, controller Pod Identity credentials, NodeClass/NodePool readiness,
NodeClaim/EC2 provisioning and registration, smoke pod placement, interruption
handling, consolidation and live rollback/teardown, existing service health.
The executable smoke/runbook covers these checks for an explicitly authorized
lab deployment. Mock cleanup verifies command behavior, not real node deletion.

## Independent correction review — 2026-10-10

Reviewed current branch against `origin/main` (the baseline above), inspected all
issue requirements, and reran the complete offline command before and after fixes.
The reviewer found and corrected two safety gaps: smoke logical timeouts did not
bound hung API/credential processes, and the singleton controller rollout allowed
temporary surge capacity on small bootstrap workers. All kubectl commands now
have API and process deadlines; controller maxSurge=0 avoids a second controller.
Mock regression tests execute real GNU timeout against a stalled fake kubectl and
verify readiness failure stops before mutation. Render tests verify rollout settings.

The offline suite now downloads the official v1.13.0 CloudFormation prerequisites
and compares **every statement in all five policies**, after substitutions, rather
than merely checking selected tags. All policies match. Official EKS support,
Karpenter compatibility, release chart/image and AL2023 release sources were
independently rechecked; no version incompatibility was found. Regional availability
is still unverified. Final full offline suite: exit 0. `git diff --check`: passed.

Requirement review:

| Area | Offline conclusion / remaining deployment gate |
| --- | --- |
| IAM / identities | Official scoped policies; exact worker PassRole, dedicated Pod Identity trust, worker/CNI/ECR policies and API-only EC2_LINUX access; credentials unverified live |
| Bootstrap | Existing general settings preserved; singleton pinned and no surge; actual free resources and Spot availability must be checked before enabling capacity |
| CRD ownership/order | Pinned separate CRD release precedes controller; staged Helm capacity avoids Terraform custom-resource schema discovery; live Established/Ready unverified |
| Chart / Kubernetes / AMI | EKS 1.36, chart/controller/CRDs 1.13.0 and AL2023 v20261003 supported by primary sources; region/account availability unverified |
| Networking | Explicit private subnet IDs and single cluster SG; private addressing, NAT, IMDSv2; live connectivity and LBC discovery behavior unverified |
| Interruptions | Four official event types, encrypted SQS, source-rule/account-constrained producer and exact-queue consumer; delivery/drain unverified |
| Dynamic capacity | Finite 16 CPU/64Gi defaults, standard amd64 families/sizes, Spot only, 5m consolidation, one voluntary disruption; PDB/CEL/reconciliation unverified |
| Smoke / regression | Two 1-CPU pods, dynamic selector, process/request/rollout bounds and cleanup; mock failure/hang tests pass; live provisioning/consolidation unverified |
| Rollout / teardown | No surge, staged readiness, drain before capacity deletion, retain controller/permissions until EC2 cleanup; manual deletion budget caveat documented; live exercise unperformed |
| Existing behavior | Baseline Terraform HCL semantics and it-tools bytes preserved; no live plan or application/service regression evidence |

No confirmed offline blocker remains. Deployment is gated on an authorized plan,
bootstrap headroom, AMI availability, Spot role/quotas and readiness checks. No live
AWS/Kubernetes access, Terraform plan/apply/destroy, GitHub write or billable action
was performed by this reviewer. Unperformed live checks remain explicitly listed
above; offline results do not establish the live acceptance criteria.
