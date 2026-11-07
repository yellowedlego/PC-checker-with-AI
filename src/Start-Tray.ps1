<#
  트레이 아이콘 (알림 영역). 눈에 띄지 않게 상주하면서 대시보드 열기, 구간·메모 표시, 기록 켜고 끄기를 돕는다.
  - 왼쪽 클릭: '표시하기' 창 / 오른쪽 클릭: 메뉴
  - 부팅 후 처음 한 번만 작은 알림을 띄운다 (메뉴에서 끌 수 있음)
  - 관리자 권한 불필요, 네트워크 전송 없음
    powershell -STA -File Start-Tray.ps1 [-DataDir <폴더>] [-SelfTest]
  -SelfTest: 화면에 띄우지 않고 메뉴 구성만 만들어 JSON 으로 출력한다 (테스트용)
#>
param([string]$DataDir, [switch]$SelfTest, [string]$AppRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UI.ps1')
if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
if (-not $AppRoot) { $AppRoot = Get-AppRoot }
New-Item -ItemType Directory -Path $AppRoot -Force | Out-Null
$stopFlag = Join-Path $AppRoot 'tray-stop.flag'
$src = $PSScriptRoot

# ---- 중복 실행 방지 (SelfTest 는 건너뜀) ----
$mutex = $null
if (-not $SelfTest) {
  $mutex = New-Object Threading.Mutex($false, ('Local\PCCheckerWithAI.Tray.' + ([regex]::Replace($DataDir.ToLower(), '[^a-z0-9]', ''))))
  if (-not $mutex.WaitOne(0)) { exit 0 }
  Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue
}
[Windows.Forms.Application]::EnableVisualStyles()

# ---- 아이콘: 코드로 그린 동그란 표시 ----
function New-TrayIcon([string]$Hex) {
  $bmp = New-Object Drawing.Bitmap 32, 32; $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $g.FillEllipse((New-Object Drawing.SolidBrush (Ui-Color $Hex)), 2, 2, 28, 28)
  $w = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
  $g.FillRectangle($w, 8, 17, 4, 8); $g.FillRectangle($w, 14, 11, 4, 14); $g.FillRectangle($w, 20, 14, 4, 11)
  $g.Dispose(); $icon = [Drawing.Icon]::FromHandle($bmp.GetHicon()); $icon
}

$ni = New-Object Windows.Forms.NotifyIcon
$ni.Icon = New-TrayIcon '#A9482A'; $ni.Text = 'PC 상태 기록'
$menu = New-Object Windows.Forms.ContextMenuStrip; $menu.Font = Ui-Font 10
$ctx = @{ Panel = $null; Proc = $null }

function Add-Item([string]$Text, [scriptblock]$OnClick, [bool]$Enabled = $true) { $it = New-Object Windows.Forms.ToolStripMenuItem $Text; $it.Enabled = $Enabled; if ($OnClick) { $it.Add_Click($OnClick) }; [void]$menu.Items.Add($it); $it }
function Start-Report([string]$Pack, [string]$Open) {
  if ($ctx.Proc -and -not $ctx.Proc.HasExited) { $ni.ShowBalloonTip(3000, 'PC 상태 기록', '이미 파일을 만드는 중이에요. 잠시만 기다려 주세요.', 'Info'); return }
  $a = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', (Q (Join-Path $src 'Make-Report.ps1')), '-DataDir', (Q $DataDir), '-Pack', $Pack, '-Open', $Open)
  $ctx.Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden -PassThru
  $ni.ShowBalloonTip(4000, 'PC 상태 기록', '파일을 만들고 있어요 (10~40초). 끝나면 자동으로 열려요.', 'Info')
}
function Show-Panel { if (-not $ctx.Panel -or $ctx.Panel.Form.IsDisposed) { $ctx.Panel = New-MarkerPanel $DataDir $src ([bool](Get-Settings $AppRoot).panel_topmost) }; $ctx.Panel.Form.Show(); $ctx.Panel.Form.Activate() }

$null = Add-Item '대시보드 열기' { Start-Report 'full' 'dashboard' }
$null = Add-Item 'AI에 줄 가벼운 파일 만들기' { Start-Report 'light' 'folder' }
[void]$menu.Items.Add('-')
$null = Add-Item '구간·메모 표시하기 창 열기' { Show-Panel }
[void]$menu.Items.Add('-')
$stateItem = Add-Item '기록 상태 확인 중…' $null $false
$toggleItem = Add-Item '기록 끄기' {
  $st = Get-CollectorState $DataDir
  if ($st.status -eq 'running') { New-Item -ItemType File -Path (Join-Path $DataDir 'stop.flag') -Force | Out-Null; $ni.ShowBalloonTip(3000, 'PC 상태 기록', '기록을 멈췄어요. 메뉴에서 다시 켤 수 있어요.', 'Info') }
  else { $a = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', (Q (Join-Path $src 'Start-Collector.ps1')), '-DataDir', (Q $DataDir)); Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden; $ni.ShowBalloonTip(3000, 'PC 상태 기록', '기록을 다시 시작했어요.', 'Info') }
}
$welcomeItem = Add-Item '시작할 때 알림 보이기' {
  $s = Get-Settings $AppRoot; $s.welcome_balloon = -not [bool]$s.welcome_balloon; Save-Settings $s $AppRoot; $welcomeItem.Checked = [bool]$s.welcome_balloon
}
$welcomeItem.Checked = [bool](Get-Settings $AppRoot).welcome_balloon
[void]$menu.Items.Add('-')
$null = Add-Item '이 아이콘만 닫기 (기록은 계속)' { $script:quit = $true; [Windows.Forms.Application]::Exit() }
$null = Add-Item '기록도 끄고 닫기' { New-Item -ItemType File -Path (Join-Path $DataDir 'stop.flag') -Force | Out-Null; $script:quit = $true; [Windows.Forms.Application]::Exit() }
$ni.ContextMenuStrip = $menu
$ni.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-Panel } })

$update = {
  $st = Get-CollectorState $DataDir
  $stateItem.Text = $st.text; $toggleItem.Text = $(if ($st.status -eq 'running') { '기록 끄기' } else { '기록 켜기' })
  $tip = 'PC 상태 기록 · ' + ($st.text -replace '^[●■▲] ', ''); if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }; $ni.Text = $tip
}

if ($SelfTest) {
  & $update
  $panel = New-MarkerPanel $DataDir $src $true
  $res = [ordered]@{ menu_items = @($menu.Items | ForEach-Object { if ($_ -is [Windows.Forms.ToolStripSeparator]) { '---' } else { $_.Text } }); icon_ok = [bool]$ni.Icon; panel_controls = $panel.Form.Controls.Count; tooltip = $ni.Text }
  $panel.Form.Dispose(); $ni.Dispose(); $menu.Dispose()
  $res | ConvertTo-Json -Compress
  return
}

# ---- 실행 ----
$ni.Visible = $true
& $update
$settings = Get-Settings $AppRoot
$bootKey = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s')
if ($settings.welcome_balloon -and $settings.last_welcome_boot -ne $bootKey) {
  $ni.ShowBalloonTip(7000, 'PC 상태 기록', '재부팅 후부터 기록하고 있어요. 이 아이콘을 눌러 구간·메모를 표시하거나 대시보드를 열 수 있어요. 기록은 이 PC 안에만 저장돼요.', 'Info')
  $settings.last_welcome_boot = $bootKey; Save-Settings $settings $AppRoot
}
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 5000
$timer.Add_Tick({
    & $update
    if (Test-Path $stopFlag) { Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue; $script:quit = $true; [Windows.Forms.Application]::Exit() }
    if ($ctx.Proc -and $ctx.Proc.HasExited) { $code = $ctx.Proc.ExitCode; $ctx.Proc = $null; if ($code -ne 0) { $ni.ShowBalloonTip(5000, 'PC 상태 기록', '파일을 만들지 못했어요. 기록이 1분 이상 쌓였는지 확인해 주세요.', 'Warning') } }
  })
$timer.Start()
try { [Windows.Forms.Application]::Run() } finally {
  $timer.Stop(); $ni.Visible = $false; $ni.Dispose(); if ($ctx.Panel -and -not $ctx.Panel.Form.IsDisposed) { $ctx.Panel.Form.Dispose() }
  if ($mutex) { try { $mutex.ReleaseMutex() | Out-Null } catch { } }
}
