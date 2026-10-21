param([string]$Suite = 'All')
$ErrorActionPreference = 'Stop'
$script:Passed = 0; $script:Failed = 0
function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected -or (($null -eq $Actual) -ne ($null -eq $Expected))) { throw "Expected '$Expected', got '$Actual'" }
}
function Assert-True($Value) { if (-not $Value) { throw 'Expected true' } }
function Assert-Throws([scriptblock]$Action) { $caught = $false; try { & $Action } catch { $caught = $true }; Assert-True $caught }
function Test([string]$Name,[scriptblock]$Action) {
    try { & $Action; $script:Passed++; Write-Output "PASS $Name" }
    catch { $script:Failed++; Write-Output "FAIL $Name : $($_.Exception.Message)" }
}
$files = @(Get-ChildItem $PSScriptRoot -Filter '*.Tests.ps1' | Where-Object { $Suite -eq 'All' -or $_.BaseName -eq "$Suite.Tests" })
if ($files.Count -eq 0) { throw "No suite: $Suite" }
foreach ($file in $files) { try { . $file.FullName } catch { $script:Failed++; Write-Output "FAIL loading $($file.Name): $($_.Exception.Message)" } }
Write-Output "RESULT $script:Passed passed, $script:Failed failed"
if ($script:Failed) { exit 1 }
