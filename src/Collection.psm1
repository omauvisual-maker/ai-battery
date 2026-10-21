$script:Jobs=@{}
$script:Children=[hashtable]::Synchronized(@{})
function Test-CollectionResultCurrent($Result,[int]$Generation,$LastStartedUtc) {
 return ($Result.Generation -eq $Generation -and (-not $LastStartedUtc -or [datetimeoffset]$Result.StartedUtc -ge [datetimeoffset]$LastStartedUtc))
}
function Merge-MeasureFailure($Previous,$Current) {
 if ($Current.Policy -eq 'subscriptionOnly') {return $Current}
 if ($Current.Status -in @('error','unavailable') -and $Previous -and ($null -ne $Previous.RemainingPercent -or $null -ne $Previous.SpentMonthUsd)) {
  $copy=@{}; foreach ($key in $Previous.Keys) { $copy[$key]=$Previous[$key] }; $copy.Status='stale';$copy.Message=$Current.Message;$copy.RetryAfter=$Current.RetryAfter;return $copy
 }
 return $Current
}
function Get-RetryDelay([int]$Failures,[int]$RetryAfter=0) { return [int][math]::Min(900,[math]::Max($RetryAfter,60*[math]::Pow(2,[math]::Min(4,[math]::Max(0,$Failures-1))))) }
function Test-ProviderCollectionFailed($Snapshot) { return ($Snapshot.Api.Status -in @('error','stale') -or $Snapshot.Subscription.Status -in @('error','stale')) }
function Request-ProviderRefresh($State,[string]$Id) { if ($Id) {$State.NextCollection[$Id]=[datetimeoffset]::MinValue;$State.ForceRefresh[$Id]=$true} }
function Start-CollectionJob([string]$ProviderId,$Settings,[int]$Generation,$Previous=$null,[bool]$ForceRefresh=$false,[ValidateSet('legacy','subscriptionOnly')][string]$Policy='legacy') {
 if ($script:Jobs.ContainsKey($ProviderId)) { return $false }
 $root=$PSScriptRoot;$started=[datetimeoffset]::UtcNow
 $ps=[powershell]::Create()
 [void]$ps.AddScript({param($root,$settings,$previous,$children,$forceRefresh,$policy)
  $ErrorActionPreference='Stop'; Import-Module (Join-Path $root 'Providers.psm1') -DisableNameChecking
  Get-ProviderSnapshot $settings @{NowUtc=[datetimeoffset]::UtcNow;Previous=$previous;Children=$children;ForceRefresh=$forceRefresh;Policy=$policy}
 }).AddArgument($root).AddArgument($Settings).AddArgument($Previous).AddArgument($script:Children).AddArgument($ForceRefresh).AddArgument($Policy)
 $handle=$ps.BeginInvoke()
 $script:Jobs[$ProviderId]=@{PS=$ps;Handle=$handle;StartedUtc=$started;Generation=$Generation;TimedOut=$false}
 return $true
}
function Receive-CollectionJobs {
 foreach ($id in @($script:Jobs.Keys)) {
  $job=$script:Jobs[$id]
  if (-not $job.Handle.IsCompleted) {
   if (-not $job.TimedOut -and [datetimeoffset]::UtcNow-$job.StartedUtc -gt [timespan]::FromSeconds(45)) { $job.TimedOut=$true;[void]$job.PS.BeginStop($null,$null) }
   continue
  }
  try {
   $out=$job.PS.EndInvoke($job.Handle)
   if ($job.PS.HadErrors -or $out.Count -ne 1) { throw 'Falha no coletor.' }
   $snapshot=$out[0].BaseObject; if (-not $snapshot) { $snapshot=$out[0] }
   @{ProviderId=$id;Generation=$job.Generation;StartedUtc=$job.StartedUtc;Snapshot=$snapshot}
  } catch { @{ProviderId=$id;Generation=$job.Generation;StartedUtc=$job.StartedUtc;Snapshot=$null;Error='Coleta nao concluida.'} }
  finally { $job.PS.Dispose(); $script:Jobs.Remove($id) }
 }
}
function Stop-CollectionJobs {
 foreach ($job in $script:Jobs.Values) { try { [void]$job.PS.BeginStop($null,$null) } catch {} }
 foreach ($key in @($script:Children.Keys)) { $p=$script:Children[$key];try { if (-not $p.HasExited) { $p.Kill() } } catch {} }
 $script:Jobs=@{}
}
Export-ModuleMember -Function *
