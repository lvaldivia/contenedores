# Despliegue ECS y EKS: recorrido reproducible

La guía completa está en [README.md](README.md), con arquitectura, VPC, comandos PowerShell/Bash, Secrets Manager, SQL y explicación de cada YAML. Seguir un solo recorrido: el principal usa **EKS Auto Mode**, sin requerir managed node groups adicionales.

Para Linux, la [guía Bash detallada](docs/LINUX.md) muestra instalación/requisitos, cada comando y sus resultados, los equivalentes nativos de los `.ps1`, recuperación de fallos, rotación, actualización y limpieza. Los scripts ECS/EKS Linux ejecutan AWS CLI directamente, sin Python ni PowerShell.

## Orden de ejecución

| Paso | Windows PowerShell | Linux Bash | Comprobar antes de avanzar |
| --- | --- | --- | --- |
| Red/RDS | `cd infra`, sesión, `terraform init`, plan/apply | Mismos comandos Terraform | Outputs y RDS disponible |
| App secret | `./scripts/lab.ps1 secret` | `bash scripts/ecs.sh secret` | ARN del secreto appuser |
| Imagen | `./scripts/lab.ps1 image --version v1` | `bash scripts/ecs.sh image --version v1` | Imagen amd64 en ECR |
| Roles/tareas | `./scripts/lab.ps1 prepare --version v1` | `bash scripts/ecs.sh prepare --version v1` | Roles y revisiones registradas |
| SQL | `./scripts/lab.ps1 bootstrap` | `bash scripts/ecs.sh bootstrap` | STOPPED y exitCode=0 |
| ECS público | `./scripts/lab.ps1 ecs --cidr 'TU_IPV4/32'` | `bash scripts/ecs.sh service --cidr 'TU_IPV4/32'` | Targets healthy y CRUD |
| EKS | `./scripts/lab.ps1 eks --cidr 'TU_IPV4/32'` | `bash scripts/eks.sh create --cidr 'TU_IPV4/32'` | ACTIVE y Access entry |
| Regla MySQL EKS | Plan/apply Terraform en infra | Plan/apply Terraform en infra | Regla 3306 desde SG real |
| Pods | `./scripts/lab.ps1 deploy --version v1` | `bash scripts/eks.sh deploy --version v1` | Rollout y readiness |
| Publicación opcional EKS | Editar/aplicar YAML ALB | `bash scripts/eks.sh publish-alb --cidr 'TU_IPV4/32'` | ADDRESS y targets healthy |

Ejecutar los wrappers desde la raíz; volver a ella después de trabajar en `infra`. Sustituir el CIDR por la IP pública real. Los pasos ECS y EKS son de primera instalación: ante fallo parcial inspeccionar AWS antes de repetirlos. Para detalle de parámetros, permisos, fallos, actualización y eliminación, consultar el README principal.

## Alternativa manual Windows

[backend/README.md](backend/README.md) conserva los pasos de generación manual de tareas ECS con `Prepare-Ecs.ps1`. Ese generador no crea servicios AWS. Para sincronizar solo el secreto EKS existe `Sync-EksSecret.ps1`; exige el contexto esperado y no reinicia pods. Ambos están explicados en el inventario de scripts del README.

## Equivalentes manuales Linux

```bash
source ./infra/Initialize-Session.sh
bash backend/scripts/Prepare-Ecs.sh --image-uri 'URI_REAL_ECR' --app-secret-arn 'ARN_REAL_APPUSER' --version v1
bash eks/Initialize-Eks.sh
bash backend/scripts/Sync-EksSecret.sh --app-secret-arn 'ARN_REAL_APPUSER' --context contenedores-eks
```

El generador solo escribe JSON. La sincronización requiere que ya exista el namespace; no reinicia pods. No es necesario ejecutar estos comandos individuales si ya se usaron `ecs.sh prepare` y `eks.sh deploy`, que los incorporan.

Las políticas de referencia de managed node groups en `policy/03-eks/` son material didáctico de otro modo de despliegue. No sustituir con ellas el trust ni los permisos Auto Mode. Antes de eliminar EKS quitar la referencia MySQL a su SG; antes de destruir Terraform retirar workloads, servicios y balanceadores externos.
