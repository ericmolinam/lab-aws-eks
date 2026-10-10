The purpose of this document is to describe how my personal AWS Organization and accounts are configured to allow different users and profiles to use IAM Identity Center to natively access and interact with an EKS cluster.

## Architecture

The following diagram shows the overall flow of how identity and access to the EKS cluster are managed.


```mermaid
flowchart TD
    subgraph Management_Account["emolinam5-root account"]
        Users["Users (admin1, dev1, dev2, ...)"]
        Groups["Identity Center: Groups (admin, developer)"]
        PermSets["Permission Sets:
        - AdministratorAccess
        - PowerUserAccess"]

        Users -->|members of| Groups
        Groups -->|mapped to| PermSets
    end

    subgraph AWS_Organizations["AWS Organizations assignments"]
        AssignAdmin["Assignment: admin + AdministratorAccess -> dev AWS Account"]
        AssignDev["Assignment: developer + PowerUserAccess -> dev AWS Account"]
    end

    subgraph Dev_Account["aws-platform-dev account"]
        RoleAdmin["IAM Role (auto-provisioned):
        AWSReservedSSO_AdministratorAccess_*"]
        RoleDev["IAM Role (auto-provisioned):
        AWSReservedSSO_PowerUserAccess_*"]

        subgraph EKS_Access_Entries["EKS Access Entries (API Auth)"]
            EntryAdmin["aws_eks_access_entry: sso_admin
            Policy: AmazonEKSClusterAdminPolicy
            Scope: cluster"]
            EntryDev["aws_eks_access_entry: sso_poweruser
            Policy: AmazonEKSEditPolicy
            Scope: cluster"]
        end

        subgraph Cluster["EKS Cluster (dev-eks)"]
            ControlPlane["ControlPlane (API Server)"]
            NodeGroup["Node Group (Spot instances)"]
        end
    end

    PermSets --> AWS_Organizations
    AssignAdmin -.->|provisions| RoleAdmin
    AssignDev -.->|provisions| RoleDev

    RoleAdmin -->|principal_arn| EntryAdmin
    RoleDev -->|principal_arn| EntryDev

    EntryAdmin -->|grants admin to| ControlPlane
    EntryDev -->|grants edit to| ControlPlane
    ControlPlane --- NodeGroup
```


1. **Users & Groups**:
   - Users (`admin1`, `dev1`, `dev2`) are defined centrally through Identity Center.
   - Users are grouped into functional teams (e.g., `admin`, `developer`).

2. **Permission Sets**:
   - `AdministratorAccess`: Full administrative privileges across AWS services.
   - `PowerUserAccess`: Full AWS services access excluding direct IAM/Organization user and group management.

3. **Account Assignments**:
   - Groups are assigned to the different AWS accounts (e.g., **`aws-platform-dev`**) with their respective Permission Sets.
   - AWS Identity Center automatically provisions the IAM roles inside the AWS account.
      - **Note**: Identity Center creates **one IAM role per Permission Set per target account**, not one role per user. Every member of the `developer` group assumes the same underlying IAM role in the AWS account.

---

When a user executes AWS CLI or `kubectl` commands, authentication traverses three stages: **federated identity**, **STS role assumption**, and **EKS access validation**.

```mermaid
sequenceDiagram
    autonumber
    actor User as Developer / Admin
    participant CLI as AWS CLI (SSO Plugin)
    participant SSO as IAM Identity Center (Portal)
    participant STS as AWS STS (DEV_ACCOUNT_ID)
    participant K8s as kubectl
    participant EKS as EKS Control Plane (dev-eks)

    User->>CLI: aws sso login --profile <profile>
    CLI->>SSO: Initiates PKCE OAuth2 flow
    SSO-->>User: Browser prompt for credentials + MFA
    User->>SSO: Authenticates
    SSO-->>CLI: Issues SSO bearer token
    
    User->>K8s: kubectl get pods
    K8s->>CLI: Calls exec credential plugin (aws eks get-token)
    CLI->>STS: AssumeRoleWithSAML (assumes AWSReservedSSO_*)
    STS-->>CLI: Returns temporary STS session credentials
    CLI-->>K8s: Returns signed token (STS presigned URL)
    K8s->>EKS: API request with Bearer Token
    EKS->>EKS: Extracts assumed-role base ARN
    EKS->>EKS: Matches ARN against aws_eks_access_entry
    EKS-->>K8s: HTTP 200 (Authorized via Access Policy Association)
```
**Note**:  Users with the same Permission Set share the underlying IAM Role ARN, but their specific username appears in the STS session name:
```text
arn:aws:sts::<DEV_ACCOUNT_ID>:assumed-role/AWSReservedSSO_PowerUserAccess_<hash>/<username>
```
This way, tools like AWS CloudTrail and EKS audit logs record `<username>` on every API call, preserving individual auditability.

---
Once the cluster is up and running, traffic routing and public DNS records are fully automated and declarative.

```mermaid
flowchart LR
    User([User Request]) --> Cloudflare[Cloudflare DNS]
    Cloudflare --> ALB[AWS Application Load Balancer]
    
    subgraph EKS["EKS Cluster"]
        ING[Ingress: it-tools]
        LBC[AWS Load Balancer Controller]
        EDNS[ExternalDNS]
        POD[Pods: it-tools]
    end

    ACM[(ACM Certificate)] -.->|TLS match| ALB
    ING -->|triggers provisioning| LBC
    LBC -->|provisions & manages| ALB
    ALB -->|direct IP routing| POD
    ING -->|watches host & status| EDNS
    EDNS -->|syncs CNAME| Cloudflare
```

1. **AWS Load Balancer Controller**:
   - Authenticates using **EKS Pod Identity**.
   - The AWS LBC watches for Kubernetes `Ingress` resources and automatically creates/configures an internet-facing AWS Application Load Balancer.
   - Automatically discovers matching TLS certificates in **AWS Certificate Manager (ACM)** for configured hostnames.

2. **ExternalDNS**:
   - Watches the cluster's `Ingress` resources.
   - Automatically provisions, updates, and deletes `CNAME` records in **Cloudflare** pointing to the ALB address, ensuring DNS stays in sync with the application lifecycle.

## Demand-based worker capacity

Karpenter adds request-based Spot workload provisioning and consolidation while
retaining the existing `general` managed group for bootstrap capacity. See the
[Karpenter deployment, verification and teardown runbook](docs/KARPENTER.md) for
version pins, configuration, offline checks and the bounded smoke test.
Dynamic capacity is disabled until the explicit second deployment stage.
