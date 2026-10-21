Import-Module "$PSScriptRoot\..\src\Telemetry.psm1" -Force
Import-Module "$PSScriptRoot\..\src\Desktop.psm1" -Force -DisableNameChecking
Test 'Codex window policy requires a restored visible desktop window' {
 Assert-Equal (Test-CodexWindowReady @(@{Visible=$true;Minimized=$true})) $false
 Assert-Equal (Test-CodexWindowReady @(@{Visible=$true;Minimized=$false})) $true
 Assert-Equal (Test-CodexWindowReady @()) $false
}
Test 'Turn usage is attributed once and tool payload content discarded' {
 $s=New-TelemetryState;$f=New-TelemetryFile
 Add-TelemetryEvent $s $f @{timestamp='2026-10-13T12:00:00Z';type='task_started';payload=@{}} # ignored shape
 Add-TelemetryEvent $s $f @{timestamp='2026-10-13T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='t1'}}
 Add-TelemetryEvent $s $f @{type='turn_context';payload=@{model='gpt-6.1-sol'}}
 $e=@{timestamp='2026-10-13T12:00:10Z';type='token_usage_record';payload=@{turn_id='t1';response_id='r1';usage=@{input_tokens=1000;cached_input_tokens=800;output_tokens=100;total_tokens=1100}}}
 Add-TelemetryEvent $s $f $e;Add-TelemetryEvent $s $f $e
 Add-TelemetryEvent $s $f @{timestamp='2026-10-13T12:00:11Z';type='event_msg';payload=@{type='item_started';turn_id='t1';item=@{type='CommandExecution';id='i1';command='SECRET';aggregated_output='SECRET'}}}
 $r=Get-TelemetryReport $s ([datetimeoffset]'2026-10-13T12:00:20Z');Assert-Equal $r.Turns.Count 1
 Assert-Equal $r.Turns[0].TotalTokens 1100;Assert-Equal $r.Turns[0].ElapsedSeconds 20
 Assert-Equal ([math]::Round($r.Turns[0].EstimatedUsd,6)) 0.00148
 Assert-True (($s|ConvertTo-Json -Depth 12) -notmatch 'SECRET')
 Add-TelemetryEvent $s $f @{timestamp='2026-10-13T12:00:30Z';type='event_msg';payload=@{type='task_complete';turn_id='t1'}}
 Assert-Equal (Get-TelemetryReport $s ([datetimeoffset]'2026-10-13T13:00:00Z')).Turns[0].ElapsedSeconds 30
}
Test 'Missing usage and unknown price are not zero-dollar claims' {
 Assert-Equal (Get-TokenEstimate 'unknown' @{input_tokens=100;output_tokens=10}) $null
 $s=New-TelemetryState;$f=New-TelemetryFile;Add-TelemetryEvent $s $f @{timestamp='2026-10-13T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='t2'}}
 $r=Get-TelemetryReport $s ([datetimeoffset]'2026-10-13T12:01:00Z');Assert-Equal $r.Turns[0].TotalTokens $null;Assert-Equal $r.Turns[0].EstimatedUsd $null
}
Test 'Partial append is consumed only after newline and never counted twice' {
 $dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
 try {
 $path=Join-Path $dir 'rollout-test.jsonl';$line='{"timestamp":"2026-10-13T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"p1"}}'
 [IO.File]::WriteAllText($path,$line,[Text.UTF8Encoding]::new($false));$s=New-TelemetryState
 Update-CodexTelemetry $s $dir;Assert-Equal $s.Turns.Count 0
 [IO.File]::AppendAllText($path,"`n");Update-CodexTelemetry $s $dir;Update-CodexTelemetry $s $dir;Assert-Equal $s.Turns.Count 1
 } finally {Remove-Item -LiteralPath $path;[IO.Directory]::Delete($dir)}
}
Test 'Oversized rollout content cannot block later telemetry' {
 Initialize-TelemetryReader;$path=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString()+'.jsonl')
 try {
  [IO.File]::WriteAllText($path,('x'*(5*1024*1024))+"`n"+'{"timestamp":"2026-10-13T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"after-large"}}'+"`n",[Text.UTF8Encoding]::new($false))
  $a=[AIBattery.RolloutReader]::Read($path,0,$false);Assert-True ($a.Offset -gt 0);Assert-True $a.Skipping
  $b=[AIBattery.RolloutReader]::Read($path,$a.Offset,$a.Skipping);Assert-True (($b.Lines -join '') -match 'after-large');Assert-Equal $b.Skipping $false
 } finally {Remove-Item -LiteralPath $path}
}
Test 'First turn in a new local session has a zero cumulative baseline' {
 $s=New-TelemetryState;$f=New-TelemetryFile
 Add-TelemetryEvent $s $f @{type='session_meta';payload=@{}}
 Add-TelemetryEvent $s $f @{type='turn_context';payload=@{model='gpt-6.1-sol'}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-13T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='first'}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-13T12:00:10Z';type='event_msg';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=100;cached_input_tokens=0;output_tokens=10}}}}
 Assert-Equal (Get-TelemetryReport $s).Turns[0].TotalTokens 110
}
