function Get-ProcessInventory {
 $items=@(Get-CimInstance Win32_Process -Property Name,ProcessId,ParentProcessId,ExecutablePath,CommandLine -ErrorAction Stop)
 foreach ($p in $items) {
  if (-not $p.ExecutablePath) { continue }
  $scriptPath=$null; $helper=$false
  if ($p.Name -ieq 'node.exe' -and $p.CommandLine) {
   $m=[regex]::Match($p.CommandLine,'(?:"(?<script>[^"\r\n]+\.(?:js|mjs|cjs))"|(?<script>\S+\.(?:js|mjs|cjs)))(?:\s|$)')
   if ($m.Success) { $scriptPath=$m.Groups['script'].Value }
  }
  if ($p.Name -ieq 'codex.exe' -and $p.CommandLine -match '(?:\s|^)app-server(?:\s|$)') { $helper=$true }
  [pscustomobject]@{Id=$p.ProcessId;ParentId=$p.ParentProcessId;Name=$p.Name;ExecutablePath=$p.ExecutablePath;ScriptPath=$scriptPath;IsHelper=$helper}
 }
}
function Resolve-ActiveProviders([object[]]$Inventory,[object[]]$Rules) {
 foreach ($id in @('codex','claude','gemini')) {
  $found=$false
  foreach ($rule in @($Rules | Where-Object ProviderId -eq $id)) {
   foreach ($p in $Inventory) {
    if ($p.IsHelper -or -not $p.ExecutablePath) { continue }
    if ($p.ExecutablePath -ieq $rule.ExecutablePath -and (-not $rule.ScriptPath -or $p.ScriptPath -ieq $rule.ScriptPath)) { $found=$true; break }
   }
   if ($found) { break }
  }
  if ($found) { $id }
 }
}
function Find-InstalledProviderRules([string]$LocalAppData=[Environment]::GetFolderPath('LocalApplicationData'),[string]$UserProfile=$env:USERPROFILE) {
 $local=$LocalAppData
 $rules=New-Object System.Collections.Generic.List[object]
 $patterns=@(
  @{Id='codex';Path="$local\OpenAI\Codex\bin\*\codex.exe";Kind='cli'},
  @{Id='codex';Path="$env:ProgramFiles\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe";Kind='desktop'},
  @{Id='claude';Path="$local\Claude\app-*\Claude.exe";Kind='desktop'},
  @{Id='claude';Path="$local\AnthropicClaude\app-*\Claude.exe";Kind='desktop'},
  @{Id='claude';Path="$env:ProgramFiles\WindowsApps\Claude_*\app\claude.exe";Kind='desktop'},
  # Native Claude Code installer and the copy the Store app runs for its Code tab.
  @{Id='claude';Path="$UserProfile\.local\bin\claude.exe";Kind='cli'},
  @{Id='claude';Path="$local\Claude-Data\*\claude-code\*\*\claude.exe";Kind='cli'},
  @{Id='gemini';Path="$local\Google\Gemini\app-*\Gemini.exe";Kind='desktop'}
 )
 foreach ($pattern in $patterns) {
  foreach ($file in @(Get-Item -Path $pattern.Path -ErrorAction SilentlyContinue)) {
   $rules.Add(@{ProviderId=$pattern.Id;ExecutablePath=$file.FullName;ScriptPath=$null;Kind=$pattern.Kind})
  }
 }
 # Installed package processes remain discoverable if WindowsApps directory enumeration is restricted.
 foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
  try { $path=$p.Path } catch { continue }
  $packageRule=Get-PackageProviderRule $path
  if ($packageRule) {$rules.Add($packageRule)}
 }
 foreach ($id in @('claude','gemini')) {
  $command=Get-Command $id -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command -and $command.Source -match '\.exe$') { $rules.Add(@{ProviderId=$id;ExecutablePath=$command.Source;ScriptPath=$null;Kind='cli'}) }
  $node=Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  $relative=if ($id -eq 'claude') {'@anthropic-ai\claude-code\cli.js'} else {'@google\gemini-cli\dist\index.js'}
  $script=Join-Path ([Environment]::GetFolderPath('ApplicationData')) "npm\node_modules\$relative"
  if ($node -and (Test-Path -LiteralPath $script)) { $rules.Add(@{ProviderId=$id;ExecutablePath=$node.Source;ScriptPath=$script;Kind='cli'}) }
 }
 return @($rules.ToArray())
}
# Node CLIs run from npm, npx caches or project-local node_modules; match the package, not the folder.
function Get-ScriptProviderRule($Process) {
 if (-not $Process -or -not $Process.ScriptPath -or $Process.Name -ine 'node.exe') {return $null}
 $id=$null
 if ($Process.ScriptPath -match '[\\/]@anthropic-ai[\\/]claude-code[\\/]') {$id='claude'}
 elseif ($Process.ScriptPath -match '[\\/]@google[\\/]gemini-cli[\\/]') {$id='gemini'}
 if ($id) {return @{ProviderId=$id;ExecutablePath=$Process.ExecutablePath;ScriptPath=$Process.ScriptPath;Kind='cli'}}
 return $null
}
function Get-PackageProviderRule([string]$Path,[string]$PackageRoot=(Join-Path $env:ProgramFiles 'WindowsApps')) {
 if (-not $Path) {return $null}
 $root=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')+'\';$full=[IO.Path]::GetFullPath($Path)
 if (-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) {return $null}
 $relative=$full.Substring($root.Length);$id=$null
 if ($relative -match '^OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$') {$id='codex'}
 elseif ($relative -match '^(?:Claude_[^\\]+|Anthropic[^\\]*Claude[^\\]*)\\app\\Claude\.exe$') {$id='claude'}
 if ($id) {return @{ProviderId=$id;ExecutablePath=$full;ScriptPath=$null;Kind='desktop'}}
 return $null
}
Export-ModuleMember -Function *
