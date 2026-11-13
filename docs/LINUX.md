# Despliegue completo en Linux con Bash: ECS y EKS

Antes de este recorrido, seguir [la guía del alumno](ALUMNOS.md): usar cuenta AWS propia, completar `lab.config.json` y ejecutar `bash scripts/setup.sh`. Los ejemplos `laboratorio` y `us-east-1` se sustituyen mediante esa configuración; no se necesitan datos del docente.

Este recorrido usa scripts **Bash nativos** que ejecutan AWS CLI, jq, Terraform,
Docker y kubectl directamente. No requiere PowerShell ni Python para desplegar.
`scripts/lab.sh` sigue disponible como alternativa que llama al provisionador
Python, pero no es el recorrido explicado aquí.

Cuenta `CUENTA_DEL_ALUMNO`, región `us-east-1`, perfil `laboratorio`. Los comandos
crean recursos con costo. Ejecutarlos desde la raíz del repositorio, donde están
`infra`, `backend`, `scripts` y `policy`. La arquitectura, los CIDR de la VPC y la
explicación de los YAML están en el [README principal](../README.md).

## 1. Mapa de scripts Windows / Linux

| Función | Windows | Linux nativo |
| --- | --- | --- |
| Preparar variables de sesión | `. ./infra/Initialize-Session.ps1` | `source ./infra/Initialize-Session.sh` |
| Crear secreto appuser | `./scripts/lab.ps1 secret` | `bash scripts/ecs.sh secret` |
| Publicar imagen ECR | `./scripts/lab.ps1 image --version v1` | `bash scripts/ecs.sh image --version v1` |
| Solo generar tareas/políticas | `backend/scripts/Prepare-Ecs.ps1` | `backend/scripts/Prepare-Ecs.sh` |
| Roles, logs y registro ECS | `./scripts/lab.ps1 prepare --version v1` | `bash scripts/ecs.sh prepare --version v1` |
| Inicialización SQL | `./scripts/lab.ps1 bootstrap` | `bash scripts/ecs.sh bootstrap` |
| ALB y servicio Fargate | `./scripts/lab.ps1 ecs --cidr IPV4/32` | `bash scripts/ecs.sh service --cidr IPV4/32` |
| Actualizar servicio ECS | AWS CLI `update-service` | `bash scripts/ecs.sh update` |
| Crear Auto Mode | `./scripts/lab.ps1 eks --cidr IPV4/32` | `bash scripts/eks.sh create --cidr IPV4/32` |
| Conectar kubectl | `eks/Initialize-Eks.ps1` | `bash eks/Initialize-Eks.sh` o `bash scripts/eks.sh connect` |
| Solo sincronizar secreto | `backend/scripts/Sync-EksSecret.ps1` | `backend/scripts/Sync-EksSecret.sh` |
| Configuración y pods | `./scripts/lab.ps1 deploy --version v1` | `bash scripts/eks.sh deploy --version v1` |
| ALB EKS opcional | Editar/aplicar YAML | `bash scripts/eks.sh publish-alb --cidr IPV4/32` |

Todos los scripts `.sh` de esta tabla contienen operaciones Bash reales; no
ejecutan archivos `.ps1`. La biblioteca `scripts/lib/common.sh` centraliza el
perfil, la comprobación de cuenta, lectura de outputs y creación de roles.

## 2. Dependencias Linux

Se requiere Bash >= 4, jq >= 1.6, AWS CLI v2, Terraform >= 1.10, Docker con
contenedores Linux y kubectl compatible con la versión EKS. Python solo se usa
en las pruebas automatizadas, no en los scripts de despliegue de este documento.

En Ubuntu/Debian se pueden instalar las utilidades básicas con:

```bash
sudo apt-get update
sudo apt-get install -y bash jq git curl unzip ca-certificates
```

Instalar AWS CLI, Terraform, Docker y kubectl siguiendo sus distribuciones
oficiales; evitar mezclar instalaciones de CLI v1/v2. Verificar que Docker esté
iniciado y que el usuario tenga acceso al daemon:

```bash
bash --version
jq --version
aws --version
terraform version
docker version
kubectl version --client

for tool in bash jq aws terraform docker kubectl; do
  command -v "$tool" || exit 1
done
```

En Linux ARM, Docker debe poder construir para `linux/amd64`, porque las tareas
y Deployment de este laboratorio usan x86_64. Configurar emulación/buildx o
construir desde un host amd64 antes de publicar esa imagen.

Los scripts se ejecutan con `bash ruta/script.sh`; no es obligatorio `chmod +x`.
`.gitattributes` conserva LF para evitar errores de CRLF al clonar desde Windows.
Las rutas se calculan a partir de `BASH_SOURCE`, por lo que los scripts encuentran
el proyecto incluso cuando se invocan desde otra carpeta. Los comandos manuales
de esta guía sí asumen que la terminal está en la raíz.

## 3. Configurar el perfil y comprobar la cuenta

Si el perfil no existe, configurarlo mediante el mecanismo de autenticación de
tu cuenta. Para credenciales convencionales:

```bash
aws configure --profile laboratorio
source ./infra/Initialize-Session.sh
aws sts get-caller-identity --profile "$AWS_PROFILE"
```

Esperar el Account ID propio, igual a `account_id` de la configuración. El script de sesión exporta `AWS_PROFILE`,
`AWS_DEFAULT_REGION` y deshabilita el paginador. Se usa `source` porque un proceso
hijo no puede cambiar las variables de la terminal padre.

Los ejecutables ECS/EKS, además, pasan el perfil y región explícitamente y
consultan STS antes de crear recursos. No modifican los permisos del usuario. Antes de los siguientes pasos, copiar y completar `lab.config.example.json` como `lab.config.json` y ejecutar `bash scripts/setup.sh`; este paso genera las variables Terraform y comprueba RDS sin crear recursos.
Se necesitan permisos de aprovisionamiento sobre los servicios usados e
`iam:PassRole` sobre los roles del laboratorio. Las políticas limitadas de push
ECR y sincronización de secretos no sustituyen esos permisos administrativos.

Linux usa su almacén de CA; no importa certificados del almacén Windows. Si la
red corporativa requiere una cadena propia, configurar `AWS_CA_BUNDLE` con un
archivo PEM confiable. No desactivar TLS. Nunca ejecutar el flujo de secretos
con `bash -x` o `set -x`.

## 4. Probar el backend local antes de crear AWS

```bash
cd backend
test -f .env || cp .env.example .env
# Editar .env para definir las claves locales.
docker compose up -d --build
docker compose ps
curl --fail http://localhost:3000/health/ready
cd ..
```

Abrir `http://localhost:3000/docs/`. Compose crea MySQL local, espera su salud,
inicializa la tabla y arranca la API. `migrate` debe terminar con código 0. El
volumen local no tiene relación con RDS. Para parar conservando datos:
`docker compose -f backend/compose.yaml down`.

## 5. Crear VPC, subredes, rutas, NAT y RDS

Antes de recrear, comprobar que un `infra/eks-auto.auto.tfvars` de una ejecución
anterior no contenga el SG borrado. Su valor inicial debe ser:

```hcl
eks_auto_node_security_group_id = ""
```

Si ese archivo no existe, la variable ya tiene valor vacío por defecto. No borrar
el estado Terraform de una infraestructura existente para comenzar de nuevo.

```bash
terraform -chdir=infra init
terraform -chdir=infra fmt -check
terraform -chdir=infra validate
terraform -chdir=infra plan -out=lab.tfplan
# Revisar nombres, cuenta, region y operaciones antes de aplicar.
terraform -chdir=infra apply lab.tfplan
terraform -chdir=infra output
```

Resultado: una VPC, dos subredes públicas, dos privadas de aplicación, dos
aisladas de BD, rutas/IGW, NAT y Elastic IP, SG y RDS MySQL privado. RDS crea la
base `contenedores`, administrador `labadmin` y administra su password en
Secrets Manager mediante `manage_master_user_password=true`.

Consultar sin revelar passwords:

```bash
terraform -chdir=infra output -raw vpc_id
terraform -chdir=infra output -json app_private_subnet_ids
terraform -chdir=infra output -json public_subnet_ids
terraform -chdir=infra output -raw mysql_host
terraform -chdir=infra output -raw mysql_admin_secret_arn
```

La base todavía no tiene `products` ni el usuario appuser. RDS acepta conexiones
privadas desde los SG autorizados; la laptop no accede directamente al puerto
3306. No hace falta recuperar el password maestro para continuar.

## 6. Crear el secreto de aplicación

```bash
bash scripts/ecs.sh secret
```

Internamente el script:

1. Comprueba el perfil/cuenta con STS y consulta los secretos existentes.
2. Reutiliza `contenedores/api/mysql` si existe, sin modificar su contraseña.
3. Si falta, pide una clave aleatoria de 32 caracteres mediante
   `secretsmanager get-random-password`.
4. `jq` construye `SecretString` con `username=appuser` y el password.
5. Guarda la solicitud en un directorio temporal privado con `umask 077`, llama
   `create-secret` mediante `file://` y elimina el temporal al salir.

El valor no se pasa como argumento del proceso ni se imprime. El resultado
visible es el ARN y nombre. Este secreto es diferente del administrador creado
por RDS. Consultar solo su identificación:

```bash
aws secretsmanager describe-secret --secret-id contenedores/api/mysql \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" --query '{Name:Name,ARN:ARN}'
```

## 7. Crear ECR, construir y publicar

```bash
bash scripts/ecs.sh image --version v1
```

`image` consulta ECR, crea el repositorio `contenedores-api` si falta y habilita
scan-on-push al crearlo. Pasa el token de `get-login-password` a `docker login`
por stdin. Después ejecuta `docker build --platform linux/amd64` y `docker push`.
La etiqueta resultante es:

```text
CUENTA_DEL_ALUMNO.dkr.ecr.REGION_DEL_ALUMNO.amazonaws.com/contenedores-api:v1
```

Comprobar publicación:

```bash
aws ecr describe-images --repository-name contenedores-api \
  --image-ids imageTag=v1 --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
```

## 8. Generar tareas y políticas: equivalente de Prepare-Ecs.ps1

Este paso independiente sirve para estudiar o revisar los JSON antes de crear
roles y registrar tareas. **Solo genera archivos locales.**

```bash
IMAGE_URI="${LAB_AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/contenedores-api:v1"
APP_SECRET_ARN="$(aws secretsmanager describe-secret \
  --secret-id contenedores/api/mysql --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" \
  --query ARN --output text)"

bash backend/scripts/Prepare-Ecs.sh \
  --image-uri "$IMAGE_URI" \
  --app-secret-arn "$APP_SECRET_ARN" \
  --version v1
```

Entradas: outputs del estado Terraform, URI de la imagen y ARN del secreto de
aplicación. No lee passwords. Comprueba que el estado pertenezca a la cuenta
prevista y que el ARN sea el secreto appuser del laboratorio.

El script lee los seis `*.example.json`, reemplaza sus marcadores con `jq walk`,
valida que no queden marcadores y escribe:

| Salida local | Contenido |
| --- | --- |
| `bootstrap-task.json` | Imagen, RDS, execution role, cuatro variables secretas y comando init-db |
| `runtime-task.json` | API, health check y dos variables secretas appuser |
| `network.json` | Dos subredes privadas, SG ECS y `assignPublicIp=DISABLED` |
| `bootstrap-secrets-policy.json` | Lectura del secreto appuser y administrador |
| `runtime-secrets-policy.json` | Lectura solo del secreto appuser |
| `trust.json` | ECS tasks puede asumir el execution role |

Actualiza también `policy/ecs-*-secrets-policy.json`, `ecs-task-trust.json` y los
ARNs de lectura de secretos de las políticas completas `policy/02-ecs/`.
Los ejemplos versionados no se modifican. Las copias generadas específicas del
despliegue permanecen ignoradas. Ver [marcadores](../backend/ecs/generated/LEEME.md).

Para revisar sin mostrar passwords, porque estas definiciones solo tienen ARNs:

```bash
jq . backend/ecs/generated/runtime-task.json
jq . backend/ecs/generated/bootstrap-task.json
jq . backend/ecs/generated/network.json
```

## 9. Crear roles, logs, clúster y registrar tareas

```bash
bash scripts/ecs.sh prepare --version v1
```

Este paso ejecuta otra vez el generador con los valores actuales; no es necesario
repetir el paso 8 si no se quiere inspeccionar los archivos antes. A continuación:

1. Crea `/ecs/contenedores-api` si no existe y fija retención en siete días.
2. Crea o actualiza el trust de los roles bootstrap/runtime.
3. Adjunta `AmazonECSTaskExecutionRolePolicy` y la política inline
   `database-secret` adecuada para cada rol.
4. Registra `bootstrap-task.json` y `runtime-task.json`, mostrando sus ARNs.
5. Crea/reutiliza el clúster ECS `contenedores-lab`.

Repetir `prepare` registra revisiones nuevas. No ejecuta SQL ni crea el servicio
público. Los permisos IAM pueden tardar en propagarse; ante AccessDenied inicial
revisar la política y esperar antes de reintentar bootstrap.

## 10. Crear la tabla y appuser mediante bootstrap

```bash
bash scripts/ecs.sh bootstrap
```

Usa `network.json` para ejecutar Fargate en privado, con ambos secretos inyectados
por el execution role. Espera `tasks-stopped` y comprueba que exista el contenedor
y que su `exitCode` sea 0. Si no se pudo iniciar o terminó con error, el script
devuelve código distinto de cero.

`init-db.mjs` crea `products`, crea/actualiza `appuser` con la contraseña del
secreto y concede SELECT, INSERT, UPDATE y DELETE sobre `contenedores`.
No borra productos. No ejecutar bootstraps en paralelo. Revisar logs:

```bash
aws logs tail /ecs/contenedores-api --since 10m \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
```

## 11. Crear ALB y servicio Fargate

Definir la IP pública real de salida. `203.0.113.10/32` es solo un ejemplo de
documentación: sustituirlo. El script exige una IPv4 válida con `/32`.

```bash
OPERATOR_CIDR='TU_IPV4_PUBLICA/32'
bash scripts/ecs.sh service --cidr "$OPERATOR_CIDR"
bash scripts/ecs.sh status
```

`service` obtiene VPC/subredes/SG desde Terraform y crea:

1. SG `contenedores-api-alb`: entrada HTTP 80 desde el operador.
2. Regla TCP 3000 en el SG ECS desde el SG ALB.
3. ALB público en las dos subredes públicas.
4. Target group tipo IP y puerto 3000 con `/health/ready`.
5. Listener HTTP 80 que reenvía al target group.
6. Servicio Fargate `contenedores-lab`, dos tareas privadas y 60 segundos de
   gracia para health checks.

Espera el ALB y el servicio estables y muestra `http://DNS/docs/`. Abrir Swagger,
crear un producto y listar. `service` es de primera instalación: si falla a mitad,
inspeccionar AWS antes de repetir para evitar colisiones de nombres. No borra
recursos existentes para resolver esas colisiones.

## 12. Crear EKS Auto Mode

```bash
bash scripts/eks.sh create --cidr "$OPERATOR_CIDR"
```

Este script crea/actualiza el rol de clúster con su trust de Auto Mode y estas
políticas AWS administradas: AmazonEKSClusterPolicy, AmazonEKSComputePolicy,
AmazonEKSBlockStoragePolicyV2, AmazonEKSLoadBalancingPolicy y
AmazonEKSNetworkingPolicy. El rol de nodos confía en EC2 y usa
AmazonEKSWorkerNodeMinimalPolicy y AmazonEC2ContainerRegistryPullOnly.

Construye una solicitud JSON temporal con:

- Subredes privadas y SG preparado por Terraform.
- Endpoint privado habilitado y público restringido al CIDR del operador.
- Pools Auto Mode `system` y `general-purpose`.
- Capacidades integradas de balanceo y block storage activas.
- Autenticación API y creación automática de entrada admin del creador desactivada.
- Logs api/audit/authenticator habilitados.

Tras 15 segundos iniciales de propagación IAM, solicita el clúster y espera
ACTIVE. AWS elige su versión Kubernetes predeterminada disponible. Después crea
la Access entry del usuario/rol indicado en `operator_arn`, asocia
AmazonEKSClusterAdminPolicy y obtiene el SG real del clúster.

Guarda ese SG en `infra/eks-auto.auto.tfvars`. No crea managed node groups
adicionales. El rol administrador de Kubernetes es para este laboratorio;
limitarlo al adaptar a un entorno compartido.

### Si expira la espera de creación

No repetir `create` sin consultar AWS. Los waiters pueden agotar su tiempo aunque
el servicio siga creando el clúster. Consultar y esperar otra vez:

```bash
aws eks describe-cluster --name contenedores-eks --profile "$AWS_PROFILE" \
  --region "$AWS_DEFAULT_REGION" --query 'cluster.{status:status,version:version}'
aws eks wait cluster-active --name contenedores-eks \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
```

Si la primera ejecución terminó antes de crear la Access entry, completar los
pasos pendientes. Primero listar las existentes, para no duplicar:

```bash
aws eks list-access-entries --cluster-name contenedores-eks \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
```

Solo si falta el principal, crearla:

```bash
PRINCIPAL_ARN="$LAB_OPERATOR_ARN"
aws eks create-access-entry --cluster-name contenedores-eks \
  --principal-arn "$PRINCIPAL_ARN" --type STANDARD \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
aws eks associate-access-policy --cluster-name contenedores-eks \
  --principal-arn "$PRINCIPAL_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
```

Recuperar el SG y guardar la variable si esa parte no se ejecutó:

```bash
AUTO_SG="$(aws eks describe-cluster --name contenedores-eks \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" \
  --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)"
printf 'eks_auto_node_security_group_id = "%s"\n' "$AUTO_SG" > infra/eks-auto.auto.tfvars
```

## 13. Autorizar MySQL desde el SG real de EKS

```bash
terraform -chdir=infra plan -out=eks-mysql.tfplan
# Revisar: debe agregar la regla 3306, sin recrear la base.
terraform -chdir=infra apply eks-mysql.tfplan
```

La regla de `eks-auto-mysql.tf` conecta el SG real de Auto Mode con el SG MySQL.
Un SG EKS de ejemplo que no esté en las interfaces reales no permitiría la
conexión. En una NodeClass personalizada comprobar sus SG efectivos.

## 14. Conectar kubectl: equivalente de Initialize-Eks.ps1

```bash
bash eks/Initialize-Eks.sh
# Equivalente con el script de etapas:
bash scripts/eks.sh connect
```

Solo es necesario ejecutar una de las dos variantes. Actualizan kubeconfig con
AWS CLI, fijan alias `contenedores-eks`, comprueban contexto y consultan nodos.
No crean EKS ni importan CA al sistema Linux. Si todavía no hay workloads, Auto
Mode puede no haber creado capacidad de aplicación; eso no se arregla creando
un managed node group adicional. Comprobar pools y eventos:

```bash
kubectl --context contenedores-eks get nodepools
kubectl --context contenedores-eks get nodes -o wide
```

## 15. Sincronizar solo el Secret: equivalente de Sync-EksSecret.ps1

Este paso es independiente para una rotación o una demostración manual.
El despliegue completo del paso 16 ya lo ejecuta internamente.

```bash
kubectl --context contenedores-eks apply -f backend/k8s/namespace.yaml
APP_SECRET_ARN="$(aws secretsmanager describe-secret \
  --secret-id contenedores/api/mysql --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" \
  --query ARN --output text)"
bash backend/scripts/Sync-EksSecret.sh \
  --app-secret-arn "$APP_SECRET_ARN" \
  --context contenedores-eks
```

Antes de leer AWS, comprueba el contexto seleccionado. Luego verifica cuenta,
lee SecretString, exige `username=appuser` y password no vacío y genera un Secret
Opaque con `DB_USER` y `DB_PASSWORD` codificados en base64. La tubería conecta
AWS CLI → jq → kubectl server-side apply por stdin. No guarda password en disco
ni argv, y no crea anotación last-applied con otra copia del secreto.

No reinicia pods. Base64 no es cifrado; no guardar la salida en Git. Si cambia
la clave, actualizar también MySQL con bootstrap y reiniciar los workloads.

## 16. Desplegar ConfigMap, Secret, Deployment y Service

```bash
bash scripts/eks.sh deploy --version v1
bash scripts/eks.sh status
```

`deploy` configura kubeconfig/contexto y ejecuta, en este orden:

1. Namespace desde `namespace.yaml`.
2. ConfigMap generado por jq con host/base actuales, TLS y versión solicitada.
3. Sincronización del Secret mediante `Sync-EksSecret.sh`.
4. `kubectl set image --local` sobre `deployment.yaml`, para usar la imagen ECR
   de esa versión sin editar permanentemente el archivo de referencia.
5. Aplicación del Deployment resultante por stdin y de `service.yaml`.
6. Espera de rollout con timeout de 600 segundos.

Para acceso sin ALB:

```bash
kubectl --context contenedores-eks -n contenedores \
  port-forward service/productos-api 8080:80
```

Abrir `http://localhost:8080/docs/`. Desde otra terminal:

```bash
curl --fail http://localhost:8080/health/ready
curl --fail http://localhost:8080/api/info
curl --fail http://localhost:8080/api/products
```

Los productos creados desde ECS deben estar en la respuesta. El Service sigue
siendo ClusterIP. Detener el túnel con Ctrl+C no elimina pods.

## 17. Publicar el ALB EKS usando subredes actuales

```bash
bash scripts/eks.sh publish-alb --cidr "$OPERATOR_CIDR"
kubectl --context contenedores-eks -n contenedores \
  get ingress productos-api-public -w
```

`publish-alb` requiere el contexto correcto y genera tres objetos equivalentes
a `backend/k8s/alb/ingress.yaml`: IngressClassParams, IngressClass e Ingress.
Usa las subredes públicas actuales de Terraform y el CIDR recibido; no reutiliza
IDs de la VPC eliminada. Los envía como una List JSON por stdin a kubectl.

El controlador Auto Mode crea el ALB internet-facing, IPv4, target IP, listener
HTTP 80 y health check `/health/ready`. Esperar ADDRESS y targets healthy antes
de abrir `http://ADDRESS/docs/`. La salida inicial de apply no garantiza que el
balanceador ya esté disponible. HTTPS requiere certificado y configuración
adicional; esta publicación es HTTP restringido al operador.

## 18. Publicar una versión nueva

ECS:

```bash
bash scripts/ecs.sh image --version v2
bash scripts/ecs.sh prepare --version v2
bash scripts/ecs.sh update
bash scripts/ecs.sh status
```

`update` utiliza la última revisión registrada de `contenedores-api-runtime`.
No interpreta una versión de imagen: esa relación se establece en `prepare`.
No ejecutar `update` antes de registrar la revisión que se quiere desplegar.

EKS, después de publicar la misma imagen:

```bash
bash scripts/eks.sh deploy --version v2
kubectl --context contenedores-eks -n contenedores \
  rollout status deployment/productos-api --timeout=600s
```

Actualizar la imagen del manifiesto versionado si se quiere conservar v2 como
referencia. Los scripts no cambian automáticamente el YAML de Git.

## 19. Rotación de password appuser

Después de actualizar la contraseña del secreto en Secrets Manager:

```bash
bash scripts/ecs.sh bootstrap
bash scripts/ecs.sh update
bash backend/scripts/Sync-EksSecret.sh --app-secret-arn "$APP_SECRET_ARN"
kubectl --context contenedores-eks -n contenedores \
  rollout restart deployment/productos-api
kubectl --context contenedores-eks -n contenedores \
  rollout status deployment/productos-api --timeout=600s
```

Bootstrap actualiza MySQL. ECS update fuerza tareas nuevas para inyectar la
contraseña actual. Sincronización copia el valor a Kubernetes y restart renueva
las variables de los pods. Reaplicar un Secret no modifica el entorno de un
proceso ya iniciado. Si cambió el ARN del secreto, repetir prepare para actualizar
políticas y referencias de las task definitions antes de ejecutar bootstrap.

## 20. Fallos y recuperación

| Fallo | Revisar / acción |
| --- | --- |
| `Falta dependencia` | `command -v` y PATH de la terminal Linux |
| Cuenta distinta | Perfil propio de lab.config.json y `aws sts get-caller-identity` |
| `Faltan outputs` | Estado correcto y apply Terraform completado |
| ECR build exec format error | Arquitectura del host y build amd64 |
| Bootstrap AccessDenied | execution role, ARN exacto y propagación IAM |
| Bootstrap termina con error | stoppedReason y CloudWatch; no continuar a servicio |
| ECS targets unhealthy | SG ALB→ECS 3000, host RDS, TLS y appuser |
| EKS waiter expira | Consultar ACTIVE/CREATING; no duplicar create |
| kubectl timeout | IP pública del operador, endpoint EKS, VPN y CA |
| kubectl Forbidden | Access entry y política EKS; DescribeCluster no basta |
| Pod Pending | Pool, selector amd64, eventos y capacidad |
| Readiness 503 | SG real Auto Mode→RDS, SQL y password |
| Secret sync contexto incorrecto | Ejecutar connect y seleccionar contenedores-eks |
| ALB no muestra ADDRESS | CRD Auto Mode, permisos de rol, etiquetas y eventos Ingress |

Comandos de diagnóstico:

```bash
kubectl --context contenedores-eks -n contenedores get events --sort-by=.metadata.creationTimestamp
kubectl --context contenedores-eks -n contenedores logs deployment/productos-api --tail=100
kubectl --context contenedores-eks -n contenedores describe ingress productos-api-public
aws logs tail /ecs/contenedores-api --since 10m --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
```

`service` y `create` son primeras instalaciones, no reconciliadores. Ante un
fallo parcial conservar la salida, consultar recursos y completar o retirar lo
creado antes de reintentar. Una espera agotada no equivale a un rollback.

## 21. Limpieza desde Linux

La eliminación borra MySQL sin snapshot final. Exportar datos si se necesitan.
Retirar primero workloads y recursos externos a Terraform:

```bash
kubectl --context contenedores-eks delete namespace contenedores
# Esperar que el controlador retire ALB y target groups EKS.
kubectl --context contenedores-eks delete ingressclass alb-contenedores --ignore-not-found
kubectl --context contenedores-eks delete ingressclassparams.eks.amazonaws.com alb-contenedores --ignore-not-found

aws ecs update-service --cluster contenedores-lab --service contenedores-lab \
  --desired-count 0 --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
aws ecs delete-service --cluster contenedores-lab --service contenedores-lab \
  --force --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
```

Esperar tareas detenidas; retirar ALB/TG/SG ECS, referencias del SG y clúster ECS
según el [orden de limpieza principal](../README.md#limpieza-y-costos). Si el
servicio pertenecía a un stack CloudFormation, eliminar su stack.

Antes de borrar EKS, retirar la referencia externa de MySQL al SG EKS:

```bash
printf 'eks_auto_node_security_group_id = ""\n' > infra/eks-auto.auto.tfvars
terraform -chdir=infra plan -out=remove-eks-sg.tfplan
terraform -chdir=infra apply remove-eks-sg.tfplan
aws eks delete-cluster --name contenedores-eks --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"
aws eks wait cluster-deleted --name contenedores-eks --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION"

terraform -chdir=infra plan -destroy -out=cleanup.tfplan
terraform -chdir=infra apply cleanup.tfplan
terraform -chdir=infra state list
```

Si se añadieron managed node groups o Fargate profiles por otra ruta, retirarlos
antes del clúster. Borrar también ECR/imágenes, secreto appuser, logs, task
definitions y roles exclusivos; Terraform no los administra. Conservar estado
y backup para verificar y resolver cualquier dependencia restante.

## 22. Verificar scripts sin desplegar AWS

Ayuda y sintaxis no crean recursos:

```bash
bash scripts/ecs.sh --help
bash scripts/eks.sh --help
bash backend/scripts/Prepare-Ecs.sh --help
bash backend/scripts/Sync-EksSecret.sh --help
bash eks/Initialize-Eks.sh --help

for file in scripts/ecs.sh scripts/eks.sh scripts/lib/common.sh \
  backend/scripts/Prepare-Ecs.sh backend/scripts/Sync-EksSecret.sh \
  eks/Initialize-Eks.sh infra/Initialize-Session.sh; do
  bash -n "$file" || exit 1
done
```

Con Python 3 instalado, las pruebas usan binarios simulados en una copia temporal
del proyecto; no cambian políticas/estado reales ni llaman a AWS:

```bash
python3 -m unittest discover -s scripts -p test_linux_scripts.py -v
```

También se pueden ejecutar en un contenedor Linux aislado de la red. La imagen
debe estar descargada antes y contiene Bash, jq y Python:

```bash
docker run --rm --network none \
  --mount "type=bind,source=$PWD,target=/work,readonly" --workdir /work \
  --entrypoint /bin/bash public.ecr.aws/sam/build-python3.12:latest \
  -c 'python3 -m unittest discover -s scripts -p test_linux_scripts.py -v'
```

Estas pruebas verifican orquestación, generación y barreras de cuenta/contexto;
no demuestran permisos efectivos, conectividad RDS ni disponibilidad de AWS.

## Referencias

- [AWS CLI: task definitions ECS](https://docs.aws.amazon.com/cli/latest/reference/ecs/register-task-definition.html).
- [AWS CLI: crear EKS](https://docs.aws.amazon.com/cli/latest/reference/eks/create-cluster.html).
- [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/create-cluster-auto.html).
- [Documentación general y arquitectura](../README.md).
