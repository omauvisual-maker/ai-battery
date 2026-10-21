Import-Module "$PSScriptRoot\..\src\Detection.psm1" -Force
$rules=@(@{ProviderId='codex';ExecutablePath='C:\Apps\Codex\ChatGPT.exe';Kind='desktop'},@{ProviderId='claude';ExecutablePath='C:\Apps\Claude\Claude.exe';Kind='desktop'},@{ProviderId='gemini';ExecutablePath='C:\Tools\node.exe';ScriptPath='C:\Tools\gemini\index.js';Kind='cli'})
Test 'No apps means no icons' { Assert-Equal @(Resolve-ActiveProviders @() $rules).Count 0 }
Test 'Deduplicate and detect two apps' { $p=@(@{ExecutablePath='C:\Apps\Codex\ChatGPT.exe'},@{ExecutablePath='C:\Apps\Codex\ChatGPT.exe'},@{ExecutablePath='C:\Apps\Claude\Claude.exe'}); Assert-Equal (@(Resolve-ActiveProviders $p $rules) -join ',') 'codex,claude' }
Test 'Impostor and helper excluded' { Assert-Equal @(Resolve-ActiveProviders @(@{ExecutablePath='C:\Other\ChatGPT.exe'},@{ExecutablePath='C:\Apps\Claude\Crashpad.exe'}) $rules).Count 0 }
Test 'Explicit node script required' { Assert-Equal @(Resolve-ActiveProviders @(@{ExecutablePath='C:\Tools\node.exe'}) $rules).Count 0; Assert-Equal (@(Resolve-ActiveProviders @(@{ExecutablePath='C:\Tools\node.exe';ScriptPath='C:\Tools\gemini\index.js'}) $rules) -join ',') 'gemini' }
Test 'Missing path and closing last instance' { Assert-Equal @(Resolve-ActiveProviders @(@{ExecutablePath=$null}) $rules).Count 0; Assert-Equal @(Resolve-ActiveProviders @() $rules).Count 0 }
Test 'Package discovery anchored to real WindowsApps directory' { Assert-Equal (Get-PackageProviderRule 'C:\Users\Public\WindowsApps\OpenAI.Codex_fake\app\ChatGPT.exe' 'C:\Program Files\WindowsApps') $null;Assert-Equal (Get-PackageProviderRule 'C:\Program Files\WindowsApps\OpenAI.Codex_1\app\ChatGPT.exe' 'C:\Program Files\WindowsApps').ProviderId 'codex' }
Test 'Claude Code and Gemini CLI scripts recognized from any install folder' {
 Assert-Equal (Get-ScriptProviderRule @{Name='node.exe';ExecutablePath='C:\node\node.exe';ScriptPath='D:\x\node_modules\@google\gemini-cli\dist\index.js'}).ProviderId 'gemini'
 Assert-Equal (Get-ScriptProviderRule @{Name='node.exe';ExecutablePath='C:\node\node.exe';ScriptPath='C:\y\node_modules\@anthropic-ai\claude-code\cli.js'}).ProviderId 'claude'
 Assert-Equal (Get-ScriptProviderRule @{Name='node.exe';ExecutablePath='C:\node\node.exe';ScriptPath='C:\z\server.mjs'}) $null
}
Test 'Native Claude Code CLI installs are detected' {
 $root=Join-Path ([IO.Path]::GetTempPath()) ('aib-det-'+[guid]::NewGuid());$home2=Join-Path $root 'home';$local=Join-Path $root 'local'
 try {
  $bin=New-Item -ItemType Directory -Force (Join-Path $home2 '.local\bin');Set-Content (Join-Path $bin 'claude.exe') 'x'
  $embedded=New-Item -ItemType Directory -Force (Join-Path $local 'Claude-Data\claude_pkg\claude-code\2.1.0\abc');Set-Content (Join-Path $embedded 'claude.exe') 'x'
  $paths=@(Find-InstalledProviderRules $local $home2 | Where-Object {$_.ProviderId -eq 'claude'} | ForEach-Object {$_.ExecutablePath})
  Assert-True ($paths -contains (Join-Path $bin 'claude.exe'));Assert-True ($paths -contains (Join-Path $embedded 'claude.exe'))
 } finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
}
Test 'Claude Store package recognized without plan check' { $rule=Get-PackageProviderRule 'C:\Program Files\WindowsApps\Claude_2.31226.1.0_x64__pzs8sxrjxfjjc\app\claude.exe' 'C:\Program Files\WindowsApps';Assert-Equal $rule.ProviderId 'claude';Assert-Equal (Get-PackageProviderRule 'C:\Program Files\WindowsApps\Claude_2\app\resources\claude-ssh-proxy.exe' 'C:\Program Files\WindowsApps') $null }
