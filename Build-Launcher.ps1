$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\src\Desktop.psm1" -DisableNameChecking
Initialize-DesktopIntegration
Add-Type -AssemblyName System.Drawing
$assetDir=Join-Path $PSScriptRoot 'assets';[IO.Directory]::CreateDirectory($assetDir) | Out-Null
$bitmap=[Drawing.Bitmap]::new(64,64);$g=[Drawing.Graphics]::FromImage($bitmap);$g.SmoothingMode='AntiAlias'
$path=[Drawing.Drawing2D.GraphicsPath]::new();$path.AddArc(1,1,20,20,180,90);$path.AddArc(43,1,20,20,270,90);$path.AddArc(43,43,20,20,0,90);$path.AddArc(1,43,20,20,90,90);$path.CloseFigure()
$background=[Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Rectangle]::new(0,0,64,64),[Drawing.Color]::FromArgb(37,40,47),[Drawing.Color]::FromArgb(8,9,12),45)
$border=[Drawing.Pen]::new([Drawing.Color]::FromArgb(185,195,213),1.5);$silver=[Drawing.Pen]::new([Drawing.Color]::FromArgb(234,239,248),2.5);$bars=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(94,224,160));$tip=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(234,239,248))
$handle=[IntPtr]::Zero;$icon=$null
try {
 $g.Clear([Drawing.Color]::Transparent);$g.FillPath($background,$path);$g.DrawPath($border,$path)
 $g.DrawRectangle($silver,12,21,36,22);$g.FillRectangle($tip,50,27,3,10)
 foreach ($x in @(17,26,35)) {$g.FillRectangle($bars,$x,26,6,12)}
 $handle=$bitmap.GetHicon();$icon=[Drawing.Icon]::FromHandle($handle);$stream=[IO.File]::Create((Join-Path $assetDir 'AI-Battery.ico'));try {$icon.Save($stream)} finally {$stream.Dispose()}
} finally {if ($icon) {$icon.Dispose()};if ($handle -ne [IntPtr]::Zero) {[void][AIBattery.DesktopIntegration]::DestroyIcon($handle)};$g.Dispose();$bitmap.Dispose();$path.Dispose();$background.Dispose();$border.Dispose();$silver.Dispose();$bars.Dispose();$tip.Dispose()}
$provider=[Microsoft.CSharp.CSharpCodeProvider]::new();$options=[CodeDom.Compiler.CompilerParameters]::new();$options.GenerateExecutable=$true;$options.GenerateInMemory=$false;$options.OutputAssembly=Join-Path $PSScriptRoot 'AI Battery.exe';$options.CompilerOptions='/optimize+ /target:winexe /win32icon:"'+(Join-Path $assetDir 'AI-Battery.ico')+'"'
[void]$options.ReferencedAssemblies.Add('System.dll');[void]$options.ReferencedAssemblies.Add('System.Windows.Forms.dll')
try {$result=$provider.CompileAssemblyFromFile($options,(Join-Path $PSScriptRoot 'src\Launcher.cs'));if ($result.Errors.HasErrors) {throw (($result.Errors | ForEach-Object {$_.ErrorText}) -join '; ')}} finally {$provider.Dispose()}
Write-Output 'Launcher AI Battery.exe compilado com icone proprio.'
