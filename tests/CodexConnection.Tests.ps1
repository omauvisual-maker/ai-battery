Import-Module "$PSScriptRoot\..\src\Core.psm1" -Force
Import-Module "$PSScriptRoot\..\src\providers\Codex.psm1" -Force
Test 'Codex CLI found in app bin folder when absent from PATH' {
 $root=Join-Path ([IO.Path]::GetTempPath()) ('aib-codex-'+[guid]::NewGuid())
 try {
  $old=New-Item -ItemType Directory -Force (Join-Path $root 'OpenAI\Codex\bin\old');$new=New-Item -ItemType Directory -Force (Join-Path $root 'OpenAI\Codex\bin\new')
  Set-Content (Join-Path $old 'codex.exe') 'x';Set-Content (Join-Path $new 'codex.exe') 'x'
  (Get-Item (Join-Path $old 'codex.exe')).LastWriteTime=[datetime]'2026-01-01';(Get-Item (Join-Path $new 'codex.exe')).LastWriteTime=[datetime]'2026-10-01'
  Assert-Equal (Resolve-CodexExecutable $root '') (Join-Path $new 'codex.exe')
 } finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
}
Test 'Codex CLI missing everywhere returns null' {
 $root=Join-Path ([IO.Path]::GetTempPath()) ('aib-codex-'+[guid]::NewGuid())
 Assert-Equal (Resolve-CodexExecutable $root '') $null
}
Test 'Codex child starts without UTF-8 BOM and console encoding is restored' {
 $before=[Console]::InputEncoding
 try {
  [Console]::InputEncoding=[Text.UTF8Encoding]::new($true)
  $inside=Invoke-WithBomFreeConsoleInput { [Console]::InputEncoding.GetPreamble().Length }
  Assert-Equal $inside 0
  Assert-Equal ([Console]::InputEncoding.GetPreamble().Length) 3
 } finally { [Console]::InputEncoding=$before }
}
Test 'Codex child pipe carries JSON without BOM' {
 $info=[Diagnostics.ProcessStartInfo]::new('powershell.exe','-NoProfile -Command "$b=[Console]::OpenStandardInput();$x=New-Object byte[] 1;[void]$b.Read($x,0,1);$x[0]"')
 $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true
 $before=[Console]::InputEncoding
 try {
  [Console]::InputEncoding=[Text.UTF8Encoding]::new($true)
  $p=Invoke-WithBomFreeConsoleInput { [Diagnostics.Process]::Start($info) }
  $p.StandardInput.WriteLine('{"id":1}');$p.StandardInput.Close()
  $first=$p.StandardOutput.ReadToEnd().Trim();[void]$p.WaitForExit(10000)
  Assert-Equal $first ([string][int][char]'{')
 } finally { [Console]::InputEncoding=$before }
}
