Import-Module "$PSScriptRoot\..\src\Core.psm1" -Force
Import-Module "$PSScriptRoot\..\src\Providers.psm1" -Force
Import-Module "$PSScriptRoot\..\src\Collection.psm1" -Force
Test 'Subscription policy blocks API and secrets before legacy configured billing branches' {
 $module=Get-Module Providers
 & $module { $script:SecretCalls=0;$script:ApiCalls=0;function script:Read-ProviderSecret {$script:SecretCalls++;throw 'Secret must not be read'};function script:Get-ApiCostMeasure {$script:ApiCalls++;throw 'Billing must not run'} }
 foreach ($id in @('claude','gemini')) {
  foreach ($refresh in @($false,$true)) {
   $settings=@{Id=$id;SubscriptionMode='manual';ManualSubscription=@{RemainingPercent=73;UpdatedAtUtc='2026-10-18T10:00:00Z'};ApiMode='auto';GeminiQueryEnabled=$true;GeminiProjectId='fixture';GeminiBillingTable='fixture.billing.export'}
   $snapshot=Get-ProviderSnapshot $settings @{Policy='subscriptionOnly';NowUtc=[datetimeoffset]'2026-10-18T10:01:00Z';ForceRefresh=$refresh}
   Assert-Equal $snapshot.Api.Status 'unavailable';Assert-Equal $snapshot.Api.SpentMonthUsd $null;Assert-Equal $snapshot.Subscription.RemainingPercent 73
  }
 }
 Assert-Equal (& $module {$script:SecretCalls}) 0;Assert-Equal (& $module {$script:ApiCalls}) 0
 Import-Module "$PSScriptRoot\..\src\Providers.psm1" -Force
}
Test 'Subscription policy does not carry forward stale API totals or manual billing' {
 $s=Get-ProviderSnapshot @{Id='claude';SubscriptionMode='manual';ManualSubscription=@{RemainingPercent=50;UpdatedAtUtc='2026-10-18T10:00:00Z'};ApiMode='manual';ManualApi=@{SpentMonthUsd=89;UpdatedAtUtc='2026-10-18T10:00:00Z'}} @{Policy='subscriptionOnly';NowUtc=[datetimeoffset]'2026-10-18T10:01:00Z';Previous=@{Api=@{Status='connected';SpentMonthUsd=123;ObservedAtUtc='2026-10-18T10:00:00Z'}}}
 Assert-Equal $s.Api.SpentMonthUsd $null;Assert-Equal $s.Api.Status 'unavailable'
}
Test 'Policy disabled API cannot resurrect older spend through failure retention' {
 $old=@{Status='connected';RemainingPercent=11;SpentMonthUsd=89;ObservedAtUtc='2026-10-18T10:00:00Z'}
 $current=@{Status='unavailable';Source='Assinaturas somente';Policy='subscriptionOnly';SpentMonthUsd=$null;RemainingPercent=$null;ObservedAtUtc=$null}
 $merged=Merge-MeasureFailure $old $current
 Assert-Equal $merged.Status 'unavailable';Assert-Equal $merged.SpentMonthUsd $null;Assert-Equal $merged.RemainingPercent $null
}
Test 'Collection runspace applies subscriptionOnly for manual refresh' {
 $settings=@{Id='claude';SubscriptionMode='manual';ManualSubscription=@{RemainingPercent=60;UpdatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')};ApiMode='manual';ManualApi=@{SpentMonthUsd=88;UpdatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}}
 try {
  Assert-True (Start-CollectionJob 'claude' $settings 5 $null $true 'subscriptionOnly')
  $deadline=[datetimeoffset]::UtcNow.AddSeconds(10);$results=@()
  while (-not $results.Count -and [datetimeoffset]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 40;$results=@(Receive-CollectionJobs)}
  Assert-Equal $results.Count 1;Assert-Equal $results[0].Snapshot.Subscription.RemainingPercent 60;Assert-Equal $results[0].Snapshot.Api.Status 'unavailable';Assert-Equal $results[0].Snapshot.Api.SpentMonthUsd $null
 } finally {Stop-CollectionJobs}
}
Test 'Panel manual refresh keeps legacy billing disabled in unified and fallback modes' {
 $tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Start-AIBattery.ps1'),[ref]$tokens,[ref]$errors)
 foreach ($name in @('Refresh-PanelProvider','Invoke-PanelTick')) {
  $node=$tree.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
  . ([scriptblock]::Create($node.Extent.Text))
 }
 function Receive-DetectionJob {}
 function Update-PanelRuntime {}
 function Update-Sidebar {}
 function Update-LiveReportClock {}
 function Repair-WindowPlacement {}
 function Clear-RecoveredProviderAlert {}
 $stopEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset);$toggleEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset)
 try {
  foreach ($source in @('unified','local')) {
   $provider=@{Id='claude';SubscriptionMode='manual';ManualSubscription=@{RemainingPercent=60;UpdatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')};ApiMode='manual';ManualApi=@{SpentMonthUsd=88;UpdatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}}
   $old=New-ProviderSnapshot 'claude';$old.Api.Status='connected';$old.Api.SpentMonthUsd=77;$old.Api.RemainingPercent=23
   $script:State=@{Closing=$false;Runtime=@{Source=$source};CollectionPolicy='subscriptionOnly';Generation=1;ActiveIds=@('claude');Settings=@{Providers=@($provider)};Snapshots=@{claude=$old};NextCollection=@{};LastCollection=@{};Failures=@{claude=0};Alerts=@{};ForceRefresh=@{};DetectionJob=@{Pending=$true};DetectionAt=[datetimeoffset]::UtcNow}
   Refresh-PanelProvider 'claude';Invoke-PanelTick
   $deadline=[datetimeoffset]::UtcNow.AddSeconds(5)
   while (-not $script:State.LastCollection.claude -and [datetimeoffset]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 20;Invoke-PanelTick}
   Assert-True ($null -ne $script:State.LastCollection.claude);Assert-Equal $script:State.Snapshots.claude.Subscription.RemainingPercent 60
   Assert-Equal $script:State.Snapshots.claude.Api.Status 'unavailable';Assert-Equal $script:State.Snapshots.claude.Api.SpentMonthUsd $null
  }
 } finally {Stop-CollectionJobs;$stopEvent.Dispose();$toggleEvent.Dispose()}
}
