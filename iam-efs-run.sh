#!/bin/bash

set -euo pipefail

# Function to prompt user for input with a message
prompt_user() {
    read -rp "$1: " "$2"
}

# Function to extract AWS account ID
get_account_id() {
    aws sts get-caller-identity --query Account --output text
}

# Function to extract AWS region
get_aws_region() {
    aws configure get region
}

# Function to extract OIDC Provider endpoint
get_oidc_provider_endpoint() {
    rosa describe cluster -c "$(oc get clusterversion -o jsonpath='{.items[].spec.clusterID}{"\n"}')" -o yaml | awk '/oidc_endpoint_url/ {print $2}' | cut -d '/' -f 3,4
}

# Function to create IAM role
create_iam_role() {
    aws iam create-role --role-name "${1}-aws-efs-csi-operator" --assume-role-policy-document file://efs-trust.policy.json --query "Role.Arn" --output text
}

# Function to create IAM policy
create_iam_policy() {
    aws iam create-policy --policy-name "${1}-rosa-efs-csi" --policy-document file://efs-iam-policy.json --query 'Policy.Arn' --output text
}

# Function to attach IAM policy to role
attach_policy_to_role() {
    aws iam attach-role-policy --role-name "${1}-aws-efs-csi-operator" --policy-arn "$2"
}

# Main script starts here

# Prompt user for Cluster Name
prompt_user "Please enter Cluster Name" CLUSTER_NAME

# Prompt user for ROSA VPC ID
prompt_user "Please enter ROSA VPC ID" ROSA_VPC_ID

# Extract Account ID and Region
ACCOUNT_ID=$(get_account_id)
AWS_REGION=$(get_aws_region)

# Extract OIDC Provider endpoint
OIDC_PROVIDER_ENDPOINT=$(get_oidc_provider_endpoint)
echo "OIDC Provider Endpoint: $OIDC_PROVIDER_ENDPOINT"

# Generate IAM Policy
cat >efs-iam-policy.json <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "ec2:DescribeAvailabilityZones",
        "elasticfilesystem:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:CreateAccessPoint"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/efs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "elasticfilesystem:DeleteAccessPoint",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/efs.csi.aws.com/cluster": "true"
        }
      }
    }
  ]
}
EOT

# Generate Policy trust file
cat >efs-trust.policy.json <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_ENDPOINT}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER_ENDPOINT}:sub": [
            "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-operator",
            "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-controller-sa"
          ]
        }
      }
    }
  ]
}
EOT

# Create IAM Role and Policy
ROLE_ARN=$(create_iam_role "$CLUSTER_NAME")
echo "Role ARN: $ROLE_ARN"

POLICY_ARN=$(create_iam_policy "$CLUSTER_NAME")
echo "Policy ARN: $POLICY_ARN"

# Attach IAM Role to Policy
attach_policy_to_role "$CLUSTER_NAME" "$POLICY_ARN"

# Rest of the script...

## Extract Region
AWS_REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]') ## Unnecessary

## Create EFS and grab the ID
FILE_SYSTEM_ID1=$(aws efs create-file-system --region ${AWS_REGION} --encrypted --performance-mode generalPurpose --tags Key=Name,Value="EFS_Storage_Class_1"  --query 'FileSystemId' --output text)  

FILE_SYSTEM_ID2=$(aws efs create-file-system --region ${AWS_REGION} --encrypted --performance-mode generalPurpose --tags Key=Name,Value="EFS_Storage_Class_2" --query 'FileSystemId' --output text)

## Create Security Group & Rules in ROSA VPC

ROSA_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids ${ROSA_VPC_ID} --query 'Vpcs[0].CidrBlock' --output text)

EFS_SG_ID=$(aws ec2 create-security-group --group-name EFS-SG --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=EFS_Storage_Class_2_SG}]' --description "Security group for EFS NFS access" --vpc-id ${ROSA_VPC_ID} --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id ${EFS_SG_ID} --protocol tcp --port 2049 --cidr ${ROSA_VPC_CIDR} 

## Set Mount Target
# for i in ${FILE_SYSTEM_ID1} ${FILE_SYSTEM_ID2}; do
#   aws efs create-mount-target --file-system-id $i --subnet-id  subnet-id --security-group ${EFS_SG_ID} --region ${AWS_REGION}
# done

sleep 90

## Create Secret 
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
 name: aws-efs-cloud-credentials
 namespace: openshift-cluster-csi-drivers
stringData:
  credentials: |-
    [default]
    sts_regional_endpoints = regional
    role_arn = ${ROLE_ARN} 
    web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF


## Install Operator Group
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cluster-csi-drivers-w4rjh
  namespace: openshift-cluster-csi-drivers
spec:
  upgradeStrategy: Default
EOF

## Install Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-efs-csi-driver-operator
  namespace: openshift-cluster-csi-drivers
spec:
  channel: stable
  config:
    env:
    - name: ROLEARN
      value: ${ROLE_ARN} 
  installPlanApproval: Automatic
  name: aws-efs-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

sleep 90

## Create CSI Driver
cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: efs.csi.aws.com
spec:
  logLevel: Normal
  managementState: Managed
  operatorLogLevel: Trace
EOF

## Create Storage Class for Namespace 
cat <<EOF | oc apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: demo-1-storageclass
provisioner: efs.csi.aws.com
allowVolumeExpansion: true
parameters:
  provisioningMode: efs-ap 
  fileSystemId: ${FILE_SYSTEM_ID1}
  directoryPerms: "700" 
  gidRangeStart: "1000" 
  gidRangeEnd: "2000" 
  basePath: "/dynamic_provisioning" 
EOF

## Create Storage Class for Namespace 
cat <<EOF | oc apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: demo-2-storageclass
provisioner: efs.csi.aws.com
allowVolumeExpansion: true
parameters:
  provisioningMode: efs-ap 
  fileSystemId: ${FILE_SYSTEM_ID2} 
  directoryPerms: "700" 
  gidRangeStart: "2001" 
  gidRangeEnd: "3000" 
  basePath: "/dynamic_provisioning" 
EOF

for i in 'demo-1' 'demo-2'; do 
  oc new-project $i
done

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-1-pvc
  namespace: demo-1
spec:
  storageClassName: demo-1-storageclass
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
EOF

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-2-vpc
  namespace: demo-2
spec:
  storageClassName: demo-2-storageclass
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF

## Test 

echo Creating OPA gatekeper instance
cat <<EOF | oc apply -f -
apiVersion: operator.gatekeeper.sh/v1alpha1
kind: Gatekeeper
metadata:
  name: gatekeeper
spec:
  audit:
    logLevel: INFO
    replicas: 1
  mutatingWebhook: Enabled
  validatingWebhook: Enabled
  webhook:
    admissionEventsInvolvedNamespace: Enabled
    emitAdmissionEvents: Enabled
    logLevel: DEBUG
    logMutations: Enabled
    mutationAnnotations: Enabled
    replicas: 1
EOF

sleep 60

echo Creating OPA Gatekeeper policy
oc apply -f opa-gatekeeper-policy.yaml

echo Completed


