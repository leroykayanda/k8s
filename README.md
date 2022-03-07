**cicd-test**

This is a simple CICD pipeline for EKS. The tutorial is [here](https://dev.to/leroykayanda/a-simple-cicd-pipeline-on-eks-using-codepipeline-55bb).

**eks-init**

This is a bash script that initializes the components below.

 1. [VPC CNI prefix mode](https://aws.amazon.com/blogs/containers/amazon-vpc-cni-increases-pods-per-node-limits/)
 2. Horizontal Pod Autoscaler 
 3. A LimitRange 
 4. Cluster Autoscaler
 5. [Prometheus, Loki and Grafana](https://dev.to/leroykayanda/kubernetes-monitoring-using-grafana-3dhc)
 6. [AWS Load Balancer controller](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html)
 7. EKS container insights
 8. EFS CSI
 9. Create cluster
 10. Delete cluster
 11. Istio

The tutorial is [here](https://dev.to/leroykayanda/bash-script-to-initialize-an-eks-cluster-with-common-components-eg-autoscaler-container-insights-etc-1nom).
