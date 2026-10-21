param([switch]$NoStartup,[switch]$Diagnostics,[switch]$ShowPanel,[int]$RunForSeconds=0)
$ErrorActionPreference='Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Inicie com powershell.exe -STA.' }
foreach ($module in @('Core','Settings','Detection','Collection','Desktop','UI','Lifecycle','Telemetry','RuntimeClient')) { Import-Module (Join-Path $PSScriptRoot "src\$module.psm1") -DisableNameChecking }
Set-DesktopAppIdentity
$mutex=[Threading.Mutex]::new($false,(Get-MonitorMutexName));$owns=$false
try { $owns=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns=$true }
if (-not $owns) { if ($ShowPanel) {[void](Send-MonitorCommand 'Toggle')};if ($Diagnostics) { Write-Output 'Monitor ja esta em execucao.' };$mutex.Dispose();exit 0 }
$toggleEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,(Get-MonitorEventName 'Toggle'))
$stopEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,(Get-MonitorEventName 'Stop'))
$script:State=@{Root=$PSScriptRoot;Settings=$null;Snapshots=@{};ActiveIds=@();Rules=@();Generation=1;NextCollection=@{};LastCollection=@{};Failures=@{};Alerts=@{};ForceRefresh=@{};DetectionJob=$null;DetectionAt=[datetimeoffset]::MinValue;LastRuleScan=[datetimeoffset]::MinValue;Closing=$false;UI=$null;Timer=$null;App=$null}
$script:State.Telemetry=New-TelemetryState
$script:State.Runtime=New-RuntimeClientState
$script:State.CollectionPolicy='subscriptionOnly'
function Save-PanelSettings($Settings) {
 $providersChanged=Test-ProviderSettingsChanged $script:State.Settings $Settings
 $path=Join-Path (Get-AppDataDirectory) 'settings.json';Write-AppSettings $path $Settings
 $script:State.Settings=$Settings;if (-not $providersChanged) {return};$script:State.Generation++;$script:State.LastRuleScan=[datetimeoffset]::MinValue
 foreach ($id in @('codex','claude','gemini')) {$script:State.NextCollection[$id]=[datetimeoffset]::MinValue;$script:State.Snapshots[$id]=New-ProviderSnapshot $id;$script:State.Failures[$id]=0}
}
function Refresh-PanelProvider([string]$Id) {
 Request-ProviderRefresh $script:State $Id
 $script:State.Runtime.LastPollAt=[datetimeoffset]::MinValue
}
function Stop-PanelMonitor {
 $script:State.Closing=$true;$script:State.Timer.Stop();Stop-RuntimePoll $script:State.Runtime;Stop-CollectionJobs
 if ($script:State.DetectionJob) { try { [void]$script:State.DetectionJob.PS.BeginStop($null,$null) } catch {} }
 Close-AppWindows;$script:State.App.Shutdown()
}
function Start-DetectionJob {
 $scan=([datetimeoffset]::UtcNow-$script:State.LastRuleScan -gt [timespan]::FromSeconds(30))
 $ps=[powershell]::Create()
 [void]$ps.AddScript({param($root,$scan,$existing,$settings)
  $ErrorActionPreference='Stop';Import-Module (Join-Path $root 'src\Detection.psm1') -DisableNameChecking
  $rules=if ($scan) {@(Find-InstalledProviderRules)} else {@($existing)}
  $inventory=@(Get-ProcessInventory)
  $packageRules=@(foreach ($process in $inventory) {$packageRule=Get-PackageProviderRule $process.ExecutablePath;if ($packageRule) {$packageRule};$scriptRule=Get-ScriptProviderRule $process;if ($scriptRule) {$scriptRule}})
  $all=@($rules)+@($settings.Providers | ForEach-Object {$_.DetectionRules} | Where-Object {$_})+@($packageRules)
  $ids=@(Resolve-ActiveProviders $inventory $all)
  Import-Module (Join-Path $root 'src\Desktop.psm1') -DisableNameChecking
  Initialize-DesktopIntegration
  $paths=@($all | Where-Object {$_.ProviderId -eq 'codex' -and $_.Kind -eq 'desktop'} | ForEach-Object {$_.ExecutablePath})
  $processIds=@($inventory | Where-Object {$_.ExecutablePath -in $paths -and -not $_.IsHelper} | ForEach-Object {[int]$_.Id})
  $ready=Test-CodexWindowReady ([AIBattery.DesktopIntegration]::ReadWindows([int[]]$processIds))
  @{ActiveIds=$ids;Rules=$rules;AllRules=$all;Scanned=$scan;CodexReady=$ready}
 }).AddArgument($script:State.Root).AddArgument($scan).AddArgument($script:State.Rules).AddArgument($script:State.Settings)
 $script:State.DetectionJob=@{PS=$ps;Handle=$ps.BeginInvoke();Started=[datetimeoffset]::UtcNow;Generation=$script:State.Generation;TimedOut=$false}
 $script:State.DetectionAt=[datetimeoffset]::UtcNow
}
function Receive-DetectionJob {
 $job=$script:State.DetectionJob;if (-not $job) {return}
 if (-not $job.Handle.IsCompleted) {
  if (-not $job.TimedOut -and [datetimeoffset]::UtcNow-$job.Started -gt [timespan]::FromSeconds(10)) {$job.TimedOut=$true;[void]$job.PS.BeginStop($null,$null)}
  return
 }
 try {
  $out=$job.PS.EndInvoke($job.Handle)
  if ($job.PS.HadErrors -or $out.Count -ne 1) { throw 'Deteccao indisponivel.' }
  $r=$out[0];if ($job.Generation -ne $script:State.Generation) {return}
  $script:State.ActiveIds=@($r.ActiveIds);$script:State.Rules=@($r.Rules)
  Set-CodexWindowVisibility ([bool]$r.CodexReady)
  if ($r.Scanned) {$script:State.LastRuleScan=[datetimeoffset]::UtcNow}
  foreach ($id in @('codex','claude','gemini')) {
   $path=$r.AllRules | Where-Object { $_.ProviderId -eq $id -and $_.Kind -eq 'desktop' } | Select-Object -First 1
   if ($path) {$script:State.UI.RulePaths[$id]=$path.ExecutablePath}
  }
 } catch { if ($Diagnostics) {[Console]::WriteLine('Deteccao temporariamente indisponivel: '+$_.Exception.Message)} }
 finally { $job.PS.Dispose();$script:State.DetectionJob=$null }
}
function Update-PanelRuntime {
 $runtime=$script:State.Runtime
 $snapshot=Receive-RuntimePoll $runtime
 if ($snapshot) {$runtime.PendingSnapshot=$snapshot}
 if ($runtime.PendingSnapshot) {
  # Invalidate local results first, then asynchronously stop and drain the reader.
  [void](Set-RuntimeSource $runtime 'unified')
  [void](Stop-RuntimeLocalCollection $runtime)
 }
 $local=Receive-RuntimeLocalCollection $runtime
 if ($runtime.PendingSnapshot -and -not $runtime.LocalPoll) {
  $report=ConvertTo-OperationsReport $runtime.PendingSnapshot
  if (Set-RuntimeOperationsReport $runtime $report 'unified' $runtime.Generation) {Set-OperationsReport $report}
  $runtime.PendingSnapshot=$null
 } elseif ($local) {Set-OperationsReport $local}
 if ($runtime.Report) {$runtime.Report.Stale=[bool]$runtime.Stale}
 if ($runtime.Source -eq 'local') {[void](Start-RuntimeLocalCollection $runtime $script:State.Telemetry)}
 [void](Start-RuntimePoll $runtime)
}
function Invoke-PanelTick {
 if ($script:State.Closing) {return}
 try {
  if ($stopEvent.WaitOne(0)) {Stop-PanelMonitor;return}
  if ($toggleEvent.WaitOne(0)) {Toggle-PanelVisibility}
  Receive-DetectionJob
  Update-PanelRuntime
  if (-not $script:State.DetectionJob -and [datetimeoffset]::UtcNow-$script:State.DetectionAt -ge [timespan]::FromSeconds(2)) {Start-DetectionJob}
  foreach ($result in @(Receive-CollectionJobs)) {
   $id=$result.ProviderId
   if (-not (Test-CollectionResultCurrent $result $script:State.Generation $script:State.LastCollection[$id])) {continue}
   $old=$script:State.Snapshots[$id];$new=$result.Snapshot
   if (-not $new) {$new=New-ProviderSnapshot $id;$new.Subscription.Status='error';$new.Api.Status='error'}
   foreach ($measure in @('Subscription','Api')) {
    $new[$measure]=Merge-MeasureFailure $old[$measure] $new[$measure]
    $key=Get-MeasureAlertKey $id $measure $new[$measure] ([datetimeoffset]::UtcNow)
    $armed=if ($script:State.Alerts.ContainsKey($key)) {$script:State.Alerts[$key]} else {$true}
    $transition=Get-AlertTransition $old[$measure] $new[$measure] $armed;$script:State.Alerts[$key]=$transition.Armed
    if ($transition.Notify) {Set-ProviderAlert $id ((Get-ProviderName $id)+': '+(Get-PercentText $new[$measure].RemainingPercent)+' restante ('+$measure+')') $measure}
   }
   $script:State.Snapshots[$id]=$new;$script:State.LastCollection[$id]=$result.StartedUtc
   Clear-RecoveredProviderAlert $id $new
   $failed=Test-ProviderCollectionFailed $new
   if ($failed) {$script:State.Failures[$id]++} else {$script:State.Failures[$id]=0}
   $delay=if ($failed) {Get-RetryDelay $script:State.Failures[$id] ([int]$new.Api.RetryAfter)} else {120}
   $script:State.NextCollection[$id]=[datetimeoffset]::UtcNow.AddSeconds($delay)
  }
  foreach ($id in $script:State.ActiveIds) {
   if (-not $script:State.NextCollection[$id] -or [datetimeoffset]::UtcNow -ge $script:State.NextCollection[$id]) {
    $p=$script:State.Settings.Providers | Where-Object Id -eq $id | Select-Object -First 1
    $started=Start-CollectionJob $id $p $script:State.Generation $script:State.Snapshots[$id] ([bool]$script:State.ForceRefresh[$id]) $script:State.CollectionPolicy;if ($started) {$script:State.ForceRefresh[$id]=$false}
   }
   foreach ($kind in @('Subscription','Api')) {
    $m=$script:State.Snapshots[$id][$kind];$seconds=if ($kind -eq 'Subscription') {120} else {600}
    if ($m.Status -eq 'connected' -and -not $m.IsManual -and $m.ObservedAtUtc -and [datetimeoffset]::UtcNow-[datetimeoffset]$m.ObservedAtUtc -gt [timespan]::FromSeconds($seconds)) {$m.Status='stale';$m.Message='Aguardando nova leitura.'}
   }
  }
  Update-Sidebar $script:State.ActiveIds $script:State.Snapshots
  Update-LiveReportClock
  Repair-WindowPlacement
 } catch { if ($Diagnostics) { [Console]::WriteLine('Monitor: '+$_.Exception.Message) } }
}
try {
 $script:State.Settings=Read-AppSettings
 foreach ($id in @('codex','claude','gemini')) {$script:State.Snapshots[$id]=New-ProviderSnapshot $id;$script:State.Failures[$id]=0}
 $script:State.UI=New-AppWindows $script:State.Settings {param($s) Save-PanelSettings $s} {Stop-PanelMonitor} {param($id) Refresh-PanelProvider $id}
 $script:State.UI.CodexReady=$false;$script:State.UI.AutoStartReport=$true
 $app=[Windows.Application]::new();$app.ShutdownMode='OnExplicitShutdown';$script:State.App=$app
 $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[timespan]::FromMilliseconds(500);$timer.Add_Tick({Invoke-PanelTick});$script:State.Timer=$timer
 $script:StopAt=if ($RunForSeconds -gt 0) {[datetimeoffset]::UtcNow.AddSeconds($RunForSeconds)} else {$null}
 if ($RunForSeconds -gt 0) { $timer.Add_Tick({ if ([datetimeoffset]::UtcNow -ge $script:StopAt) { if ($Diagnostics) { $safe=@{ActiveIds=$script:State.ActiveIds;Providers=@(foreach ($id in $script:State.ActiveIds) {@{Id=$id;SubscriptionStatus=$script:State.Snapshots[$id].Subscription.Status;RemainingPercent=$script:State.Snapshots[$id].Subscription.RemainingPercent;ApiStatus=$script:State.Snapshots[$id].Api.Status}});SidebarVisible=$script:State.UI.Sidebar.IsVisible;CodexWindowReady=$script:State.UI.CodexReady;OperationTurns=@($script:State.UI.OperationsReport.Turns).Count;OperationTurnsWithTokens=@($script:State.UI.OperationsReport.Turns | Where-Object {$null -ne $_.TotalTokens}).Count};[Console]::WriteLine(($safe | ConvertTo-Json -Depth 5)) };Stop-PanelMonitor } }) }
 if ($ShowPanel) {Toggle-PanelVisibility}
 Start-DetectionJob;[void](Start-RuntimePoll $script:State.Runtime);$timer.Start();[void]$app.Run()
} catch {
 if ($Diagnostics) {Write-Output $_.Exception.Message}
 try { Add-Type -AssemblyName PresentationFramework;[void][Windows.MessageBox]::Show('O painel nao iniciou. Verifique a configuracao local ou execute com -Diagnostics.','AI Battery') } catch {}
 exit 1
} finally {
 Stop-RuntimePoll $script:State.Runtime
 Stop-CollectionJobs
 $toggleEvent.Dispose();$stopEvent.Dispose()
 if ($owns) {$mutex.ReleaseMutex()};$mutex.Dispose()
}
