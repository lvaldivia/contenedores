$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../infra/Initialize-Session.ps1')
$identity = & aws sts get-caller-identity --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION --output json
if ($LASTEXITCODE -ne 0 -or ($identity | ConvertFrom-Json).Account -ne $env:LAB_AWS_ACCOUNT_ID) { throw 'Cuenta AWS incorrecta.' }
for ($attempt=1; $attempt -le 30; $attempt++) {
    $status = & aws eks describe-cluster --name contenedores-eks --query cluster.status --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION --output text
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar el cluster.' }
    Write-Output "Estado EKS: $status"
    if ($status -eq 'ACTIVE') {
        $desired=Get-Content -Raw (Join-Path $PSScriptRoot 'cluster-network-logging-update.json') | ConvertFrom-Json
        foreach ($kind in @('resourcesVpcConfig','logging')) {
            $body=@{name='contenedores-eks'}
            $body[$kind]=$desired.$kind
            $path=Join-Path $PSScriptRoot "update-$kind.json"
            [IO.File]::WriteAllText($path,($body | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            $request='file://' + $path
            $raw=& aws eks update-cluster-config --cli-input-json $request --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION --output json
            if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar $kind" }
            $id=($raw | ConvertFrom-Json).update.id
            Write-Output "Actualizacion $kind iniciada: $id"
            $complete=$false
            for ($poll=1;$poll -le 40;$poll++) {
                $raw=& aws eks describe-update --name contenedores-eks --update-id $id --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION --output json
                if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar la actualizacion.' }
                $update=($raw | ConvertFrom-Json).update
                if ($update.status -eq 'Successful') { $complete=$true; Write-Output "$kind verificado: Successful"; break }
                if ($update.status -in @('Failed','Cancelled')) { throw "Actualizacion fallida: $($update | ConvertTo-Json -Depth 6)" }
                Start-Sleep -Seconds 10
            }
            if (-not $complete) { throw "Tiempo de espera agotado para $kind" }
        }
        exit 0
    }
    if ($status -in @('FAILED','DELETING')) { throw "Estado inesperado: $status" }
    Start-Sleep -Seconds 20
}
throw 'El cluster no llego a ACTIVE dentro del periodo de espera.'
