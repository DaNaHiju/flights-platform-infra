# ── IAM roles for EKS ────────────────────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${local.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_node_group" {
  name = "${local.name_prefix}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.36"

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.cluster.id]
  }

  tags = merge(local.common_tags, { Name = local.cluster_name })

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ── Launch Template (carries the worker nodes' security group) ──────────────
# aws_eks_node_group has no security_group_ids argument, so the nodes SG is
# attached via a launch template instead. Instance type and scaling stay on
# the node group; this template's only job is the SG attachment.

resource "aws_launch_template" "nodes" {
  name_prefix = "${local.name_prefix}-nodes-"

  vpc_security_group_ids = [aws_security_group.nodes.id]

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${local.name_prefix}-node" })
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── EKS Managed Node Groups (system + app) ───────────────────────────────────

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-system"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = [var.system_instance_type]

  labels = {
    workload = "system"
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = "$Latest"
  }

  scaling_config {
    desired_size = var.system_desired_node_count
    min_size     = var.system_min_node_count
    max_size     = var.system_max_node_count
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-system-node-group" })

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]
}

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-app"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = [var.app_instance_type]

  labels = {
    workload = "app"
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = "$Latest"
  }

  scaling_config {
    desired_size = var.app_desired_node_count
    min_size     = var.app_min_node_count
    max_size     = var.app_max_node_count
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-app-node-group" })

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]
}

# ── Budget alarm (cost guardrail) ────────────────────────────────────────────
# Alerts at 50/80/100 % of actual spend and at 100 % of forecasted spend.

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = "30"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80, 100]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
