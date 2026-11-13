# Backend de productos: Docker, MySQL y ECS

Primero completar la [configuración por alumno](../docs/ALUMNOS.md). Guía de despliegue ECS y EKS: [paso a paso](../GUIA-ECS-EKS.md).

API Node.js 24 / Fastify. CRUD persistente en MySQL, consultas parametrizadas,
validacion de entradas, Swagger UI y contrato OpenAPI exportable.

## Ejecutar localmente

```powershell
cd backend
Copy-Item .env.example .env  # Solo la primera vez; cambiar las claves locales si se desea.
docker compose up -d --build
docker compose ps
```

Swagger: http://localhost:3000/docs/

OpenAPI: http://localhost:3000/openapi.json

Compose arranca MySQL, ejecuta una tarea de inicializacion y luego el backend.
La tabla no se recrea ni se vacia al reiniciar. El volumen conserva los datos.
MySQL no publica ningun puerto del host; la API solo escucha en localhost del host.
La imagen se ejecuta como usuario `node` y maneja SIGTERM para terminar conexiones.

| Metodo | Ruta | Resultado |
| --- | --- | --- |
| GET | `/api/products?limit=20&offset=0` | Lista paginada |
| GET | `/api/products/{id}` | Producto o 404 |
| POST | `/api/products` | Crea producto; 201 y Location |
| PUT | `/api/products/{id}` | Reemplaza datos; 200 o 404 |
| DELETE | `/api/products/{id}` | Elimina; 204 o 404 |
| GET | `/api/info` | Version, entorno y hostname |
| GET | `/health/live` | Proceso activo, independiente de MySQL |
| GET | `/health/ready` | 200 con MySQL disponible; 503 si falla |

Ejemplo para Swagger (Try it out):

```json
{"name":"Teclado","description":"Producto de demostracion","price":89.90,"stock":10}
```

`name` y `price` son obligatorios. `description` y `stock` toman `""` y `0`
si se omiten, incluido PUT. El precio permite dos decimales y valores no negativos.
POST no es idempotente: reintentar una creacion puede crear otro producto.
La API de laboratorio no tiene autenticacion: usar datos ficticios y restringir
la entrada del balanceador a la IP de la demostracion.

## Verificacion y contrato

Con Compose levantado:

```powershell
npm ci
npm test
npm run docs
npm audit
```

Los tests HTTP prueban el contenedor y MySQL reales; borran sus productos al terminar.
La prueba de fallo de readiness usa un repositorio que simula la caida de la BD.
Los schemas en `src/app.mjs` son la fuente de validacion y documentacion.
`npm run docs` regenera `docs/openapi.json`; no editar ese archivo a mano.
El contrato puede importarse en Postman sin cuenta ni publicacion.

Para detener sin perder datos: `docker compose down`.
`docker compose down -v` elimina los datos locales; usarlo solo al reiniciar el laboratorio.

## Preparar despliegue en ECR / ECS

### Linux: scripts Bash nativos

El procedimiento Linux completo está en [docs/LINUX.md](../docs/LINUX.md).
Estos scripts ejecutan AWS CLI directamente; no necesitan PowerShell ni Python.
Requieren Bash >= 4, jq >= 1.6, AWS CLI v2, Terraform y Docker. Para EKS también
kubectl. Desde la raíz, después de crear la red y RDS con Terraform:

```bash
source ./infra/Initialize-Session.sh
bash scripts/ecs.sh secret
bash scripts/ecs.sh image --version v1
bash scripts/ecs.sh prepare --version v1
bash scripts/ecs.sh bootstrap
bash scripts/ecs.sh service --cidr 'TU_IPV4_PUBLICA/32'
bash scripts/ecs.sh status
```

`prepare` genera JSON y configura roles/logs/tareas. Para **solo generar** los
JSON, el equivalente de `Prepare-Ecs.ps1` es `Prepare-Ecs.sh`:

```bash
IMAGE_URI="${LAB_AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/contenedores-api:v1"
APP_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id contenedores/api/mysql \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" --query ARN --output text)"
bash backend/scripts/Prepare-Ecs.sh \
  --image-uri "$IMAGE_URI" --app-secret-arn "$APP_SECRET_ARN" --version v1
```

No repetir la generación manual si se ejecutará `ecs.sh prepare`; la etapa ya
la incluye. Para publicar v2 ejecutar `image --version v2`, `prepare --version v2`
y `bash scripts/ecs.sh update`. `service` es para primera instalación; `update`
actualiza el servicio existente y espera estabilidad.

Para sincronizar solo el secreto EKS, después de crear el clúster y namespace:

```bash
bash eks/Initialize-Eks.sh
kubectl --context contenedores-eks apply -f backend/k8s/namespace.yaml
bash backend/scripts/Sync-EksSecret.sh \
  --app-secret-arn "$APP_SECRET_ARN" --context contenedores-eks
```

Este script valida contexto/cuenta y transmite credenciales por stdin. No las
escribe en disco ni reinicia pods. El paso `bash scripts/eks.sh deploy --version v1`
incluye ConfigMap actual, sincronización, Deployment, Service y espera de rollout.

### Windows: procedimiento manual PowerShell

Estos pasos son para la siguiente etapa y no se ejecutan automaticamente.
La VPC y RDS existentes se leen del estado de `../infra`.

### 1. Imagen en ECR

```powershell
. ../infra/Initialize-Session.ps1
$account = $env:LAB_AWS_ACCOUNT_ID
$registry = "$account.dkr.ecr.us-east-1.amazonaws.com"
$image = "${registry}/contenedores-api:v1"
aws ecr create-repository --repository-name contenedores-api --image-scanning-configuration scanOnPush=true
aws ecr get-login-password | docker login --username AWS --password-stdin $registry
docker build --platform linux/amd64 -t $image .
docker push $image
```

Omitir `create-repository` si el repositorio ya existe. Usar etiquetas nuevas (`v2`, etc.) para actualizaciones.

### 2. Secreto de aplicacion y definiciones de tarea

En Secrets Manager, crear un secreto de tipo clave/valor en us-east-1 con
`username=appuser` y `password` generado aleatoriamente. Usar la clave de cifrado
predeterminada `aws/secretsmanager`. No usar la clave de administrador como clave de aplicacion.
Copiar su ARN, no su valor, y generar los archivos:

```powershell
./scripts/Prepare-Ecs.ps1 -ImageUri $image -AppSecretArn 'ARN_DEL_SECRETO_DE_APLICACION'
```

El script solo genera JSON locales en `ecs/generated`:

La carpeta también incluye `*.example.json` versionados con marcadores para
cuenta, región, imagen, RDS, secretos y red. Ver [tabla de reemplazos y pasos
manuales](ecs/generated/LEEME.md). Los JSON generados sin `.example` se ignoran
porque corresponden a una ejecución concreta; los ejemplos sí van en el commit.

- Runtime: credenciales de aplicacion, TLS a RDS y health check.
- Bootstrap: comando de inicializacion, secreto administrador RDS y secreto de aplicacion.
- Politicas IAM: runtime solo lee el secreto de aplicacion; bootstrap lee ambos.
- Red: subredes privadas y security group ECS ya creados, sin IP publica.

Crear roles de ejecucion y registrar tareas:

```powershell
aws logs create-log-group --log-group-name /ecs/contenedores-api
aws logs put-retention-policy --log-group-name /ecs/contenedores-api --retention-in-days 7
foreach ($kind in @('runtime','bootstrap')) {
  $role = "contenedores-api-$kind-execution"
  aws iam create-role --role-name $role --assume-role-policy-document file://ecs/generated/trust.json
  aws iam attach-role-policy --role-name $role --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam put-role-policy --role-name $role --policy-name database-secret --policy-document "file://ecs/generated/$kind-secrets-policy.json"
  aws ecs register-task-definition --cli-input-json "file://ecs/generated/$kind-task.json"
}
aws ecs create-cluster --cluster-name contenedores-lab
```

Si el log group, roles o cluster ya existen, reutilizarlos. Esperar la propagacion
IAM antes de ejecutar la primera tarea. Las tareas usan Fargate Linux 1.4.0 o posterior
para inyectar claves JSON de los secretos.

### 3. Inicializacion unica de RDS

```powershell
aws ecs run-task --cluster contenedores-lab --launch-type FARGATE --platform-version LATEST --task-definition contenedores-api-bootstrap --network-configuration file://ecs/generated/network.json
```

Esperar que esa tarea termine en `STOPPED`, comprobar `exitCode=0` y revisar
CloudWatch `/ecs/contenedores-api`. El comando crea `products`, crea/actualiza
`appuser` y concede SELECT, INSERT, UPDATE y DELETE en `contenedores`.
La operacion es repetible y no borra productos. No iniciar tareas de bootstrap en paralelo.
El runtime no recibe las credenciales de administrador ni ejecuta DDL.
Si se cambia la clave de aplicacion en Secrets Manager, repetir bootstrap y forzar
un despliegue nuevo del servicio: ECS inyecta los secretos al iniciar cada tarea.

### 4. Servicio Fargate y balanceador

En ECS crear un servicio con `contenedores-api-runtime`, dos tareas,
las subredes y SG de `ecs/generated/network.json`, e IP publica deshabilitada.

Crear un ALB en las dos subredes publicas de `../infra`:

- Listener HTTP 80 para este laboratorio (HTTPS requiere dominio/certificado).
- Target group **tipo IP**, puerto 3000; health check `/health/ready`.
- Security group del ALB: entrada 80 solo desde tu IP publica `/32` y salida al backend.
- En el SG ECS existente, agregar entrada TCP 3000 **desde el SG del ALB**.
- Asociar el target group al contenedor `api`, puerto 3000, en el servicio ECS.
- Configurar health check grace period de 60 segundos.

Abrir `http://DNS_DEL_ALB/docs/` y crear/listar productos desde Swagger.
Los contenedores siguen usando RDS por red privada y TLS con el CA global de RDS.
El CA publico se incluye en `certs/`; renovarlo desde el truststore de AWS cuando corresponda.

Para la clase: consultar `/api/info`, detener una tarea y observar su reemplazo;
publicar `v2`, generar/registrar la nueva task definition y actualizar el servicio.

## Limite de la verificacion

El backend se prueba localmente con Docker y MySQL. Los archivos ECS quedan preparados;
no implican que ECR, los roles, el balanceador ni el servicio ya esten desplegados.
La conexion con RDS se comprobara al ejecutar bootstrap y el servicio dentro de la VPC.

Referencias: https://github.com/fastify/fastify-swagger y
https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
