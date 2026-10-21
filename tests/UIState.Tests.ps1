Import-Module "$PSScriptRoot\..\src\Core.psm1" -Force
Import-Module "$PSScriptRoot\..\src\UI.psm1" -Force
Test 'Summary selects subscription then API' {
 $s=New-ProviderSnapshot 'claude';$s.Subscription.RemainingPercent=70;$s.Subscription.Status='connected';$s.Api.RemainingPercent=20;$s.Api.Status='connected'
 Assert-Equal (Get-SummaryView $s).Percent 70; Assert-Equal (Get-SummaryView $s).Kind 'Assinatura'
 $s.Subscription.RemainingPercent=$null;Assert-Equal (Get-SummaryView $s).Kind 'API'
}
Test 'No data and stale clearly labeled' { $s=New-ProviderSnapshot 'claude';Assert-Equal (Get-SummaryView $s).Percent $null;$s.Api.RemainingPercent=15;$s.Api.Status='stale';Assert-True ((Get-SummaryView $s).Label -match 'atrasad') }
Test 'Selection removed and icons deduplicated' { $r=Get-UIState @('codex','codex','claude') 'gemini'; Assert-Equal $r.ActiveIds.Count 2;Assert-Equal $r.SelectedId $null;Assert-True $r.ShowSidebar;Assert-Equal (Get-UIState @() 'codex').ShowSidebar $false }
Test 'Position clamped to workarea' { $p=Get-ClampedPosition @{X=5000;Y=-500} @{Left=0;Top=0;Width=1920;Height=1080} 84 300;Assert-Equal $p.X 1836;Assert-Equal $p.Y 0 }
Test 'Recovered alert clears only after valid reading' { Assert-True (Test-MeasureRecovered @{Status='connected';RemainingPercent=21});Assert-Equal (Test-MeasureRecovered @{Status='stale';RemainingPercent=90}) $false;Assert-Equal (Test-MeasureRecovered @{Status='connected';RemainingPercent=20}) $false }
Test 'Horizontal and vertical dock geometry' { $v=Get-DockLayout 'vertical' 3;$h=Get-DockLayout 'horizontal' 3;Assert-True ($v.Height -gt $v.Width);Assert-True ($h.Width -gt $h.Height);Assert-True ($h.Height -le 110);Assert-True ((Get-DockLayout 'horizontal' 0).Width -gt 0) }
Test 'Operations view labels missing values and leaves ended task duration fixed' {
 $row=@{Id='native1';Status='Interrompido';Operation='Tarefa observada';Model='fixture';StartedAtUtc='2026-10-18T10:00:00Z';ElapsedSeconds=5;TotalTokens=$null;EstimatedUsd=$null;Operations=2;InputTokens=$null;CachedTokens=$null;OutputTokens=$null}
 $view=Get-OperationsRowView $row ([datetimeoffset]'2026-10-18T10:01:00Z')
 Assert-True ($view.Text -match '00:00:05');Assert-True ($view.Text.Contains(([string][char]0x2014)+' tokens'));Assert-True ($view.ToolTip.Contains('Entrada: '+[char]0x2014))
 $row.Status='Em andamento';Assert-True ((Get-OperationsRowView $row ([datetimeoffset]'2026-10-18T10:01:00Z')).Text -match '00:01:00')
}
Test 'Operations source distinguishes unified local and stale observation' {
 $unified=Get-OperationsSourceText @{Source='unified';ObservedAtUtc='2026-10-18T10:00:00Z';Stale=$false}
 Assert-True ($unified -match 'unificado');Assert-True ($unified -notmatch 'tarifas')
 $local=Get-OperationsSourceText @{Source='local';ObservedAtUtc='2026-10-18T10:00:00Z';Stale=$true}
 Assert-True ($local -match 'local');Assert-True ($local -match 'desatualizada')
}
