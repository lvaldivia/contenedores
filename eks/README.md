# EKS Auto Mode del laboratorio

Cuenta `CUENTA_DEL_ALUMNO`, perfil `laboratorio`, región `us-east-1`, nombre `contenedores-eks`. Estos son nombres de referencia; no implican un clúster actualmente activo. El procedimiento completo de recreación Windows/Linux está en [README principal](../README.md).

## Crear y desplegar

1. Crear la infraestructura Terraform y ejecutar secreto, imagen, prepare y bootstrap.
2. Ejecutar `scripts/lab.ps1 eks --cidr 'TU_IPV4/32'` en Windows o `bash scripts/eks.sh create --cidr 'TU_IPV4/32'` en Linux.
3. Revisar/aplicar Terraform para autorizar MySQL desde el SG actual escrito por el script.
4. Ejecutar `deploy --version v1` desde el wrapper del sistema y verificar pods/Service.

Auto Mode usa pools `system` y `general-purpose`. El Deployment solicita nodos Linux amd64 para la imagen x86_64. No requiere crear un managed node group adicional. Los dos pods no tienen garantizada distribución entre zonas porque el manifiesto no declara topology spread constraints.

## IAM y acceso

Trust versionable del clúster: [policy/03-eks/auto-cluster-trust.json](../policy/03-eks/auto-cluster-trust.json), con AssumeRole y TagSession. Permisos administrados: AmazonEKSClusterPolicy, AmazonEKSComputePolicy, AmazonEKSBlockStoragePolicyV2, AmazonEKSLoadBalancingPolicy y AmazonEKSNetworkingPolicy.

Nodos: confianza EC2, AmazonEKSWorkerNodeMinimalPolicy y AmazonEC2ContainerRegistryPullOnly. Operador: Access entry Standard y AmazonEKSClusterAdminPolicy para este laboratorio. IAM DescribeCluster y acceso Kubernetes son permisos distintos.

El endpoint privado permite comunicación de nodos. El endpoint público se restringe a la IPv4 del operador /32. Si cambia la IP, actualizar publicAccessCidrs desde AWS antes de usar kubectl. Los logs api/audit/authenticator se envían a CloudWatch.

## Utilidades Windows existentes

`Initialize-Eks.ps1` configura kubeconfig y usa `tools/kubectl.exe`. Ese binario no se versiona: instalar kubectl desde su distribución oficial o colocarlo localmente en esa ruta con checksum verificado. La utilidad combina la CA del clúster con las CA confiables del equipo y puede importar la CA al almacén CurrentUser/Root para resolver inspección TLS local. Usa HTTP/1.1 mediante GODEBUG; no desactiva TLS.

## Equivalentes nativos Linux

La [guía Linux detallada](../docs/LINUX.md) cubre cada etapa, sus parámetros y
recuperación de fallos. No se ejecutan `.ps1` ni el provisionador Python.
Desde la raíz, con red/RDS, imagen, secreto appuser y bootstrap ya preparados:

```bash
source ./infra/Initialize-Session.sh
bash scripts/eks.sh create --cidr 'TU_IPV4_PUBLICA/32'
terraform -chdir=infra plan -out=eks-mysql.tfplan
terraform -chdir=infra apply eks-mysql.tfplan
bash eks/Initialize-Eks.sh
bash scripts/eks.sh deploy --version v1
bash scripts/eks.sh status
kubectl --context contenedores-eks -n contenedores port-forward svc/productos-api 8080:80
```

`Initialize-Eks.sh` configura kubeconfig y comprueba nodos con el kubectl del
PATH de Linux, sin importar CA Windows. Su equivalente por etapas es
`bash scripts/eks.sh connect`; ejecutar solo una variante.

El equivalente de `Sync-EksSecret.ps1`, para actualizar únicamente el Secret:

```bash
APP_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id contenedores/api/mysql \
  --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" --query ARN --output text)"
bash backend/scripts/Sync-EksSecret.sh --app-secret-arn "$APP_SECRET_ARN"
```

Requiere namespace existente y contexto seleccionado. No reinicia pods y no
guarda el password en archivos. `eks.sh deploy` ya incorpora esa sincronización.
Para ALB público con IP y subredes actuales:

```bash
bash scripts/eks.sh publish-alb --cidr 'TU_IPV4_PUBLICA/32'
kubectl --context contenedores-eks -n contenedores get ingress productos-api-public -w
```

`create` es primera instalación; `deploy` sirve también para nuevas versiones.
Ante un waiter agotado, consultar el estado AWS y completar Access entry antes
de repetir creaciones. Ver la recuperación detallada en la guía Linux.

## Utilidades históricas de diagnóstico Windows

`Complete-ClusterConfig.ps1` es una utilidad histórica para aplicar secuencialmente red y logs desde el archivo local `cluster-network-logging-update.json`. No es necesaria con el nuevo creador, que envía esa configuración al crear el clúster. El JSON local contiene CIDR/SG de una ejecución y no debe reutilizarse sin actualizar.

`verify_cluster.py` es un diagnóstico histórico Windows: revisa nodos, IAM, Access entry, logs y addons específicos, y lee un resultado de prueba TCP local. Sus requisitos de addons corresponden al clúster de esa ejecución; no es un validador genérico de Auto Mode nuevo. No ejecutarlo como paso obligatorio ni confundir prueba TCP con autenticación SQL.

Los archivos de resultados, CA y backups locales se ignoran en Git. El script portable `scripts/lab.py` no depende de esos resultados ni de esos JSON de diagnóstico.

## Antes de eliminar el clúster

Eliminar el namespace/Ingress mientras el controlador siga operativo y esperar limpieza del ALB. Vaciar `eks_auto_node_security_group_id` en `infra/eks-auto.auto.tfvars`, revisar/aplicar Terraform y después retirar nodos/grupos y clúster. Así no queda una regla externa de RDS reteniendo el SG de EKS. Verificar los recursos restantes antes de destruir la VPC.
