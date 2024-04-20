#! /bin/bash

set -x

echo "Please enter Cluster Name:"

read CLUSTER_NAME

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

AWS_REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')

OIDC_PROVIDER_ENDPOINT=$(rosa describe cluster -c $(oc get clusterversion -o jsonpath='{.items[].spec.clusterID}{"\n"}') -o yaml | awk '/oidc_endpoint_url/ {print $2}' | cut -d '/' -f 3,4)

echo OIDC Provider Endpoint: $OIDC_PROVIDER_ENDPOINT

cat > efs-iam-policy.json <<EOT
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

cat > efs-trust.policy.json <<EOT
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

ROLE_ARN=$(aws iam create-role --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" --assume-role-policy-document file://efs-trust.policy.json --query "Role.Arn" --output text); 

echo Role ARN: $ROLE_ARN

POLICY_ARN=$(aws iam create-policy --policy-name "${CLUSTER_NAME}-rosa-efs-csi" --policy-document file://efs-iam-policy.json --query 'Policy.Arn' --output text); 

echo Policy ARN: $POLICY_ARN

aws iam attach-role-policy --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" --policy-arn $POLICY_ARN

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

set -x