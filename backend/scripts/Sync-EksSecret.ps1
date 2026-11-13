param(
  [Parameter(Mandatory=$true)][string]$AppSecretArn,
  [string]$ExpectedContext = 'contenedores-eks'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../infra/Initialize-Session.ps1')
$current = & kubectl config current-context
if ($LASTEXITCODE -ne 0 -or $current -ne $ExpectedContext) {
  throw "Selecciona primero el contexto Kubernetes '$ExpectedContext'. No se transfirio ningun secreto."
}
$identity = & aws sts get-caller-identity --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION --output json
if ($LASTEXITCODE -ne 0 -or ($identity | ConvertFrom-Json).Account -ne $env:LAB_AWS_ACCOUNT_ID) { throw 'Cuenta AWS incorrecta.' }
if ($AppSecretArn -notlike "arn:aws:secretsmanager:$($env:LAB_AWS_REGION):$($env:LAB_AWS_ACCOUNT_ID):secret:contenedores/api/mysql-*") { throw 'ARN del secreto de aplicacion incorrecto.' }
$raw = & aws secretsmanager get-secret-value --secret-id $AppSecretArn --query SecretString --output text --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION
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
