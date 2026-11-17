# flights-platform-infra

Terraform for the `flights-platform` EKS environment (region `eu-north-1`). GitOps content (Helm charts, ArgoCD) lives in `flights-platform-manifests`; application code in `flights-platform`.

Remote state: S3 `flights-tfstate-565923528020` + DynamoDB `flights-tf-locks`, created by [`bootstrap/`](bootstrap/README.md) (local state, never touched by the root config).

## What it creates

| File | Resources |
|---|---|
| `vpc.tf` | VPC, 2 AZs, public + private subnets, IGW, **one** NAT gateway (`single_nat = true`) |
| `security-groups.tf` | Control plane and node SGs, SG-to-SG rules (incl. cluster→nodes TCP 1025-65535) |
| `eks.tf` | EKS 1.35 (private endpoint + public endpoint restricted by CIDR), node groups `system` and `app` (both `m7i-flex.large`, see "Deviations"; `app` tainted `workload=app:NoSchedule`), add-ons: vpc-cni, kube-proxy, coredns, eks-pod-identity-agent, aws-ebs-csi-driver |
| `pod-identity.tf` | Roles + Pod Identity associations: external-secrets, aws-load-balancer-controller, cluster-autoscaler, ebs-csi |
| `ecr.tf` | ECR `flights-api`, `flights-worker`, `flights-web` (scan on push, keep last 15 images) |
| `secrets.tf` | Secrets Manager `flights/eks/db` (keys `DB_USER`, `DB_PASSWORD`, random password) |
| `github-ci.tf` | IAM user `github-ecr-push` (ECR push to the 3 repositories only, no console) |

Nothing here creates a load balancer: the ALB is created at runtime by the AWS Load Balancer Controller from an Ingress in the manifests repo. See [DESTROY.md](DESTROY.md) for why that matters at teardown.

## Usage

```bash
export AWS_PROFILE=aws-lab
cp terraform.tfvars.example terraform.tfvars   # git-ignored; set public_access_cidrs
terraform init
terraform plan -out=eks.tfplan
terraform apply eks.tfplan
$(terraform output -raw kubeconfig_command)
```

Only free-tier-eligible instance types are accepted (validation in `variables.tf`, list in `locals.tf`).

### Changing the allowed IP for the EKS API

The public EKS endpoint only accepts the CIDRs in `public_access_cidrs` (`terraform.tfvars`, git-ignored). If your public IP changes, `kubectl` times out. Fix:

```bash
curl -s https://checkip.amazonaws.com        # your new IP
# edit terraform.tfvars: public_access_cidrs = ["<new-ip>/32"]
terraform apply -target=aws_eks_cluster.main
```

(Or, without Terraform, as a stopgap: `aws eks update-cluster-config --name flights-dev-eks --resources-vpc-config publicAccessCidrs=<new-ip>/32`; then reconcile `terraform.tfvars`, otherwise the next apply reverts it.)

## Deviations from the assignment

Both come from limits that AWS puts on Free plan accounts, not from design preference.

| Assignment | Here | Cause |
|---|---|---|
| Node groups `system` t3.medium / `app` t3.large | both `m7i-flex.large` | The account can only launch free-tier-eligible instance types |
| IRSA (IAM OIDC provider) | EKS Pod Identity | An AWS-managed SCP denies `iam:*Provider*` |
| GitHub OIDC for CI | IAM user `github-ecr-push` with a static key | Same SCP |

### t3.medium / t3.large -> m7i-flex.large

The first apply created the cluster but the node groups stayed in `CREATING` with zero nodes. The Auto Scaling Group failed on every launch attempt with:

```
Could not launch On-Demand Instances. InvalidParameterCombination - The specified
instance type is not eligible for Free Tier. For a list of Free Tier instance types,
run 'describe-instance-types' with the filter 'free-tier-eligible=true'.
```

`aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true` in `eu-north-1` returns only `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large` and `m7i-flex.large`. `t3.small` (2 GiB, 11 pods per node) cannot hold the platform (ArgoCD, Istio, ESO, AWS controllers). `m7i-flex.large` (2 vCPU, 8 GiB, 29 pods per node) matches a t3.large on memory, so both groups use it. Sizing: `system` 2 nodes; `app` min 1 / desired 1 / max 2. The allowed list lives in `locals.tf` and is enforced by variable validation, so an ineligible type fails at `terraform plan`, not 15 minutes into an apply. Requires Terraform >= 1.9.

### IRSA -> Pod Identity (why Pod Identity and not IRSA)

IRSA needs an IAM **OIDC provider** for the cluster. This account is an AWS Free plan project, whose organization applies an AWS-managed service control policy that cannot be changed. Its `DenyIAMRestrictedActions` statement denies `iam:*Provider*`:

```json
{
  "Sid": "DenyIAMRestrictedActions",
  "Effect": "Deny",
  "Action": ["iam:*Alias*", "iam:*Organizations*", "iam:*Provider*", "iam:*LoginProfile*", "..."],
  "Resource": "*"
}
```

Source: [Managed policies for your organization](https://docs.aws.amazon.com/accounts/latest/reference/scps-and-rcps-for-projects.html) (AWS Account Management). The same deny shows up as `iam:ListOpenIDConnectProviders ... with an explicit deny in a service control policy`.

EKS Pod Identity needs no OIDC provider: the `eks-pod-identity-agent` add-on serves credentials and an `aws_eks_pod_identity_association` binds a ServiceAccount to a role (trust principal `pods.eks.amazonaws.com`). Associations are declared for:

| ServiceAccount | Role |
|---|---|
| `external-secrets/external-secrets` | reads only `secret:flights/eks/*` |
| `kube-system/aws-load-balancer-controller` | upstream controller policy |
| `kube-system/cluster-autoscaler` | describe + scale only ASGs tagged for this cluster |
| `kube-system/ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicy` |

Consequence: the ESO `ClusterSecretStore` for EKS has **no** `jwt.serviceAccountRef`; it uses the identity of the ESO controller pod.

## GitHub Actions → ECR: forced exception (static access key)

The keyless option (GitHub OIDC) also needs an IAM OIDC provider, so the same SCP rules it out. CI therefore uses the IAM user `github-ecr-push`:

- Policy: `ecr:GetAuthorizationToken` plus push actions on the three ECR repositories. Nothing else.
- No console access (no login profile).
- **The access key is not created by Terraform**, so the secret never reaches the state. It is created with the CLI and piped straight into GitHub Secrets (never printed, never written to a file):

```bash
aws iam create-access-key --user-name github-ecr-push --output json \
  | jq -r '.AccessKey | "\(.AccessKeyId)\t\(.SecretAccessKey)"' \
  | { IFS=$'\t' read -r id secret
      printf %s "$id"     | gh secret set AWS_ACCESS_KEY_ID     -R DaNaHiju/flights-platform
      printf %s "$secret" | gh secret set AWS_SECRET_ACCESS_KEY -R DaNaHiju/flights-platform; }
```

Rotate by creating a second key, updating the secrets, then `aws iam delete-access-key` for the old one. `terraform destroy` deletes the user and any keys (`force_destroy`).

## Created by hand (not in Terraform)

- **AWS Budget** "My Monthly Cost Budget" ($30/month): created manually in the console before this repo existed, so Terraform does not manage it. An earlier `aws_budgets_budget` ($10) was removed from the code.
- **GitHub Secrets** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `flights-platform` (see above).

## Teardown

See [DESTROY.md](DESTROY.md). Read it before the first apply.
