# 화면 부품 (WinForms, 추가 설치 없음). '표시하기' 패널을 만든다. 이 파일은 불러오기만 하고 아무것도 실행하지 않는다.
# 디자인: 따뜻한 중성 배경, 낮은 채도, 넉넉한 여백, 큰 버튼(높이 38px), 상태는 색이 아니라 기호+글자로.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Common.ps1')

$script:UiFontName = $(if ((New-Object Drawing.Text.InstalledFontCollection).Families | Where-Object { $_.Name -eq 'Malgun Gothic' }) { 'Malgun Gothic' } else { 'Segoe UI' })
function Ui-Color([string]$hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
function Ui-Font([double]$pt, [bool]$bold = $false) { New-Object Drawing.Font($script:UiFontName, [single]$pt, $(if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular })) }
function Q([string]$s) { '"' + $s + '"' }

function New-UiButton([string]$Text, [int]$X, [int]$Y, [int]$W, [bool]$Primary = $false) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $Text; $b.SetBounds($X, $Y, $W, 38); $b.FlatStyle = 'Flat'; $b.Font = Ui-Font 10 $Primary; $b.Cursor = 'Hand'; $b.UseVisualStyleBackColor = $false
  if ($Primary) { $b.BackColor = Ui-Color '#A9482A'; $b.ForeColor = [Drawing.Color]::White; $b.FlatAppearance.BorderColor = Ui-Color '#A9482A' }
  else { $b.BackColor = [Drawing.Color]::White; $b.ForeColor = Ui-Color '#2B2926'; $b.FlatAppearance.BorderColor = Ui-Color '#E4DFD2' }
  $b.FlatAppearance.MouseOverBackColor = $(if ($Primary) { Ui-Color '#92401F' } else { Ui-Color '#F4F1E8' })
  $b
}

# '표시하기' 패널: 구간 시작/끝, 증상 메모, 리포트 만들기. 반환: 컨트롤 모음(테스트에서 PerformClick 으로 눌러 볼 수 있다)
function New-MarkerPanel([string]$DataDir, [string]$SrcDir, [bool]$TopMost = $true) {
  if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
  if (-not $SrcDir) { $SrcDir = $PSScriptRoot }
  $f = New-Object Windows.Forms.Form
  $f.Text = 'PC 상태 기록 · 표시하기'; $f.ClientSize = New-Object Drawing.Size(400, 262); $f.FormBorderStyle = 'FixedToolWindow'
  $f.StartPosition = 'Manual'; $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $f.Location = New-Object Drawing.Point(($wa.Right - 420), ($wa.Bottom - 292))
  $f.BackColor = Ui-Color '#FAF9F5'; $f.ForeColor = Ui-Color '#2B2926'; $f.Font = Ui-Font 10; $f.TopMost = $TopMost; $f.ShowInTaskbar = $true

  $hint = New-Object Windows.Forms.Label; $hint.Text = '지금 무엇을 하고 있나요? (이름만, 개인정보는 쓰지 마세요)'; $hint.SetBounds(16, 12, 370, 22); $hint.ForeColor = Ui-Color '#675F55'; $hint.Font = Ui-Font 9
  $tb = New-Object Windows.Forms.TextBox; $tb.SetBounds(16, 38, 368, 28); $tb.Font = Ui-Font 11; $tb.BorderStyle = 'FixedSingle'; $tb.MaxLength = 80
  $bStart = New-UiButton '구간 시작' 16 78 112 $true; $bEnd = New-UiButton '구간 끝' 136 78 112; $bNote = New-UiButton '증상 메모' 256 78 128
  $status = New-Object Windows.Forms.Label; $status.SetBounds(16, 128, 368, 44); $status.Font = Ui-Font 10; $status.Text = ''
  $bReport = New-UiButton '대시보드 열기' 16 178 180 $true; $bPack = New-UiButton 'AI용 가벼운 파일' 204 178 180
  $chk = New-Object Windows.Forms.CheckBox; $chk.Text = '항상 위에 두기'; $chk.SetBounds(16, 226, 200, 26); $chk.Checked = $TopMost; $chk.Font = Ui-Font 9; $chk.ForeColor = Ui-Color '#675F55'
  $f.Controls.AddRange(@($hint, $tb, $bStart, $bEnd, $bNote, $status, $bReport, $bPack, $chk))

  $ctx = @{ DataDir = $DataDir; SrcDir = $SrcDir; Flash = ''; FlashUntil = [datetime]::MinValue; Proc = $null; Status = $status; TextBox = $tb }
  $refresh = {
    if ($ctx.Proc -and -not $ctx.Proc.HasExited) { $ctx.Status.Text = '… 파일을 만드는 중이에요 (10~40초). 끝나면 자동으로 열려요.'; return }
    if ($ctx.Proc -and $ctx.Proc.HasExited) { $ctx.Flash = $(if ($ctx.Proc.ExitCode -eq 0) { '✓ 만들었어요.' } else { '▲ 만들지 못했어요. 기록이 1분 이상 쌓였는지 확인해 주세요.' }); $ctx.FlashUntil = (Get-Date).AddSeconds(6); $ctx.Proc = $null }
    if ((Get-Date) -lt $ctx.FlashUntil) { $ctx.Status.Text = $ctx.Flash; return }
    $ctx.Status.Text = (Get-CollectorState $ctx.DataDir).text
  }.GetNewClosure()
  $flash = { param([string]$msg) $ctx.Flash = $msg; $ctx.FlashUntil = (Get-Date).AddSeconds(5); $ctx.Status.Text = $msg }.GetNewClosure()
  $need = { if (-not $ctx.TextBox.Text.Trim()) { & $flash '▲ 위 칸에 이름을 한 줄 적어 주세요.'; $ctx.TextBox.Focus() | Out-Null; $false } else { $true } }.GetNewClosure()

  $bStart.Add_Click({ if (& $need) { $l = $ctx.TextBox.Text.Trim(); Send-Marker 'start' $l $ctx.DataDir | Out-Null; & $flash "✓ 구간을 시작했어요: $l" } }.GetNewClosure())
  $bEnd.Add_Click({ Send-Marker 'end' '' $ctx.DataDir | Out-Null; & $flash '✓ 구간을 끝냈어요.' }.GetNewClosure())
  $bNote.Add_Click({ if (& $need) { $l = $ctx.TextBox.Text.Trim(); Send-Marker 'note' $l $ctx.DataDir | Out-Null; & $flash "✓ 메모를 남겼어요 (이후 5분 촘촘히 기록): $l" } }.GetNewClosure())
  $startReport = { param([string]$pack, [string]$open) $args2 = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', (Q (Join-Path $ctx.SrcDir 'Make-Report.ps1')), '-DataDir', (Q $ctx.DataDir), '-Pack', $pack, '-Open', $open); $ctx.Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args2 -WindowStyle Hidden -PassThru; & $refresh }.GetNewClosure()
  $bReport.Add_Click({ if (-not $ctx.Proc) { & $startReport 'full' 'dashboard' } }.GetNewClosure())
  $bPack.Add_Click({ if (-not $ctx.Proc) { & $startReport 'light' 'folder' } }.GetNewClosure())
  $chk.Add_CheckedChanged({ $f.TopMost = $chk.Checked }.GetNewClosure())

  $timer = New-Object Windows.Forms.Timer; $timer.Interval = 2000; $timer.Add_Tick($refresh); $f.Add_Shown({ & $refresh; $timer.Start() }.GetNewClosure()); $f.Add_FormClosed({ $timer.Stop(); $timer.Dispose() }.GetNewClosure())
  & $refresh
  @{ Form = $f; TextBox = $tb; BtnStart = $bStart; BtnEnd = $bEnd; BtnNote = $bNote; BtnReport = $bReport; BtnPack = $bPack; CheckTop = $chk; Status = $status; Refresh = $refresh; Context = $ctx }
}
