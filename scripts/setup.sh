#!/usr/bin/env bash
# Comprobaciones de la PC y cuenta del alumno; no crea recursos AWS.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf '%s\n' 'Copiar lab.config.example.json a lab.config.json, completarlo y ejecutar bash scripts/setup.sh.'
  printf '%s\n' 'Comprueba herramientas, STS y RDS; genera variables Terraform locales sin crear AWS.'; exit 0
fi
[[ $# -eq 0 ]] || lab_die 'setup no recibe parametros.'
lab_require aws jq terraform docker kubectl
[[ -f "$LAB_ROOT/lab.config.json" ]] || lab_die 'Copiar y completar lab.config.example.json como lab.config.json.'
lab_check_account
[[ "$(aws --version 2>&1)" == aws-cli/2.* ]] || lab_die 'Se requiere AWS CLI v2.'
[[ "$(docker info --format '{{.OSType}}')" == linux ]] || lab_die 'Iniciar Docker con contenedores Linux.'
terraform version
kubectl version --client
identity="$(lab_aws sts get-caller-identity)"
principal="${LAB_OPERATOR_ARN:-$(jq -er '.Arn' <<<"$identity")}"
[[ "$principal" == "arn:aws:iam::$LAB_ACCOUNT:user/"* || "$principal" == "arn:aws:iam::$LAB_ACCOUNT:role/"* ]] ||
  lab_die 'Completar operator_arn con el ARN IAM del usuario/rol, no el ARN STS de una sesion.'
requested="$(jq -r '.mysql_engine_version // ""' "$LAB_ROOT/lab.config.json")"
[[ -z "$requested" || "$requested" =~ ^8\.4\.[0-9]+$ ]] || lab_die 'mysql_engine_version debe estar vacio o ser MySQL 8.4.x.'
if [[ -n "$requested" ]]; then
  versions="$(lab_aws rds describe-db-engine-versions --engine mysql --engine-version "$requested")"
else
  versions="$(lab_aws rds describe-db-engine-versions --engine mysql --engine-version 8.4 --default-only)"
fi
version="$(jq -er '[.DBEngineVersions[] | select((.Status // "available") == "available")][0].EngineVersion // empty' <<<"$versions")" ||
  lab_die 'No se encontro una version MySQL 8.4 disponible; consultar RDS en esta region.'
options="$(lab_aws rds describe-orderable-db-instance-options --engine mysql --engine-version "$version" --db-instance-class db.t4g.micro)"
jq -e '.OrderableDBInstanceOptions | length > 0' <<<"$options" >/dev/null ||
  lab_die 'db.t4g.micro no disponible para la version/region seleccionadas.'
updated="$(jq --arg principal "$principal" --arg version "$version" \
  '.operator_arn=$principal | .mysql_engine_version=$version' "$LAB_ROOT/lab.config.json")"
printf '%s\n' "$updated" > "$LAB_ROOT/lab.config.json"
jq -n --arg account "$LAB_ACCOUNT" --arg profile "$LAB_PROFILE" --arg region "$LAB_REGION" --arg version "$version" \
  '{account_id:$account,profile:$profile,region:$region,mysql_engine_version:$version}' \
  > "$LAB_ROOT/infra/lab.auto.tfvars.json"
printf 'Configuracion validada: cuenta=%s, perfil=%s, region=%s, MySQL=%s\n' "$LAB_ACCOUNT" "$LAB_PROFILE" "$LAB_REGION" "$version"
printf '%s\n' 'Variables locales generadas. No se creo ningun recurso AWS. Continuar con Terraform.'
