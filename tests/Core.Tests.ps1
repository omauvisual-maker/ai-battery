Import-Module "$PSScriptRoot\..\src\Core.psm1" -Force
Test 'API 20% and zero clamp' { Assert-Equal (Get-ApiRemainingPercent 100 80) 20; Assert-Equal (Get-ApiRemainingPercent 100 120) 0 }
Test 'Unknown budget or spend stays unknown' { Assert-Equal (Get-ApiRemainingPercent $null 80) $null; Assert-Equal (Get-ApiRemainingPercent 0 80) $null; Assert-Equal (Get-ApiRemainingPercent 100 $null) $null }
Test 'Negative costs rejected' { Assert-Throws { Get-ApiRemainingPercent 100 -1 } }
Test 'Tightest subscription window' { Assert-Equal (Get-SubscriptionRemainingPercent @(@{usedPercent=30},@{usedPercent=85})) 15 }
Test 'Color boundaries' { Assert-Equal (Get-BatteryColor 41) '#5EE0A0'; Assert-Equal (Get-BatteryColor 40) '#F5C76B'; Assert-Equal (Get-BatteryColor 20) '#FF747C'; Assert-Equal (Get-BatteryColor $null) '#78849A' }
Test 'Threshold once and rearm' {
 $x = Get-AlertTransition $null @{Status='connected';RemainingPercent=20} $true
 Assert-True $x.Notify; Assert-Equal $x.Armed $false
 $x = Get-AlertTransition $null @{Status='connected';RemainingPercent=19} $x.Armed; Assert-Equal $x.Notify $false
 $x = Get-AlertTransition $null @{Status='connected';RemainingPercent=25} $x.Armed; Assert-True $x.Armed
 Assert-Equal (Get-AlertTransition $null @{Status='stale';RemainingPercent=10} $true).Notify $false
}
Test 'Sao Paulo billing month at UTC boundary' { $p=Get-BillingPeriod ([datetimeoffset]'2026-11-01T01:00:00Z'); Assert-Equal $p.MonthStartUtc.ToString('yyyy-MM-ddTHH:mm') '2026-10-01T03:00'; Assert-Equal $p.DayStartUtc.ToString('yyyy-MM-ddTHH:mm') '2026-10-31T03:00' }
Test 'API alert identity stable within billing month' { $a=Get-MeasureAlertKey 'codex' 'Api' @{PeriodEndUtc='2026-10-11T12:00:00Z'} ([datetimeoffset]'2026-10-11T12:00:00Z');$b=Get-MeasureAlertKey 'codex' 'Api' @{PeriodEndUtc='2026-10-11T12:05:00Z'} ([datetimeoffset]'2026-10-11T12:05:00Z');Assert-Equal $a $b;Assert-True ($a -ne (Get-MeasureAlertKey 'codex' 'Api' @{} ([datetimeoffset]'2026-11-11T12:00:00Z'))) }
