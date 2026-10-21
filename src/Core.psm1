function Get-ApiRemainingPercent($BudgetUsd,$SpentUsd) {
 if ($null -eq $BudgetUsd -or $BudgetUsd -le 0 -or $null -eq $SpentUsd) { return $null }
 $SpentUsd=[double]$SpentUsd; $BudgetUsd=[double]$BudgetUsd
 if ($SpentUsd -lt 0 -or [double]::IsNaN($SpentUsd) -or [double]::IsInfinity($SpentUsd) -or [double]::IsNaN($BudgetUsd) -or [double]::IsInfinity($BudgetUsd)) { throw 'Gasto ou orcamento invalido.' }
 return [math]::Round([math]::Max(0,[math]::Min(100,100*(1-$SpentUsd/$BudgetUsd))),1)
}
function Get-SubscriptionRemainingPercent([object[]]$Limits) {
 $values=@($Limits | Where-Object { $null -ne $_.usedPercent -and $_.usedPercent -ge 0 -and $_.usedPercent -le 100 } | ForEach-Object { 100-[double]$_.usedPercent })
 if (-not $values.Count) { return $null }; return ($values | Measure-Object -Minimum).Minimum
}
function Get-BatteryColor($Remaining) {
 if ($null -eq $Remaining) { return '#78849A' }; if ($Remaining -le 20) { return '#FF747C' }; if ($Remaining -le 40) { return '#F5C76B' }; return '#5EE0A0'
}
function Get-AlertTransition($Previous,$Current,[bool]$Armed) {
 $notify=$false
 if ($Current.Status -eq 'connected' -and $null -ne $Current.RemainingPercent) {
   if ($Current.RemainingPercent -gt 20) { $Armed=$true }
   elseif ($Armed) { $notify=$true; $Armed=$false }
 }
 return @{Notify=$notify;Armed=$Armed}
}
function Get-BillingPeriod([datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
 $zone=[TimeZoneInfo]::FindSystemTimeZoneById('E. South America Standard Time')
 $local=[TimeZoneInfo]::ConvertTime($Now,$zone)
 $month=[datetime]::SpecifyKind([datetime]::new($local.Year,$local.Month,1),[DateTimeKind]::Unspecified)
 $day=[datetime]::SpecifyKind($local.Date,[DateTimeKind]::Unspecified)
 return @{MonthStartUtc=[datetimeoffset][TimeZoneInfo]::ConvertTimeToUtc($month,$zone); MonthEndUtc=[datetimeoffset][TimeZoneInfo]::ConvertTimeToUtc($month.AddMonths(1),$zone);DayStartUtc=[datetimeoffset][TimeZoneInfo]::ConvertTimeToUtc($day,$zone);DayEndUtc=[datetimeoffset][TimeZoneInfo]::ConvertTimeToUtc($day.AddDays(1),$zone)}
}
function New-Measure([string]$Status='unconfigured',[string]$Source='Configurar') {
 return @{Status=$Status;Source=$Source;ObservedAtUtc=$null;DataThroughUtc=$null;PeriodStartUtc=$null;PeriodEndUtc=$null;RemainingPercent=$null;ResetAtUtc=$null;IsManual=$false;SpentTodayUsd=$null;SpentMonthUsd=$null;BudgetUsd=$null;OverBudgetUsd=$null;Message=$null}
}
function New-ProviderSnapshot([string]$ProviderId) { return @{ProviderId=$ProviderId;Subscription=(New-Measure 'unavailable' 'Sem fonte conectada');Api=(New-Measure)} }
function Get-MeasureAlertKey([string]$ProviderId,[string]$Kind,$Measure,[datetimeoffset]$Now) {
 $period=if ($Kind -eq 'Api') { (Get-BillingPeriod $Now).MonthEndUtc.ToString('o') } elseif ($Measure.ResetAtUtc) { $Measure.ResetAtUtc } else { 'subscription' }
 return ($ProviderId+':'+$Kind+':'+$period)
}
Export-ModuleMember -Function *
