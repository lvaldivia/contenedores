param(
  [Parameter(Position=0,Mandatory=$true)][string]$Step,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Options
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../infra/Initialize-Session.ps1"
python "$PSScriptRoot/lab.py" $Step @Options
if ($LASTEXITCODE -ne 0) { throw "Fallo el paso $Step" }
