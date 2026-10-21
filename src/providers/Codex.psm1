Import-Module "$PSScriptRoot\..\Core.psm1"
function Convert-CodexLimits($Result,[datetimeoffset]$Now) {
 $bucket=$null
 if ($Result.rateLimitsByLimitId -and $Result.rateLimitsByLimitId.codex) { $bucket=$Result.rateLimitsByLimitId.codex }
 elseif ($Result.rateLimits -and (-not $Result.rateLimits.limitId -or $Result.rateLimits.limitId -eq 'codex')) { $bucket=$Result.rateLimits }
 $limits=@($bucket.primary,$bucket.secondary | Where-Object { $null -ne $_ -and $null -ne $_.usedPercent -and $_.usedPercent -ge 0 -and $_.usedPercent -le 100 })
 if (-not $limits.Count) { return (New-Measure 'unavailable' 'Codex: limites nao disponiveis') }
 $tight=$limits | Sort-Object usedPercent -Descending | Select-Object -First 1
 $m=New-Measure 'connected' "Codex oficial | janela $($tight.windowDurationMins) min"
 $m.RemainingPercent=Get-SubscriptionRemainingPercent $limits; $m.ObservedAtUtc=$Now.ToString('o');$m.DataThroughUtc=$m.ObservedAtUtc
 if ($tight.resetsAt) { $m.ResetAtUtc=[datetimeoffset]::FromUnixTimeSeconds([long]$tight.resetsAt).ToString('o'); $m.PeriodEndUtc=$m.ResetAtUtc }
 return $m
}
function Read-CodexResponse($Process,[int]$Id,[datetime]$Deadline) {
 while ([datetime]::UtcNow -lt $Deadline) {
  $task=$Process.StandardOutput.ReadLineAsync()
  $ms=[math]::Max(1,[int]($Deadline-[datetime]::UtcNow).TotalMilliseconds)
  if (-not $task.Wait($ms)) { throw 'Tempo limite consultando Codex.' }
  $line=$task.Result; if ($null -eq $line) { throw 'Codex encerrou a conexao.' }
  $message=ConvertFrom-Json $line
  if ($message.id -eq $Id) { if ($message.error) { throw 'Codex nao disponibilizou limites nesta conta.' }; return $message.result }
 }
 throw 'Tempo limite consultando Codex.'
}
# The Codex app installs its CLI under a versioned bin folder that is not on PATH.
function Resolve-CodexExecutable([string]$LocalAppData=[Environment]::GetFolderPath('LocalApplicationData'),[string]$SearchPath=$env:PATH) {
 foreach ($dir in @($SearchPath -split ';' | Where-Object {$_})) {
  $candidate=Join-Path $dir 'codex.exe'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
 }
 $newest=Get-ChildItem -Path (Join-Path $LocalAppData 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
 if ($newest) { return $newest.FullName }
 return $null
}
# .NET Framework builds Process.StandardInput from Console.InputEncoding and writes its preamble at
# start. With code page 65001 that is a UTF-8 BOM, which makes app-server drop the first JSON-RPC
# message. Start the child with a BOM-free encoding and restore the console setting afterwards.
function Invoke-WithBomFreeConsoleInput([scriptblock]$Action) {
 $previous=$null
 try { $previous=[Console]::InputEncoding; if ($previous.GetPreamble().Length) {[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)} } catch { $previous=$null }
 try { & $Action } finally { if ($previous) { try {[Console]::InputEncoding=$previous} catch {} } }
}
function Get-CodexSubscription($Settings,$Context) {
 $exe=Resolve-CodexExecutable
 if (-not $exe) { return (New-Measure 'unconfigured' 'Instale ou conecte o Codex CLI') }
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$exe;$info.Arguments='app-server';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info; $childKey=[guid]::NewGuid().ToString()
 try {
  Invoke-WithBomFreeConsoleInput { [void]$p.Start() }; if ($Context.Children) { $Context.Children[$childKey]=$p }
  $stderr=$p.StandardError.ReadToEndAsync()
  $deadline=[datetime]::UtcNow.AddSeconds(15)
  $stdin=$p.StandardInput
  $stdin.WriteLine((@{method='initialize';id=1;params=@{clientInfo=@{name='ai_battery';title='AI Battery Sidebar';version='1.0.0'}}} | ConvertTo-Json -Depth 5 -Compress))
  $null=Read-CodexResponse $p 1 $deadline
  $stdin.WriteLine('{"method":"initialized","params":{}}')
  $stdin.WriteLine('{"method":"account/rateLimits/read","id":2}')
  $result=Read-CodexResponse $p 2 $deadline
  return (Convert-CodexLimits $result $Context.NowUtc)
 } finally {
  if ($Context.Children) { $Context.Children.Remove($childKey) }
  if ($p.Id -and -not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(2000) }
  $p.Dispose()
 }
}
Export-ModuleMember -Function Convert-CodexLimits,Get-CodexSubscription,Resolve-CodexExecutable,Invoke-WithBomFreeConsoleInput
