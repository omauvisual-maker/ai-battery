param([string]$StartupDirectory=[Environment]::GetFolderPath('Startup'))
$ErrorActionPreference='Stop'
$target=[IO.Path]::GetFullPath((Join-Path $StartupDirectory 'AIBattery.lnk'))
$directory=[IO.Path]::GetFullPath($StartupDirectory).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($target) -ine $directory) { throw 'Caminho fora da pasta de inicializacao.' }
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
Write-Output 'Inicializacao automatica desativada. Os apps de IA nao foram alterados.'
