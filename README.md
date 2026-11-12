# Laboratorio de contenedores: Docker, ECS y EKS

API de productos con Node.js 24, Fastify y MySQL. Este proyecto permite ejecutar la aplicación con Docker Compose y desplegar la misma imagen en AWS ECS Fargate o Amazon EKS, compartiendo una base de datos RDS privada.

## Qué contiene

| Carpeta | Contenido |
| --- | --- |
| `backend/` | API REST, Dockerfile, Compose, pruebas y contrato OpenAPI |
| `backend/scripts/` | Generación de tareas ECS y sincronización de secretos EKS |
| `backend/k8s/` | Namespace, ConfigMap, Deployment y Service Kubernetes |
| `infra/` | Terraform para VPC, subredes, NAT Gateway, security groups y RDS |
| `policy/` | Políticas IAM y relaciones de confianza por escenario |

Terraform **solo crea la red y RDS**. ECR, ECS, EKS, sus roles y balanceadores se crean en pasos separados. Los archivos existentes no demuestran que esos servicios estén desplegados.

```text
Local:  localhost:3000 → API Docker → MySQL Docker + volumen
ECS:    cliente → ALB → tareas Fargate privadas → RDS privado
EKS:    kubectl port-forward → Service → pods privados → mismo RDS
```

## 1. Ejecutar en tu equipo

Requisitos: Git, Docker Engine o Docker Desktop con contenedores Linux y Docker Compose v2. Node.js 24 o posterior solo es necesario para ejecutar pruebas y regenerar OpenAPI fuera del contenedor.

Desde la raíz del repositorio, en PowerShell:

```powershell
cd backend
Copy-Item .env.example .env # Solo si todavía no existe .env
# Editar .env para definir las contraseñas locales.
docker compose up -d --build
docker compose ps
Invoke-RestMethod http://localhost:3000/health/ready
```

Compose inicia MySQL, espera que esté disponible, ejecuta `migrate` para crear la tabla y arranca la API. Es normal que `migrate` termine con código 0. La API se publica en `127.0.0.1:3000`; MySQL no expone un puerto del equipo.

- Swagger interactivo: <http://localhost:3000/docs/>
- OpenAPI: <http://localhost:3000/openapi.json>
- Estado del proceso: `/health/live`.
- Disponibilidad con conexión a MySQL: `/health/ready` (200 o 503).
- Versión, entorno y hostname: `/api/info`.

Crear y consultar un producto:

```powershell
$product = @{ name='Teclado'; description='Demo'; price=89.90; stock=10 } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri http://localhost:3000/api/products -ContentType 'application/json' -Body $product
Invoke-RestMethod 'http://localhost:3000/api/products?limit=20&offset=0'
```

El CRUD también ofrece `GET`, `PUT` y `DELETE` en `/api/products/{id}`. `name` y `price` son obligatorios; Swagger detalla los campos y respuestas.

```powershell
docker compose logs --tail 100 api migrate mysql
npm ci
npm test
npm run docs
docker compose down
```

Las pruebas HTTP requieren la API y MySQL locales activos y crean/eliminan productos de prueba. `down` conserva el volumen; **`docker compose down -v` elimina los datos locales**. Cambiar la contraseña en `.env` no cambia la de un MySQL ya inicializado: actualizar el usuario SQL o recrear el volumen solo si sus datos son desechables.

## 2. Preparar AWS y la base de datos

Requisitos adicionales: AWS CLI autenticada, Terraform >= 1.10 y permisos para los recursos del laboratorio. Para EKS se necesita también `kubectl` compatible con la versión del clúster.

Los archivos están preparados para la cuenta `299147769461`, región `us-east-1` y perfil `luisvaldivia`. **Para otra cuenta**, adaptar `allowed_account_ids` en `infra/main.tf`, perfil/región en los scripts, ARNs de `policy/` e imagen y endpoint de `backend/k8s/`. El proveedor bloquea cuentas distintas de la configurada.

Desde la raíz:

```powershell
cd infra
. ./Initialize-Session.ps1
aws sts get-caller-identity
terraform init
terraform fmt -check
terraform validate
terraform plan -out=lab.tfplan
# Revisar el plan antes de crear recursos con costo.
terraform apply lab.tfplan
terraform output
cd ..
```

En Windows, el script configura certificados y perfil para la sesión. El switch opcional `-LocalPluginTlsWorkaround` está documentado en [infra/README.md](infra/README.md); usarlo únicamente si aparece el problema de TLS local allí descrito.

Se crean dos zonas con subredes públicas, privadas de aplicación y aisladas de base de datos. RDS acepta MySQL 3306 desde los security groups ECS/EKS. Los contenedores salen por NAT; la laptop no accede directamente a RDS. Terraform mantiene estado local: conservarlo de forma segura para administrar y destruir los recursos.

## 3. Publicar imagen y desplegar en ECS

Seguir [el procedimiento ECS del backend](backend/README.md#preparar-despliegue-en-ecr--ecs), en este orden:

1. Publicar la imagen `linux/amd64` en ECR como `contenedores-api:v1`.
2. Crear en Secrets Manager `contenedores/api/mysql`, con claves `username=appuser` y `password`. Usar el cifrado predeterminado `aws/secretsmanager` para las políticas incluidas.
3. Ejecutar desde `backend/` el generador con la imagen y el ARN real del secreto:

   ```powershell
   $image = '299147769461.dkr.ecr.us-east-1.amazonaws.com/contenedores-api:v1'
   $appSecretArn = 'ARN_REAL_DEL_SECRETO_DE_APLICACION'
   ./scripts/Prepare-Ecs.ps1 -ImageUri $image -AppSecretArn $appSecretArn -Version v1
   ```

4. Crear CloudWatch log group, roles de ejecución, definiciones de tareas y clúster ECS según la guía del backend. El generador solo escribe archivos; no crea recursos AWS. Regenerar los JSON antes de usarlos: las plantillas iniciales pueden contener marcadores.
5. Ejecutar la tarea `contenedores-api-bootstrap` en las subredes privadas y esperar `STOPPED` con `exitCode=0`. Crea la tabla y el usuario de aplicación con permisos de CRUD; no borra productos. El secreto administrador solo se entrega a esta tarea.
6. Crear el servicio Fargate con dos tareas `contenedores-api-runtime`, sin IP pública. Crear un ALB en las subredes públicas y un target group **IP**, puerto 3000, health check `/health/ready`. Permitir 3000 en el SG de tareas desde el SG del ALB; restringir HTTP del ALB a tu IP para la demostración.
7. Comprobar tareas y targets saludables; abrir `http://DNS_DEL_ALB/docs/` y crear/listar productos.

Las [políticas por escenario](policy/ESCENARIOS.md) explican qué documentos corresponden a cada rol. La API de laboratorio no tiene autenticación; usar datos ficticios y acceso restringido.

## 4. Desplegar en EKS

El procedimiento completo está en [GUIA-ECS-EKS.md](GUIA-ECS-EKS.md). EKS reutiliza la imagen ECR y la tabla/usuario inicializados mediante bootstrap. El Service incluido es `ClusterIP`: el acceso de demostración se hace por `port-forward`; no crea un balanceador público.

## 5. Actualizaciones y diagnóstico

- Publicar etiquetas nuevas (`v2`, `v3`), generar y registrar una nueva revisión de tarea y actualizar el servicio ECS. En EKS usar `kubectl set image` y comprobar `rollout status`, como muestra la guía.
- Si cambia la contraseña de Secrets Manager: repetir bootstrap para actualizar MySQL, sincronizar el Secret EKS y reiniciar pods; forzar también un nuevo despliegue ECS. Los procesos existentes no reciben el cambio automáticamente.
- Readiness 503 o targets no saludables: revisar logs, endpoint RDS, reglas TCP 3306, secreto y resultado de bootstrap.
- `ImagePullBackOff`: comprobar URI/tag de ECR, permisos del rol de nodos y salida de red.
- Pods pendientes: comprobar capacidad de nodos y arquitectura `linux/amd64`.
- El README describe los procedimientos a partir del código; subir a GitHub no ejecuta un despliegue AWS ni valida una instalación remota.

## Costos y limpieza

NAT Gateway, RDS, EKS, Fargate, balanceadores, IPv4, logs y secretos pueden generar cargos. Eliminar primero servicios/tareas ECS, workloads y clúster/nodos EKS, balanceadores y recursos asociados creados fuera de Terraform. Eliminar también imágenes ECR, logs y secreto de aplicación cuando ya no se necesiten.

Después, desde `infra/`, revisar `terraform plan -destroy` y ejecutar `terraform destroy` si corresponde. **Esta configuración elimina RDS sin snapshot final y borra sus backups automatizados**: exportar los datos que se quieran conservar antes de destruir.

## Archivos locales

No versionar `.env`, credenciales, estados/planes Terraform, `.terraform/`, certificados locales del equipo, `node_modules/` ni archivos temporales. `.env.example` solo contiene valores locales de ejemplo. Los certificados CA públicos de RDS en `backend/certs/` sí forman parte de la imagen.
