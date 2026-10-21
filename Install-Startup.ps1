param([string]$StartupDirectory=[Environment]::GetFolderPath('Startup'))
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\src\Lifecycle.psm1"
$spec=Get-StartupShortcutSpec (Join-Path $PSScriptRoot 'Start-AIBattery.ps1')
if (-not (Test-Path -LiteralPath $spec.WorkingDirectory)) { throw 'Diretorio do monitor nao encontrado.' }
[IO.Directory]::CreateDirectory($StartupDirectory) | Out-Null
$shell=New-Object -ComObject WScript.Shell
try {
 $shortcut=$shell.CreateShortcut((Join-Path $StartupDirectory 'AIBattery.lnk'))
 $shortcut.TargetPath=$spec.TargetPath;$shortcut.Arguments=$spec.Arguments;$shortcut.WorkingDirectory=$spec.WorkingDirectory;$shortcut.WindowStyle=7;$shortcut.Description='Painel lateral de consumo Codex, Claude e Gemini';$shortcut.Save()
 Write-Output 'Inicializacao automatica ativada para este usuario.'
} finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
