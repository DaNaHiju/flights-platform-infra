# DESTROY: full teardown of the EKS environment

Everything here costs money by the hour (EKS control plane, NAT gateway, EC2 nodes, ALB, EBS). Tear down as soon as the evidence is captured.

**Why the order matters.** Terraform only knows what it created. The ALB, its target groups and security groups are created at runtime by the AWS Load Balancer Controller, and the EBS volumes by the EBS CSI driver from PVCs. Terraform cannot see them. If the cluster is destroyed first, they are orphaned: the ALB keeps billing, and its ENIs and security groups block deletion of the subnets and VPC (`DependencyViolation`). So: delete Kubernetes-side resources first, verify, then `terraform destroy`.

`bootstrap/` (state bucket and lock table) is **not** part of this teardown. Do not destroy it while the root state still exists.

```bash
export AWS_PROFILE=aws-lab AWS_REGION=eu-north-1
CLUSTER=flights-dev-eks
cd ~/workspace/github.com/danahiju/flights-repos/flights-platform-infra
$(terraform output -raw kubeconfig_command)
VPC_ID=$(terraform output -raw vpc_id)
```

## 1. Stop GitOps from recreating things

```bash
kubectl -n argocd patch application platform-root-eks --type merge \
  -p '{"spec":{"syncPolicy":null}}'
```

## 2. Delete the load balancer and the volumes from inside Kubernetes

```bash
# ALB: deleting the Ingress makes the controller delete the ALB, listeners, target groups and its SG.
kubectl delete ingress --all -A --wait=true
# Any Service of type LoadBalancer (none expected on EKS) would leave an NLB/CLB behind:
kubectl get svc -A | grep LoadBalancer || echo "no LoadBalancer services"

# EBS: Postgres/Redis PVCs. Deleting them deletes the volumes (reclaimPolicy Delete).
kubectl delete application -n argocd --all --wait=true --timeout=10m   # workloads first
kubectl delete pvc --all -A --wait=true --timeout=10m
```

If an Application hangs on its finalizer, inspect it (`kubectl describe application -n argocd <name>`) before removing the finalizer by hand.

## 3. Verify nothing is left in AWS that Terraform cannot see (BEFORE destroy)

All four must print nothing (or "none"):

```bash
echo "ALBs/NLBs:";  aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].[LoadBalancerName,Type]" --output text
echo "Classic ELBs:"; aws elb describe-load-balancers \
  --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text
echo "EBS volumes (k8s PVCs):"; aws ec2 describe-volumes \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER,ebs.csi.aws.com/cluster" \
  --query 'Volumes[].[VolumeId,State]' --output text
echo "Controller-made SGs:"; aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
  --query 'SecurityGroups[].GroupId' --output text
```

## 4. Terraform destroy

```bash
terraform plan -destroy -out=destroy.tfplan
# Expect only resources from the table in README.md. Nothing from bootstrap/.
terraform apply destroy.tfplan
```

This also deletes the `github-ecr-push` user together with its access key, all ECR repositories (`force_delete`) and the Secrets Manager secret (`recovery_window_in_days = 0`, so no 30-day wait).

## 5. Verify nothing is left (AFTER destroy)

Every command must come back empty:

```bash
echo "EKS:";  aws eks list-clusters --query 'clusters' --output text
echo "NAT gateways:"; aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=pending,available,deleting" \
  --query 'NatGateways[].[NatGatewayId,State]' --output text
echo "Elastic IPs:"; aws ec2 describe-addresses --query 'Addresses[].[AllocationId,PublicIp]' --output text
echo "Load balancers:"; aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
echo "EBS volumes:"; aws ec2 describe-volumes --query 'Volumes[].[VolumeId,State]' --output text
echo "ENIs outside the default VPC:"; aws ec2 describe-network-interfaces \
  --query "NetworkInterfaces[?VpcId!='$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)'].[NetworkInterfaceId,VpcId,Description]" --output text
echo "VPCs (only the default may remain):"; aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,IsDefault]' --output text
echo "ECR:"; aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
echo "Secrets:"; aws secretsmanager list-secrets --query 'SecretList[].Name' --output text
echo "IAM user:"; aws iam get-user --user-name github-ecr-push 2>&1 | head -1   # expect NoSuchEntity
```

If a VPC or subnet refuses to delete with `DependencyViolation`, something was orphaned: list `describe-network-interfaces --filters Name=vpc-id,Values=$VPC_ID`, read each ENI's `Description` (an `ELB app/...` ENI means an ALB survived; delete it with `aws elbv2 delete-load-balancer`), then re-run `terraform apply destroy.tfplan`.

## 6. Clean up outside Terraform

```bash
gh secret delete AWS_ACCESS_KEY_ID     -R DaNaHiju/flights-platform
gh secret delete AWS_SECRET_ACCESS_KEY -R DaNaHiju/flights-platform
rm -f destroy.tfplan
```

The $30 budget stays (created by hand). The S3 state bucket and lock table from `bootstrap/` stay too; they cost cents. To remove them see [bootstrap/README.md](bootstrap/README.md#teardown).
