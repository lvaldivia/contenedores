#!/usr/bin/env bash
# Aprovisionamiento y despliegue EKS Auto Mode nativo Bash; sin PowerShell/Python.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
usage() {
  cat <<'EOF'
Uso: bash scripts/eks.sh ETAPA [--version v1] [--cidr IPV4/32]
  create       Primera instalacion: roles Auto Mode, cluster y Access entry.
  connect      Configura kubeconfig y comprueba nodos del cluster existente.
  deploy       ConfigMap actual, Secret por stdin, Deployment, Service y rollout.
  publish-alb  IngressClassParams, IngressClass e Ingress con subredes/IP actuales.
  status       Consulta cluster, nodos, pods, Service e Ingress.
create y publish-alb requieren --cidr IPV4/32.
Orden: create -> revisar/aplicar Terraform para MySQL -> deploy -> publish-alb opcional.
Antes: red/RDS, secreto appuser, imagen ECR y bootstrap SQL deben estar preparados.
EOF
}
step="${1:---help}"
[[ $# -eq 0 ]] || shift
version=v1 cidr=''
while (($#)); do
  case "$1" in
    --version) [[ $# -ge 2 ]] || lab_die 'Falta version'; version="$2"; shift 2 ;;
    --cidr) [[ $# -ge 2 ]] || lab_die 'Falta CIDR'; cidr="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) lab_die "Opcion desconocida: $1" ;;
  esac
done
case "$step" in
  -h|--help) usage; exit 0 ;;
  create|connect|deploy|publish-alb|status) ;;
  *) usage; lab_die "Etapa desconocida: $step" ;;
esac
lab_require aws jq
if [[ "$step" == create || "$step" == publish-alb ]]; then lab_cidr "$cidr"; fi
lab_check_account
lab_temp
cd -- "$LAB_ROOT"
cluster=contenedores-eks
case "$step" in
  create)
    lab_require terraform
    [[ "$LAB_OPERATOR_ARN" == "arn:aws:iam::$LAB_ACCOUNT:user/"* || "$LAB_OPERATOR_ARN" == "arn:aws:iam::$LAB_ACCOUNT:role/"* ]] ||
      lab_die 'Ejecutar setup y completar operator_arn con el usuario/rol IAM propio antes de crear EKS.'
    outputs="$(lab_outputs)"
    lab_role contenedores-eks-cluster-role "$LAB_ROOT/policy/03-eks/auto-cluster-trust.json" \
      AmazonEKSClusterPolicy AmazonEKSComputePolicy AmazonEKSBlockStoragePolicyV2 \
      AmazonEKSLoadBalancingPolicy AmazonEKSNetworkingPolicy
    lab_role contenedores-eks-node-role "$LAB_ROOT/policy/03-eks/node-trust.json" \
      AmazonEKSWorkerNodeMinimalPolicy AmazonEC2ContainerRegistryPullOnly
    jq -n --arg cluster "$cluster" --arg account "$LAB_ACCOUNT" --arg cidr "$cidr" --argjson infra "$outputs" '{
      name:$cluster,roleArn:("arn:aws:iam::"+$account+":role/contenedores-eks-cluster-role"),
      resourcesVpcConfig:{subnetIds:$infra.app_private_subnet_ids,securityGroupIds:[$infra.eks_security_group_id],
        endpointPrivateAccess:true,endpointPublicAccess:true,publicAccessCidrs:[$cidr]},
      computeConfig:{enabled:true,nodePools:["general-purpose","system"],
        nodeRoleArn:("arn:aws:iam::"+$account+":role/contenedores-eks-node-role")},
      kubernetesNetworkConfig:{elasticLoadBalancing:{enabled:true}},storageConfig:{blockStorage:{enabled:true}},
      accessConfig:{authenticationMode:"API",bootstrapClusterCreatorAdminPermissions:false},
      logging:{clusterLogging:[{types:["api","audit","authenticator"],enabled:true}]}
    }' > "$LAB_TMP/cluster.json"
    printf '%s\n' 'Esperando 15 segundos de propagacion IAM antes de solicitar EKS...'
    sleep 15
    lab_aws eks create-cluster --cli-input-json "file://$LAB_TMP/cluster.json" | jq '.cluster|{name,status,version}'
    printf '%s\n' 'Esperando ACTIVE. Si expira el waiter, consultar estado antes de repetir create.'
    lab_aws eks wait cluster-active --name "$cluster"
    principal="$LAB_OPERATOR_ARN"
    lab_aws eks create-access-entry --cluster-name "$cluster" --principal-arn "$principal" --type STANDARD >/dev/null
    lab_aws eks associate-access-policy --cluster-name "$cluster" --principal-arn "$principal" \
      --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster >/dev/null
    sg="$(lab_aws eks describe-cluster --name "$cluster" | jq -er '.cluster.resourcesVpcConfig.clusterSecurityGroupId')"
    printf 'eks_auto_node_security_group_id = "%s"\n' "$sg" > infra/eks-auto.auto.tfvars
    printf 'EKS activo; SG real %s. Revisar y aplicar Terraform para permitir MySQL.\n' "$sg" ;;
  connect)
    bash eks/Initialize-Eks.sh ;;
  deploy)
    lab_require terraform kubectl
    lab_aws eks update-kubeconfig --name "$cluster" --alias "$cluster"
    outputs="$(lab_outputs)"
    kubectl --context "$cluster" apply -f backend/k8s/namespace.yaml
    jq -n --arg version "$version" --argjson infra "$outputs" '{
      apiVersion:"v1",kind:"ConfigMap",metadata:{name:"api-config",namespace:"contenedores"},
      data:{DB_HOST:$infra.mysql_host,DB_PORT:"3306",DB_NAME:$infra.mysql_database,DB_SSL:"true",
        DB_SSL_CA:"/app/certs/rds-global-bundle.pem",APP_ENV:"eks",APP_VERSION:$version}
    }' | kubectl --context "$cluster" apply -f -
    app_secret="$(lab_aws secretsmanager describe-secret --secret-id contenedores/api/mysql | jq -er '.ARN')"
    bash backend/scripts/Sync-EksSecret.sh --app-secret-arn "$app_secret" --context "$cluster"
    image="$LAB_ACCOUNT.dkr.ecr.$LAB_REGION.amazonaws.com/contenedores-api:$version"
    kubectl set image --local -f backend/k8s/deployment.yaml "api=$image" -o yaml |
      kubectl --context "$cluster" apply -f -
    kubectl --context "$cluster" apply -f backend/k8s/service.yaml
    kubectl --context "$cluster" -n contenedores rollout status deployment/productos-api --timeout=600s
    printf '%s\n' 'Acceso: kubectl --context contenedores-eks -n contenedores port-forward svc/productos-api 8080:80' ;;
  publish-alb)
    lab_require terraform kubectl
    [[ "$(kubectl config current-context)" == "$cluster" ]] || lab_die 'Ejecutar connect antes de publicar.'
    outputs="$(lab_outputs)"
    # Los tres documentos son JSON Kubernetes en una List; no se editan IDs antiguos del YAML fuente.
    jq -n --arg cidr "$cidr" --argjson infra "$outputs" '{apiVersion:"v1",kind:"List",items:[
      {apiVersion:"eks.amazonaws.com/v1",kind:"IngressClassParams",metadata:{name:"alb-contenedores"},
       spec:{scheme:"internet-facing",loadBalancerName:"contenedores-eks-alb",ipAddressType:"ipv4",
             targetType:"ip",inboundCIDRs:[$cidr],subnets:{ids:$infra.public_subnet_ids}}},
      {apiVersion:"networking.k8s.io/v1",kind:"IngressClass",metadata:{name:"alb-contenedores"},
       spec:{controller:"eks.amazonaws.com/alb",parameters:{apiGroup:"eks.amazonaws.com",
             kind:"IngressClassParams",name:"alb-contenedores"}}},
      {apiVersion:"networking.k8s.io/v1",kind:"Ingress",metadata:{name:"productos-api-public",namespace:"contenedores",
       annotations:{"alb.ingress.kubernetes.io/listen-ports":"[{\"HTTP\":80}]",
         "alb.ingress.kubernetes.io/healthcheck-path":"/health/ready",
         "alb.ingress.kubernetes.io/healthcheck-port":"traffic-port",
         "alb.ingress.kubernetes.io/success-codes":"200"}},
       spec:{ingressClassName:"alb-contenedores",rules:[{http:{paths:[{path:"/",pathType:"Prefix",
         backend:{service:{name:"productos-api",port:{number:80}}}}]}}]}}
    ]}' | kubectl --context "$cluster" apply -f -
    kubectl --context "$cluster" -n contenedores get ingress productos-api-public
    printf '%s\n' 'Esperar ADDRESS y targets healthy antes de abrir http://ADDRESS/docs/.' ;;
  status)
    lab_require kubectl
    lab_aws eks describe-cluster --name "$cluster" | jq '.cluster|{name,status,version,computeConfig}'
    kubectl --context "$cluster" get nodes -o wide
    kubectl --context "$cluster" -n contenedores get pods,svc,ingress ;;
esac
