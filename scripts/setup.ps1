# Configuracion y consultas previas; no crea infraestructura AWS.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../infra/Initialize-Session.ps1"
python "$PSScriptRoot/lab.py" configure
if ($LASTEXITCODE -ne 0) { throw 'No se completo la configuracion del alumno.' }
