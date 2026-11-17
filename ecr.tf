# ── ECR repositories (one per service image) ────────────────────────────────

resource "aws_ecr_repository" "services" {
  for_each = toset(var.ecr_repositories)

  name = each.value
  # Mutable: re-running CI for the same commit re-pushes the same sha-<7> tag.
  image_tag_mutability = "MUTABLE"
  # Lets `terraform destroy` delete a repository that still holds images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

# Keep storage cost flat: only the 15 most recent images per repository.
resource "aws_ecr_lifecycle_policy" "services" {
  for_each = aws_ecr_repository.services

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 15 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}
