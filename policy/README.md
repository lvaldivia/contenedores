# Politicas IAM del laboratorio

Para usar los JSON organizados por escenario, consultar [ESCENARIOS.md](ESCENARIOS.md).
Incluye políticas de ECR, ejecución ECS, roles y operador EKS y un anexo opcional IoT/Lambda/S3.

Cuenta y región propias de `lab.config.json`. Las políticas activas incluyen
marcadores que deben completarse; los generadores ECS usan los valores actuales.
Estos archivos son documentos JSON; crearlos no aplica cambios en AWS.

| Rol | Politica de confianza | Politicas de permisos |
| --- | --- | --- |
| contenedores-api-runtime-execution | ecs-task-trust.json | AmazonECSTaskExecutionRolePolicy + ecs-runtime-secrets-policy.json inline |
| contenedores-api-bootstrap-execution | ecs-task-trust.json | AmazonECSTaskExecutionRolePolicy + ecs-bootstrap-secrets-policy.json inline |
| contenedores-eks-cluster-role | 03-eks/auto-cluster-trust.json | AmazonEKSClusterPolicy + AmazonEKSComputePolicy + AmazonEKSBlockStoragePolicyV2 + AmazonEKSLoadBalancingPolicy + AmazonEKSNetworkingPolicy |
| contenedores-eks-node-role | 03-eks/node-trust.json | AmazonEKSWorkerNodeMinimalPolicy + AmazonEC2ContainerRegistryPullOnly |

## Donde pegar cada JSON

- Archivos `*-trust.json`: IAM > Roles > rol > Trust relationships > Edit trust policy.
  Al crear un rol, tambien pueden usarse en Custom trust policy.
- `ecs-*-secrets-policy.json`: IAM > Roles > rol > Permissions > Add permissions >
  Create inline policy > JSON. Nombre sugerido: `database-secret`.
- Archivos `aws-managed-*.json`: copias de referencia obtenidas de AWS.
  En consola usar Add permissions > Attach policies y buscar el nombre exacto de
  la politica de AWS, en vez de crear una copia personalizada que quedaria desactualizada.

## Secreto de aplicacion

El secreto `contenedores/api/mysql` lo crea cada alumno. Sustituir
`__APP_SECRET_ARN__` por su ARN real y `__ADMIN_SECRET_ARN__` por el output de RDS,
o ejecutar prepare para generar esos valores. En las políticas de operador se
puede restringir el nombre con el sufijo AWS de seis caracteres `-??????`.
No contienen passwords ni permiten leer todos los secretos de la cuenta.
Bootstrap incluye ademas el ARN exacto del secreto administrador de la RDS existente.

Despues de crear el secreto, desde `contenedores/backend` ejecutar:

```powershell
./scripts/Prepare-Ecs.ps1 -ImageUri $image -AppSecretArn $appSecretArn
```

Ese comando reemplaza las dos politicas de Secrets Manager de esta carpeta con
el ARN exacto recibido. Usar el nombre `contenedores/api/mysql` para mantener la
coherencia con la guia. Las politicas asumen cifrado con `aws/secretsmanager`;
una clave KMS propia requeriria revisar permisos y la politica de esa clave.

`AmazonEKSClusterAdminPolicy` del acceso al cluster es una politica de acceso EKS,
no un documento IAM para pegar como inline. Se asocia desde EKS > Access entries.

Las políticas de operador de las subcarpetas cubren push a ECR y conexión/sincronización
en EKS. No conceden administración general, creación de IAM ni provisión de toda la infraestructura.
