#! /bin/bash

set -x

echo "Please enter Cluster Name:"
read CLUSTER_NAME

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

export POLICY_NAME="${CLUSTER_NAME}-rosa-efs-csi"

export ROLE_NAME="${CLUSTER_NAME}-aws-efs-csi-operator"

# Function to print error message and exit
function handle_error {
    echo "An error occurred. Exiting..."
    exit 1
}

# Trap errors and handle them using the handle_error function
trap handle_error ERR

# Grab policy ARN
echo "Retrieving IAM policy ARN..."

POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)

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

# Deleting secret to test files upload
echo "Deleting  secret"

oc delete secret aws-efs-cloud-credentials -n openshift-cluster-csi-drivers

rm -rf efs-*

set -x