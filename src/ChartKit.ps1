# PNG 그래프 그리기 도구 (System.Drawing, 추가 설치 없음). 가벼운 AI용 팩에서 쓴다.
# 원칙: 색만으로 구분하지 않는다 (선 모양 + 줄 끝 직접 라벨 + 무늬 + 숫자), 모든 그림 아래에 '읽는 법' 설명 띠를 붙인다.
Add-Type -AssemblyName System.Drawing

$script:CkW = 1000
$script:FontName = $(if ((New-Object Drawing.Text.InstalledFontCollection).Families | Where-Object { $_.Name -eq 'Malgun Gothic' }) { 'Malgun Gothic' } else { 'Segoe UI' })
$script:Pal = @{ ink = '#2b2926'; muted = '#675f55'; grid = '#e4dfd2'; accent = '#a9482a'; blue = '#2b5c8a'; olive = '#5f7a2e'; gray = '#59534a'; band = '#ddd2f0'; shade = '#f6e5dc'; track = '#efe9db'; h0 = '#efe9db'; h1 = '#e3b768'; h2 = '#b3452c'; nodata = '#e9e4d6' }
function C([string]$k) { [Drawing.ColorTranslator]::FromHtml($script:Pal[$k]) }
function F([double]$px, [bool]$bold = $false) { New-Object Drawing.Font($script:FontName, [single]$px, $(if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }), [Drawing.GraphicsUnit]::Pixel) }
function Br([string]$k) { New-Object Drawing.SolidBrush (C $k) }

function Get-Ramp([double]$t) {
  if ([double]::IsNaN($t)) { return (C 'nodata') }
  $t = [math]::Max(0.0, [math]::Min(1.0, [double]$t))
  $a = C 'h0'; $b = C 'h1'; $c = C 'h2'
  if ($t -lt 0.5) { $u = $t * 2; $p = $a; $q = $b } else { $u = ($t - 0.5) * 2; $p = $b; $q = $c }
  [Drawing.Color]::FromArgb([int]($p.R + ($q.R - $p.R) * $u), [int]($p.G + ($q.G - $p.G) * $u), [int]($p.B + ($q.B - $p.B) * $u))
}

function Get-TextHeight([string]$Text, $Font, [int]$Width) {
  $b = New-Object Drawing.Bitmap 1, 1; $g = [Drawing.Graphics]::FromImage($b)
  $h = [math]::Ceiling($g.MeasureString($Text, $Font, $Width).Height); $g.Dispose(); $b.Dispose(); [int]$h
}

# 캔버스: 그림 영역 높이 + 설명 띠 높이. Caption = @{ title; how; legend }
function New-Canvas([int]$PlotH, $Caption) {
  $tw = $script:CkW - 40
  $fT = F 15 $true; $fB = F 13
  $capH = 14 + (Get-TextHeight $Caption.title $fT $tw) + 4 + (Get-TextHeight $Caption.how $fB $tw) + 4 + (Get-TextHeight $Caption.legend $fB $tw) + 4 + (Get-TextHeight '※ 기준선과 색 단계는 임시 값입니다. 원인을 단정하는 그림이 아닙니다.' $fB $tw) + 12
  $bmp = New-Object Drawing.Bitmap($script:CkW, ($PlotH + $capH))
  $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([Drawing.Color]::White)
  @{ Bmp = $bmp; G = $g; PlotH = $PlotH; CapH = $capH; Caption = $Caption }
}

function Add-Caption($cv) {
  $g = $cv.G; $y = $cv.PlotH; $tw = $script:CkW - 40
  $g.FillRectangle((Br 'track'), 0, $y, $script:CkW, $cv.CapH)
  $g.DrawLine((New-Object Drawing.Pen (C 'grid'), 2), 0, $y, $script:CkW, $y)
  $y += 14
  foreach ($row in @(@($cv.Caption.title, (F 15 $true), 'ink'), @($cv.Caption.how, (F 13), 'ink'), @($cv.Caption.legend, (F 13), 'ink'), @('※ 기준선과 색 단계는 임시 값입니다. 원인을 단정하는 그림이 아닙니다.', (F 13), 'muted'))) {
    $rect = New-Object Drawing.RectangleF(20, $y, $tw, 2000)
    $g.DrawString($row[0], $row[1], (Br $row[2]), $rect)
    $y += (Get-TextHeight $row[0] $row[1] $tw) + 4
  }
}

function Save-Png($cv, [string]$Path) {
  Add-Caption $cv
  $cv.Bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $cv.G.Dispose(); $cv.Bmp.Dispose()
  $img = [Drawing.Image]::FromFile($Path); $r = [ordered]@{ path = $Path; width = $img.Width; height = $img.Height; kb = [math]::Round((Get-Item $Path).Length / 1KB, 0) }; $img.Dispose(); $r
}

function Write-Text($g, [string]$Text, $Font, [string]$Color, [double]$x, [double]$y, [string]$Align = 'Near') {
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = [Drawing.StringAlignment]::$Align; $sf.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
  $g.DrawString($Text, $Font, (Br $Color), [single]$x, [single]$y, $sf)
}

# 시간축: P개 점으로 줄인 뒤 눈금 라벨을 만든다
function Get-Binned([double[]]$a, [int]$P) {
  $n = $a.Count; if ($n -le $P) { return $a }
  $out = New-Object 'double[]' $P
  for ($b = 0; $b -lt $P; $b++) {
    $s = [int][math]::Floor($b * $n / $P); $e = [int][math]::Floor(($b + 1) * $n / $P); if ($e -le $s) { $e = $s + 1 }
    $sum = 0.0; $c = 0; for ($i = $s; $i -lt [math]::Min($e, $n); $i++) { if (-not [double]::IsNaN($a[$i])) { $sum += $a[$i]; $c++ } }
    $out[$b] = $(if ($c) { $sum / $c } else { [double]::NaN })
  }
  $out
}
function Get-TimeAxis($Times, [double[]]$Mins, [int]$P, [int]$K = 6) {
  $n = $Times.Count; $early = ($Mins.Count -gt 0 -and $Mins[0] -lt 180); $ticks = New-Object Collections.Generic.List[object]
  for ($t = 0; $t -le $k; $t++) {
    $bi = [int][math]::Round($t * ($P - 1) / $k); $src = [int][math]::Floor($bi * $n / $P); if ($src -ge $n) { $src = $n - 1 }
    $lab = $(if ($early) { $m = [math]::Round($Mins[$src]); if ($m -lt 60) { "+$m" + '분' } else { '+' + [math]::Floor($m / 60) + 'h' + ($m % 60) + 'm' } } else { ([datetime]$Times[$src]).ToString('MM-dd HH:mm') })
    $ticks.Add(@{ i = $bi; label = $lab })
  }
  @{ P = $P; N = $n; Ticks = $ticks; Map = { param($srcIdx, $nn, $pp) [int][math]::Min($pp - 1, [math]::Floor($srcIdx * $pp / $nn)) } }
}

# 선 그래프. series: @{ name; vals(double[P]); style(0 실선,1 파선,2 점선,3 쇄선); color }
function Draw-Lines($cv, [double]$X, [double]$Y, [double]$W, [double]$H, $Series, $Axis, [double]$YMin, [double]$YMax, [string]$YLabel, $Thresholds, $Bands, $Shades, $Notes) {
  $g = $cv.G; $P = $Axis.P
  $px = { param($i) $X + $W * $i / [math]::Max(1, $P - 1) }; $py = { param($v) $Y + $H - $H * ($v - $YMin) / [math]::Max(1e-9, ($YMax - $YMin)) }
  foreach ($s in $Shades) { $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(120, (C 'shade')))), [single](& $px $s.i0), [single]$Y, [single]((& $px $s.i1) - (& $px $s.i0) + 2), [single]$H) }
  foreach ($b in $Bands) {
    $x0 = & $px $b.i0; $x1 = (& $px $b.i1) + 2
    $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(150, (C 'band')))), [single]$x0, [single]$Y, [single]($x1 - $x0), [single]$H)
    Write-Text $g $b.label (F 12 $true) 'ink' ($x0 + 4) ($Y + 3)
  }
  $penGrid = New-Object Drawing.Pen (C 'grid'), 1
  for ($t = 0; $t -le 5; $t++) {
    $v = $YMin + ($YMax - $YMin) * $t / 5; $yy = & $py $v
    $g.DrawLine($penGrid, [single]$X, [single]$yy, [single]($X + $W), [single]$yy)
    Write-Text $g ([string][math]::Round($v, 0)) (F 12) 'muted' ($X - 6) ($yy - 8) 'Far'
  }
  Write-Text $g $YLabel (F 12) 'muted' ($X - 62) ($Y - 22)
  foreach ($tk in $Axis.Ticks) { $xx = & $px $tk.i; $g.DrawLine($penGrid, [single]$xx, [single]($Y + $H), [single]$xx, [single]($Y + $H + 4)); Write-Text $g $tk.label (F 12) 'muted' $xx ($Y + $H + 6) 'Center' }
  foreach ($th in $Thresholds) {
    if ($th.v -lt $YMin -or $th.v -gt $YMax) { continue }
    $pen = New-Object Drawing.Pen (C 'muted'), 1; $pen.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash; $yy = & $py $th.v
    $g.DrawLine($pen, [single]$X, [single]$yy, [single]($X + $W), [single]$yy); Write-Text $g $th.label (F 11) 'muted' ($X + $W - 4) ($yy - 14) 'Far'
  }
  $g.DrawRectangle((New-Object Drawing.Pen (C 'muted'), 1), [single]$X, [single]$Y, [single]$W, [single]$H)
  $dash = @([Drawing.Drawing2D.DashStyle]::Solid, [Drawing.Drawing2D.DashStyle]::Dash, [Drawing.Drawing2D.DashStyle]::Dot, [Drawing.Drawing2D.DashStyle]::DashDot)
  $labels = New-Object Collections.Generic.List[object]
  foreach ($s in $Series) {
    $pen = New-Object Drawing.Pen (C $s.color), 2.4; $pen.DashStyle = $dash[$s.style]; $run = New-Object Collections.Generic.List[Drawing.PointF]; $last = $null
    for ($i = 0; $i -lt $P; $i++) {
      $v = $s.vals[$i]
      if ([double]::IsNaN($v)) { if ($run.Count -gt 1) { $g.DrawLines($pen, $run.ToArray()) }; $run.Clear(); continue }
      $vv = [math]::Max($YMin, [math]::Min($YMax, $v)); $pt = New-Object Drawing.PointF([single](& $px $i), [single](& $py $vv)); $run.Add($pt); $last = $pt
    }
    if ($run.Count -gt 1) { $g.DrawLines($pen, $run.ToArray()) } elseif ($run.Count -eq 1) { $g.FillEllipse((Br $s.color), $run[0].X - 2, $run[0].Y - 2, 4, 4) }
    if ($last) { $labels.Add(@{ y = $last.Y; text = $s.name; color = $s.color }) }
  }
  # 줄 끝 직접 라벨 (겹치면 위아래로 밀어냄)
  $sorted = @($labels | Sort-Object { $_.y }); $prev = -100
  foreach ($l in $sorted) { $yy = [math]::Max($l.y - 8, $prev + 15); $prev = $yy; Write-Text $g $l.text (F 12 $true) $l.color ($X + $W + 8) $yy }
  foreach ($n in $Notes) { $xx = & $px $n.i; $pts = @((New-Object Drawing.PointF([single]$xx, [single]($Y - 12))), (New-Object Drawing.PointF([single]($xx + 6), [single]($Y - 6))), (New-Object Drawing.PointF([single]$xx, [single]$Y)), (New-Object Drawing.PointF([single]($xx - 6), [single]($Y - 6)))); $g.FillPolygon((Br 'accent'), $pts); Write-Text $g $n.label (F 12 $true) 'accent' ($xx + 9) ($Y - 20) }
}

# 히트맵 행 (대시보드와 같은 색 단계 + 점/빗금 무늬)
function Draw-HeatRows($cv, [double]$X, [double]$Y, [double]$LabelW, [double]$CellW, [double]$RowH, $Rows, [int]$Bins) {
  $g = $cv.G; $yy = $Y
  foreach ($r in $Rows) {
    Write-Text $g $r.label (F 13) 'ink' $X ($yy + 3)
    for ($b = 0; $b -lt $Bins; $b++) {
      $t = $r.ts[$b]; $x0 = $X + $LabelW + $b * $CellW
      $g.FillRectangle((New-Object Drawing.SolidBrush (Get-Ramp $t)), [single]$x0, [single]$yy, [single]($CellW - 0.6), [single]($RowH - 1.5))
      if (-not [double]::IsNaN($t) -and -not $r.relative) {
        if ($t -ge 0.9) { $p = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(170, 40, 30, 20)), 1; $g.DrawLine($p, [single]$x0, [single]($yy + $RowH - 2), [single]($x0 + $CellW - 0.6), [single]$yy) }
        elseif ($t -ge 0.5) { $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(150, 40, 30, 20))), [single]($x0 + $CellW / 2 - 0.8), [single]($yy + $RowH / 2 - 1.5), 1.6, 1.6) }
      }
    }
    $xs = $X + $LabelW + $Bins * $CellW + 10
    Write-Text $g $r.stat (F 12) 'ink' $xs ($yy + 4)
    $yy += $RowH
  }
}

# 기준 대비 막대: 0.5 = 주의 기준, 0.9 = 높음 기준
function Draw-ThresholdBars($cv, [double]$X, [double]$Y, [double]$LabelW, [double]$TrackW, [double]$RowH, $Rows) {
  $g = $cv.G; $yy = $Y; $pen = New-Object Drawing.Pen (C 'muted'), 1; $pen.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash
  $x0 = $X + $LabelW
  Write-Text $g '주의 기준(임시)' (F 11) 'muted' ($x0 + $TrackW * 0.5) ($Y - 20) 'Center'; Write-Text $g '높음 기준(임시)' (F 11) 'muted' ($x0 + $TrackW * 0.9) ($Y - 20) 'Center'
  foreach ($r in $Rows) {
    Write-Text $g $r.label (F 13) 'ink' $X ($yy + 4)
    $g.FillRectangle((Br 'track'), [single]$x0, [single]($yy + 3), [single]$TrackW, [single]($RowH - 8))
    $len = [math]::Max(2.0, $TrackW * [math]::Max(0.0, [math]::Min(1.0, [double]$r.t)))
    $g.FillRectangle((New-Object Drawing.SolidBrush (Get-Ramp $r.t)), [single]$x0, [single]($yy + 3), [single]$len, [single]($RowH - 8))
    $g.DrawRectangle((New-Object Drawing.Pen (C 'muted'), 1), [single]$x0, [single]($yy + 3), [single]$len, [single]($RowH - 8))
    $g.DrawLine($pen, [single]($x0 + $TrackW * 0.5), [single]($yy), [single]($x0 + $TrackW * 0.5), [single]($yy + $RowH - 2)); $g.DrawLine($pen, [single]($x0 + $TrackW * 0.9), [single]($yy), [single]($x0 + $TrackW * 0.9), [single]($yy + $RowH - 2))
    Write-Text $g $r.text (F 12 $true) 'ink' ($x0 + $TrackW + 10) ($yy + 4)
    $yy += $RowH
  }
}

# 구간 변화 막대: 기준선 대비 증감
function Draw-DeltaBars($cv, [double]$X, [double]$Y, [double]$LabelW, [double]$HalfW, [double]$RowH, [string]$Title, $Items) {
  $g = $cv.G; Write-Text $g $Title (F 14 $true) 'ink' $X $Y; $yy = $Y + 26; $mid = $X + $LabelW + $HalfW
  $mx = ($Items | ForEach-Object { [math]::Abs($_.delta) } | Measure-Object -Maximum).Maximum; if (-not $mx -or $mx -eq 0) { $mx = 1 }
  foreach ($it in $Items) {
    Write-Text $g $it.label (F 13) 'ink' $X ($yy + 3)
    $len = $HalfW * [math]::Abs($it.delta) / $mx
    if ($it.delta -ge 0) { $g.FillRectangle((Br 'accent'), [single]$mid, [single]($yy + 3), [single]$len, [single]($RowH - 8)); $txtX = $mid + $len + 6; $arrow = '▲ +' } else { $g.FillRectangle((Br 'olive'), [single]($mid - $len), [single]($yy + 3), [single]$len, [single]($RowH - 8)); $txtX = $mid + 6; $arrow = '▼ ' }
    Write-Text $g ($arrow + $it.deltaText + '  (구간 평균 ' + $it.meanText + ')') (F 12) 'ink' $txtX ($yy + 4)
    $yy += $RowH
  }
  $g.DrawLine((New-Object Drawing.Pen (C 'muted'), 1), [single]$mid, [single]($Y + 22), [single]$mid, [single]$yy)
}
