Import-Module "$PSScriptRoot\Core.psm1"
Import-Module "$PSScriptRoot\providers\Codex.psm1"
Import-Module "$PSScriptRoot\providers\Costs.psm1"
Import-Module "$PSScriptRoot\Settings.psm1"
function Get-ProviderSnapshot($Settings,$Context) {
 $snapshot=New-ProviderSnapshot $Settings.Id
 if (-not $Context.NowUtc) { $Context.NowUtc=[datetimeoffset]::UtcNow }
 $period=Get-BillingPeriod $Context.NowUtc
 if ($Settings.SubscriptionMode -eq 'manual' -and $Settings.ManualSubscription) {
  $m=New-Measure 'connected' 'Saldo informado manualmente';$m.IsManual=$true;$m.RemainingPercent=[double]$Settings.ManualSubscription.RemainingPercent;$m.ObservedAtUtc=$Settings.ManualSubscription.UpdatedAtUtc
  if ($Context.NowUtc-[datetimeoffset]$m.ObservedAtUtc -gt [timespan]::FromHours(24)) { $m.Status='stale';$m.Message='Atualize o saldo manual; leitura ha mais de 24 h.' }
  $snapshot.Subscription=$m
 } elseif ($Settings.Id -eq 'codex' -and $Settings.SubscriptionMode -ne 'manual') {
  try { $snapshot.Subscription=Get-CodexSubscription $Settings $Context } catch { $snapshot.Subscription=New-Measure 'error' 'Codex nao conectado';$snapshot.Subscription.Message='Nao foi possivel ler limites. Confirme login do Codex CLI.' }
 }
 if ($Context.Policy -eq 'subscriptionOnly') {
  $snapshot.Api=New-Measure 'unavailable' 'Assinaturas somente'
  $snapshot.Api.Policy='subscriptionOnly'
  $snapshot.Api.Message='Consulta de faturamento desativada por politica de assinaturas.'
  return $snapshot
 }
 if ($Settings.ApiMode -eq 'manual') {
  if ($Settings.ManualApi) {
   $m=New-Measure 'connected' 'Gasto informado manualmente';$m.IsManual=$true;$m.ObservedAtUtc=$Settings.ManualApi.UpdatedAtUtc;$m.SpentMonthUsd=[double]$Settings.ManualApi.SpentMonthUsd;$m.BudgetUsd=$Settings.ApiMonthlyBudgetUsd;$m.PeriodStartUtc=$period.MonthStartUtc.ToString('o');$m.PeriodEndUtc=$period.MonthEndUtc.ToString('o')
   if ([datetimeoffset]$m.ObservedAtUtc -lt $period.MonthStartUtc) { $m.Status='stale';$m.Message='Valor manual de outro mes; atualize o gasto.' } else { $m.RemainingPercent=Get-ApiRemainingPercent $m.BudgetUsd $m.SpentMonthUsd }
   if ($m.BudgetUsd) { $m.OverBudgetUsd=[math]::Max(0,$m.SpentMonthUsd-$m.BudgetUsd) };$snapshot.Api=$m
  }
 } elseif (-not $Context.ForceRefresh -and $Context.Previous -and $Context.Previous.Api.ObservedAtUtc -and $Context.Previous.Api.Status -in @('connected','stale') -and $Context.NowUtc-[datetimeoffset]$Context.Previous.Api.ObservedAtUtc -lt [timespan]::FromMinutes(5)) { $snapshot.Api=$Context.Previous.Api }
 else {
  try {
   if (-not $Context.ContainsKey('Secret')) { $Context.Secret=Read-ProviderSecret $Settings.Id }
   $snapshot.Api=Get-ApiCostMeasure $Settings.Id $Settings $Context
  } catch { $snapshot.Api=New-Measure 'error' 'Erro consultando custos';$snapshot.Api.Message='Verifique credencial administrativa, permissao e conexao.';$snapshot.Api.RetryAfter=$_.Exception.Data['RetryAfter'] }
 }
 return $snapshot
}
Export-ModuleMember -Function Get-ProviderSnapshot,Get-ApiCostMeasure,Convert-CodexLimits
