#!/usr/bin/env bash
# Equivalente Bash de Sync-EksSecret.ps1. Credenciales solo en la tuberia stdin.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
app_secret='' context=contenedores-eks
while (($#)); do
  case "$1" in
    --app-secret-arn) [[ $# -ge 2 ]] || lab_die 'Falta ARN'; app_secret="$2"; shift 2 ;;
    --context) [[ $# -ge 2 ]] || lab_die 'Falta contexto'; context="$2"; shift 2 ;;
    -h|--help)
      printf '%s\n' 'Uso: bash backend/scripts/Sync-EksSecret.sh --app-secret-arn ARN [--context contenedores-eks]'
      printf '%s\n' 'Requiere namespace existente. No guarda passwords ni reinicia pods.'; exit 0 ;;
    *) lab_die "Opcion desconocida: $1" ;;
  esac
done
[[ -n "$app_secret" ]] || lab_die 'Se requiere --app-secret-arn.'
lab_require aws jq kubectl
current="$(kubectl config current-context)"
[[ "$current" == "$context" ]] || lab_die "Seleccionar contexto $context; no se leyo ningun secreto."
[[ "$app_secret" == "arn:aws:secretsmanager:$LAB_REGION:$LAB_ACCOUNT:secret:contenedores/api/mysql-"* ]] ||
  lab_die 'Se esperaba el ARN del secreto de aplicacion.'
lab_check_account
lab_aws secretsmanager get-secret-value --secret-id "$app_secret" |
  jq -ce '.SecretString | fromjson |
    if .username == "appuser" and (.password | type == "string" and length > 0) then
      {apiVersion:"v1",kind:"Secret",type:"Opaque",
       metadata:{name:"mysql-app",namespace:"contenedores"},
       data:{DB_USER:(.username|@base64),DB_PASSWORD:(.password|@base64)}}
    else error("Se esperaba username=appuser y password no vacio") end' |
  kubectl --context "$context" apply --server-side --field-manager=lab-secret-sync -f -
printf '%s\n' 'mysql-app sincronizado por stdin. Reiniciar pods si cambio la clave.'
