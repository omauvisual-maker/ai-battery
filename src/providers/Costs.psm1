Import-Module "$PSScriptRoot\..\Core.psm1"
function Invoke-CostRequest([string]$Uri,[hashtable]$Headers,$Body,$Context) {
 if ($Context.HttpClient) { return (& $Context.HttpClient $Uri $Headers $Body) }
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 try {
  if ($Body) { return (Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Post -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 12 -Compress) -TimeoutSec 15 -ErrorAction Stop) }
  return (Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -TimeoutSec 15 -ErrorAction Stop)
 } catch {
  $code=0;$retry=0
  if ($_.Exception.Response) { $code=[int]$_.Exception.Response.StatusCode; [void][int]::TryParse($_.Exception.Response.Headers['Retry-After'],[ref]$retry) }
  $error=[Exception]::new("Fonte retornou erro HTTP $code. Verifique a conexao e as permissoes.");$error.Data['RetryAfter']=$retry;throw $error
 }
}
function Get-ApiCostMeasure([string]$ProviderId,$Settings,$Context) {
 $now=[datetimeoffset]$Context.NowUtc; $period=Get-BillingPeriod $now
 if (-not $Context.Secret) { return (New-Measure 'unconfigured' 'Configure credencial de custos') }
 if ($ProviderId -eq 'gemini' -and (-not $Settings.GeminiQueryEnabled -or -not $Settings.GeminiBillingTable -or -not $Settings.GeminiProjectId)) { return (New-Measure 'unconfigured' 'Configure exportacao existente do Google Cloud') }
 $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Context.Secret)
 try {
  $token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  if ($ProviderId -eq 'gemini') { return (Get-GeminiCost $Settings $Context $token $period) }
  $headers=if ($ProviderId -eq 'claude') { @{'x-api-key'=$token;'anthropic-version'='2023-06-01'} } else { @{Authorization="Bearer $token"} }
  $start=$period.MonthStartUtc;$end=$now
  $base=if ($ProviderId -eq 'claude') { 'https://api.anthropic.com/v1/organizations/cost_report?starting_at='+[uri]::EscapeDataString($start.ToString('o'))+'&ending_at='+[uri]::EscapeDataString($end.ToString('o'))+'&limit=31' } else { "https://api.openai.com/v1/organization/costs?start_time=$($start.ToUnixTimeSeconds())&end_time=$($end.ToUnixTimeSeconds())&bucket_width=1d&limit=31" }
  $page=$null;$seen=New-Object 'System.Collections.Generic.HashSet[string]';$total=[decimal]0;$today=[decimal]0;$aligned=$true;$monthAligned=$true;$firstBucket=$null;$lastBucket=$null;$count=0
  do {
   if (++$count -gt 40) { throw 'Excesso de paginas na fonte de custos.' }
   $uri=$base;if ($page) { $uri+='&page='+[uri]::EscapeDataString($page) }
   $response=Invoke-CostRequest $uri $headers $null $Context
   if ($null -eq $response.data -or $null -eq $response.has_more) { throw 'Resposta de custos invalida.' }
   foreach ($bucket in $response.data) {
    $bs=if ($ProviderId -eq 'claude') { [datetimeoffset]$bucket.starting_at } else { [datetimeoffset]::FromUnixTimeSeconds([long]$bucket.start_time) }
    $be=if ($ProviderId -eq 'claude') { [datetimeoffset]$bucket.ending_at } else { [datetimeoffset]::FromUnixTimeSeconds([long]$bucket.end_time) }
    if ($be -le $bs -or $null -eq $bucket.results) { throw 'Bucket de custos invalido.' }
    if ($bs -lt $period.MonthStartUtc -or $be -gt $period.MonthEndUtc) { $monthAligned=$false }
    if (-not $firstBucket -or $bs -lt $firstBucket) {$firstBucket=$bs};if (-not $lastBucket -or $be -gt $lastBucket) {$lastBucket=$be}
    foreach ($r in $bucket.results) {
     $currency=if ($ProviderId -eq 'claude') { $r.currency } else { $r.amount.currency }
     $raw=if ($ProviderId -eq 'claude') { $r.amount } else { $r.amount.value }
     if ($currency -ine 'usd' -or $null -eq $raw) { throw 'Moeda ou valor invalido na fonte.' }
     $value=[decimal]::Parse([string]$raw,[Globalization.CultureInfo]::InvariantCulture)
     if ($ProviderId -eq 'claude') { $value/=100 }
     $total+=$value
     if ($bs -ge $period.DayStartUtc -and $be -le $period.DayEndUtc) { $today+=$value } elseif ($be -gt $period.DayStartUtc -and $bs -lt $period.DayEndUtc) { $aligned=$false }
    }
   }
   $page=$response.next_page
   if ($response.has_more -and (-not $page -or -not $seen.Add($page))) { throw 'Paginacao invalida na fonte.' }
  } while ($response.has_more)
  $m=New-Measure 'connected' $(if ($ProviderId -eq 'claude') {'Claude API | buckets diarios'} else {'OpenAI API | buckets diarios'})
  $m.ObservedAtUtc=$now.ToString('o');$m.DataThroughUtc=$null;$m.PeriodStartUtc=if ($firstBucket) {$firstBucket.ToString('o')} else {$start.ToString('o')};$m.PeriodEndUtc=if ($lastBucket) {$lastBucket.ToString('o')} else {$end.ToString('o')};$m.SpentMonthUsd=[math]::Max(0,[double]$total);$m.BudgetUsd=$Settings.ApiMonthlyBudgetUsd
  if ($aligned) { $m.SpentTodayUsd=[math]::Max(0,[double]$today) }
  $m.Message='Total informado pelo provedor para a janela consultada; cobranca pode atrasar. Hoje indisponivel quando buckets nao alinham com Sao Paulo.'
  if ($monthAligned) { $m.RemainingPercent=Get-ApiRemainingPercent $m.BudgetUsd $m.SpentMonthUsd; if ($m.BudgetUsd) { $m.OverBudgetUsd=[math]::Max(0,$m.SpentMonthUsd-$m.BudgetUsd) } }
  else {$m.Message='Buckets ultrapassam a fronteira do mes em Sao Paulo. Total da janela da fonte; percentual mensal indisponivel.'}
  return $m
 } finally { $token=$null; [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Get-GeminiCost($Settings,$Context,[string]$Token,$Period) {
 if ($Settings.GeminiBillingTable -notmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_]+\.[a-zA-Z0-9_]+$' -or $Settings.GeminiProjectId -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Projeto ou tabela BigQuery invalidos.' }
 $query='SELECT SUM((cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)) / NULLIF(currency_conversion_rate,0)) AS month_usd, SUM(IF(usage_start_time >= @day_start, (cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)) / NULLIF(currency_conversion_rate,0),0)) AS today_usd, MAX(export_time) AS exported_at, COUNTIF(currency_conversion_rate IS NULL OR currency_conversion_rate <= 0) AS invalid_rates FROM `'+$Settings.GeminiBillingTable+'` WHERE project.id = @project AND usage_start_time >= @month_start AND usage_start_time < @now AND (LOWER(service.description) LIKE "%generative language%" OR LOWER(sku.description) LIKE "%gemini%")'
 $params=@(@{name='project';parameterType=@{type='STRING'};parameterValue=@{value=$Settings.GeminiProjectId}},@{name='month_start';parameterType=@{type='TIMESTAMP'};parameterValue=@{value=$Period.MonthStartUtc.ToString('o')}},@{name='day_start';parameterType=@{type='TIMESTAMP'};parameterValue=@{value=$Period.DayStartUtc.ToString('o')}},@{name='now';parameterType=@{type='TIMESTAMP'};parameterValue=@{value=$Context.NowUtc.ToString('o')}})
 $body=@{query=$query;useLegacySql=$false;parameterMode='NAMED';queryParameters=$params;timeoutMs=10000;maximumBytesBilled='100000000';useQueryCache=$true}
 $r=Invoke-CostRequest "https://bigquery.googleapis.com/bigquery/v2/projects/$($Settings.GeminiProjectId)/queries" @{Authorization="Bearer $Token"} $body $Context
 if (-not $r.jobComplete -or $r.errors -or -not $r.rows) { throw 'Consulta BigQuery nao finalizada ou sem dados.' }
 $f=$r.rows[0].f
 if ($f.Count -lt 4 -or $null -eq $f[3].v -or [long]$f[3].v -gt 0) {throw 'Exportacao sem taxa de conversao confiavel.'}
 if ($null -eq $f[0].v -or $null -eq $f[2].v) { return (New-Measure 'unavailable' 'Exportacao sem dados Gemini neste mes') }
 $m=New-Measure 'connected' 'Gemini | exportacao Cloud Billing (pode atrasar)'
 $m.SpentMonthUsd=[math]::Max(0,[double]::Parse($f[0].v,[Globalization.CultureInfo]::InvariantCulture));$m.SpentTodayUsd=[math]::Max(0,[double]::Parse($f[1].v,[Globalization.CultureInfo]::InvariantCulture));$m.BudgetUsd=$Settings.ApiMonthlyBudgetUsd
 $m.DataThroughUtc=[datetimeoffset]::FromUnixTimeSeconds([long][double]::Parse($f[2].v,[Globalization.CultureInfo]::InvariantCulture)).ToString('o');$m.ObservedAtUtc=$Context.NowUtc.ToString('o');$m.PeriodStartUtc=$Period.MonthStartUtc.ToString('o');$m.PeriodEndUtc=$Period.MonthEndUtc.ToString('o')
 $m.RemainingPercent=Get-ApiRemainingPercent $m.BudgetUsd $m.SpentMonthUsd
 if ($m.BudgetUsd) { $m.OverBudgetUsd=[math]::Max(0,$m.SpentMonthUsd-$m.BudgetUsd) }
 $m.Message='Projeto filtrado por servico Generative Language ou SKU Gemini. Custos liquidos convertidos para US$ pela taxa do faturamento.'
 if ($Context.NowUtc-[datetimeoffset]$m.DataThroughUtc -gt [timespan]::FromMinutes(10)) {$m.Status='stale';$m.Message+=' Exportacao atrasada; aguarde o provedor.'}
 return $m
}
Export-ModuleMember -Function Get-ApiCostMeasure
