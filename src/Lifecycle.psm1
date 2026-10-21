function Get-MonitorMutexName { return ('Local\AIBattery.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
function Get-MonitorEventName([string]$Action) {if ($Action -notin @('Toggle','Stop')) {throw 'Comando invalido.'};return ('Local\AIBattery.'+$Action+'.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
function Send-MonitorCommand([string]$Action) {
 $event=$null
 try {$event=[Threading.EventWaitHandle]::OpenExisting((Get-MonitorEventName $Action));[void]$event.Set();return $true} catch [Threading.WaitHandleCannotBeOpenedException] {return $false} finally {if ($event) {$event.Dispose()}}
}
function Get-StartupShortcutSpec([string]$ScriptPath) {
 if ($ScriptPath.Contains('"')) { throw 'Caminho invalido.' }
 return @{TargetPath=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "'+$ScriptPath+'"');WorkingDirectory=(Split-Path -Parent $ScriptPath)}
}
Export-ModuleMember -Function *
