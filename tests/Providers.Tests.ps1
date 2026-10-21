Import-Module "$PSScriptRoot\..\src\Core.psm1" -Force
Import-Module "$PSScriptRoot\..\src\Providers.psm1" -Force
Test 'Unconfigured API is unknown' { $s=Get-ProviderSnapshot @{Id='claude';ApiMode='auto';SubscriptionMode='auto'} @{NowUtc=[datetimeoffset]::UtcNow;Secret=$null}; Assert-Equal $s.Api.Status 'unconfigured'; Assert-Equal $s.Api.RemainingPercent $null }
Test 'Manual retains observation time and budget' {
 $s=Get-ProviderSnapshot @{Id='claude';ApiMode='manual';SubscriptionMode='manual';ApiMonthlyBudgetUsd=100;ManualSubscription=@{RemainingPercent=18;UpdatedAtUtc='2026-10-11T12:00:00Z'};ManualApi=@{SpentMonthUsd=80;UpdatedAtUtc='2026-10-11T12:00:00Z'}} @{NowUtc=[datetimeoffset]'2026-10-11T13:00:00Z'}
 Assert-Equal $s.Api.RemainingPercent 20; Assert-Equal $s.Subscription.RemainingPercent 18; Assert-Equal $s.Subscription.ObservedAtUtc '2026-10-11T12:00:00Z'; Assert-True $s.Api.IsManual
}
Test 'Manual previous month not carried forward' { $s=Get-ProviderSnapshot @{Id='claude';ApiMode='manual';SubscriptionMode='auto';ApiMonthlyBudgetUsd=100;ManualApi=@{SpentMonthUsd=80;UpdatedAtUtc='2026-09-11T12:00:00Z'}} @{NowUtc=[datetimeoffset]'2026-10-11T13:00:00Z'}; Assert-Equal $s.Api.Status 'stale'; Assert-Equal $s.Api.RemainingPercent $null }
Test 'OpenAI dollar amount and pagination' {
 $script:pages=0
 $client={param($uri,$headers,$body) $script:pages++; if ($script:pages -eq 1) { return @{data=@(@{start_time=1791687600;end_time=1791774000;results=@(@{amount=@{currency='usd';value=3.5}})});has_more=$true;next_page='p2'} }; return @{data=@(@{start_time=1791774000;end_time=1791860400;results=@(@{amount=@{currency='usd';value=1.5}})});has_more=$false;next_page=$null} }
 $m=Get-ApiCostMeasure 'codex' @{ApiMonthlyBudgetUsd=100} @{NowUtc=[datetimeoffset]'2026-10-12T15:00:00Z';Secret=(ConvertTo-SecureString 'test' -AsPlainText -Force);HttpClient=$client}
 Assert-Equal $m.SpentMonthUsd 5; Assert-Equal $m.RemainingPercent 95; Assert-Equal $script:pages 2
}
Test 'Claude cents and schema validation' {
 $client={param($uri,$headers,$body) @{data=@(@{starting_at='2026-10-11T00:00:00Z';ending_at='2026-10-12T00:00:00Z';results=@(@{currency='USD';amount='1234'})});has_more=$false;next_page=$null} }
 $m=Get-ApiCostMeasure 'claude' @{ApiMonthlyBudgetUsd=100} @{NowUtc=[datetimeoffset]'2026-10-12T15:00:00Z';Secret=(ConvertTo-SecureString 'test' -AsPlainText -Force);HttpClient=$client}
 Assert-Equal $m.SpentMonthUsd 12.34
 Assert-Throws { Get-ApiCostMeasure 'claude' @{} @{NowUtc=[datetimeoffset]::UtcNow;Secret=(ConvertTo-SecureString 'test' -AsPlainText -Force);HttpClient={@{oops=1}}} }
}
Test 'Codex known bucket only and lowest window' { $m=Convert-CodexLimits @{rateLimitsByLimitId=@{codex=@{primary=@{usedPercent=30;windowDurationMins=300;resetsAt=1791800000};secondary=@{usedPercent=85;windowDurationMins=10080;resetsAt=1791900000}};other=@{primary=@{usedPercent=99}}}} ([datetimeoffset]'2026-10-11T13:00:00Z'); Assert-Equal $m.RemainingPercent 15; Assert-True ($m.Source -match '10080') }
Test 'Missing Codex limits remain unavailable' { Assert-Equal (Convert-CodexLimits @{rateLimits=$null} ([datetimeoffset]::UtcNow)).Status 'unavailable' }
Test 'Misaligned month does not claim exact percentage' {
 $client={param($uri,$headers,$body) @{data=@(@{start_time=([datetimeoffset]'2026-10-01T00:00:00Z').ToUnixTimeSeconds();end_time=([datetimeoffset]'2026-10-02T00:00:00Z').ToUnixTimeSeconds();results=@(@{amount=@{currency='usd';value=90}})});has_more=$false;next_page=$null} }
 $m=Get-ApiCostMeasure 'codex' @{ApiMonthlyBudgetUsd=100} @{NowUtc=[datetimeoffset]'2026-10-11T13:00:00Z';Secret=(ConvertTo-SecureString 'test' -AsPlainText -Force);HttpClient=$client}
 Assert-Equal $m.RemainingPercent $null;Assert-True ([datetimeoffset]$m.PeriodStartUtc -eq [datetimeoffset]'2026-10-01T00:00:00Z');Assert-True ($m.Message -match 'fronteira')
}
Test 'Old Gemini export stays stale and cannot alert' {
 $client={param($uri,$headers,$body) @{jobComplete=$true;rows=@(@{f=@(@{v='90'},@{v='1'},@{v=([datetimeoffset]'2026-10-02T00:00:00Z').ToUnixTimeSeconds().ToString()},@{v='0'})})} }
 $m=Get-ApiCostMeasure 'gemini' @{ApiMonthlyBudgetUsd=100;GeminiQueryEnabled=$true;GeminiProjectId='test-project';GeminiBillingTable='test-project.billing.export'} @{NowUtc=[datetimeoffset]'2026-10-11T13:00:00Z';Secret=(ConvertTo-SecureString 'test' -AsPlainText -Force);HttpClient=$client}
 Assert-Equal $m.Status 'stale';Assert-Equal (Get-AlertTransition $null $m $true).Notify $false
}
