Test 'Runtime client module is available' { Import-Module "$PSScriptRoot\..\src\RuntimeClient.psm1" -Force -ErrorAction Stop }
function New-TestRuntimeSnapshot([long]$Tokens=120) {
 return @{version=1;cursor=7;tasks=@(@{id='codex:s1:t1';taskId='codex:s1:t1';providerId='codex';adapterId='codex-local';mode='observed';projectId=$null;sessionId='s1';runId=$null;turnId='t1';state='running';model='fixture';startedAt='2026-10-18T10:00:00Z';endedAt=$null;updatedAt='2026-10-18T10:01:00Z';elapsedSeconds=60;operationCount=2;activeOperations=1;usage=@{inputTokens=100;cachedInputTokens=$null;cacheWriteInputTokens=$null;outputTokens=20;reasoningOutputTokens=$null;totalTokens=$Tokens;estimatedUsd=$null;quality='exact';source='codex-local'};operations=@()});totals=@{totalTokens=$Tokens;estimatedUsd=$null};coverage=@();subscriptions=@();gateway=$null;nextOffset=$null}
}
Test 'Source replacement preserves native identity and never adds previous totals' {
 $state=New-RuntimeClientState;$totals=@();$local=ConvertTo-OperationsReport (New-TestRuntimeSnapshot)
 Assert-True (Set-RuntimeOperationsReport $state $local 'local' $state.Generation);$totals+= $state.Report.Totals.TotalTokens
 $generation=Set-RuntimeSource $state 'unified';Assert-True (Set-RuntimeOperationsReport $state (ConvertTo-OperationsReport (New-TestRuntimeSnapshot)) 'unified' $generation);$totals+=$state.Report.Totals.TotalTokens
 Register-RuntimeFailure $state;Assert-Equal $state.Source 'unified';Assert-True $state.Stale;Assert-Equal $state.Report.Turns[0].Status 'Em andamento'
 Register-RuntimeFailure $state;Register-RuntimeFailure $state;Assert-Equal $state.Source 'local'
 Assert-True (Set-RuntimeOperationsReport $state $local 'local' $state.Generation);$totals+=$state.Report.Totals.TotalTokens
 $generation=Set-RuntimeSource $state 'unified';Assert-True (Set-RuntimeOperationsReport $state (ConvertTo-OperationsReport (New-TestRuntimeSnapshot 140)) 'unified' $generation);$totals+=$state.Report.Totals.TotalTokens
 Assert-Equal ($totals -join ',') '120,120,120,140';Assert-Equal $state.Report.Turns[0].Id 'codex:s1:t1'
}
Test 'Results from an invalidated local generation cannot replace unified report' {
 $state=New-RuntimeClientState;$old=$state.Generation;$report=ConvertTo-OperationsReport (New-TestRuntimeSnapshot)
 [void](Set-RuntimeSource $state 'unified');[void](Set-RuntimeOperationsReport $state $report 'unified' $state.Generation)
 Assert-Equal (Set-RuntimeOperationsReport $state @{Turns=@();Totals=@{TotalTokens=999}} 'local' $old) $false
 Assert-Equal $state.Report.Totals.TotalTokens 120
}
Test 'Snapshot adapter preserves missing metrics and terminal outcome' {
 $snapshot=New-TestRuntimeSnapshot;$snapshot.tasks[0].usage.totalTokens=$null;$snapshot.tasks[0].usage.inputTokens=$null;$snapshot.tasks[0].state='interrupted'
 $report=ConvertTo-OperationsReport $snapshot
 Assert-Equal $report.Turns[0].TotalTokens $null;Assert-Equal $report.Turns[0].InputTokens $null;Assert-Equal $report.Turns[0].EstimatedUsd $null
 Assert-Equal $report.Turns[0].Status 'Interrompido';Assert-Equal $report.Turns[0].Operation 'Tarefa observada';Assert-Equal $report.Source 'unified'
}
Test 'Mixed unknown and completed tasks remain a healthy unified snapshot without invented time' {
 $snapshot=New-TestRuntimeSnapshot;$unknown=$snapshot.tasks[0];$unknown.state='unknown';$unknown.elapsedSeconds=$null
 $completed=(New-TestRuntimeSnapshot).tasks[0];$completed.id='codex:s1:t2';$completed.taskId='codex:s1:t2';$completed.turnId='t2';$completed.state='completed';$completed.endedAt='2026-10-18T10:01:00Z'
 $snapshot.tasks=@($unknown,$completed);$snapshot.totals.totalTokens=240
 $state=New-RuntimeClientState;[void](Set-RuntimeSource $state 'unified')
 $json=ConvertTo-Json $snapshot -Depth 12 -Compress;$state.Request=[scriptblock]::Create("'"+$json.Replace("'","''")+"'")
 try {
  Assert-True (Start-RuntimePoll $state)
  $deadline=[datetimeoffset]::UtcNow.AddSeconds(3);$received=$null
  while ($state.Poll -and [datetimeoffset]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 20;$received=Receive-RuntimePoll $state}
  Assert-True ($null -ne $received);Assert-Equal $state.Failures 0;Assert-Equal $state.Source 'unified';Assert-Equal $state.Stale $false
  $report=ConvertTo-OperationsReport $received
  Assert-True (Set-RuntimeOperationsReport $state $report 'unified' $state.Generation)
  Assert-Equal $report.Turns.Count 2;Assert-Equal $report.Turns[0].Status 'Desconhecido';Assert-Equal $report.Turns[0].State 'unknown';Assert-Equal $report.Turns[0].ElapsedSeconds $null
  Assert-Equal $report.Turns[1].Status 'Concluido';Assert-Equal $report.Turns[1].ElapsedSeconds 60;Assert-Equal $report.Totals.TotalTokens 240
 } finally {Stop-RuntimePoll $state}
}
Test 'Malformed snapshots are rejected before replacing valid data' {
 $snapshot=New-TestRuntimeSnapshot;$snapshot.version=9;Assert-Throws {ConvertTo-OperationsReport $snapshot}
 $snapshot=New-TestRuntimeSnapshot;$snapshot.tasks[0].usage.totalTokens=-1;Assert-Throws {ConvertTo-OperationsReport $snapshot}
 $snapshot=New-TestRuntimeSnapshot;$snapshot.tasks[0].state='arbitrary';Assert-Throws {ConvertTo-OperationsReport $snapshot}
}
Test 'Runtime polling returns immediately and maintains one pending request' {
 $state=New-RuntimeClientState;$state.Request={Start-Sleep -Milliseconds 800;New-Object psobject -Property @{version=1;cursor=1;tasks=@();totals=@{totalTokens=$null};coverage=@();subscriptions=@();gateway=$null;nextOffset=$null}}
 $clock=[Diagnostics.Stopwatch]::StartNew()
 try {
  Assert-True (Start-RuntimePoll $state);Assert-True ($clock.ElapsedMilliseconds -lt 600);Assert-Equal (Start-RuntimePoll $state) $false
  Assert-Equal (Receive-RuntimePoll $state) $null
  $deadline=[datetimeoffset]::UtcNow.AddSeconds(6);$snapshot=$null
  while (-not $snapshot -and [datetimeoffset]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 40;$snapshot=Receive-RuntimePoll $state}
  Assert-Equal $snapshot.version 1;Assert-Equal $state.Failures 0;Assert-Equal $state.Poll $null
 } finally {Stop-RuntimePoll $state}
}
Test 'Closing runtime client cancels outstanding poll and prevents restart' {
 $state=New-RuntimeClientState;$state.Request={Start-Sleep -Seconds 5};[void](Start-RuntimePoll $state)
 Stop-RuntimePoll $state;Assert-Equal $state.Poll $null;Assert-Equal (Start-RuntimePoll $state) $false
}
Test 'Hung runtime request times out asynchronously without changing task outcome' {
 $state=New-RuntimeClientState;$state.Request={Start-Sleep -Seconds 8};$state.Report=ConvertTo-OperationsReport (New-TestRuntimeSnapshot)
 try {
  [void](Start-RuntimePoll $state);$state.Poll.StartedAt=[datetimeoffset]::UtcNow.AddSeconds(-3)
  $clock=[Diagnostics.Stopwatch]::StartNew();Assert-Equal (Receive-RuntimePoll $state) $null;Assert-True ($clock.ElapsedMilliseconds -lt 500)
  $deadline=[datetimeoffset]::UtcNow.AddSeconds(1)
  while ($state.Poll -and [datetimeoffset]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 20;[void](Receive-RuntimePoll $state)}
  Assert-Equal $state.Poll $null;Assert-Equal $state.Failures 1;Assert-Equal $state.Report.Turns[0].Status 'Em andamento'
 } finally {Stop-RuntimePoll $state}
}
Test 'Unified takeover drains local reader before exposing new report' {
 $state=New-RuntimeClientState;$state.LocalRequest={param($telemetry,$path) Start-Sleep -Seconds 4;@{Turns=@(@{Id='codex:s1:t1';TotalTokens=999});Totals=@{TotalTokens=999}}}
 try {
  Assert-True (Start-RuntimeLocalCollection $state @{});Assert-Equal (Start-RuntimeLocalCollection $state @{}) $false
  $state.PendingSnapshot=New-TestRuntimeSnapshot;[void](Set-RuntimeSource $state 'unified')
  [void](Stop-RuntimeLocalCollection $state)
  $deadline=[datetimeoffset]::UtcNow.AddSeconds(5)
  while ($state.LocalPoll -and [datetimeoffset]::UtcNow -lt $deadline) {[void](Receive-RuntimeLocalCollection $state);Start-Sleep -Milliseconds 20}
  Assert-Equal $state.LocalPoll $null;Assert-Equal $state.Report $null
  Assert-True (Set-RuntimeOperationsReport $state (ConvertTo-OperationsReport $state.PendingSnapshot) 'unified' $state.Generation)
  Assert-Equal $state.Report.Totals.TotalTokens 120
 } finally {Stop-RuntimePoll $state}
}
Test 'Panel runtime transition applies unified report and ignores stopped local work' {
 $parseErrors=$null;$tokens=$null;$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Start-AIBattery.ps1'),[ref]$tokens,[ref]$parseErrors)
 Assert-Equal @($parseErrors).Count 0
 $function=$tree.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-PanelRuntime'},$true)
 Assert-True ($null -ne $function)
 . ([scriptblock]::Create($function.Extent.Text))
 $runtime=New-RuntimeClientState;$runtime.Request={throw 'fixture offline'};$runtime.LocalRequest={Start-Sleep -Seconds 4;@{Turns=@();Totals=@{TotalTokens=999}}}
 $script:State=@{Runtime=$runtime;Telemetry=@{}};$script:PaintedReport=$null
 function Set-OperationsReport($Report) {$script:PaintedReport=$Report}
 try {
  [void](Start-RuntimeLocalCollection $runtime @{});$runtime.PendingSnapshot=New-TestRuntimeSnapshot
  $deadline=[datetimeoffset]::UtcNow.AddSeconds(5)
  while (-not $script:PaintedReport -and [datetimeoffset]::UtcNow -lt $deadline) {Update-PanelRuntime;Start-Sleep -Milliseconds 20}
  Assert-Equal $runtime.Source 'unified';Assert-Equal $runtime.LocalPoll $null;Assert-Equal $script:PaintedReport.Totals.TotalTokens 120
 } finally {Stop-RuntimePoll $runtime}
}
