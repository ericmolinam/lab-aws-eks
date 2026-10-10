# Release-matched policy templates are translated from the official v1.13.0
# CloudFormation example; see iam/karpenter/SOURCE.md.
data "aws_caller_identity" "karpenter" {}
data "aws_partition" "karpenter" {}

locals {
  karpenter_version = "1.13.0"
  karpenter_events = {
    health    = { source = ["aws.health"], detail-type = ["AWS Health Event"] }
    spot      = { source = ["aws.ec2"], detail-type = ["EC2 Spot Instance Interruption Warning"] }
    rebalance = { source = ["aws.ec2"], detail-type = ["EC2 Instance Rebalance Recommendation"] }
    state     = { source = ["aws.ec2"], detail-type = ["EC2 Instance State-change Notification"] }
  }
}

resource "aws_iam_role" "karpenter_nodes" {
  name = "${local.eks_name}-karpenter-nodes"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_nodes" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy", "AmazonEC2ContainerRegistryPullOnly"])
  role       = aws_iam_role.karpenter_nodes.name
  policy_arn = "arn:${data.aws_partition.karpenter.partition}:iam::aws:policy/${each.value}"
}

resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.karpenter_nodes.arn
  type          = "EC2_LINUX"
}

resource "aws_iam_role" "karpenter" {
  name = "${local.eks_name}-karpenter-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "pods.eks.amazonaws.com" }
      Condition = { StringEquals = {
        "aws:RequestTag/eks-cluster-name"           = local.eks_name
        "aws:RequestTag/kubernetes-namespace"       = "kube-system"
        "aws:RequestTag/kubernetes-service-account" = "karpenter"
      } }
    }]
  })
}

resource "aws_iam_policy" "karpenter" {
  for_each = fileset("${path.module}/iam/karpenter", "*.json.tftpl")
  name     = "${local.eks_name}-karpenter-${trimsuffix(each.value, ".json.tftpl")}"
  policy = templatefile("${path.module}/iam/karpenter/${each.value}", {
    partition     = data.aws_partition.karpenter.partition
    region        = local.region
    account_id    = data.aws_caller_identity.karpenter.account_id
    cluster_name  = local.eks_name
    node_role_arn = aws_iam_role.karpenter_nodes.arn
    queue_arn     = aws_sqs_queue.karpenter.arn
  })
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  for_each   = aws_iam_policy.karpenter
  role       = aws_iam_role.karpenter.name
  policy_arn = each.value.arn
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.eks.name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter.arn
}

resource "aws_sqs_queue" "karpenter" {
  name                      = "${local.eks_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each      = local.karpenter_events
  name          = "${local.eks_name}-karpenter-${each.key}"
  event_pattern = jsonencode(each.value)
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each   = aws_cloudwatch_event_rule.karpenter
  rule       = each.value.name
  arn        = aws_sqs_queue.karpenter.arn
  depends_on = [aws_sqs_queue_policy.karpenter]
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow", Principal = { Service = "events.amazonaws.com" }
        Action = "sqs:SendMessage", Resource = aws_sqs_queue.karpenter.arn
        Condition = {
          ArnEquals    = { "aws:SourceArn" = [for rule in aws_cloudwatch_event_rule.karpenter : rule.arn] }
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.karpenter.account_id }
        }
      },
      {
        Sid       = "DenyHTTP", Effect = "Deny", Principal = "*"
        Action    = "sqs:*", Resource = aws_sqs_queue.karpenter.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "helm_release" "karpenter_crd" {
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = local.karpenter_version
  namespace  = "kube-system"
  depends_on = [aws_eks_node_group.general, aws_eks_access_policy_association.sso_admin]
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = local.karpenter_version
  namespace  = "kube-system"
  skip_crds  = true
  values = [file("${path.module}/manifests/karpenter/controller-values.yaml"), yamlencode({
    settings = {
      clusterName       = aws_eks_cluster.eks.name
      clusterEndpoint   = aws_eks_cluster.eks.endpoint
      interruptionQueue = aws_sqs_queue.karpenter.name
      eksControlPlane   = true
    }
    controller = { env = [{ name = "AWS_REGION", value = local.region }] }
  })]
  depends_on = [helm_release.karpenter_crd, aws_eks_addon.this,
    aws_eks_pod_identity_association.karpenter, aws_iam_role_policy_attachment.karpenter,
    aws_iam_role_policy_attachment.karpenter_nodes, aws_eks_access_entry.karpenter_nodes,
  aws_cloudwatch_event_target.karpenter]
}

# Helm owns these custom resources, avoiding kubernetes_manifest plan-time
# schema discovery before CRDs exist. Enable only after bootstrap checks.
resource "helm_release" "karpenter_capacity" {
  count     = var.karpenter_capacity_enabled ? 1 : 0
  name      = "karpenter-capacity"
  chart     = "${path.module}/manifests/karpenter"
  namespace = "kube-system"
  values = [yamlencode({
    # Make local template/default changes visible to Terraform/Helm upgrades.
    manifestRevision = sha256(join("", [for f in sort(tolist(fileset("${path.module}/manifests/karpenter", "**"))) : filesha256("${path.module}/manifests/karpenter/${f}")]))
    nodeRole         = aws_iam_role.karpenter_nodes.name
    subnetIds        = [for subnet in aws_subnet.private : subnet.id]
    securityGroupId  = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
    zones            = [for subnet in aws_subnet.private : subnet.availability_zone]
    clusterName      = local.eks_name
    cpuLimit         = var.karpenter_cpu_limit
    memoryLimit      = var.karpenter_memory_limit
    capacityType     = var.karpenter_capacity_type
    instanceFamilies = var.karpenter_instance_families
    instanceSizes    = var.karpenter_instance_sizes
    consolidateAfter = var.karpenter_consolidate_after
  })]
  depends_on = [helm_release.karpenter]
}
