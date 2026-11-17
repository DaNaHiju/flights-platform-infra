output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "nodes_security_group_id" {
  description = "Security group attached to the worker nodes"
  value       = aws_security_group.nodes.id
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "ecr_registry" {
  description = "ECR registry host (images are <registry>/<repository>:sha-<7>)"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "ECR repository URL per service"
  value       = { for k, r in aws_ecr_repository.services : k => r.repository_url }
}

output "db_secret_name" {
  description = "Secrets Manager secret with the Postgres credentials"
  value       = aws_secretsmanager_secret.db.name
}

output "pod_identity_role_arns" {
  description = "Pod Identity role ARNs by component"
  value = {
    external_secrets             = aws_iam_role.external_secrets.arn
    aws_load_balancer_controller = aws_iam_role.aws_load_balancer_controller.arn
    cluster_autoscaler           = aws_iam_role.cluster_autoscaler.arn
    ebs_csi                      = aws_iam_role.ebs_csi.arn
  }
}

output "github_ecr_push_user" {
  description = "IAM user whose access key is loaded into GitHub Secrets (created by hand, not by Terraform)"
  value       = aws_iam_user.github_ecr_push.name
}
