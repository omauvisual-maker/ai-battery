Import-Module "$PSScriptRoot\..\src\Telemetry.psm1" -Force
function New-LiveFixture([string]$Directory) {
 $path=Join-Path $Directory 'rollout-backlog.jsonl'
 $lines=@('{"type":"session_meta","payload":{"id":"live-session","cwd":"C:\\Synthetic"}}','{"type":"turn_context","payload":{"model":"old-model"}}')
 foreach($i in 1..1000){$lines+='{"timestamp":"2026-10-18T10:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"old-'+$i+'"}}'}
 [IO.File]::WriteAllText($path,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false));return $path
}
Test 'Appended native operations and usage precede unfinished historical backfill' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=New-LiveFixture $dir;$s=New-TelemetryState;$initial=Read-TelemetryBatch $s $dir 4194304 2200
  Assert-True ($initial.Events.Count -lt 1000);Assert-True ($initial.Coverage.pendingFiles -gt 0)
  $append=@('{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"item_started","turn_id":"fresh","item":{"id":"new-item","type":"McpToolCall","arguments":"SECRET"}}}','{"timestamp":"2026-10-18T12:00:01Z","type":"token_usage_record","payload":{"turn_id":"fresh","response_id":"new-response","usage":{"input_tokens":40,"output_tokens":5}}}')
  [IO.File]::AppendAllText($path,($append -join "`n")+"`n",[Text.UTF8Encoding]::new($false));$next=Read-TelemetryBatch $s $dir 4194304 5000
  $live=@($next.Events|Where-Object turnId -eq 'fresh');Assert-Equal $live.Count 2
  Assert-Equal $next.Events[0].turnId 'fresh';Assert-Equal $live[0].sessionId 'live-session';Assert-Equal $live[0].model $null
  Assert-Equal $live[0].quality 'reported';Assert-Equal $live[1].usage.inputTokens 40
  Assert-Equal @($next.Events|Where-Object {$_.turnId -like 'old-*' -and $_.quality -ne 'historical'}).Count 0
  Assert-True ($next.Coverage.pendingFiles -gt 0);Assert-True (($next|ConvertTo-Json -Depth 35) -notmatch 'SECRET')
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Live lane checkpoint rewinds fragmented UTF8 without keeping private source bytes' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=New-LiveFixture $dir;$s=New-TelemetryState;$initial=Read-TelemetryBatch $s $dir 4194304 2200
  $line='{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"item_started","turn_id":"fresh-utf8","item":{"id":"'+[char]0x00e9+'","type":"McpToolCall","arguments":"SECRET"}}}'
  $bytes=[Text.Encoding]::UTF8.GetBytes($line+"`n");$split=[Array]::IndexOf($bytes,[byte]195)+1
  $stream=[IO.File]::Open($path,[IO.FileMode]::Append);try{$stream.Write($bytes,0,$split)}finally{$stream.Dispose()}
  $partial=Read-TelemetryBatch $s $dir 4194304 2200;Assert-Equal @($partial.Events|Where-Object turnId -eq 'fresh-utf8').Count 0
  $cp=$partial.Checkpoint;Assert-True ($null -ne $cp.files[$path].Live);Assert-Equal $cp.files[$path].Live.Fragment $null
  Assert-Equal $cp.files[$path].Live.Offset $initial.Checkpoint.files[$path].InitialLength
  Assert-True (($cp|ConvertTo-Json -Depth 35) -notmatch 'SECRET')
  $stream=[IO.File]::Open($path,[IO.FileMode]::Append);try{$stream.Write($bytes,$split,$bytes.Length-$split)}finally{$stream.Dispose()}
  $restored=New-TelemetryState;Restore-TelemetryCheckpoint $restored ($cp|ConvertTo-Json -Depth 35|ConvertFrom-Json)
  $resumed=Read-TelemetryBatch $restored $dir 4194304 5000;$facts=@($resumed.Events|Where-Object turnId -eq 'fresh-utf8');Assert-Equal $facts.Count 1;Assert-Equal $facts[0].quality 'reported'
  $again=Read-TelemetryBatch $restored $dir 4194304 5000;Assert-Equal @($again.Events|Where-Object turnId -eq 'fresh-utf8').Count 0
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Unread historical headers prove only live session identity without inheriting old turn state' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $original=New-LiveFixture $dir;$firstPath=Join-Path $dir 'rollout-a.jsonl';[IO.File]::Move($original,$firstPath)
  $lastPath=Join-Path $dir 'rollout-z.jsonl';$content=[IO.File]::ReadAllText($firstPath).Replace('live-session','unread-session');[IO.File]::WriteAllText($lastPath,$content,[Text.UTF8Encoding]::new($false))
  $s=New-TelemetryState;$initial=Read-TelemetryBatch $s $dir 4194304 1024;Assert-Equal $s.Files[$lastPath].SessionId $null
  [IO.File]::AppendAllText($lastPath,'{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"item_started","turn_id":"current","item":{"id":"identified","type":"McpToolCall"}}}'+"`n",[Text.UTF8Encoding]::new($false))
  $batch=Read-TelemetryBatch $s $dir 4194304 3000;$live=@($batch.Events|Where-Object turnId -eq 'current');Assert-Equal $live.Count 1;Assert-Equal $live[0].sessionId 'unread-session'
  Assert-Equal $live[0].taskId (Get-NativeTelemetryKey 'codex' 'unread-session' 'current');Assert-Equal $live[0].model $null
  Assert-Equal $batch.SourceContext.sessions.'unread-session'.cwd 'C:\Synthetic'
  [IO.File]::AppendAllText($lastPath,'{"timestamp":"2026-10-18T12:00:01Z","type":"event_msg","payload":{"type":"item_started","item":{"id":"unidentified","type":"McpToolCall"}}}'+"`n"+'{"timestamp":"2026-10-18T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9999,"output_tokens":999}}}}'+"`n",[Text.UTF8Encoding]::new($false))
  $next=Read-TelemetryBatch $s $dir 4194304 3000
  Assert-Equal @($next.Events|Where-Object {$_.quality -ne 'historical'}).Count 0
  Assert-Equal $s.Files[$lastPath].Live.CurrentTurn $null;Assert-Equal $s.Files[$lastPath].Live.TurnBaseline $null
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Live batches preserve every unsent append and do not mutate earlier checkpoint snapshots' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=New-LiveFixture $dir;$s=New-TelemetryState;$initial=Read-TelemetryBatch $s $dir 4194304 2200;$confirmed=$initial.Checkpoint
  $lines=@();foreach($i in 1..20){$lines+='{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"item_started","turn_id":"appended","item":{"id":"i'+$i+'","type":"McpToolCall"}}}'}
  [IO.File]::AppendAllText($path,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false));$all=@()
  foreach($n in 1..30){$batch=Read-TelemetryBatch $s $dir 4194304 2200;$all+=@($batch.Events|Where-Object turnId -eq 'appended');if($all.Count -eq 20){break}}
  Assert-Equal $all.Count 20;Assert-Equal @($all.eventId|Select-Object -Unique).Count 20
  Assert-Equal $confirmed.files[$path].Live.Offset $confirmed.files[$path].InitialLength
  Assert-True ($batch.Coverage.pendingFiles -gt 0)
  $restored=New-TelemetryState;Restore-TelemetryCheckpoint $restored $confirmed;$replay=Read-TelemetryBatch $restored $dir 4194304 2200
  Assert-Equal $replay.Events[0].eventId $all[0].eventId
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'A settled legacy checkpoint retains verified native turn baseline for live cumulative usage' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-legacy.jsonl';$records=@(
   @{type='session_meta';payload=@{id='legacy-session';cwd='C:\Synthetic'}},
   @{type='turn_context';payload=@{model='verified-model'}},
   @{timestamp='2026-10-18T10:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='previous'}},
   @{timestamp='2026-10-18T10:00:01Z';type='event_msg';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=100;output_tokens=10}}}},
   @{timestamp='2026-10-18T10:00:02Z';type='event_msg';payload=@{type='task_complete';turn_id='previous'}},
   @{timestamp='2026-10-18T10:00:03Z';type='event_msg';payload=@{type='task_started';turn_id='current'}}
  )
  [IO.File]::WriteAllText($path,(($records|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 12}) -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  $f=New-TelemetryFile;foreach($record in $records){[void](ConvertTo-TelemetryFacts $f $record)};$f.Offset=(Get-Item -LiteralPath $path).Length;$f.InitialLength=$f.Offset;$f.Creation=(Get-Item -LiteralPath $path).CreationTimeUtc.Ticks
  $s=New-TelemetryState;$s.Files[$path]=$f;$s.DiscoveredAtUtc=[datetimeoffset]::UtcNow.ToString('o');$checkpoint=Get-TelemetryCheckpoint $s
  [void]$checkpoint.files[$path].Remove('Live');[void]$checkpoint.files[$path].Remove('BackfillDone');[void]$checkpoint.files[$path].Remove('LiveReconciled')
  $restored=New-TelemetryState;Restore-TelemetryCheckpoint $restored ($checkpoint|ConvertTo-Json -Depth 35|ConvertFrom-Json)
  [IO.File]::AppendAllText($path,'{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"output_tokens":15}}}}'+"`n"+'{"timestamp":"2026-10-18T12:00:01Z","type":"event_msg","payload":{"type":"task_complete"}}'+"`n",[Text.UTF8Encoding]::new($false))
  $batch=Read-TelemetryBatch $restored $dir;$usage=@($batch.Events|Where-Object type -eq 'usage.updated');Assert-Equal $usage.Count 1
  Assert-Equal $usage[0].turnId 'current';Assert-Equal $usage[0].usage.inputTokens 40;Assert-Equal $usage[0].usage.outputTokens 5;Assert-Equal $usage[0].model 'verified-model';Assert-Equal $usage[0].quality 'reported'
  Assert-Equal @($batch.Events|Where-Object type -eq 'run.completed').Count 1
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Verified initial frontier reconciles once and historical reconstruction never produces stale live effects' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-reconcile.jsonl';$lines=@('{"type":"session_meta","payload":{"id":"recover-session","cwd":"C:\\Synthetic"}}','{"type":"turn_context","payload":{"model":"recovered-model"}}','{"timestamp":"2026-10-18T10:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}')
  foreach($i in 1..1000){$lines+='{"timestamp":"2026-10-18T10:00:01Z","type":"event_msg","payload":{"type":"item_started","turn_id":"current","item":{"id":"old-'+$i+'","type":"McpToolCall"}}}'}
  [IO.File]::WriteAllText($path,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false));$s=New-TelemetryState;$initial=Read-TelemetryBatch $s $dir 4194304 2200
  [IO.File]::AppendAllText($path,'{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":25,"output_tokens":4}}}}'+"`n",[Text.UTF8Encoding]::new($false))
  $unknown=Read-TelemetryBatch $s $dir 4194304 2200;Assert-Equal @($unknown.Events|Where-Object type -eq 'usage.updated').Count 0
  $recovered=@();foreach($n in 1..30){$batch=Read-TelemetryBatch $s $dir;$recovered+=@($batch.Events|Where-Object type -eq 'usage.updated');if($recovered.Count){break}}
  Assert-Equal $recovered.Count 1;Assert-Equal $recovered[0].turnId 'current';Assert-Equal $recovered[0].usage.inputTokens 25;Assert-Equal $recovered[0].quality 'historical'
  Assert-True $s.Files[$path].LiveReconciled;Assert-Equal $s.Files[$path].Live.Model 'recovered-model'
  [IO.File]::AppendAllText($path,'{"timestamp":"2026-10-18T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"output_tokens":6}}}}'+"`n",[Text.UTF8Encoding]::new($false))
  $fresh=Read-TelemetryBatch $s $dir;$freshUsage=@($fresh.Events|Where-Object type -eq 'usage.updated');Assert-Equal $freshUsage.Count 1;Assert-Equal $freshUsage[0].usage.inputTokens 30;Assert-Equal $freshUsage[0].quality 'reported'
  $empty=Read-TelemetryBatch $s $dir;Assert-Equal $empty.Events.Count 0
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'An initial incomplete source record remains historical when delayed backfill finishes it' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-initial-partial.jsonl';$lines=@('{"type":"session_meta","payload":{"id":"boundary-session","cwd":"C:\\Synthetic"}}')
  foreach($i in 1..300){$lines+='{"timestamp":"2026-10-18T10:00:00Z","type":"event_msg","payload":{"type":"item_started","turn_id":"old","item":{"id":"old-'+$i+'","type":"McpToolCall"}}}'}
  $partial='{"timestamp":"2026-10-18T10:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"boundary'
  [IO.File]::WriteAllText($path,($lines -join "`n")+"`n"+$partial,[Text.UTF8Encoding]::new($false));$s=New-TelemetryState;[void](Read-TelemetryBatch $s $dir 4194304 2200)
  [IO.File]::AppendAllText($path,'"}}'+"`n",[Text.UTF8Encoding]::new($false));$found=@()
  foreach($n in 1..20){$batch=Read-TelemetryBatch $s $dir 4194304 131072;$found+=@($batch.Events|Where-Object turnId -eq 'boundary');if($found.Count){break}}
  Assert-Equal $found.Count 1;Assert-Equal $found[0].quality 'historical';Assert-True $s.Files[$path].LiveReconciled
  [IO.File]::AppendAllText($path,'{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"item_started","turn_id":"boundary","item":{"id":"fresh","type":"McpToolCall"}}}'+"`n",[Text.UTF8Encoding]::new($false))
  $fresh=Read-TelemetryBatch $s $dir;Assert-Equal @($fresh.Events).Count 1;Assert-Equal $fresh.Events[0].quality 'reported'
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
