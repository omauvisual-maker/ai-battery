Import-Module "$PSScriptRoot\Core.psm1"
Import-Module "$PSScriptRoot\Settings.psm1"
Import-Module "$PSScriptRoot\Desktop.psm1"
$script:UI=$null
function Get-DockLayout([string]$Orientation,[int]$Count) {
 if ($Orientation -eq 'horizontal') {return @{Orientation='Horizontal';Width=(176+88*[math]::Max(0,$Count));Height=106}}
 return @{Orientation='Vertical';Width=92;Height=(160+100*[math]::Max(0,$Count))}
}
function Get-SummaryView($Snapshot) {
 $measure=$Snapshot.Subscription;$kind='Assinatura'
 if ($null -eq $measure.RemainingPercent) { $measure=$Snapshot.Api;$kind='API' }
 $label=Get-MeasureStatusText $measure
 return @{Percent=$measure.RemainingPercent;Kind=$kind;Label=$label;Color=(Get-BatteryColor $measure.RemainingPercent)}
}
function Get-MeasureStatusText($Measure) {
 if ($Measure.IsManual -and $Measure.Status -eq 'connected') { return 'Manual' }
 switch ($Measure.Status) { 'connected' { return 'Conectado' }; 'stale' { return 'Atualizacao atrasada' }; 'error' { return 'Falha na conexao' }; 'unavailable' { return 'Indisponivel' }; default { return 'Configurar' } }
}
function Test-MeasureRecovered($Measure) { return ($Measure.Status -eq 'connected' -and $null -ne $Measure.RemainingPercent -and $Measure.RemainingPercent -gt 20) }
function Get-UIState([string[]]$ActiveIds,[string]$SelectedId) {
 $ids=@($ActiveIds | Select-Object -Unique)
 $selected=$null;if ($SelectedId -in $ids) { $selected=$SelectedId }
 return @{ActiveIds=$ids;SelectedId=$selected;ShowSidebar=($ids.Count -gt 0)}
}
function Get-ClampedPosition($Position,$Area,[double]$Width,[double]$Height) {
 $x=if ($Position) {$Position.X} else {$Area.Left+$Area.Width-$Width-12}
 $y=if ($Position) {$Position.Y} else {$Area.Top+($Area.Height-$Height)/2}
 return @{X=[math]::Max($Area.Left,[math]::Min($x,$Area.Left+$Area.Width-$Width));Y=[math]::Max($Area.Top,[math]::Min($y,$Area.Top+$Area.Height-$Height))}
}
function Get-PercentText($Value) { if ($null -eq $Value) { return [string][char]0x2014 }; return ([math]::Round([double]$Value,1).ToString('0.#',[Globalization.CultureInfo]::InvariantCulture)+'%') }
function Get-MoneyText($Value) { if ($null -eq $Value) { return [string][char]0x2014 }; return ('US$ '+([double]$Value).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)) }
function Get-LocalTimeText($Value) { if (-not $Value) { return 'sem leitura' }; try { $zone=[TimeZoneInfo]::FindSystemTimeZoneById('E. South America Standard Time');return [TimeZoneInfo]::ConvertTime([datetimeoffset]$Value,$zone).ToString('dd/MM HH:mm') } catch { return 'horario indisponivel' } }
function Read-XamlWithContext([xml]$Xml,$Context) {
 $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Xml.OuterXml))
 try {return [Windows.Markup.XamlReader]::Load($stream,$Context)} finally {$stream.Dispose()}
}
function Read-Window([string]$FileName) {
 $xml=[xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot $FileName))
 $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('p','http://schemas.microsoft.com/winfx/2006/xaml/presentation')
 foreach ($node in @($xml.SelectNodes('//p:Style[@TargetType="Button" or @TargetType="TextBox" or @TargetType="CheckBox"]',$ns))) {[void]$node.ParentNode.RemoveChild($node)}
 foreach ($node in @($xml.SelectNodes('//p:Setter[@Property="FontFamily"]',$ns))) {[void]$node.ParentNode.RemoveChild($node)}
 foreach ($node in @($xml.SelectNodes('//*[@FontWeight]',$ns))) {$node.SetAttribute('FontWeight','Bold')}
 $xml.DocumentElement.SetAttribute('FontWeight','Bold')
 $context=[Windows.Markup.ParserContext]::new();$context.BaseUri=[uri]::new($PSScriptRoot.TrimEnd('\')+'\')
 $window=Read-XamlWithContext $xml $context
 if ($window.Resources.MergedDictionaries.Count -eq 0) { $theme=Read-XamlWithContext ([xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Theme.xaml'))) $context;$window.Resources.MergedDictionaries.Add($theme) }
 $fontDir=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\fonts'
 $window.FontFamily=[Windows.Media.FontFamily]::new([uri]::new($fontDir+'\'),'./#Inter')
 $window.FontWeight=[Windows.FontWeights]::Bold
 $icon=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\AI-Battery.ico';if (Test-Path $icon) {$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([uri]::new($icon))}
 return $window
}
function Get-ProviderName([string]$Id) { switch ($Id) {'codex' {'Codex'};'claude' {'Claude'};'gemini' {'Gemini'}} }
function Get-AppUI { return $script:UI }
function New-AppWindows($Settings,[scriptblock]$SaveCallback,[scriptblock]$ExitCallback,[scriptblock]$RefreshCallback) {
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Drawing,System.Windows.Forms
 $script:UI=@{Settings=$Settings;SaveCallback=$SaveCallback;ExitCallback=$ExitCallback;RefreshCallback=$RefreshCallback;Sidebar=(Read-Window 'Sidebar.xaml');Dashboard=(Read-Window 'Dashboard.xaml');SettingsWindow=$null;Snapshots=@{};ActiveIds=@();SelectedId=$null;Buttons=@{};Alerts=@{};Exiting=$false;RulePaths=@{};UserHidden=$false;ForceVisible=$false;LastPaintKey=$null}
 $script:UI.CodexReady=$true;$script:UI.OperationsReport=$null;$script:UI.ResumeDashboard=$false;$script:UI.LastReportClock=$null
 $sidebar=$script:UI.Sidebar;$dashboard=$script:UI.Dashboard
 $sidebar.Topmost=[bool]$Settings.Topmost;$dashboard.Topmost=[bool]$Settings.Topmost
 $sidebar.Add_SourceInitialized({param($sender,$e) Set-DesktopWindowIdentity $sender})
 $sidebar.FindName('DragHandle').Add_MouseLeftButtonDown({param($sender,$e) if ($e.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) { $script:UI.Sidebar.DragMove();$script:UI.Settings.Position=@{X=$script:UI.Sidebar.Left;Y=$script:UI.Sidebar.Top};try { & $script:UI.SaveCallback $script:UI.Settings } catch {};Set-DashboardPosition } })
 $sidebar.FindName('OpenSettings').Add_Click({ $id=if ($script:UI.SelectedId) {$script:UI.SelectedId} elseif ($script:UI.ActiveIds.Count) {$script:UI.ActiveIds[0]} else {'codex'};Show-ProviderSettings $id })
 $sidebar.FindName('ExitMonitor').Add_Click({ & $script:UI.ExitCallback })
 $sidebar.FindName('ToggleOrientation').Add_Click({ Switch-DockOrientation })
 $sidebar.Add_Closing({param($sender,$e) if (-not $script:UI.Exiting) { $e.Cancel=$true;Hide-Panel } })
 $dashboard.Add_Closing({param($sender,$e) if (-not $script:UI.Exiting) { $e.Cancel=$true;$sender.Hide();$script:UI.SelectedId=$null } })
 $dashboard.FindName('CloseDashboard').Add_Click({ $script:UI.Dashboard.Hide();$script:UI.SelectedId=$null })
 $dashboard.FindName('ConfigureProvider').Add_Click({Show-ProviderSettings $script:UI.SelectedId})
 $dashboard.FindName('RefreshData').Add_Click({ & $script:UI.RefreshCallback $script:UI.SelectedId })
 $dashboard.FindName('DismissAlert').Add_Click({ if ($script:UI.SelectedId) {$script:UI.Alerts.Remove($script:UI.SelectedId)};$script:UI.Dashboard.FindName('AlertBanner').Visibility='Collapsed' })
 $sidebar.Add_SizeChanged({ Set-AppWindowPosition $script:UI.Settings.Position;Set-DashboardPosition })
 $tray=[Windows.Forms.NotifyIcon]::new();$iconPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\AI-Battery.ico';if (Test-Path $iconPath) {$script:UI.OwnIcon=[Drawing.Icon]::new($iconPath);$tray.Icon=$script:UI.OwnIcon} else {$tray.Icon=[Drawing.SystemIcons]::Information};$tray.Text='AI Battery | consumo de IA'
 $menu=[Windows.Forms.ContextMenuStrip]::new()
 $toggle=$menu.Items.Add('Abrir / recolher painel');$toggle.Add_Click({Toggle-PanelVisibility})
 $orient=$menu.Items.Add('Horizontal / vertical');$orient.Add_Click({Switch-DockOrientation})
 $configure=$menu.Items.Add('Configurar Codex, Claude e Gemini');$configure.Add_Click({Show-ProviderSettings 'codex'})
 $exit=$menu.Items.Add('Encerrar monitor');$exit.Add_Click({ & $script:UI.ExitCallback })
 $tray.ContextMenuStrip=$menu;$tray.Add_DoubleClick({Show-ProviderSettings 'codex'});$tray.Visible=$true;$script:UI.Tray=$tray;$script:UI.TrayMenu=$menu
 return $script:UI
}
function Apply-DockLayout {
 $layout=Get-DockLayout $script:UI.Settings.Orientation $script:UI.ActiveIds.Count;$w=$script:UI.Sidebar
 $w.FindName('DockRoot').Orientation=$layout.Orientation;$w.FindName('AppList').Orientation=$layout.Orientation;$w.FindName('DockControls').Orientation=$layout.Orientation
 $w.Width=$layout.Width;$w.Height=$layout.Height
 $w.FindName('ToggleOrientation').Content=if ($layout.Orientation -eq 'Horizontal') {'V'} else {'H'}
 Set-AppWindowPosition $script:UI.Settings.Position;Set-DashboardPosition
}
function Switch-DockOrientation {
 $candidate=ConvertTo-AppHashtable (ConvertFrom-Json ($script:UI.Settings | ConvertTo-Json -Depth 12))
 $candidate.Position=@{X=$script:UI.Sidebar.Left;Y=$script:UI.Sidebar.Top};$candidate.Orientation=if ($candidate.Orientation -eq 'horizontal') {'vertical'} else {'horizontal'}
 try {& $script:UI.SaveCallback $candidate;$script:UI.Settings=$candidate;Apply-DockLayout;$script:UI.LastPaintKey=$null;Update-Sidebar $script:UI.ActiveIds $script:UI.Snapshots} catch {[void][Windows.MessageBox]::Show('Nao foi possivel salvar a orientacao.','AI Battery')}
}
function Toggle-PanelVisibility {
 if (-not $script:UI.CodexReady) {return}
 if ($script:UI.Sidebar.IsVisible -and $script:UI.Sidebar.WindowState -ne 'Minimized') { Hide-Panel }
 else {$script:UI.UserHidden=$false;$script:UI.ForceVisible=($script:UI.ActiveIds.Count -eq 0);$script:UI.Sidebar.WindowState='Normal';Apply-DockLayout;$script:UI.Sidebar.Show();[void]$script:UI.Sidebar.Activate()}
 $script:UI.LastPaintKey=$null
}
function Hide-Panel {$script:UI.UserHidden=$true;$script:UI.ForceVisible=$false;$script:UI.SelectedId=$null;$script:UI.Sidebar.Hide();$script:UI.Dashboard.Hide();$script:UI.LastPaintKey=$null}
function Set-CodexWindowVisibility([bool]$Ready) {
 if ($script:UI.CodexReady -eq $Ready) {return}
 if (-not $Ready) {$script:UI.ResumeDashboard=$script:UI.Dashboard.IsVisible;$script:UI.Sidebar.Hide();$script:UI.Dashboard.Hide()}
 $script:UI.CodexReady=$Ready;$script:UI.LastPaintKey=$null
 if ($Ready -and $script:UI.ResumeDashboard -and -not $script:UI.UserHidden -and $script:UI.SelectedId) {$script:UI.Dashboard.Show();Set-DashboardPosition;$script:UI.ResumeDashboard=$false}
}
function Set-OperationsReport($Report) {$script:UI.OperationsReport=$Report;$script:UI.LastReportClock=$null}
function Get-OperationsRowView($Row,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
 $elapsed=$Row.ElapsedSeconds
 if ($Row.Status -eq 'Em andamento' -and $Row.StartedAtUtc) {try {$elapsed=[math]::Max(0,[int]($Now-[datetimeoffset]$Row.StartedAtUtc).TotalSeconds)} catch {}}
 $dash=[string][char]0x2014
 $duration=if ($null -eq $elapsed) {$dash} else {([timespan]::FromSeconds($elapsed)).ToString('hh\:mm\:ss')}
 $tokens=if ($null -eq $Row.TotalTokens) {$dash} else {([long]$Row.TotalTokens).ToString('N0',[Globalization.CultureInfo]::GetCultureInfo('pt-BR'))}
 $cost=if ($null -eq $Row.EstimatedUsd) {$dash} else {'US$ '+([double]$Row.EstimatedUsd).ToString('0.0000',[Globalization.CultureInfo]::InvariantCulture)}
 $shortId=[string]$Row.Id;if ($shortId.Length -gt 8) {$shortId=$shortId.Substring($shortId.Length-8)}
 $operations=if ($null -eq $Row.Operations) {$dash} else {$Row.Operations}
 $counts=@(foreach ($name in @('InputTokens','CachedTokens','OutputTokens')) {if ($null -eq $Row[$name]) {$dash} else {$Row[$name]}})
 return @{Text="$($Row.Operation) | $($Row.Status)`n$duration | $tokens tokens | $cost estimado`n$($Row.Model) | execucao $shortId | $operations operacoes";ToolTip="Entrada: $($counts[0]) | cache: $($counts[1]) | saida: $($counts[2])"}
}
function Get-OperationsSourceText($Report) {
 $label=if ($Report.Source -eq 'unified') {'Runtime unificado'} else {'Leitura local (historico recente)'}
 $text=$label+': '+(Get-LocalTimeText $Report.ObservedAtUtc)
 if ($Report.Stale) {$text+=' | observacao desatualizada; runtime indisponivel'}
 if ($Report.Error) {$text+=' | leitura parcial; aguardando novos eventos'}
 return $text
}
function Update-LiveReportClock {
 if (-not $script:UI.Dashboard.IsVisible -or $script:UI.SelectedId -ne 'codex') {return}
 $second=[datetimeoffset]::UtcNow.ToUnixTimeSeconds()
 if ($script:UI.LastReportClock -eq $second) {return};$script:UI.LastReportClock=$second;Update-OperationsCard
}
function Update-OperationsCard {
 $w=$script:UI.Dashboard;$card=$w.FindName('OperationsCard')
 $card.Visibility=if ($script:UI.SelectedId -eq 'codex') {'Visible'} else {'Collapsed'}
 if ($script:UI.SelectedId -ne 'codex') {return}
 $report=$script:UI.OperationsReport;$rows=@($report.Turns | Where-Object {$_});$list=$w.FindName('OperationsList');$list.Children.Clear()
 $active=@($rows | Where-Object {$_.Status -eq 'Em andamento'}).Count
 $w.FindName('OperationsSummary').Text=if ($rows.Count) {"$active em andamento | $($rows.Count) execucoes recentes"} else {'Aguardando eventos locais do Codex'}
 foreach ($row in $rows) {
  $view=Get-OperationsRowView $row
  $text=[Windows.Controls.TextBlock]::new();$text.Text=$view.Text
  $text.TextWrapping='Wrap';$text.FontSize=11;$text.Margin='0,0,0,12';$text.Foreground=if ($row.Status -eq 'Em andamento') {'#A4DDC6'} else {'#AAB6CC'}
  $text.ToolTip=$view.ToolTip;[void]$list.Children.Add($text)
 }
 $w.FindName('OperationsSource').Text=Get-OperationsSourceText $report
}
function Repair-WindowPlacement {
 if (-not $script:UI.Sidebar.IsVisible) {return}
 $areas=@([Windows.Forms.Screen]::AllScreens | ForEach-Object {$_.WorkingArea.ToString()}) -join ';'
 $source=[Windows.PresentationSource]::FromVisual($script:UI.Sidebar)
 if ($source) {$areas+=';'+$source.CompositionTarget.TransformToDevice.ToString()}
 if ($areas -ne $script:UI.DisplaySignature) {
  $script:UI.DisplaySignature=$areas
  Set-AppWindowPosition @{X=$script:UI.Sidebar.Left;Y=$script:UI.Sidebar.Top};Set-DashboardPosition
 }
}
function Set-AppWindowPosition($SavedPosition) {
 $window=$script:UI.Sidebar
 $area=[Windows.SystemParameters]::WorkArea
 # Screen coordinates are converted back to WPF device-independent units.
 if ($SavedPosition) {
  $source=[Windows.PresentationSource]::FromVisual($window)
  if ($source) {
   $matrix=$source.CompositionTarget.TransformToDevice
   $point=[Drawing.Point]::new([int]($SavedPosition.X*$matrix.M11),[int]($SavedPosition.Y*$matrix.M22))
   $screen=[Windows.Forms.Screen]::FromPoint($point).WorkingArea
   $area=@{Left=$screen.Left/$matrix.M11;Top=$screen.Top/$matrix.M22;Width=$screen.Width/$matrix.M11;Height=$screen.Height/$matrix.M22}
  }
 }
 $height=if ($window.ActualHeight -gt 0) {$window.ActualHeight} else {350}
 $position=Get-ClampedPosition $SavedPosition $area $window.Width $height;$window.Left=$position.X;$window.Top=$position.Y
}
function Set-DashboardPosition {
 if (-not $script:UI.Dashboard.IsVisible) { return }
 $area=[Windows.SystemParameters]::WorkArea;$side=$script:UI.Sidebar;$dash=$script:UI.Dashboard
 $source=[Windows.PresentationSource]::FromVisual($side)
 if ($source) { $m=$source.CompositionTarget.TransformToDevice;$screen=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int]($side.Left*$m.M11),[int]($side.Top*$m.M22))).WorkingArea;$area=@{Left=$screen.Left/$m.M11;Top=$screen.Top/$m.M22;Width=$screen.Width/$m.M11;Height=$screen.Height/$m.M22} }
 if ($script:UI.Settings.Orientation -eq 'horizontal') {$x=$side.Left;$y=$side.Top+$side.Height+12;if ($y+$dash.Height -gt $area.Top+$area.Height) {$y=$side.Top-$dash.Height-12}}
 else {$x=$side.Left-$dash.Width-12;$y=$side.Top;if ($x -lt $area.Left) {$x=$side.Left+$side.Width+12}}
 $pos=Get-ClampedPosition @{X=$x;Y=$y} $area $dash.Width $dash.Height;$dash.Left=$pos.X;$dash.Top=$pos.Y
}
function New-ProviderIcon([string]$Id) {
 $path=$script:UI.RulePaths[$Id]
 if ($path -and (Test-Path -LiteralPath $path)) {
  $icon=$null
  try { $icon=[Drawing.Icon]::ExtractAssociatedIcon($path);$image=[Windows.Controls.Image]::new();$image.Width=30;$image.Height=30;$image.Source=[Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle,[Windows.Int32Rect]::Empty,[Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions());$image.Source.Freeze();return $image } catch {} finally { if ($icon) {$icon.Dispose()} }
 }
 $t=[Windows.Controls.TextBlock]::new();$t.FontSize=28;$t.HorizontalAlignment='Center';$t.FontWeight='Bold'
 switch ($Id) { 'codex' {$t.Text='C';$t.Foreground='#D9E4F2'};'claude' {$t.Text=[string][char]0x2733;$t.Foreground='#DB9571'};'gemini' {$t.Text=[string][char]0x2726;$t.Foreground='#90B4FA'} }
 return $t
}
function Update-Sidebar([string[]]$ActiveIds,[hashtable]$Snapshots) {
 $paintKey=($ActiveIds -join ',')+'|'+$script:UI.Settings.Orientation+'|'+$script:UI.SelectedId+'|'+$script:UI.UserHidden+'|'+$script:UI.ForceVisible+'|'+($Snapshots | ConvertTo-Json -Depth 8 -Compress)+'|'+($script:UI.Alerts | ConvertTo-Json -Depth 4 -Compress)
 if ($paintKey -eq $script:UI.LastPaintKey) {return};$script:UI.LastPaintKey=$paintKey
 $state=Get-UIState $ActiveIds $script:UI.SelectedId;$script:UI.Snapshots=$Snapshots
 if ($script:UI.SelectedId -and -not $state.SelectedId) { $script:UI.Dashboard.Hide();$script:UI.SelectedId=$null }
 if (($state.ActiveIds -join ',') -ne ($script:UI.ActiveIds -join ',')) {
  $script:UI.ActiveIds=$state.ActiveIds;$list=$script:UI.Sidebar.FindName('AppList');$list.Children.Clear();$script:UI.Buttons=@{}
  if ($state.ActiveIds.Count) {$script:UI.ForceVisible=$false}
  foreach ($id in $state.ActiveIds) {
   $button=[Windows.Controls.Button]::new();$button.Tag=$id;$button.Margin='2,3';$button.Padding='2,6';$button.Width=74;$button.Height=90
   $panel=[Windows.Controls.StackPanel]::new();$panel.HorizontalAlignment='Center';[void]$panel.Children.Add((New-ProviderIcon $id))
   $name=[Windows.Controls.TextBlock]::new();$name.Text=Get-ProviderName $id;$name.FontSize=10;$name.Foreground='#AAB6CC';$name.HorizontalAlignment='Center';$name.Margin='0,3,0,3';[void]$panel.Children.Add($name)
   $pct=[Windows.Controls.TextBlock]::new();$pct.FontSize=13;$pct.FontWeight='Bold';$pct.HorizontalAlignment='Center';[void]$panel.Children.Add($pct)
   $battery=[Windows.Controls.ProgressBar]::new();$battery.Width=36;$battery.Height=5;$battery.Maximum=100;$battery.Background='#303B50';$battery.BorderThickness=0;$battery.Margin='0,5,0,0';[void]$panel.Children.Add($battery)
   $button.Content=$panel;$button.Add_Click({param($sender,$e) Show-ProviderDashboard ([string]$sender.Tag) });[void]$list.Children.Add($button)
   $script:UI.Buttons[$id]=@{Button=$button;Percent=$pct;Battery=$battery}
  }
  Apply-DockLayout
 }
 foreach ($id in $script:UI.ActiveIds) {
  $s=$Snapshots[$id];if (-not $s) {$s=New-ProviderSnapshot $id};$v=Get-SummaryView $s;$controls=$script:UI.Buttons[$id]
  $controls.Percent.Text=Get-PercentText $v.Percent;$controls.Percent.Foreground=$v.Color;$controls.Battery.Foreground=$v.Color;$controls.Battery.Value=if ($null -eq $v.Percent) {0} else {$v.Percent}
  $controls.Button.ToolTip="$($v.Kind) | $($v.Label)"
  if ($script:UI.Alerts.ContainsKey($id)) { $controls.Button.Background='#31161B' } elseif ($script:UI.SelectedId -eq $id) { $controls.Button.Background='#20232D' } else { $controls.Button.Background='#0B0C0F' }
 }
 if (($state.ShowSidebar -or $script:UI.ForceVisible) -and -not $script:UI.UserHidden -and $script:UI.CodexReady) { if (-not $script:UI.Sidebar.IsVisible) { Apply-DockLayout;$script:UI.Sidebar.Show();Set-AppWindowPosition $script:UI.Settings.Position } } else { $script:UI.Sidebar.Hide();$script:UI.Dashboard.Hide() }
 if ($script:UI.SelectedId) { Update-Dashboard }
 if ($script:UI.AutoStartReport -and $script:UI.CodexReady -and 'codex' -in $script:UI.ActiveIds -and -not $script:UI.UserHidden) {$script:UI.AutoStartReport=$false;Show-ProviderDashboard 'codex'}
}
function Show-ProviderDashboard([string]$ProviderId) {
 if (-not $script:UI.CodexReady) {return}
 if ($ProviderId -notin $script:UI.ActiveIds) { return }
 $script:UI.SelectedId=$ProviderId;Update-Dashboard;$script:UI.Dashboard.Show();Set-DashboardPosition;[void]$script:UI.Dashboard.Activate()
}
function Update-Dashboard {
 $id=$script:UI.SelectedId;if (-not $id) { return };$s=$script:UI.Snapshots[$id];if (-not $s) {$s=New-ProviderSnapshot $id};$w=$script:UI.Dashboard
 $w.FindName('ProviderTitle').Text=Get-ProviderName $id
 Update-OperationsCard
 foreach ($key in @('Subscription','Api')) {
  $m=$s[$key];$w.FindName($key+'Percent').Text=Get-PercentText $m.RemainingPercent;$w.FindName($key+'Percent').Foreground=Get-BatteryColor $m.RemainingPercent
  $bar=$w.FindName($key+'Battery');$bar.Value=if ($null -eq $m.RemainingPercent) {0} else {$m.RemainingPercent};$bar.Foreground=Get-BatteryColor $m.RemainingPercent
  $lines=@((Get-MeasureStatusText $m),$m.Source,('Leitura: '+(Get-LocalTimeText $m.ObservedAtUtc)))
  if ($m.DataThroughUtc) {$lines+=('Dados da fonte: '+(Get-LocalTimeText $m.DataThroughUtc))}
  if ($m.PeriodStartUtc -and $m.PeriodEndUtc) {$lines+=('Janela: '+(Get-LocalTimeText $m.PeriodStartUtc)+' ate '+(Get-LocalTimeText $m.PeriodEndUtc))}
  if ($m.ResetAtUtc) { $lines+=('Reposicao: '+(Get-LocalTimeText $m.ResetAtUtc)) }
  if ($key -eq 'Api') { $lines+=('Orcamento: '+(Get-MoneyText $m.BudgetUsd));if ($m.OverBudgetUsd -gt 0) {$lines+=('Excedente: '+(Get-MoneyText $m.OverBudgetUsd))} }
  if ($m.Message) { $lines+=$m.Message };$w.FindName($key+'Details').Text=$lines -join "`n"
 }
 $w.FindName('TodayCost').Text=Get-MoneyText $s.Api.SpentTodayUsd;$w.FindName('MonthCost').Text=Get-MoneyText $s.Api.SpentMonthUsd
 $w.FindName('AlertBanner').Visibility=if ($script:UI.Alerts.ContainsKey($id)) {'Visible'} else {'Collapsed'}
 if ($script:UI.Alerts.ContainsKey($id)) {$w.FindName('AlertText').Text=$script:UI.Alerts[$id].Message}
}
function Set-ProviderAlert([string]$Id,[string]$Message,[string]$Kind) { $script:UI.Alerts[$Id]=@{Message=$Message;Kind=$Kind};Update-Sidebar $script:UI.ActiveIds $script:UI.Snapshots }
function Clear-RecoveredProviderAlert([string]$Id,$Snapshot) { if ($script:UI.Alerts.ContainsKey($Id) -and (Test-MeasureRecovered $Snapshot[$script:UI.Alerts[$Id].Kind])) { $script:UI.Alerts.Remove($Id) } }
function Convert-InputNumber([string]$Text) {
 if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
 $v=0.0; if (-not [double]::TryParse($Text.Trim().Replace(',','.'),[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$v) -or [double]::IsNaN($v) -or [double]::IsInfinity($v)) { throw 'Informe um numero positivo, sem separador de milhar.' }; return $v
}
function Set-SettingsProviderFields([string]$ProviderId) {
 $p=$script:UI.Settings.Providers | Where-Object Id -eq $ProviderId | Select-Object -First 1
 $w=$script:UI.SettingsWindow;$w.Tag=$ProviderId;$w.FindName('SettingsTitle').Text='Configurar '+(Get-ProviderName $ProviderId)
 foreach ($name in @('SubscriptionInput','ApiInput','ExecutableInput','GoogleProject','GoogleTable','SettingsMessage')) { $w.FindName($name).Text='' }
 $w.FindName('SecretInput').Clear();$w.FindName('GoogleFields').Visibility='Collapsed';$w.FindName('EnableGoogleQuery').IsChecked=$false
 $w.FindName('SecretLabel').Text='Chave administrativa da API';$w.FindName('SecretHint').Text='Chave Admin com acesso a custos da organizacao. Deixe vazio para manter a credencial salva.'
 $w.FindName('AlwaysOnTop').IsChecked=[bool]$script:UI.Settings.Topmost;$w.FindName('BudgetInput').Text=if ($null -eq $p.ApiMonthlyBudgetUsd) {''} else {[string]$p.ApiMonthlyBudgetUsd}
 $w.FindName('ManualSubscription').IsChecked=($p.SubscriptionMode -eq 'manual');$w.FindName('ManualApi').IsChecked=($p.ApiMode -eq 'manual')
 if ($p.ManualSubscription) {$w.FindName('SubscriptionInput').Text=[string]$p.ManualSubscription.RemainingPercent};if ($p.ManualApi) {$w.FindName('ApiInput').Text=[string]$p.ManualApi.SpentMonthUsd}
 if ($p.DetectionRules.Count) {$w.FindName('ExecutableInput').Text=if ($p.DetectionRules[0].ScriptPath) {$p.DetectionRules[0].ScriptPath} else {$p.DetectionRules[0].ExecutablePath}}
 if ($ProviderId -eq 'gemini') { $w.FindName('GoogleFields').Visibility='Visible';$w.FindName('GoogleProject').Text=$p.GeminiProjectId;$w.FindName('GoogleTable').Text=$p.GeminiBillingTable;$w.FindName('EnableGoogleQuery').IsChecked=[bool]$p.GeminiQueryEnabled;$w.FindName('SecretLabel').Text='Token OAuth Google Cloud (expira)';$w.FindName('SecretHint').Text='Token com acesso BigQuery. Deixe vazio para manter. Ao expirar, renove nas configuracoes.' }
}
function New-ProviderSettingsWindow([string]$ProviderId) {
 if ($script:UI.SettingsWindow) { return $script:UI.SettingsWindow }
 $w=Read-Window 'Settings.xaml';$script:UI.SettingsWindow=$w
 Set-SettingsProviderFields $ProviderId
 $picker=$w.FindName('ProviderPicker');foreach ($item in $picker.Items) {if ($item.Tag -eq $ProviderId) {$picker.SelectedItem=$item;break}}
 $picker.Add_SelectionChanged({param($sender,$e) if ($sender.SelectedItem) {Set-SettingsProviderFields ([string]$sender.SelectedItem.Tag)} })
 $w.FindName('BrowseExecutable').Add_Click({ $dialog=[Microsoft.Win32.OpenFileDialog]::new();$dialog.Filter='Aplicativo ou CLI|*.exe;*.js;*.mjs;*.cjs';if ($dialog.ShowDialog()) {$script:UI.SettingsWindow.FindName('ExecutableInput').Text=$dialog.FileName} })
 $w.FindName('CancelSettings').Add_Click({$script:UI.SettingsWindow.Close()})
 $w.Add_Closed({$script:UI.SettingsWindow=$null})
 $w.FindName('SaveSettings').Add_Click({
  $w=$script:UI.SettingsWindow
  try {
   $candidate=ConvertTo-AppHashtable (ConvertFrom-Json ($script:UI.Settings | ConvertTo-Json -Depth 12));$p=$candidate.Providers | Where-Object Id -eq $w.Tag | Select-Object -First 1
   $candidate.Topmost=[bool]$w.FindName('AlwaysOnTop').IsChecked;$p.ApiMonthlyBudgetUsd=Convert-InputNumber $w.FindName('BudgetInput').Text
   $p.SubscriptionMode=if ($w.FindName('ManualSubscription').IsChecked) {'manual'} else {'auto'};$p.ApiMode=if ($w.FindName('ManualApi').IsChecked) {'manual'} else {'auto'}
   $remaining=Convert-InputNumber $w.FindName('SubscriptionInput').Text;$spent=Convert-InputNumber $w.FindName('ApiInput').Text
   if ($null -ne $remaining -and ($remaining -lt 0 -or $remaining -gt 100)) { throw 'Saldo da assinatura deve estar entre 0 e 100.' }
   if ($p.SubscriptionMode -eq 'manual' -and $null -eq $remaining) { throw 'Informe o saldo restante da assinatura.' }
   if ($p.ApiMode -eq 'manual' -and $null -eq $spent) { throw 'Informe o gasto mensal da API.' }
   if ($null -ne $remaining) { $p.ManualSubscription=@{RemainingPercent=$remaining;UpdatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')} }
   if ($null -ne $spent) { $p.ManualApi=@{SpentMonthUsd=$spent;UpdatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')} }
   $exe=$w.FindName('ExecutableInput').Text.Trim();$p.DetectionRules=@()
   if ($exe) {
    if (-not [IO.Path]::IsPathRooted($exe) -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Selecione um executavel ou script existente.' }
    if ($exe -match '\.(js|mjs|cjs)$') { $node=Get-Command node.exe -ErrorAction Stop;$p.DetectionRules=@(@{ProviderId=$p.Id;ExecutablePath=$node.Source;ScriptPath=$exe;Kind='cli'}) }
    elseif ($exe -match '\.exe$') {$p.DetectionRules=@(@{ProviderId=$p.Id;ExecutablePath=$exe;ScriptPath=$null;Kind='desktop'})} else { throw 'Selecione um arquivo .exe ou .js.' }
   }
   if ($p.Id -eq 'gemini') {$p.GeminiProjectId=$w.FindName('GoogleProject').Text.Trim();$p.GeminiBillingTable=$w.FindName('GoogleTable').Text.Trim();$p.GeminiQueryEnabled=[bool]$w.FindName('EnableGoogleQuery').IsChecked}
   $secret=$w.FindName('SecretInput').SecurePassword
   if ($secret.Length) { Save-ProviderSecret $p.Id $secret }
   & $script:UI.SaveCallback $candidate
   $script:UI.Settings=$candidate;$script:UI.Sidebar.Topmost=$candidate.Topmost;$script:UI.Dashboard.Topmost=$candidate.Topmost
   $w.Close(); & $script:UI.RefreshCallback $p.Id
  } catch { $w.FindName('SettingsMessage').Text=$_.Exception.Message }
 })
 return $w
}
function Show-ProviderSettings([string]$ProviderId) {
 if ($script:UI.SettingsWindow) {[void]$script:UI.SettingsWindow.Activate();return}
 $w=New-ProviderSettingsWindow $ProviderId;[void]$w.ShowDialog()
}
function Close-AppWindows {
 $script:UI.Exiting=$true
 if ($script:UI.Tray) {$script:UI.Tray.Visible=$false;$script:UI.Tray.Dispose();$script:UI.TrayMenu.Dispose()}
 if ($script:UI.OwnIcon) {$script:UI.OwnIcon.Dispose()}
 if ($script:UI.SettingsWindow) {$script:UI.SettingsWindow.Close()};$script:UI.Dashboard.Close();$script:UI.Sidebar.Close()
}
Export-ModuleMember -Function *
