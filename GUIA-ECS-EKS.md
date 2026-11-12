# Guía de despliegue ECS y EKS

Comenzar por [README.md](README.md): ejecución local, preparación de AWS, Terraform y costos. Los comandos siguientes se ejecutan en PowerShell desde la raíz, salvo indicación contraria.

## ECS

Completar en orden las secciones de [ECR / ECS del backend](backend/README.md#preparar-despliegue-en-ecr--ecs): imagen ECR, secreto de aplicación, generación y registro de tareas, bootstrap y servicio con ALB. Antes de pasar a EKS, confirmar bootstrap con código 0 y disponibilidad de RDS. No se necesita mantener un servicio ECS activo para ejecutar EKS, pero sí inicializar la base.

## Crear el clúster EKS y los nodos

Estos recursos no están implementados en Terraform. Crearlos desde la consola AWS con un operador autorizado:

1. Crear rol de clúster y rol de nodos según [policy/ESCENARIOS.md](policy/ESCENARIOS.md#03-eks). Usar sus políticas administradas indicadas.
2. Crear un clúster llamado `contenedores-eks` en la VPC de `terraform -chdir=infra output vpc_id`, usando `app_private_subnet_ids`. Seleccionar una versión Kubernetes soportada por la cuenta/región y un modo de autenticación con Access entries.
3. Configurar acceso al endpoint de Kubernetes: privado para los nodos y público restringido a la IP del operador para estos comandos desde la laptop. Con endpoint únicamente privado se requiere VPN u otro acceso a la VPC.
4. Crear una Access entry para el principal IAM del operador y asociar `AmazonEKSClusterAdminPolicy` con alcance de clúster para este laboratorio. El permiso IAM para describir EKS no concede acceso a Kubernetes por sí solo.
5. Crear un managed node group Linux x86_64 en las subredes privadas con el rol de nodos. Si se usa launch template para adjuntar `eks_security_group_id`, incluir también los grupos/reglas necesarios para comunicación entre nodos y control plane. RDS permite 3306 desde ese SG; adjuntarlo a las interfaces de los nodos. Este recorrido presupone VPC CNI normal, sin security groups por pod.
6. Esperar clúster y nodos activos. Verificar complementos VPC CNI, CoreDNS y kube-proxy. Los nodos necesitan salida por NAT para descargar imágenes y acceder a servicios AWS.

## Conectar y aplicar la aplicación

```powershell
. ./infra/Initialize-Session.ps1
aws eks update-kubeconfig --name contenedores-eks --region us-east-1 --profile luisvaldivia --alias contenedores-eks
kubectl config current-context
kubectl get nodes
terraform -chdir=infra output mysql_host
```

Antes de aplicar, editar `backend/k8s/configmap.yaml` con el endpoint RDS devuelto por Terraform y `backend/k8s/deployment.yaml` con la imagen ECR publicada. No usar el endpoint de ejemplo si se creó una RDS nueva.

```powershell
kubectl apply -f backend/k8s/namespace.yaml
kubectl apply -f backend/k8s/configmap.yaml
$appSecretArn = 'ARN_REAL_DEL_SECRETO_DE_APLICACION'
./backend/scripts/Sync-EksSecret.ps1 -AppSecretArn $appSecretArn
kubectl apply -f backend/k8s/deployment.yaml
kubectl apply -f backend/k8s/service.yaml
kubectl -n contenedores rollout status deployment/productos-api --timeout=180s
kubectl -n contenedores get pods,svc
kubectl -n contenedores port-forward service/productos-api 8080:80
```

Mantener `port-forward` activo y abrir <http://localhost:8080/docs/>. En otra terminal, probar `Invoke-RestMethod http://localhost:8080/health/ready` y el CRUD desde Swagger. Detener el túnel con Ctrl+C.

El script lee Secrets Manager usando el perfil `luisvaldivia`, verifica el contexto `contenedores-eks` y transmite `DB_USER`/`DB_PASSWORD` a Kubernetes por stdin. No guardar su contenido en Git. El pod no necesita credenciales AWS. Los permisos del operador deben permitir leer ese secreto y crear/actualizar Secrets Kubernetes.

## Publicar una versión y revisar fallos

Después de construir y publicar una nueva etiqueta en ECR:

```powershell
$image = '299147769461.dkr.ecr.us-east-1.amazonaws.com/contenedores-api:v2'
kubectl -n contenedores set image deployment/productos-api api=$image
kubectl -n contenedores set env deployment/productos-api APP_VERSION=v2
kubectl -n contenedores rollout status deployment/productos-api --timeout=180s
kubectl -n contenedores logs deployment/productos-api --tail=100
kubectl -n contenedores get events --sort-by=.metadata.creationTimestamp
```

Actualizar también los manifiestos versionados para conservar la imagen y `APP_VERSION` deseadas. Ante un fallo de publicación, `kubectl -n contenedores rollout undo deployment/productos-api` revierte el Deployment; no revierte cambios de datos ni del ConfigMap.

Al rotar la contraseña: actualizar Secrets Manager, repetir bootstrap, ejecutar `Sync-EksSecret.ps1` y `kubectl -n contenedores rollout restart deployment/productos-api`. Comprobar luego el rollout y readiness.

## Retirar el despliegue

`kubectl delete -f backend/k8s/` elimina los objetos de aplicación, incluido su namespace y Secret; no elimina RDS. Retirar después node groups y clúster EKS desde AWS. Seguir la limpieza del [README principal](README.md#costos-y-limpieza) para los demás recursos.
