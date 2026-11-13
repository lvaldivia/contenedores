# Guía del alumno: una PC y una cuenta AWS propia

Cada alumno clona el repositorio en su equipo y trabaja en **su propia cuenta
AWS**. No necesita las credenciales, el perfil, los IDs de red ni los secretos del
docente. Los mismos nombres de laboratorio pueden existir en cuentas distintas.
Este recorrido contempla una instalación del laboratorio por cuenta y región.

## 1. Qué debe proporcionar el docente

- URL del repositorio y una revisión/tag probado que todos deben clonar.
- Objetivo y orden de las etapas: Docker local → red/RDS → ECS → EKS → limpieza.
- Región recomendada. `us-east-1` es el ejemplo de partida; cada alumno puede
  elegir otra región comercial compatible en su configuración.
- Una identidad IAM del alumno con permisos para este laboratorio. Las políticas
  limitadas de push ECR y sincronización de secretos no crean toda la infraestructura.
- Un presupuesto y tiempo para completar la limpieza al terminar la clase.

No usar claves del docente ni credenciales del usuario root. Una cuenta propia
no garantiza permisos o cuotas suficientes: cuentas administradas por Academy,
organizaciones o sandboxes pueden restringir IAM, EKS Auto Mode o tipos de EC2.
El docente debe comprobar esas restricciones antes de asignar el recorrido EKS.

## 2. Herramientas según el sistema operativo

| Herramienta | Windows | Linux |
| --- | --- | --- |
| Git | Git para Windows | Paquete de la distribución |
| Docker | Docker Desktop con backend Linux / WSL2 | Docker Engine o Desktop |
| AWS CLI | Versión 2 en PATH | Versión 2 en PATH |
| Terraform | >= 1.10 en PATH | >= 1.10 en PATH |
| kubectl | En PATH, compatible con la versión del clúster | Igual |
| Python | >= 3.10 para los scripts PowerShell de etapas | No requerido para desplegar por Bash |
| Bash / jq | No necesarios para el recorrido PowerShell | Bash >= 4 y jq >= 1.6 |

En Windows ejecutar los bloques PowerShell en PowerShell; en Linux ejecutar los
bloques Bash. No copiar un bloque de otro sistema en una terminal diferente.
Node.js >= 24 solo se necesita para pruebas/desarrollo fuera de Docker.

En una PC ARM, la imagen AWS debe construirse para `linux/amd64` con emulación
o desde un host compatible. Los scripts ya solicitan esa plataforma. No cambiar
solo el nodeSelector a ARM manteniendo una imagen amd64.

## 3. Clonar y verificar Docker local

Clonar la URL indicada por el docente y entrar en la carpeta del proyecto.
Esta primera etapa no requiere configurar AWS.

Windows:

```powershell
cd backend
Copy-Item .env.example .env # Solo si aún no existe.
# Editar las claves locales de .env.
docker compose up -d --build
docker compose ps
Invoke-RestMethod http://localhost:3000/health/ready
cd ..
```

Linux:

```bash
cd backend
test -f .env || cp .env.example .env
# Editar las claves locales de .env.
docker compose up -d --build
docker compose ps
curl --fail http://localhost:3000/health/ready
cd ..
```

Abrir `http://localhost:3000/docs/`, crear y listar un producto. La contraseña
local no es la contraseña AWS. Si el puerto 3000 está ocupado, revisar la
aplicación que lo usa antes de cambiar el puerto publicado en Compose.

## 4. Crear un perfil con credenciales propias

Los dos sistemas usan AWS CLI. El nombre de perfil puede ser cualquiera; en
esta guía se llama `laboratorio`:

```text
aws configure --profile laboratorio
aws sts get-caller-identity --profile laboratorio
```

Si la organización usa IAM Identity Center/SSO, configurar e iniciar ese perfil
con su mecanismo correspondiente en lugar de crear claves permanentes. La salida
STS debe pertenecer a la cuenta del alumno. No copiar claves ni archivos `.aws`
dentro del repositorio.

## 5. Configurar el laboratorio en un único archivo

Windows:

```powershell
Copy-Item lab.config.example.json lab.config.json
notepad lab.config.json
```

Linux:

```bash
cp lab.config.example.json lab.config.json
${EDITOR:-nano} lab.config.json
```

Completar con los valores propios:

```json
{
  "account_id": "123456789012",
  "profile": "laboratorio",
  "region": "us-east-1",
  "operator_arn": "",
  "mysql_engine_version": ""
}
```

`123456789012` es un ejemplo: reemplazarlo por los 12 dígitos devueltos por STS.
El perfil debe coincidir exactamente con el creado. Región, cuenta y perfil se
utilizan tanto en Terraform como en los scripts de creación.

| Campo | Cómo completarlo |
| --- | --- |
| `account_id` | Cuenta esperada; evita crear en otra cuenta por error de perfil |
| `profile` | Nombre local del perfil AWS CLI del alumno |
| `region` | Región comercial AWS elegida para todo el laboratorio |
| `operator_arn` | Vacío para inferir un usuario IAM; para sesiones asumidas/SSO, escribir el ARN IAM del rol real |
| `mysql_engine_version` | Vacío para consultar la versión menor predeterminada de MySQL 8.4 en esa región; o indicar una versión disponible específica |

Para `operator_arn`, usar `arn:aws:iam::CUENTA:user/NOMBRE` o
`arn:aws:iam::CUENTA:role/RUTA/NOMBRE`. **No** usar el ARN
`arn:aws:sts::...:assumed-role/.../SESION` devuelto por una sesión temporal.
El administrador de la cuenta puede proporcionar el ARN exacto del rol con su
ruta. Ese principal recibirá la Access entry de Kubernetes al crear EKS.

`lab.config.json` no contiene passwords y está ignorado por Git. No compartirlo
como configuración de otro alumno: representa la identidad esperada de esta PC.

## 6. Ejecutar la preparación sin crear recursos

Windows:

```powershell
./scripts/setup.ps1
. ./infra/Initialize-Session.ps1
```

Linux:

```bash
bash scripts/setup.sh
source ./infra/Initialize-Session.sh
```

La preparación comprueba herramientas, Docker Linux, STS, principal IAM y
disponibilidad regional de MySQL / `db.t4g.micro`. Si la versión estaba vacía,
selecciona la predeterminada disponible y la guarda para las siguientes
ejecuciones. No crea VPC, RDS, roles ni clústeres.

Genera `infra/lab.auto.tfvars.json`, ignorado por Git, con `account_id`, `profile`,
`region` y `mysql_engine_version`. Terraform lo carga automáticamente. El
proveedor usa `allowed_account_ids` con la cuenta de este archivo y bloquea las
demás. Los scripts también verifican STS antes de realizar cambios.

Resultado esperado: mensaje `Configuracion validada` con la cuenta del alumno,
su perfil, región y versión MySQL. Si falla, corregirlo antes de continuar.
Esto no demuestra todos los permisos futuros ni la capacidad/quota EC2 de EKS;
esas restricciones siguen dependiendo de la cuenta.

## 7. Crear la infraestructura

Comandos iguales en ambos sistemas; usar comillas en el argumento `-out`:

```text
terraform -chdir=infra init
terraform -chdir=infra fmt -check
terraform -chdir=infra validate
terraform -chdir=infra plan -out=lab.tfplan
terraform -chdir=infra apply lab.tfplan
terraform -chdir=infra output
```

En Windows PowerShell, si su versión separa el argumento, usar
`terraform '-chdir=infra' plan '-out=lab.tfplan'`.

Esperar RDS disponible y outputs de la cuenta propia. No copiar el estado, los
planes o `.terraform` de un compañero. Una PC tiene su estado local; mover la
administración a otro equipo requiere transferir ese estado de forma controlada.

Si se repite desde cero después de borrar EKS, comprobar que
`infra/eks-auto.auto.tfvars` no tenga el SG antiguo. Su valor vacío es
`eks_auto_node_security_group_id = ""`. No editar un plan ya guardado para
resolver cambios de configuración: generar un plan nuevo.

## 8. ECS: secreto, imagen, tareas, tabla y servicio

Windows:

```powershell
./scripts/lab.ps1 secret
./scripts/lab.ps1 image --version v1
./scripts/lab.ps1 prepare --version v1
./scripts/lab.ps1 bootstrap
./scripts/lab.ps1 ecs --cidr 'TU_IPV4_PUBLICA/32'
```

Linux:

```bash
bash scripts/ecs.sh secret
bash scripts/ecs.sh image --version v1
bash scripts/ecs.sh prepare --version v1
bash scripts/ecs.sh bootstrap
bash scripts/ecs.sh service --cidr 'TU_IPV4_PUBLICA/32'
bash scripts/ecs.sh status
```

Sustituir el CIDR por la IPv4 pública actual de salida del alumno, no por una IP
privada de la PC. Los nombres de ECR, roles y tareas son iguales en cada cuenta,
pero sus ARNs e imagen URI se generan con la cuenta y región propias.

Cada paso tiene una comprobación antes de pasar al siguiente:

| Paso | Resultado que debe ver el alumno |
| --- | --- |
| `secret` | ARN `contenedores/api/mysql` de su cuenta |
| `image` | Imagen v1 en su propio ECR |
| `prepare` | Roles y task definitions con su cuenta/region |
| `bootstrap` | STOPPED y `exitCode=0`; tabla y appuser creados |
| `ecs` / `service` | Servicio estable y URL Swagger del ALB |

Abrir la URL, consultar `/api/info`, crear un producto y guardarlo como evidencia
para compararlo después en EKS. El secreto maestro de RDS y appuser son distintos;
el runtime solo recibe appuser. El CA público global de RDS incluido en la
imagen permite validar TLS también al elegir otra región comercial.

## 9. EKS Auto Mode y autorización MySQL

Windows:

```powershell
./scripts/lab.ps1 eks --cidr 'TU_IPV4_PUBLICA/32'
terraform '-chdir=infra' plan '-out=eks-mysql.tfplan'
terraform '-chdir=infra' apply eks-mysql.tfplan
./scripts/lab.ps1 deploy --version v1
```

Linux:

```bash
bash scripts/eks.sh create --cidr 'TU_IPV4_PUBLICA/32'
terraform -chdir=infra plan -out=eks-mysql.tfplan
terraform -chdir=infra apply eks-mysql.tfplan
bash scripts/eks.sh deploy --version v1
```

La Access entry se crea para `operator_arn` de la configuración del alumno, no
para el usuario del docente. El SG real de EKS se guarda localmente y Terraform
autoriza su entrada MySQL. Auto Mode crea capacidad Linux amd64 para el workload;
no añadir un managed node group adicional para este recorrido.

La imagen y host RDS de los pods se generan desde configuración/outputs propios.
Los YAML versionados contienen marcadores visibles para explicar su estructura,
y no deben aplicarse manualmente sin completar esos valores.

```text
kubectl --context contenedores-eks -n contenedores get pods,svc
kubectl --context contenedores-eks -n contenedores port-forward svc/productos-api 8080:80
```

Abrir `http://localhost:8080/docs/`: el producto creado desde ECS debe estar en
la misma base. Conservar evidencia de pods listos y `/api/info` con entorno EKS.

## 10. Publicación ALB EKS opcional

Windows:

```powershell
./scripts/lab.ps1 publish --cidr 'TU_IPV4_PUBLICA/32'
```

Linux:

```bash
bash scripts/eks.sh publish-alb --cidr 'TU_IPV4_PUBLICA/32'
```

Ambos recorridos completan las subredes públicas actuales y el CIDR del alumno.
Esperar el DNS `ADDRESS` y targets healthy antes de probar Swagger. La
publicación usa HTTP 80 restringido al operador; no incluye un dominio/ACM.

## 11. Evidencias y criterios de finalización

| Etapa | Evidencia mínima |
| --- | --- |
| Local | Compose saludable, readiness 200 y producto creado |
| Identidad | Account ID propio y región, sin claves ni passwords |
| Infra | Outputs y RDS privado disponible |
| ECS | Bootstrap exitCode 0, tareas RUNNING, target healthy y CRUD |
| EKS | Pods Ready, rollout completado y el mismo producto persistido |
| Actualización | v2 visible en `/api/info` después del rollout |
| Limpieza | Sin recursos de laboratorio en AWS y estado Terraform vacío |

Nunca adjuntar capturas que muestren passwords, access keys o valores de Secret.
Los IDs y ARNs pueden verse para explicar identidad y dependencias.

## 12. Limpieza obligatoria al terminar

NAT, IPv4, RDS, EKS/Auto Mode, nodos y balanceadores generan cargos según la
cuenta/región. No asumir que todo entra en Free Tier o que apagar la API retira
la infraestructura. El docente debe reservar tiempo de clase para la limpieza.

Seguir el [orden de limpieza](../README.md#limpieza-y-costos): retirar Ingress y
workloads mientras EKS está activo, servicio ECS/tareas, balanceadores/TG/SG,
referencia MySQL→SG EKS, clúster y finalmente Terraform. Borrar también imágenes,
secreto appuser, logs, revisiones de tareas y roles exclusivos.

Al final ejecutar `terraform -chdir=infra state list` y consultar AWS en la cuenta
y región del alumno. Destruir elimina RDS sin snapshot final y los datos se pierden.
No usar un estado ajeno para limpiar recursos.

## 13. Qué está comprobado y qué falta comprobar en clase

Las pruebas locales simulan una cuenta y región diferentes de las del docente,
verifican generación de JSON/ARNs, bloqueo de cuentas equivocadas y los recorridos
ECS/EKS. Los scripts Bash se prueban en Linux sin red; también se valida sintaxis
PowerShell y Terraform.

La validación final requiere que el docente haga un recorrido completo en una
cuenta de alumno representativa, con las mismas restricciones y herramientas,
desde un clon nuevo hasta la limpieza. Las pruebas simuladas no prueban permisos
efectivos, cuotas, disponibilidad EC2, TLS corporativo ni conectividad real RDS.
Registrar la revisión Git y versiones utilizadas para entregar esa referencia.

## Más detalle

- [Arquitectura, VPC y explicación de todos los YAML](../README.md).
- [Linux: operación detallada de cada script](LINUX.md).
- [Políticas IAM por escenario](../policy/ESCENARIOS.md).
- [Plantillas ECS y tabla de reemplazos](../backend/ecs/generated/LEEME.md).
- [RDS: consultar versiones disponibles por región](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.VersionMgmt.html).
- [IAM para EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/auto-learn-iam.html).
