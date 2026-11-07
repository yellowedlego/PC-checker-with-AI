<#
  PC-checker-with-AI 가벼운 AI용 팩 (4단계)
  큰 CSV를 못 읽거나 긴 글을 소화하기 어려운 AI를 위해, 같은 데이터를 작게 줄여 만든다. 읽기 전용, 네트워크 전송 없음.

    powershell -ExecutionPolicy Bypass -File .\src\Build-LightPack.ps1 [-ExportDir <폴더>] [-OutDir <폴더>]

  출력(OutDir, 기본 <ExportDir>\light):
    summary.md        약 4KB 이내. 핵심 수치/발견/원인 후보 + 이모지 칸으로 그린 '글자 히트맵'(이미지를 못 보는 AI용)
    chart_*.png       코드로 그린 그래프 4~6장. 폭 1000px 이하, 장당 300KB 이하, 각 그림 아래에 읽는 법 설명 띠
    charts_guide.md   각 그래프가 무엇이고 어떻게 읽는지

  원칙: 모든 기준값은 '임시'이고 도구는 원인을 단정하지 않는다. 판단은 AI/사용자가 한다.
#>
param(
  [string]$ExportDir,
  [string]$DataDir,
  [string]$OutDir,
  [int]$MaxSummaryBytes = 4600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'MetricCatalog.ps1')
. (Join-Path $PSScriptRoot 'ChartKit.ps1')
$inv = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding $false
if (-not $DataDir) { $DataDir = Get-DefaultDataDir }
if (-not $ExportDir) {
  $latest = Get-ChildItem (Join-Path $DataDir 'export') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) { throw "내보낸 파일이 없습니다. 먼저 Export-Data.ps1 을 실행하세요. ($DataDir\export)" }
  $ExportDir = $latest.FullName
}
if (-not $OutDir) { $OutDir = Join-Path $ExportDir 'light' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Get-ChildItem $OutDir -Include 'chart_*.png', 'summary.md', 'charts_guide.md' -File -ErrorAction SilentlyContinue | Remove-Item -Force

$sum = [IO.File]::ReadAllText((Join-Path $ExportDir 'summary.json'), $utf8) | ConvertFrom-Json
$rows = @(Import-Csv (Join-Path $ExportDir 'metrics_1min.csv') -Encoding UTF8)
$N = $rows.Count; if ($N -lt 2) { throw '기록이 너무 적습니다 (2분 이상 필요).' }
$times = @($rows | ForEach-Object { $_.time }); $mins = [double[]]@($rows | ForEach-Object { [double]::Parse($_.min_since_boot, $inv) })
$colNames = @($rows[0].PSObject.Properties.Name)

function Get-Col([string]$key) {
  if ($colNames -notcontains $key) { return $null }
  $a = New-Object 'double[]' $N; $d = 0.0
  for ($i = 0; $i -lt $N; $i++) { $s = $rows[$i].$key; if ($s -ne '' -and [double]::TryParse($s, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $a[$i] = $d } else { $a[$i] = [double]::NaN } }
  if (@($a | Where-Object { -not [double]::IsNaN($_) }).Count -lt 2) { return $null }
  , $a
}
function Get-Met([string]$key) { $p = $sum.metrics.PSObject.Properties[$key]; if ($p) { $p.Value } else { $null } }
function Info([string]$key) { Get-MetricInfo $key }
function Fmt($v) { if ($null -eq $v -or ($v -is [double] -and [double]::IsNaN($v))) { '-' } else { $a = [math]::Abs([double]$v); if ($a -ge 1000) { ([double]$v).ToString('N0', $inv) } elseif ($a -ge 100) { ([double]$v).ToString('0', $inv) } elseif ($a -ge 10) { ([double]$v).ToString('0.#', $inv) } else { ([double]$v).ToString('0.##', $inv) } } }
function Unit([string]$key) { $u = (Info $key).unit; if ($u.Length -le 4) { $u } else { '' } }
function ReadingShort($r) { if (-not $r) { return '' }; if ($r -match '높음|낮음') { '높음(임시)' } elseif ($r -match '주의') { '주의(임시)' } elseif ($r -match '정상') { '정상(임시)' } elseif ($r -match '측정값 없음') { '값없음' } else { '기준없음' } }
function KeyFirst([string]$pattern) { $colNames | Where-Object { $_ -match $pattern -and $_ -notlike '*__max' } | Select-Object -First 1 }

# ---------- 구간/메모 위치 ----------
$segs = @(); $notes = @()
foreach ($s in @($sum.segments)) { if ($s.label) { $a = [datetime]$s.start; $b = [datetime]$s.end; $i0 = -1; $i1 = -1; for ($i = 0; $i -lt $N; $i++) { $t = [datetime]$times[$i]; if ($t -ge $a.AddMinutes(-1) -and $i0 -lt 0) { $i0 = $i }; if ($t -le $b) { $i1 = $i } }; if ($i0 -ge 0 -and $i1 -ge $i0) { $segs += @{ label = [string]$s.label; i0 = $i0; i1 = $i1; src = $s } } } }
foreach ($nt in @($sum.notes)) { if ($nt.label) { $a = [datetime]$nt.time; $best = 0; for ($i = 0; $i -lt $N; $i++) { if ([datetime]$times[$i] -le $a) { $best = $i } }; $notes += @{ label = [string]$nt.label; i = $best; src = $nt } } }
function ToBin([int]$src, [int]$P) { [int][math]::Min($P - 1, [math]::Floor($src * $P / $N)) }

# ---------- 핵심 줄 선택 (그림 1과 글자 히트맵이 같은 줄을 쓴다) ----------
$prio = @('^cpu\.util$', '^cpu\.core_max$', '^mem\.commit_pct$', '^mem\.avail_mb$', '^disk\..*\.busy$', '^disk\..*\.latency_ms$', '^gpu\.engine\.3D$', '^gpu\.engine\.VideoDecode$', '^nv\.gpu0\.temp_c$', '^nv\.gpu0\.util$', '^nv\.gpu0\.fan_pct$', '^nv\.gpu0\.sm_mhz$', '^hw\.temp_c\.', '^fan_group\.case\.mean_pct$', '^fan_group\.cpu\.mean_pct$', '^cpu\.dpc$', '^mem\.pages_per_sec$')
$keys = New-Object Collections.Generic.List[string]
foreach ($h in @($sum.highlights_over_provisional_thresholds)) { if ($h.metric -and $colNames -contains $h.metric -and -not $keys.Contains($h.metric)) { $keys.Add($h.metric) } }
foreach ($p in $prio) { foreach ($c in ($colNames | Where-Object { $_ -match $p -and $_ -notlike '*__max' })) { if (-not $keys.Contains($c) -and $null -ne (Get-Col $c)) { $keys.Add($c) } } }
$keys = [Collections.Generic.List[string]]@($keys | Select-Object -First 14)

function Get-RowModel([string]$key, [int]$Bins) {
  $col = Get-Col $key; if ($null -eq $col) { return $null }
  if ($Bins -gt $N) { $Bins = $N }   # 기록이 칸 수보다 짧으면 칸 수를 줄인다 (없는 칸을 0으로 읽지 않도록)
  $vals = Get-Binned $col $Bins; $info = Info $key; $fin = @($vals | Where-Object { -not [double]::IsNaN($_) })
  $mn = ($fin | Measure-Object -Minimum).Minimum; $mx = ($fin | Measure-Object -Maximum).Maximum
  $relative = ($null -eq $info.warn -and -not ($info.unit -eq '%' -and $info.scale -eq 'absolute'))
  $ts = New-Object 'double[]' $Bins
  for ($b = 0; $b -lt $Bins; $b++) {
    $v = $vals[$b]
    if ([double]::IsNaN($v)) { $ts[$b] = [double]::NaN }
    elseif ($relative) { $ts[$b] = $(if ($mx -gt $mn) { ($v - $mn) / ($mx - $mn) } else { 0 }) }
    else { $ts[$b] = Get-AbsT $info $v }
  }
  $m = Get-Met $key
  @{ key = $key; label = (Get-MetricLabel $key); vals = $vals; ts = $ts; relative = $relative; metric = $m; info = $info }
}
function StatText($r) { $m = $r.metric; if ($null -eq $m) { return '' }; $u = Unit $r.key; $rd = $(if ($r.relative) { '상대색' } else { ReadingShort $m.reading_by_p95 }); "평균 $(Fmt $m.mean)$u / 최고 $(Fmt $m.max_peak_in_any_minute)$u  $rd" }

$results = New-Object Collections.Generic.List[object]
$sumNote = '그래프 파일'

# =====================================================================
# 그림 1: 한눈에 보는 히트맵
# =====================================================================
$B1 = [math]::Min(96, $N); $rm1 = @($keys | ForEach-Object { Get-RowModel $_ $B1 } | Where-Object { $_ })
$rowH = 22; $labW = 190; $cw = [math]::Max(3, [math]::Floor(470 / $B1)); $top = 72
foreach ($r in $rm1) { $r.stat = StatText $r }
$plotH = $top + $rm1.Count * $rowH + 40
$cap = @{ title = '그림 1. 한눈에 보는 히트맵 (가로=시간, 세로=부품)'; how = '진한 칸일수록 값이 큰 순간입니다. 점(·) 무늬는 주의 기준, 빗금(/) 무늬는 높음 기준을 넘은 칸이에요(임시 기준). 줄 끝의 숫자는 그 줄의 평균·최고 값입니다. 맨 위 보라색 띠는 내가 표시한 구간, ◆는 증상 메모예요.'; legend = '색: 연한 베이지(낮음) → 노랑 → 진한 주황·적갈색(높음). "상대색"으로 표시된 줄은 그 줄의 최소~최대를 기준으로 칠한 것이라 진하다고 위험하다는 뜻이 아닙니다. 회색 칸은 값 없음.' }
$cv = New-Canvas $plotH $cap; $g = $cv.G
Write-Text $g '내 PC 상태 한눈에 보기' (F 20 $true) 'ink' 20 10
# 구간·메모 띠 (히트맵 위, 칸에 가려지지 않도록 별도 줄)
Write-Text $g '내가 표시한 구간·메모' (F 12) 'muted' 20 48
$g.FillRectangle((Br 'track'), [single](20 + $labW), 46, [single]($B1 * $cw), 18)
foreach ($s in $segs) { $sb0 = ToBin $s.i0 $B1; $sb1 = ToBin $s.i1 $B1; $sw = ($sb1 - $sb0 + 1) * $cw; $g.FillRectangle((Br 'band'), [single](20 + $labW + $sb0 * $cw), 46, [single]$sw, 18); Write-Text $g $s.label (F 11 $true) 'ink' (20 + $labW + $sb0 * $cw + 3) 48 }
foreach ($nt in $notes) { $nb = ToBin $nt.i $B1; $xx = 20 + $labW + $nb * $cw + $cw / 2; $pts = @((New-Object Drawing.PointF([single]$xx, 46)), (New-Object Drawing.PointF([single]($xx + 7), 55)), (New-Object Drawing.PointF([single]$xx, 64)), (New-Object Drawing.PointF([single]($xx - 7), 55))); $g.FillPolygon((Br 'accent'), $pts); Write-Text $g $nt.label (F 11 $true) 'accent' ($xx + 10) 48 }
Draw-HeatRows $cv 20 $top $labW $cw $rowH $rm1 $B1
$ax = Get-TimeAxis $times $mins $B1 4; $yb = $top + $rm1.Count * $rowH + 4
foreach ($tk in $ax.Ticks) { Write-Text $g $tk.label (F 11) 'muted' (20 + $labW + $tk.i * $cw + $cw / 2) $yb 'Center' }
$results.Add(@{ name = 'chart_1_heatmap.png'; r = (Save-Png $cv (Join-Path $OutDir 'chart_1_heatmap.png')); desc = '한눈에 보는 히트맵' })

# =====================================================================
# 그림 2: 임시 기준 대비 위치 (막대)
# =====================================================================
$bars = @()
foreach ($p in $sum.metrics.PSObject.Properties) {
  $m = $p.Value; if ($p.Name -match '^cpu\.core\.\d' -or $null -eq $m.provisional_thresholds -or $null -eq $m.p95) { continue }
  $low = ($m.provisional_thresholds.direction -eq 'low'); $bv = $(if ($low -and $null -ne $m.p5) { $m.p5 } else { $m.p95 })
  $t = Get-AbsT (Info $p.Name) ([double]$bv); if ($null -eq $t) { continue }
  $bars += [pscustomobject]@{ label = (Get-MetricLabel $p.Name); t = $t; text = ($(if ($low) { '하위5%' } else { '상위5%' }) + " $(Fmt $bv)$(Unit $p.Name) · " + (ReadingShort $m.reading_by_p95)) }
}
$bars = @($bars | Sort-Object t -Descending | Select-Object -First 12)
if ($bars.Count -ge 2) {
  $rh = 28; $plotH = 74 + $bars.Count * $rh + 16
  $cap = @{ title = '그림 2. 임시 기준에 얼마나 가까운가 (나쁜 쪽 5% 값 기준)'; how = '막대가 길수록 임시 기준에 가깝거나 넘은 것입니다. 왼쪽 점선(50%)이 "주의" 기준, 오른쪽 점선(90%)이 "높음" 기준이에요. 값은 1분 평균 중 나쁜 쪽 5%입니다(높을수록 나쁜 지표는 상위 5%, 남은 메모리처럼 낮을수록 나쁜 지표는 하위 5%). 아주 짧은 급등은 반영이 약해요.'; legend = '막대 색은 히트맵과 같은 색 단계(연한 베이지 → 진한 적갈색)이고, 막대 옆 글자가 정확한 값과 임시 판정(정상/주의/높음)입니다.' }
  $cv = New-Canvas $plotH $cap
  Write-Text $cv.G '임시 기준 대비 위치' (F 20 $true) 'ink' 20 12
  Draw-ThresholdBars $cv 20 76 270 400 $rh $bars
  $results.Add(@{ name = 'chart_2_vs_thresholds.png'; r = (Save-Png $cv (Join-Path $OutDir 'chart_2_vs_thresholds.png')); desc = '임시 기준 대비 위치' })
}

# =====================================================================
# 시계열 공통
# =====================================================================
$P = [math]::Min(480, $N); $axis = Get-TimeAxis $times $mins $P
$bands = @($segs | ForEach-Object { @{ i0 = (ToBin $_.i0 $P); i1 = (ToBin $_.i1 $P); label = $_.label } })
$noteMarks = @($notes | ForEach-Object { @{ i = (ToBin $_.i $P); label = $_.label } })
function Mk-Series([string]$key, [string]$name, [int]$style, [string]$color) { $c = Get-Col $key; if ($null -eq $c) { return $null }; @{ name = $name; vals = (Get-Binned $c $P); style = $style; color = $color; key = $key } }
function YMaxFor($series, [double]$floor) { $mx = $floor; foreach ($s in $series) { foreach ($v in $s.vals) { if (-not [double]::IsNaN($v) -and $v -gt $mx) { $mx = $v } } }; $(if ($floor -eq 100 -and $mx -le 100) { 100 } else { [math]::Ceiling($mx * 1.05 / 10) * 10 }) }

# ---------- 그림 3: 온도와 팬 ----------
$tempKeys = @((KeyFirst '^nv\.gpu0\.temp_c$'), (KeyFirst '^hw\.temp_c\.(?i:.*(cpu|core|package|tctl|tdie).*)$')) | Where-Object { $_ }
$ts3 = @()
$k = KeyFirst '^nv\.gpu0\.temp_c$'; if ($k) { $ts3 += Mk-Series $k 'GPU 온도(°C)' 0 'accent' }
$k = KeyFirst '^hw\.temp_c\.(?i:.*(cpu|core|package|tctl|tdie).*)$'; if ($k) { $ts3 += Mk-Series $k 'CPU 온도(°C)' 1 'blue' }
$k = KeyFirst '^fan_group\.case\.mean_pct$'; if ($k) { $ts3 += Mk-Series $k '케이스 팬(%)' 2 'olive' }
$k = KeyFirst '^fan_group\.cpu\.mean_pct$'; if ($k) { $ts3 += Mk-Series $k 'CPU 팬(%)' 3 'gray' }
if (-not (KeyFirst '^fan_group\.(case|cpu)\.mean_pct$')) { $k = KeyFirst '^nv\.gpu0\.fan_pct$'; if ($k) { $ts3 += Mk-Series $k 'GPU 팬(%)' 2 'olive' } }
$ts3 = @($ts3 | Where-Object { $_ })
if (@($ts3 | Where-Object { $_.name -match '온도' }).Count -ge 1 -and $ts3.Count -ge 2) {
  # 온도는 낮은데 팬은 높은 구간 (summary.json 의 온도-팬 쌍과 같은 정의)
  $shades = @(); $pair = @($sum.thermal_fan_analysis | Where-Object { $null -ne $_.fan_high_while_temp_low_minutes -and $_.fan_high_while_temp_low_minutes -gt 0 }) | Select-Object -First 1
  if ($pair) {
    $tv = Get-Binned (Get-Col $pair.temperature) $P; $fv = Get-Binned (Get-Col $pair.fan) $P
    $tf = @($tv | Where-Object { -not [double]::IsNaN($_) }); $ff = @($fv | Where-Object { -not [double]::IsNaN($_) })
    $tmin = ($tf | Measure-Object -Minimum).Minimum; $tmax = ($tf | Measure-Object -Maximum).Maximum; $fmin = ($ff | Measure-Object -Minimum).Minimum; $fmax = ($ff | Measure-Object -Maximum).Maximum
    $lowT = $tmin + 0.35 * ($tmax - $tmin); $highF = $fmin + 0.6 * ($fmax - $fmin); $start = -1
    for ($i = 0; $i -le $P; $i++) { $on = ($i -lt $P -and -not [double]::IsNaN($tv[$i]) -and -not [double]::IsNaN($fv[$i]) -and $tv[$i] -le $lowT -and $fv[$i] -ge $highF); if ($on -and $start -lt 0) { $start = $i } elseif (-not $on -and $start -ge 0) { $shades += @{ i0 = $start; i1 = ($i - 1) }; $start = -1 } }
  }
  $ym = YMaxFor $ts3 100; $plotH = 400
  $cap = @{ title = '그림 3. 온도와 팬 속도'; how = '실선·파선은 온도(°C), 점선·쇄선은 팬 속도(최대 대비 %)이고 같은 눈금(0~' + $ym + ')을 씁니다. 줄 끝에 이름이 적혀 있어요. 온도가 내려갔는데 팬이 높게 남아 있는지 두 선을 비교해 보세요.'; legend = '주황 음영 = 온도는 그 PC의 낮은 편(하위 35%)인데 팬은 높은 편(상위 40%)인 구간. 보라 띠 = 내가 표시한 구간, ◆ = 증상 메모. 팬이 0%인 것은 저온에서 멈추는 정상 동작일 수 있습니다.' }
  $cv = New-Canvas $plotH $cap; Write-Text $cv.G '온도와 팬 속도' (F 20 $true) 'ink' 20 10
  Draw-Lines $cv 70 64 780 270 $ts3 $axis 0 $ym '°C 또는 %' @(@{ v = 80; label = '주의(임시) 80' }) $bands $shades $noteMarks
  $results.Add(@{ name = 'chart_3_thermal_fan.png'; r = (Save-Png $cv (Join-Path $OutDir 'chart_3_thermal_fan.png')); desc = '온도와 팬 속도' })
}

# ---------- 그림 4: CPU/GPU 부하 ----------
$ts4 = @(); $k = KeyFirst '^cpu\.util$'; if ($k) { $ts4 += Mk-Series $k 'CPU 사용률(%)' 0 'accent' }
$k = KeyFirst '^nv\.gpu0\.util$'; if (-not $k) { $k = KeyFirst '^gpu\.engine\.3D$' }; if ($k) { $ts4 += Mk-Series $k 'GPU 사용률(%)' 1 'blue' }
$k = KeyFirst '^gpu\.engine\.VideoDecode$'; if ($k) { $ts4 += Mk-Series $k '영상 디코드(%)' 2 'olive' }
$k = KeyFirst '^cpu\.core_max$'; if ($k) { $ts4 += Mk-Series $k '가장 바쁜 코어(%)' 3 'gray' }
$ts4 = @($ts4 | Where-Object { $_ })
if ($ts4.Count -ge 2) {
  $ym = YMaxFor $ts4 100
  $cap = @{ title = '그림 4. CPU와 GPU가 얼마나 바빴나'; how = '세로는 사용률(%)입니다. CPU가 높을 때 GPU는 어떤지, 영상 재생 구간에서 "영상 디코드"가 올라가는지 비교해 보세요. 영상이 끊기는데 디코드가 0 근처라면 그래픽 가속을 못 쓰고 있을 수 있어요(가능성일 뿐).'; legend = '실선=CPU 사용률, 파선=GPU 사용률, 점선=영상 디코드, 쇄선=가장 바쁜 코어. 점선 가로선은 CPU "주의" 임시 기준(80%). 보라 띠 = 내가 표시한 구간, ◆ = 증상 메모.' }
  $cv = New-Canvas 360 $cap; Write-Text $cv.G 'CPU·GPU 사용률' (F 20 $true) 'ink' 20 10
  Draw-Lines $cv 70 64 780 240 $ts4 $axis 0 $ym '%' @(@{ v = 80; label = '주의(임시) 80' }) $bands @() $noteMarks
  $results.Add(@{ name = 'chart_4_cpu_gpu.png'; r = (Save-Png $cv (Join-Path $OutDir 'chart_4_cpu_gpu.png')); desc = 'CPU·GPU 사용률' })
}

# ---------- 그림 5: 메모리와 디스크 ----------
$kc = KeyFirst '^mem\.commit_pct$'; $kb = KeyFirst '^disk\..*\.busy$'; $ka = KeyFirst '^mem\.avail_mb$'; $kl = KeyFirst '^disk\..*\.latency_ms$'
if ($kc -or $kb -or $ka -or $kl) {
  $cap = @{ title = '그림 5. 메모리와 디스크'; how = '위: 메모리 약속량(커밋, %)과 디스크 사용 시간(%). 중간: 남은 메모리(GB). 아래: 디스크 응답 시간(ms). 약속량이 계속 높거나 남은 메모리가 줄면 메모리가 빠듯하다는 뜻이고, 응답 시간이 길면 디스크가 느린 것입니다.'; legend = '실선=약속량·남은 메모리·응답 시간, 파선=디스크 사용 시간. 가로 점선은 임시 기준(커밋 80%, 남은 메모리 2GB, 응답 20ms). 보라 띠 = 내가 표시한 구간, ◆ = 증상 메모.' }
  $cv = New-Canvas 560 $cap; Write-Text $cv.G '메모리와 디스크' (F 20 $true) 'ink' 20 10
  $ta = @(); if ($kc) { $ta += Mk-Series $kc '커밋(%)' 0 'accent' }; if ($kb) { $ta += Mk-Series $kb '디스크 사용(%)' 1 'blue' }; $ta = @($ta | Where-Object { $_ })
  if ($ta.Count) { Draw-Lines $cv 70 56 780 120 $ta $axis 0 (YMaxFor $ta 100) '%' @(@{ v = 80; label = '커밋 주의(임시) 80' }) $bands @() $noteMarks }
  if ($ka) { $s = Mk-Series $ka '남은 메모리(GB)' 0 'olive'; $s.vals = @($s.vals | ForEach-Object { if ([double]::IsNaN($_)) { $_ } else { $_ / 1024 } }); Draw-Lines $cv 70 214 780 100 @($s) $axis 0 ([math]::Max(4, [math]::Ceiling((($s.vals | Where-Object { -not [double]::IsNaN($_) } | Measure-Object -Maximum).Maximum) * 1.1))) 'GB' @(@{ v = 2; label = '주의(임시) 2GB' }) $bands @() @() }
  if ($kl) { $s = Mk-Series $kl '응답 시간(ms)' 0 'accent'; Draw-Lines $cv 70 366 780 100 @($s) $axis 0 ([math]::Max(25, (YMaxFor @($s) 25))) 'ms' @(@{ v = 20; label = '주의(임시) 20ms' }) $bands @() @() }
  $results.Add(@{ name = 'chart_5_memory_disk.png'; r = (Save-Png $cv (Join-Path $OutDir 'chart_5_memory_disk.png')); desc = '메모리와 디스크' })
}

# ---------- 그림 6: 구간·메모 전후 변화 ----------
$SEGKEYS = @('cpu.util', 'gpu.engine.3D', 'gpu.engine.VideoDecode', 'nv.gpu0.temp_c', 'nv.gpu0.util', 'mem.commit_pct', 'proc.top_cpu_core_pct')
$groups = @()
foreach ($s in $segs) { $st = $s.src.stats; if ($st -and $st.metrics) { $items = @(); foreach ($kk in $SEGKEYS) { $mp = $st.metrics.PSObject.Properties[$kk]; if ($mp -and $null -ne $mp.Value.delta_vs_baseline) { $items += [pscustomobject]@{ label = (Get-MetricLabel $kk); delta = [double]$mp.Value.delta_vs_baseline; deltaText = (Fmt $mp.Value.delta_vs_baseline); meanText = (Fmt $mp.Value.mean) } } }; if ($items.Count) { $groups += @{ title = ('구간 "' + $s.label + '" — 기준선과 비교'); items = $items } } } }
foreach ($nt in $notes) { $b = $nt.src.five_min_before; $a = $nt.src.five_min_after; if ($b -and $b.metrics -and $a -and $a.metrics) { $items = @(); foreach ($kk in $SEGKEYS) { $pb = $b.metrics.PSObject.Properties[$kk]; $pa = $a.metrics.PSObject.Properties[$kk]; if ($pb -and $pa) { $d = [double]$pa.Value.mean - [double]$pb.Value.mean; $items += [pscustomobject]@{ label = (Get-MetricLabel $kk); delta = $d; deltaText = (Fmt $d); meanText = (Fmt $pa.Value.mean) } } }; if ($items.Count) { $groups += @{ title = ('메모 "' + $nt.label + '" — 직후 5분 vs 직전 5분'); items = $items } } } }
$groups = @($groups | Select-Object -First 3)
if ($groups.Count) {
  $rh = 26; $plotH = 24; foreach ($gr in $groups) { $plotH += 40 + $gr.items.Count * $rh }
  $cap = @{ title = '그림 6. 내가 표시한 구간·메모 전후의 변화'; how = '각 묶음은 "표시한 구간의 평균"이 "기준선(구간 밖 평소)"보다 얼마나 높았는지(▲ 주황, 오른쪽) 낮았는지(▼ 초록, 왼쪽) 보여줍니다. 메모는 메모 직전 5분과 직후 5분을 비교해요. 숫자는 증감량, 괄호는 그때의 평균입니다.'; legend = '▲/▼는 기준선보다 높거나 낮았다는 뜻일 뿐 좋고 나쁨이 아닙니다. 기준선은 평소 구간의 평균이라 평소 값이 흔들리면 증감도 흔들려요. 이 비교는 원본 기록(24시간 보관)을 쓰므로 시간이 지나면 만들 수 없습니다.' }
  $cv = New-Canvas $plotH $cap; $yy = 16
  foreach ($gr in $groups) { Draw-DeltaBars $cv 20 $yy 230 230 $rh $gr.title $gr.items; $yy += 40 + $gr.items.Count * $rh }
  $results.Add(@{ name = 'chart_6_segments.png'; r = (Save-Png $cv (Join-Path $OutDir 'chart_6_segments.png')); desc = '구간·메모 전후 변화' })
}

# =====================================================================
# 글자 히트맵 + summary.md
# =====================================================================
$sq = @{ w = [char]::ConvertFromUtf32(0x2B1C); g = [char]::ConvertFromUtf32(0x1F7E9); y = [char]::ConvertFromUtf32(0x1F7E8); o = [char]::ConvertFromUtf32(0x1F7E7); r = [char]::ConvertFromUtf32(0x1F7E5); n = [char]::ConvertFromUtf32(0x2B1B) }
function Cell([double]$t) { if ([double]::IsNaN($t)) { $sq.n } elseif ($t -lt 0.25) { $sq.w } elseif ($t -lt 0.5) { $sq.g } elseif ($t -lt 0.7) { $sq.y } elseif ($t -lt 0.9) { $sq.o } else { $sq.r } }

function Build-Summary([int]$MaxItems, [int]$MaxRows, [int]$TextCols) {
  if ($TextCols -gt $N) { $TextCols = $N }
  $L = New-Object Collections.Generic.List[string]
  $L.Add('# PC 상태 요약 (가벼운 AI용)')
  $L.Add('> 모든 기준값은 **임시 값**이라 이 PC의 정상 범위와 다를 수 있고, 이 요약은 원인을 단정하지 않습니다. "정상/주의/높음"은 일반적인 기준으로 읽는 순서를 돕는 표시일 뿐이에요. 판단은 AI와 사용자가 합니다.')
  $L.Add('')
  $cpuName = $sum.hardware.cpu.name; $gp = @($sum.hardware.gpus | ForEach-Object { $_.name }) -join ', '
  $L.Add("- 부팅 $($sum.boot.boot_time) / 기록 ${N}분 ($($sum.boot.window_start) ~ $($sum.boot.window_end))")
  $L.Add("- 하드웨어: $cpuName, RAM $($sum.hardware.ram_gb)GB" + $(if ($gp) { ", $gp" } else { '' }))
  $src = $sum.data_quality.sources_available; if ($src) { $miss = @($src.PSObject.Properties | Where-Object { $_.Value -eq $false } | ForEach-Object { $_.Name }); if ($miss) { $L.Add("- 측정 안 된 것: $($miss -join ', ') (값이 없다는 뜻이지 정상이라는 뜻이 아님)") } }
  $L.Add('')
  $L.Add('## 임시 기준을 넘은 지표 (1차 해석, 임시)')
  $hi = @($sum.highlights_over_provisional_thresholds | Select-Object -First $MaxItems)
  if ($hi.Count) { foreach ($h in $hi) { $i = Info $h.metric; $th = $(if ($null -ne $i.warn) { "주의$(if ($i.direction -eq 'low') { '≤' } else { '≥' })$($i.warn)/높음$(if ($i.direction -eq 'low') { '≤' } else { '≥' })$($i.hot)" } else { '' }); $L.Add("- $(Get-MetricLabel $h.metric): 상위5% $(Fmt $h.p95)$($h.unit), 기준 초과 $($h.minutes_over_warn)분 [임시 $th] → $(ReadingShort $h.reading)") } } else { $L.Add('- 없음') }
  $L.Add('')
  $L.Add('## 원인 후보 (결론 아님: supports=관측됨 / against=기준 미만 / no_data=측정 안 됨)')
  $sup = @($sum.hypotheses | Where-Object { $_.evidence -eq 'supports' } | Select-Object -First $MaxItems)
  foreach ($h in $sup) { $d = [string]$h.detail; if ($d.Length -gt 90) { $d = $d.Substring(0, 90) + '…' }; $L.Add("- [supports] $($h.hypothesis) — $d") }
  $ag = @($sum.hypotheses | Where-Object { $_.evidence -eq 'against' }).Count; $nd = @($sum.hypotheses | Where-Object { $_.evidence -eq 'no_data' } | ForEach-Object { $_.id })
  $L.Add("- against ${ag}개 / no_data $($nd.Count)개" + $(if ($nd.Count) { " ($($nd -join ','))" } else { '' }))
  # 가장 눈에 띄는 온도-팬 쌍: 분석 가능한 것 중 '온도는 낮은데 팬은 높은 시간'이 가장 긴 것 (없으면 첫 번째)
  $th = @($sum.thermal_fan_analysis | Where-Object { -not $_.note } | Sort-Object { [double]$_.fan_high_while_temp_low_minutes } -Descending | Select-Object -First 1); if (-not $th.Count) { $th = @($sum.thermal_fan_analysis | Select-Object -First 1) }
  if ($th.Count -and $th[0].temperature) { $t0 = $th[0]; $L.Add(''); $L.Add('## 온도·팬'); if ($t0.note) { $L.Add("- $($t0.temperature) vs $($t0.fan_label): $($t0.note)") } else { $L.Add("- $($t0.temperature) 최고 $($t0.temp_max)°C, 10도 식는 데 $(Fmt $t0.cooldown_10c_minutes)분, 온도는 낮은데 팬은 높은 시간 $($t0.fan_high_while_temp_low_minutes)분, 팬이 온도를 $($t0.fan_follows_temp_with_lag_minutes)분 늦게 따라감(r=$($t0.correlation_at_that_lag))") } }
  if ($segs.Count -or $notes.Count) { $L.Add(''); $L.Add('## 내가 표시한 구간·메모'); foreach ($s in ($segs | Select-Object -First 3)) { $L.Add("- 구간 '$($s.label)' $($times[$s.i0].Substring(5, 11)) ~ $($times[$s.i1].Substring(11, 5))") }; foreach ($nt in ($notes | Select-Object -First 3)) { $L.Add("- 메모 '$($nt.label)' $($times[$nt.i].Substring(5, 11))") } }
  # 글자 히트맵
  $rm = @($keys | Select-Object -First $MaxRows | ForEach-Object { Get-RowModel $_ $TextCols } | Where-Object { $_ })
  $L.Add(''); $L.Add("## 글자 히트맵 (왼쪽→오른쪽 = 시간, ${TextCols}칸)")
  $L.Add("범례: $($sq.w)낮음 $($sq.g)보통 $($sq.y)주의 이상(임시) $($sq.o)높은 편 $($sq.r)높음(임시) $($sq.n)값 없음. 이름 앞 ~는 상대색(그 줄 최소~최대 기준, 위험 아님).")
  $L.Add('```')
  foreach ($r in $rm) { $cells = -join ($r.ts | ForEach-Object { Cell $_ }); $m = $r.metric; $L.Add("$(if ($r.relative) { '~' })$($r.label) $cells $(Fmt $m.mean)/$(Fmt $m.max_peak_in_any_minute)$(Unit $r.key)") }
  $L.Add('```')
  $L.Add('(줄 끝 숫자 = 평균/최고)')
  $L.Add('')
  $L.Add('## 같은 폴더의 그림 (모두 아래에 읽는 법 설명이 붙어 있음)')
  foreach ($r in $results) { $L.Add("- $($r.name): $($r.desc)") }
  $L.Add('- 더 자세한 분석이 필요하면 metrics_1min.csv, summary.json, schema.md를 달라고 요청하세요.')
  $L -join "`n"
}
$md = ''; $attempts = @(@(8, 12, 24), @(6, 10, 24), @(5, 8, 20), @(4, 6, 16), @(3, 5, 12))
foreach ($a in $attempts) { $md = Build-Summary $a[0] $a[1] $a[2]; if ($utf8.GetByteCount($md) -le $MaxSummaryBytes) { break } }
[IO.File]::WriteAllText((Join-Path $OutDir 'summary.md'), $md, $utf8)

# =====================================================================
# charts_guide.md
# =====================================================================
$GL = New-Object Collections.Generic.List[string]
$GL.Add('# 그래프 읽는 법'); $GL.Add('')
$GL.Add('이 폴더의 그림은 코드로 그린 PNG이고, 각 그림 아래쪽 띠에도 같은 설명이 들어 있습니다. 모든 기준선과 색 단계는 **임시 값**이며, 그림은 원인을 단정하지 않습니다.'); $GL.Add('')
$GL.Add('## 공통 약속'); $GL.Add('')
$GL.Add('- 시간은 가로축(왼쪽이 오래된 때)입니다. 부팅 직후 3시간 이내 기록이면 `+분`, 아니면 `월-일 시:분`으로 표시합니다.')
$GL.Add('- 색은 연한 베이지(낮음) → 노랑 → 진한 적갈색(높음)입니다. 색만으로 구분하지 않도록 **점 무늬 = 주의 이상(임시), 빗금 무늬 = 높음(임시)**, 선 그래프는 **실선·파선·점선·쇄선 + 줄 끝 이름 표시**를 씁니다.')
$GL.Add('- 보라색 띠 = 사용자가 표시한 구간, 주황 ◆ = 증상 메모. 회색 칸 = 값 없음.')
$GL.Add('- 각 값은 1분 평균입니다. 1분보다 짧은 급등은 평균에 묻힐 수 있어요.'); $GL.Add('')
$guide = @{
  'chart_1_heatmap.png' = @('그림 1. 한눈에 보는 히트맵', '가로=시간, 세로=부품(핵심 최대 14줄). 줄 끝에 평균·최고·임시 판정이 적혀 있습니다.', '진한 칸을 찾고, 같은 시각에 다른 줄도 진해지는지 보세요. "상대색" 줄은 그 줄의 최소~최대 기준이라 진하다고 위험하다는 뜻이 아닙니다.')
  'chart_2_vs_thresholds.png' = @('그림 2. 임시 기준에 얼마나 가까운가', '지표별 상위 5% 값이 임시 기준에서 어디쯤인지 막대로 보여줍니다(길이 50% = 주의 기준, 90% = 높음 기준).', '막대가 점선을 넘는 줄이 "임시 기준으로 눈에 띄는 곳"입니다. 기준 자체가 일반 값이라 이 PC에선 정상일 수도 있어요.')
  'chart_3_thermal_fan.png' = @('그림 3. 온도와 팬 속도', '온도(°C)와 팬 속도(최대 대비 %)를 같은 눈금에 겹쳐 그렸습니다. 주황 음영은 온도는 낮은 편인데 팬은 높은 편인 구간입니다.', '온도가 내려간 뒤에도 팬이 높게 남는지, 팬이 온도보다 늦게 따라가는지 볼 수 있습니다. GPU 팬 0%는 저온 정지 모드일 수 있어요. CPU·케이스 팬은 센서 프로그램이 있을 때만 그려집니다.')
  'chart_4_cpu_gpu.png' = @('그림 4. CPU와 GPU 사용률', 'CPU, GPU, 영상 디코드 사용률과 가장 바쁜 코어를 겹쳐 그렸습니다.', '영상 재생 구간에서 디코드가 오르는지, CPU와 GPU가 같이 오르는지 비교하세요. 코어 하나만 높고 전체가 낮으면 한 프로그램이 한 코어에 몰린 것일 수 있어요.')
  'chart_5_memory_disk.png' = @('그림 5. 메모리와 디스크', '위: 메모리 약속량(커밋)과 디스크 사용 시간(%), 중간: 남은 메모리(GB), 아래: 디스크 응답 시간(ms).', '약속량이 계속 높거나 남은 메모리가 줄면 메모리가 빠듯한 것, 응답 시간이 길고 사용 시간이 높으면 디스크가 느린 것입니다(가능성).')
  'chart_6_segments.png' = @('그림 6. 구간·메모 전후 변화', '표시한 구간의 평균이 기준선보다 높았는지(▲ 주황) 낮았는지(▼ 초록), 메모 직전·직후 5분의 차이를 막대로 보여줍니다.', '▲▼는 좋고 나쁨이 아니라 평소보다 높거나 낮았다는 뜻입니다. 구간 중 어떤 부품이 평소와 가장 달랐는지 찾는 용도예요.')
}
foreach ($r in $results) {
  $gd = $guide[$r.name]; $GL.Add("## $($r.name)"); $GL.Add(''); $GL.Add("**$($gd[0])** ($($r.r.width)×$($r.r.height)px, $($r.r.kb)KB)"); $GL.Add(''); $GL.Add("- 무엇인가: $($gd[1])"); $GL.Add("- 어떻게 읽나: $($gd[2])"); $GL.Add('')
}
if ($results.Count -lt 6) { $GL.Add('## 만들어지지 않은 그림'); $GL.Add(''); $GL.Add('- 해당 데이터가 없으면 그림을 만들지 않습니다(예: 온도 센서가 없으면 그림 3의 CPU 선이 없고, 표시한 구간·메모가 없으면 그림 6이 없음). 빠진 그림은 "측정되지 않았다"는 뜻이지 "문제가 없다"는 뜻이 아닙니다.') }
[IO.File]::WriteAllText((Join-Path $OutDir 'charts_guide.md'), ($GL -join "`n"), $utf8)

Write-Host "[light] 완료: $OutDir" -ForegroundColor Green
Write-Host ("  summary.md        {0,6:N0} bytes" -f $utf8.GetByteCount($md))
foreach ($r in $results) { Write-Host ("  {0,-28} {1}x{2}px {3}KB" -f $r.name, $r.r.width, $r.r.height, $r.r.kb) }
Write-Host '  charts_guide.md'
$OutDir
