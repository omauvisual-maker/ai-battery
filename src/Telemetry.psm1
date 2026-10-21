function Initialize-TelemetryReader {
 if (-not ('AIBattery.RolloutReader' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'TelemetryNative.cs')}
}
function Get-NativeTelemetryKey([string]$Provider,[string]$Session,[string]$Turn) {
 Initialize-TelemetryReader
 return [AIBattery.RolloutReader]::Key([string[]]@($Provider,$Session,$Turn))
}
function New-TelemetryFile {
 return @{Offset=0L;Model=$null;CurrentTurn=$null;Baseline=$null;TurnBaseline=$null;LastWrite=0L;Skipping=$false;Fragment=$null;SessionId=$null;Cwd=$null;Generation=[guid]::NewGuid().ToString('N');InitialLength=0L;Creation=0L;Historical=$false;ReadError=$false;DroppedLines=0;Prefix=$null;Live=$null;BackfillDone=$false;LiveReconciled=$false}
}
function New-TelemetryState {return @{Files=@{};Turns=@{};ObservedAtUtc=$null;Error=$false;DiscoveredAtUtc=$null;RoundRobin=0}}
function Test-TelemetryIdentifier($Value) {return ($Value -is [string] -and $Value.Length -gt 0 -and $Value.Length -le 256 -and $Value -notmatch '[\x00-\x1f\x7f]')}
function ConvertTo-TelemetryUsage($Usage) {
 if ($null -eq $Usage) {return $null}
 $out=@{};$known=$false
 foreach($pair in @(@('input_tokens','inputTokens'),@('cached_input_tokens','cachedInputTokens'),@('cache_write_input_tokens','cacheWriteInputTokens'),@('output_tokens','outputTokens'),@('reasoning_output_tokens','reasoningOutputTokens'),@('total_tokens','sourceTotalTokens'))) {
  $value=$Usage.($pair[0]);$out[$pair[1]]=$null
  if($null -eq $value){continue}
  if($value -is [bool] -or $value -is [string]) {return $null}
  try {$number=[decimal]$value} catch {return $null}
  if($number -lt 0 -or $number -gt 9007199254740991 -or [decimal]::Truncate($number) -ne $number){return $null}
  $out[$pair[1]]=[long]$number;$known=$true
 }
 if(-not $known){return $null}
 if($null -ne $out.inputTokens -and (($null -ne $out.cachedInputTokens -and $out.cachedInputTokens -gt $out.inputTokens) -or ($null -ne $out.cacheWriteInputTokens -and $out.cacheWriteInputTokens -gt $out.inputTokens) -or ([decimal]$out.cachedInputTokens+[decimal]$out.cacheWriteInputTokens -gt $out.inputTokens))){return $null}
 if($null -ne $out.outputTokens -and $null -ne $out.reasoningOutputTokens -and $out.reasoningOutputTokens -gt $out.outputTokens){return $null}
 return $out
}
function ConvertTo-TelemetryFacts($File,$Event) {
 $p=$Event.payload;if($null -eq $p){return}
 if($Event.type -eq 'session_meta') {
  if(Test-TelemetryIdentifier $p.id){$File.SessionId=$p.id}
  if($p.cwd -is [string] -and $p.cwd.Length -le 32768 -and $p.cwd -notmatch '[\x00-\x1f]'){$File.Cwd=$p.cwd}
  if(-not $File.Baseline){$File.Baseline=@{input_tokens=0L;cached_input_tokens=0L;cache_write_input_tokens=0L;output_tokens=0L;reasoning_output_tokens=0L;total_tokens=0L}}
  return
 }
 if($Event.type -eq 'turn_context') {
  if((Test-TelemetryIdentifier $p.turn_id) -and $p.turn_id -ne $File.CurrentTurn){$File.CurrentTurn=$p.turn_id;$File.TurnBaseline=$File.Baseline}
  if($p.model -is [string] -and $p.model -match '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,127}$'){$File.Model=$p.model}
  return
 }
 $type=$null;$state=$null;$usage=$null;$evidence=$null;$operation=$null;$turn=$p.turn_id
 if($Event.type -eq 'token_usage_record') {
  if(-not (Test-TelemetryIdentifier $turn) -or -not (Test-TelemetryIdentifier $p.response_id)){return}
  $usage=ConvertTo-TelemetryUsage $p.usage;if(-not $usage){return}
  $usage.basis='response';$evidence=$p.response_id;$type='usage.updated'
 } elseif($Event.type -eq 'event_msg') {
  if(-not $turn){$turn=$File.CurrentTurn}
  if($p.type -eq 'token_count') {
   $total=$p.info.total_token_usage;$valid=ConvertTo-TelemetryUsage $total
   if(-not $valid){return}
   if($File.CurrentTurn -and $File.TurnBaseline) {
    $delta=@{};foreach($key in @('input_tokens','cached_input_tokens','cache_write_input_tokens','output_tokens','reasoning_output_tokens','total_tokens')) {
     $delta[$key]=$null;if($null -ne $total.$key -and $null -ne $File.TurnBaseline.$key){$delta[$key]=[long]$total.$key-[long]$File.TurnBaseline.$key}
    }
    $usage=ConvertTo-TelemetryUsage $delta
    if($usage){$usage.basis='turn_cumulative';$evidence='cumulative';$type='usage.updated';$turn=$File.CurrentTurn}
   }
   $File.Baseline=@{};foreach($key in @('input_tokens','cached_input_tokens','cache_write_input_tokens','output_tokens','reasoning_output_tokens','total_tokens')){$File.Baseline[$key]=$total.$key}
   if(-not $usage){return}
  } else {
   switch($p.type) {
    'task_started' {$type='run.started';$state='running';if(Test-TelemetryIdentifier $turn){$File.CurrentTurn=$turn;$File.TurnBaseline=$File.Baseline}}
    'task_complete' {$type='run.completed';$state='completed'}
    'turn_aborted' {$type='run.interrupted';$state='interrupted'}
    'item_started' {$type='operation.started';$state='running';$operation=$p.item.id}
    'item_completed' {$type='operation.completed';$state='completed';$operation=$p.item.id}
    default {return}
   }
  }
 } else {return}
 if(-not $type -or -not (Test-TelemetryIdentifier $turn)){return}
 $session=if($File.SessionId){$File.SessionId}else{'partial:'+$File.Generation}
 $native=Get-NativeTelemetryKey 'codex' $session $turn
 if($operation){if(-not (Test-TelemetryIdentifier $operation)){return};$operation=[AIBattery.RolloutReader]::Key([string[]]@('codex',$session,$turn,'item',$operation))}
 if($usage){$usage.evidenceId=[AIBattery.RolloutReader]::Key([string[]]@('codex',$session,$turn,'usage',$evidence))}
 $at=$null;try {if($Event.timestamp){$at=([datetimeoffset]$Event.timestamp).ToUniversalTime().ToString('o')}}catch{}
 $quality=if($File.Historical){'historical'}elseif(-not $File.SessionId -or -not $at){'partial'}else{'reported'}
 $tokenIdentity=if($usage){[AIBattery.RolloutReader]::Key([string[]]@($usage.evidenceId,$usage.basis,$usage.inputTokens,$usage.cachedInputTokens,$usage.cacheWriteInputTokens,$usage.outputTokens,$usage.reasoningOutputTokens,$usage.sourceTotalTokens))}else{$operation}
 $eventId=[AIBattery.RolloutReader]::Key([string[]]@('codex',$session,$turn,$type,$tokenIdentity,$at))
 return @{version=1;eventId=$eventId;occurredAt=$at;observedAt=[datetimeoffset]::UtcNow.ToString('o');providerId='codex';adapterId='codex-rollout';mode='observed';projectId=$null;sessionId=$session;taskId=$native;runId=$native;turnId=$turn;parentTaskId=$null;operationId=$operation;correlationId=$null;type=$type;actor='executor';target='project';state=$state;model=$File.Model;quality=$quality;usage=$usage}
}
function Get-TokenEstimate([string]$Model,$Usage) {
 # Legacy standalone reference estimate; normalized facts never include monetary estimates.
 $prices=@{'gpt-6.1-sol'=@(2,.10,10,2.5);'gpt-6-astra'=@(10,1,50,12.5);'gpt-6-luna'=@(.10,.01,.50,.125);'gpt-5.3-codex'=@(1.75,.175,14,0)}
 if (-not $prices.ContainsKey($Model) -or $null -eq $Usage.input_tokens -or $null -eq $Usage.output_tokens) {return $null}
 $inputTokens=[double]$Usage.input_tokens;$cached=[double]$Usage.cached_input_tokens;$writes=[double]$Usage.cache_write_input_tokens;$outputTokens=[double]$Usage.output_tokens
 if ($inputTokens -lt 0 -or $cached -lt 0 -or $outputTokens -lt 0 -or $writes -lt 0 -or $cached+$writes -gt $inputTokens) {return $null}
 if ($writes -gt 0 -and $prices[$Model][3] -eq 0) {return $null}
 $p=$prices[$Model];return (($inputTokens-$cached-$writes)*$p[0]+$cached*$p[1]+$writes*$p[3]+$outputTokens*$p[2])/1000000
}
function Get-TelemetryTurn($State,[string]$Id,$File,$Timestamp) {
 if(-not $Id){return $null}
 if(-not $State.Turns.ContainsKey($Id)){$State.Turns[$Id]=@{Id=$Id;StartedAtUtc=$null;EndedAtUtc=$null;LastEventUtc=$Timestamp;Model=$File.Model;InputTokens=$null;CachedTokens=$null;OutputTokens=$null;TotalTokens=$null;EstimatedUsd=$null;CostKnown=$true;RecordUsage=$false;Responses=@{};Items=@{};Operation='Execucao';TerminalStatus=$null;Historical=[bool]$File.Historical;Baseline=$File.Baseline}}
 return $State.Turns[$Id]
}
function Set-TurnUsage($Turn,$Usage,[bool]$Accumulate) {
 $valid=ConvertTo-TelemetryUsage $Usage
 if(-not $valid){return $false}
 $estimate=Get-TokenEstimate $Turn.Model $Usage
 if(-not $Accumulate){$Turn.InputTokens=0L;$Turn.CachedTokens=0L;$Turn.OutputTokens=0L;$Turn.TotalTokens=0L;$Turn.EstimatedUsd=0.0;$Turn.CostKnown=$true}
 if($null -eq $valid.inputTokens){$Turn.InputTokens=$null}elseif($null -ne $Turn.InputTokens){$Turn.InputTokens+=$valid.inputTokens}
 if($null -eq $valid.outputTokens){$Turn.OutputTokens=$null}elseif($null -ne $Turn.OutputTokens){$Turn.OutputTokens+=$valid.outputTokens}
 $Turn.TotalTokens=if($null -ne $Turn.InputTokens -and $null -ne $Turn.OutputTokens){$Turn.InputTokens+$Turn.OutputTokens}else{$null}
 if($null -eq $valid.cachedInputTokens){$Turn.CachedTokens=$null}elseif($null -ne $Turn.CachedTokens){$Turn.CachedTokens+=$valid.cachedInputTokens}
 if($null -eq $estimate){$Turn.CostKnown=$false;$Turn.EstimatedUsd=$null}elseif($Turn.CostKnown){$Turn.EstimatedUsd+=$estimate}
 return $true
}
function Add-TelemetryFact($State,$File,$Fact,$Label=$null) {
 $t=Get-TelemetryTurn $State $Fact.taskId $File $Fact.occurredAt;$t.LastEventUtc=$Fact.occurredAt
 if($Fact.quality -ne 'historical'){$t.Historical=$false}
 if($Fact.model){$t.Model=$Fact.model}
 switch($Fact.type) {
  'run.started' {if(-not $t.StartedAtUtc){$t.StartedAtUtc=$Fact.occurredAt};if(-not $t.TerminalStatus){$t.Operation='Processando'}}
  'run.completed' {if(-not $t.TerminalStatus){$t.TerminalStatus='Concluido';$t.EndedAtUtc=$Fact.occurredAt;$t.Operation='Concluido'}}
  'run.interrupted' {if(-not $t.TerminalStatus){$t.TerminalStatus='Interrompido';$t.EndedAtUtc=$Fact.occurredAt;$t.Operation='Interrompido'}}
  'usage.updated' {
   $u=$Fact.usage;if($u.basis -eq 'response' -and $t.Responses.ContainsKey($u.evidenceId)){return}
   if($u.basis -eq 'turn_cumulative' -and $t.RecordUsage){return}
   $legacy=@{input_tokens=$u.inputTokens;cached_input_tokens=$u.cachedInputTokens;cache_write_input_tokens=$u.cacheWriteInputTokens;output_tokens=$u.outputTokens}
   if(Set-TurnUsage $t $legacy ($u.basis -eq 'response' -and $t.RecordUsage)){if($u.basis -eq 'response'){$t.Responses[$u.evidenceId]=$true;$t.RecordUsage=$true}}
  }
  {$_ -in @('operation.started','operation.completed')} {if(-not $Label){$Label='Operacao'};if($Fact.operationId){$t.Items[$Fact.operationId]=@{Label=$Label;Status=if($Fact.type -eq 'operation.completed'){'Concluido'}else{'Em andamento'}}};if(-not $t.TerminalStatus){$t.Operation=$Label}}
 }
}
function Add-TelemetryEvent($State,$File,$Event) {
 $facts=@(ConvertTo-TelemetryFacts $File $Event)
 if($Event.type -eq 'turn_context' -and $File.CurrentTurn) {$session=if($File.SessionId){$File.SessionId}else{'partial:'+$File.Generation};$key=Get-NativeTelemetryKey 'codex' $session $File.CurrentTurn;if($State.Turns.ContainsKey($key)){$State.Turns[$key].Model=$File.Model}}
 $label=switch($Event.payload.item.type){'CommandExecution'{'Comando'};'FileChange'{'Alteracao de arquivo'};'McpToolCall'{'Ferramenta'};'Reasoning'{'Raciocinio'};'AgentMessage'{'Resposta'};'ContextCompaction'{'Compactacao'};'SubAgentActivity'{'Agente'};default{$null}}
 foreach($fact in $facts){Add-TelemetryFact $State $File $fact $label}
}
function ConvertTo-TelemetryHashtable($Value) {
 if($null -eq $Value){return $null}
 if($Value -is [System.Collections.IDictionary]){$h=@{};foreach($k in $Value.Keys){$h[$k]=ConvertTo-TelemetryHashtable $Value[$k]};return $h}
 if($Value -is [pscustomobject]){$h=@{};foreach($p in $Value.PSObject.Properties){$h[$p.Name]=ConvertTo-TelemetryHashtable $p.Value};return $h}
 if($Value -is [array]){return ,@($Value|ForEach-Object {ConvertTo-TelemetryHashtable $_})}
 return $Value
}
function Copy-TelemetryCheckpointValue($Value) {
 if($Value -is [System.Collections.IDictionary]) {
  $copy=@{};foreach($key in $Value.Keys){$copy[$key]=Copy-TelemetryCheckpointValue $Value[$key]}
  if($copy.Fragment){$copy.Offset-=[Convert]::FromBase64String($copy.Fragment).Length;$copy.Fragment=$null}
  return $copy
 }
 return $Value
}
function Get-TelemetryCheckpoint($State) {
 $files=Copy-TelemetryCheckpointValue $State.Files
 return @{version=1;files=$files;discoveredAtUtc=$State.DiscoveredAtUtc;roundRobin=$State.RoundRobin}
}
function Restore-TelemetryCheckpoint($State,$Checkpoint) {
 if(-not $Checkpoint){return}
 $cp=ConvertTo-TelemetryHashtable $Checkpoint
 if($cp.encoding -eq 'gzip-base64') {
  $bytes=[Convert]::FromBase64String($cp.data);$ms=[IO.MemoryStream]::new($bytes);$gzip=[IO.Compression.GZipStream]::new($ms,[IO.Compression.CompressionMode]::Decompress);$reader=[IO.StreamReader]::new($gzip,[Text.Encoding]::UTF8)
  try{$cp=ConvertTo-TelemetryHashtable (ConvertFrom-Json $reader.ReadToEnd())}finally{$reader.Dispose();$gzip.Dispose();$ms.Dispose()}
 }
 if($cp.version -ne 1 -or -not ($cp.files -is [hashtable])){throw 'INVALID_CHECKPOINT'}
 $State.Files=$cp.files;$State.DiscoveredAtUtc=$cp.discoveredAtUtc;$State.RoundRobin=[int]$cp.roundRobin
}
function Get-TelemetryPrefix([string]$Path,[long]$Length) {
 $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 try{$bytes=New-Object byte[] ([int][math]::Min(128,$Length));$count=$stream.Read($bytes,0,$bytes.Length);$sha=[Security.Cryptography.SHA256]::Create();try{return [Convert]::ToBase64String($sha.ComputeHash($bytes,0,$count))}finally{$sha.Dispose()}}finally{$stream.Dispose()}
}
function Sync-TelemetryLiveFrontier($File) {
 # Seed only a complete, verified native record boundary, never a partially read history.
 if($File.LiveReconciled -or -not $File.BackfillDone -or $File.Fragment -or $File.Skipping -or $File.Offset -lt $File.InitialLength){return}
 $seen=if($File.Live){[long]$File.Live.Offset}else{[long]$File.Offset}
 $live=New-TelemetryFile
 foreach($key in @('Model','CurrentTurn','Baseline','TurnBaseline','SessionId','Cwd','Generation','Creation')){$live[$key]=Copy-TelemetryCheckpointValue $File[$key]}
 $live.Offset=[long]$File.Offset;$live.BoundaryChecked=$true;$live.BoundarySkip=$false
 # Newly attributable records already scanned by the provisional live cursor are evidence replay.
 $live.ReplayUntil=[math]::Max($seen,[long]$File.Offset)
 $File.Live=$live;$File.LiveReconciled=$true
}
function Initialize-TelemetryLanes($File) {
 if($File.Live){Sync-TelemetryLiveFrontier $File;return}
 $live=New-TelemetryFile
 # A migrated checkpoint may already have committed appends beyond the original boundary.
 $live.Offset=[math]::Max([long]$File.InitialLength,[long]$File.Offset)
 $live.Generation=$File.Generation;$live.SessionId=$File.SessionId;$live.Cwd=$File.Cwd
 $live.BoundaryChecked=($live.Offset -eq 0);$live.BoundarySkip=$false
 $File.Live=$live
 $File.BackfillDone=($File.Offset -ge $File.InitialLength -and -not $File.Fragment -and -not $File.Skipping)
 Sync-TelemetryLiveFrontier $File
}
function Set-TelemetryCursor($Cursor,$Before) {
 $Cursor.Clear();foreach($key in $Before.Keys){$Cursor[$key]=$Before[$key]}
}
function Read-TelemetryLane($State,$Entry,$Cursor,$Budget,[int]$ByteLimit,[int]$EventLimit,[bool]$Backfill) {
 if($Budget.Stop -or $ByteLimit -le 0){return}
 try {
  $Cursor.ReadError=$false
  if(-not $Backfill -and -not $Cursor.BoundaryChecked -and $Cursor.Offset -gt 0) {
   $stream=[IO.FileStream]::new($Entry.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
   try{$stream.Position=$Cursor.Offset-1;$Cursor.Skipping=($stream.ReadByte() -ne 10);$Cursor.BoundarySkip=$Cursor.Skipping;$Cursor.BoundaryChecked=$true;$Budget.Bytes++}finally{$stream.Dispose()}
  }
  $allow=[int][math]::Min($ByteLimit,$Budget.MaxBytes-$Budget.Bytes)
  if($Backfill -and $Cursor.Offset -lt $Cursor.InitialLength){$allow=[int][math]::Min($allow,$Cursor.InitialLength-$Cursor.Offset)}
  if($allow -le 0 -or $Cursor.Offset -ge $Entry.Info.Length){return}
  $chunk=[AIBattery.RolloutReader]::ReadBounded($Entry.Path,$Cursor.Offset,$allow,$Cursor.Fragment,[bool]$Cursor.Skipping);$Budget.Bytes+=$chunk.BytesRead
  $cut=$false;$laneBytes=0;$laneFacts=0
  foreach($line in $chunk.Lines) {
   $before=@{};foreach($key in $Cursor.Keys){$before[$key]=$Cursor[$key]}
   # Backfill stops after the initial frontier's incomplete record; even that completion is old evidence.
   $Cursor.Historical=$Backfill -or (-not $Backfill -and $Cursor.ReplayUntil -gt 0 -and $line.EndOffset -le $Cursor.ReplayUntil)
   $facts=@();try{if($line.Text -match '"type"\s*:\s*"(session_meta|turn_context|token_usage_record|event_msg)"'){$event=ConvertFrom-Json $line.Text -ErrorAction Stop;$facts=@(ConvertTo-TelemetryFacts $Cursor $event)}}catch{$State.Error=$true}
   $size=0;foreach($fact in $facts){$size+=[Text.Encoding]::UTF8.GetByteCount(($fact|ConvertTo-Json -Depth 10 -Compress))+1}
   if($Budget.EventBytes+$size -gt $Budget.MaxEventBytes -and $Budget.Events.Count -gt 0){Set-TelemetryCursor $Cursor $before;$Budget.Stop=$true;$cut=$true;break}
   if($laneBytes+$size -gt $EventLimit -and $laneFacts -gt 0){Set-TelemetryCursor $Cursor $before;$cut=$true;break}
   foreach($fact in $facts){[void]$Budget.Events.Add($fact)};$Budget.EventBytes+=$size;$laneBytes+=$size;$laneFacts+=$facts.Count
   $Cursor.Offset=$line.EndOffset;$Cursor.Fragment=$null;$Cursor.Skipping=$false
   if($Backfill -and $line.EndOffset -ge $Cursor.InitialLength){$Cursor.BackfillDone=$true;$cut=$true;break}
  }
  if(-not $cut) {
   $Cursor.Offset=$chunk.Offset;$Cursor.Fragment=$chunk.Fragment;$Cursor.Skipping=$chunk.Skipping
   $drops=$chunk.DroppedLines
   if(-not $Backfill -and $Cursor.BoundarySkip -and -not $chunk.Skipping){$drops=[math]::Max(0,$drops-1);$Cursor.BoundarySkip=$false}
   $Cursor.DroppedLines+=$drops
   if($Backfill -and $Cursor.Offset -ge $Cursor.InitialLength -and -not $Cursor.Fragment -and -not $Cursor.Skipping){$Cursor.BackfillDone=$true}
  }
  elseif($Backfill -and $Cursor.BackfillDone){$Cursor.DroppedLines+=$chunk.DroppedLines}
  $Cursor.LastWrite=$Entry.Info.LastWriteTimeUtc.Ticks
 }catch{$Cursor.ReadError=$true;$State.Error=$true}
}
function Read-TelemetrySessionHeader($Entry,$Budget) {
 $file=$Entry.Cursor
 if($file.SessionId -or $Budget.Bytes -ge $Budget.MaxBytes){return}
 try {
  $allow=[int][math]::Min(65536,[math]::Max(0,[math]::Min($Budget.MaxBytes-$Budget.Bytes,[math]::Floor($Budget.MaxBytes/4))))
  if($allow -le 0){return}
  $chunk=[AIBattery.RolloutReader]::ReadBounded($Entry.Path,0,$allow,$null,$false);$Budget.Bytes+=$chunk.BytesRead
  foreach($line in $chunk.Lines) {
   if($line.Text -notmatch '"type"\s*:\s*"session_meta"'){continue}
   $header=ConvertFrom-Json $line.Text -ErrorAction Stop
   if($header.type -ne 'session_meta'){continue}
   $context=New-TelemetryFile;[void](ConvertTo-TelemetryFacts $context $header)
   # A header proves identity/project only; its zero baseline is invalid for a tail.
   $file.SessionId=$context.SessionId;$file.Cwd=$context.Cwd;break
  }
 }catch{$State.Error=$true}
}
function Read-TelemetryBatch($State,[string]$Directory,[int]$MaxBytes=4194304,[int]$MaxEventBytes=131072) {
 Initialize-TelemetryReader;$State.Error=$false;$now=[datetimeoffset]::UtcNow
 $budget=@{Events=(New-Object System.Collections.ArrayList);Bytes=0;EventBytes=0;MaxBytes=$MaxBytes;MaxEventBytes=$MaxEventBytes;Stop=$false}
 if(-not $State.DiscoveredAtUtc -or $now-[datetimeoffset]$State.DiscoveredAtUtc -ge [timespan]::FromSeconds(30)) {
  try {
   $initial=-not $State.DiscoveredAtUtc
   foreach($item in @(Get-ChildItem -LiteralPath $Directory -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction Stop)) {
    if(-not $State.Files.ContainsKey($item.FullName)) {
     $file=New-TelemetryFile;$file.InitialLength=if($initial){$item.Length}else{0L};$file.Historical=$initial;$file.Creation=$item.CreationTimeUtc.Ticks
     Initialize-TelemetryLanes $file;$State.Files[$item.FullName]=$file
    }
   }
   $State.DiscoveredAtUtc=$now.ToString('o')
  }catch{$State.Error=$true}
 }
 $entries=@()
 foreach($path in @($State.Files.Keys)) {
  $cursor=$State.Files[$path]
  try {
   $info=Get-Item -LiteralPath $path -ErrorAction Stop;Initialize-TelemetryLanes $cursor
   $anchor=[math]::Max($cursor.Offset,$cursor.Live.Offset)
   $prefix=Get-TelemetryPrefix $path ([math]::Min($anchor,$info.Length))
   $replaced=($cursor.Creation -ne 0 -and $cursor.Creation -ne $info.CreationTimeUtc.Ticks)
   if($cursor.Prefix -and $anchor -ge 128 -and $prefix -ne $cursor.Prefix){$replaced=$true}
   if($cursor.Offset -gt $info.Length -or $cursor.Live.Offset -gt $info.Length -or $replaced) {
    $fresh=New-TelemetryFile;$fresh.Creation=$info.CreationTimeUtc.Ticks;Initialize-TelemetryLanes $fresh;$State.Files[$path]=$fresh;$cursor=$fresh
   }
   $cursor.ReadError=$false;$cursor.Live.ReadError=$false
   $entries+=@{Path=$path;Info=$info;Cursor=$cursor}
  }catch{$cursor.ReadError=$true;$State.Error=$true}
 }
 $ordered=@($entries|Sort-Object @{Expression={$_.Path}})
 if($ordered.Count -gt 0){$shift=$State.RoundRobin % $ordered.Count;$ordered=@($ordered[$shift..($ordered.Count-1)])+@($ordered|Select-Object -First $shift)}
 $liveEntries=@($ordered|Where-Object {$_.Cursor.Live.Offset -lt $_.Info.Length})
 $historyEntries=@($ordered|Where-Object {-not $_.Cursor.BackfillDone})
 # Reserve a quarter of byte work for old metadata while prioritizing fresh native events.
 $liveByteBudget=if($historyEntries.Count -gt 0){[int][math]::Max(1,[math]::Floor($MaxBytes*.75))}else{$MaxBytes}
 foreach($entry in $liveEntries) {
  if($budget.Stop -or $budget.Bytes -ge $liveByteBudget){break}
  Read-TelemetrySessionHeader $entry $budget
  $entry.Cursor.Live.SessionId=$entry.Cursor.SessionId;$entry.Cursor.Live.Cwd=$entry.Cursor.Cwd
  $slice=[int][math]::Min(1048576,[math]::Max(1,[math]::Floor($liveByteBudget/[math]::Max(1,$liveEntries.Count))))
  $slice=[int][math]::Min($slice,$liveByteBudget-$budget.Bytes)
  $eventSlice=[int][math]::Max(1024,[math]::Floor($MaxEventBytes/[math]::Max(1,$liveEntries.Count)))
  Read-TelemetryLane $State $entry $entry.Cursor.Live $budget $slice $eventSlice $false
  # A new file can reveal its verified session in the live header.
  if($entry.Cursor.Live.SessionId){$entry.Cursor.SessionId=$entry.Cursor.Live.SessionId;$entry.Cursor.Cwd=$entry.Cursor.Live.Cwd}
 }
 foreach($entry in $historyEntries) {
  if($budget.Stop -or $budget.Bytes -ge $MaxBytes){break}
  $slice=[int][math]::Min(1048576,$MaxBytes-$budget.Bytes)
  Read-TelemetryLane $State $entry $entry.Cursor $budget $slice $MaxEventBytes $true
  Sync-TelemetryLiveFrontier $entry.Cursor
 }
 foreach($entry in $entries) {
  try{$entry.Cursor.Prefix=Get-TelemetryPrefix $entry.Path ([math]::Min([math]::Max($entry.Cursor.Offset,$entry.Cursor.Live.Offset),$entry.Info.Length))}catch{$entry.Cursor.ReadError=$true;$State.Error=$true}
 }
 $State.RoundRobin++;$State.ObservedAtUtc=$now.ToString('o')
 $pending=0;$failed=0;$covered=0;$ignored=0;$sessions=@{}
 foreach($path in $State.Files.Keys) {
  $f=$State.Files[$path]
  if($f.ReadError -or ($f.Live -and $f.Live.ReadError)){$failed++}
  if($f.DroppedLines -gt 0 -or ($f.Skipping -and -not $f.BackfillDone) -or ($f.Live -and ($f.Live.DroppedLines -gt 0 -or ($f.Live.Skipping -and -not $f.Live.BoundarySkip)))){$ignored++}
  try {
   $length=(Get-Item -LiteralPath $path -ErrorAction Stop).Length
   if(-not $f.BackfillDone -or $f.Live.Offset -lt $length -or $f.Live.Fragment -or ($f.Live.Skipping -and -not $f.Live.BoundarySkip)){$pending++}else{$covered++}
  }catch{}
  if($f.SessionId){$sessions[$f.SessionId]=@{cwd=$f.Cwd}}
 }
 return @{Events=@($budget.Events.ToArray());Checkpoint=(Get-TelemetryCheckpoint $State);Coverage=@{status=if($State.Error -or $ignored -gt 0){'partial'}elseif($pending -gt 0){'backfill'}else{'observed'};filesDiscovered=$State.Files.Count;filesCovered=$covered;pendingFiles=$pending;failedFiles=$failed;ignoredFiles=$ignored;bytesRead=$budget.Bytes;backfillComplete=($pending -eq 0 -and -not $State.Error -and $ignored -eq 0);observedAt=$now.ToString('o')};SourceContext=@{sessions=$sessions}}
}
function Update-CodexTelemetry($State,[string]$Directory=(Join-Path $env:USERPROFILE '.codex\sessions')) {
 $batch=Read-TelemetryBatch $State $Directory
 foreach($fact in $batch.Events){Add-TelemetryFact $State @{Model=$fact.model;Historical=($fact.quality -eq 'historical');Baseline=$null} $fact}
 $keep=@($State.Turns.Values|Sort-Object LastEventUtc -Descending|Select-Object -First 40|ForEach-Object {$_.Id});foreach($id in @($State.Turns.Keys)){if($id -notin $keep){$State.Turns.Remove($id)}}
}
function Get-TelemetryReport($State,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
 $rows=@(foreach($t in @($State.Turns.Values|Sort-Object LastEventUtc -Descending|Select-Object -First 12)) {
  $elapsed=$null;if($t.StartedAtUtc -and (-not $t.TerminalStatus -or $t.EndedAtUtc)){try{$end=if($t.EndedAtUtc){[datetimeoffset]$t.EndedAtUtc}elseif($t.Historical){[datetimeoffset]$t.LastEventUtc}else{$Now};$elapsed=[math]::Max(0,[int]($end-[datetimeoffset]$t.StartedAtUtc).TotalSeconds)}catch{}}
  $status=if($t.TerminalStatus){$t.TerminalStatus}elseif($t.Historical){'Historico'}elseif($t.LastEventUtc -and $Now-[datetimeoffset]$t.LastEventUtc -gt [timespan]::FromMinutes(5)){'Sem evento recente'}else{'Em andamento'}
  @{Id=$t.Id;Model=$t.Model;StartedAtUtc=$t.StartedAtUtc;Status=$status;Operation=$t.Operation;ElapsedSeconds=$elapsed;InputTokens=$t.InputTokens;CachedTokens=$t.CachedTokens;OutputTokens=$t.OutputTokens;TotalTokens=$t.TotalTokens;EstimatedUsd=$t.EstimatedUsd;Operations=$t.Items.Count}
 })
 $total=$null;foreach($t in $State.Turns.Values){if($null -ne $t.TotalTokens){if($null -eq $total){$total=0L};$total+=$t.TotalTokens}}
 return @{Turns=$rows;ObservedAtUtc=$State.ObservedAtUtc;Error=$State.Error;Totals=@{TotalTokens=$total;scope='recent-local'}}
}
Export-ModuleMember -Function *
