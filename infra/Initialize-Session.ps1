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
$env:AWS_PROFILE = 'luisvaldivia'
$env:AWS_DEFAULT_REGION = 'us-east-1'

# Only needed on this workstation if Terraform's local provider mTLS fails.
# This affects Terraform-provider loopback RPC, not HTTPS verification to AWS.
if ($LocalPluginTlsWorkaround) { $env:TF_DISABLE_PLUGIN_TLS = '1' }
Write-Host 'AWS session: luisvaldivia / us-east-1. Certificate verification to AWS remains enabled.'
