#!/usr/bin/env bash
# Usar: source ./infra/Initialize-Session.sh
# Este script se carga con source; no modifica opciones de la terminal padre.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'Usar source ./infra/Initialize-Session.sh para exportar la sesion en la terminal actual.' >&2
  exit 1
fi
lab_config_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lab.config.json"
if [[ ! -f "$lab_config_path" ]]; then
  printf '%s\n' 'Copiar lab.config.example.json a lab.config.json y ejecutar setup.' >&2
  return 1
fi
if ! command -v jq >/dev/null; then
  printf '%s\n' 'Instalar jq para leer lab.config.json.' >&2
  return 1
fi
AWS_PROFILE="$(jq -er '.profile' "$lab_config_path")" || return 1
AWS_DEFAULT_REGION="$(jq -er '.region' "$lab_config_path")" || return 1
LAB_AWS_ACCOUNT_ID="$(jq -er '.account_id' "$lab_config_path")" || return 1
LAB_OPERATOR_ARN="$(jq -r '.operator_arn // ""' "$lab_config_path")"
export LAB_AWS_ACCOUNT_ID LAB_OPERATOR_ARN
export AWS_PROFILE AWS_DEFAULT_REGION
export AWS_PAGER=""
printf 'Sesion AWS: %s / %s. TLS permanece habilitado.\n' "$AWS_PROFILE" "$AWS_DEFAULT_REGION"
unset lab_config_path
# Linux usa su almacen CA. Si hay CA corporativa, exportar AWS_CA_BUNDLE por separado.
