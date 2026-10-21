param([string[]]$ShortcutDirectories=@([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('Programs')))
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\src\Desktop.psm1" -DisableNameChecking
Initialize-DesktopIntegration
$launcher=Join-Path $PSScriptRoot 'AI Battery.exe';if (-not (Test-Path -LiteralPath $launcher)) {throw 'Execute Build-Launcher.ps1 primeiro.'}
$shell=New-Object -ComObject WScript.Shell
try {
 foreach ($directory in $ShortcutDirectories) {
  [IO.Directory]::CreateDirectory($directory) | Out-Null;$linkPath=Join-Path $directory 'AI Battery.lnk';$link=$shell.CreateShortcut($linkPath)
  $link.TargetPath=$launcher;$link.WorkingDirectory=$PSScriptRoot;$link.IconLocation=(Join-Path $PSScriptRoot 'assets\AI-Battery.ico')+',0';$link.Description='Abrir ou recolher painel de consumo de IA';$link.Save()
  [AIBattery.DesktopIntegration]::SetShortcutIdentity($linkPath)
  Write-Output $linkPath
 }
} finally {[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
