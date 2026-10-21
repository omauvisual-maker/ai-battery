# Private host protocol. Only sanitized facts are public; checkpoint/cwd stay on the host.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot '..\src\Telemetry.psm1') -Force -WarningAction SilentlyContinue
Initialize-TelemetryReader
function Read-WorkerFrame([string]$Line) {
 if($null -eq $Line){return $null}
 if([Text.Encoding]::UTF8.GetByteCount($Line) -gt 262144){throw 'FRAME_LIMIT'}
 $frame=ConvertFrom-Json $Line -ErrorAction Stop
 if($frame.type -notin @('init','ack','stop')){throw 'INVALID_FRAME'}
 return $frame
}
function Compress-WorkerCheckpoint($Checkpoint) {
 $json=$Checkpoint|ConvertTo-Json -Depth 30 -Compress
 if([Text.Encoding]::UTF8.GetByteCount($json) -le 65536){return $Checkpoint}
 $memory=[IO.MemoryStream]::new();$gzip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Compress,$true)
 try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$gzip.Write($bytes,0,$bytes.Length)}finally{$gzip.Dispose()}
 try{return @{version=1;encoding='gzip-base64';data=[Convert]::ToBase64String($memory.ToArray())}}finally{$memory.Dispose()}
}
try {
 $init=Read-WorkerFrame ([AIBattery.RolloutReader]::ReadProtocolFrame())
 if(-not $init -or $init.type -ne 'init'){throw 'INVALID_INIT'}
 $directory=$init.config.directory
 if($null -eq $directory){$directory=Join-Path $env:USERPROFILE '.codex\sessions'}
 if($directory -isnot [string] -or -not [IO.Path]::IsPathRooted($directory)){throw 'INVALID_INIT'}
 $directory=[IO.Path]::GetFullPath($directory)
 $poll=2000;if($null -ne $init.config.pollIntervalMs){$poll=[int]$init.config.pollIntervalMs;if($poll -lt 20 -or $poll -gt 30000){throw 'INVALID_INTERVAL'}}
 $state=New-TelemetryState;Restore-TelemetryCheckpoint $state $init.checkpoint
 $pending=$null;$nextPoll=[datetimeoffset]::MinValue;$read=[AIBattery.RolloutReader]::ReadProtocolLine()
 while($true) {
  if($read.IsCompleted) {
   $frame=Read-WorkerFrame $read.Result
   if(-not $frame -or $frame.type -eq 'stop'){break}
   if($frame.type -ne 'ack' -or -not $pending -or $frame.batchId -ne $pending){throw 'INVALID_ACK'}
   $pending=$null;$nextPoll=[datetimeoffset]::UtcNow.AddMilliseconds($poll);$read=[AIBattery.RolloutReader]::ReadProtocolLine()
  }
  if(-not $pending -and [datetimeoffset]::UtcNow -ge $nextPoll) {
   $before=Get-TelemetryCheckpoint $state;$limit=65536
   while($true) {
    $batch=Read-TelemetryBatch $state $directory 4194304 $limit
    # Only sessions referenced by this frame need cwd for host-side project matching.
    $contexts=@{};foreach($event in $batch.Events){if($batch.SourceContext.sessions.ContainsKey($event.sessionId)){$contexts[$event.sessionId]=$batch.SourceContext.sessions[$event.sessionId]}}
    $id=[guid]::NewGuid().ToString('N')
    $out=@{type='batch';batchId=$id;events=@($batch.Events);checkpoint=(Compress-WorkerCheckpoint $batch.Checkpoint);coverage=$batch.Coverage;sourceContext=@{sessions=$contexts}}
    $json=$out|ConvertTo-Json -Compress -Depth 35
    if([Text.Encoding]::UTF8.GetByteCount($json) -le 262144){break}
    if($limit -le 1024){throw 'CHECKPOINT_CAPACITY'}
    $state=New-TelemetryState;Restore-TelemetryCheckpoint $state $before;$limit=[int]($limit/2)
   }
   [Console]::Out.WriteLine($json);[Console]::Out.Flush();$pending=$id
  }
  Start-Sleep -Milliseconds 20
 }
 exit 0
}catch {
 # Error messages can contain source text or paths, so expose a fixed code only.
 [Console]::Out.WriteLine('{"type":"error","code":"TELEMETRY_WORKER_FAILED"}')
 [Console]::Out.Flush()
 exit 1
}
