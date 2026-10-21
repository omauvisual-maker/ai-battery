Import-Module "$PSScriptRoot\..\src\Telemetry.psm1" -Force
Test 'Native identities match SHA256 JSON array and namespace sessions' {
 Assert-Equal (Get-NativeTelemetryKey 'codex' 'session-a' 'turn-1') '9268ee6c5ac55f50b5072b2ec7a30e8102745543f43eb93fcca6286b7a51caec'
 Assert-True ((Get-NativeTelemetryKey 'codex' 'session-a' 'turn-1') -ne (Get-NativeTelemetryKey 'codex' 'session-b' 'turn-1'))
}
Test 'Invalid explicit usage leaves identity available and valid explicit usage replaces fallback' {
 $s=New-TelemetryState;$f=New-TelemetryFile
 Add-TelemetryEvent $s $f @{type='session_meta';payload=@{id='session-a';cwd='C:\private'}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='turn-1'}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:01Z';type='event_msg';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=100;output_tokens=20}}}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:02Z';type='token_usage_record';payload=@{turn_id='turn-1';response_id='r1';usage=@{input_tokens=-1;output_tokens=5}}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:03Z';type='token_usage_record';payload=@{turn_id='turn-1';response_id='r1';usage=@{input_tokens=40;output_tokens=5}}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:04Z';type='token_usage_record';payload=@{turn_id='turn-1';response_id='r2';usage=@{input_tokens=60;output_tokens=15}}}
 Assert-Equal (Get-TelemetryReport $s).Turns[0].TotalTokens 120
}
Test 'Terminal status survives late operations and identical turns in separate sessions' {
 $s=New-TelemetryState
 foreach($session in @('a','b')) {
  $f=New-TelemetryFile;Add-TelemetryEvent $s $f @{type='session_meta';payload=@{id=$session}}
  Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='shared'}}
  Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:01Z';type='event_msg';payload=@{type='task_complete';turn_id='shared'}}
  Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:02Z';type='event_msg';payload=@{type='item_completed';turn_id='shared';item=@{id='i1';type='CommandExecution';command='SECRET'}}}
 }
 $report=Get-TelemetryReport $s;Assert-Equal $report.Turns.Count 2
 foreach($turn in $report.Turns) {Assert-Equal $turn.Status 'Concluido'}
}
Test 'Normalized facts preserve unknown counters and exclude private text' {
 $f=New-TelemetryFile
 [void](ConvertTo-TelemetryFacts $f @{type='session_meta';payload=@{id='safe-session';cwd='C:\SECRET';prompt='SECRET'}})
 $facts=@(ConvertTo-TelemetryFacts $f @{timestamp='2026-10-18T12:00:00Z';type='token_usage_record';payload=@{turn_id='t';response_id='r';usage=@{input_tokens=40;output_tokens=5};arguments='SECRET'}})
 Assert-Equal $facts.Count 1;Assert-Equal $facts[0].type 'usage.updated'
 Assert-Equal $facts[0].usage.cachedInputTokens $null;Assert-Equal $facts[0].usage.sourceTotalTokens $null
 Assert-True (($facts|ConvertTo-Json -Depth 20) -notmatch 'SECRET|arguments|prompt|cwd')
 Assert-Equal $facts[0].providerId 'codex';Assert-Equal $facts[0].version 1
 Assert-Equal @((ConvertTo-TelemetryFacts $f @{type='token_usage_record';payload=@{turn_id='t';response_id='bad';usage=@{input_tokens='invalid';output_tokens=5}}})).Count 0
}
Test 'Fact identity is stable through a reconstructed cursor and unknown sessions are partial' {
 $f=New-TelemetryFile;$f.Generation='synthetic-generation'
 $event=@{timestamp='2026-10-18T12:00:00Z';type='token_usage_record';payload=@{turn_id='t';response_id='r';usage=@{input_tokens=1;output_tokens=2}}}
 $one=@(ConvertTo-TelemetryFacts $f $event)[0]
 $other=New-TelemetryFile;$other.Generation='synthetic-generation';$two=@(ConvertTo-TelemetryFacts $other $event)[0]
 Assert-Equal $one.eventId $two.eventId;Assert-Equal $one.quality 'partial'
 Assert-Equal $one.sessionId 'partial:synthetic-generation'
 Assert-Equal @((ConvertTo-TelemetryFacts $f @{timestamp='2026-10-18T12:00:00Z';type='token_usage_record';payload=@{turn_id='t';response_id='r';usage=@{input_tokens=1;output_tokens=2;cached_input_tokens=2}}})).Count 0
}
Test 'Operation and response evidence identities encode turn and item without separator collisions' {
 $a=New-TelemetryFile;$b=New-TelemetryFile;$a.SessionId='s';$b.SessionId='s'
 $one=@(ConvertTo-TelemetryFacts $a @{timestamp='2026-10-18T12:00:00Z';type='token_usage_record';payload=@{turn_id='t:usage:r';response_id='x';usage=@{input_tokens=1;output_tokens=2}}})[0]
 $two=@(ConvertTo-TelemetryFacts $b @{timestamp='2026-10-18T12:00:00Z';type='token_usage_record';payload=@{turn_id='t';response_id='r:usage:x';usage=@{input_tokens=1;output_tokens=2}}})[0]
 Assert-True ($one.usage.evidenceId -ne $two.usage.evidenceId)
}
Test 'Missing source timestamp stays unknown instead of receiving a synthetic date' {
 $f=New-TelemetryFile;$f.SessionId='undated'
 $fact=@(ConvertTo-TelemetryFacts $f @{type='event_msg';payload=@{type='task_complete';turn_id='t'}})[0]
 Assert-Equal $fact.occurredAt $null;Assert-Equal $fact.quality 'partial'
}
Test 'A partial explicit response replaces fallback without turning unknown counters into zero' {
 $s=New-TelemetryState;$f=New-TelemetryFile
 Add-TelemetryEvent $s $f @{type='session_meta';payload=@{id='partial-usage'}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='t'}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:01Z';type='event_msg';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=100;output_tokens=20}}}}
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:02Z';type='token_usage_record';payload=@{turn_id='t';response_id='partial';usage=@{output_tokens=5}}}
 $row=(Get-TelemetryReport $s).Turns[0];Assert-Equal $row.TotalTokens $null;Assert-Equal $row.InputTokens $null;Assert-Equal $row.OutputTokens 5
}
Test 'Fresh evidence after initial backfill makes an unfinished local turn current' {
 $s=New-TelemetryState;$f=New-TelemetryFile;$f.Historical=$true
 Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:00Z';type='event_msg';payload=@{type='task_started';turn_id='t'}}
 Assert-Equal (Get-TelemetryReport $s).Turns[0].Status 'Historico'
 $f.Historical=$false;Add-TelemetryEvent $s $f @{timestamp='2026-10-18T12:00:01Z';type='event_msg';payload=@{type='item_started';turn_id='t';item=@{id='i';type='McpToolCall'}}}
 Assert-Equal (Get-TelemetryReport $s ([datetimeoffset]'2026-10-18T12:00:02Z')).Turns[0].Status 'Em andamento'
}
Test 'An explicit live turn context supplies its native ID without inferring historical state' {
 $f=New-TelemetryFile;$f.SessionId='context-session'
 [void](ConvertTo-TelemetryFacts $f @{type='turn_context';payload=@{model='live-model';turn_id='explicit-context-turn'}})
 $facts=@(ConvertTo-TelemetryFacts $f @{timestamp='2026-10-18T12:00:00Z';type='event_msg';payload=@{type='item_started';item=@{id='i';type='McpToolCall'}}})
 Assert-Equal $facts.Count 1;Assert-Equal $facts[0].turnId 'explicit-context-turn';Assert-Equal $facts[0].model 'live-model'
 Assert-Equal $f.TurnBaseline $null
}
