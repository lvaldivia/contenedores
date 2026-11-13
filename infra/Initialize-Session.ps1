param([switch]$LocalPluginTlsWorkaround)
$ErrorActionPreference = 'Stop'

# Trust the Windows CA stores, including the workstation's enterprise CA.
# No AWS credentials are copied or stored by this script.
$certificates = @{}
foreach ($storePath in @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\CA', 'Cert:\CurrentUser\Root', 'Cert:\CurrentUser\CA')) {
    Get-ChildItem -Path $storePath | ForEach-Object { $certificates[$_.Thumbprint] = $_ }
}
$pemBlocks = foreach ($cert in $certificates.Values) {
    "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($cert.RawData, [Base64FormattingOptions]::InsertLineBreaks) + "`n-----END CERTIFICATE-----"
}
$bundlePath = Join-Path $PSScriptRoot 'windows-ca.pem'
[IO.File]::WriteAllText($bundlePath, ($pemBlocks -join "`n"), [Text.Encoding]::ASCII)
$env:AWS_CA_BUNDLE = $bundlePath
$configPath = Join-Path $PSScriptRoot '../lab.config.json'
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $env:LAB_AWS_ACCOUNT_ID = $config.account_id
    $env:LAB_AWS_PROFILE = $config.profile
    $env:LAB_AWS_REGION = $config.region
    $env:LAB_OPERATOR_ARN = $config.operator_arn
}
if ($env:LAB_AWS_PROFILE) { $env:AWS_PROFILE = $env:LAB_AWS_PROFILE }
if ($env:LAB_AWS_REGION) { $env:AWS_DEFAULT_REGION = $env:LAB_AWS_REGION }

# Only needed on this workstation if Terraform's local provider mTLS fails.
# This affects Terraform-provider loopback RPC, not HTTPS verification to AWS.
if ($LocalPluginTlsWorkaround) { $env:TF_DISABLE_PLUGIN_TLS = '1' }
Write-Host "AWS session: $env:AWS_PROFILE / $env:AWS_DEFAULT_REGION. Certificate verification to AWS remains enabled."
