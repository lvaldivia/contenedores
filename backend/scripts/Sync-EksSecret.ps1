param(
  [Parameter(Mandatory=$true)][string]$AppSecretArn,
  [string]$ExpectedContext = 'contenedores-eks'
)
$ErrorActionPreference = 'Stop'
$current = & kubectl config current-context
if ($LASTEXITCODE -ne 0 -or $current -ne $ExpectedContext) {
  throw "Selecciona primero el contexto Kubernetes '$ExpectedContext'. No se transfirio ningun secreto."
}
$raw = & aws secretsmanager get-secret-value --secret-id $AppSecretArn --query SecretString --output text --profile luisvaldivia --region us-east-1
if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer el secreto de aplicacion.' }
$credentials = $raw | ConvertFrom-Json
if (-not $credentials.username -or -not $credentials.password) { throw 'El secreto debe contener username y password.' }
if ($credentials.username -eq 'labadmin') { throw 'Usa el secreto de aplicacion, no el administrador de RDS.' }
$payload = @{
  apiVersion='v1'; kind='Secret'; type='Opaque'
  metadata=@{name='mysql-app'; namespace='contenedores'}
  data=@{
    DB_USER=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credentials.username))
    DB_PASSWORD=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credentials.password))
  }
} | ConvertTo-Json -Depth 5 -Compress
# stdin only: do not write secret data to disk, output, or kubectl's last-applied annotation.
$payload | & kubectl --context $ExpectedContext apply --server-side --field-manager=lab-secret-sync -f -
if ($LASTEXITCODE -ne 0) { throw 'No se pudo aplicar el secreto al namespace contenedores.' }
Remove-Variable raw,credentials,payload
Write-Host 'Secreto mysql-app sincronizado. Los pods deben reiniciarse si cambio la clave.'
