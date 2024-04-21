#!/bin/bash

set -euo pipefail

echo "Please enter Cluster Name:"
read -r CLUSTER_NAME

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

POLICY_NAME="${CLUSTER_NAME}-rosa-efs-csi"
ROLE_NAME="${CLUSTER_NAME}-aws-efs-csi-operator"

# Extract Security Group ID based on the name EFS-SG
EFS_SG_ID=$(aws ec2 describe-security-groups --filter Name=group-name,Values=EFS-SG | jq -r '.SecurityGroups[].GroupId')
# Delete EFS Security Group
aws ec2 delete-security-group --group-id "${EFS_SG_ID}" || true

# Function to print error message and exit
handle_error() {
    echo "An error occurred. Exiting..."
    exit 1
}

# Trap errors and handle them using the handle_error function
trap handle_error ERR

# Grab policy ARN
echo "Retrieving IAM policy ARN..."
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)

if [[ -z "$POLICY_ARN" ]]; then
    echo "Policy $POLICY_NAME not found. Exiting..."
    exit 1
fi

# Detach policy from role
echo "Detaching IAM policy from role..."
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"

# Delete IAM role
echo "Deleting IAM role..."
aws iam delete-role --role-name "$ROLE_NAME"

# Delete IAM policy
echo "Deleting IAM policy..."
aws iam delete-policy --policy-arn "$POLICY_ARN"

# Deleting secret
echo "Deleting secret..."
oc delete secret aws-efs-cloud-credentials -n openshift-cluster-csi-drivers || true

# Delete Storage Class
for i in 'demo-1-storageclass' 'demo-2-storageclass'; do
  oc delete storageclass "$i" || true
done

# Delete Cluster CSI Driver
oc delete clustercsidriver efs.csi.aws.com || true

# Install Subscription & CSVs
oc delete subscription aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers || true

oc delete csv "$(oc get csv | grep aws-efs | awk '{print $1}')" || true

# Delete Projects
for i in 'demo-1' 'demo-2'; do
  oc delete project "$i" || true
done

oc delete -f kyverno-policy.yaml || true

helm uninstall kyverno -n kyverno || true

oc delete namespace kyverno || true

rm -rf efs-*

