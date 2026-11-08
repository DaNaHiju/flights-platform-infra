# flights-platform-infra

Terraform for the flights-platform EKS cluster on an AWS Free Plan account.

## Requirements and order

Needs Terraform >= 1.10 (S3 `use_lockfile`), AWS CLI v2, `kubectl` and `make`.

1. `make bootstrap-up` creates the state bucket `flights-platform-tfstate-<account_id>`
   (local state in `bootstrap/`, keep that file safe) and writes `backend.hcl`
   with the bucket and region. Without the Makefile: copy `backend.hcl.example`
   to `backend.hcl` and fill it in.
2. `cp terraform.tfvars.example terraform.tfvars` and set at least `alert_email`
   (required).
3. `make up` runs `terraform init -backend-config=backend.hcl` and `terraform apply`.

## Cost and teardown

Rough cost while the stack is up (us-east-1, on-demand, check current pricing):
EKS control plane ~$0.10/h, NAT gateway ~$0.045/h, 2x t3.small ~$0.04/h, 1-2x
m7i-flex.large ~$0.10-0.20/h each. About **$0.30-0.50/h**, i.e. ~$7-12 per day.
The monthly budget is $30 with alerts at 50/80/100 % actual and 100 % forecast.

**ALWAYS `make down` when you finish.** It deletes Ingresses and
LoadBalancer Services (so AWS releases the load balancers), waits for them to
disappear, runs `terraform destroy` and then `make check-orphans`, which exits
non-zero if anything tagged `Project=flights-platform`, or any NAT gateway,
ELB, ENI or EIP in the VPC, is left.

`make bootstrap-down` destroys the state bucket and **all Terraform state**;
it asks for confirmation. Run `make down` first.

## Before the first apply

- Use an IAM user with MFA. Never the root user.
- Do **not** enable AWS Organizations or IAM Identity Center: doing so converts
  the account to Paid and expires the credits.
- Check the on-demand vCPU quota in Service Quotas ("Running On-Demand Standard
  instances"). Defaults need up to 6 vCPUs (2x t3.small system + up to 2x
  m7i-flex.large app); new accounts may have a lower limit.

## Deviations from the assignment

- **Instance types:** Free Plan only allows t3.micro, t3.small, t4g.micro,
  t4g.small, c7i-flex.large and m7i-flex.large. System nodes use t3.small, app
  nodes m7i-flex.large (min 1 / max 2); variable validations reject other types.
- **State locking:** S3 native `use_lockfile` instead of a DynamoDB table, since
  `dynamodb_table` is deprecated. No DynamoDB resources exist.
