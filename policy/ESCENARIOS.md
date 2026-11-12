# Políticas por escenario

Los archivos están preparados para la cuenta 299147769461 y us-east-1.
No se aplicaron permisos en AWS. Las políticas de operador son complementarias;
no conceden permisos para crear toda la infraestructura, administrar IAM ni ejecutar Terraform.

## 01 ECR

`01-ecr/operator-push-policy.json`: adjuntar al usuario/rol que ejecuta Docker login
y push desde la laptop. Permite publicar y consultar imágenes solo en `contenedores-api`.
El repositorio debe existir. No concede creación de repositorios ni administración IAM.

## 02 ECS

| Rol | Confianza | Permisos propios completos |
| --- | --- | --- |
| contenedores-api-runtime-execution | 02-ecs/runtime-trust.json | 02-ecs/runtime-execution-policy.json |
| contenedores-api-bootstrap-execution | 02-ecs/bootstrap-trust.json | 02-ecs/bootstrap-execution-policy.json |

En IAM crear el rol con su trust, agregar la política de permisos como inline
y asignarlo como **Task execution role**. Estos JSON completos incluyen descarga ECR,
logs y secretos; se pueden usar en lugar de la combinación de política administrada
y política adicional de secretos de la guía original. Elegir una sola alternativa.

Crear previamente `/ecs/contenedores-api` en CloudWatch. No incluyen CreateLogGroup.
Runtime solo lee el secreto `contenedores/api/mysql`; bootstrap también lee el
administrador RDS y ejecuta la inicialización. Ningún task role es necesario para
este backend: no hace llamadas al SDK de AWS.

Los archivos originales `ecs-*-secrets-policy.json` en la raíz se conservan por
compatibilidad y siguen siendo válidos como alternativa con la política administrada.
`Prepare-Ecs.ps1` actualiza los permisos completos y los JSON originales con el ARN recibido.

## 03 EKS

- Cluster: confianza `03-eks/cluster-trust.json`. Adjuntar **AmazonEKSClusterPolicy**.
  `cluster-permissions-reference.json` es una copia de referencia, no una política adicional necesaria.
- Nodos: confianza `03-eks/node-trust.json`. Adjuntar **AmazonEKSWorkerNodePolicy**,
  **AmazonEC2ContainerRegistryPullOnly** y **AmazonEKS_CNI_Policy** para el recorrido IPv4.
  `node-permissions-reference.json` reúne sus contenidos para explicarlos; no adjuntarlo
  además de esas tres políticas. AWS puede actualizar sus políticas administradas.
- Operador: `03-eks/operator-connect-and-sync-policy.json` permite describir el
  cluster y leer el secreto para el script de sincronización. No administra el
  cluster, nodos ni Kubernetes por sí sola.
- Dentro de EKS, asociar **AmazonEKSClusterAdminPolicy** en una Access entry al
  principal operador para el laboratorio. Es una política de acceso EKS, no IAM.
- El pod no recibe credenciales AWS. El script del operador copia la contraseña
  de aplicación a un Secret Kubernetes; requiere repetir sincronización y restart
  si cambia. No equivale a una integración automática con Secrets Manager.

## MySQL y red

No se necesita `rds:*` para que el backend ejecute SQL con usuario y contraseña.
Se necesitan tres cosas separadas: credenciales, red TCP 3306 y grants MySQL.
IAM Database Authentication no está habilitado en este laboratorio; no agregar
`rds-db:connect` esperando que sustituya la configuración actual.

El SG MySQL debe permitir 3306 desde el SG ECS y el SG EKS de los nodos.
El usuario `appuser` recibe SELECT, INSERT, UPDATE y DELETE mediante bootstrap.
Los grupos de seguridad y los grants no son políticas IAM y no se adjuntan a roles.

## 04 IoT Lambda S3 opcional

Estos nombres son los previstos para una ampliación; estos recursos **no fueron creados**:

| Recurso | Nombre |
| --- | --- |
| Client ID MQTT | sensor-aula |
| Topic MQTT | aula/telemetria |
| Regla IoT | contenedores_telemetria |
| Lambda | contenedores-iot-processor |
| Bucket privado | contenedores-iot-299147769461-us-east-1 |
| Prefijo de objetos | telemetria/ |
| Rol Lambda sugerido | contenedores-iot-lambda-execution |

- `lambda-trust.json`: confianza del rol de ejecución de Lambda.
- `lambda-execution-policy.json`: permisos inline de ese rol para PutObject en
  `telemetria/*` y logs. Precrear `/aws/lambda/contenedores-iot-processor`.
  Asume bucket con cifrado SSE-S3 y Lambda fuera de la VPC; no incluye permisos KMS ni ENIs.
- `device-certificate-policy.json`: política **AWS IoT**, crear en IoT Core >
  Security > Policies y adjuntar al certificado activo del sensor. No es IAM.
  Solo conecta clientId `sensor-aula` y publica en `aula/telemetria`.
  No habilita suscripción/recepción. El cliente MQTT de prueba de la consola usa
  la identidad del operador, no el certificado ni esta política.
- `lambda-resource-policy.json`: muestra el permiso basado en recursos en Lambda.
  No se pega como política de ejecución IAM. Agregar desde la configuración de
  permisos de Lambda o mediante el comando de abajo. La regla IoT no necesita
  un rol de ejecución adicional para esta acción Lambda.

Comando para cuando existan Lambda y la regla, no ejecutado en esta entrega:

```powershell
aws lambda add-permission --function-name contenedores-iot-processor --statement-id AllowTelemetryRule --action lambda:InvokeFunction --principal iot.amazonaws.com --source-arn arn:aws:iot:us-east-1:299147769461:rule/contenedores_telemetria --source-account 299147769461 --profile luisvaldivia --region us-east-1
```

Configurar la regla con `SELECT * FROM 'aula/telemetria'`, acción Lambda sobre la
función indicada; la función deberá guardar sus resultados bajo `telemetria/`.
Si cambias nombres, ajustar ARNs antes de aplicar permisos. Revisar que el nombre
del bucket esté disponible. Esto prepara permisos y explicación; no implementa
la función ni los certificados de la demo IoT.

Referencias oficiales:

- https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html
- https://docs.aws.amazon.com/lambda/latest/dg/services-iot.html
- https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html
