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

An independent read-only reviewer also ran the complete offline command with the
same installed tooling: exit 0, no material implementation defects found. This
review likewise made no live AWS/Kubernetes calls.
