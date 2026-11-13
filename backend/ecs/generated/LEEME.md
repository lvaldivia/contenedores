# Definiciones ECS: ejemplos versionados y archivos de despliegue

Los `*.example.json` se incluyen en Git para estudiar la estructura y permitir
un despliegue manual. Los `*.json` sin `.example` son salidas locales con los
valores de una ejecución y permanecen ignorados. Los ejemplos no contienen
contraseñas ni identificadores de la infraestructura eliminada.

## Archivos

| Ejemplo | Uso |
| --- | --- |
| `bootstrap-task.example.json` | Tarea temporal que crea tabla, usuario y grants; recibe ambos secretos |
| `runtime-task.example.json` | API permanente con health check; recibe solo appuser |
| `bootstrap-secrets-policy.example.json` | Lectura de secreto de aplicación y administrador |
| `runtime-secrets-policy.example.json` | Lectura únicamente del secreto de aplicación |
| `network.example.json` | Dos subredes privadas, SG ECS e IP pública deshabilitada |
| `trust.example.json` | Confianza del rol de ejecución en ECS tasks; no requiere reemplazos |

## Marcadores que se deben reemplazar

| Marcador | Valor y origen |
| --- | --- |
| `__ACCOUNT_ID__` | Cuenta AWS; consultar `aws sts get-caller-identity` |
| `__REGION__` | Región del laboratorio, por ejemplo `us-east-1` |
| `__IMAGE_URI__` | URI completa de la imagen publicada en ECR, incluida etiqueta o digest |
| `__APP_VERSION__` | Versión visible en `/api/info`, por ejemplo `v1` |
| `__DB_HOST__` | `terraform -chdir=infra output -raw mysql_host` |
| `__APP_SECRET_ARN__` | ARN completo de `contenedores/api/mysql`, con su sufijo real |
| `__ADMIN_SECRET_ARN__` | `terraform -chdir=infra output -raw mysql_admin_secret_arn` |
| `__PRIVATE_SUBNET_1__`, `__PRIVATE_SUBNET_2__` | `terraform -chdir=infra output -json app_private_subnet_ids` |
| `__ECS_SECURITY_GROUP_ID__` | `terraform -chdir=infra output -raw ecs_security_group_id` |

Conservar `:username::` y `:password::` después de los marcadores de ARN en las
task definitions: indican qué clave JSON inyecta ECS. En las políticas IAM se
usa el ARN sin esos selectores. No reemplazar los marcadores por passwords.
Conservar también los nombres de roles o adaptarlos a los roles creados.

## Opción recomendada: generar los valores actuales

Desde la raíz, después de crear RDS, el secreto appuser y la imagen:

Windows PowerShell:

```powershell
./scripts/lab.ps1 prepare --version v1
```

Linux Bash:

```bash
bash scripts/ecs.sh prepare --version v1
```

Estos pasos generan archivos locales, crean/actualizan roles y registran tareas.
No modifican los ejemplos versionados. La alternativa PowerShell que **solo
genera archivos**, desde la raíz, es:

```powershell
./backend/scripts/Prepare-Ecs.ps1 -ImageUri 'URI_REAL_DE_ECR' -AppSecretArn 'ARN_REAL_DE_APPUSER' -Version v1
```

Equivalente Linux que **solo genera archivos**, con Bash y jq:

```bash
bash backend/scripts/Prepare-Ecs.sh \
  --image-uri 'URI_REAL_DE_ECR' \
  --app-secret-arn 'ARN_REAL_DE_APPUSER' --version v1
```

Este `.sh` no llama a PowerShell ni Python. Lee los outputs actuales, completa
los seis ejemplos y actualiza las políticas locales. Ver [guía Linux](../../../docs/LINUX.md).

## Alternativa manual: copiar y completar ejemplos

Los comandos siguientes copian sobre los archivos locales de despliegue si ya
existen. Ejecutarlos desde la raíz y después editar las copias, conservando los
`*.example.json` como referencia portable.

Windows PowerShell:

```powershell
Get-ChildItem backend/ecs/generated/*.example.json | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $_.DirectoryName ($_.Name.Replace('.example.json', '.json')))
}
```

Linux Bash:

```bash
for file in backend/ecs/generated/*.example.json; do
  cp -- "$file" "${file%.example.json}.json"
done
```

Reemplazar todos los marcadores en las copias. Comprobar que no quede ninguno:

Windows:

```powershell
Get-ChildItem backend/ecs/generated/*.json | Where-Object Name -NotLike '*.example.json' | Select-String '__[A-Z0-9_]+__'
```

Linux:

```bash
find backend/ecs/generated -maxdepth 1 -name '*.json' ! -name '*.example.json' -exec grep -nE '__[A-Z0-9_]+__' {} +
```

No debe aparecer ninguna coincidencia. En Bash, grep devuelve código 1 cuando
no encuentra marcadores; eso es el resultado esperado de esta comprobación.
No registrar directamente un `*.example.json`: sus marcadores no son valores AWS.

Antes de ejecutar las tareas deben existir imagen ECR, log group y roles con las
políticas apropiadas. Seguir el [README principal](../../../README.md) para el
orden completo y [README del backend](../../README.md) para registro manual.
