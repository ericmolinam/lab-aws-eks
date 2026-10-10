# Karpenter lab operations

Karpenter provisions workers for unschedulable pods based on **resource requests**
and scheduling constraints. It does not scale EC2 on a CPU percentage. HPA could
later use metrics-server to increase application replicas, whose requests then
create node demand; neither HPA nor metrics-server is installed here.

## Version decision (verified 2026-10-10)

[EKS version support](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
lists 1.36 on standard support. The [official compatibility matrix](https://karpenter.sh/docs/upgrading/compatibility/)
requires Karpenter >=1.13 for 1.36. Both controller and CRD charts are pinned to
1.13.0; the controller chart also supplies a pinned image digest. Kubernetes stays
1.36. [AL2023 v20261003](https://github.com/awslabs/amazon-eks-ami/releases/tag/v20261003)
includes `amazon-eks-node-al2023-x86_64-standard-1.36-v20261003` (1.36.4-20261003),
using kernel 6.18. The release warning for kernel 6.12 concerns versions 1.31–1.35,
not these 1.36 workers. The alias is `al2023@v20261003`, never `latest`.
Availability of that AMI in eu-west-1 remains a live preflight check.

The APIs are `karpenter.sh/v1` and `karpenter.k8s.aws/v1`. Selected settings are
checked against the downloaded 1.13.0 CRDs, with [release NodePool](https://karpenter.sh/v1.13/concepts/nodepools/),
[NodeClass](https://karpenter.sh/v1.13/concepts/nodeclasses/) and
[disruption](https://karpenter.sh/v1.13/concepts/disruption/) documentation.
Chart OCI digests observed offline:

- controller chart: `sha256:58f71ed9635a4641bf5d09517ff276c6712eb7b59795ce93a4c321a9fcc3bbf5`
- CRD chart: `sha256:3176c3ac16914cd033ac17fea9428d5f21170e1347d9cd91ae43a34836dfa5a6`

## Bootstrap and workload capacity

`general` stays Spot with t3.small/t3a.small/t2.small, desired 2/min 1/max 4, and
its existing desired-size lifecycle setting. The controller is pinned using
`eks.amazonaws.com/nodegroup: general`; one replica requests 100m CPU/256Mi memory
and has a 512Mi memory limit. This is a small-lab starting size, not measured live
capacity evidence. These 2Gi instances also run CNI, kube-proxy, Pod Identity,
CoreDNS, LBC, ExternalDNS and application pods. Before deploying, use
`kubectl describe nodes -l eks.amazonaws.com/nodegroup=general` to compare per-node
allocatable capacity, Allocated resources and pod slots. At least one Ready node
must have room for the controller request **and** system pods, with memory headroom
to its limit; inspect existing Pending pods too. Stop on insufficient capacity,
OOMKills or sustained controller throttling; report a bootstrap blocker instead
of resizing or moving the controller onto dynamic nodes. Readiness cannot be
inferred just from instance size. A singleton briefly pauses reconciliation on
restart. Controller rolling updates explicitly use maxSurge=0/maxUnavailable=1
so upgrades require capacity for only one controller, with a brief reconciliation
pause. Spot bootstrap capacity can disappear; an independently approved change
to On-Demand bootstrap capacity (and possibly larger instances/two replicas) is
recommended for availability, but is outside this change.

Dynamic `lab` capacity uses Linux/amd64 Spot, private subnets in the existing two
AZs, standard m/c/r families at large/xlarge sizes, no GPU/Neuron and no automatic
On-Demand fallback. It selects **explicit subnet IDs and exactly the EKS cluster
security group ID**. The existing cluster group's self-referencing connectivity
is shared with managed workers/control plane; no extra cluster ownership SG tags,
SSH rules, or CIDR-wide ingress are added. Public addresses are disabled; existing
NAT supplies AWS API/image access. IMDSv2 is required, hop limit 1; pods should
use Pod Identity rather than node credentials. Existing it-tools requests,
Ingress, LBC, ExternalDNS and SSO access entries are unchanged.

| Terraform input | Default | Purpose |
| --- | --- | --- |
| karpenter_capacity_enabled | false | Explicit second deployment stage |
| karpenter_cpu_limit | 16 | Aggregate dynamic vCPU (positive, at most 64) |
| karpenter_memory_limit | 64Gi | Aggregate dynamic memory, positive integer Gi |
| karpenter_capacity_type | spot | on-demand requires explicit owner-approved change |
| karpenter_instance_families | m5/m5a/m6i/m6a, c5/c5a/c6i/c6a, r5/r5a/r6i/r6a | Allowlisted standard families |
| karpenter_instance_sizes | large, xlarge | Bounded choices |
| karpenter_consolidate_after | 5m | Quiet period before consolidation |

Limits are eventually consistent guardrails: concurrent provisioning can briefly
exceed them. They are **not an AWS spending cap**, and do not count bootstrap
nodes. Requests, DaemonSet overhead, AZ affinity, volumes, taints, PDBs and
availability affect usable capacity. Consolidation is `WhenEmptyOrUnderutilized`,
with at most one voluntary disruption at once. PDBs and do-not-disrupt annotations
can block consolidation; the budget does not stop unavoidable Spot termination.
Expiration is disabled to avoid periodic lab churn. Spot-to-Spot replacement is
left at the release's disabled default; empty-node removal and feasible deletion
consolidation still operate. Other applications may occupy dynamic nodes, so
removing the smoke test need not return the pool to zero.

## Initialization and authorized deployment order

No commands in this section were executed against AWS or Kubernetes during
implementation. Apply, smoke and cleanup require separate owner authorization.

1. Install Terraform >=1.15 and compatible Helm (offline verification used
   Terraform 1.15.0 and Helm 3.19.0). Run the offline checks below. Initialize the
   existing backend/workspace normally for deployment; never replace its state.
2. Confirm account/region/cluster, access, NAT connectivity, AMI regional
   availability, private subnet IP space, EC2 Spot vCPU quotas and instance
   offerings. Account-wide `AWSServiceRoleForEC2Spot` must exist. Have an authorized
   account administrator inspect it and, only if absent, create it with
   `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`.
   Terraform intentionally does not manage/create this shared role to avoid
   colliding with an existing account-wide resource. Controller IAM cannot create it.
3. Check bootstrap capacity as above. Keep `karpenter_capacity_enabled=false`.
   With approved credentials run `terraform plan -out=karpenter.tfplan` and inspect
   `terraform show karpenter.tfplan`. Reject any cluster replacement, managed-group
   deletion/resizing, SSO removal or unexpected changes to LBC/DNS/app resources.
   Baseline t2.small/AMI and Spot availability may themselves block bootstrap;
   resolve separately with owner approval. Existing drift cannot be assessed offline.
4. Only with approval apply the reviewed plan. Terraform creates dedicated worker
   IAM/access, constrained controller Pod Identity, SQS/EventBridge, then the
   `karpenter-crd` Helm release, then the controller. Wait for CRDs Established:
   `kubectl wait --for=condition=Established crd/nodepools.karpenter.sh crd/nodeclaims.karpenter.sh crd/ec2nodeclasses.karpenter.k8s.aws --timeout=180s`.
   Check `kubectl -n kube-system rollout status deploy/karpenter --timeout=300s`
   and placement with `kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter -o wide`.
   Validate node labels, Pod Identity association and controller logs; stop if Pending.
5. Persist `karpenter_capacity_enabled=true` in your private tfvars, review a new
   full plan, then apply with approval. The local `karpenter-capacity` Helm chart
   declaratively owns the NodeClass and NodePool; do not also kubectl apply those
   resources. Helm needs no Kubernetes custom-resource schema at Terraform plan
   time, unlike `kubernetes_manifest`; `depends_on` alone would not solve that
   provider's fresh-cluster schema discovery. Staging still separates bootstrap
   readiness from enabling EC2 provisioning. Wait for NodeClass/NodePool Ready
   before creating dynamic workloads.

API-only node authentication uses a dedicated `EC2_LINUX` access entry. It does
not modify `aws-auth` or existing SSO entries. Policy provenance and unavoidable
read-only wildcards are described in `iam/karpenter/SOURCE.md`.

## Bounded smoke test (authorized environment only)

`scripts/karpenter-smoke.sh up` applies a namespace and zero-replica deployment,
then scales it to **two pods**, each requesting 1 vCPU/256Mi. Its `lab` selector
cannot match bootstrap nodes. On an initially empty pool this creates scheduling
demand sufficient for a NodeClaim, without a huge workload. Readiness waits 180s;
pod rollout times out after 600s. GNU `timeout` is required: every kubectl process
has a wall-clock deadline and a 30s API request timeout. The entire `up` command
is bounded below 20 minutes including kill grace; `down` is bounded to 215s.
A timeout deliberately leaves evidence available;
run `scripts/karpenter-smoke.sh down` to remove the namespace (180s timeout), even
if `up` failed. Do not increase replicas repeatedly to solve provisioning failures.

Capture NodeClaims, Ready nodes and pod Running/Ready placement. For every worker
inspect its providerID and use approved read-only AWS describe commands to confirm
private subnet, no public address, Spot lifecycle and selected SG/AMI:

```sh
kubectl get nodepool lab -o yaml
kubectl get ec2nodeclass lab -o yaml
kubectl get nodeclaims -l karpenter.sh/nodepool=lab -o wide
kubectl get nodes -L eks.amazonaws.com/nodegroup,karpenter.sh/nodepool,karpenter.sh/capacity-type,topology.kubernetes.io/zone
kubectl -n karpenter-smoke get pods -o wide
aws ec2 describe-instances --region eu-west-1 --instance-ids <instance-id>
```

After `down`, observe for up to 15 minutes (five-minute delay plus reconciliation,
eviction and termination); periodically run `kubectl get nodeclaims,nodes` and
check controller logs. An empty smoke-only pool should reach zero dynamic nodes
while `general` and the controller remain Ready. This is an observation timeout,
not a guaranteed consolidation SLA. Stop and diagnose after the window; do not
force-delete finalizers. Check LBC/ExternalDNS deployments, it-tools rollout,
Ingress status and the app URL before and after. Record results rather than
assuming unrelated services survived.

## Diagnostics and interruptions

```sh
kubectl describe nodepool lab
kubectl describe ec2nodeclass lab
kubectl get nodeclaims -o yaml
kubectl -n kube-system logs deploy/karpenter --all-containers --since=15m
kubectl get events -A --sort-by=.lastTimestamp
kubectl -n karpenter-smoke describe pods
kubectl get pdb -A
```

NodeClass Ready diagnoses AMI/subnets/SGs/instance profile; NodePool Ready diagnoses
usable configuration; NodeClaim conditions distinguish launch, registration and
initialization failures. Pending pods with no NodeClaim suggest incompatible
selectors/requests, pool limits, constraints or controller identity errors.
Launched instances failing registration suggest access-entry/IAM, DNS/NAT/API
connectivity, CNI or bootstrap issues. `AccessDenied` requires checking Pod Identity
agent, association/service account, release policy tags and constrained PassRole.
`InsufficientInstanceCapacity` or limit errors require checking Spot AZ offerings
and quotas; do not silently enable On-Demand. Inspect OOM/restarts and bootstrap
Allocated resources for controller capacity problems.

Four regional EventBridge rules deliver Health scheduled events, Spot warnings,
rebalance recommendations and instance state changes to the encrypted five-minute
SQS queue. Rules receive account/region events; the controller matches relevant
NodeClaims. Check AWS EventBridge FailedInvocations and SQS visible/oldest-message
metrics and logs for queue/permission failures. Spot warnings trigger best-effort
replacement/drain with limited notice; rebalance recommendations are observed but
are not a guarantee of proactive replacement. PDBs cannot prevent EC2 reclaim.
Do not inject fake/live interruptions without explicit authorization.

## Rollback and safe teardown

Keep the controller, Pod Identity, node access, IAM, queue and CRDs until all
dynamic nodes are gone. First remove the smoke namespace and drain/remove or
reschedule **all** workloads on `lab` nodes to approved surviving capacity. Honor
PDBs and wait for evictions; check application recovery. With approval, change
`karpenter_capacity_enabled=false`, review/apply a plan removing only the capacity
Helm release. NodePool deletion cascades NodeClaims and controller finalizers drain
and terminate their EC2 nodes. Manual NodePool deletion is not rate-limited by the
one-node disruption budget; drain/reschedule workloads first rather than relying
on that budget for teardown safety. Wait for no `lab` NodeClaims/nodes and confirm in
EC2 that tagged workers have terminated. If blocked, retain controller and policies
and diagnose workloads/PDBs; never strip finalizers just to unblock Terraform.

Only after that, a separately reviewed code removal can uninstall the controller,
then CRD release, then queue/rules, Pod Identity and IAM/access resources. Check
and clean controller-created instance profiles/launch templates while permissions
still exist. Do not destroy the root stack as a shortcut: it contains existing
cluster/NAT/apps/access infrastructure. Helm chart downgrade alone is not a safe
CRD rollback; check the release upgrade guide and stored API versions first.
Returning to the pre-Karpenter configuration requires workloads to fit the
unchanged managed group before removing dynamic capacity.

Zero dynamic nodes still incurs EKS control-plane, NAT gateways, bootstrap Spot,
load balancer, storage, DNS and other account costs. Queue/EventBridge charges can
also remain. Consolidation is a capacity optimization, not a zero-cost switch.

## Reproducible offline verification

```sh
python3 -m venv /tmp/karpenter-checks
/tmp/karpenter-checks/bin/pip install -r tests/requirements.txt
PYTHON=/tmp/karpenter-checks/bin/python scripts/check-karpenter-offline.sh
```

Set HELM/TERRAFORM to installed binary paths if needed. The script downloads only
pinned public charts, initializes providers with no backend, validates Terraform,
renders Helm, checks release CRD structural JSON Schema and unknown spec fields,
compares all five IAM policies with the pinned official CloudFormation source,
asserts controller/Spot/IAM invariants, compares existing Terraform semantics and
it-tools bytes with baseline 5d2cf29, and executes smoke sequencing/cleanup with a
fake kubectl, including a stalled-process deadline test using real GNU timeout.
It never calls real kubectl or AWS. Kubernetes CEL admission,
controller reconciliation and cloud permissions cannot be proven by JSON Schema;
server admission and the live acceptance checks above remain required.
