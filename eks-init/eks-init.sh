#!/bin/bash
CLUSTER_NAME=rr-istio
REGION=us-east-1
AWS_ACCOUNT=123

CREATE_CLUSTER=0
DELETE_CLUSTER=0
ENABLE_PREFIX_MODE=0
INSTALL_HPA=0
SETUP_LIMITRANGE=0
CLUSTER_AUTOSCALER=0
GRAFANA=0
INSTALL_ISTIO=0

#AWS Load Balancer controller and its required parameters
LB_CONTROLLER=0
IAM_OIDC=0
ECR_REPO=602401143452.dkr.ecr.us-east-1.amazonaws.com

#EKS container insights and its required parameters
CONTAINER_INSIGHTS=0
FluentBitHttpPort=2020
FluentBitReadFromHead=Off

#EFS and its required parameters
EFS=0
AZ1_MOUNT_POINT_SUBNET_ID=subnet-032038f5838abd515
AZ2_MOUNT_POINT_SUBNET_ID=subnet-0eb2594d2ed1cabdb

usage()
{
  printf "\nUsage: EKS-Init: 
  [ -cluster <cluster_name> ]
  [ -create : Create a clsuter using eksctl ]
  [ -nuke : <cluster_name> Delete cluster ]
  [ -prefix_mode  : Set up VPC CNI prefix mode ] 
  [ -grafana  : Set up Grafana ] 
  [ -region <AWS Region>  ]
  [ -autoscaler  : Install cluster autoscaler ]
  [ -insights  : Set up EKS container insights]
  [ -limit_range : Set up a Limitrange ]
  [ -iam_oidc : Create an IAM OIDC provider for your cluster ]
  [ -ecr_repo <Repo URI> : Amazon container image registry ]
  [ -aws_account <AWS account number> ]
  [ -lb_controller : Install the AWS Load Balancer Controller add-on]
  [ -efs : Set up EFS CSI for cluster storage ]
  [ -istio : Set up Istio ]
  [ -az1_mp <AZ1 Subnet ID for EFS Mount Point> ]
  [ -az2_mp <AZ2 Subnet ID for EFS Mount Point> ]\n"
  exit 2
}

PARSED_ARGUMENTS=$(getopt -a -n EKS-Init -o c:phlbiargckafy:z:udi --long cluster:,prefix_mode,hpa,limit_range,iam_oidc,lb_controller,aws_account:,ecr_repo:,region:,insights,autoscaler,grafana,efs,az1_mp:,az2_mp:,create,nuke,istio -- "$@")
VALID_ARGUMENTS=$?
if [ "$VALID_ARGUMENTS" != "0" ]; then
  usage
fi

eval set -- "$PARSED_ARGUMENTS"
#echo "PARSED_ARGUMENTS is $PARSED_ARGUMENTS"

while :
do
  case "$1" in
    --cluster) CLUSTER_NAME="$2" ; shift 2 ;;
    --aws_account) AWS_ACCOUNT="$2" ; shift 2 ;;
    --region) REGION="$2" ; shift 2 ;;
    --ecr_repo) ECR_REPO="$2" ; shift 2 ;;
    --az1_mp) AZ1_MOUNT_POINT_SUBNET_ID="$2" ; shift 2 ;;
    --az2_mp) AZ2_MOUNT_POINT_SUBNET_ID="$2" ; shift 2 ;;
    --prefix_mode)   ENABLE_PREFIX_MODE=1;  shift   ;;
    --hpa)   INSTALL_HPA=1; shift   ;;
    --create)   CREATE_CLUSTER=1; shift   ;;
    --nuke)   DELETE_CLUSTER=1; shift   ;;
    --istio)   INSTALL_ISTIO=1; shift   ;;
    --grafana)   GRAFANA=1; shift   ;;
    --efs)   EFS=1; shift   ;;
    --autoscaler)   CLUSTER_AUTOSCALER=1; shift   ;;
    --insights)   CONTAINER_INSIGHTS=1; shift   ;;
    --limit_range) SETUP_LIMITRANGE=1; shift  ;;
    --lb_controller) LB_CONTROLLER=1; shift  ;;
    --iam_oidc) IAM_OIDC=1; shift  ;;
    --) shift; break ;;
    *) printf "Unexpected argument: $1 "
       usage ;;
  esac
done

sed -i 's@CLUSTER_NAME@'"$CLUSTER_NAME"'@' eks-apps/limit-range.yaml
sed -i 's@CLUSTER_NAME@'"$CLUSTER_NAME"'@' eks-apps/hpa.yaml
sed -i 's@CLUSTER_NAME@'"$CLUSTER_NAME"'@' eks-apps/eksctl_create-cluster.yaml

if [ $DELETE_CLUSTER -gt 0 ]
then
echo "+++ Deleting cluster"

eksctl delete cluster -f eks-apps/eksctl_create-cluster.yaml

printf "+++ Done\n\n"
fi



if [ $CREATE_CLUSTER -gt 0 ]
then
echo "+++ Creating cluster"

eksctl create cluster -f eks-apps/eksctl_create-cluster.yaml

printf "+++ Done\n\n"
fi


if [ $EFS -gt 0 ]
then
echo "+++ Setting up EFS"

curl -o iam-policy-example.json https://raw.githubusercontent.com/kubernetes-sigs/aws-efs-csi-driver/v1.3.2/docs/iam-policy-example.json
aws iam create-policy \
    --policy-name AmazonEKS_EFS_CSI_Driver_Policy \
    --policy-document file://iam-policy-example.json

eksctl create iamserviceaccount \
    --name efs-csi-controller-sa \
    --namespace kube-system \
    --cluster $CLUSTER_NAME \
    --attach-policy-arn arn:aws:iam::$AWS_ACCOUNT:policy/AmazonEKS_EFS_CSI_Driver_Policy \
    --approve \
    --override-existing-serviceaccounts \
    --region $REGION

#install CSI driver
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update

helm upgrade -i aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set image.repository=$ECR_REPO/eks/aws-efs-csi-driver \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=efs-csi-controller-sa

vpc_id=$(aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)

cidr_range=$(aws ec2 describe-vpcs \
    --vpc-ids $vpc_id \
    --query "Vpcs[].CidrBlock" \
    --output text)

security_group_id=$(aws ec2 create-security-group \
    --group-name EKS_EFS_SG \
    --description "My EFS security group" \
    --vpc-id $vpc_id \
    --output text)

#Allow NFS traffic from VPC CIDR
aws ec2 authorize-security-group-ingress \
    --group-id $security_group_id \
    --protocol tcp \
    --port 2049 \
    --cidr $cidr_range

#create the EFS
file_system_id=$(aws efs create-file-system \
    --region $REGION \
    --performance-mode generalPurpose \
    --query 'FileSystemId' \
    --output text)

#wait for EFS to be created before creating mount points
sleep 10

#create 2 mount points in different AZs for high availability
aws efs create-mount-target \
    --file-system-id $file_system_id \
    --subnet-id $AZ1_MOUNT_POINT_SUBNET_ID \
    --security-groups $security_group_id

aws efs create-mount-target \
    --file-system-id $file_system_id \
    --subnet-id $AZ2_MOUNT_POINT_SUBNET_ID \
    --security-groups $security_group_id
    
#file_system_id=fs-0ec1915f566f463b0
sed -i 's@<EFS>@'"$file_system_id"'@' eks-apps/efs-storage-class.yaml

kubectl apply -f eks-apps/efs-storage-class.yaml
#unset the gp2 storag class as the default storage class
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class-

printf "+++ Done\n\n"
fi

if [ $GRAFANA -gt 0 ]
then
echo "+++ Installing Grafana"

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki-stack --set grafana.enabled=true,prometheus.enabled=true, \
--set prometheus.server.retention=2d,loki.config.table_manager.retention_deletes_enabled=true,loki.config.table_manager.retention_period=48h, \
--set grafana.persistence.enabled=true,grafana.persistence.size=1Gi, \
--set loki.persistence.enabled=true,loki.persistence.size=1Gi, \
--set prometheus.alertmanager.persistentVolume.enabled=true,prometheus.alertmanager.persistentVolume.size=1Gi, \
--set prometheus.server.persistentVolume.enabled=true,prometheus.server.persistentVolume.size=1Gi --set grafana.initChownData.enabled=false

printf "\nGrafana default password:"
kubectl get secret loki-grafana -o go-template='{{range $k,$v := .data}}{{printf "%s: " $k}}{{if not $v}}{{$v}}{{else}}{{$v | base64decode}}{{end}}{{"\n"}}{{end}}'

printf "+++ Done\n\n"
fi


if [ $ENABLE_PREFIX_MODE -gt 0 ]
then
echo "+++ Enabling VPC CNI prefix assignment mode"
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
kubectl describe daemonset -n kube-system aws-node | grep ENABLE_PREFIX_DELEGATION
printf "+++ Done\n\n"
fi

if [ $INSTALL_HPA -gt 0 ]
then
echo "+++ Installing Metrics Server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl apply -f eks-apps/hpa.yaml
printf "+++ Done\n\n"
fi

if [ $SETUP_LIMITRANGE -gt 0 ]
then
echo "+++ Setting up a Limitrange"
kubectl apply -f eks-apps/limit-range.yaml
printf "+++ Done\n\n"
fi

if [ $IAM_OIDC -gt 0 ]
then
echo "+++ Setting up an IAM OIDC provider for your cluster $CLUSTER_NAME"
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve --region $REGION
printf "+++ Done\n\n"
fi

if [ $LB_CONTROLLER -gt 0 ]
then
echo "+++ Installing the AWS Load Balancer Controller add-on"

curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.0/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json --region $REGION

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve --region $REGION

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set image.repository="$ECR_REPO/amazon/aws-load-balancer-controller" \
  --set serviceAccount.name=aws-load-balancer-controller 

kubectl get deployment -n kube-system aws-load-balancer-controller

printf "+++ Done\n\n"
fi

if [ $CONTAINER_INSIGHTS -gt 0 ]
then

echo "+++ Installing EKS container insights"

[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${CLUSTER_NAME}'/;s/{{region_name}}/'${REGION}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 

printf "+++ Done\n\n"
fi



if [ $CLUSTER_AUTOSCALER -gt 0 ]
then

echo "+++ Installing Cluster Autoscaler"

aws iam create-policy \
    --policy-name AmazonEKSClusterAutoscalerPolicy \
    --policy-document file://eks-apps/cluster-autoscaler-policy.json --region $REGION

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT:policy/AmazonEKSClusterAutoscalerPolicy \
  --override-existing-serviceaccounts \
  --approve --region $REGION

sed -i 's@<YOUR CLUSTER NAME>@'"$CLUSTER_NAME"'@' eks-apps/cluster-autoscaler-autodiscover.yaml

kubectl apply -f eks-apps/cluster-autoscaler-autodiscover.yaml

kubectl patch deployment cluster-autoscaler \
  -n kube-system \
  -p '{"spec":{"template":{"metadata":{"annotations":{"cluster-autoscaler.kubernetes.io/safe-to-evict": "false"}}}}}'

# we need to retrieve the latest docker image available for our EKS version
K8S_VERSION=$(kubectl version --short | grep 'Server Version:' | sed 's/[^0-9.]*\([0-9.]*\).*/\1/' | cut -d. -f1,2)
AUTOSCALER_VERSION=$(curl -s "https://api.github.com/repos/kubernetes/autoscaler/releases" | grep '"tag_name":' | sed -s 's/.*-\([0-9][0-9\.]*\).*/\1/' | grep -m1 ${K8S_VERSION})

kubectl -n kube-system \
    set image deployment cluster-autoscaler \
    cluster-autoscaler=us.gcr.io/k8s-artifacts-prod/autoscaling/cluster-autoscaler:v${AUTOSCALER_VERSION}


printf "+++ Done\n\n"
fi


if [ $INSTALL_ISTIO -gt 0 ]
then
echo "+++ Setting up Istio"

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

#install istioctl

curl -L https://git.io/getLatestIstio | sh -
cd istio-*
current_directory=$(pwd)
echo "export PATH=$PATH:$current_directory/bin" >> ~/.bashrc
echo "alias i=istioctl" >> ~/.bashrc
source ~/.bashrc


# Create a namespace istio-system for Istio components:
kubectl create namespace istio-system 
 
# Install the Istio base chart which contains cluster-wide resources used by the Istio control plane:

helm install -n istio-system istio-base manifests/charts/base  
 
# Install the Istio discovery chart which deploys the istiod service:

helm install --namespace istio-system istiod \
    manifests/charts/istio-control/istio-discovery \
    --set global.hub="docker.io/istio" --set global.tag="1.13.1" 
    
 
# Install the Istio ingress gateway chart which contains the ingress gateway components:

helm install --namespace istio-system istio-ingress \
    manifests/charts/gateways/istio-ingress  \
    --set global.hub="docker.io/istio" --set global.tag="1.13.1" \
    --set gateways.istio-ingressgateway.serviceAnnotations."service\.beta\.kubernetes\.io/aws-load-balancer-ssl-cert"="arn:aws:acm:us-east-1:552212359451:certificate/d2176176-8b72-485f-bebe-48169fcca582" \
	--set gateways.istio-ingressgateway.serviceAnnotations."service\.beta\.kubernetes\.io/aws-load-balancer-backend-protocol"="http" \
    --set gateways.istio-ingressgateway.serviceAnnotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"="true" \
    --set gateways.istio-ingressgateway.serviceAnnotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb"

#label namespace for proxy envoy injection

#kubectl label ns default istio-injection=enabled

#install kiali

kubectl apply -f samples/addons/kiali.yaml
kubectl apply -f samples/addons/prometheus.yaml
kubectl apply -f samples/addons/grafana.yaml
kubectl apply -f samples/addons/jaeger.yaml

printf "+++ Done\n\n"
fi


echo "VAR: $AZ1_MOUNT_POINT_SUBNET_ID"
