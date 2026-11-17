locals {
  app_name    = var.app_name
  environment = var.environment

  name_prefix = "${local.app_name}-${local.environment}"

  cluster_name = "${local.name_prefix}-eks"

  common_tags = {
    Application = local.app_name
    Environment = local.environment
    ManagedBy   = "terraform"
  }

  # Availability zones: first two in the selected region
  azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
  ]

  public_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 0),
    cidrsubnet(var.vpc_cidr, 8, 1),
  ]

  private_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 10),
    cidrsubnet(var.vpc_cidr, 8, 11),
  ]

  # One NAT gateway when single_nat is true, otherwise one per AZ.
  nat_count = var.single_nat ? 1 : length(local.azs)

  # Two managed node groups. `system` hosts the platform (ArgoCD, Istio, ESO,
  # controllers) and is untainted; `app` hosts the workloads and carries a taint
  # so nothing lands there without an explicit toleration.
  node_groups = {
    system = {
      instance_type = var.system_node_instance_type
      min           = var.system_node_min
      desired       = var.system_node_desired
      max           = var.system_node_max
      labels        = { role = "system" }
      taints        = []
    }
    app = {
      instance_type = var.app_node_instance_type
      min           = var.app_node_min
      desired       = var.app_node_desired
      max           = var.app_node_max
      labels        = { role = "app", workload = "app" }
      taints        = [{ key = "workload", value = "app", effect = "NO_SCHEDULE" }]
    }
  }
}

data "aws_caller_identity" "current" {}
