# Runtime reads metadata from the fixed loopback endpoint; it never starts a service or model.
function New-RuntimeClientState {
 return @{Source='local';Generation=1;Failures=0;Stale=$false;Report=$null;LastSnapshot=$null;PendingSnapshot=$null;Poll=$null;LocalPoll=$null;LastPollAt=[datetimeoffset]::MinValue;LastLocalPollAt=[datetimeoffset]::MinValue;Closed=$false;Request=$null;LocalRequest=$null;Policy='subscriptionOnly'}
}
function Get-RuntimeField($Value,[string]$Name) {
 if ($null -eq $Value) {return $null}
 if ($Value -is [Collections.IDictionary]) {return ,$Value[$Name]}
 $property=$Value.PSObject.Properties[$Name];if ($property) {return ,$property.Value};return $null
}
function Get-RuntimeNumber($Value,[bool]$Integer=$true) {
 if ($null -eq $Value) {return $null}
 if ($Value -is [string] -or $Value -is [bool]) {throw 'RUNTIME_INVALID_METRIC'}
 try {$number=[double]$Value} catch {throw 'RUNTIME_INVALID_METRIC'}
 if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or ($Integer -and $number -ne [math]::Floor($number))) {throw 'RUNTIME_INVALID_METRIC'}
 return $Value
}
function Get-RuntimeDate($Value) {
 if ($null -eq $Value) {return $null}
 if ($Value -is [datetime]) {return ([datetimeoffset]$Value).ToUniversalTime().ToString('o')}
 if ([string]$Value -notmatch '^\d{4}-\d\d-\d\dT.*(?:Z|\+00:00)$') {throw 'RUNTIME_INVALID_DATE'}
 try {return ([datetimeoffset]$Value).ToUniversalTime().ToString('o')} catch {throw 'RUNTIME_INVALID_DATE'}
}
function ConvertTo-OperationsReport($Snapshot) {
 if ((Get-RuntimeField $Snapshot 'version') -ne 1) {throw 'RUNTIME_UNSUPPORTED_VERSION'}
 $cursor=Get-RuntimeNumber (Get-RuntimeField $Snapshot 'cursor');if ($null -eq $cursor) {throw 'RUNTIME_INVALID_CURSOR'}
 $tasks=Get-RuntimeField $Snapshot 'tasks';if ($null -eq $tasks -or $tasks -is [string] -or @($tasks).Count -gt 1000) {throw 'RUNTIME_INVALID_TASKS'}
 $latest=$null;$ids=@{};$rows=@(foreach ($task in $tasks) {
  $id=[string](Get-RuntimeField $task 'id');$state=[string](Get-RuntimeField $task 'state')
  if (-not $id -or $id.Length -gt 256 -or $ids.ContainsKey($id)) {throw 'RUNTIME_INVALID_ID'};$ids[$id]=$true
  $status=switch ($state) {'queued' {'Na fila'};'planning' {'Planejando'};'running' {'Em andamento'};'awaiting_approval' {'Aguardando aprovacao'};'completed' {'Concluido'};'failed' {'Falhou'};'interrupted' {'Interrompido'};'unknown' {'Desconhecido'};default {throw 'RUNTIME_INVALID_STATE'}}
  $updated=Get-RuntimeDate (Get-RuntimeField $task 'updatedAt');if ($updated -and (-not $latest -or [datetimeoffset]$updated -gt [datetimeoffset]$latest)) {$latest=$updated}
  $usage=Get-RuntimeField $task 'usage';$model=[string](Get-RuntimeField $task 'model')
  if ($model.Length -gt 128 -or $model -match '[\r\n\x00-\x1f]') {throw 'RUNTIME_INVALID_MODEL'}
  $quality=[string](Get-RuntimeField $usage 'quality');if ($quality -notin @('exact','partial','unavailable','estimated','unknown','complete','reported','cumulative','fallback','response','none','')) {$quality='partial'}
  @{Id=$id;ProviderId=(Get-RuntimeField $task 'providerId');SessionId=(Get-RuntimeField $task 'sessionId');TurnId=(Get-RuntimeField $task 'turnId');Model=$model;StartedAtUtc=(Get-RuntimeDate (Get-RuntimeField $task 'startedAt'));EndedAtUtc=(Get-RuntimeDate (Get-RuntimeField $task 'endedAt'));ObservedAtUtc=$updated;Status=$status;State=$state;Operation='Tarefa observada';ElapsedSeconds=(Get-RuntimeNumber (Get-RuntimeField $task 'elapsedSeconds') $false);InputTokens=(Get-RuntimeNumber (Get-RuntimeField $usage 'inputTokens'));CachedTokens=(Get-RuntimeNumber (Get-RuntimeField $usage 'cachedInputTokens'));CacheWriteTokens=(Get-RuntimeNumber (Get-RuntimeField $usage 'cacheWriteInputTokens'));OutputTokens=(Get-RuntimeNumber (Get-RuntimeField $usage 'outputTokens'));ReasoningTokens=(Get-RuntimeNumber (Get-RuntimeField $usage 'reasoningOutputTokens'));TotalTokens=(Get-RuntimeNumber (Get-RuntimeField $usage 'totalTokens'));EstimatedUsd=(Get-RuntimeNumber (Get-RuntimeField $usage 'estimatedUsd') $false);Operations=(Get-RuntimeNumber (Get-RuntimeField $task 'operationCount'));ActiveOperations=(Get-RuntimeNumber (Get-RuntimeField $task 'activeOperations'));Quality=$quality}
 })
 $totals=Get-RuntimeField $Snapshot 'totals'
 return @{Turns=$rows;Totals=@{TotalTokens=(Get-RuntimeNumber (Get-RuntimeField $totals 'totalTokens'));EstimatedUsd=(Get-RuntimeNumber (Get-RuntimeField $totals 'estimatedUsd') $false)};ObservedAtUtc=$latest;Error=$false;Source='unified';Stale=$false;Cursor=$cursor;Coverage=(Get-RuntimeField $Snapshot 'coverage')}
}
function Set-RuntimeSource($State,[ValidateSet('local','unified')][string]$Source) {
 if ($State.Source -ne $Source) {$State.Generation++;$State.Source=$Source}
 return $State.Generation
}
function Set-RuntimeOperationsReport($State,$Report,[string]$Source,[int]$Generation) {
 if ($State.Closed -or $Source -ne $State.Source -or $Generation -ne $State.Generation -or -not $Report) {return $false}
 # A source switch replaces the view. Neither source's totals are imported into the other.
 $Report.Source=$Source;$Report.Stale=[bool]$State.Stale
 if ($Source -eq 'local') {
  foreach ($row in @($Report.Turns)) {if ($row) {$row.EstimatedUsd=$null}}
 }
 $State.Report=$Report;return $true
}
function Register-RuntimeFailure($State) {
 $State.Failures++;$State.Stale=$true
 if ($State.Report) {$State.Report.Stale=$true}
 if ($State.Failures -ge 3) {[void](Set-RuntimeSource $State 'local')}
}
function Start-RuntimePoll($State) {
 if ($State.Closed -or $State.Poll -or [datetimeoffset]::UtcNow-$State.LastPollAt -lt [timespan]::FromSeconds(2)) {return $false}
 $State.LastPollAt=[datetimeoffset]::UtcNow;$ps=[powershell]::Create()
 [void]$ps.AddScript({param($request)
  $ErrorActionPreference='Stop'
  if ($request) {& ([scriptblock]::Create($request));return}
  $http=[Net.HttpWebRequest]::Create('http://127.0.0.1:43127/api/runtime/snapshot')
  $http.Proxy=$null;$http.AllowAutoRedirect=$false;$http.Timeout=1200;$http.ReadWriteTimeout=1200;$http.Method='GET'
  $response=$null;$stream=$null;$buffer=[byte[]]::new(8192);$data=[IO.MemoryStream]::new()
  try {
   $response=$http.GetResponse();if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 2097152) {throw 'RUNTIME_HTTP_UNAVAILABLE'}
   $stream=$response.GetResponseStream()
   while (($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {if ($data.Length+$count -gt 2097152) {throw 'RUNTIME_RESPONSE_TOO_LARGE'};$data.Write($buffer,0,$count)}
   [Text.Encoding]::UTF8.GetString($data.ToArray())
  } finally {if ($stream) {$stream.Dispose()};if ($response) {$response.Dispose()};$data.Dispose();$http.Abort()}
 }).AddArgument($(if ($State.Request) {$State.Request.ToString()} else {$null}))
 try {$State.Poll=@{PS=$ps;Handle=$ps.BeginInvoke();StartedAt=[datetimeoffset]::UtcNow;Stopping=$false};return $true} catch {$ps.Dispose();Register-RuntimeFailure $State;return $false}
}
function Receive-RuntimePoll($State) {
 $job=$State.Poll;if (-not $job) {return $null}
 if (-not $job.Handle.IsCompleted) {
  if (-not $job.Stopping -and [datetimeoffset]::UtcNow-$job.StartedAt -gt [timespan]::FromSeconds(2)) {$job.Stopping=$true;try {$job.StopHandle=$job.PS.BeginStop($null,$null)} catch {}}
  return $null
 }
 try {
  $output=$job.PS.EndInvoke($job.Handle);if ($job.PS.HadErrors -or $output.Count -ne 1) {throw 'RUNTIME_POLL_FAILED'}
  $snapshot=$output[0];if ($snapshot -is [string]) {$snapshot=ConvertFrom-Json $snapshot -ErrorAction Stop}
  [void](ConvertTo-OperationsReport $snapshot)
  $State.Failures=0;$State.Stale=$false;$State.LastSnapshot=$snapshot;return $snapshot
 } catch {Register-RuntimeFailure $State;return $null}
 finally {if ($job.StopHandle) {try {$job.PS.EndStop($job.StopHandle)} catch {}};$job.PS.Dispose();$State.Poll=$null}
}
function Stop-RuntimePoll($State) {
 $State.Closed=$true;$State.Generation++;$State.PendingSnapshot=$null
 if ($State.Poll) {try {$State.Poll.PS.Stop()} catch {} finally {$State.Poll.PS.Dispose();$State.Poll=$null}}
 if ($State.LocalPoll) {try {$State.LocalPoll.PS.Stop()} catch {} finally {$State.LocalPoll.PS.Dispose();$State.LocalPoll=$null}}
}
function Start-RuntimeLocalCollection($State,$Telemetry,[string]$SessionsPath=$null) {
 if ($State.Closed -or $State.Source -ne 'local' -or $State.PendingSnapshot -or $State.LocalPoll -or [datetimeoffset]::UtcNow-$State.LastLocalPollAt -lt [timespan]::FromSeconds(2)) {return $false}
 $ps=[powershell]::Create();$State.LastLocalPollAt=[datetimeoffset]::UtcNow
 [void]$ps.AddScript({param($root,$telemetry,$path,$request)
  $ErrorActionPreference='Stop'
  if ($request) {& ([scriptblock]::Create($request)) $telemetry $path;return}
  Import-Module (Join-Path $root 'Telemetry.psm1') -DisableNameChecking
  if ($path) {Update-CodexTelemetry $telemetry $path} else {Update-CodexTelemetry $telemetry}
  Get-TelemetryReport $telemetry
 }).AddArgument($PSScriptRoot).AddArgument($Telemetry).AddArgument($SessionsPath).AddArgument($(if ($State.LocalRequest) {$State.LocalRequest.ToString()} else {$null}))
 try {$State.LocalPoll=@{PS=$ps;Handle=$ps.BeginInvoke();Generation=$State.Generation;StartedAt=$State.LastLocalPollAt;Stopping=$false};return $true} catch {$ps.Dispose();return $false}
}
function Stop-RuntimeLocalCollection($State) {
 $job=$State.LocalPoll;if (-not $job) {return $true}
 if (-not $job.Stopping) {$job.Stopping=$true;try {$job.StopHandle=$job.PS.BeginStop($null,$null)} catch {}}
 # The UI drains this job on later ticks; a source switch never waits on disk I/O.
 return $false
}
function Receive-RuntimeLocalCollection($State) {
 $job=$State.LocalPoll;if (-not $job) {return $null}
 if (-not $job.Handle.IsCompleted) {
  if ([datetimeoffset]::UtcNow-$job.StartedAt -gt [timespan]::FromSeconds(10)) {[void](Stop-RuntimeLocalCollection $State)}
  return $null
 }
 try {
  $output=$job.PS.EndInvoke($job.Handle)
  if ($job.Stopping -or $job.PS.HadErrors -or $output.Count -ne 1) {return $null}
  $report=$output[0]
  if (Set-RuntimeOperationsReport $State $report 'local' $job.Generation) {return $report}
 } catch {return $null} finally {
  if ($job.StopHandle) {try {$job.PS.EndStop($job.StopHandle)} catch {}}
  $job.PS.Dispose();$State.LocalPoll=$null
 }
 return $null
}
Export-ModuleMember -Function New-RuntimeClientState,Start-RuntimePoll,Receive-RuntimePoll,Stop-RuntimePoll,ConvertTo-OperationsReport,Set-RuntimeSource,Set-RuntimeOperationsReport,Register-RuntimeFailure,Start-RuntimeLocalCollection,Stop-RuntimeLocalCollection,Receive-RuntimeLocalCollection
