#!/usr/bin/env bash
# Funciones compartidas por los scripts Bash; no crea recursos al cargarse.
set -euo pipefail
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB_ACCOUNT="${LAB_AWS_ACCOUNT_ID:-}"
LAB_REGION="${LAB_AWS_REGION:-us-east-1}"
LAB_PROFILE="${LAB_AWS_PROFILE:-${AWS_PROFILE:-default}}"
LAB_OPERATOR_ARN="${LAB_OPERATOR_ARN:-}"
export AWS_PAGER=""

lab_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
lab_require() {
  local tool
  for tool in "$@"; do command -v "$tool" >/dev/null || lab_die "Falta dependencia: $tool"; done
}
lab_config() {
  local config="$LAB_ROOT/lab.config.json"
  if [[ -f "$config" ]]; then
    LAB_ACCOUNT="$(jq -er '.account_id' "$config")"
    LAB_REGION="$(jq -er '.region' "$config")"
    LAB_PROFILE="$(jq -er '.profile' "$config")"
    LAB_OPERATOR_ARN="$(jq -r '.operator_arn // ""' "$config")"
  fi
  [[ "$LAB_ACCOUNT" =~ ^[0-9]{12}$ ]] || lab_die 'Copiar lab.config.example.json a lab.config.json y completar la cuenta propia.'
  [[ "$LAB_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ && -n "$LAB_PROFILE" ]] || lab_die 'Region o perfil invalidos en lab.config.json.'
  export LAB_AWS_ACCOUNT_ID="$LAB_ACCOUNT" LAB_AWS_REGION="$LAB_REGION" LAB_AWS_PROFILE="$LAB_PROFILE"
  export LAB_OPERATOR_ARN AWS_PROFILE="$LAB_PROFILE" AWS_DEFAULT_REGION="$LAB_REGION"
}
lab_aws() {
  command aws --profile "$LAB_PROFILE" --region "$LAB_REGION" --output json --no-cli-pager "$@"
}
lab_check_account() {
  local account
  lab_config
  account="$(lab_aws sts get-caller-identity | jq -er '.Account')"
  [[ "$account" == "$LAB_ACCOUNT" ]] || lab_die "Cuenta $account distinta de $LAB_ACCOUNT; no se modifico AWS."
}
lab_outputs() {
  local outputs account region
  outputs="$(terraform "-chdir=$LAB_ROOT/infra" output -json)"
  account="$(jq -er '.mysql_admin_secret_arn.value | split(":")[4]' <<<"$outputs")"
  region="$(jq -er '.region.value' <<<"$outputs")"
  [[ "$account" == "$LAB_ACCOUNT" && "$region" == "$LAB_REGION" ]] || lab_die 'El estado Terraform pertenece a otra cuenta o region; no reutilizarlo.'
  printf '%s\n' "$outputs" |
    jq -e 'with_entries(.value = .value.value) |
      if .vpc_id and .mysql_host and .mysql_admin_secret_arn and
         (.app_private_subnet_ids | length == 2) then .
      else error("Faltan outputs: crear primero la infraestructura Terraform") end'
}
lab_cidr() {
  jq -en --arg cidr "$1" '$cidr | split("/") |
    length == 2 and .[1] == "32" and
    (.[0] | test("^(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}$") and
      (split(".") | all(.[]; tonumber <= 255)))' >/dev/null ||
    lab_die 'Usar una IPv4 publica valida con /32, por ejemplo 203.0.113.10/32.'
}
lab_temp() {
  # Cada script ejecutable llama esta funcion una vez. Las solicitudes se eliminan al salir.
  umask 077
  LAB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/contenedores.XXXXXXXX")"
  trap 'rm -rf -- "$LAB_TMP"' EXIT
}
lab_role() {
  local name="$1" trust="$2" policy roles
  shift 2
  roles="$(lab_aws iam list-roles)"
  if jq -e --arg name "$name" '.Roles | any(.[]; .RoleName == $name)' <<<"$roles" >/dev/null; then
    lab_aws iam update-assume-role-policy --role-name "$name" --policy-document "file://$trust" >/dev/null
  else
    lab_aws iam create-role --role-name "$name" --assume-role-policy-document "file://$trust" >/dev/null
  fi
  for policy in "$@"; do
    lab_aws iam attach-role-policy --role-name "$name" --policy-arn "arn:aws:iam::aws:policy/$policy"
  done
}
