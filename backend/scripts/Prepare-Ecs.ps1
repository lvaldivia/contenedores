param(
  [Parameter(Mandatory=$true)][string]$ImageUri,
  [Parameter(Mandatory=$true)][string]$AppSecretArn,
  [string]$Version = 'v1'
)
$ErrorActionPreference = 'Stop'
$infraPath = Join-Path $PSScriptRoot '../../infra'
$raw = & terraform "-chdir=$infraPath" output -json
if ($LASTEXITCODE -ne 0) { throw 'No se pudieron leer los outputs de infraestructura' }
$infra = $raw | ConvertFrom-Json
$account = ($infra.mysql_admin_secret_arn.value -split ':')[4]
$region = $infra.region.value
$out = Join-Path $PSScriptRoot '../ecs/generated'
New-Item -ItemType Directory -Force $out | Out-Null
$policyOut = Join-Path $PSScriptRoot '../../policy'
New-Item -ItemType Directory -Force $policyOut | Out-Null
function Save-Policy($Name, $Value) {
  [IO.File]::WriteAllText((Join-Path $policyOut $Name), ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
function Save-Json($Name, $Value) {
  [IO.File]::WriteAllText((Join-Path $out $Name), ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
$trust = @{ Version='2012-10-17'; Statement=@(@{ Effect='Allow'; Principal=@{Service='ecs-tasks.amazonaws.com'}; Action='sts:AssumeRole' }) }
Save-Json 'trust.json' $trust
Save-Policy 'ecs-task-trust.json' $trust
foreach ($kind in @('runtime','bootstrap')) {
  $secretArns = @($AppSecretArn)
  if ($kind -eq 'bootstrap') { $secretArns += $infra.mysql_admin_secret_arn.value }
  Save-Json "$kind-secrets-policy.json" @{ Version='2012-10-17'; Statement=@(@{ Effect='Allow'; Action='secretsmanager:GetSecretValue'; Resource=$secretArns }) }
  Save-Policy "ecs-$kind-secrets-policy.json" @{ Version='2012-10-17'; Statement=@(@{ Effect='Allow'; Action='secretsmanager:GetSecretValue'; Resource=$secretArns }) }
  $scenarioPolicy = Join-Path $policyOut "02-ecs/$kind-execution-policy.json"
  if (Test-Path -LiteralPath $scenarioPolicy) {
    $complete = Get-Content -LiteralPath $scenarioPolicy -Raw | ConvertFrom-Json
    ($complete.Statement | Where-Object Sid -eq 'ReadDatabaseCredentials').Resource = $secretArns
    Save-Policy "02-ecs/$kind-execution-policy.json" $complete
  }
  $secrets = @(
    @{name='DB_USER'; valueFrom="${AppSecretArn}:username::"},
    @{name='DB_PASSWORD'; valueFrom="${AppSecretArn}:password::"}
  )
  if ($kind -eq 'bootstrap') {
    $admin = $infra.mysql_admin_secret_arn.value
    $secrets += @{name='DB_ADMIN_USER'; valueFrom="${admin}:username::"}
    $secrets += @{name='DB_ADMIN_PASSWORD'; valueFrom="${admin}:password::"}
  }
  $container = @{
    name='api'; image=$ImageUri; essential=$true
    portMappings=@(@{containerPort=3000; protocol='tcp'})
    environment=@(
      @{name='DB_HOST'; value=$infra.mysql_host.value},
      @{name='DB_PORT'; value='3306'},
      @{name='DB_NAME'; value=$infra.mysql_database.value},
      @{name='DB_SSL'; value='true'},
      @{name='DB_SSL_CA'; value='/app/certs/rds-us-east-1-bundle.pem'},
      @{name='APP_ENV'; value='ecs'},
      @{name='APP_VERSION'; value=$Version}
    )
    secrets=$secrets
    logConfiguration=@{logDriver='awslogs'; options=@{'awslogs-group'='/ecs/contenedores-api'; 'awslogs-region'=$region; 'awslogs-stream-prefix'=$kind}}
  }
  if ($kind -eq 'bootstrap') { $container.command=@('node','src/init-db.mjs') }
  else {
    $container.healthCheck=@{
      command=@('CMD-SHELL', 'node -e "fetch(''http://127.0.0.1:3000/health/live'').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"')
      interval=30; timeout=6; retries=3; startPeriod=20
    }
  }
  Save-Json "$kind-task.json" @{
    family="contenedores-api-$kind"; networkMode='awsvpc'; requiresCompatibilities=@('FARGATE')
    cpu='256'; memory='512'; executionRoleArn="arn:aws:iam::${account}:role/contenedores-api-$kind-execution"
    runtimePlatform=@{cpuArchitecture='X86_64'; operatingSystemFamily='LINUX'}
    containerDefinitions=@($container)
  }
}
Save-Json 'network.json' @{awsvpcConfiguration=@{
  subnets=@($infra.app_private_subnet_ids.value); securityGroups=@($infra.ecs_security_group_id.value); assignPublicIp='DISABLED'
}}
Write-Host "Archivos generados en $out. No se creo ni desplego ningun recurso AWS."
