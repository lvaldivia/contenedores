#!/usr/bin/env bash
# Alternativa portable que usa Python. Para Bash nativo: scripts/ecs.sh y scripts/eks.sh.
set -euo pipefail
export AWS_PAGER=""
exec python3 "$(cd -- "$(dirname -- "$0")" && pwd)/lab.py" "$@"
