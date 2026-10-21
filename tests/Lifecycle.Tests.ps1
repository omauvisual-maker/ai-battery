Import-Module "$PSScriptRoot\..\src\Lifecycle.psm1" -Force
Test 'Startup quotes paths with spaces and hides console' { $s=Get-StartupShortcutSpec 'C:\My Apps\Start-AIBattery.ps1';Assert-True ($s.Arguments.Contains('"C:\My Apps\Start-AIBattery.ps1"'));Assert-True ($s.Arguments.Contains('-WindowStyle Hidden'));Assert-True ($s.Arguments.Contains('-STA')) }
Test 'Installer idempotent and removes only its own shortcut' {
 $dir=Join-Path $env:TEMP ([guid]::NewGuid().ToString());[IO.Directory]::CreateDirectory($dir) | Out-Null
 try {
  [IO.File]::WriteAllText((Join-Path $dir 'keep.txt'),'keep')
  & "$PSScriptRoot\..\Install-Startup.ps1" -StartupDirectory $dir
  & "$PSScriptRoot\..\Install-Startup.ps1" -StartupDirectory $dir
  Assert-Equal @(Get-ChildItem $dir -Filter '*.lnk').Count 1
  $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut((Join-Path $dir 'AIBattery.lnk'));Assert-True ($link.Arguments.Contains('Start-AIBattery.ps1'));Assert-True ($link.TargetPath -match 'powershell.exe$')
  & "$PSScriptRoot\..\Uninstall-Startup.ps1" -StartupDirectory $dir
  Assert-True (Test-Path (Join-Path $dir 'keep.txt'));Assert-Equal @(Get-ChildItem $dir -Filter '*.lnk').Count 0
 } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
Test 'Mutex is namespaced by current user' { Assert-True ((Get-MonitorMutexName) -match '^Local\\AIBattery\.S-1-') }
Test 'Launcher commands use user-scoped events' { Assert-True ((Get-MonitorEventName 'Toggle') -match '^Local\\AIBattery\.Toggle\.S-1-');Assert-True ((Get-MonitorEventName 'Stop') -match '^Local\\AIBattery\.Stop\.S-1-');Assert-Throws {Get-MonitorEventName 'Unknown'} }
