function Initialize-DesktopIntegration {
 if (-not ('AIBattery.DesktopIntegration' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'DesktopIntegration.cs')}
}
# Lives here because the detection runspace imports only Detection and Desktop.
function Test-CodexWindowReady($Windows) {return (@($Windows | Where-Object {$_.Visible -and -not $_.Minimized}).Count -gt 0)}
function Set-DesktopAppIdentity {Initialize-DesktopIntegration;[AIBattery.DesktopIntegration]::SetProcessIdentity()}
function Set-DesktopWindowIdentity($Window) {
 Initialize-DesktopIntegration;$root=Split-Path $PSScriptRoot -Parent;$launcher=Join-Path $root 'AI Battery.exe'
 if (Test-Path $launcher) {[AIBattery.DesktopIntegration]::SetWindowIdentity([Windows.Interop.WindowInteropHelper]::new($Window).Handle,$launcher,(Join-Path $root 'assets\AI-Battery.ico'))}
}
Export-ModuleMember -Function *
