$ErrorActionPreference = 'Stop'

$profileScript = '{{PROFILE_SCRIPT}}'
$powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -Path $profileScript)) {
    throw "PHP console profile was not found at '$profileScript'."
}

$startArgs = @(
    '-NoExit'
    '-ExecutionPolicy'
    'Bypass'
    '-NoLogo'
    '-File'
    $profileScript
)

Start-Process -FilePath $powershellExe -ArgumentList $startArgs -WorkingDirectory '{{WEB_ROOT}}'
