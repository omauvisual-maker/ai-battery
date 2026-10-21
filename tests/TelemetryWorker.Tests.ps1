Import-Module "$PSScriptRoot\..\src\Telemetry.psm1" -Force
Test 'Worker emits bounded UTF8 batches, waits for ACK and resumes confirmed checkpoint' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 $worker=Join-Path $PSScriptRoot '..\tools\Watch-RuntimeTelemetry.ps1';$process=$null
 try {
  $path=Join-Path $dir 'rollout-worker.jsonl';$meta='{"type":"session_meta","payload":{"id":"worker-session","cwd":"C:\\Synthetic","prompt":"SECRET"}}'
  $started='{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"worker-turn"}}'
  [IO.File]::WriteAllText($path,$meta+"`n"+$started+"`n",[Text.UTF8Encoding]::new($false))
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName='powershell.exe';$info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$worker+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
  $process=[Diagnostics.Process]::Start($info)
  $init=@{type='init';checkpoint=$null;config=@{directory=$dir;pollIntervalMs=50}}|ConvertTo-Json -Compress -Depth 30;$process.StandardInput.WriteLine($init);$process.StandardInput.Flush()
  $read=$process.StandardOutput.ReadLineAsync();Assert-True $read.Wait(15000);$line=$read.Result;Assert-True ([Text.Encoding]::UTF8.GetByteCount($line) -le 262144)
  $first=ConvertFrom-Json $line;Assert-Equal $first.type 'batch';Assert-Equal @($first.events).Count 1;Assert-True ($line -notmatch 'SECRET')
  [IO.File]::AppendAllText($path,'{"timestamp":"2026-10-18T12:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"worker-turn"}}'+"`n")
  $next=$process.StandardOutput.ReadLineAsync();Assert-Equal $next.Wait(200) $false
  $process.StandardInput.WriteLine((@{type='ack';batchId=$first.batchId}|ConvertTo-Json -Compress));$process.StandardInput.Flush();Assert-True $next.Wait(15000)
  $second=ConvertFrom-Json $next.Result;Assert-Equal @($second.events|Where-Object type -eq 'run.completed').Count 1;Assert-Equal $second.events[0].quality 'reported'
  $process.StandardInput.WriteLine('{"type":"stop"}');$process.StandardInput.Flush();Assert-True $process.WaitForExit(5000);Assert-Equal $process.ExitCode 0
  $state=New-TelemetryState;Restore-TelemetryCheckpoint $state $first.checkpoint;$resumed=Read-TelemetryBatch $state $dir
  Assert-Equal @($resumed.Events|Where-Object type -eq 'run.completed').Count 1
  Assert-Equal $resumed.Events[0].eventId $second.events[0].eventId
 } finally {if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()};if($process){$process.Dispose()};Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Worker default directory is resolved inside its supplied synthetic user profile' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());$sessions=Join-Path $dir '.codex\sessions';[void][IO.Directory]::CreateDirectory($sessions);$process=$null
 try {
  $path=Join-Path $sessions 'rollout-default.jsonl';[IO.File]::WriteAllText($path,'{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"default"}}'+"`n",[Text.UTF8Encoding]::new($false))
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName='powershell.exe';$info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot '..\tools\Watch-RuntimeTelemetry.ps1')+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.EnvironmentVariables['USERPROFILE']=$dir
  $process=[Diagnostics.Process]::Start($info);$process.StandardInput.WriteLine('{"type":"init","config":{"directory":null,"pollIntervalMs":50}}');$process.StandardInput.Flush()
  $read=$process.StandardOutput.ReadLineAsync();Assert-True $read.Wait(15000);$batch=ConvertFrom-Json $read.Result
  Assert-Equal $batch.type 'batch';Assert-Equal $batch.events[0].turnId 'default'
  $process.StandardInput.WriteLine('{"type":"stop"}');$process.StandardInput.Flush();Assert-True $process.WaitForExit(5000);Assert-Equal $process.ExitCode 0
 } finally {if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()};if($process){$process.Dispose()};Remove-Item -LiteralPath $dir -Recurse -Force}
}
Test 'Worker rejects an oversized unfinished frame without waiting for newline' {
 $process=$null
 try {
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName='powershell.exe';$info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot '..\tools\Watch-RuntimeTelemetry.ps1')+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $process=[Diagnostics.Process]::Start($info);$process.StandardInput.Write(('x'*262145));$process.StandardInput.Flush()
  $read=$process.StandardOutput.ReadLineAsync();Assert-True $read.Wait(3000)
  $errorFrame=ConvertFrom-Json $read.Result;Assert-Equal $errorFrame.code 'TELEMETRY_WORKER_FAILED';Assert-True $process.WaitForExit(3000);Assert-Equal $process.ExitCode 1
 } finally {if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()};if($process){$process.Dispose()}}
}
Test 'Worker compresses private checkpoints and splits large source context before committing offsets' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir);$process=$null
 try {
  foreach($i in 1..9) {
   $lines=@(@{type='session_meta';payload=@{id="large-$i";cwd=('C:\'+('p'*30000))}},@{timestamp='2026-10-18T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='t'}})
   [IO.File]::WriteAllText((Join-Path $dir "rollout-$i.jsonl"),(($lines|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 9}) -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  }
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName='powershell.exe';$info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot '..\tools\Watch-RuntimeTelemetry.ps1')+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $process=[Diagnostics.Process]::Start($info);$process.StandardInput.WriteLine((@{type='init';checkpoint=$null;config=@{directory=$dir;pollIntervalMs=50}}|ConvertTo-Json -Compress -Depth 10));$process.StandardInput.Flush()
  $read=$process.StandardOutput.ReadLineAsync();Assert-True $read.Wait(15000);$line=$read.Result;Assert-True ([Text.Encoding]::UTF8.GetByteCount($line) -le 262144);$first=ConvertFrom-Json $line
  Assert-Equal $first.type 'batch';Assert-Equal $first.checkpoint.encoding 'gzip-base64';Assert-True (@($first.events).Count -lt 9)
  $all=@($first.events);$current=$first
  foreach($n in 1..12) {
   if($all.Count -eq 9){break}
   $process.StandardInput.WriteLine((@{type='ack';batchId=$current.batchId}|ConvertTo-Json -Compress));$process.StandardInput.Flush()
   $read=$process.StandardOutput.ReadLineAsync();Assert-True $read.Wait(15000);Assert-True ([Text.Encoding]::UTF8.GetByteCount($read.Result) -le 262144);$current=ConvertFrom-Json $read.Result;$all+=@($current.events)
  }
  Assert-Equal $all.Count 9;Assert-Equal @($all.eventId|Select-Object -Unique).Count 9
  $restored=New-TelemetryState;Restore-TelemetryCheckpoint $restored $current.checkpoint;Assert-Equal @((Read-TelemetryBatch $restored $dir).Events).Count 0
  $process.StandardInput.WriteLine('{"type":"stop"}');$process.StandardInput.Flush();Assert-True $process.WaitForExit(5000);Assert-Equal $process.ExitCode 0
 } finally {if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()};if($process){$process.Dispose()};Remove-Item -LiteralPath $dir -Recurse -Force}
}
