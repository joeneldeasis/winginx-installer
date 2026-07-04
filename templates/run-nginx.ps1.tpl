$ErrorActionPreference = 'Stop'

$nginxRoot = '{{NGINX_ROOT_WIN}}'
$nginxExe = Join-Path -Path $nginxRoot -ChildPath 'nginx.exe'

Set-Location -LiteralPath $nginxRoot
& $nginxExe -p $nginxRoot -c 'conf\nginx.conf' -g 'daemon off;'
