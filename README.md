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

Rotate by creating a second key, updating the secrets, then `aws iam delete-access-key` for the old one. Delete the key by hand before `terraform destroy` (DESTROY.md, step 3): Terraform does not know it, and `force_destroy` cannot be used because the SCP denies `iam:DeleteLoginProfile`.

## Created by hand (not in Terraform)

- **AWS Budget** "My Monthly Cost Budget" ($30/month): created manually in the console before this repo existed, so Terraform does not manage it. An earlier `aws_budgets_budget` ($10) was removed from the code.
- **GitHub Secrets** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `flights-platform` (see above).

## Evidence

[`docs/evidence/`](docs/evidence/README.md) holds what the running EKS environment looked like before teardown: nodes, pods, ArgoCD Applications, PVCs, Ingress/ALB, `curl` through the ALB, ArgoCD screenshots, and a documented finding (the flight provider answering `502` from the datacenter IP).

## Relaunching EKS

Checklist to bring the environment back after a teardown ([DESTROY.md](DESTROY.md)). Run the steps in order. `bootstrap/` (state bucket and lock table) survives the teardown: do **not** re-apply it, only `terraform init` in the root.

### 1. Prerequisites

```bash
export AWS_PROFILE=aws-lab AWS_REGION=eu-north-1
cd ~/workspace/github.com/danahiju/flights-repos/flights-platform-infra
terraform init
gh auth status          # needs access to DaNaHiju/flights-platform
```

### 2. Update your public IP in `terraform.tfvars`

The variable is `public_access_cidrs` (git-ignored file; template in `terraform.tfvars.example`). If it is stale, `kubectl` times out.

```bash
curl -s https://checkip.amazonaws.com
# edit terraform.tfvars:  public_access_cidrs = ["<your-ip>/32"]
```

### 3. Apply and configure kubectl

```bash
terraform plan -out=eks.tfplan
terraform apply eks.tfplan
$(terraform output -raw kubeconfig_command)
```

This is the only stack to apply. It creates the VPC, EKS, **empty** ECR repositories and the IAM user `github-ecr-push` (without an access key).

### 4. Create a new access key for `github-ecr-push` and load it into GitHub Secrets

The teardown deleted the key and the secrets. The user exists only after step 3. The key goes straight into the secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` of `DaNaHiju/flights-platform`, never printed or written to a file (command in [GitHub Actions → ECR](#github-actions--ecr-forced-exception-static-access-key)):

```bash
aws iam create-access-key --user-name github-ecr-push --output json \
  | jq -r '.AccessKey | "\(.AccessKeyId)\t\(.SecretAccessKey)"' \
  | { IFS=$'\t' read -r id secret
      printf %s "$id"     | gh secret set AWS_ACCESS_KEY_ID     -R DaNaHiju/flights-platform
      printf %s "$secret" | gh secret set AWS_SECRET_ACCESS_KEY -R DaNaHiju/flights-platform; }
```

### 5. Enable ECR push and fill ECR with the tags EKS references

Set `ECR_PUSH` so future CI runs on `main` also push to ECR (it needs the step 4 secrets):

```bash
gh variable set ECR_PUSH --body true -R DaNaHiju/flights-platform
```

The ECR repositories are empty after a relaunch, and the pods stay in `ImagePullBackOff` until the exact tags the EKS values point at exist there. **Do not re-run CI or push an empty commit to fill them:**

- An empty commit changes no files, so every `dorny/paths-filter` filter is false and the `build` job is skipped.
- Re-running a run repeats that commit's filter result, so it builds only the services that commit touched. The last `main` commit happens to touch `.github/workflows/ci.yml` (which is in all three filters), but that is luck, not a rule.
- It tags `sha-<7 of that commit>`, while the api chart pins its own tag in `values-eks.yaml`. Re-running an older run would make `update-manifests` bump the staging tags back to that older sha.

Instead, copy the images that already exist in GHCR, with the exact tags the EKS values use (api: `charts/flights-api/values-eks.yaml`; worker and web: `values.yaml` of their chart, bumped by CI). `imagetools create` copies the manifest registry to registry, so the digest is preserved. Run it from this repo, with the sibling repo `flights-platform-manifests` checked out next to it:

```bash
M=../flights-platform-manifests
REGISTRY=$(terraform output -raw ecr_registry)
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
# only if the GHCR packages are private:  echo "$GHCR_PAT" | docker login ghcr.io -u DaNaHiju --password-stdin   # PAT with read:packages

for svc in api worker web; do
  case "$svc" in
    api) file=$M/charts/flights-api/values-eks.yaml ;;
    *)   file=$M/charts/flights-$svc/values.yaml ;;
  esac
  tag=$(yq '.image.tag' "$file")
  docker buildx imagetools create \
    --tag "$REGISTRY/flights-$svc:$tag" "ghcr.io/danahiju/flights-$svc:$tag"
done
```

Check the three images exist in ECR with the tag EKS expects, e.g. `terraform output ecr_repository_urls` plus a look in the ECR console, before moving on. If a tag is missing from GHCR, it has to be built: that needs a workflow change (see the open question in the PR).

### 6. Bootstrap ArgoCD (manual, in the manifests repo)

ArgoCD cannot install itself, so three manual commands are needed: `helm install argocd`, `kubectl apply` of the AppProject `platform-infra`, and `kubectl apply` of the root Application `platform-root-eks`. The commands live in a single place, see [Bootstrap in `flights-platform-manifests`](https://github.com/DaNaHiju/flights-platform-manifests/blob/main/argocd/eks/README.md#bootstrap-one-time-per-cluster). Follow them in that order, with kubectl already pointing at the new cluster (step 3).

The AppProject `platform-infra` is bootstrap and ArgoCD does **not** manage it: any later change to `argocd/eks/projects/platform-infra.yaml` in the manifests repo is applied by hand with `kubectl apply -f` (merging it does not update the live object).

### 7. Minimal verification

```bash
kubectl get nodes                   # all Ready (2 system + 1 app; the app group may grow to 2)
kubectl get applications -n argocd  # all Synced / Healthy
kubectl get ingress -n istio-system istio-ingressgateway   # ADDRESS = the ALB hostname
```

### 8. Reminder: destroy when done

Everything bills by the hour (EKS, NAT gateway, nodes, ALB, EBS). When the evidence is captured, follow [DESTROY.md](DESTROY.md) **in order**: Kubernetes-side resources first, then `terraform destroy`. Do not run `terraform destroy` straight away: the ALB and the EBS volumes are not in the Terraform state and would be orphaned.

## Teardown

See [DESTROY.md](DESTROY.md). Read it before the first apply. To bring the environment back, see [Relaunching EKS](#relaunching-eks).
