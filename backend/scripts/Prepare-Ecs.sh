#!/usr/bin/env bash
# Equivalente Bash del generador Prepare-Ecs.ps1. Solo escribe JSON locales.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
image='' app_secret='' version=v1
usage() {
  cat <<'EOF'
Uso: bash backend/scripts/Prepare-Ecs.sh --image-uri URI --app-secret-arn ARN [--version v1]
Lee terraform output; completa seis plantillas y actualiza politicas ECS locales.
No crea roles, no registra tareas y no recupera passwords. No requiere PowerShell ni Python.
EOF
}
while (($#)); do
  case "$1" in
    --image-uri) [[ $# -ge 2 ]] || lab_die 'Falta --image-uri'; image="$2"; shift 2 ;;
    --app-secret-arn) [[ $# -ge 2 ]] || lab_die 'Falta --app-secret-arn'; app_secret="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || lab_die 'Falta --version'; version="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) lab_die "Opcion desconocida: $1" ;;
  esac
done
[[ -n "$image" && -n "$app_secret" ]] || { usage; exit 1; }
lab_require terraform jq
lab_config
outputs="$(lab_outputs)"
account="$(jq -er '.mysql_admin_secret_arn | split(":")[4]' <<<"$outputs")"
[[ "$account" == "$LAB_ACCOUNT" ]] || lab_die 'El estado Terraform pertenece a otra cuenta.'
[[ "$app_secret" == "arn:aws:secretsmanager:$LAB_REGION:$LAB_ACCOUNT:secret:contenedores/api/mysql-"* ]] ||
  lab_die 'Usar el ARN completo del secreto de aplicacion de este laboratorio.'
replacements="$(jq -n --arg image "$image" --arg arn "$app_secret" --arg version "$version" \
  --arg account "$account" --arg region "$LAB_REGION" --argjson infra "$outputs" '{
  "__IMAGE_URI__":$image, "__APP_SECRET_ARN__":$arn, "__APP_VERSION__":$version,
  "__ACCOUNT_ID__":$account, "__REGION__":$region, "__DB_HOST__":$infra.mysql_host,
  "__ADMIN_SECRET_ARN__":$infra.mysql_admin_secret_arn,
  "__PRIVATE_SUBNET_1__":$infra.app_private_subnet_ids[0],
  "__PRIVATE_SUBNET_2__":$infra.app_private_subnet_ids[1],
  "__ECS_SECURITY_GROUP_ID__":$infra.ecs_security_group_id}')"
out="$LAB_ROOT/backend/ecs/generated"
mkdir -p -- "$out"
for name in bootstrap-task runtime-task bootstrap-secrets-policy runtime-secrets-policy network trust; do
  jq --argjson replacements "$replacements" '
    walk(if type == "string" then
      reduce ($replacements | to_entries[]) as $r (. ; split($r.key) | join($r.value))
    else . end)' "$out/$name.example.json" > "$out/$name.json"
  jq -e '[.. | strings | select(test("__[A-Z0-9_]+__"))] | length == 0' "$out/$name.json" >/dev/null ||
    lab_die "Quedaron marcadores sin reemplazar en $name.json"
done
cp -- "$out/trust.json" "$LAB_ROOT/policy/ecs-task-trust.json"
for kind in bootstrap runtime; do
  cp -- "$out/$kind-secrets-policy.json" "$LAB_ROOT/policy/ecs-$kind-secrets-policy.json"
  complete="$LAB_ROOT/policy/02-ecs/$kind-execution-policy.json"
  updated="$(jq --slurpfile secrets "$out/$kind-secrets-policy.json" '
    (.Statement[] | select(.Sid == "ReadDatabaseCredentials").Resource) = $secrets[0].Statement[0].Resource' "$complete")"
  printf '%s\n' "$updated" > "$complete"
  # Las politicas completas de referencia tambien deben apuntar a la cuenta actual.
  updated="$(jq --arg account "$LAB_ACCOUNT" --arg region "$LAB_REGION" '
    walk(if type == "string" and startswith("arn:aws:") then
      split(":") | (if .[3] != "" then .[3]=$region else . end) |
      (if .[4] | test("^([0-9]{12}|__ACCOUNT_ID__)$") then .[4]=$account else . end) | join(":")
    else . end)' "$complete")"
  printf '%s\n' "$updated" > "$complete"
done
printf 'JSON generados en %s. No se creo ningun recurso AWS.\n' "$out"
