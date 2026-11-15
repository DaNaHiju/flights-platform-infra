# bootstrap

Creates the resources that the root configuration's remote backend (`backend "s3"` in `../versions.tf`) depends on.

## What it creates

| Resource | Name | Notes |
|---|---|---|
| S3 bucket | `flights-tfstate-<account_id>` | versioning enabled, SSE AES256, all public access blocked, `prevent_destroy = true` |
| DynamoDB table | `flights-tf-locks` | `PAY_PER_REQUEST`, hash key `LockID` (S) |

Region defaults to `eu-north-1` (variable `region`).

Outputs: `bucket_name`, `table_name`, `region`.

## Why local state

This folder cannot store its state in the bucket it creates (chicken-and-egg), so it uses **local state**. `*.tfstate` and `*.tfstate.*` are git-ignored: keep the local state file safe, because losing it means Terraform no longer tracks these resources.

## Apply

```bash
export AWS_PROFILE=aws-lab
cd bootstrap
terraform init
terraform fmt -check
terraform validate
terraform plan      # expect 5 resources to add: bucket, versioning, SSE, public access block, table
terraform apply
```

Then run `terraform init` in the repo root; it will use the bucket and table.

## Teardown

Only do this once nothing else uses the backend (migrate or delete the root state first).

1. Empty **every version** of the bucket, including delete markers. `aws s3 rm` is not enough for a versioned bucket. Delete each version and delete marker with `aws s3api delete-objects`, or use the console's "Empty bucket".
2. Remove (or set to `false`) `prevent_destroy` in `main.tf`.
3. `terraform destroy` inside `bootstrap/`.

## Alternative: `use_lockfile`

Terraform >= 1.10 supports S3-native locking (`use_lockfile = true` in the `backend "s3"` block), which stores a lock file next to the state object and removes the need for DynamoDB. `dynamodb_table` is deprecated in recent Terraform versions. This setup keeps the DynamoDB table for now. To switch, set `use_lockfile = true` in the root backend, drop `dynamodb_table`, and remove `aws_dynamodb_table.tflock` from this folder.
