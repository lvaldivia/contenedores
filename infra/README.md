# Red y MySQL para los laboratorios ECS / EKS

Cuenta, perfil y región: los indicados por cada alumno en `lab.config.json`. Ejecutar `scripts/setup.ps1` o `bash scripts/setup.sh` antes de Terraform. Ver [guía del alumno](../docs/ALUMNOS.md).
Terraform administra exclusivamente los recursos de esta carpeta con estado local.
El proveedor rechaza otras cuentas para evitar un despliegue accidental.

## Arquitectura

Una sola VPC permite que ECS y EKS usen la misma base de datos mediante sus IP privadas.
No se necesita peering ni una VPC por servicio.

```text
VPC 10.80.0.0/16
  us-east-1a                         us-east-1b
  Publica 10.80.0.0/24               Publica 10.80.1.0/24
    Internet Gateway + NAT            futuros balanceadores
  Aplicacion 10.80.16.0/20           Aplicacion 10.80.32.0/20
    futuras tareas ECS / nodos EKS     futuras tareas ECS / nodos EKS
  BD aislada 10.80.240.0/24          BD aislada 10.80.241.0/24
    RDS usa un subnet group con ambas zonas; la instancia es Single-AZ
```

- Las subredes publicas tienen ruta al Internet Gateway. No asignan IP publica automaticamente.
- Las subredes de aplicacion salen por una NAT Gateway en la primera zona.
- Las subredes de base de datos solo tienen la ruta local de la VPC, sin NAT ni Internet Gateway.
- Las etiquetas `kubernetes.io/role/elb` e `internal-elb` preparan el descubrimiento de subredes para futuros balanceadores EKS.
- ECS y EKS cuentan con security groups independientes, con salida habilitada y sin entrada de aplicacion todavia.
- RDS acepta TCP 3306 exclusivamente desde esos dos security groups.
- No se crean clusters, nodos, tareas, balanceadores, ECR, workloads ni aplicaciones en esta etapa.

## MySQL

RDS MySQL 8.4 (versión regional comprobada por setup), `db.t4g.micro`, 20 GiB gp3 cifrados (autoscaling hasta 30 GiB).
Base inicial: `contenedores`. Administrador: `labadmin`.
Sin endpoint publico. RDS genera y administra la contrasena en Secrets Manager;
Terraform entrega solo el ARN del secreto, nunca el valor de la contrasena.

La conectividad de red queda preparada. La prueba SQL se hara en la siguiente etapa,
desde una tarea ECS o un pod EKS dentro de la VPC; tu laptop no tiene acceso directo.
Para la aplicacion se debe crear un usuario MySQL limitado a `contenedores`, separado
del administrador, y configurar la entrega del secreto al contenedor.

### Conexion posterior de ECS

Usar `app_private_subnet_ids`, `ecs_security_group_id` y `assignPublicIp=DISABLED`.
Variables futuras: `DB_HOST=mysql_host`, `DB_PORT=3306`, `DB_NAME=contenedores`.
El permiso de red no concede acceso a Secrets Manager: el rol apropiado de ECS debe
tener `secretsmanager:GetSecretValue` sobre el secreto usado por la aplicacion.
Agregar las reglas de ingreso HTTP desde el security group del balanceador al crear el servicio.

### Conexion posterior de EKS

Crear el cluster y los nodos en `app_private_subnet_ids`.
Adjuntar `eks_security_group_id` a los nodos mediante su launch template, ademas
de los security groups necesarios para la comunicacion de Kubernetes.
Esto presupone VPC CNI normal, sin custom networking ni security groups por pod.
Si se habilitan security groups por pod, autorizar ese SG especificamente en RDS.
La aplicacion recibira las mismas variables de conexion y un secreto de aplicacion.
El acceso AWS al secreto se configurara con identidad del workload en la siguiente etapa.

## Operacion desde PowerShell

```powershell
cd infra
. .\Initialize-Session.ps1 -LocalPluginTlsWorkaround
aws sts get-caller-identity
terraform init
terraform fmt -check
terraform validate
terraform plan '-out=lab.tfplan'
terraform apply lab.tfplan
terraform output
```

En esta computadora el RPC local de Terraform con el proveedor fallo al validar
su certificado mTLS. El switch usa `TF_DISABLE_PLUGIN_TLS=1` solo para ese transporte
local. HTTPS hacia AWS sigue verificando certificados mediante los almacenes Windows.
En otro equipo se puede omitir el switch si el proveedor funciona normalmente.

Guardar `terraform.tfstate` y su backup de forma segura; no subirlos a Git ni borrarlos.
Se incluye `.terraform.lock.hcl` para fijar la version del proveedor.
Los IDs y el endpoint se consultan con `terraform output`.

## Operación desde Linux / Bash

Desde la raíz, con AWS CLI v2 y Terraform instalados:

```bash
source ./infra/Initialize-Session.sh
aws sts get-caller-identity --profile "$AWS_PROFILE"
terraform -chdir=infra init
terraform -chdir=infra fmt -check
terraform -chdir=infra validate
terraform -chdir=infra plan -out=lab.tfplan
terraform -chdir=infra apply lab.tfplan
terraform -chdir=infra output
```

`Initialize-Session.sh` se carga con `source` para exportar perfil/región en la
terminal. No necesita PowerShell, no importa CA y no desactiva TLS del proveedor.
Si existe `eks-auto.auto.tfvars` de una ejecución anterior, vaciar el SG eliminado
antes de recrear. Después de crear EKS con `scripts/eks.sh create`, revisar/aplicar
el plan que autoriza MySQL desde el SG real escrito por ese script.

El [procedimiento Linux completo](../docs/LINUX.md) continúa con secreto appuser,
ECR, roles/tareas ECS, bootstrap SQL y EKS. La red y la base no bastan para crear
el usuario appuser: su secreto y el bootstrap son pasos separados.

## Costos y limpieza

La NAT Gateway, su IPv4 publica, RDS, almacenamiento y Secrets Manager generan cargos.
La NAT unica reduce recursos para el laboratorio, pero no ofrece salida multi-AZ
tolerante a fallos; el trafico desde la segunda zona puede generar transferencia entre AZ.
RDS es Single-AZ con un dia de retencion de backups.

Este es un entorno desechable: `deletion_protection=false` y `skip_final_snapshot=true`.
Al destruir se eliminan la base y sus backups automatizados sin snapshot final.
Exportar datos antes si se desean conservar. No ejecutar la limpieza durante la clase.

Despues de eliminar primero los futuros servicios ECS/EKS y sus balanceadores/ENIs:

```powershell
terraform plan -destroy
terraform destroy
```

## Referencias

- https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html
- https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html
- https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html
