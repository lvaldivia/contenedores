$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../infra/Initialize-Session.ps1')
$toolsPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../tools'))
if (-not (Test-Path -LiteralPath (Join-Path $toolsPath 'kubectl.exe'))) { throw 'Falta kubectl en contenedores/tools.' }
$env:PATH = "$toolsPath;$env:PATH"
$env:GODEBUG=((@($env:GODEBUG -split ',' | Where-Object { $_ -and $_ -notmatch '^http2client=' }) + @('http2client=0')) -join ',')
$identity = & aws sts get-caller-identity --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION --output json
if ($LASTEXITCODE -ne 0 -or ($identity | ConvertFrom-Json).Account -ne $env:LAB_AWS_ACCOUNT_ID) { throw 'Cuenta AWS incorrecta.' }
& aws eks update-kubeconfig --name contenedores-eks --region $env:AWS_DEFAULT_REGION --profile $env:AWS_PROFILE --alias contenedores-eks
if ($LASTEXITCODE -ne 0) { throw 'No se pudo configurar kubeconfig.' }
# Use both the EKS CA and certificates already trusted by this Windows machine.
# Some managed networks re-sign HTTPS; certificate and hostname validation stay enabled.
$clusterCA = & aws eks describe-cluster --name contenedores-eks --query cluster.certificateAuthority.data --output text --profile $env:AWS_PROFILE --region $env:AWS_DEFAULT_REGION
if ($LASTEXITCODE -ne 0 -or -not $clusterCA -or $clusterCA -eq 'None') { throw 'El cluster todavia no publica su CA.' }
$certPath=Join-Path $PSScriptRoot 'eks-cluster-ca.cer'
[IO.File]::WriteAllBytes($certPath,[Convert]::FromBase64String($clusterCA))
$cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($certPath)
if (-not (Test-Path ("Cert:/CurrentUser/Root/"+$cert.Thumbprint))) {
    Import-Certificate -FilePath $certPath -CertStoreLocation Cert:/CurrentUser/Root | Out-Null
}
$bundle = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clusterCA)) + "`n" + [IO.File]::ReadAllText($env:AWS_CA_BUNDLE)
$bundlePath = Join-Path $PSScriptRoot 'cluster-trust-bundle.pem'
[IO.File]::WriteAllText($bundlePath,$bundle,[Text.Encoding]::ASCII)
& kubectl config set-cluster "arn:aws:eks:$($env:AWS_DEFAULT_REGION):$($env:LAB_AWS_ACCOUNT_ID):cluster/contenedores-eks" "--certificate-authority=$bundlePath" --embed-certs=true
if ($LASTEXITCODE -ne 0) { throw 'No se pudo configurar la cadena de confianza.' }
& kubectl version --client
& kubectl config current-context
