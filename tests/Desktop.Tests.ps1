Import-Module "$PSScriptRoot\..\src\Desktop.psm1" -Force -DisableNameChecking
Test 'Native launcher is a windowed executable' { $bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\AI Battery.exe'));Assert-Equal ([Text.Encoding]::ASCII.GetString($bytes,0,2)) 'MZ';$pe=[BitConverter]::ToInt32($bytes,60);Assert-Equal ([BitConverter]::ToUInt16($bytes,$pe+24+68)) 2 }
Test 'Shortcut has dedicated taskbar identity' { $dir=Join-Path $env:TEMP ([guid]::NewGuid().ToString());try {& "$PSScriptRoot\..\Install-Desktop.ps1" -ShortcutDirectories @($dir);Initialize-DesktopIntegration;$path=Join-Path $dir 'AI Battery.lnk';Assert-Equal ([AIBattery.DesktopIntegration]::GetShortcutIdentity($path)) 'AIBattery.Desktop';$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($path);Assert-True ($link.TargetPath -match 'AI Battery.exe$');Assert-True ($link.IconLocation -match 'AI-Battery.ico');[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)} finally {if (Test-Path $dir) {Remove-Item -LiteralPath $dir -Recurse -Force}} }
Test 'Detection job modules provide every command the job calls' {
 $root=Split-Path $PSScriptRoot -Parent;$ps=[powershell]::Create()
 try {
  [void]$ps.AddScript({param($root) Import-Module (Join-Path $root 'src\Detection.psm1') -DisableNameChecking;Import-Module (Join-Path $root 'src\Desktop.psm1') -DisableNameChecking
   @('Find-InstalledProviderRules','Get-ProcessInventory','Get-PackageProviderRule','Get-ScriptProviderRule','Resolve-ActiveProviders','Initialize-DesktopIntegration','Test-CodexWindowReady') | Where-Object {-not (Get-Command $_ -ErrorAction SilentlyContinue)}
  }).AddArgument($root)
  $missing=@($ps.Invoke());Assert-Equal ($missing -join ',') ''
 } finally { $ps.Dispose() }
}
