# ── Postgres credentials in Secrets Manager ──────────────────────────────────
# The password is generated here and never appears in Git. It does land in the
# Terraform state (S3, encrypted, versioned, private) like any random_password.
# External Secrets Operator syncs it into the cluster as the Secret that the
# flights-api Deployment and the Postgres subchart both read.

resource "random_password" "db" {
  length = 32
  # Alphanumeric only: the value goes into a connection URL and a shell-free env var.
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name        = var.db_secret_name
  description = "Postgres credentials for flights-api (keys DB_USER, DB_PASSWORD)"

  # 0 = delete immediately on destroy, so a teardown/re-create cycle can reuse
  # the name instead of waiting out the default 30-day recovery window.
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    DB_USER     = var.db_user
    DB_PASSWORD = random_password.db.result
  })
}
