#!/usr/bin/env bash
# Aprovisionamiento ECS nativo Bash: AWS CLI + jq + Terraform + Docker.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
usage() {
  cat <<'EOF'
Uso: bash scripts/ecs.sh ETAPA [--version v1] [--cidr IPV4/32]
  secret     Genera/reutiliza contenedores/api/mysql. No cambia la clave existente.
  image      Crea/reutiliza ECR, construye linux/amd64 y publica la version.
  prepare    Genera JSON, configura roles/logs y registra tareas ECS.
  bootstrap  Ejecuta init-db.mjs y exige exitCode=0.
  service    Primera instalacion de SG, ALB, target group, listener y servicio.
  update     Actualiza el servicio a la ultima task definition runtime registrada.
  status     Consulta servicio y tareas; no cambia AWS.
Primera instalacion: secret -> image -> prepare -> bootstrap -> service.
Antes: crear red/RDS con Terraform. service requiere --cidr IPV4/32.
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
  secret|image|prepare|bootstrap|service|update|status) ;;
  *) usage; lab_die "Etapa desconocida: $step" ;;
esac
lab_require aws jq
if [[ "$step" == service ]]; then lab_cidr "$cidr"; fi
lab_check_account
lab_temp
cd -- "$LAB_ROOT"
case "$step" in
  secret)
    secrets="$(lab_aws secretsmanager list-secrets)"
    if jq -e '.SecretList | any(.[]; .Name == "contenedores/api/mysql")' <<<"$secrets" >/dev/null; then
      printf '%s\n' 'Se reutiliza contenedores/api/mysql; no se roto su clave.'
    else
      # La clave pasa de AWS a jq y al archivo privado, nunca como argumento de proceso.
      lab_aws secretsmanager get-random-password --password-length 32 --exclude-punctuation |
        jq '{Name:"contenedores/api/mysql",
             SecretString:({username:"appuser",password:.RandomPassword}|tojson),
             Tags:[{Key:"Project",Value:"contenedores-lab"}]}' > "$LAB_TMP/secret.json"
      lab_aws secretsmanager create-secret --cli-input-json "file://$LAB_TMP/secret.json" | jq '{ARN,Name}'
    fi ;;
  image)
    lab_require docker
    registry="$LAB_ACCOUNT.dkr.ecr.$LAB_REGION.amazonaws.com"
    repositories="$(lab_aws ecr describe-repositories)"
    if ! jq -e '.repositories | any(.[]; .repositoryName == "contenedores-api")' <<<"$repositories" >/dev/null; then
      lab_aws ecr create-repository --repository-name contenedores-api \
        --image-scanning-configuration scanOnPush=true >/dev/null
    fi
    # get-login-password devuelve texto, no un objeto JSON.
    lab_aws ecr get-login-password | docker login --username AWS --password-stdin "$registry"
    docker build --platform linux/amd64 -t "$registry/contenedores-api:$version" backend
    docker push "$registry/contenedores-api:$version" ;;
  prepare)
    lab_require terraform
    image="$LAB_ACCOUNT.dkr.ecr.$LAB_REGION.amazonaws.com/contenedores-api:$version"
    app_secret="$(lab_aws secretsmanager describe-secret --secret-id contenedores/api/mysql | jq -er '.ARN')"
    bash backend/scripts/Prepare-Ecs.sh --image-uri "$image" --app-secret-arn "$app_secret" --version "$version"
    groups="$(lab_aws logs describe-log-groups --log-group-name-prefix /ecs/contenedores-api)"
    if ! jq -e '.logGroups | any(.[]; .logGroupName == "/ecs/contenedores-api")' <<<"$groups" >/dev/null; then
      lab_aws logs create-log-group --log-group-name /ecs/contenedores-api
    fi
    lab_aws logs put-retention-policy --log-group-name /ecs/contenedores-api --retention-in-days 7
    for kind in bootstrap runtime; do
      role="contenedores-api-$kind-execution"
      lab_role "$role" "$LAB_ROOT/backend/ecs/generated/trust.json" service-role/AmazonECSTaskExecutionRolePolicy
      lab_aws iam put-role-policy --role-name "$role" --policy-name database-secret \
        --policy-document "file://$LAB_ROOT/backend/ecs/generated/$kind-secrets-policy.json"
      lab_aws ecs register-task-definition --cli-input-json "file://$LAB_ROOT/backend/ecs/generated/$kind-task.json" |
        jq -r '.taskDefinition.taskDefinitionArn'
    done
    lab_aws ecs create-cluster --cluster-name contenedores-lab | jq -r '.cluster.clusterArn'
    printf '%s\n' 'Roles y tareas preparados. Esperar propagacion IAM antes del bootstrap.' ;;
  bootstrap)
    [[ -f backend/ecs/generated/network.json ]] || lab_die 'Ejecutar primero prepare.'
    lab_aws ecs run-task --cluster contenedores-lab --launch-type FARGATE --platform-version LATEST \
      --task-definition contenedores-api-bootstrap --network-configuration file://backend/ecs/generated/network.json \
      > "$LAB_TMP/task.json"
    jq -e '(.failures // [] | length == 0) and (.tasks | length == 1)' "$LAB_TMP/task.json" >/dev/null ||
      lab_die 'No se pudo iniciar bootstrap; consultar failures en ECS.'
    task="$(jq -er '.tasks[0].taskArn' "$LAB_TMP/task.json")"
    printf 'Esperando fin de bootstrap: %s\n' "$task"
    lab_aws ecs wait tasks-stopped --cluster contenedores-lab --tasks "$task"
    lab_aws ecs describe-tasks --cluster contenedores-lab --tasks "$task" > "$LAB_TMP/stopped.json"
    jq -e '(.tasks | length == 1) and (.tasks[0].containers | length > 0 and all(.[]; .exitCode == 0))' \
      "$LAB_TMP/stopped.json" >/dev/null ||
      lab_die 'Bootstrap fallo: revisar stoppedReason y CloudWatch /ecs/contenedores-api.'
    printf '%s\n' 'Bootstrap OK: exitCode=0; tabla y usuario SQL listos.' ;;
  service)
    lab_require terraform
    [[ -f backend/ecs/generated/network.json ]] || lab_die 'Ejecutar primero prepare.'
    outputs="$(lab_outputs)"
    vpc="$(jq -er '.vpc_id' <<<"$outputs")"
    app_sg="$(jq -er '.ecs_security_group_id' <<<"$outputs")"
    mapfile -t subnets < <(jq -r '.public_subnet_ids[]' <<<"$outputs")
    sg="$(lab_aws ec2 create-security-group --group-name contenedores-api-alb \
      --description 'HTTP del operador para laboratorio' --vpc-id "$vpc" | jq -er '.GroupId')"
    lab_aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 80 --cidr "$cidr" >/dev/null
    lab_aws ec2 authorize-security-group-ingress --group-id "$app_sg" --protocol tcp --port 3000 --source-group "$sg" >/dev/null
    lab_aws elbv2 create-load-balancer --name contenedores-api-alb --type application --scheme internet-facing \
      --subnets "${subnets[@]}" --security-groups "$sg" > "$LAB_TMP/lb.json"
    lb="$(jq -er '.LoadBalancers[0].LoadBalancerArn' "$LAB_TMP/lb.json")"
    tg="$(lab_aws elbv2 create-target-group --name contenedores-api-tg --protocol HTTP --port 3000 \
      --target-type ip --vpc-id "$vpc" --health-check-path /health/ready | jq -er '.TargetGroups[0].TargetGroupArn')"
    lab_aws elbv2 wait load-balancer-available --load-balancer-arns "$lb"
    lab_aws elbv2 create-listener --load-balancer-arn "$lb" --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=$tg" >/dev/null
    lab_aws ecs create-service --cluster contenedores-lab --service-name contenedores-lab \
      --task-definition contenedores-api-runtime --desired-count 2 --launch-type FARGATE --platform-version LATEST \
      --network-configuration file://backend/ecs/generated/network.json --health-check-grace-period-seconds 60 \
      --load-balancers "targetGroupArn=$tg,containerName=api,containerPort=3000" >/dev/null
    lab_aws ecs wait services-stable --cluster contenedores-lab --services contenedores-lab
    jq -r '"Swagger ECS: http://" + .LoadBalancers[0].DNSName + "/docs/"' "$LAB_TMP/lb.json" ;;
  update)
    lab_aws ecs update-service --cluster contenedores-lab --service contenedores-lab \
      --task-definition contenedores-api-runtime --force-new-deployment >/dev/null
    lab_aws ecs wait services-stable --cluster contenedores-lab --services contenedores-lab
    printf '%s\n' 'Servicio actualizado a la ultima revision runtime. Verificar /api/info.' ;;
  status)
    lab_aws ecs describe-services --cluster contenedores-lab --services contenedores-lab |
      jq '{services:[.services[]|{serviceName,status,desiredCount,runningCount,pendingCount,events:.events[:5]}],failures}'
    lab_aws ecs list-tasks --cluster contenedores-lab ;;
esac
