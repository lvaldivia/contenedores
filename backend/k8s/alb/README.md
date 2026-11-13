# Publicar la API con un ALB de EKS Auto Mode

Estos archivos describen una publicacion opcional que debe recrearse sobre un
cluster Auto Mode activo con AmazonEKSLoadBalancingPolicy. No indican recursos activos.
El recorrido completo Windows/Linux y la explicacion de cada documento estan en
[README principal](../../../README.md).
No instalar un segundo controlador para este recorrido ni crear manualmente el ALB.

## Linux: generar con IP y subredes actuales

Desde la raíz, con clúster y aplicación ya desplegados:

```bash
bash eks/Initialize-Eks.sh
bash scripts/eks.sh publish-alb --cidr 'TU_IPV4_PUBLICA/32'
kubectl --context contenedores-eks -n contenedores get ingress productos-api-public -w
```

El script Bash lee `public_subnet_ids` de Terraform y genera los mismos tres
objetos con el CIDR solicitado, sin reutilizar los IDs antiguos del YAML.
Requiere Bash, jq, AWS CLI, Terraform y kubectl; no PowerShell ni Python.
Ver [procedimiento Linux completo](../../../docs/LINUX.md).

## Windows: aplicación del YAML de referencia

1. Abrir PowerShell en la carpeta demos e inicializar la sesion:

```powershell
. ./contenedores/eks/Initialize-Eks.ps1
cd ./contenedores/backend
```

2. Revisar `k8s/alb/ingress.yaml`. `inboundCIDRs` permite solo la IPv4 publica
   actual de la demostracion. Si cambia, sustituir el valor por la nueva IP /32.
   No incluir la IP privada de la laptop. El backend no tiene autenticacion de usuarios.
   Reemplazar tambien `subnets.ids` por `public_subnet_ids` del Terraform actual;
   los IDs anteriores dejan de existir al destruir la VPC.
3. Comprobar los pods y crear los recursos Kubernetes:

```powershell
kubectl get pods,svc -n contenedores
kubectl apply -f k8s/alb/ingress.yaml
kubectl get ingress productos-api-public -n contenedores -w
```

4. Esperar a que ADDRESS muestre el DNS del ALB. Ctrl+C detiene la observacion,
   no elimina los recursos. Si tarda, consultar:

```powershell
kubectl describe ingress productos-api-public -n contenedores
```

5. Copiar el DNS y abrir Swagger por HTTP:

```powershell
$albDns = kubectl get ingress productos-api-public -n contenedores -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
Write-Output "http://$albDns/docs/"
```

En la consola AWS: EC2 > Load Balancers > contenedores-eks-alb. Debe ser
Application / internet-facing, estar Active y tener un listener HTTP 80.
El target group debe ser tipo IP con destinos Healthy en puerto 3000.
EKS administra su registro y los security groups para el trafico del ALB.
No registrar a mano las IP efimeras de los pods.

La ruta es navegador -> ALB:80 -> Service productos-api:80 -> pod:3000 -> RDS.
El Service existente permanece ClusterIP. No crear ademas un Service LoadBalancer:
eso pediria otro balanceador NLB y no forma parte de este recorrido.

Este manifiesto publica HTTP. HTTPS requiere un dominio y un certificado ACM
apropiado, ademas del listener HTTPS en el Ingress. La URL del API de EKS sigue
siendo solo para administrar Kubernetes y no aloja Swagger.

Para retirar solo esta publicacion al terminar:

```powershell
kubectl delete -f k8s/alb/ingress.yaml
```

Auto Mode elimina el ALB asociado. No eliminarlo primero desde EC2 porque Kubernetes
continuaria intentando mantener la configuracion declarada por el Ingress.

Referencia: https://docs.aws.amazon.com/eks/latest/userguide/auto-configure-alb.html
