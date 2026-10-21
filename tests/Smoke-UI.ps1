param([string]$PreviewDirectory=(Join-Path $PSScriptRoot '..\docs\previews'))
$ErrorActionPreference='Stop'
foreach ($name in @('Core','Settings','UI')) {Import-Module "$PSScriptRoot\..\src\$name.psm1" -DisableNameChecking}
$settings=New-AppSettings
$ui=New-AppWindows $settings {param($s)} {} {}
function Save-WindowPreview($Window,[string]$Name) {
 $Window.UpdateLayout();[IO.Directory]::CreateDirectory($PreviewDirectory) | Out-Null
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$Window.ActualWidth,[int]$Window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($Window)
 $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create((Join-Path $PreviewDirectory ($Name+'.png')));try {$encoder.Save($stream)} finally {$stream.Dispose()}
}
try {
 $snapshots=@{};foreach ($id in @('codex','claude','gemini')) {$snapshots[$id]=New-ProviderSnapshot $id}
 Update-Sidebar @() $snapshots
 if ($ui.Sidebar.IsVisible) {throw 'Barra deve iniciar oculta.'}
 if (-not $ui.Tray.Visible) {throw 'Configuracao precisa estar acessivel pela bandeja sem IAs.'}
 Update-Sidebar @('codex') $snapshots
 if (-not $ui.Sidebar.IsVisible -or $ui.Buttons.Count -ne 1) {throw 'Barra nao abriu.'}
 $click=[Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
 $ui.Buttons.codex.Button.RaiseEvent($click)
 if (-not $ui.Dashboard.IsVisible -or $ui.SelectedId -ne 'codex') {throw 'Clique nao abriu dashboard.'}
 Set-OperationsReport @{Turns=@(@{Id='smoke-test';Model='gpt-6.1-sol';Status='Em andamento';Operation='Ferramenta';StartedAtUtc=[datetimeoffset]::UtcNow.AddSeconds(-20).ToString('o');ElapsedSeconds=20;TotalTokens=1500;EstimatedUsd=.002;InputTokens=1400;CachedTokens=1000;OutputTokens=100;Operations=3});ObservedAtUtc=[datetimeoffset]::UtcNow.ToString('o');Error=$false}
 Update-LiveReportClock
 if ($ui.Dashboard.FindName('OperationsList').Children.Count -ne 1) {throw 'Relatorio nao exibiu operacao.'}
 Set-CodexWindowVisibility $false;Update-Sidebar @('codex') $snapshots
 if ($ui.Sidebar.IsVisible -or $ui.Dashboard.IsVisible -or $ui.UserHidden) {throw 'Minimizar Codex nao ocultou janelas temporariamente.'}
 Set-CodexWindowVisibility $true;Update-Sidebar @('codex') $snapshots
 if (-not $ui.Sidebar.IsVisible -or -not $ui.Dashboard.IsVisible) {throw 'Restaurar Codex nao restaurou relatorio.'}
 Update-Sidebar @('codex','claude','gemini') $snapshots
 if ($ui.Buttons.Count -ne 3) {throw 'Icones nao adicionados.'}
 Save-WindowPreview $ui.Sidebar 'sidebar-vertical'
 $ui.Sidebar.FindName('ToggleOrientation').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 $ui.Sidebar.UpdateLayout()
 if ($ui.Settings.Orientation -ne 'horizontal' -or $ui.Sidebar.ActualWidth -le $ui.Sidebar.ActualHeight) {throw 'Orientacao horizontal nao aplicada.'}
 $font=[Windows.Media.Typeface]::new($ui.Sidebar.FontFamily,[Windows.FontStyles]::Normal,[Windows.FontWeights]::Bold,[Windows.FontStretches]::Normal);$glyph=$null
 if (-not $font.TryGetGlyphTypeface([ref]$glyph) -or $glyph.FontUri.AbsoluteUri -notmatch 'Inter-Bold.ttf') {throw 'Inter Bold real nao carregou.'}
 Save-WindowPreview $ui.Sidebar 'sidebar-horizontal'
 $button=$ui.Buttons.codex.Button;[void]$button.ApplyTemplate();$frame=$button.Template.FindName('MetalFrame',$button)
 $enter=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount);$enter.RoutedEvent=[Windows.UIElement]::MouseEnterEvent;$button.RaiseEvent($enter)
 if (-not $frame.BorderBrush.RelativeTransform.HasAnimatedProperties) {throw 'Efeito metalico nao iniciou ao interagir.'}
 $leave=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount);$leave.RoutedEvent=[Windows.UIElement]::MouseLeaveEvent;$button.RaiseEvent($leave)
 $framePump=[Windows.Threading.DispatcherFrame]::new();[void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle,[Action]{$framePump.Continue=$false});[Windows.Threading.Dispatcher]::PushFrame($framePump)
 if ($frame.BorderBrush.RelativeTransform.HasAnimatedProperties) {throw 'Animacao continua consumindo em repouso.'}
 Update-Sidebar @('codex','claude','gemini') $snapshots
 if ($ui.Buttons.Count -ne 3) {throw 'Mudanca de orientacao perdeu icones.'}
 $ui.Buttons.claude.Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 if ($ui.SelectedId -ne 'claude') {throw 'Dashboard nao trocou.'}
 Update-Sidebar @('codex') $snapshots
 if ($ui.Dashboard.IsVisible) {throw 'Dashboard de IA fechada permanece aberto.'}
 $ui.Buttons.codex.Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 $ui.Dashboard.FindName('ProviderTitle').Text='Codex | TESTE DE INTERFACE'
 $ui.Dashboard.UpdateLayout();$ui.Sidebar.UpdateLayout()
 [IO.Directory]::CreateDirectory($PreviewDirectory) | Out-Null
 foreach ($entry in @(@{Window=$ui.Sidebar;Name='sidebar'},@{Window=$ui.Dashboard;Name='dashboard'})) {
  $w=$entry.Window;$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$w.ActualWidth,[int]$w.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($w)
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
  $stream=[IO.File]::Create((Join-Path $PreviewDirectory ($entry.Name+'.png')));try {$encoder.Save($stream)} finally {$stream.Dispose()}
 }
 $settingsWindow=New-ProviderSettingsWindow 'codex';$settingsWindow.Show()
 $picker=$settingsWindow.FindName('ProviderPicker');$picker.SelectedIndex=2
 if ($settingsWindow.Tag -ne 'gemini' -or $settingsWindow.FindName('GoogleFields').Visibility -ne 'Visible') {throw 'Seletor nao configurou IA fechada.'}
 $picker.SelectedIndex=1
 if ($settingsWindow.Tag -ne 'claude' -or $settingsWindow.FindName('GoogleFields').Visibility -ne 'Collapsed') {throw 'Seletor manteve campos da outra IA.'}
 $settingsWindow.Close()
 Repair-WindowPlacement
 Update-Sidebar @() $snapshots
 if ($ui.Sidebar.IsVisible -or $ui.Dashboard.IsVisible) {throw 'Janelas nao ocultadas.'}
 Toggle-PanelVisibility
 if (-not $ui.Sidebar.IsVisible -or $ui.Buttons.Count -ne 0) {throw 'Abrir manualmente sem IA deve mostrar controles sem inventar icones.'}
 Toggle-PanelVisibility
 Update-Sidebar @() $snapshots
 if ($ui.Sidebar.IsVisible) {throw 'Recolher painel foi desfeito pela atualizacao.'}
 Update-Sidebar @('codex','claude') $snapshots
 if ($ui.Sidebar.IsVisible) {throw 'Nova IA desfez recolhimento explicito.'}
 Toggle-PanelVisibility;Show-ProviderDashboard 'codex';$ui.Sidebar.Close()
 $snapshots.codex.Subscription.Status='error';Update-Sidebar @('codex','claude') $snapshots
 if ($ui.Sidebar.IsVisible -or $ui.Dashboard.IsVisible -or -not $ui.UserHidden) {throw 'Fechar pela barra de tarefas deixou dashboard aberto ou reabriu painel.'}
 'PASS WPF: ocultar, abrir, adicionar icones, clique, trocar dashboard, remover IA, renderizar, carregar configuracoes.'
} finally { Close-AppWindows }
