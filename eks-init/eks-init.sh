#!/bin/bash
CLUSTER_NAME=<my_cluster>
REGION=us-east-1
AWS_ACCOUNT=<123>

ENABLE_PREFIX_MODE=0
INSTALL_HPA=0
SETUP_LIMITRANGE=0
CLUSTER_AUTOSCALER=0
GRAFANA=0

#AWS Load Balancer controller and its required parameters
LB_CONTROLLER=0
IAM_OIDC=0
ECR_REPO=<repo>

#EKS container insights and its required parameters
CONTAINER_INSIGHTS=0
FluentBitHttpPort=2020
FluentBitReadFromHead=Off

usage()
{
  printf "\nUsage: EKS-Init: 
  [ -cluster <cluster name> ]
  [ -region <AWS Region>  ]
  [ -aws_account <AWS account number> ]
  [ -prefix_mode  : Set up VPC CNI prefix mode ] 
  [ -hpa  : Set up Horizontal Pod Autoscaler] 
  [ -limit_range : Set up a Limitrange ]
  [ -autoscaler  : Install cluster autoscaler ]
  [ -grafana  : Set up Grafana ] 
  [ -lb_controller : Install the AWS Load Balancer Controller add-on]
  [ -iam_oidc : Create an IAM OIDC provider for your cluster ]
  [ -ecr_repo <Repo URI> : Amazon container image registry ]
  [ -insights  : Set up EKS container insights]\n"
  exit 2
}

PARSED_ARGUMENTS=$(getopt -a -n EKS-Init -o c:phlbiargcka --long cluster:,prefix_mode,hpa,limit_range,iam_oidc,lb_controller,aws_account:,ecr_repo:,region:,insights,autoscaler,grafana -- "$@")
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
    --prefix_mode)   ENABLE_PREFIX_MODE=1;  shift   ;;
    --hpa)   INSTALL_HPA=1; shift   ;;
    --grafana)   GRAFANA=1; shift   ;;
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
--set prometheus.server.persistentVolume.enabled=true,prometheus.server.persistentVolume.size=1Gi

printf "\nGrafana default password:"
kubectl get secret loki-grafana -o go-template='{{range $k,$v := .data}}{{printf "%s: " $k}}{{if not $v}}{{$v}}{{else}}{{$v | base64decode}}{{end}}{{"\n"}}{{end}}'

printf "+++ Done\n\n"
fi


echo "VAR: $GRAFANA"
