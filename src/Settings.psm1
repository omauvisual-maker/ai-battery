function Get-AppDataDirectory { return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIBattery') }
function ConvertTo-AppHashtable($Value) {
 if ($null -eq $Value) { return $null }
 if ($Value -is [System.Collections.IDictionary]) { $h=@{}; foreach ($k in $Value.Keys) { $h[$k]=ConvertTo-AppHashtable $Value[$k] }; return $h }
 if ($Value -is [pscustomobject]) { $h=@{}; foreach ($p in $Value.PSObject.Properties) { $h[$p.Name]=ConvertTo-AppHashtable $p.Value }; return $h }
 if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-AppHashtable $_ }) }
 return $Value
}
function New-AppSettings {
 $providers=@(foreach ($id in @('codex','claude','gemini')) { @{Id=$id;DetectionRules=@();ApiMonthlyBudgetUsd=$null;ManualSubscription=$null;ManualApi=$null;SubscriptionMode='auto';ApiMode='auto';GeminiProjectId='';GeminiBillingTable=''} })
 return @{SchemaVersion=1;Topmost=$true;Orientation='vertical';Position=$null;Providers=$providers}
}
function ConvertTo-CanonicalSettings($Value) {
 if ($null -eq $Value) {return $null}
 if ($Value -is [pscustomobject]) {$Value=ConvertTo-AppHashtable $Value}
 if ($Value -is [System.Collections.IDictionary]) {$result=[ordered]@{};foreach ($key in @($Value.Keys | Sort-Object)) {$result[$key]=ConvertTo-CanonicalSettings $Value[$key]};return $result}
 if ($Value -is [array]) {return ,@($Value | ForEach-Object {ConvertTo-CanonicalSettings $_})}
 if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {return [decimal]$Value}
 return $Value
}
function Test-ProviderSettingsChanged($Previous,$Next) {
 $before=(ConvertTo-CanonicalSettings $Previous.Providers) | ConvertTo-Json -Depth 16 -Compress
 $after=(ConvertTo-CanonicalSettings $Next.Providers) | ConvertTo-Json -Depth 16 -Compress
 return ($before -cne $after)
}
function Read-AppSettings([string]$Path=(Join-Path (Get-AppDataDirectory) 'settings.json')) {
 if (-not (Test-Path -LiteralPath $Path)) { return (New-AppSettings) }
 try { $s=ConvertTo-AppHashtable (ConvertFrom-Json ([IO.File]::ReadAllText($Path))) } catch { throw 'Configuracao invalida. O arquivo original foi preservado.' }
 if ($s.SchemaVersion -ne 1 -or @($s.Providers).Count -ne 3) { throw 'Versao de configuracao nao suportada.' }
 foreach ($p in $s.Providers) { if ($p.Id -notin @('codex','claude','gemini')) { throw 'Provedor invalido.' } }
 if (@($s.Providers.Id | Select-Object -Unique).Count -ne 3) { throw 'Provedores duplicados.' }
 if (-not $s.Orientation) {$s.Orientation='vertical'}
 if ($s.Orientation -notin @('horizontal','vertical')) {throw 'Orientacao invalida.'}
 return $s
}
function Write-AppSettings([string]$Path,[object]$Settings) {
 if ($Settings.Orientation -and $Settings.Orientation -notin @('horizontal','vertical')) {throw 'Orientacao invalida.'}
 foreach ($p in $Settings.Providers) {
  if ($null -ne $p.ApiMonthlyBudgetUsd -and ([double]$p.ApiMonthlyBudgetUsd -le 0 -or [double]::IsInfinity([double]$p.ApiMonthlyBudgetUsd) -or [double]::IsNaN([double]$p.ApiMonthlyBudgetUsd))) { throw 'Orcamento deve ser maior que zero.' }
  if ($p.ManualSubscription -and ($p.ManualSubscription.RemainingPercent -lt 0 -or $p.ManualSubscription.RemainingPercent -gt 100)) { throw 'Saldo deve estar entre 0 e 100.' }
  if ($p.ManualApi -and $p.ManualApi.SpentMonthUsd -lt 0) { throw 'Gasto deve ser positivo.' }
 }
 $dir=Split-Path -Parent $Path; [IO.Directory]::CreateDirectory($dir) | Out-Null
 $tmp=$Path+'.'+[guid]::NewGuid().ToString()+'.tmp'
 try { [IO.File]::WriteAllText($tmp,($Settings | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false)); if (Test-Path $Path) { [IO.File]::Replace($tmp,$Path,$Path+'.backup') } else { [IO.File]::Move($tmp,$Path) } } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function Save-ProviderSecret([string]$ProviderId,[securestring]$Secret,[string]$Directory=(Get-AppDataDirectory)) {
 if ($ProviderId -notin @('codex','claude','gemini')) { throw 'Provedor invalido.' }
 [IO.Directory]::CreateDirectory($Directory) | Out-Null
 [IO.File]::WriteAllText((Join-Path $Directory "$ProviderId.secret"),(ConvertFrom-SecureString $Secret))
}
function Read-ProviderSecret([string]$ProviderId,[string]$Directory=(Get-AppDataDirectory)) {
 if ($ProviderId -notin @('codex','claude','gemini')) { throw 'Provedor invalido.' }
 $path=Join-Path $Directory "$ProviderId.secret"; if (-not (Test-Path -LiteralPath $path)) { return $null }
 return (ConvertTo-SecureString ([IO.File]::ReadAllText($path)))
}
Export-ModuleMember -Function *
