#!/usr/bin/env bash
# Configura la conexion al cluster existente; no crea EKS ni modifica CA del sistema.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/common.sh"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf '%s\n' 'Uso: bash eks/Initialize-Eks.sh (cluster existente, AWS CLI y kubectl en PATH)'; exit 0
fi
[[ $# -eq 0 ]] || lab_die 'Este script no recibe parametros.'
lab_require aws jq kubectl
lab_check_account
lab_aws eks update-kubeconfig --name contenedores-eks --alias contenedores-eks
[[ "$(kubectl config current-context)" == contenedores-eks ]] || lab_die 'Contexto inesperado.'
kubectl --context contenedores-eks version --client
kubectl --context contenedores-eks --request-timeout=30s get nodes -o wide
