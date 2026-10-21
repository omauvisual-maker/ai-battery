Import-Module "$PSScriptRoot\..\src\Telemetry.psm1" -Force
Test 'Discovery covers twelve files within a byte budget and resumes private checkpoints' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  foreach($i in 1..12) {
   $lines=@(@{type='session_meta';payload=@{id="session-$i";cwd='C:\Synthetic'}},@{timestamp='2026-10-18T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='t'}})
   [IO.File]::WriteAllText((Join-Path $dir "rollout-$i.jsonl"),(($lines|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 9}) -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  }
  $s=New-TelemetryState;$events=@();$first=Read-TelemetryBatch $s $dir 500
  Assert-True ($first.Coverage.pendingFiles -gt 0);Assert-True ($first.Coverage.bytesRead -le 500);$events+=@($first.Events)
  foreach($n in 1..20) {$batch=Read-TelemetryBatch $s $dir 500;$events+=@($batch.Events);if($batch.Coverage.pendingFiles -eq 0){break}}
  Assert-Equal $s.Files.Count 12;Assert-Equal @($events|Where-Object type -eq 'run.started').Count 12
  Assert-Equal @($events|Where-Object quality -ne 'historical').Count 0
  $restore=New-TelemetryState;Restore-TelemetryCheckpoint $restore ($batch.Checkpoint|ConvertTo-Json -Depth 30|ConvertFrom-Json)
  $replayed=Read-TelemetryBatch $restore $dir 500;Assert-Equal @($replayed.Events).Count 0
  Assert-Equal $replayed.SourceContext.sessions.'session-1'.cwd 'C:\Synthetic'
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Fragmented UTF8 and oversized lines preserve the next complete fact' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-fragment.jsonl';$secret='synthetic-'+[char]0x00e9
  $line=@{type='session_meta';payload=@{id='utf8';cwd=$secret}}|ConvertTo-Json -Compress
  [IO.File]::WriteAllText($path,$line,[Text.UTF8Encoding]::new($false));$s=New-TelemetryState
  foreach($n in 1..30) {$b=Read-TelemetryBatch $s $dir 7}
  Assert-Equal @($b.Events).Count 0
  [IO.File]::AppendAllText($path,"`r`n"+('x'*(4*1024*1024+20))+"`n"+'{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"after"}}'+"`n",[Text.UTF8Encoding]::new($false))
  $all=@();foreach($n in 1..12){$b=Read-TelemetryBatch $s $dir 1048576;$all+=@($b.Events)}
  Assert-Equal @($all|Where-Object type -eq 'run.started').Count 1
  Assert-Equal $b.SourceContext.sessions.utf8.cwd $secret
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Checkpoint excludes partial source text and byte prefixes' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-private.jsonl';$private='{"type":"event_msg","payload":{"type":"agent_message","text":"'+('SECRET'*80)
  [IO.File]::WriteAllText($path,$private,[Text.UTF8Encoding]::new($false));$s=New-TelemetryState;$b=Read-TelemetryBatch $s $dir 1024
  $cursor=$b.Checkpoint.files[$path];Assert-Equal $cursor.Offset 0;Assert-Equal $cursor.Fragment $null
  Assert-Equal $b.Coverage.backfillComplete $false;Assert-Equal $b.Coverage.pendingFiles 1
  Assert-Equal ([Convert]::FromBase64String($cursor.Prefix)).Length 32
  Assert-True (($b.Checkpoint|ConvertTo-Json -Depth 30) -notmatch 'SECRET')
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Invalid UTF8 record is skipped without hiding a later fact or other files' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-invalid-utf8.jsonl';$good=[Text.Encoding]::UTF8.GetBytes('{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"survives"}}'+"`n")
  [IO.File]::WriteAllBytes($path,([byte[]]@(255,10)+$good));$s=New-TelemetryState;$batch=Read-TelemetryBatch $s $dir
  Assert-Equal $batch.Events.Count 1;Assert-Equal $batch.Coverage.ignoredFiles 1;Assert-Equal $batch.Coverage.status 'partial'
  $after=Read-TelemetryBatch $s $dir;Assert-Equal $after.Events.Count 0;Assert-Equal $after.Coverage.ignoredFiles 1
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Append rotation truncation and discovery preserve native event identity' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-original.jsonl';$meta='{"type":"session_meta","payload":{"id":"stable"}}'+"`n";$start='{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}'+"`n"
  [IO.File]::WriteAllText($path,$meta+$start,[Text.UTF8Encoding]::new($false));$s=New-TelemetryState;$first=Read-TelemetryBatch $s $dir
  Assert-Equal $first.Events[0].quality 'historical'
  [IO.File]::AppendAllText($path,'{"timestamp":"2026-10-18T12:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t"}}'+"`n")
  $append=Read-TelemetryBatch $s $dir;Assert-Equal $append.Events[0].quality 'reported'
  $rotated=Join-Path $dir 'rollout-rotated.jsonl';[IO.File]::Copy($path,$rotated);$s.DiscoveredAtUtc='2026-01-01T00:00:00Z';$rotation=Read-TelemetryBatch $s $dir
  Assert-Equal $rotation.Events[0].eventId $first.Events[0].eventId
  [IO.File]::WriteAllText($path,$meta+$start,[Text.UTF8Encoding]::new($false));$truncated=Read-TelemetryBatch $s $dir
  Assert-Equal $truncated.Events[0].eventId $first.Events[0].eventId
  Assert-Equal @(@($first.Events)+@($append.Events)+@($rotation.Events)+@($truncated.Events)|ForEach-Object {$_.taskId}|Select-Object -Unique).Count 1
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Fact collection leaves WPF reduction to its bounded standalone facade' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-facts-only.jsonl';[IO.File]::WriteAllText($path,'{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}'+"`n",[Text.UTF8Encoding]::new($false))
  $s=New-TelemetryState;$b=Read-TelemetryBatch $s $dir;Assert-Equal @($b.Events).Count 1;Assert-Equal $s.Turns.Count 0
  $local=New-TelemetryState;Update-CodexTelemetry $local $dir;Assert-Equal $local.Turns.Count 1
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'A full batch leaves offset before the first unsent event' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
  $path=Join-Path $dir 'rollout-bounded.jsonl';$lines=@('{"type":"session_meta","payload":{"id":"bounded"}}');foreach($i in 1..100){$lines+='{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"item_started","turn_id":"t","item":{"id":"i'+$i+'"}}}'}
  [IO.File]::WriteAllText($path,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false));$s=New-TelemetryState;$one=Read-TelemetryBatch $s $dir 4194304 2200
  Assert-True ($one.Events.Count -lt 100);$restore=New-TelemetryState;Restore-TelemetryCheckpoint $restore $one.Checkpoint;$all=@($one.Events)
  foreach($n in 1..100){$b=Read-TelemetryBatch $restore $dir 4194304 2200;$all+=@($b.Events);if($b.Coverage.pendingFiles -eq 0){break}}
  Assert-Equal $all.Count 100;Assert-Equal @($all.eventId|Select-Object -Unique).Count 100
 } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
}
