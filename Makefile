# flights-platform-infra: lifecycle helpers.
#   make bootstrap-up   one-time: state bucket (+ writes backend.hcl)
#   make up             init + apply the EKS stack
#   make down           ordered teardown + orphan check  (ALWAYS run when done)
#   make check-orphans  fail if anything of this project is still billing

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

REGION        ?= us-east-1
# Value of the common "Project" tag set by default_tags in the root provider (var.project).
PROJECT_TAG   ?= flights-platform
# Dedicated kubectl context for the EKS cluster. Every kubectl call below passes
# --context explicitly so the homelab (k3s) context is never touched.
KUBE_CONTEXT  ?= flights-eks
LB_WAIT_TRIES ?= 60

.PHONY: help up down check-orphans bootstrap-up bootstrap-down

help:
	@echo "Targets: bootstrap-up | up | down | check-orphans | bootstrap-down"

# ── Root stack ───────────────────────────────────────────────────────────────

up:
	if [ ! -f backend.hcl ]; then
	  echo "backend.hcl missing: run 'make bootstrap-up' or copy backend.hcl.example" >&2
	  exit 1
	fi
	terraform init -backend-config=backend.hcl
	terraform apply

down:
	echo "==> [1/3] Releasing AWS load balancers created from inside the cluster"
	CLUSTER=$$(terraform output -raw cluster_name 2>/dev/null || true)
	VPC=$$(terraform output -raw vpc_id 2>/dev/null || true)
	if [ -n "$$CLUSTER" ]; then
	  aws eks update-kubeconfig --region $(REGION) --name "$$CLUSTER" --alias $(KUBE_CONTEXT)
	  # Stop Argo CD first, otherwise it recreates what we delete.
	  kubectl --context $(KUBE_CONTEXT) -n argocd scale statefulset argocd-application-controller --replicas=0 2>/dev/null || true
	  kubectl --context $(KUBE_CONTEXT) delete ingress --all --all-namespaces --wait=true --timeout=10m
	  kubectl --context $(KUBE_CONTEXT) get svc --all-namespaces \
	    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
	  | while read -r ns name; do
	      kubectl --context $(KUBE_CONTEXT) delete svc -n "$$ns" "$$name" --wait=true --timeout=10m
	    done
	else
	  echo "No cluster in state: skipping in-cluster cleanup"
	fi
	if [ -n "$$VPC" ]; then
	  echo "Waiting for ELBs in $$VPC to disappear..."
	  N=0; C=0
	  for i in $$(seq 1 $(LB_WAIT_TRIES)); do
	    N=$$(aws elbv2 describe-load-balancers --region $(REGION) --query "length(LoadBalancers[?VpcId=='$$VPC'])" --output text)
	    C=$$(aws elb describe-load-balancers --region $(REGION) --query "length(LoadBalancerDescriptions[?VPCId=='$$VPC'])" --output text)
	    [ "$$((N + C))" -eq 0 ] && break
	    sleep 10
	  done
	  if [ "$$((N + C))" -ne 0 ]; then
	    echo "Load balancers still present in $$VPC; aborting before destroy" >&2
	    exit 1
	  fi
	fi
	echo "==> [2/3] terraform destroy"
	terraform destroy
	echo "==> [3/3] Orphan check"
	make --no-print-directory check-orphans

check-orphans:
	FAIL=0
	echo "==> Resources tagged Project=$(PROJECT_TAG) in $(REGION)"
	ARNS=$$(aws resourcegroupstaggingapi get-resources --region $(REGION) \
	  --tag-filters Key=Project,Values=$(PROJECT_TAG) \
	  --query 'ResourceTagMappingList[].ResourceARN' --output text)
	if [ -n "$$ARNS" ]; then
	  echo "$$ARNS" | tr '\t' '\n'
	  echo "(the tagging API can lag a few minutes behind deletions)"
	  FAIL=1
	fi
	EIP=$$(aws ec2 describe-addresses --region $(REGION) \
	  --filters Name=tag:Project,Values=$(PROJECT_TAG) \
	  --query 'Addresses[].AllocationId' --output text)
	if [ -n "$$EIP" ]; then echo "ORPHAN EIP: $$EIP"; FAIL=1; fi
	VPCS=$$(aws ec2 describe-vpcs --region $(REGION) \
	  --filters Name=tag:Project,Values=$(PROJECT_TAG) \
	  --query 'Vpcs[].VpcId' --output text)
	for VPC in $$VPCS; do
	  echo "==> Checking VPC $$VPC"
	  NAT=$$(aws ec2 describe-nat-gateways --region $(REGION) \
	    --filter Name=vpc-id,Values=$$VPC \
	    --query "NatGateways[?State!='deleted'].NatGatewayId" --output text)
	  ENI=$$(aws ec2 describe-network-interfaces --region $(REGION) \
	    --filters Name=vpc-id,Values=$$VPC \
	    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
	  ALB=$$(aws elbv2 describe-load-balancers --region $(REGION) \
	    --query "LoadBalancers[?VpcId=='$$VPC'].LoadBalancerArn" --output text)
	  CLB=$$(aws elb describe-load-balancers --region $(REGION) \
	    --query "LoadBalancerDescriptions[?VPCId=='$$VPC'].LoadBalancerName" --output text)
	  for item in "NAT:$$NAT" "ENI:$$ENI" "ELBv2:$$ALB" "ELB:$$CLB"; do
	    if [ -n "$${item#*:}" ]; then echo "ORPHAN $${item%%:*}: $${item#*:}"; FAIL=1; fi
	  done
	done
	if [ "$$FAIL" -ne 0 ]; then
	  echo "Orphaned resources found: clean them up manually." >&2
	  exit 1
	fi
	echo "No orphaned resources found."

# ── Bootstrap (state bucket) ─────────────────────────────────────────────────

bootstrap-up:
	terraform -chdir=bootstrap init
	terraform -chdir=bootstrap apply
	printf 'bucket = "%s"\nregion = "%s"\n' \
	  "$$(terraform -chdir=bootstrap output -raw state_bucket_name)" \
	  "$$(terraform -chdir=bootstrap output -raw aws_region)" > backend.hcl
	echo "Wrote backend.hcl"

bootstrap-down:
	echo "WARNING: this destroys the S3 bucket holding ALL Terraform state (every version)."
	echo "Run 'make down' first; afterwards the root stack can no longer be managed."
	read -r -p "Type 'destroy-state' to continue: " ANSWER
	[ "$$ANSWER" = "destroy-state" ] || { echo "Aborted."; exit 1; }
	terraform -chdir=bootstrap destroy
